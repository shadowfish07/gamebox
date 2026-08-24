package room

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"math"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"

	"me.zqydev/gamebox/server/internal/games/gameapi"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/lan/journal"
	"me.zqydev/gamebox/server/internal/nickname"
	"me.zqydev/gamebox/server/internal/protocol"
)

// Service owns the journal Store for its lifetime. Close must be called before
// another process or service can reopen the room root.
type Service struct {
	mu               sync.RWMutex
	store            *journal.Store
	state            projection
	clock            func() time.Time
	colorRandom      io.Reader
	playerRandom     io.Reader
	credentialRandom io.Reader
	tokenPepper      string
	closed           bool
	closeStore       func(*journal.Store) error
}

func (service *Service) String() string {
	if service == nil {
		return "room.Service<nil>"
	}
	service.mu.RLock()
	defer service.mu.RUnlock()
	return "room.Service{journal:<store> entropy:<readers> tokenPepper:<redacted>}"
}

func (service *Service) GoString() string { return service.String() }

// Open acquires the journal lifetime lock and strictly replays every committed
// record. Existing rooms require the original token pepper so credentials stay
// verifiable without ever persisting that pepper.
func Open(config Config) (*Service, error) {
	if strings.TrimSpace(config.Root) == "" {
		return nil, ErrInvalidConfiguration
	}
	if config.Clock == nil {
		config.Clock = time.Now
	}
	if config.ColorRandom == nil {
		config.ColorRandom = rand.Reader
	}
	if config.PlayerRandom == nil {
		config.PlayerRandom = rand.Reader
	}
	if config.CredentialRandom == nil {
		config.CredentialRandom = rand.Reader
	}
	store, records, err := journal.Open(config.Root, config.FileOps)
	if err != nil {
		if errors.Is(err, journal.ErrJournalCorrupt) {
			return nil, errors.Join(ErrRecoveryCorrupt, err)
		}
		return nil, err
	}
	state, replayErr := replayRecords(records, config.TokenPepper)
	if replayErr != nil {
		_ = store.Close()
		return nil, replayErr
	}
	return &Service{store: store, state: state, clock: config.Clock, colorRandom: config.ColorRandom, playerRandom: config.PlayerRandom, credentialRandom: config.CredentialRandom, tokenPepper: config.TokenPepper, closeStore: func(store *journal.Store) error { return store.Close() }}, nil
}

// Close releases the journal lifetime lock. It is idempotent.
func (service *Service) Close() error {
	if service == nil {
		return nil
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	if service.closed {
		return nil
	}
	closeStore := service.closeStore
	if closeStore == nil {
		closeStore = func(store *journal.Store) error { return store.Close() }
	}
	if err := closeStore(service.store); err != nil {
		return err
	}
	service.closed = true
	return nil
}

func (service *Service) Create(ctx context.Context, request CreateRequest) (CreatedRoom, error) {
	if service == nil || service.store == nil {
		return CreatedRoom{}, ErrInvalidConfiguration
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	if err := service.commandContext(ctx); err != nil {
		return CreatedRoom{}, err
	}
	if service.state.created {
		return CreatedRoom{}, ErrRoomExists
	}
	now, err := service.nowMillis()
	if err != nil || !canonicalID(request.RoomID) || !canonicalID(request.HostPlayerID) || request.RoomID == request.HostPlayerID ||
		len(request.TokenPepper) < minimumTokenPepperBytes || !validCredential(request.RoomKey) || !validCredential(request.HostResumeToken) || request.JoinExpiresAt <= now {
		return CreatedRoom{}, ErrInvalidRequest
	}
	display, _, err := nickname.Normalize(request.HostNickname)
	if err != nil {
		return CreatedRoom{}, ErrInvalidRequest
	}
	if service.tokenPepper != "" && !secretEqual(service.tokenPepper, request.TokenPepper) {
		return CreatedRoom{}, ErrInvalidConfiguration
	}
	color, err := service.randomHostColor()
	if err != nil {
		return CreatedRoom{}, ErrInternal
	}
	payload := roomCreatedPayload{
		RoomID: request.RoomID, GameID: gomoku.GameID, CreatedAt: now, JoinExpiresAt: request.JoinExpiresAt,
		Host:             Player{PlayerID: request.HostPlayerID, Nickname: display, Seat: 0, Color: color},
		RoomKeyDigest:    credentialDigest(request.TokenPepper, roomKeyDigestDomain, request.RoomKey),
		PepperCheck:      credentialDigest(request.TokenPepper, pepperCheckDomain, request.RoomID),
		HostResumeDigest: credentialDigest(request.TokenPepper, resumeDigestDomain, request.HostResumeToken),
	}
	draft, err := makeDraft(recordRoomCreated, nil, nil, payload)
	if err != nil {
		return CreatedRoom{}, ErrInternal
	}
	previousPepper := service.tokenPepper
	service.tokenPepper = request.TokenPepper
	record, err := service.store.Append(ctx, draft)
	if err != nil {
		service.tokenPepper = previousPepper
		return CreatedRoom{}, err
	}
	if err := service.advanceCommitted(record); err != nil {
		return CreatedRoom{}, err
	}
	return CreatedRoom{Snapshot: cloneSnapshot(service.state.snapshot)}, nil
}

func (service *Service) Join(ctx context.Context, request JoinRequest) (JoinedPlayer, error) {
	if service == nil || service.store == nil {
		return JoinedPlayer{}, ErrInvalidConfiguration
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	if err := service.commandContext(ctx); err != nil {
		return JoinedPlayer{}, err
	}
	if !service.state.created {
		return JoinedPlayer{}, ErrRoomNotFound
	}
	if !canonicalID(request.RoomID) || request.RoomID != service.state.snapshot.RoomID || !canonicalID(request.JoinAttemptID) || !validCredential(request.CandidateResumeToken) || !validCredential(request.RoomKey) {
		return JoinedPlayer{}, ErrInvalidRequest
	}
	if !digestEqual(service.state.roomKeyDigest, credentialDigest(service.tokenPepper, roomKeyDigestDomain, request.RoomKey)) {
		return JoinedPlayer{}, ErrRoomKeyInvalid
	}
	candidateDigest := credentialDigest(service.tokenPepper, resumeDigestDomain, request.CandidateResumeToken)
	if len(service.state.snapshot.Players) == 2 {
		guest := service.state.snapshot.Players[1]
		if request.JoinAttemptID != service.state.joinAttemptID || !digestEqual(service.state.resumeDigests[guest.PlayerID], candidateDigest) {
			return JoinedPlayer{}, ErrRoomLocked
		}
		ticket, err := service.issueLaunchLocked(ctx, guest.PlayerID, candidateDigest)
		if err != nil {
			return JoinedPlayer{}, err
		}
		return JoinedPlayer{Player: guest, LaunchTicket: ticket}, nil
	}
	if _, found, collision := lookupResumeDigest(service.state.resumeDigests, candidateDigest); found || collision {
		return JoinedPlayer{}, ErrInvalidRequest
	}
	if service.state.snapshot.Status != StatusWaiting {
		return JoinedPlayer{}, ErrRoomLocked
	}
	now, err := service.nowMillis()
	if err != nil {
		return JoinedPlayer{}, ErrInternal
	}
	if !validJoinTimestamp(service.state.createdAt, now, service.state.snapshot.JoinExpiresAt) {
		return JoinedPlayer{}, ErrJoinExpired
	}
	display, _, err := nickname.Normalize(request.Nickname)
	if err != nil {
		return JoinedPlayer{}, ErrInvalidRequest
	}
	playerID, err := service.randomPlayerID()
	if err != nil {
		return JoinedPlayer{}, ErrInternal
	}
	host := service.state.snapshot.Players[0]
	color := ColorBlack
	if host.Color == ColorBlack {
		color = ColorWhite
	}
	player := Player{PlayerID: playerID, Nickname: display, Seat: 1, Color: color}
	payload := playerJoinedPayload{RoomID: request.RoomID, Player: player, JoinAttemptID: request.JoinAttemptID, ResumeDigest: candidateDigest, JoinedAt: now}
	draft, err := makeDraft(recordPlayerJoined, nil, nil, payload)
	if err != nil {
		return JoinedPlayer{}, ErrInternal
	}
	record, err := service.store.Append(ctx, draft)
	if err != nil {
		return JoinedPlayer{}, err
	}
	if err := service.advanceCommitted(record); err != nil {
		return JoinedPlayer{}, err
	}
	ticket, err := service.issueLaunchLocked(ctx, player.PlayerID, candidateDigest)
	if err != nil {
		return JoinedPlayer{}, err
	}
	return JoinedPlayer{Player: player, LaunchTicket: ticket}, nil
}

func (service *Service) IssueLaunch(ctx context.Context, playerID, resumeToken string) (LaunchTicket, error) {
	if service == nil || service.store == nil {
		return LaunchTicket{}, ErrInvalidConfiguration
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	if err := service.commandContext(ctx); err != nil {
		return LaunchTicket{}, err
	}
	if !canonicalID(playerID) || !validCredential(resumeToken) {
		return LaunchTicket{}, ErrInvalidRequest
	}
	digest := credentialDigest(service.tokenPepper, resumeDigestDomain, resumeToken)
	matchedPlayerID, found, collision := lookupResumeDigest(service.state.resumeDigests, digest)
	if !found || collision || matchedPlayerID != playerID {
		return LaunchTicket{}, ErrResumeInvalid
	}
	return service.issueLaunchLocked(ctx, playerID, digest)
}

func (service *Service) issueLaunchLocked(ctx context.Context, playerID, validatedResumeDigest string) (LaunchTicket, error) {
	if service.state.snapshot.Status == StatusEmpty || service.state.snapshot.Status == StatusCancelled {
		return LaunchTicket{}, ErrInvalidRequest
	}
	if !digestEqual(service.state.resumeDigests[playerID], validatedResumeDigest) {
		return LaunchTicket{}, ErrResumeInvalid
	}
	now, err := service.nowMillis()
	expiresAt, validLifetime := launchTicketExpiry(now)
	if err != nil || !validLifetime {
		return LaunchTicket{}, ErrInternal
	}
	for attempt := 0; attempt < 8; attempt++ {
		plaintextBytes := make([]byte, credentialEntropyBytes)
		if _, err := io.ReadFull(service.credentialRandom, plaintextBytes); err != nil {
			return LaunchTicket{}, ErrInternal
		}
		plaintext := base64.RawURLEncoding.EncodeToString(plaintextBytes)
		digest := credentialDigest(service.tokenPepper, launchDigestDomain, plaintext)
		if _, _, exists := findIssuedCredential(service.state.issued, digest); exists {
			continue
		}
		payload := credentialIssuedPayload{RoomID: service.state.snapshot.RoomID, PlayerID: playerID, CredentialDigest: digest, IssuedAt: now, ExpiresAt: expiresAt}
		draft, err := makeDraft(recordCredentialIssued, nil, nil, payload)
		if err != nil {
			return LaunchTicket{}, ErrInternal
		}
		record, err := service.store.Append(ctx, draft)
		if err != nil {
			return LaunchTicket{}, err
		}
		if err := service.advanceCommitted(record); err != nil {
			return LaunchTicket{}, err
		}
		return LaunchTicket{PlayerID: playerID, Token: plaintext, ExpiresAt: expiresAt}, nil
	}
	return LaunchTicket{}, ErrInternal
}

func (service *Service) Connect(ctx context.Context, credential ConnectCredential) (ConnectionCredential, error) {
	if service == nil || service.store == nil {
		return ConnectionCredential{}, ErrInvalidConfiguration
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	if err := service.commandContext(ctx); err != nil {
		return ConnectionCredential{}, err
	}
	launch := credential.LaunchTicket != ""
	resume := credential.ResumeToken != ""
	if launch == resume {
		return ConnectionCredential{}, ErrInvalidRequest
	}
	if launch {
		if service.state.snapshot.Status == StatusCancelled {
			return ConnectionCredential{}, ErrTicketInvalid
		}
		if !validCredential(credential.LaunchTicket) {
			return ConnectionCredential{}, ErrTicketInvalid
		}
		digest := credentialDigest(service.tokenPepper, launchDigestDomain, credential.LaunchTicket)
		storedDigest, issued, ok := findIssuedCredential(service.state.issued, digest)
		now, err := service.nowMillis()
		if err != nil {
			return ConnectionCredential{}, ErrInternal
		}
		if !ok || issued.consumed || !activeDigestMatches(service.state.activeTicket, issued.playerID, digest) || now > issued.expiresAt {
			return ConnectionCredential{}, ErrTicketInvalid
		}
		payload := credentialConsumedPayload{RoomID: service.state.snapshot.RoomID, PlayerID: issued.playerID, CredentialDigest: storedDigest, ConsumedAt: now}
		draft, err := makeDraft(recordCredentialConsumed, nil, nil, payload)
		if err != nil {
			return ConnectionCredential{}, ErrInternal
		}
		record, err := service.store.Append(ctx, draft)
		if err != nil {
			return ConnectionCredential{}, err
		}
		if err := service.advanceCommitted(record); err != nil {
			return ConnectionCredential{}, err
		}
		return ConnectionCredential{RoomID: service.state.snapshot.RoomID, PlayerID: issued.playerID}, nil
	}
	if !validCredential(credential.ResumeToken) {
		return ConnectionCredential{}, ErrResumeInvalid
	}
	if service.state.snapshot.Status == StatusCancelled {
		return ConnectionCredential{}, ErrResumeInvalid
	}
	digest := credentialDigest(service.tokenPepper, resumeDigestDomain, credential.ResumeToken)
	playerID, found, collision := lookupResumeDigest(service.state.resumeDigests, digest)
	if found && !collision {
		return ConnectionCredential{RoomID: service.state.snapshot.RoomID, PlayerID: playerID}, nil
	}
	return ConnectionCredential{}, ErrResumeInvalid
}

// ConnectLAN authenticates a LAN WebSocket's first message. An initial
// connection proves the launch ticket and durable resume token together before
// the one-time ticket is consumed; a reconnect presents only the resume token.
func (service *Service) ConnectLAN(ctx context.Context, credential ConnectCredential) (ConnectionCredential, error) {
	if service == nil || service.store == nil {
		return ConnectionCredential{}, ErrInvalidConfiguration
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	if err := service.commandContext(ctx); err != nil {
		return ConnectionCredential{}, err
	}
	launch := credential.LaunchTicket != ""
	resume := credential.ResumeToken != ""
	if !resume || !validCredential(credential.ResumeToken) {
		return ConnectionCredential{}, ErrResumeInvalid
	}
	resumeDigest := credentialDigest(service.tokenPepper, resumeDigestDomain, credential.ResumeToken)
	resumePlayerID, found, collision := lookupResumeDigest(service.state.resumeDigests, resumeDigest)
	if !found || collision || service.state.snapshot.Status == StatusCancelled {
		return ConnectionCredential{}, ErrResumeInvalid
	}
	if !launch {
		return ConnectionCredential{RoomID: service.state.snapshot.RoomID, PlayerID: resumePlayerID}, nil
	}
	if !validCredential(credential.LaunchTicket) {
		return ConnectionCredential{}, ErrTicketInvalid
	}
	launchDigest := credentialDigest(service.tokenPepper, launchDigestDomain, credential.LaunchTicket)
	storedDigest, issued, ok := findIssuedCredential(service.state.issued, launchDigest)
	now, err := service.nowMillis()
	if err != nil {
		return ConnectionCredential{}, ErrInternal
	}
	if !ok || issued.consumed || !activeDigestMatches(service.state.activeTicket, issued.playerID, launchDigest) || now > issued.expiresAt {
		return ConnectionCredential{}, ErrTicketInvalid
	}
	if issued.playerID != resumePlayerID {
		return ConnectionCredential{}, ErrResumeInvalid
	}
	payload := credentialConsumedPayload{RoomID: service.state.snapshot.RoomID, PlayerID: issued.playerID, CredentialDigest: storedDigest, ConsumedAt: now}
	draft, err := makeDraft(recordCredentialConsumed, nil, nil, payload)
	if err != nil {
		return ConnectionCredential{}, ErrInternal
	}
	record, err := service.store.Append(ctx, draft)
	if err != nil {
		return ConnectionCredential{}, err
	}
	if err := service.advanceCommitted(record); err != nil {
		return ConnectionCredential{}, err
	}
	return ConnectionCredential{RoomID: service.state.snapshot.RoomID, PlayerID: issued.playerID}, nil
}

func (service *Service) Apply(ctx context.Context, request ActionRequest) (Event, Snapshot, *GameResult, error) {
	if service == nil || service.store == nil {
		return Event{}, Snapshot{}, nil, ErrInvalidConfiguration
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	if err := service.commandContext(ctx); err != nil {
		return Event{}, Snapshot{}, nil, err
	}
	canonicalPayload, fingerprint, err := validatedAction(request.PlayerID, request.ActionID, request.ExpectedRevision, request.Type, request.Payload)
	if err != nil {
		return Event{}, Snapshot{}, nil, ErrInvalidRequest
	}
	if committed, exists := service.state.actions[request.ActionID]; exists {
		if committed.requestType != request.Type || committed.fingerprint != fingerprint || committed.expectedRevision != request.ExpectedRevision || committed.event.ActorPlayerID != request.PlayerID {
			return Event{}, Snapshot{}, nil, ErrActionConflict
		}
		return cloneEvent(committed.event), cloneSnapshot(service.state.snapshot), cloneResult(service.state.snapshot.Result), nil
	}
	if service.state.snapshot.Status != StatusActive || len(service.state.snapshot.Players) != 2 || !service.state.hasPlayer(request.PlayerID) {
		return Event{}, Snapshot{}, nil, ErrInvalidRequest
	}
	if request.ExpectedRevision != service.state.snapshot.Revision {
		return Event{}, Snapshot{}, nil, ErrStaleRevision
	}
	now, err := service.nowMillis()
	if err != nil || service.state.snapshot.Revision == math.MaxInt64 {
		return Event{}, Snapshot{}, nil, ErrInternal
	}
	nextRevision := service.state.snapshot.Revision + 1
	var event Event
	var reason string
	var winner *string
	terminal := false
	if request.Type == gomoku.MoveRequested {
		produced, nextGame, applyErr := gomoku.NewRules().Apply(service.state.snapshot.Game, request.PlayerID, gameapi.Action{Type: request.Type, Payload: canonicalPayload})
		if applyErr != nil {
			return Event{}, Snapshot{}, nil, safeRuleError(applyErr)
		}
		if produced.Revision != nextRevision {
			return Event{}, Snapshot{}, nil, ErrInternal
		}
		canonicalEventPayload, canonicalErr := canonicalJSON(produced.Payload)
		if canonicalErr != nil {
			return Event{}, Snapshot{}, nil, ErrInternal
		}
		event = Event{RoomID: service.state.snapshot.RoomID, Revision: nextRevision, Type: produced.Type, ActionID: request.ActionID, ActorPlayerID: request.PlayerID, Payload: canonicalEventPayload, CommittedAt: now}
		summary, summaryErr := decodeGameSummary(nextGame)
		if summaryErr != nil {
			return Event{}, Snapshot{}, nil, ErrInternal
		}
		if summary.Status == StatusFinished {
			terminal, reason, winner = true, summary.Result, summary.WinnerPlayerID
			if (reason != ResultFive && reason != ResultDraw) || reason == ResultFive && winner == nil || reason == ResultDraw && winner != nil {
				return Event{}, Snapshot{}, nil, ErrInternal
			}
		}
	} else {
		if service.state.snapshot.Revision == 0 {
			return Event{}, Snapshot{}, nil, ErrInvalidRequest
		}
		opponent := service.state.opponent(request.PlayerID)
		if opponent.PlayerID == "" {
			return Event{}, Snapshot{}, nil, ErrInternal
		}
		winnerID := opponent.PlayerID
		winner = &winnerID
		reason, terminal = ResultResignation, true
		payload, marshalErr := json.Marshal(resignedPayload{PlayerID: request.PlayerID, WinnerPlayerID: winnerID})
		if marshalErr != nil {
			return Event{}, Snapshot{}, nil, ErrInternal
		}
		event = Event{RoomID: service.state.snapshot.RoomID, Revision: nextRevision, Type: protocol.TypeGomokuResigned, ActionID: request.ActionID, ActorPlayerID: request.PlayerID, Payload: payload, CommittedAt: now}
	}
	recordPayload := actionRecordPayload{RoomID: service.state.snapshot.RoomID, Event: event, RequestType: request.Type, RequestPayload: canonicalPayload, ActionFingerprint: fingerprint, ExpectedRevision: request.ExpectedRevision, Reason: reason, WinnerPlayerID: cloneStringPointer(winner)}
	recordType := recordGameEvent
	if terminal {
		recordType = recordRoomFinished
	}
	var journalRevision *int64
	if !terminal {
		journalRevision = &nextRevision
	}
	draft, err := makeDraft(recordType, journalRevision, &request.ActionID, recordPayload)
	if err != nil {
		return Event{}, Snapshot{}, nil, ErrInternal
	}
	record, err := service.store.Append(ctx, draft)
	if err != nil {
		return Event{}, Snapshot{}, nil, err
	}
	if err := service.advanceCommitted(record); err != nil {
		return Event{}, Snapshot{}, nil, err
	}
	return cloneEvent(event), cloneSnapshot(service.state.snapshot), cloneResult(service.state.snapshot.Result), nil
}

func (service *Service) Cancel(ctx context.Context, playerID string) (Event, error) {
	if service == nil || service.store == nil {
		return Event{}, ErrInvalidConfiguration
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	if err := service.commandContext(ctx); err != nil {
		return Event{}, err
	}
	if !canonicalID(playerID) || !service.state.created || len(service.state.snapshot.Players) == 0 || playerID != service.state.snapshot.Players[0].PlayerID ||
		service.state.snapshot.Revision != 0 || (service.state.snapshot.Status != StatusWaiting && service.state.snapshot.Status != StatusActive) {
		return Event{}, ErrRoomNotCancellable
	}
	now, err := service.nowMillis()
	if err != nil {
		return Event{}, ErrInternal
	}
	revision := int64(1)
	event := Event{RoomID: service.state.snapshot.RoomID, Revision: revision, Type: protocol.TypePlatformMatchCancelled, ActorPlayerID: playerID, Payload: json.RawMessage(`{}`), CommittedAt: now}
	draft, err := makeDraft(recordRoomCancelled, nil, nil, cancelledRecordPayload{RoomID: service.state.snapshot.RoomID, Event: event})
	if err != nil {
		return Event{}, ErrInternal
	}
	record, err := service.store.Append(ctx, draft)
	if err != nil {
		return Event{}, err
	}
	if err := service.advanceCommitted(record); err != nil {
		return Event{}, err
	}
	return cloneEvent(event), nil
}

func (service *Service) AcknowledgeResult(ctx context.Context, playerID, resultHash string) error {
	if service == nil || service.store == nil {
		return ErrInvalidConfiguration
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	if err := service.commandContext(ctx); err != nil {
		return err
	}
	if !canonicalID(playerID) || !service.state.hasPlayer(playerID) {
		return ErrInvalidRequest
	}
	if service.state.snapshot.Status != StatusFinished || service.state.snapshot.Result == nil {
		return ErrResultNotReady
	}
	if !digestEqual(resultHash, service.state.snapshot.Result.ResultHash) {
		return ErrResultHashMismatch
	}
	if service.state.acknowledged[playerID] {
		return nil
	}
	now, err := service.nowMillis()
	if err != nil {
		return ErrInternal
	}
	payload := resultPersistedPayload{RoomID: service.state.snapshot.RoomID, PlayerID: playerID, ResultHash: resultHash, PersistedAt: now}
	draft, err := makeDraft(recordResultPersisted, nil, nil, payload)
	if err != nil {
		return ErrInternal
	}
	record, err := service.store.Append(ctx, draft)
	if err != nil {
		return err
	}
	return service.advanceCommitted(record)
}

func (service *Service) Snapshot() Snapshot {
	if service == nil {
		return Snapshot{}
	}
	service.mu.RLock()
	defer service.mu.RUnlock()
	return cloneSnapshot(service.state.snapshot)
}

// WriteManifestProjection updates only the non-authoritative endpoint locator.
// Authoritative room state continues to come exclusively from journal replay.
func (service *Service) WriteManifestProjection(endpoint string) error {
	if service == nil || service.store == nil || strings.TrimSpace(endpoint) == "" {
		return ErrInvalidConfiguration
	}
	service.mu.RLock()
	defer service.mu.RUnlock()
	if service.closed || !service.state.created {
		return ErrInvalidRequest
	}
	return service.store.WriteManifestProjection(service.state.snapshot.RoomID, service.state.snapshot.GameID, endpoint, 1)
}

func (service *Service) advanceCommitted(record journal.Record) error {
	if err := service.state.applyRecord(record, service.tokenPepper); err != nil {
		_ = service.store.Close()
		service.closed = true
		return errors.Join(journal.ErrReopenRequired, err)
	}
	return nil
}

func (service *Service) commandContext(ctx context.Context) error {
	if service.closed {
		return journal.ErrJournalClosed
	}
	if ctx == nil {
		return ErrInvalidRequest
	}
	return ctx.Err()
}

func (service *Service) nowMillis() (int64, error) {
	now := service.clock().UTC().UnixMilli()
	if now <= 0 {
		return 0, ErrInternal
	}
	return now, nil
}

func (service *Service) randomHostColor() (Color, error) {
	var value [1]byte
	if _, err := io.ReadFull(service.colorRandom, value[:]); err != nil {
		return "", err
	}
	if value[0]&1 == 0 {
		return ColorBlack, nil
	}
	return ColorWhite, nil
}

func (service *Service) randomPlayerID() (string, error) {
	for attempt := 0; attempt < 8; attempt++ {
		identifier, err := uuid.NewRandomFromReader(service.playerRandom)
		if err != nil {
			return "", err
		}
		value := identifier.String()
		if !service.state.hasPlayer(value) && value != service.state.snapshot.RoomID {
			return value, nil
		}
	}
	return "", ErrInternal
}

func makeDraft(recordType string, revision *int64, actionID *string, payload any) (journal.Draft, error) {
	encoded, err := json.Marshal(payload)
	if err != nil {
		return journal.Draft{}, err
	}
	return journal.Draft{Type: recordType, GameRevision: cloneInt64Pointer(revision), ActionID: cloneStringPointer(actionID), Payload: encoded}, nil
}

func validatedAction(playerID, actionID string, expectedRevision int64, actionType string, payload json.RawMessage) (json.RawMessage, string, error) {
	if !canonicalID(playerID) || !canonicalID(actionID) || expectedRevision < 0 || len(payload) == 0 || len(payload) > maximumActionPayloadBytes || !utf8.Valid(payload) {
		return nil, "", ErrInvalidRequest
	}
	var canonical json.RawMessage
	switch actionType {
	case gomoku.MoveRequested:
		fields, err := strictObjectRaw(payload, map[string]bool{"x": true, "y": true})
		if err != nil || len(fields) != 2 {
			return nil, "", ErrInvalidRequest
		}
		x, xErr := canonicalJSONInteger(fields["x"])
		y, yErr := canonicalJSONInteger(fields["y"])
		if xErr != nil || yErr != nil || x < 0 || x >= gomoku.BoardSize || y < 0 || y >= gomoku.BoardSize {
			return nil, "", ErrInvalidRequest
		}
		canonical, _ = json.Marshal(struct {
			X int `json:"x"`
			Y int `json:"y"`
		}{X: x, Y: y})
	case protocol.TypeGomokuResignRequested:
		fields, err := strictObjectRaw(payload, map[string]bool{})
		if err != nil || len(fields) != 0 {
			return nil, "", ErrInvalidRequest
		}
		canonical = json.RawMessage(`{}`)
	default:
		return nil, "", ErrInvalidRequest
	}
	return canonical, actionFingerprint(playerID, actionType, canonical), nil
}

func strictObjectRaw(payload json.RawMessage, allowed map[string]bool) (map[string]json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(payload))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, ErrInvalidRequest
	}
	fields := make(map[string]json.RawMessage, len(allowed))
	for decoder.More() {
		keyToken, err := decoder.Token()
		key, ok := keyToken.(string)
		if err != nil || !ok || !allowed[key] {
			return nil, ErrInvalidRequest
		}
		if _, duplicate := fields[key]; duplicate {
			return nil, ErrInvalidRequest
		}
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			return nil, ErrInvalidRequest
		}
		fields[key] = raw
	}
	if token, err = decoder.Token(); err != nil || token != json.Delim('}') {
		return nil, ErrInvalidRequest
	}
	if _, err = decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, ErrInvalidRequest
	}
	return fields, nil
}

func canonicalJSONInteger(raw json.RawMessage) (int, error) {
	var value int
	if len(raw) == 0 || json.Unmarshal(raw, &value) != nil || string(raw) != strconv.Itoa(value) {
		return 0, ErrInvalidRequest
	}
	return value, nil
}

func canonicalID(value string) bool {
	parsed, err := uuid.Parse(value)
	return err == nil && parsed.String() == value && parsed.Variant() == uuid.RFC4122
}

func validCredential(value string) bool {
	return value != "" && len(value) <= maximumCredentialBytes && utf8.ValidString(value)
}

func safeRuleError(err error) error {
	switch {
	case errors.Is(err, gomoku.ErrNotYourTurn):
		return gomoku.ErrNotYourTurn
	case errors.Is(err, gomoku.ErrCellOccupied):
		return gomoku.ErrCellOccupied
	case errors.Is(err, gameapi.ErrInvalidAction):
		return ErrInvalidRequest
	default:
		return ErrInternal
	}
}

type resignedPayload struct {
	PlayerID       string `json:"userId"`
	WinnerPlayerID string `json:"winnerUserId"`
}

func cloneSnapshot(snapshot Snapshot) Snapshot {
	clone := snapshot
	clone.Players = append([]Player(nil), snapshot.Players...)
	clone.Game = cloneGameSnapshot(snapshot.Game)
	clone.Result = cloneResult(snapshot.Result)
	clone.ResultAcknowledgedPlayerIDs = append([]string(nil), snapshot.ResultAcknowledgedPlayerIDs...)
	return clone
}

func cloneGameSnapshot(snapshot gameapi.Snapshot) gameapi.Snapshot {
	return gameapi.Snapshot{Revision: snapshot.Revision, State: append(json.RawMessage(nil), snapshot.State...)}
}

func cloneEvent(event Event) Event {
	clone := event
	clone.Payload = append(json.RawMessage(nil), event.Payload...)
	return clone
}

func cloneResult(result *GameResult) *GameResult {
	if result == nil {
		return nil
	}
	clone := *result
	clone.WinnerPlayerID = cloneStringPointer(result.WinnerPlayerID)
	return &clone
}

func cloneStringPointer(value *string) *string {
	if value == nil {
		return nil
	}
	clone := *value
	return &clone
}

func cloneInt64Pointer(value *int64) *int64 {
	if value == nil {
		return nil
	}
	clone := *value
	return &clone
}
