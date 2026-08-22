package room

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"sort"

	"me.zqydev/gamebox/server/internal/games/gameapi"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/lan/journal"
	"me.zqydev/gamebox/server/internal/nickname"
	"me.zqydev/gamebox/server/internal/protocol"
)

const (
	recordRoomCreated        = "room.created"
	recordPlayerJoined       = "player.joined"
	recordCredentialIssued   = "credential.issued"
	recordCredentialConsumed = "credential.consumed"
	recordGameEvent          = "game.event"
	recordRoomCancelled      = "room.cancelled"
	recordRoomFinished       = "room.finished"
	recordResultPersisted    = "result.persisted"

	roomKeyDigestDomain       = "gamebox/lan-room-key/v1"
	resumeDigestDomain        = "gamebox/lan-resume-token/v1"
	launchDigestDomain        = "gamebox/lan-launch-ticket/v1"
	pepperCheckDomain         = "gamebox/lan-token-pepper-check/v1"
	launchTicketLifetimeMS    = int64(60_000)
	credentialEntropyBytes    = 32
	minimumTokenPepperBytes   = 32
	maximumCredentialBytes    = 4096
	maximumActionPayloadBytes = 1024
)

var canonicalDigest = regexp.MustCompile(`^[0-9a-f]{64}$`)

type roomCreatedPayload struct {
	RoomID           string `json:"roomId"`
	GameID           string `json:"gameId"`
	CreatedAt        int64  `json:"createdAt"`
	JoinExpiresAt    int64  `json:"joinExpiresAt"`
	Host             Player `json:"host"`
	RoomKeyDigest    string `json:"roomKeyDigest"`
	PepperCheck      string `json:"pepperCheck"`
	HostResumeDigest string `json:"hostResumeDigest"`
}

type playerJoinedPayload struct {
	RoomID        string `json:"roomId"`
	Player        Player `json:"player"`
	JoinAttemptID string `json:"joinAttemptId"`
	ResumeDigest  string `json:"resumeDigest"`
	JoinedAt      int64  `json:"joinedAt"`
}

type credentialIssuedPayload struct {
	RoomID           string `json:"roomId"`
	PlayerID         string `json:"playerId"`
	CredentialDigest string `json:"credentialDigest"`
	IssuedAt         int64  `json:"issuedAt"`
	ExpiresAt        int64  `json:"expiresAt"`
}

type credentialConsumedPayload struct {
	RoomID           string `json:"roomId"`
	PlayerID         string `json:"playerId"`
	CredentialDigest string `json:"credentialDigest"`
	ConsumedAt       int64  `json:"consumedAt"`
}

type actionRecordPayload struct {
	RoomID            string          `json:"roomId"`
	Event             Event           `json:"event"`
	RequestType       string          `json:"requestType"`
	RequestPayload    json.RawMessage `json:"requestPayload"`
	ActionFingerprint string          `json:"actionFingerprint"`
	ExpectedRevision  int64           `json:"expectedRevision"`
	Reason            string          `json:"reason,omitempty"`
	WinnerPlayerID    *string         `json:"winnerPlayerId,omitempty"`
}

type cancelledRecordPayload struct {
	RoomID string `json:"roomId"`
	Event  Event  `json:"event"`
}

type resultPersistedPayload struct {
	RoomID      string `json:"roomId"`
	PlayerID    string `json:"playerId"`
	ResultHash  string `json:"resultHash"`
	PersistedAt int64  `json:"persistedAt"`
}

type issuedCredential struct {
	playerID  string
	issuedAt  int64
	expiresAt int64
	consumed  bool
}

type committedAction struct {
	event            Event
	requestType      string
	fingerprint      string
	expectedRevision int64
}

type projection struct {
	snapshot      Snapshot
	created       bool
	roomKeyDigest string
	pepperCheck   string
	joinAttemptID string
	resumeDigests map[string]string
	issued        map[string]issuedCredential
	activeTicket  map[string]string
	actions       map[string]committedAction
	acknowledged  map[string]bool
}

func newProjection() projection {
	return projection{
		snapshot:      Snapshot{GameID: gomoku.GameID, Status: StatusEmpty},
		resumeDigests: make(map[string]string), issued: make(map[string]issuedCredential),
		activeTicket: make(map[string]string), actions: make(map[string]committedAction), acknowledged: make(map[string]bool),
	}
}

func replayRecords(records []journal.Record, tokenPepper string) (projection, error) {
	state := newProjection()
	for _, record := range records {
		if err := state.applyRecord(record, tokenPepper); err != nil {
			return projection{}, fmt.Errorf("%w: sequence %d type %s", ErrRecoveryCorrupt, record.JournalSequence, record.Type)
		}
	}
	return state, nil
}

func (state *projection) applyRecord(record journal.Record, tokenPepper string) error {
	switch record.Type {
	case recordRoomCreated:
		return state.applyCreated(record, tokenPepper)
	case recordPlayerJoined:
		return state.applyJoined(record)
	case recordCredentialIssued:
		return state.applyCredentialIssued(record)
	case recordCredentialConsumed:
		return state.applyCredentialConsumed(record)
	case recordGameEvent:
		return state.applyAction(record, false)
	case recordRoomFinished:
		return state.applyAction(record, true)
	case recordRoomCancelled:
		return state.applyCancelled(record)
	case recordResultPersisted:
		return state.applyResultPersisted(record)
	default:
		return ErrRecoveryCorrupt
	}
}

func (state *projection) applyCreated(record journal.Record, tokenPepper string) error {
	if state.created || record.JournalSequence != 1 || record.GameRevision != nil || record.ActionID != nil {
		return ErrRecoveryCorrupt
	}
	var payload roomCreatedPayload
	if decodeStrict(record.Payload, &payload) != nil || !canonicalID(payload.RoomID) || payload.GameID != gomoku.GameID || payload.CreatedAt <= 0 ||
		payload.JoinExpiresAt <= payload.CreatedAt || !validPlayer(payload.Host, 0) || !canonicalDigest.MatchString(payload.RoomKeyDigest) ||
		!canonicalDigest.MatchString(payload.PepperCheck) || !canonicalDigest.MatchString(payload.HostResumeDigest) {
		return ErrRecoveryCorrupt
	}
	if len(tokenPepper) < minimumTokenPepperBytes || !digestEqual(payload.PepperCheck, credentialDigest(tokenPepper, pepperCheckDomain, payload.RoomID)) {
		return ErrRecoveryCorrupt
	}
	initial, err := gomoku.NewRules().Rebuild(nil)
	if err != nil {
		return ErrRecoveryCorrupt
	}
	state.created = true
	state.roomKeyDigest = payload.RoomKeyDigest
	state.pepperCheck = payload.PepperCheck
	state.resumeDigests[payload.Host.PlayerID] = payload.HostResumeDigest
	state.snapshot = Snapshot{RoomID: payload.RoomID, GameID: gomoku.GameID, Status: StatusWaiting, Players: []Player{payload.Host}, Game: initial, JoinExpiresAt: payload.JoinExpiresAt}
	return nil
}

func (state *projection) applyJoined(record journal.Record) error {
	if !state.created || state.snapshot.Status != StatusWaiting || len(state.snapshot.Players) != 1 || record.GameRevision != nil || record.ActionID != nil {
		return ErrRecoveryCorrupt
	}
	var payload playerJoinedPayload
	if decodeStrict(record.Payload, &payload) != nil || payload.RoomID != state.snapshot.RoomID || !validPlayer(payload.Player, 1) ||
		payload.Player.PlayerID == state.snapshot.Players[0].PlayerID || payload.Player.Color == state.snapshot.Players[0].Color ||
		!canonicalID(payload.JoinAttemptID) || !canonicalDigest.MatchString(payload.ResumeDigest) || payload.JoinedAt <= 0 {
		return ErrRecoveryCorrupt
	}
	for _, existingDigest := range state.resumeDigests {
		if digestEqual(existingDigest, payload.ResumeDigest) {
			return ErrRecoveryCorrupt
		}
	}
	var blackID, whiteID string
	for _, player := range []Player{state.snapshot.Players[0], payload.Player} {
		if player.Color == ColorBlack {
			blackID = player.PlayerID
		} else if player.Color == ColorWhite {
			whiteID = player.PlayerID
		} else {
			return ErrRecoveryCorrupt
		}
	}
	game, err := gomoku.NewSnapshot(blackID, whiteID)
	if err != nil {
		return ErrRecoveryCorrupt
	}
	state.joinAttemptID = payload.JoinAttemptID
	state.resumeDigests[payload.Player.PlayerID] = payload.ResumeDigest
	state.snapshot.Players = append(state.snapshot.Players, payload.Player)
	state.snapshot.Game = game
	state.snapshot.Status = StatusActive
	return nil
}

func (state *projection) applyCredentialIssued(record journal.Record) error {
	if !state.created || state.snapshot.Status == StatusCancelled || record.GameRevision != nil || record.ActionID != nil {
		return ErrRecoveryCorrupt
	}
	var payload credentialIssuedPayload
	if decodeStrict(record.Payload, &payload) != nil || payload.RoomID != state.snapshot.RoomID || !state.hasPlayer(payload.PlayerID) ||
		!canonicalDigest.MatchString(payload.CredentialDigest) || payload.IssuedAt <= 0 || payload.ExpiresAt <= payload.IssuedAt {
		return ErrRecoveryCorrupt
	}
	if _, exists := state.issued[payload.CredentialDigest]; exists {
		return ErrRecoveryCorrupt
	}
	state.issued[payload.CredentialDigest] = issuedCredential{playerID: payload.PlayerID, issuedAt: payload.IssuedAt, expiresAt: payload.ExpiresAt}
	state.activeTicket[payload.PlayerID] = payload.CredentialDigest
	return nil
}

func (state *projection) applyCredentialConsumed(record journal.Record) error {
	if !state.created || state.snapshot.Status == StatusCancelled || record.GameRevision != nil || record.ActionID != nil {
		return ErrRecoveryCorrupt
	}
	var payload credentialConsumedPayload
	if decodeStrict(record.Payload, &payload) != nil || payload.RoomID != state.snapshot.RoomID || !canonicalDigest.MatchString(payload.CredentialDigest) {
		return ErrRecoveryCorrupt
	}
	issued, ok := state.issued[payload.CredentialDigest]
	if !ok || issued.consumed || issued.playerID != payload.PlayerID || state.activeTicket[payload.PlayerID] != payload.CredentialDigest ||
		payload.ConsumedAt < issued.issuedAt || payload.ConsumedAt > issued.expiresAt {
		return ErrRecoveryCorrupt
	}
	issued.consumed = true
	state.issued[payload.CredentialDigest] = issued
	delete(state.activeTicket, payload.PlayerID)
	return nil
}

func (state *projection) applyAction(record journal.Record, terminal bool) error {
	if !state.created || state.snapshot.Status != StatusActive || len(state.snapshot.Players) != 2 || record.ActionID == nil || !canonicalID(*record.ActionID) ||
		terminal && record.GameRevision != nil || !terminal && (record.GameRevision == nil || *record.GameRevision != state.snapshot.Revision+1) {
		return errors.New("invalid action record envelope")
	}
	if _, exists := state.actions[*record.ActionID]; exists {
		return errors.New("duplicate action id")
	}
	var payload actionRecordPayload
	if decodeStrict(record.Payload, &payload) != nil || payload.RoomID != state.snapshot.RoomID || payload.Event.RoomID != state.snapshot.RoomID ||
		payload.Event.ActionID != *record.ActionID || payload.Event.Revision != state.snapshot.Revision+1 || payload.Event.CommittedAt <= 0 ||
		payload.ExpectedRevision != state.snapshot.Revision || !state.hasPlayer(payload.Event.ActorPlayerID) || !canonicalDigest.MatchString(payload.ActionFingerprint) {
		return errors.New("invalid action record payload")
	}
	canonicalPayload, fingerprint, err := validatedAction(payload.Event.ActorPlayerID, *record.ActionID, payload.ExpectedRevision, payload.RequestType, payload.RequestPayload)
	if err != nil || fingerprint != payload.ActionFingerprint || !bytes.Equal(canonicalPayload, payload.RequestPayload) {
		return errors.New("action fingerprint mismatch")
	}

	var nextGame gameapi.Snapshot
	if payload.RequestType == gomoku.MoveRequested {
		produced, producedSnapshot, applyErr := gomoku.NewRules().Apply(state.snapshot.Game, payload.Event.ActorPlayerID, gameapi.Action{Type: payload.RequestType, Payload: payload.RequestPayload})
		if applyErr != nil || !eventMatchesGame(payload.Event, produced) {
			return errors.New("gomoku apply mismatch")
		}
		nextGame = producedSnapshot
		summary, summaryErr := decodeGameSummary(nextGame)
		if summaryErr != nil {
			return errors.New("gomoku summary invalid")
		}
		if terminal {
			if summary.Status != StatusFinished || payload.Reason != summary.Result || !sameStringPointer(payload.WinnerPlayerID, summary.WinnerPlayerID) {
				return errors.New("terminal gomoku result mismatch")
			}
		} else if summary.Status != StatusActive || payload.Reason != "" || payload.WinnerPlayerID != nil {
			return errors.New("nonterminal gomoku result mismatch")
		}
	} else if payload.RequestType == protocol.TypeGomokuResignRequested {
		if !terminal || state.snapshot.Revision == 0 || payload.Event.Type != protocol.TypeGomokuResigned || payload.Reason != ResultResignation {
			return errors.New("invalid resignation envelope")
		}
		winner := state.opponent(payload.Event.ActorPlayerID)
		wantPayload, _ := json.Marshal(resignedPayload{PlayerID: payload.Event.ActorPlayerID, WinnerPlayerID: winner.PlayerID})
		if winner.PlayerID == "" || payload.WinnerPlayerID == nil || *payload.WinnerPlayerID != winner.PlayerID || !bytes.Equal(payload.Event.Payload, wantPayload) {
			return errors.New("invalid resignation result")
		}
		nextGame = cloneGameSnapshot(state.snapshot.Game)
	} else {
		return errors.New("unsupported action type")
	}

	state.snapshot.Revision = payload.Event.Revision
	state.snapshot.Game = nextGame
	state.actions[*record.ActionID] = committedAction{event: cloneEvent(payload.Event), requestType: payload.RequestType, fingerprint: payload.ActionFingerprint, expectedRevision: payload.ExpectedRevision}
	if terminal {
		state.snapshot.Status = StatusFinished
		state.snapshot.Result = &GameResult{ResultHash: record.Hash, WinnerPlayerID: cloneStringPointer(payload.WinnerPlayerID), Reason: payload.Reason, Revision: payload.Event.Revision}
	}
	return nil
}

func (state *projection) applyCancelled(record journal.Record) error {
	if !state.created || (state.snapshot.Status != StatusWaiting && state.snapshot.Status != StatusActive) || state.snapshot.Revision != 0 ||
		record.ActionID != nil || record.GameRevision != nil {
		return ErrRecoveryCorrupt
	}
	var payload cancelledRecordPayload
	if decodeStrict(record.Payload, &payload) != nil || payload.RoomID != state.snapshot.RoomID || payload.Event.RoomID != state.snapshot.RoomID ||
		payload.Event.Revision != 1 || payload.Event.Type != protocol.TypePlatformMatchCancelled || payload.Event.ActionID != "" ||
		len(state.snapshot.Players) == 0 || payload.Event.ActorPlayerID != state.snapshot.Players[0].PlayerID || string(payload.Event.Payload) != "{}" || payload.Event.CommittedAt <= 0 {
		return ErrRecoveryCorrupt
	}
	state.snapshot.Revision = 1
	state.snapshot.Status = StatusCancelled
	return nil
}

func (state *projection) applyResultPersisted(record journal.Record) error {
	if !state.created || state.snapshot.Status != StatusFinished || state.snapshot.Result == nil || record.GameRevision != nil || record.ActionID != nil {
		return ErrRecoveryCorrupt
	}
	var payload resultPersistedPayload
	if decodeStrict(record.Payload, &payload) != nil || payload.RoomID != state.snapshot.RoomID || !state.hasPlayer(payload.PlayerID) ||
		payload.ResultHash != state.snapshot.Result.ResultHash || payload.PersistedAt <= 0 || state.acknowledged[payload.PlayerID] {
		return ErrRecoveryCorrupt
	}
	state.acknowledged[payload.PlayerID] = true
	state.refreshAcknowledgedPlayers()
	return nil
}

func (state *projection) refreshAcknowledgedPlayers() {
	ids := make([]string, 0, len(state.acknowledged))
	for playerID := range state.acknowledged {
		ids = append(ids, playerID)
	}
	sort.Strings(ids)
	state.snapshot.ResultAcknowledgedPlayerIDs = ids
}

func (state *projection) hasPlayer(playerID string) bool {
	for _, player := range state.snapshot.Players {
		if player.PlayerID == playerID {
			return true
		}
	}
	return false
}

func (state *projection) opponent(playerID string) Player {
	for _, player := range state.snapshot.Players {
		if player.PlayerID != playerID {
			return player
		}
	}
	return Player{}
}

func validPlayer(player Player, seat int) bool {
	display, _, err := nickname.Normalize(player.Nickname)
	return err == nil && display == player.Nickname && canonicalID(player.PlayerID) && player.Seat == seat && (player.Color == ColorBlack || player.Color == ColorWhite)
}

func credentialDigest(pepper, domain, plaintext string) string {
	mac := hmac.New(sha256.New, []byte(pepper))
	_, _ = io.WriteString(mac, domain)
	_, _ = mac.Write([]byte{0})
	_, _ = io.WriteString(mac, plaintext)
	return hex.EncodeToString(mac.Sum(nil))
}

func digestEqual(left, right string) bool {
	if len(left) != len(right) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(left), []byte(right)) == 1
}

func actionFingerprint(playerID, actionType string, canonicalPayload json.RawMessage) string {
	digest := sha256.New()
	_, _ = io.WriteString(digest, playerID)
	_, _ = digest.Write([]byte{0})
	_, _ = io.WriteString(digest, actionType)
	_, _ = digest.Write([]byte{0})
	_, _ = digest.Write(canonicalPayload)
	return hex.EncodeToString(digest.Sum(nil))
}

func decodeStrict(raw json.RawMessage, destination any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return ErrRecoveryCorrupt
	}
	return nil
}

type gameSummary struct {
	Status         string  `json:"status"`
	WinnerPlayerID *string `json:"winnerUserId"`
	Result         string  `json:"result"`
}

func decodeGameSummary(snapshot gameapi.Snapshot) (gameSummary, error) {
	var raw struct {
		Status         string  `json:"status"`
		WinnerPlayerID *string `json:"winnerUserId"`
		Result         *string `json:"result"`
	}
	if json.Unmarshal(snapshot.State, &raw) != nil || (raw.Status != StatusActive && raw.Status != StatusFinished) {
		return gameSummary{}, ErrRecoveryCorrupt
	}
	result := ""
	if raw.Result != nil {
		result = *raw.Result
	}
	return gameSummary{Status: raw.Status, WinnerPlayerID: cloneStringPointer(raw.WinnerPlayerID), Result: result}, nil
}

func eventMatchesGame(event Event, produced gameapi.Event) bool {
	canonicalProduced, err := canonicalJSON(produced.Payload)
	return err == nil && event.Revision == produced.Revision && event.Type == produced.Type && event.ActorPlayerID == produced.ActorID && bytes.Equal(event.Payload, canonicalProduced)
}

func canonicalJSON(raw json.RawMessage) (json.RawMessage, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, err
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, ErrInvalidRequest
	}
	encoded, err := json.Marshal(value)
	return json.RawMessage(encoded), err
}

func sameStringPointer(left, right *string) bool {
	return left == nil && right == nil || left != nil && right != nil && *left == *right
}
