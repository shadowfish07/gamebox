package matches

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/games"
	"me.zqydev/gamebox/server/internal/games/gameapi"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/protocol"
	"me.zqydev/gamebox/server/internal/store"
)

const (
	initiatorID = "11111111-1111-4111-8111-111111111111"
	opponentID  = "22222222-2222-4222-8222-222222222222"
	thirdID     = "33333333-3333-4333-8333-333333333333"
)

type fixture struct {
	db       *sql.DB
	registry *games.Registry
	clock    *clock.Fake
	now      time.Time
}

func newFixture(t *testing.T) fixture {
	t.Helper()
	db, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "gamebox.sqlite"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	t.Cleanup(func() {
		if err := db.Close(); err != nil {
			t.Errorf("close store: %v", err)
		}
	})
	now := time.Date(2026, time.August, 19, 9, 10, 11, 987654321, time.FixedZone("fixture", 8*60*60))
	result := fixture{db: db, registry: games.NewRegistry(), clock: clock.NewFake(now), now: now}
	result.addUser(t, initiatorID, "Initiator", true)
	result.addUser(t, opponentID, "Opponent", true)
	result.addUser(t, thirdID, "Third", true)
	return result
}

func (fixture fixture) addUser(t *testing.T, id, nickname string, enabled bool) {
	t.Helper()
	enabledInteger := 0
	if enabled {
		enabledInteger = 1
	}
	_, err := fixture.db.Exec(`
INSERT INTO users(id,nickname,normalized_nickname,enabled,created_at,updated_at)
VALUES (?,?,?,?,?,?)`, id, nickname, strings.ToLower(nickname), enabledInteger, fixture.now.Add(-time.Hour).Unix(), fixture.now.Add(-time.Hour).Unix())
	if err != nil {
		t.Fatalf("insert user: %v", err)
	}
}

func (fixture fixture) service(t *testing.T, random io.Reader) *Service {
	t.Helper()
	service, err := NewService(fixture.db, fixture.registry, fixture.clock, random)
	if err != nil {
		t.Fatalf("NewService: %v", err)
	}
	return service
}

func TestCreateRejectsInvalidParticipantsAndGamesWithoutWrites(t *testing.T) {
	tests := []struct {
		name      string
		gameID    string
		initiator string
		opponent  string
		disableID string
		want      error
	}{
		{name: "self", gameID: gomoku.GameID, initiator: initiatorID, opponent: initiatorID, want: ErrInvalidRequest},
		{name: "unknown initiator", gameID: gomoku.GameID, initiator: "44444444-4444-4444-8444-444444444444", opponent: opponentID, want: ErrInvalidRequest},
		{name: "unknown opponent", gameID: gomoku.GameID, initiator: initiatorID, opponent: "44444444-4444-4444-8444-444444444444", want: ErrInvalidRequest},
		{name: "disabled initiator", gameID: gomoku.GameID, initiator: initiatorID, opponent: opponentID, disableID: initiatorID, want: ErrInvalidRequest},
		{name: "disabled opponent", gameID: gomoku.GameID, initiator: initiatorID, opponent: opponentID, disableID: opponentID, want: ErrInvalidRequest},
		{name: "unknown game", gameID: "missing", initiator: initiatorID, opponent: opponentID, want: ErrInvalidRequest},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newFixture(t)
			if test.disableID != "" {
				if _, err := fixture.db.Exec(`UPDATE users SET enabled=0 WHERE id=?`, test.disableID); err != nil {
					t.Fatalf("disable user: %v", err)
				}
			}
			match, err := fixture.service(t, bytes.NewReader([]byte{0})).Create(context.Background(), test.gameID, test.initiator, test.opponent)
			if !errors.Is(err, test.want) || match.ID != "" {
				t.Fatalf("Create = (%+v, %v), want zero match and %v", match, err, test.want)
			}
			if err.Error() != test.want.Error() {
				t.Fatalf("Create exposed input or SQL detail: %q", err)
			}
			assertTableCount(t, fixture.db, "matches", 0)
			assertTableCount(t, fixture.db, "match_players", 0)
			assertTableCount(t, fixture.db, "active_game_slots", 0)
		})
	}
}

func TestCreatePersistsExactlyTwoStableSeatsAndRandomOppositeColors(t *testing.T) {
	tests := []struct {
		name           string
		randomByte     byte
		initiatorColor Color
		opponentColor  Color
	}{
		{name: "zero bit makes initiator black", randomByte: 0xfe, initiatorColor: ColorBlack, opponentColor: ColorWhite},
		{name: "one bit makes initiator white", randomByte: 0x7f, initiatorColor: ColorWhite, opponentColor: ColorBlack},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newFixture(t)
			reader := &oneByteReader{value: test.randomByte}
			created, err := fixture.service(t, reader).Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatalf("Create: %v", err)
			}
			parsed, parseErr := uuid.Parse(created.ID)
			if parseErr != nil || parsed.Version() != 4 || parsed.Variant() != uuid.RFC4122 || created.ID != strings.ToLower(created.ID) {
				t.Fatalf("match ID = %q, want lowercase secure UUIDv4 (parse %v)", created.ID, parseErr)
			}
			if created.GameID != gomoku.GameID || created.Status != StatusActive || created.Revision != 0 {
				t.Fatalf("created match = %+v", created)
			}
			wantTimestamp := time.Unix(fixture.now.UTC().Unix(), 0).UTC()
			if created.CreatedAt != wantTimestamp || created.UpdatedAt != wantTimestamp {
				t.Fatalf("timestamps = %v/%v, want %v", created.CreatedAt, created.UpdatedAt, wantTimestamp)
			}
			if reader.reads != 1 {
				t.Fatalf("entropy reads = %d, want exactly one byte read", reader.reads)
			}

			players := readPlayers(t, fixture.db, created.ID)
			want := []Player{
				{UserID: initiatorID, Seat: 0, Color: test.initiatorColor},
				{UserID: opponentID, Seat: 1, Color: test.opponentColor},
			}
			if fmt.Sprint(players) != fmt.Sprint(want) {
				t.Fatalf("players = %+v, want %+v", players, want)
			}
			assertTableCount(t, fixture.db, "matches", 1)
			assertTableCount(t, fixture.db, "match_players", 2)
			assertTableCount(t, fixture.db, "active_game_slots", 2)
			var slots int
			if err := fixture.db.QueryRow(`SELECT COUNT(*) FROM active_game_slots WHERE game_id=? AND match_id=? AND user_id IN (?,?)`, gomoku.GameID, created.ID, initiatorID, opponentID).Scan(&slots); err != nil {
				t.Fatalf("read slots: %v", err)
			}
			if slots != 2 {
				t.Fatalf("match slots = %d, want 2", slots)
			}
		})
	}
}

type oneByteReader struct {
	value byte
	reads int
}

func (reader *oneByteReader) Read(buffer []byte) (int, error) {
	reader.reads++
	if len(buffer) != 1 {
		return 0, errors.New("reader requested more than one color byte")
	}
	buffer[0] = reader.value
	return 1, nil
}

type failedReader struct{ err error }

func (reader failedReader) Read([]byte) (int, error) { return 0, reader.err }

func TestCreateRandomFailureOrShortReadRollsBack(t *testing.T) {
	tests := []struct {
		name   string
		reader io.Reader
	}{
		{name: "short", reader: bytes.NewReader(nil)},
		{name: "error", reader: failedReader{err: errors.New("secret entropy diagnostic")}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newFixture(t)
			created, err := fixture.service(t, test.reader).Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
			if !errors.Is(err, ErrInternal) || created.ID != "" {
				t.Fatalf("Create = (%+v, %v), want zero and internal", created, err)
			}
			if err.Error() != ErrInternal.Error() {
				t.Fatalf("entropy error leaked: %q", err)
			}
			assertTableCount(t, fixture.db, "matches", 0)
			assertTableCount(t, fixture.db, "match_players", 0)
			assertTableCount(t, fixture.db, "active_game_slots", 0)
		})
	}
}

func TestCreateBusyErrorsAreCallerRelativeAndRollbackEverything(t *testing.T) {
	tests := []struct {
		name      string
		initiator string
		opponent  string
		want      error
	}{
		{name: "initiator busy", initiator: initiatorID, opponent: thirdID, want: ErrActiveMatchExists},
		{name: "opponent busy", initiator: thirdID, opponent: opponentID, want: ErrOpponentBusy},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newFixture(t)
			service := fixture.service(t, bytes.NewReader([]byte{0, 1}))
			first, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatalf("seed Create: %v", err)
			}
			created, err := service.Create(context.Background(), gomoku.GameID, test.initiator, test.opponent)
			if !errors.Is(err, test.want) || created.ID != "" {
				t.Fatalf("busy Create = (%+v, %v), want zero and %v", created, err, test.want)
			}
			if err.Error() != test.want.Error() {
				t.Fatalf("busy error leaked detail: %q", err)
			}
			assertTableCount(t, fixture.db, "matches", 1)
			assertTableCount(t, fixture.db, "match_players", 2)
			assertTableCount(t, fixture.db, "active_game_slots", 2)
			var survivors int
			if err := fixture.db.QueryRow(`SELECT COUNT(*) FROM matches WHERE id=?`, first.ID).Scan(&survivors); err != nil || survivors != 1 {
				t.Fatalf("seed match survivor count=%d err=%v", survivors, err)
			}
		})
	}
}

func TestCreateConcurrentSharedUserHasOneWinnerAndPreciseLoserError(t *testing.T) {
	for attempt := 0; attempt < 20; attempt++ {
		t.Run(fmt.Sprintf("attempt-%02d", attempt), func(t *testing.T) {
			fixture := newFixture(t)
			service := fixture.service(t, zeroReader{})
			type call struct {
				name      string
				initiator string
				opponent  string
			}
			calls := []call{
				{name: "A-to-B", initiator: initiatorID, opponent: opponentID},
				{name: "C-to-A", initiator: thirdID, opponent: initiatorID},
			}
			type result struct {
				call  call
				match Match
				err   error
			}
			start := make(chan struct{})
			results := make(chan result, 2)
			var workers sync.WaitGroup
			for _, item := range calls {
				item := item
				workers.Add(1)
				go func() {
					defer workers.Done()
					<-start
					ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
					defer cancel()
					match, err := service.Create(ctx, gomoku.GameID, item.initiator, item.opponent)
					results <- result{call: item, match: match, err: err}
				}()
			}
			close(start)
			workers.Wait()
			close(results)

			var winner, loser result
			for result := range results {
				if result.err == nil {
					winner = result
				} else {
					loser = result
				}
			}
			if winner.call.name == "" || loser.call.name == "" {
				t.Fatalf("results did not contain one winner and loser: winner=%+v loser=%+v", winner, loser)
			}
			wantLoser := ErrActiveMatchExists
			if winner.call.name == "A-to-B" {
				wantLoser = ErrOpponentBusy
			}
			if !errors.Is(loser.err, wantLoser) || loser.err.Error() != wantLoser.Error() {
				t.Fatalf("winner %s, loser %s error=%v, want %v", winner.call.name, loser.call.name, loser.err, wantLoser)
			}
			assertTableCount(t, fixture.db, "matches", 1)
			assertTableCount(t, fixture.db, "match_players", 2)
			assertTableCount(t, fixture.db, "active_game_slots", 2)
		})
	}
}

type zeroReader struct{}

func (zeroReader) Read(buffer []byte) (int, error) {
	for index := range buffer {
		buffer[index] = 0
	}
	return len(buffer), nil
}

func TestCreateDoesNotDisguiseOtherSQLFailuresAsBusy(t *testing.T) {
	fixture := newFixture(t)
	if _, err := fixture.db.Exec(`
CREATE TRIGGER reject_match_player BEFORE INSERT ON match_players
BEGIN SELECT RAISE(ABORT, 'synthetic player failure'); END`); err != nil {
		t.Fatalf("create fault trigger: %v", err)
	}
	created, err := fixture.service(t, bytes.NewReader([]byte{0})).Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if !errors.Is(err, ErrInternal) || errors.Is(err, ErrActiveMatchExists) || errors.Is(err, ErrOpponentBusy) || created.ID != "" {
		t.Fatalf("Create = (%+v, %v), want only internal", created, err)
	}
	if err.Error() != ErrInternal.Error() {
		t.Fatalf("SQL failure leaked: %q", err)
	}
	assertTableCount(t, fixture.db, "matches", 0)
	assertTableCount(t, fixture.db, "match_players", 0)
	assertTableCount(t, fixture.db, "active_game_slots", 0)
}

func TestCreateDoesNotTrustConstraintTextWithoutTheExactSQLiteConstraintKind(t *testing.T) {
	fixture := newFixture(t)
	if _, err := fixture.db.Exec(`
CREATE TRIGGER spoof_active_slot_conflict BEFORE INSERT ON active_game_slots
BEGIN SELECT RAISE(ABORT, 'UNIQUE constraint failed: active_game_slots.game_id, active_game_slots.user_id'); END`); err != nil {
		t.Fatalf("create spoof trigger: %v", err)
	}
	created, err := fixture.service(t, bytes.NewReader([]byte{0})).Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if !errors.Is(err, ErrInternal) || errors.Is(err, ErrActiveMatchExists) || errors.Is(err, ErrOpponentBusy) || created.ID != "" {
		t.Fatalf("Create = (%+v, %v), want only internal", created, err)
	}
	if err.Error() != ErrInternal.Error() {
		t.Fatalf("spoofed constraint leaked: %q", err)
	}
	assertTableCount(t, fixture.db, "matches", 0)
	assertTableCount(t, fixture.db, "match_players", 0)
	assertTableCount(t, fixture.db, "active_game_slots", 0)
}

type twoPlayerRules struct {
	id     string
	single bool
}

func (rules twoPlayerRules) GameID() string                 { return rules.id }
func (twoPlayerRules) PlayerLimit() int                     { return 2 }
func (rules twoPlayerRules) SingleActiveMatchPerUser() bool { return rules.single }
func (twoPlayerRules) Rebuild([]gameapi.Event) (gameapi.Snapshot, error) {
	return gameapi.Snapshot{}, nil
}
func (twoPlayerRules) Apply(gameapi.Snapshot, string, gameapi.Action) (gameapi.Event, gameapi.Snapshot, error) {
	return gameapi.Event{}, gameapi.Snapshot{}, nil
}

func TestCreateUsesGameCapabilityInsteadOfGlobalSlotPolicy(t *testing.T) {
	fixture := newFixture(t)
	registry, err := games.NewRegistryFrom(twoPlayerRules{id: "casual", single: false})
	if err != nil {
		t.Fatalf("create custom registry: %v", err)
	}
	service, err := NewService(fixture.db, registry, fixture.clock, zeroReader{})
	if err != nil {
		t.Fatalf("NewService: %v", err)
	}
	for iteration := 0; iteration < 2; iteration++ {
		if _, err := service.Create(context.Background(), "casual", initiatorID, opponentID); err != nil {
			t.Fatalf("Create iteration %d: %v", iteration, err)
		}
	}
	assertTableCount(t, fixture.db, "matches", 2)
	assertTableCount(t, fixture.db, "match_players", 4)
	assertTableCount(t, fixture.db, "active_game_slots", 0)
}

func TestCreateRejectsNonTwoPlayerGame(t *testing.T) {
	fixture := newFixture(t)
	registry, err := games.NewRegistryFrom(playerCountRules{id: "party", count: 3})
	if err != nil {
		t.Fatalf("create custom registry: %v", err)
	}
	service, err := NewService(fixture.db, registry, fixture.clock, zeroReader{})
	if err != nil {
		t.Fatalf("NewService: %v", err)
	}
	if _, err := service.Create(context.Background(), "party", initiatorID, opponentID); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("Create error=%v, want invalid request", err)
	}
	assertTableCount(t, fixture.db, "matches", 0)
}

type playerCountRules struct {
	id    string
	count int
}

func (rules playerCountRules) GameID() string   { return rules.id }
func (rules playerCountRules) PlayerLimit() int { return rules.count }
func (playerCountRules) Rebuild([]gameapi.Event) (gameapi.Snapshot, error) {
	return gameapi.Snapshot{}, nil
}
func (playerCountRules) Apply(gameapi.Snapshot, string, gameapi.Action) (gameapi.Event, gameapi.Snapshot, error) {
	return gameapi.Event{}, gameapi.Snapshot{}, nil
}

func TestCancelEitherPlayerZeroMoveCommitsCanonicalEventAndReleasesSlots(t *testing.T) {
	for _, actorID := range []string{initiatorID, opponentID} {
		t.Run(actorID, func(t *testing.T) {
			fixture := newFixture(t)
			service := fixture.service(t, bytes.NewReader([]byte{0}))
			created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatalf("Create: %v", err)
			}
			fixture.clock.Advance(3*time.Second + 999*time.Millisecond)
			event, err := service.Cancel(context.Background(), created.ID, actorID)
			if err != nil {
				t.Fatalf("Cancel: %v", err)
			}
			wantTimestamp := time.Unix(fixture.clock.Now().UTC().Unix(), 0).UTC()
			if event.MatchID != created.ID || event.Revision != 1 || event.Type != protocol.TypePlatformMatchCancelled || event.ActionID != nil || event.ActorUserID == nil || *event.ActorUserID != actorID || string(event.Payload) != `{}` || !event.CreatedAt.Equal(wantTimestamp) {
				t.Fatalf("cancel event = %+v payload=%s", event, event.Payload)
			}
			var status string
			var revision, updatedAt, finishedAt int64
			var winner, result sql.NullString
			if err := fixture.db.QueryRow(`SELECT status,revision,updated_at,finished_at,winner_user_id,result FROM matches WHERE id=?`, created.ID).
				Scan(&status, &revision, &updatedAt, &finishedAt, &winner, &result); err != nil {
				t.Fatalf("read cancelled match: %v", err)
			}
			if status != StatusCancelled || revision != 1 || updatedAt != fixture.clock.Now().UTC().Unix() || finishedAt != fixture.clock.Now().UTC().Unix() || winner.Valid || result.Valid {
				t.Fatalf("cancelled row=(%s,%d,%d,%d,%v,%v)", status, revision, updatedAt, finishedAt, winner, result)
			}
			var eventType, payload string
			var actionID sql.NullString
			var storedActor sql.NullString
			var createdAt int64
			if err := fixture.db.QueryRow(`SELECT event_type,action_id,actor_user_id,payload_json,created_at FROM match_events WHERE match_id=? AND revision=1`, created.ID).
				Scan(&eventType, &actionID, &storedActor, &payload, &createdAt); err != nil {
				t.Fatalf("read cancellation event: %v", err)
			}
			if eventType != protocol.TypePlatformMatchCancelled || actionID.Valid || !storedActor.Valid || storedActor.String != actorID || payload != `{}` || createdAt != fixture.clock.Now().UTC().Unix() {
				t.Fatalf("stored event=(%s,%v,%v,%s,%d)", eventType, actionID, storedActor, payload, createdAt)
			}
			assertTableCount(t, fixture.db, "active_game_slots", 0)
		})
	}
}

func TestCancelAdvancesExistingRevisionByExactlyOne(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if _, err := fixture.db.Exec(`INSERT INTO match_events(match_id,revision,event_type,payload_json,created_at) VALUES (?,1,'platform.audit','{}',?)`, created.ID, fixture.now.Unix()); err != nil {
		t.Fatalf("insert prior event: %v", err)
	}
	if _, err := fixture.db.Exec(`UPDATE matches SET revision=1 WHERE id=?`, created.ID); err != nil {
		t.Fatalf("advance stored match: %v", err)
	}
	event, err := service.Cancel(context.Background(), created.ID, opponentID)
	if err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	if event.Revision != 2 {
		t.Fatalf("event revision=%d, want 2", event.Revision)
	}
	var revisions string
	if err := fixture.db.QueryRow(`SELECT group_concat(revision, ',') FROM (SELECT revision FROM match_events WHERE match_id=? ORDER BY revision)`, created.ID).Scan(&revisions); err != nil {
		t.Fatalf("read revisions: %v", err)
	}
	if revisions != "1,2" {
		t.Fatalf("revisions=%q, want 1,2", revisions)
	}
}

func TestCancelRejectsUnknownNonPlayerInactiveAndAnyAcceptedMove(t *testing.T) {
	tests := []struct {
		name  string
		setup func(t *testing.T, fixture fixture, service *Service, matchID string) string
		actor string
		want  error
	}{
		{name: "unknown match", setup: func(*testing.T, fixture, *Service, string) string { return "44444444-4444-4444-8444-444444444444" }, actor: initiatorID, want: ErrMatchNotFound},
		{name: "non player", setup: func(_ *testing.T, _ fixture, _ *Service, id string) string { return id }, actor: thirdID, want: ErrMatchNotCancellable},
		{name: "unknown actor", setup: func(_ *testing.T, _ fixture, _ *Service, id string) string { return id }, actor: "44444444-4444-4444-8444-444444444444", want: ErrMatchNotCancellable},
		{name: "inactive", setup: func(t *testing.T, f fixture, _ *Service, id string) string {
			if _, err := f.db.Exec(`UPDATE matches SET status='finished',finished_at=? WHERE id=?`, f.now.Unix(), id); err != nil {
				t.Fatalf("finish match: %v", err)
			}
			return id
		}, actor: initiatorID, want: ErrMatchNotCancellable},
		{name: "accepted move", setup: func(t *testing.T, f fixture, _ *Service, id string) string {
			payload, _ := json.Marshal(map[string]any{"x": 7, "y": 7})
			if _, err := f.db.Exec(`INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at) VALUES (?,1,?,?,?, ?,?)`, id, gomoku.MoveAccepted, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", initiatorID, string(payload), f.now.Unix()); err != nil {
				t.Fatalf("insert move: %v", err)
			}
			if _, err := f.db.Exec(`UPDATE matches SET revision=1 WHERE id=?`, id); err != nil {
				t.Fatalf("advance match: %v", err)
			}
			return id
		}, actor: opponentID, want: ErrMatchNotCancellable},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newFixture(t)
			service := fixture.service(t, bytes.NewReader([]byte{0}))
			created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatalf("Create: %v", err)
			}
			matchID := test.setup(t, fixture, service, created.ID)
			event, err := service.Cancel(context.Background(), matchID, test.actor)
			if !errors.Is(err, test.want) || event.MatchID != "" {
				t.Fatalf("Cancel=(%+v,%v), want zero and %v", event, err, test.want)
			}
			if err.Error() != test.want.Error() {
				t.Fatalf("cancel error leaked details: %q", err)
			}
			var status string
			if err := fixture.db.QueryRow(`SELECT status FROM matches WHERE id=?`, created.ID).Scan(&status); err != nil {
				t.Fatalf("read match: %v", err)
			}
			if test.name != "inactive" && status != StatusActive {
				t.Fatalf("status=%q, want active", status)
			}
			assertTableCount(t, fixture.db, "active_game_slots", 2)
		})
	}
}

func TestCancelConcurrentPlayersHasExactlyOneWinner(t *testing.T) {
	for attempt := 0; attempt < 20; attempt++ {
		t.Run(fmt.Sprintf("attempt-%02d", attempt), func(t *testing.T) {
			fixture := newFixture(t)
			service := fixture.service(t, bytes.NewReader([]byte{0}))
			created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatalf("Create: %v", err)
			}
			start := make(chan struct{})
			errorsByCall := make(chan error, 2)
			var workers sync.WaitGroup
			for _, actor := range []string{initiatorID, opponentID} {
				actor := actor
				workers.Add(1)
				go func() {
					defer workers.Done()
					<-start
					_, err := service.Cancel(context.Background(), created.ID, actor)
					errorsByCall <- err
				}()
			}
			close(start)
			workers.Wait()
			close(errorsByCall)
			successes, rejected := 0, 0
			for err := range errorsByCall {
				switch {
				case err == nil:
					successes++
				case errors.Is(err, ErrMatchNotCancellable):
					rejected++
				default:
					t.Fatalf("Cancel error=%v", err)
				}
			}
			if successes != 1 || rejected != 1 {
				t.Fatalf("results=%d success %d rejected", successes, rejected)
			}
			assertTableCount(t, fixture.db, "match_events", 1)
			assertTableCount(t, fixture.db, "active_game_slots", 0)
		})
	}
}

func TestCancelSlotCorruptionRollsBackEveryStep(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if _, err := fixture.db.Exec(`DELETE FROM active_game_slots WHERE game_id=? AND user_id=?`, gomoku.GameID, opponentID); err != nil {
		t.Fatalf("corrupt slot: %v", err)
	}
	event, err := service.Cancel(context.Background(), created.ID, initiatorID)
	if !errors.Is(err, ErrInternal) || event.MatchID != "" {
		t.Fatalf("Cancel=(%+v,%v), want internal", event, err)
	}
	if err.Error() != ErrInternal.Error() {
		t.Fatalf("corruption leaked: %q", err)
	}
	var status string
	var revision int64
	var finishedAt sql.NullInt64
	if err := fixture.db.QueryRow(`SELECT status,revision,finished_at FROM matches WHERE id=?`, created.ID).Scan(&status, &revision, &finishedAt); err != nil {
		t.Fatalf("read match: %v", err)
	}
	if status != StatusActive || revision != 0 || finishedAt.Valid {
		t.Fatalf("rollback row=(%s,%d,%v)", status, revision, finishedAt)
	}
	assertTableCount(t, fixture.db, "match_events", 0)
	assertTableCount(t, fixture.db, "active_game_slots", 1)
}

func TestCancelDoesNotDeleteSlotsBelongingToAUserOutsideTheMatch(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if _, err := fixture.db.Exec(`UPDATE active_game_slots SET user_id=? WHERE game_id=? AND user_id=?`, thirdID, gomoku.GameID, opponentID); err != nil {
		t.Fatalf("corrupt slot owner: %v", err)
	}
	event, err := service.Cancel(context.Background(), created.ID, initiatorID)
	if !errors.Is(err, ErrInternal) || event.MatchID != "" {
		t.Fatalf("Cancel=(%+v,%v), want internal", event, err)
	}
	var status string
	var revision int64
	if err := fixture.db.QueryRow(`SELECT status,revision FROM matches WHERE id=?`, created.ID).Scan(&status, &revision); err != nil {
		t.Fatalf("read match: %v", err)
	}
	if status != StatusActive || revision != 0 {
		t.Fatalf("rollback row=(%s,%d)", status, revision)
	}
	assertTableCount(t, fixture.db, "match_events", 0)
	assertTableCount(t, fixture.db, "active_game_slots", 2)
}

func TestCreateHonorsContextCancellationWhileDatabaseBusyAndRestoresConnection(t *testing.T) {
	fixture := newFixture(t)
	locker, err := fixture.db.Conn(context.Background())
	if err != nil {
		t.Fatalf("reserve locker: %v", err)
	}
	defer locker.Close()
	if _, err := locker.ExecContext(context.Background(), `BEGIN IMMEDIATE`); err != nil {
		t.Fatalf("lock database: %v", err)
	}
	defer locker.ExecContext(context.Background(), `ROLLBACK`)

	ctx, cancel := context.WithTimeout(context.Background(), 75*time.Millisecond)
	defer cancel()
	started := time.Now()
	_, err = fixture.service(t, bytes.NewReader([]byte{0})).Create(ctx, gomoku.GameID, initiatorID, opponentID)
	elapsed := time.Since(started)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Create error=%v, want deadline", err)
	}
	if elapsed > 750*time.Millisecond {
		t.Fatalf("Create cancellation took %v", elapsed)
	}
	if _, err := locker.ExecContext(context.Background(), `ROLLBACK`); err != nil {
		t.Fatalf("unlock database: %v", err)
	}
	assertTableCount(t, fixture.db, "matches", 0)
	connection, err := fixture.db.Conn(context.Background())
	if err != nil {
		t.Fatalf("reserve connection: %v", err)
	}
	defer connection.Close()
	var busyTimeout int
	if err := connection.QueryRowContext(context.Background(), `PRAGMA busy_timeout`).Scan(&busyTimeout); err != nil {
		t.Fatalf("read busy timeout: %v", err)
	}
	if busyTimeout != 5000 {
		t.Fatalf("busy timeout=%d, want 5000", busyTimeout)
	}
}

func TestCancelHonorsContextCancellationWhileDatabaseBusyWithoutPartialWrites(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	locker, err := fixture.db.Conn(context.Background())
	if err != nil {
		t.Fatalf("reserve locker: %v", err)
	}
	defer locker.Close()
	if _, err := locker.ExecContext(context.Background(), `BEGIN IMMEDIATE`); err != nil {
		t.Fatalf("lock database: %v", err)
	}
	defer locker.ExecContext(context.Background(), `ROLLBACK`)

	ctx, cancel := context.WithTimeout(context.Background(), 75*time.Millisecond)
	defer cancel()
	started := time.Now()
	_, err = service.Cancel(ctx, created.ID, initiatorID)
	elapsed := time.Since(started)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Cancel error=%v, want deadline", err)
	}
	if elapsed > 750*time.Millisecond {
		t.Fatalf("Cancel cancellation took %v", elapsed)
	}
	if _, err := locker.ExecContext(context.Background(), `ROLLBACK`); err != nil {
		t.Fatalf("unlock database: %v", err)
	}
	var status string
	var revision int64
	if err := fixture.db.QueryRow(`SELECT status,revision FROM matches WHERE id=?`, created.ID).Scan(&status, &revision); err != nil {
		t.Fatalf("read match: %v", err)
	}
	if status != StatusActive || revision != 0 {
		t.Fatalf("cancelled write escaped deadline: (%s,%d)", status, revision)
	}
	assertTableCount(t, fixture.db, "match_events", 0)
	assertTableCount(t, fixture.db, "active_game_slots", 2)
}

func TestServiceRejectsNilConfigurationAndMethodsRemainDefensive(t *testing.T) {
	fixture := newFixture(t)
	tests := []struct {
		name     string
		db       *sql.DB
		registry *games.Registry
		clock    clock.Clock
		random   io.Reader
	}{
		{name: "nil db", registry: fixture.registry, clock: fixture.clock, random: zeroReader{}},
		{name: "nil registry", db: fixture.db, clock: fixture.clock, random: zeroReader{}},
		{name: "nil clock", db: fixture.db, registry: fixture.registry, random: zeroReader{}},
		{name: "typed nil clock", db: fixture.db, registry: fixture.registry, clock: (*clock.Fake)(nil), random: zeroReader{}},
		{name: "nil random", db: fixture.db, registry: fixture.registry, clock: fixture.clock},
		{name: "typed nil random", db: fixture.db, registry: fixture.registry, clock: fixture.clock, random: (*bytes.Reader)(nil)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			service, err := NewService(test.db, test.registry, test.clock, test.random)
			if service != nil || !errors.Is(err, ErrInvalidConfiguration) || err.Error() != ErrInvalidConfiguration.Error() {
				t.Fatalf("NewService=(%v,%v), want nil invalid config", service, err)
			}
		})
	}
	var nilService *Service
	if _, err := nilService.Create(context.Background(), gomoku.GameID, initiatorID, opponentID); !errors.Is(err, ErrInvalidConfiguration) {
		t.Fatalf("nil Create error=%v", err)
	}
	if _, err := nilService.Cancel(context.Background(), "44444444-4444-4444-8444-444444444444", initiatorID); !errors.Is(err, ErrInvalidConfiguration) {
		t.Fatalf("nil Cancel error=%v", err)
	}
}

func readPlayers(t *testing.T, db *sql.DB, matchID string) []Player {
	t.Helper()
	rows, err := db.Query(`SELECT user_id,seat,color FROM match_players WHERE match_id=? ORDER BY seat`, matchID)
	if err != nil {
		t.Fatalf("query players: %v", err)
	}
	defer rows.Close()
	var result []Player
	for rows.Next() {
		var player Player
		if err := rows.Scan(&player.UserID, &player.Seat, &player.Color); err != nil {
			t.Fatalf("scan player: %v", err)
		}
		result = append(result, player)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate players: %v", err)
	}
	return result
}

func assertTableCount(t *testing.T, db *sql.DB, table string, want int) {
	t.Helper()
	allowed := map[string]bool{"matches": true, "match_players": true, "active_game_slots": true, "match_events": true}
	if !allowed[table] {
		t.Fatalf("unsafe table %q", table)
	}
	var got int
	if err := db.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&got); err != nil {
		t.Fatalf("count %s: %v", table, err)
	}
	if got != want {
		t.Fatalf("%s count=%d, want %d", table, got, want)
	}
}
