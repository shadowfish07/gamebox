// Package httpapi exposes Gamebox identity and lobby operations over HTTP.
package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime"
	"net/http"
	"net/url"
	"reflect"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"

	"me.zqydev/gamebox/server/internal/auth"
	"me.zqydev/gamebox/server/internal/diagnostics"
	"me.zqydev/gamebox/server/internal/games"
	"me.zqydev/gamebox/server/internal/matches"
	"me.zqydev/gamebox/server/internal/users"
)

const maximumHTTPJSONBodyBytes int64 = 64 * 1024
const maximumHTTPJSONDepth = 32
const maximumWebSocketHeaderBytes = 8 * 1024
const maximumWebSocketHeaderFields = 32

type requestIDGenerator func() (string, error)

// RouterConfig keeps the composition root explicit and testable. RequestIDs
// must return a fresh opaque identifier and must not derive it from request
// credentials or bodies.
type RouterConfig struct {
	Auth       *auth.Service
	Matches    *matches.Service
	Games      *games.Registry
	Publisher  MatchEventPublisher
	Hub        *matches.Hub
	Logger     *log.Logger
	RequestIDs requestIDGenerator
}

type router struct {
	auth      *auth.Service
	matches   *matches.Service
	games     *games.Registry
	publisher MatchEventPublisher
	hub       *matches.Hub
	logger    *log.Logger
}

func NewRouter(config RouterConfig) (http.Handler, error) {
	if config.Auth == nil || config.Matches == nil || config.Games == nil || nilInterface(config.Publisher) || config.Hub == nil || config.Logger == nil || config.RequestIDs == nil {
		return nil, ErrInvalidConfiguration
	}
	router := &router{
		auth: config.Auth, matches: config.Matches, games: config.Games,
		publisher: config.Publisher, hub: config.Hub, logger: config.Logger,
	}
	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", router.health)
	mux.HandleFunc("POST /v1/auth/register", router.register)
	mux.HandleFunc("POST /v1/auth/refresh", router.refresh)
	mux.Handle("GET /v1/me", router.authenticated(http.HandlerFunc(router.me)))
	mux.Handle("GET /v1/games", router.authenticated(http.HandlerFunc(router.listGames)))
	mux.Handle("GET /v1/games/chinese_checkers/status", router.authenticated(http.HandlerFunc(router.chineseCheckersStatus)))
	mux.Handle("GET /v1/games/chinese_checkers/opponents", router.authenticated(http.HandlerFunc(router.chineseCheckersOpponents)))
	mux.Handle("GET /v1/games/chinese_checkers/history", router.authenticated(http.HandlerFunc(router.chineseCheckersHistory)))
	mux.Handle("POST /v1/games/chinese_checkers/matches", router.authenticated(http.HandlerFunc(router.createChineseCheckersMatch)))
	mux.Handle("GET /v1/games/gomoku/status", router.authenticated(http.HandlerFunc(router.gomokuStatus)))
	mux.Handle("GET /v1/games/gomoku/opponents", router.authenticated(http.HandlerFunc(router.gomokuOpponents)))
	mux.Handle("GET /v1/games/gomoku/history", router.authenticated(http.HandlerFunc(router.gomokuHistory)))
	mux.Handle("POST /v1/games/gomoku/matches", router.authenticated(http.HandlerFunc(router.createGomokuMatch)))
	mux.Handle("GET /v1/games/rps/status", router.authenticated(http.HandlerFunc(router.rpsStatus)))
	mux.Handle("GET /v1/games/rps/opponents", router.authenticated(http.HandlerFunc(router.rpsOpponents)))
	mux.Handle("GET /v1/games/rps/history", router.authenticated(http.HandlerFunc(router.rpsHistory)))
	mux.Handle("POST /v1/games/rps/matches", router.authenticated(http.HandlerFunc(router.createRpsMatch)))
	mux.Handle("DELETE /v1/matches/{matchId}", router.authenticated(http.HandlerFunc(router.cancelMatch)))
	mux.Handle("POST /v1/matches/{matchId}/launch-ticket", router.authenticated(http.HandlerFunc(router.createLaunchTicket)))
	mux.HandleFunc("GET /v1/ws", router.webSocket)

	registerMethodFallback(mux, "/healthz", http.MethodGet)
	registerMethodFallback(mux, "/v1/auth/register", http.MethodPost)
	registerMethodFallback(mux, "/v1/auth/refresh", http.MethodPost)
	registerMethodFallback(mux, "/v1/me", http.MethodGet)
	registerMethodFallback(mux, "/v1/games", http.MethodGet)
	registerMethodFallback(mux, "/v1/games/chinese_checkers/status", http.MethodGet)
	registerMethodFallback(mux, "/v1/games/chinese_checkers/opponents", http.MethodGet)
	registerMethodFallback(mux, "/v1/games/chinese_checkers/history", http.MethodGet)
	registerMethodFallback(mux, "/v1/games/chinese_checkers/matches", http.MethodPost)
	registerMethodFallback(mux, "/v1/games/gomoku/status", http.MethodGet)
	registerMethodFallback(mux, "/v1/games/gomoku/opponents", http.MethodGet)
	registerMethodFallback(mux, "/v1/games/gomoku/history", http.MethodGet)
	registerMethodFallback(mux, "/v1/games/gomoku/matches", http.MethodPost)
	registerMethodFallback(mux, "/v1/games/rps/status", http.MethodGet)
	registerMethodFallback(mux, "/v1/games/rps/opponents", http.MethodGet)
	registerMethodFallback(mux, "/v1/games/rps/history", http.MethodGet)
	registerMethodFallback(mux, "/v1/games/rps/matches", http.MethodPost)
	registerMethodFallback(mux, "/v1/matches/{matchId}", http.MethodDelete)
	registerMethodFallback(mux, "/v1/matches/{matchId}/launch-ticket", http.MethodPost)
	registerMethodFallback(mux, "/v1/ws", http.MethodGet)
	mux.HandleFunc("/", func(writer http.ResponseWriter, _ *http.Request) {
		writeAPIError(writer, http.StatusNotFound, "invalid_request")
	})

	return requestMiddleware(config.Logger, config.RequestIDs)(mux), nil
}

func (router *router) webSocket(writer http.ResponseWriter, request *http.Request) {
	// Credentials are accepted only in the first WebSocket data message. This
	// rejects accidental query/header transport before any upgrade or logging.
	if request.URL.RawQuery != "" || len(request.Header.Values("Authorization")) != 0 {
		writeAPIError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	if !validWebSocketUpgrade(request) {
		writeAPIError(writer, http.StatusBadRequest, "invalid_request")
		return
	}
	if !webSocketOriginAllowed(request) {
		writeAPIError(writer, http.StatusForbidden, "invalid_request")
		return
	}
	router.hub.ServeHTTP(writer, request)
}

func validWebSocketUpgrade(request *http.Request) bool {
	if request == nil || !request.ProtoAtLeast(1, 1) || len(request.Header) > maximumWebSocketHeaderFields || len(request.Host) > 1024 {
		return false
	}
	headerBytes := len(request.Host)
	for name, values := range request.Header {
		headerBytes += len(name)
		for _, value := range values {
			headerBytes += len(value)
			if headerBytes > maximumWebSocketHeaderBytes {
				return false
			}
		}
	}
	if !headerContainsToken(request.Header.Values("Connection"), "upgrade") || !headerContainsToken(request.Header.Values("Upgrade"), "websocket") {
		return false
	}
	versions := request.Header.Values("Sec-WebSocket-Version")
	keys := request.Header.Values("Sec-WebSocket-Key")
	if len(versions) != 1 || versions[0] != "13" || len(keys) != 1 {
		return false
	}
	key := strings.TrimSpace(keys[0])
	decoded, err := base64.StdEncoding.DecodeString(key)
	return err == nil && len(decoded) == 16 && base64.StdEncoding.EncodeToString(decoded) == key
}

func headerContainsToken(values []string, want string) bool {
	for _, value := range values {
		for token := range strings.SplitSeq(value, ",") {
			if strings.EqualFold(strings.TrimSpace(token), want) {
				return true
			}
		}
	}
	return false
}

func webSocketOriginAllowed(request *http.Request) bool {
	values := request.Header.Values("Origin")
	if len(values) == 0 {
		return true
	}
	if len(values) != 1 {
		return false
	}
	origin, err := url.Parse(values[0])
	if err != nil || (origin.Scheme != "http" && origin.Scheme != "https") || origin.Host == "" ||
		origin.User != nil || origin.Path != "" || origin.RawQuery != "" || origin.Fragment != "" {
		return false
	}
	return strings.EqualFold(origin.Host, request.Host)
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
		writer.Header().Set("Allow", allowedMethodsHeader(allowed))
		writeAPIError(writer, http.StatusMethodNotAllowed, "invalid_request")
	})
}

func allowedMethodsHeader(allowed string) string {
	if allowed == http.MethodGet {
		return "GET, HEAD"
	}
	return allowed
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
				logger.Printf("request_id=unavailable method=%s path=unmatched status=500 panic=false", safeRequestMethod(request.Method))
				return
			}
			writer.Header().Set("X-Request-ID", requestID)
			request = request.WithContext(context.WithValue(request.Context(), requestIDContextKey{}, requestID))
			startedAt := time.Now()
			// MaxBytesReader must receive the server's original writer so its
			// private requestTooLarge signal can close an oversized HTTP/1.x
			// connection. responseCapture deliberately stays outside this call.
			request.Body = http.MaxBytesReader(writer, request.Body, maximumHTTPJSONBodyBytes)
			capture := &responseCapture{ResponseWriter: writer, status: http.StatusOK}
			panicked := false
			defer func() {
				if recover() != nil {
					panicked = true
					if !capture.wroteHeader {
						writeAPIError(capture, http.StatusInternalServerError, "internal_error")
					}
				}
				logger.Printf("request_id=%s method=%s path=%s status=%d panic=%t duration_ms=%d", requestID, safeRequestMethod(request.Method), safeRequestPattern(request.Pattern), capture.status, panicked, time.Since(startedAt).Milliseconds())
			}()
			if !requestAcceptsJSONBody(request) {
				if requestDeclaresBody(request) {
					writer.Header().Set("Connection", "close")
					writeAPIError(capture, http.StatusBadRequest, "invalid_request")
					return
				}
			}
			if request.ContentLength > maximumHTTPJSONBodyBytes {
				writer.Header().Set("Connection", "close")
				writeAPIError(capture, http.StatusRequestEntityTooLarge, "invalid_request")
				return
			}
			next.ServeHTTP(capture, request)
		})
	}
}

func safeRequestMethod(method string) string {
	switch method {
	case http.MethodGet, http.MethodHead, http.MethodPost, http.MethodDelete, http.MethodOptions:
		return method
	default:
		return "OTHER"
	}
}

func requestAcceptsJSONBody(request *http.Request) bool {
	if request.Method != http.MethodPost {
		return false
	}
	switch request.URL.Path {
	case "/v1/auth/register", "/v1/auth/refresh", "/v1/games/chinese_checkers/matches", "/v1/games/gomoku/matches", "/v1/games/rps/matches":
		return true
	}
	const launchPrefix = "/v1/matches/"
	const launchSuffix = "/launch-ticket"
	if !strings.HasPrefix(request.URL.Path, launchPrefix) || !strings.HasSuffix(request.URL.Path, launchSuffix) {
		return false
	}
	matchID := strings.TrimSuffix(strings.TrimPrefix(request.URL.Path, launchPrefix), launchSuffix)
	return canonicalRequestID(matchID)
}

func requestDeclaresBody(request *http.Request) bool {
	return len(request.TransferEncoding) != 0 || request.ContentLength != 0
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

type requestIDContextKey struct{}

func requestIDFromContext(ctx context.Context) string {
	if ctx == nil {
		return ""
	}
	requestID, ok := ctx.Value(requestIDContextKey{}).(string)
	if !ok || !canonicalRequestID(requestID) {
		return ""
	}
	return requestID
}

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
			router.logServiceError(request, "authenticate", authErr)
			writeServiceError(writer, authErr)
			return
		}
		contextWithUser := context.WithValue(request.Context(), authenticatedUserContextKey{}, user)
		next.ServeHTTP(writer, request.WithContext(contextWithUser))
	})
}

func requestIDFrom(request *http.Request) string {
	if request == nil {
		return "unavailable"
	}
	requestID, _ := request.Context().Value(requestIDContextKey{}).(string)
	if !canonicalRequestID(requestID) {
		return "unavailable"
	}
	return requestID
}

func (router *router) logServiceError(request *http.Request, phase string, err error) {
	if router == nil || router.logger == nil || phase == "" || err == nil {
		return
	}
	detail := diagnostics.Cause(err).Error()
	router.logger.Printf("event=service_error request_id=%s phase=%s category=%s error_b64=%s", requestIDFrom(request), phase, safeServiceErrorCategory(err), base64.RawURLEncoding.EncodeToString([]byte(detail)))
}

func safeServiceErrorCategory(err error) string {
	switch {
	case errors.Is(err, context.Canceled):
		return "context_canceled"
	case errors.Is(err, context.DeadlineExceeded):
		return "context_deadline"
	case errors.Is(err, auth.ErrUnauthorized):
		return "unauthorized"
	case errors.Is(err, auth.ErrInvalidRequest), errors.Is(err, matches.ErrInvalidRequest):
		return "invalid_request"
	case errors.Is(err, matches.ErrInternal), errors.Is(err, auth.ErrInternal):
		return "internal"
	default:
		return "unknown"
	}
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
	if len(trimmed) == 0 || trimmed[0] != '{' || !utf8.Valid(trimmed) || !validHTTPJSONSurrogateEscapes(trimmed) {
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

// validHTTPJSONSurrogateEscapes prevents encoding/json from replacing an
// isolated UTF-16 surrogate with U+FFFD. It inspects every JSON string,
// including object keys; valid pairs and a literal escaped "\\uD800" remain
// lossless and are accepted.
func validHTTPJSONSurrogateEscapes(document []byte) bool {
	inString := false
	for index := 0; index < len(document); index++ {
		character := document[index]
		if !inString {
			if character == '"' {
				inString = true
			}
			continue
		}
		switch character {
		case '"':
			inString = false
		case '\\':
			if index+1 >= len(document) {
				return false
			}
			if document[index+1] != 'u' {
				index++
				continue
			}
			codeUnit, ok := decodeHTTPJSONHexCodeUnit(document, index+2)
			if !ok {
				return false
			}
			index += 5
			switch {
			case codeUnit >= 0xd800 && codeUnit <= 0xdbff:
				nextEscape := index + 1
				if nextEscape+5 >= len(document) || document[nextEscape] != '\\' || document[nextEscape+1] != 'u' {
					return false
				}
				low, lowOK := decodeHTTPJSONHexCodeUnit(document, nextEscape+2)
				if !lowOK || low < 0xdc00 || low > 0xdfff {
					return false
				}
				index = nextEscape + 5
			case codeUnit >= 0xdc00 && codeUnit <= 0xdfff:
				return false
			}
		}
	}
	return !inString
}

func decodeHTTPJSONHexCodeUnit(document []byte, start int) (uint16, bool) {
	if start+4 > len(document) {
		return 0, false
	}
	var value uint16
	for _, digit := range document[start : start+4] {
		value <<= 4
		switch {
		case digit >= '0' && digit <= '9':
			value |= uint16(digit - '0')
		case digit >= 'a' && digit <= 'f':
			value |= uint16(digit-'a') + 10
		case digit >= 'A' && digit <= 'F':
			value |= uint16(digit-'A') + 10
		default:
			return 0, false
		}
	}
	return value, true
}

func literalCanonicalPathUUID(request *http.Request, parameter string) (string, bool) {
	value := request.PathValue(parameter)
	parsed, err := uuid.Parse(value)
	if err != nil || parsed.String() != value || parsed.Variant() != uuid.RFC4122 || strings.Contains(request.URL.EscapedPath(), "%") {
		return "", false
	}
	return value, true
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
