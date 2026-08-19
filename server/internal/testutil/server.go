package testutil

import (
	"bytes"
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"me.zqydev/gamebox/server/internal/auth"
	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/games"
	"me.zqydev/gamebox/server/internal/httpapi"
	"me.zqydev/gamebox/server/internal/matches"
	"me.zqydev/gamebox/server/internal/store"
)

const (
	testJWTSecret      = "gamebox-e2e-jwt-secret-at-least-thirty-two-bytes"
	testTokenPepper    = "gamebox-e2e-token-pepper-at-least-thirty-two-bytes"
	testWorkerInterval = 15 * time.Second
	testPresencePoll   = 2 * time.Millisecond
	testMaximumInvites = 1000
)

type ServerConfig struct {
	DatabasePath     string
	Clock            *clock.Fake
	ColorRandom      io.Reader
	CredentialRandom io.Reader
}

// Server is a full real-transport integration harness. Only time and entropy
// are injectable: persistence, migrations, services, Router, Hub, Presence,
// HTTP, and WebSocket serialization are the production implementations.
type Server struct {
	URL      string
	API      *APIClient
	DB       *sql.DB
	Clock    *clock.Fake
	Matches  *matches.Service
	Presence *matches.Presence
	Hub      *matches.Hub

	httpServer *httptest.Server
	logs       *synchronizedBuffer
	workers    context.CancelFunc
	workerDone chan struct{}
	workerErrs chan error
	httpDone   chan struct{}
	handlers   *handlerLifecycle

	mu         sync.Mutex
	closing    bool
	dialing    int
	handshakes int
	clients    []*WebSocketClient
	shutdown   sync.Once
	finalizeMu sync.Mutex
	finalized  bool
	finalErr   error
}

type handlerLifecycle struct {
	next   http.Handler
	active atomic.Int64
}

func (lifecycle *handlerLifecycle) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	if request != nil && request.URL.Path == "/v1/ws" {
		lifecycle.active.Add(1)
		defer lifecycle.active.Add(-1)
	}
	lifecycle.next.ServeHTTP(writer, request)
}

type synchronizedBuffer struct {
	mu      sync.Mutex
	content bytes.Buffer
}

func (buffer *synchronizedBuffer) Write(data []byte) (int, error) {
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	return buffer.content.Write(data)
}

func (buffer *synchronizedBuffer) String() string {
	buffer.mu.Lock()
	defer buffer.mu.Unlock()
	return buffer.content.String()
}

func StartServer(ctx context.Context, config ServerConfig) (*Server, error) {
	if ctx == nil || ctx.Err() != nil || strings.TrimSpace(config.DatabasePath) == "" || config.Clock == nil {
		return nil, errors.New("invalid test server configuration")
	}
	colorRandom := config.ColorRandom
	if colorRandom == nil {
		colorRandom = rand.Reader
	}
	credentialRandom := config.CredentialRandom
	if credentialRandom == nil {
		credentialRandom = rand.Reader
	}

	database, err := store.Open(ctx, config.DatabasePath)
	if err != nil {
		return nil, fmt.Errorf("start test server store: %w", err)
	}
	closeDatabase := true
	defer func() {
		if closeDatabase {
			_ = database.Close()
		}
	}()

	registry := games.NewRegistry()
	authService, err := auth.NewService(database, config.Clock, auth.ServiceConfig{
		JWTSecret: []byte(testJWTSecret), TokenPepper: testTokenPepper,
	})
	if err != nil {
		return nil, fmt.Errorf("start test server auth: %w", err)
	}
	matchService, err := matches.NewServiceWithConfig(database, registry, config.Clock, matches.ServiceConfig{
		ColorRandom: colorRandom, LaunchTicketRandom: credentialRandom, TokenPepper: testTokenPepper,
	})
	if err != nil {
		return nil, fmt.Errorf("start test server matches: %w", err)
	}
	if err := matchService.MarkActiveMatchesOfflineOnBoot(ctx); err != nil {
		return nil, fmt.Errorf("start test server boot recovery: %w", err)
	}
	presence, err := matches.NewPresence(matchService, config.Clock)
	if err != nil {
		return nil, fmt.Errorf("start test server presence: %w", err)
	}
	hub, err := matches.NewHubWithConfig(matchService, presence, config.Clock, matches.HubConfig{
		FirstMessageTimeout: 2 * time.Second,
		HeartbeatInterval:   time.Hour,
		ActivityTimeout:     time.Hour,
	})
	if err != nil {
		return nil, fmt.Errorf("start test server hub: %w", err)
	}
	logs := &synchronizedBuffer{}
	handler, err := httpapi.NewRouter(httpapi.RouterConfig{
		Auth: authService, Matches: matchService, Games: registry, Publisher: hub, Hub: hub,
		Logger: log.New(logs, "", 0), RequestIDs: httpapi.NewProductionRequestID,
	})
	if err != nil {
		return nil, fmt.Errorf("start test server router: %w", err)
	}
	handlers := &handlerLifecycle{next: handler}
	httpServer := httptest.NewServer(handlers)
	apiClient, err := NewAPIClient(httpServer.URL, httpServer.Client())
	if err != nil {
		httpServer.Close()
		return nil, fmt.Errorf("start test server client: %w", err)
	}

	workerContext, cancelWorkers := context.WithCancel(context.Background())
	server := &Server{
		URL: httpServer.URL, API: apiClient, DB: database, Clock: config.Clock,
		Matches: matchService, Presence: presence, Hub: hub,
		httpServer: httpServer, logs: logs, workers: cancelWorkers,
		workerDone: make(chan struct{}), workerErrs: make(chan error, 2),
		httpDone: make(chan struct{}), handlers: handlers,
	}
	go server.runWorkers(workerContext)
	closeDatabase = false
	return server, nil
}

func (server *Server) runWorkers(ctx context.Context) {
	var workers sync.WaitGroup
	workers.Add(2)
	go func() {
		defer workers.Done()
		if err := server.Presence.Run(ctx); err != nil {
			server.workerErrs <- fmt.Errorf("presence worker: %w", err)
		}
	}()
	go func() {
		defer workers.Done()
		ticker := time.NewTicker(testWorkerInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				events, err := server.Matches.AbandonExpired(ctx)
				if err != nil {
					if ctx.Err() == nil {
						server.workerErrs <- fmt.Errorf("abandon worker: %w", err)
					}
					return
				}
				for _, event := range events {
					server.Hub.Publish(event.MatchID, event)
				}
			}
		}
	}()
	workers.Wait()
	close(server.workerDone)
}

func (server *Server) CreateInvites(ctx context.Context, count int) (_ []string, err error) {
	if server == nil || server.DB == nil || ctx == nil || count < 1 || count > testMaximumInvites {
		return nil, errors.New("invalid invite request")
	}
	transaction, err := server.DB.BeginTx(ctx, nil)
	if err != nil {
		return nil, errors.New("create invites failed")
	}
	defer func() {
		if rollbackErr := transaction.Rollback(); rollbackErr != nil && !errors.Is(rollbackErr, sql.ErrTxDone) && err == nil {
			err = errors.New("create invites failed")
		}
	}()
	createdAt := server.Clock.Now().UTC().UnixMilli()
	invites := make([]string, 0, count)
	for range count {
		plaintext, tokenErr := auth.RandomToken(32)
		if tokenErr != nil {
			return nil, errors.New("create invites failed")
		}
		digest, hashErr := auth.HashToken(testTokenPepper, plaintext)
		if hashErr != nil {
			return nil, errors.New("create invites failed")
		}
		if _, insertErr := transaction.ExecContext(ctx, `INSERT INTO invite_codes(code_hash,created_at) VALUES (?,?)`, digest, createdAt); insertErr != nil {
			return nil, errors.New("create invites failed")
		}
		invites = append(invites, plaintext)
	}
	if commitErr := transaction.Commit(); commitErr != nil {
		return nil, errors.New("create invites failed")
	}
	return invites, nil
}

func (server *Server) DialWebSocket(ctx context.Context) (*WebSocketClient, error) {
	if server == nil || ctx == nil {
		return nil, errors.New("invalid test server")
	}
	server.mu.Lock()
	if server.closing {
		server.mu.Unlock()
		return nil, errors.New("test server is closed")
	}
	server.dialing++
	server.mu.Unlock()
	client, err := DialWebSocket(ctx, server.URL)
	server.mu.Lock()
	server.dialing--
	if err != nil {
		server.mu.Unlock()
		return nil, err
	}
	if server.closing {
		server.mu.Unlock()
		client.closeNow()
		return nil, errors.New("test server is closed")
	}
	client.onHandshakeStart = server.beginHandshake
	client.onHandshakeDone = server.finishHandshake
	client.onConnected = func(_, _ string) {
		server.mu.Lock()
		closing := server.closing
		server.mu.Unlock()
		if closing {
			client.closeNow()
		}
	}
	server.clients = append(server.clients, client)
	server.mu.Unlock()
	return client, nil
}

func (server *Server) beginHandshake() bool {
	server.mu.Lock()
	defer server.mu.Unlock()
	if server.closing {
		return false
	}
	server.handshakes++
	return true
}

func (server *Server) finishHandshake() {
	server.mu.Lock()
	server.handshakes--
	server.mu.Unlock()
}

func (server *Server) Logs() string {
	if server == nil || server.logs == nil {
		return ""
	}
	return server.logs.String()
}

func (server *Server) Close(ctx context.Context) error {
	if server == nil {
		return nil
	}
	if ctx == nil {
		return errors.New("invalid close context")
	}
	server.shutdown.Do(server.beginShutdown)
	if err := server.waitForShutdown(ctx); err != nil {
		return err
	}

	server.finalizeMu.Lock()
	defer server.finalizeMu.Unlock()
	if server.finalized {
		return server.finalErr
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	var result error
	for {
		select {
		case workerErr := <-server.workerErrs:
			result = errors.Join(result, workerErr)
		default:
			if closeErr := server.DB.Close(); closeErr != nil {
				result = errors.Join(result, closeErr)
			}
			server.finalErr = result
			server.finalized = true
			return result
		}
	}
}

func (server *Server) beginShutdown() {
	server.mu.Lock()
	server.closing = true
	clients := append([]*WebSocketClient(nil), server.clients...)
	server.mu.Unlock()

	server.workers()
	for _, client := range clients {
		client.closeNow()
	}
	go func() {
		server.httpServer.Close()
		close(server.httpDone)
	}()
}

func (server *Server) waitForShutdown(ctx context.Context) error {
	ticker := time.NewTicker(testPresencePoll)
	defer ticker.Stop()
	for {
		server.mu.Lock()
		clients := append([]*WebSocketClient(nil), server.clients...)
		transportWork := server.dialing + server.handshakes
		server.mu.Unlock()
		for _, client := range clients {
			client.closeNow()
		}
		if transportWork == 0 && server.handlers.active.Load() == 0 && channelClosed(server.workerDone) && channelClosed(server.httpDone) {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

func channelClosed(channel <-chan struct{}) bool {
	select {
	case <-channel:
		return true
	default:
		return false
	}
}
