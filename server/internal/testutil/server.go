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
	"net/http/httptest"
	"strings"
	"sync"
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

type connectionBinding struct {
	matchID string
	userID  string
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

	mu        sync.Mutex
	closed    bool
	clients   []*WebSocketClient
	bindings  []connectionBinding
	closeOnce sync.Once
	closeErr  error
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
	httpServer := httptest.NewServer(handler)
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
	if server.closed {
		server.mu.Unlock()
		return nil, errors.New("test server is closed")
	}
	server.mu.Unlock()
	client, err := DialWebSocket(ctx, server.URL)
	if err != nil {
		return nil, err
	}
	client.onConnected = server.recordBinding
	server.mu.Lock()
	if server.closed {
		server.mu.Unlock()
		client.closeNow()
		return nil, errors.New("test server is closed")
	}
	server.clients = append(server.clients, client)
	server.mu.Unlock()
	return client, nil
}

func (server *Server) recordBinding(matchID, userID string) {
	server.mu.Lock()
	defer server.mu.Unlock()
	server.bindings = append(server.bindings, connectionBinding{matchID: matchID, userID: userID})
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
	server.closeOnce.Do(func() {
		server.closeErr = server.close(ctx)
	})
	return server.closeErr
}

func (server *Server) close(ctx context.Context) error {
	server.mu.Lock()
	server.closed = true
	clients := append([]*WebSocketClient(nil), server.clients...)
	bindings := append([]connectionBinding(nil), server.bindings...)
	server.mu.Unlock()

	server.httpServer.Close()
	server.workers()
	for _, client := range clients {
		client.closeNow()
	}
	if err := server.waitUntilDisconnected(ctx, bindings); err != nil {
		return err
	}
	select {
	case <-server.workerDone:
	case <-ctx.Done():
		return ctx.Err()
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
			return result
		}
	}
}

func (server *Server) waitUntilDisconnected(ctx context.Context, bindings []connectionBinding) error {
	if len(bindings) == 0 {
		return nil
	}
	ticker := time.NewTicker(testPresencePoll)
	defer ticker.Stop()
	for {
		allOffline := true
		for _, binding := range bindings {
			if server.Presence.IsOnline(binding.matchID, binding.userID) {
				allOffline = false
				break
			}
		}
		if allOffline {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}
