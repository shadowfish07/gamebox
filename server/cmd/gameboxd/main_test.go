package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
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

type lockedBuffer struct {
	mu     sync.Mutex
	buffer bytes.Buffer
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
