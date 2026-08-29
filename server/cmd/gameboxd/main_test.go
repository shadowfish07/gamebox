package main

import (
	"bufio"
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/store"
)

func TestRunServesHealthAndShutsDownCleanly(t *testing.T) {
	databasePath := filepath.Join(t.TempDir(), "gamebox.sqlite")
	jwtSecret := "daemon-test-jwt-secret-at-least-thirty-two-bytes"
	pepper := "daemon-test-token-pepper-at-least-thirty-two-bytes"
	t.Setenv("GAMEBOX_ADDR", "127.0.0.1:0")
	t.Setenv("GAMEBOX_DB_PATH", databasePath)
	t.Setenv("GAMEBOX_JWT_SECRET", jwtSecret)
	t.Setenv("GAMEBOX_TOKEN_PEPPER", pepper)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	logs := &lockedBuffer{}
	exited := make(chan int, 1)
	go func() { exited <- run(ctx, logs) }()

	address := waitForStartedAddress(t, logs)
	client := &http.Client{Timeout: 2 * time.Second}
	response, err := client.Get("http://" + address + "/healthz")
	if err != nil {
		t.Fatalf("GET healthz: %v\nlogs:\n%s", err, logs.String())
	}
	body, err := io.ReadAll(response.Body)
	_ = response.Body.Close()
	if err != nil || response.StatusCode != http.StatusOK || string(body) != "{\"status\":\"ok\"}\n" {
		t.Fatalf("health=(%d,%q,%v)", response.StatusCode, body, err)
	}

	cancel()
	select {
	case code := <-exited:
		if code != daemonExitOK {
			t.Fatalf("exit=%d logs:\n%s", code, logs.String())
		}
	case <-time.After(15 * time.Second):
		t.Fatalf("daemon did not stop\nlogs:\n%s", logs.String())
	}
	logged := logs.String()
	if strings.Contains(logged, jwtSecret) || strings.Contains(logged, pepper) {
		t.Fatalf("logs contain a secret: %s", logged)
	}
	records := decodeLogRecords(t, logged)
	if !hasLogEvent(records, "http_request") || !hasLogEvent(records, "hub_closed") || !hasLogEvent(records, "server_stopped") {
		t.Fatalf("missing lifecycle/request logs: %+v", records)
	}
}

func TestComponentLogWriterDecodesDiagnosticError(t *testing.T) {
	var output bytes.Buffer
	writer := &componentLogWriter{logger: newJSONLogger(&output)}
	if _, err := writer.Write([]byte("event=service_error request_id=00000000-0000-4000-8000-000000000001 phase=authenticate category=internal error_b64=c3FsaXRlOiBkYXRhYmFzZSBpcyBsb2NrZWQ\n")); err != nil {
		t.Fatalf("write component log: %v", err)
	}
	records := decodeLogRecords(t, output.String())
	if len(records) != 1 || records[0]["error"] != "sqlite: database is locked" {
		t.Fatalf("diagnostic record = %#v", records)
	}
}

func TestComponentLogWriterAllowListsIdentifiersAndDropsFreeFormSecrets(t *testing.T) {
	var output bytes.Buffer
	logger := newJSONLogger(&output)
	writer := &componentLogWriter{logger: logger}
	secret := "a-secret-that-must-not-be-logged"
	_, _ = writer.Write([]byte("request_id=11111111-1111-4111-8111-111111111111 method=GET path=/healthz status=200 panic=false credential=" + secret + "\n"))
	_, _ = writer.Write([]byte("net/http arbitrary diagnostic " + secret + "\n"))
	records := decodeLogRecords(t, output.String())
	if len(records) != 2 || records[0]["event"] != "http_request" || records[0]["request_id"] == nil || strings.Contains(output.String(), secret) {
		t.Fatalf("records=%+v output=%q", records, output.String())
	}
}

func TestRecoveryCompletesBeforeRuntimeBuilderStarts(t *testing.T) {
	database := openDaemonTestDatabase(t)
	now := time.Date(2026, time.August, 20, 8, 9, 10, 0, time.UTC)
	if _, err := database.Exec(`INSERT INTO matches(id,game_id,status,revision,created_at,updated_at) VALUES (?,?,?,?,?,?)`,
		"11111111-1111-4111-8111-111111111111", "gomoku", "active", 0, now.UnixMilli(), now.UnixMilli()); err != nil {
		t.Fatal(err)
	}
	builderCalls := 0
	started, err := recoverThenBuild(context.Background(), database, clock.NewFake(now), func() error {
		builderCalls++
		var offlineSince sql.NullInt64
		if err := database.QueryRow(`SELECT both_offline_since FROM matches WHERE id='11111111-1111-4111-8111-111111111111'`).Scan(&offlineSince); err != nil {
			return err
		}
		if !offlineSince.Valid || offlineSince.Int64 != now.UnixMilli() {
			t.Fatalf("runtime builder observed recovery=%v, want %d", offlineSince, now.UnixMilli())
		}
		return nil
	})
	if err != nil || !started || builderCalls != 1 {
		t.Fatalf("recoverThenBuild=(started=%t err=%v calls=%d)", started, err, builderCalls)
	}

	canceled, cancel := context.WithCancel(context.Background())
	cancel()
	builderCalls = 0
	started, err = recoverThenBuild(canceled, database, clock.NewFake(now), func() error {
		builderCalls++
		return nil
	})
	if !errors.Is(err, context.Canceled) || started || builderCalls != 0 {
		t.Fatalf("failed recovery=(started=%t err=%v calls=%d)", started, err, builderCalls)
	}
}

func TestShutdownWaitsForHTTPBeforeStoppingWorkersThenClosesHubAndDatabase(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	handlerEntered := make(chan struct{})
	releaseHandler := make(chan struct{})
	server := &http.Server{Handler: http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		close(handlerEntered)
		<-releaseHandler
		writer.WriteHeader(http.StatusNoContent)
	})}
	serveDone := make(chan error, 1)
	go func() { serveDone <- server.Serve(listener) }()
	clientDone := make(chan error, 1)
	go func() {
		response, requestErr := (&http.Client{Timeout: 2 * time.Second}).Get("http://" + listener.Addr().String())
		if response != nil {
			_ = response.Body.Close()
		}
		clientDone <- requestErr
	}()
	select {
	case <-handlerEntered:
	case <-time.After(time.Second):
		t.Fatal("blocking handler did not start")
	}

	workerContext, cancelWorker := context.WithCancel(context.Background())
	workerTick := make(chan chan struct{})
	workerDone := make(chan struct{})
	go func() {
		defer close(workerDone)
		for {
			select {
			case acknowledgment := <-workerTick:
				close(acknowledgment)
			case <-workerContext.Done():
				return
			}
		}
	}()

	var orderMu sync.Mutex
	var order []string
	record := func(event string) {
		orderMu.Lock()
		defer orderMu.Unlock()
		order = append(order, event)
	}
	stopped := make(chan struct{})
	shutdownDone := make(chan struct {
		stage string
		err   error
	}, 1)
	go func() {
		stage, shutdownErr := shutdownRuntime(time.Second, shutdownHooks{
			shutdownHTTP: func(ctx context.Context) error { record("http"); return server.Shutdown(ctx) },
			forceHTTP:    server.Close,
			stopWorkers: func() {
				record("workers_stop")
				cancelWorker()
				close(stopped)
			},
			waitWorkers: func(ctx context.Context) error {
				record("workers_wait")
				select {
				case <-workerDone:
					return nil
				case <-ctx.Done():
					return ctx.Err()
				}
			},
			closeHub: func(context.Context) error { record("hub"); return nil },
			closeDatabase: func() error {
				record("database")
				return nil
			},
		})
		shutdownDone <- struct {
			stage string
			err   error
		}{stage: stage, err: shutdownErr}
	}()

	acknowledged := make(chan struct{})
	workerTick <- acknowledged
	select {
	case <-acknowledged:
	case <-time.After(time.Second):
		t.Fatal("worker stopped while HTTP shutdown was blocked")
	}
	select {
	case <-stopped:
		t.Fatal("workers stopped before HTTP handler completed")
	default:
	}
	close(releaseHandler)
	result := <-shutdownDone
	if result.err != nil || result.stage != "" {
		t.Fatalf("shutdown=(%q,%v)", result.stage, result.err)
	}
	if got, want := order, []string{"http", "workers_stop", "workers_wait", "hub", "database"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("shutdown order=%v want=%v", got, want)
	}
	if err := <-clientDone; err != nil {
		t.Fatalf("in-flight request: %v", err)
	}
	if err := <-serveDone; err != nil && !errors.Is(err, http.ErrServerClosed) {
		t.Fatalf("Serve: %v", err)
	}
}

func TestShutdownTimeoutForcesHTTPClosedBeforeStoppingWorkers(t *testing.T) {
	var order []string
	record := func(event string) { order = append(order, event) }
	stage, err := shutdownRuntime(20*time.Millisecond, shutdownHooks{
		shutdownHTTP: func(ctx context.Context) error {
			record("http")
			<-ctx.Done()
			return ctx.Err()
		},
		forceHTTP:   func() error { record("http_force"); return nil },
		stopWorkers: func() { record("workers_stop") },
		waitWorkers: func(context.Context) error {
			record("workers_wait")
			return nil
		},
		closeHub: func(context.Context) error { record("hub"); return nil },
		closeDatabase: func() error {
			record("database")
			return nil
		},
	})
	if !errors.Is(err, context.DeadlineExceeded) || stage != "http" {
		t.Fatalf("shutdown=(%q,%v)", stage, err)
	}
	want := []string{"http", "http_force", "workers_stop", "workers_wait", "hub", "database"}
	if !reflect.DeepEqual(order, want) {
		t.Fatalf("shutdown order=%v want=%v", order, want)
	}
}

func TestProcessTerminationSignalsRestoreDefaultAfterFirstSignal(t *testing.T) {
	binary := filepath.Join(t.TempDir(), "gameboxd")
	build := exec.Command("go", "build", "-o", binary, ".")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build gameboxd: %v\n%s", err, output)
	}

	t.Run("single TERM exits zero", func(t *testing.T) {
		process := startDaemonProcess(t, binary)
		address := waitForStartedAddress(t, process.logs)
		assertProcessHealth(t, address)
		if err := process.command.Process.Signal(syscall.SIGTERM); err != nil {
			t.Fatal(err)
		}
		if err := process.wait(t, 15*time.Second); err != nil {
			t.Fatalf("single TERM wait: %v\nlogs:\n%s", err, process.logs.String())
		}
		logged := process.logs.String()
		if !strings.Contains(logged, `"event":"server_stopped"`) || !strings.Contains(logged, `"exitCode":0`) {
			t.Fatalf("single TERM missing clean stop: %s", logged)
		}
	})

	t.Run("second TERM force terminates blocked shutdown", func(t *testing.T) {
		process := startDaemonProcess(t, binary)
		address := waitForStartedAddress(t, process.logs)
		assertProcessHealth(t, address)
		connection, err := net.DialTimeout("tcp", address, time.Second)
		if err != nil {
			t.Fatal(err)
		}
		defer connection.Close()
		if _, err := fmt.Fprintf(connection, "POST /v1/auth/register HTTP/1.1\r\nHost: %s\r\nContent-Type: application/json\r\nContent-Length: 100\r\nExpect: 100-continue\r\n\r\n", address); err != nil {
			t.Fatal(err)
		}
		if err := connection.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
			t.Fatal(err)
		}
		reader := bufio.NewReader(connection)
		statusLine, err := reader.ReadString('\n')
		if err != nil || !strings.Contains(statusLine, " 100 ") {
			t.Fatalf("blocked request status=%q err=%v", statusLine, err)
		}
		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				t.Fatalf("read 100 Continue headers: %v", err)
			}
			if line == "\r\n" {
				break
			}
		}
		if err := connection.SetReadDeadline(time.Time{}); err != nil {
			t.Fatal(err)
		}

		if err := process.command.Process.Signal(syscall.SIGTERM); err != nil {
			t.Fatal(err)
		}
		waitForListenerClosed(t, address, time.Second)
		waitForLogEvent(t, process.logs, "shutdown_started", time.Second)
		select {
		case err := <-process.result:
			process.finished = true
			t.Fatalf("process exited before second TERM: %v\nlogs:\n%s", err, process.logs.String())
		default:
		}
		started := time.Now()
		if err := process.command.Process.Signal(syscall.SIGTERM); err != nil {
			t.Fatal(err)
		}
		err = process.wait(t, time.Second)
		if err == nil || time.Since(started) > time.Second {
			t.Fatalf("second TERM result=%v elapsed=%s logs:\n%s", err, time.Since(started), process.logs.String())
		}
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			t.Fatalf("second TERM error=%T %v", err, err)
		}
		status, ok := exitErr.Sys().(syscall.WaitStatus)
		if !ok || !status.Signaled() || status.Signal() != syscall.SIGTERM {
			t.Fatalf("second TERM wait status=%v", exitErr.Sys())
		}
	})
}

type daemonProcess struct {
	command  *exec.Cmd
	logs     *lockedBuffer
	result   chan error
	finished bool
}

func startDaemonProcess(t *testing.T, binary string) *daemonProcess {
	t.Helper()
	directory := t.TempDir()
	logs := &lockedBuffer{}
	command := exec.Command(binary)
	command.Env = append(os.Environ(),
		"GAMEBOX_ADDR=127.0.0.1:0",
		"GAMEBOX_DB_PATH="+filepath.Join(directory, "gamebox.sqlite"),
		"GAMEBOX_JWT_SECRET=process-test-jwt-secret-at-least-thirty-two-bytes",
		"GAMEBOX_TOKEN_PEPPER=process-test-token-pepper-at-least-thirty-two-bytes",
	)
	command.Stdout = io.Discard
	command.Stderr = logs
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	process := &daemonProcess{command: command, logs: logs, result: make(chan error, 1)}
	go func() { process.result <- command.Wait() }()
	t.Cleanup(func() {
		if process.finished {
			return
		}
		_ = command.Process.Kill()
		select {
		case <-process.result:
		case <-time.After(2 * time.Second):
		}
		process.finished = true
	})
	return process
}

func assertProcessHealth(t *testing.T, address string) {
	t.Helper()
	response, err := (&http.Client{Timeout: 2 * time.Second}).Get("http://" + address + "/healthz")
	if err != nil {
		t.Fatalf("GET healthz: %v", err)
	}
	body, readErr := io.ReadAll(response.Body)
	_ = response.Body.Close()
	if readErr != nil || response.StatusCode != http.StatusOK || string(body) != "{\"status\":\"ok\"}\n" {
		t.Fatalf("health=(%d,%q,%v)", response.StatusCode, body, readErr)
	}
}

func (process *daemonProcess) wait(t *testing.T, timeout time.Duration) error {
	t.Helper()
	select {
	case err := <-process.result:
		process.finished = true
		return err
	case <-time.After(timeout):
		return errors.New("process wait timed out")
	}
}

func waitForListenerClosed(t *testing.T, address string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		connection, err := net.DialTimeout("tcp", address, 20*time.Millisecond)
		if err != nil {
			return
		}
		_ = connection.Close()
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("listener remained open after first termination signal")
}

func waitForLogEvent(t *testing.T, logs *lockedBuffer, event string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		for _, record := range decodeCompleteLogRecords(t, logs.String()) {
			if record["event"] == event {
				return
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("log event %q did not appear\nlogs:\n%s", event, logs.String())
}

type lockedBuffer struct {
	mu     sync.Mutex
	buffer bytes.Buffer
}

func openDaemonTestDatabase(t *testing.T) *sql.DB {
	t.Helper()
	database, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "gamebox.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := database.Close(); err != nil {
			t.Errorf("close database: %v", err)
		}
	})
	return database
}

func (buffer *lockedBuffer) Write(data []byte) (int, error) {
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	return buffer.buffer.Write(data)
}

func (buffer *lockedBuffer) String() string {
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	return buffer.buffer.String()
}

func waitForStartedAddress(t *testing.T, logs *lockedBuffer) string {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		for _, record := range decodeCompleteLogRecords(t, logs.String()) {
			if record["event"] == "server_started" {
				address, ok := record["address"].(string)
				if !ok || address == "" {
					t.Fatalf("invalid started record: %+v", record)
				}
				return address
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("server did not start\nlogs:\n%s", logs.String())
	return ""
}

func decodeCompleteLogRecords(t *testing.T, contents string) []map[string]any {
	t.Helper()
	lines := strings.Split(contents, "\n")
	records := make([]map[string]any, 0, len(lines))
	for _, line := range lines[:max(0, len(lines)-1)] {
		if line == "" {
			continue
		}
		var record map[string]any
		if err := json.Unmarshal([]byte(line), &record); err != nil {
			t.Fatalf("invalid complete JSON log %q: %v", line, err)
		}
		records = append(records, record)
	}
	return records
}

func decodeLogRecords(t *testing.T, contents string) []map[string]any {
	t.Helper()
	if !strings.HasSuffix(contents, "\n") {
		t.Fatalf("logs do not end on a JSON line: %q", contents)
	}
	return decodeCompleteLogRecords(t, contents)
}

func hasLogEvent(records []map[string]any, event string) bool {
	for _, record := range records {
		if record["event"] == event {
			return true
		}
	}
	return false
}
