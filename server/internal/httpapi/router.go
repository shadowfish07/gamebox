// Package httpapi exposes Gamebox identity and lobby operations over HTTP.
package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"reflect"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"

	"me.zqydev/gamebox/server/internal/auth"
	"me.zqydev/gamebox/server/internal/games"
	"me.zqydev/gamebox/server/internal/matches"
	"me.zqydev/gamebox/server/internal/users"
)

const maximumHTTPJSONBodyBytes int64 = 64 * 1024
const maximumHTTPJSONDepth = 32

type requestIDGenerator func() (string, error)

// RouterConfig keeps the composition root explicit and testable. RequestIDs
// must return a fresh opaque identifier and must not derive it from request
// credentials or bodies.
type RouterConfig struct {
	Auth       *auth.Service
	Matches    *matches.Service
	Games      *games.Registry
	Publisher  MatchEventPublisher
	Logger     *log.Logger
	RequestIDs requestIDGenerator
}

type router struct {
	auth      *auth.Service
	matches   *matches.Service
	games     *games.Registry
	publisher MatchEventPublisher
}

func NewRouter(config RouterConfig) (http.Handler, error) {
	if config.Auth == nil || config.Matches == nil || config.Games == nil || nilInterface(config.Publisher) || config.Logger == nil || config.RequestIDs == nil {
		return nil, ErrInvalidConfiguration
	}
	router := &router{auth: config.Auth, matches: config.Matches, games: config.Games, publisher: config.Publisher}
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", router.health)
	mux.HandleFunc("POST /v1/auth/register", router.register)
	mux.HandleFunc("POST /v1/auth/refresh", router.refresh)
	mux.Handle("GET /v1/me", router.authenticated(http.HandlerFunc(router.me)))
	mux.Handle("GET /v1/games", router.authenticated(http.HandlerFunc(router.listGames)))
	mux.Handle("GET /v1/games/gomoku/status", router.authenticated(http.HandlerFunc(router.gomokuStatus)))
	mux.Handle("GET /v1/games/gomoku/opponents", router.authenticated(http.HandlerFunc(router.gomokuOpponents)))
	mux.Handle("POST /v1/games/gomoku/matches", router.authenticated(http.HandlerFunc(router.createGomokuMatch)))
	mux.Handle("DELETE /v1/matches/{matchId}", router.authenticated(http.HandlerFunc(router.cancelMatch)))
	mux.Handle("POST /v1/matches/{matchId}/launch-ticket", router.authenticated(http.HandlerFunc(router.createLaunchTicket)))

	registerMethodFallback(mux, "/healthz", http.MethodGet)
	registerMethodFallback(mux, "/v1/auth/register", http.MethodPost)
	registerMethodFallback(mux, "/v1/auth/refresh", http.MethodPost)
	registerMethodFallback(mux, "/v1/me", http.MethodGet)
	registerMethodFallback(mux, "/v1/games", http.MethodGet)
	registerMethodFallback(mux, "/v1/games/gomoku/status", http.MethodGet)
	registerMethodFallback(mux, "/v1/games/gomoku/opponents", http.MethodGet)
	registerMethodFallback(mux, "/v1/games/gomoku/matches", http.MethodPost)
	registerMethodFallback(mux, "/v1/matches/{matchId}", http.MethodDelete)
	registerMethodFallback(mux, "/v1/matches/{matchId}/launch-ticket", http.MethodPost)
	mux.HandleFunc("/", func(writer http.ResponseWriter, _ *http.Request) {
		writeAPIError(writer, http.StatusNotFound, "invalid_request")
	})

	return requestMiddleware(config.Logger, config.RequestIDs)(mux), nil
}

// NewProductionRequestID returns a cryptographically random UUIDv4 suitable
// for RouterConfig.RequestIDs.
func NewProductionRequestID() (string, error) {
	id, err := uuid.NewRandom()
	if err != nil {
		return "", ErrInvalidConfiguration
	}
	return id.String(), nil
}

func nilInterface(value any) bool {
	if value == nil {
		return true
	}
	reflected := reflect.ValueOf(value)
	switch reflected.Kind() {
	case reflect.Chan, reflect.Func, reflect.Interface, reflect.Map, reflect.Pointer, reflect.Slice:
		return reflected.IsNil()
	default:
		return false
	}
}

func registerMethodFallback(mux *http.ServeMux, pattern, allowed string) {
	mux.HandleFunc(pattern, func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("Allow", allowed)
		writeAPIError(writer, http.StatusMethodNotAllowed, "invalid_request")
	})
}

type responseCapture struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (capture *responseCapture) WriteHeader(status int) {
	if capture.wroteHeader {
		return
	}
	capture.status = status
	capture.wroteHeader = true
	capture.ResponseWriter.WriteHeader(status)
}

func (capture *responseCapture) Write(data []byte) (int, error) {
	if !capture.wroteHeader {
		capture.WriteHeader(http.StatusOK)
	}
	return capture.ResponseWriter.Write(data)
}

// Unwrap lets net/http.ResponseController recover optional capabilities from
// the underlying writer when the WebSocket route is added in the next task.
func (capture *responseCapture) Unwrap() http.ResponseWriter { return capture.ResponseWriter }

func requestMiddleware(logger *log.Logger, requestIDs requestIDGenerator) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
			requestID, idErr := requestIDs()
			if idErr != nil || !canonicalRequestID(requestID) {
				writeAPIError(writer, http.StatusInternalServerError, "internal_error")
				logger.Printf("request_id=unavailable method=%s path=unmatched status=500 panic=false", request.Method)
				return
			}
			writer.Header().Set("X-Request-ID", requestID)
			capture := &responseCapture{ResponseWriter: writer, status: http.StatusOK}
			request.Body = http.MaxBytesReader(capture, request.Body, maximumHTTPJSONBodyBytes)
			panicked := false
			defer func() {
				if recover() != nil {
					panicked = true
					if !capture.wroteHeader {
						writeAPIError(capture, http.StatusInternalServerError, "internal_error")
					}
				}
				logger.Printf("request_id=%s method=%s path=%s status=%d panic=%t", requestID, request.Method, safeRequestPattern(request.Pattern), capture.status, panicked)
			}()
			next.ServeHTTP(capture, request)
		})
	}
}

func safeRequestPattern(pattern string) string {
	if pattern == "" {
		return "unmatched"
	}
	if _, path, found := strings.Cut(pattern, " "); found {
		return path
	}
	return pattern
}

func canonicalRequestID(value string) bool {
	parsed, err := uuid.Parse(value)
	return err == nil && parsed.String() == value && parsed.Variant() == uuid.RFC4122
}

type authenticatedUserContextKey struct{}

func (router *router) authenticated(next http.Handler) http.Handler {
	return http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		values := request.Header.Values("Authorization")
		if len(values) != 1 {
			writeAPIError(writer, http.StatusUnauthorized, "unauthorized")
			return
		}
		scheme, credential, found := strings.Cut(values[0], " ")
		if !found || !strings.EqualFold(scheme, "Bearer") || credential == "" || strings.ContainsAny(credential, " \t\r\n") {
			writeAPIError(writer, http.StatusUnauthorized, "unauthorized")
			return
		}
		user, authErr := router.auth.Authenticate(request.Context(), credential)
		if authErr != nil {
			writeServiceError(writer, authErr)
			return
		}
		contextWithUser := context.WithValue(request.Context(), authenticatedUserContextKey{}, user)
		next.ServeHTTP(writer, request.WithContext(contextWithUser))
	})
}

func authenticatedUser(request *http.Request) (users.User, bool) {
	user, ok := request.Context().Value(authenticatedUserContextKey{}).(users.User)
	return user, ok && user.ID != "" && user.Nickname != ""
}

func decodeJSONBody(request *http.Request, destination any, exactFields ...string) (int, error) {
	mediaType, parameters, mediaErr := mime.ParseMediaType(request.Header.Get("Content-Type"))
	charset, hasCharset := parameters["charset"]
	if mediaErr != nil || mediaType != "application/json" || len(parameters) > 1 || len(parameters) == 1 && !hasCharset || hasCharset && !strings.EqualFold(charset, "utf-8") {
		return http.StatusUnsupportedMediaType, errors.New("unsupported media type")
	}
	if request.ContentLength > maximumHTTPJSONBodyBytes {
		return http.StatusRequestEntityTooLarge, errors.New("body too large")
	}
	data, readErr := io.ReadAll(request.Body)
	if readErr != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(readErr, &tooLarge) {
			return http.StatusRequestEntityTooLarge, errors.New("body too large")
		}
		return http.StatusBadRequest, errors.New("invalid body")
	}
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || trimmed[0] != '{' || !utf8.Valid(trimmed) {
		return http.StatusBadRequest, errors.New("body must be an object")
	}
	if duplicateErr := rejectDuplicateJSONKeys(trimmed); duplicateErr != nil {
		return http.StatusBadRequest, duplicateErr
	}
	if fieldsErr := requireExactTopLevelFields(trimmed, exactFields); fieldsErr != nil {
		return http.StatusBadRequest, fieldsErr
	}
	decoder := json.NewDecoder(bytes.NewReader(trimmed))
	decoder.DisallowUnknownFields()
	if decodeErr := decoder.Decode(destination); decodeErr != nil {
		return http.StatusBadRequest, errors.New("invalid json")
	}
	if trailingErr := requireJSONEnd(decoder); trailingErr != nil {
		return http.StatusBadRequest, trailingErr
	}
	return 0, nil
}

// requireExactTopLevelFields closes encoding/json's deliberate
// case-insensitive struct matching. Request DTO keys are protocol fields, so a
// differently-cased or Unicode-fold-equivalent spelling is unknown rather
// than an alias that can override the canonical key. Keys are compared after
// JSON escape decoding; rejectDuplicateJSONKeys has already established that
// each decoded spelling is unique.
func requireExactTopLevelFields(data []byte, expected []string) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(data, &fields); err != nil || fields == nil || len(fields) != len(expected) {
		return errors.New("invalid json fields")
	}
	allowed := make(map[string]struct{}, len(expected))
	for _, field := range expected {
		if field == "" {
			return errors.New("invalid json field policy")
		}
		if _, duplicate := allowed[field]; duplicate {
			return errors.New("invalid json field policy")
		}
		allowed[field] = struct{}{}
	}
	for field := range fields {
		if _, ok := allowed[field]; !ok {
			return errors.New("unknown json field")
		}
	}
	return nil
}

func requireJSONEnd(decoder *json.Decoder) error {
	var trailing any
	err := decoder.Decode(&trailing)
	if errors.Is(err, io.EOF) {
		return nil
	}
	return errors.New("trailing json")
}

func rejectDuplicateJSONKeys(data []byte) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	first, err := decoder.Token()
	if err != nil {
		return errors.New("invalid json")
	}
	if err := walkJSONToken(decoder, first, 1); err != nil {
		return err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return errors.New("trailing json")
	}
	return nil
}

func walkJSONToken(decoder *json.Decoder, token json.Token, depth int) error {
	delimiter, composite := token.(json.Delim)
	if !composite {
		return nil
	}
	if depth > maximumHTTPJSONDepth {
		return errors.New("json too deep")
	}
	switch delimiter {
	case '{':
		seen := make(map[string]struct{})
		for decoder.More() {
			keyToken, err := decoder.Token()
			if err != nil {
				return errors.New("invalid json")
			}
			key, ok := keyToken.(string)
			if !ok {
				return errors.New("invalid json")
			}
			if _, duplicate := seen[key]; duplicate {
				return errors.New("duplicate json field")
			}
			seen[key] = struct{}{}
			value, err := decoder.Token()
			if err != nil {
				return errors.New("invalid json")
			}
			if err := walkJSONToken(decoder, value, depth+1); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil || closing != json.Delim('}') {
			return errors.New("invalid json")
		}
	case '[':
		for decoder.More() {
			value, err := decoder.Token()
			if err != nil {
				return errors.New("invalid json")
			}
			if err := walkJSONToken(decoder, value, depth+1); err != nil {
				return err
			}
		}
		closing, err := decoder.Token()
		if err != nil || closing != json.Delim(']') {
			return errors.New("invalid json")
		}
	default:
		return fmt.Errorf("invalid json delimiter")
	}
	return nil
}
