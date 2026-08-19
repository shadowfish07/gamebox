package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"me.zqydev/gamebox/server/internal/auth"
	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/config"
	"me.zqydev/gamebox/server/internal/games"
	"me.zqydev/gamebox/server/internal/httpapi"
	"me.zqydev/gamebox/server/internal/matches"
	"me.zqydev/gamebox/server/internal/store"
)

const (
	daemonExitOK      = 0
	daemonExitFailure = 1
	abandonInterval   = time.Minute
	shutdownTimeout   = 10 * time.Second
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	os.Exit(run(ctx, os.Stderr))
}

func run(ctx context.Context, output io.Writer) int {
	logger := newJSONLogger(output)
	if ctx == nil || output == nil {
		return daemonExitFailure
	}
	processConfig, err := config.Load()
	if err != nil {
		logger.write("startup_failed", map[string]any{"stage": "config"})
		return daemonExitFailure
	}

	database, err := store.Open(ctx, processConfig.DBPath)
	if err != nil {
		logger.write("startup_failed", map[string]any{"stage": "store"})
		return daemonExitFailure
	}
	databaseOpen := true
	defer func() {
		if databaseOpen {
			_ = database.Close()
		}
	}()

	serviceClock := clock.Real{}
	componentWriter := &componentLogWriter{logger: logger}
	componentLogger := log.New(componentWriter, "", 0)
	var runtime runtimeComponents
	buildStage := "runtime"
	buildStarted, err := recoverThenBuild(ctx, database, serviceClock, func() error {
		var buildErr error
		runtime, buildStage, buildErr = buildRuntime(database, processConfig, serviceClock, componentLogger)
		return buildErr
	})
	if err != nil {
		if !buildStarted {
			buildStage = "boot_recovery"
		}
		logger.write("startup_failed", map[string]any{"stage": buildStage})
		return daemonExitFailure
	}

	workerContext, cancelWorkers := context.WithCancel(context.Background())
	workerErrors := make(chan error, 2)
	workersDone := make(chan struct{})
	go runWorkers(workerContext, runtime.presence, runtime.matches, runtime.hub, workerErrors, workersDone)

	listener, err := net.Listen("tcp", processConfig.Addr)
	if err != nil {
		cancelWorkers()
		<-workersDone
		logger.write("startup_failed", map[string]any{"stage": "listen"})
		return daemonExitFailure
	}
	httpServer := &http.Server{
		Handler:           runtime.handler,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       time.Minute,
		MaxHeaderBytes:    16 * 1024,
		ErrorLog:          componentLogger,
	}
	serveResult := make(chan error, 1)
	go func() { serveResult <- httpServer.Serve(listener) }()
	logger.write("server_started", map[string]any{"address": listener.Addr().String()})

	exitCode := daemonExitOK
	reason := "signal"
	select {
	case <-ctx.Done():
	case workerErr := <-workerErrors:
		if workerErr != nil {
			exitCode = daemonExitFailure
			reason = "worker_error"
		}
	case serveErr := <-serveResult:
		if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) && !errors.Is(serveErr, net.ErrClosed) {
			exitCode = daemonExitFailure
			reason = "serve_error"
		}
	}

	shutdownStage, shutdownErr := shutdownRuntime(shutdownTimeout, shutdownHooks{
		shutdownHTTP: httpServer.Shutdown,
		forceHTTP:    httpServer.Close,
		stopWorkers:  cancelWorkers,
		waitWorkers: func(waitContext context.Context) error {
			select {
			case <-workersDone:
				return nil
			case <-waitContext.Done():
				return waitContext.Err()
			}
		},
		closeHub:      runtime.hub.Close,
		closeDatabase: database.Close,
	})
	databaseOpen = false
	if shutdownErr != nil {
		exitCode = daemonExitFailure
		reason = shutdownStage + "_shutdown_error"
	}
	for {
		select {
		case workerErr := <-workerErrors:
			if workerErr != nil && exitCode == daemonExitOK {
				exitCode = daemonExitFailure
				reason = "worker_error"
			}
		default:
			goto workersDrained
		}
	}

workersDrained:
	select {
	case serveErr := <-serveResult:
		if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) && !errors.Is(serveErr, net.ErrClosed) && exitCode == daemonExitOK {
			exitCode = daemonExitFailure
			reason = "serve_error"
		}
	default:
	}
	logger.write("server_stopped", map[string]any{"exitCode": exitCode, "reason": reason})
	return exitCode
}

type runtimeComponents struct {
	matches  *matches.Service
	presence *matches.Presence
	hub      *matches.Hub
	handler  http.Handler
}

func recoverThenBuild(ctx context.Context, database *sql.DB, serviceClock clock.Clock, build func() error) (bool, error) {
	if build == nil {
		return false, errors.New("runtime builder is nil")
	}
	if err := matches.MarkActiveMatchesOfflineOnBoot(ctx, database, serviceClock); err != nil {
		return false, err
	}
	return true, build()
}

func buildRuntime(database *sql.DB, processConfig config.Config, serviceClock clock.Clock, componentLogger *log.Logger) (runtimeComponents, string, error) {
	registry := games.NewRegistry()
	authService, err := auth.NewService(database, serviceClock, auth.ServiceConfig{
		JWTSecret: []byte(processConfig.JWTSecret), TokenPepper: processConfig.TokenPepper,
	})
	if err != nil {
		return runtimeComponents{}, "auth", err
	}
	matchService, err := matches.NewServiceWithConfig(database, registry, serviceClock, matches.ServiceConfig{
		ColorRandom: rand.Reader, LaunchTicketRandom: rand.Reader, TokenPepper: processConfig.TokenPepper,
	})
	if err != nil {
		return runtimeComponents{}, "matches", err
	}
	presence, err := matches.NewPresence(matchService, serviceClock)
	if err != nil {
		return runtimeComponents{}, "presence", err
	}
	hub, err := matches.NewHubWithConfig(matchService, presence, serviceClock, matches.HubConfig{Logger: componentLogger})
	if err != nil {
		return runtimeComponents{}, "hub", err
	}
	handler, err := httpapi.NewRouter(httpapi.RouterConfig{
		Auth: authService, Matches: matchService, Games: registry, Publisher: hub, Hub: hub,
		Logger: componentLogger, RequestIDs: httpapi.NewProductionRequestID,
	})
	if err != nil {
		return runtimeComponents{}, "router", err
	}
	return runtimeComponents{matches: matchService, presence: presence, hub: hub, handler: handler}, "", nil
}

type shutdownHooks struct {
	shutdownHTTP  func(context.Context) error
	forceHTTP     func() error
	stopWorkers   func()
	waitWorkers   func(context.Context) error
	closeHub      func(context.Context) error
	closeDatabase func() error
}

func shutdownRuntime(timeout time.Duration, hooks shutdownHooks) (string, error) {
	if timeout <= 0 || hooks.shutdownHTTP == nil || hooks.forceHTTP == nil || hooks.stopWorkers == nil ||
		hooks.waitWorkers == nil || hooks.closeHub == nil || hooks.closeDatabase == nil {
		return "configuration", errors.New("invalid shutdown configuration")
	}
	var firstStage string
	var result error
	record := func(stage string, err error) {
		if err == nil {
			return
		}
		if firstStage == "" {
			firstStage = stage
		}
		result = errors.Join(result, err)
	}

	httpContext, cancelHTTP := context.WithTimeout(context.Background(), timeout)
	httpErr := hooks.shutdownHTTP(httpContext)
	cancelHTTP()
	if httpErr != nil {
		record("http", httpErr)
		record("http", hooks.forceHTTP())
	}

	hooks.stopWorkers()
	workerContext, cancelWorkers := context.WithTimeout(context.Background(), timeout)
	record("worker", hooks.waitWorkers(workerContext))
	cancelWorkers()

	hubContext, cancelHub := context.WithTimeout(context.Background(), timeout)
	record("hub", hooks.closeHub(hubContext))
	cancelHub()

	record("store", hooks.closeDatabase())
	return firstStage, result
}

func runWorkers(ctx context.Context, presence *matches.Presence, service *matches.Service, hub *matches.Hub, failures chan<- error, done chan<- struct{}) {
	defer close(done)
	var workers sync.WaitGroup
	workers.Add(2)
	go func() {
		defer workers.Done()
		if err := presence.Run(ctx); err != nil && ctx.Err() == nil {
			nonblockingError(failures, err)
		}
	}()
	go func() {
		defer workers.Done()
		if err := runAbandonWorker(ctx, service, hub); err != nil && ctx.Err() == nil {
			nonblockingError(failures, err)
		}
	}()
	workers.Wait()
}

func runAbandonWorker(ctx context.Context, service *matches.Service, hub *matches.Hub) error {
	if err := abandonExpired(ctx, service, hub); err != nil {
		return err
	}
	ticker := time.NewTicker(abandonInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
			if err := abandonExpired(ctx, service, hub); err != nil {
				if ctx.Err() != nil {
					return nil
				}
				return err
			}
		}
	}
}

func abandonExpired(ctx context.Context, service *matches.Service, hub *matches.Hub) error {
	events, err := service.AbandonExpired(ctx)
	if err != nil {
		return err
	}
	for _, event := range events {
		hub.Publish(event.MatchID, event)
	}
	return nil
}

func nonblockingError(destination chan<- error, err error) {
	select {
	case destination <- err:
	default:
	}
}

type jsonLogger struct {
	mu     sync.Mutex
	output io.Writer
}

func newJSONLogger(output io.Writer) *jsonLogger { return &jsonLogger{output: output} }

func (logger *jsonLogger) write(event string, fields map[string]any) {
	if logger == nil || logger.output == nil {
		return
	}
	record := make(map[string]any, len(fields)+2)
	record["event"] = event
	record["timestamp"] = time.Now().UTC().Format(time.RFC3339Nano)
	for key, value := range fields {
		record[key] = value
	}
	logger.mu.Lock()
	defer logger.mu.Unlock()
	_ = json.NewEncoder(logger.output).Encode(record)
}

// componentLogWriter converts the fixed, secret-free key/value records from
// the HTTP router and WebSocket hub into structured JSON. Unknown fields and
// free-form net/http diagnostics are discarded instead of being echoed.
type componentLogWriter struct {
	mu     sync.Mutex
	buffer strings.Builder
	logger *jsonLogger
}

func (writer *componentLogWriter) Write(data []byte) (int, error) {
	writer.mu.Lock()
	defer writer.mu.Unlock()
	writer.buffer.Write(data)
	for {
		contents := writer.buffer.String()
		newline := strings.IndexByte(contents, '\n')
		if newline < 0 {
			break
		}
		line := contents[:newline]
		remainder := contents[newline+1:]
		writer.buffer.Reset()
		writer.buffer.WriteString(remainder)
		writer.writeLine(line)
	}
	return len(data), nil
}

func (writer *componentLogWriter) writeLine(line string) {
	fields := make(map[string]any)
	event := "component"
	for _, field := range strings.Fields(line) {
		key, value, found := strings.Cut(field, "=")
		if !found {
			continue
		}
		switch key {
		case "event":
			if value == "websocket_connected" || value == "websocket_closed" || value == "hub_closed" {
				event = value
			}
		case "request_id", "method", "path", "connection_id", "match_id", "user_id":
			fields[key] = value
		case "status":
			if status, err := strconv.Atoi(value); err == nil {
				fields[key] = status
			}
		case "panic":
			if panicked, err := strconv.ParseBool(value); err == nil {
				fields[key] = panicked
			}
		}
	}
	if _, request := fields["request_id"]; request {
		event = "http_request"
	}
	writer.logger.write(event, fields)
}
