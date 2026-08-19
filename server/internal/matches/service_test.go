package matches

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"path/filepath"
	"reflect"
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
VALUES (?,?,?,?,?,?)`, id, nickname, strings.ToLower(nickname), enabledInteger, fixture.now.Add(-time.Hour).UnixMilli(), fixture.now.Add(-time.Hour).UnixMilli())
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
			wantTimestamp := time.UnixMilli(fixture.now.UTC().UnixMilli()).UTC()
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

type launchTicketEntropyReader struct {
	reads int
	value byte
}

func (reader *launchTicketEntropyReader) Read(destination []byte) (int, error) {
	reader.reads++
	for index := range destination {
		destination[index] = reader.value
	}
	return len(destination), nil
}

type launchTicketGateClock struct {
	base    *clock.Fake
	entered chan struct{}
	release <-chan struct{}
}

func (serviceClock *launchTicketGateClock) Now() time.Time {
	sampled := serviceClock.base.Now()
	select {
	case serviceClock.entered <- struct{}{}:
	default:
	}
	<-serviceClock.release
	return sampled
}

type launchTicketCountingClock struct {
	now   time.Time
	calls int
}

func (serviceClock *launchTicketCountingClock) Now() time.Time {
	serviceClock.calls++
	return serviceClock.now
}

func newLaunchTicketService(t *testing.T, fixture fixture, serviceClock clock.Clock, entropy io.Reader) *Service {
	t.Helper()
	service, err := NewServiceWithConfig(fixture.db, fixture.registry, serviceClock, ServiceConfig{
		ColorRandom:        bytes.NewReader([]byte{0}),
		LaunchTicketRandom: entropy,
		TokenPepper:        strings.Repeat("p", minimumTokenPepperBytes),
	})
	if err != nil {
		t.Fatalf("NewServiceWithConfig: %v", err)
	}
	return service
}

func TestCreateLaunchTicketTTLStartsAfterWriteLockAndValidation(t *testing.T) {
	fixture := newFixture(t)
	created, err := fixture.service(t, bytes.NewReader([]byte{0})).Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatalf("seed match: %v", err)
	}

	blocking, err := fixture.db.BeginTx(context.Background(), nil)
	if err != nil {
		t.Fatalf("hold immediate transaction: %v", err)
	}
	blockingOpen := true
	defer func() {
		if blockingOpen {
			_ = blocking.Rollback()
		}
	}()

	baseClock := clock.NewFake(fixture.now)
	releaseClock := make(chan struct{})
	gateClock := &launchTicketGateClock{base: baseClock, entered: make(chan struct{}, 1), release: releaseClock}
	entropy := &launchTicketEntropyReader{value: 0x5a}
	service := newLaunchTicketService(t, fixture, gateClock, entropy)
	type result struct {
		ticket LaunchTicket
		err    error
	}
	started := make(chan struct{})
	resultChannel := make(chan result, 1)
	go func() {
		close(started)
		ticket, issueErr := service.CreateLaunchTicket(context.Background(), created.ID, initiatorID)
		resultChannel <- result{ticket: ticket, err: issueErr}
	}()
	<-started

	// On the buggy implementation Now is sampled before beginWriteTransaction,
	// so this channel provides a deterministic barrier. Once fixed, the write
	// lock prevents the sample and the bounded wait proves the request is still
	// blocked before the test advances time and releases the lock.
	select {
	case <-gateClock.entered:
	case <-time.After(75 * time.Millisecond):
	}
	baseClock.Advance(37 * time.Second)
	close(releaseClock)
	if err := blocking.Rollback(); err != nil {
		t.Fatalf("release immediate transaction: %v", err)
	}
	blockingOpen = false

	var outcome result
	select {
	case outcome = <-resultChannel:
	case <-time.After(2 * time.Second):
		t.Fatal("CreateLaunchTicket did not finish after lock release")
	}
	if outcome.err != nil {
		t.Fatalf("CreateLaunchTicket: %v", outcome.err)
	}
	wantCreatedAt := baseClock.Now().UTC().UnixMilli()
	wantExpiresAt := wantCreatedAt + launchTicketLifetime.Milliseconds()
	if got := outcome.ticket.ExpiresAt.UTC().UnixMilli(); got != wantExpiresAt {
		t.Fatalf("ticket expiresAt=%d, want post-lock sample %d", got, wantExpiresAt)
	}
	var storedCreatedAt, storedExpiresAt int64
	if err := fixture.db.QueryRow(`SELECT created_at,expires_at FROM launch_tickets`).Scan(&storedCreatedAt, &storedExpiresAt); err != nil {
		t.Fatalf("read launch ticket timestamps: %v", err)
	}
	if storedCreatedAt != wantCreatedAt || storedExpiresAt != wantExpiresAt || storedExpiresAt-storedCreatedAt != launchTicketLifetime.Milliseconds() {
		t.Fatalf("stored timestamps=(%d,%d), want (%d,%d)", storedCreatedAt, storedExpiresAt, wantCreatedAt, wantExpiresAt)
	}
	if entropy.reads != 1 {
		t.Fatalf("ticket entropy reads=%d, want 1 after validation", entropy.reads)
	}
}

func TestCreateLaunchTicketSamplesClockAfterValidationAndFailsClosed(t *testing.T) {
	t.Run("overflow does not mask participant validation", func(t *testing.T) {
		fixture := newFixture(t)
		created, err := fixture.service(t, bytes.NewReader([]byte{0})).Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		serviceClock := &launchTicketCountingClock{now: time.UnixMilli(int64(^uint64(0) >> 1))}
		entropy := &launchTicketEntropyReader{value: 1}
		ticket, issueErr := newLaunchTicketService(t, fixture, serviceClock, entropy).CreateLaunchTicket(context.Background(), created.ID, thirdID)
		if !errors.Is(issueErr, ErrMatchNotFound) || ticket.Token != "" {
			t.Fatalf("nonparticipant overflow=(%+v,%v), want match not found", ticket, issueErr)
		}
		if serviceClock.calls != 0 || entropy.reads != 0 {
			t.Fatalf("validation failure sampled clock/generated entropy: clock=%d entropy=%d", serviceClock.calls, entropy.reads)
		}
		assertTableCount(t, fixture.db, "launch_tickets", 0)
	})

	t.Run("overflow after validation rolls back without plaintext", func(t *testing.T) {
		fixture := newFixture(t)
		created, err := fixture.service(t, bytes.NewReader([]byte{0})).Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		serviceClock := &launchTicketCountingClock{now: time.UnixMilli(int64(^uint64(0) >> 1))}
		entropy := &launchTicketEntropyReader{value: 2}
		ticket, issueErr := newLaunchTicketService(t, fixture, serviceClock, entropy).CreateLaunchTicket(context.Background(), created.ID, initiatorID)
		if !errors.Is(issueErr, ErrInternal) || ticket.Token != "" || ticket.MatchID != "" {
			t.Fatalf("overflow=(%+v,%v), want zero/internal", ticket, issueErr)
		}
		if serviceClock.calls != 1 || entropy.reads != 0 {
			t.Fatalf("overflow clock/entropy calls=(%d,%d), want (1,0)", serviceClock.calls, entropy.reads)
		}
		assertTableCount(t, fixture.db, "launch_tickets", 0)
		writeContext, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
		defer cancel()
		if _, err := fixture.db.ExecContext(writeContext, `UPDATE users SET updated_at=updated_at WHERE id=?`, initiatorID); err != nil {
			t.Fatalf("overflow transaction was not released: %v", err)
		}
	})

	t.Run("lock timeout never reaches clock or entropy", func(t *testing.T) {
		fixture := newFixture(t)
		created, err := fixture.service(t, bytes.NewReader([]byte{0})).Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		blocking, err := fixture.db.BeginTx(context.Background(), nil)
		if err != nil {
			t.Fatal(err)
		}
		serviceClock := &launchTicketCountingClock{now: fixture.now}
		entropy := &launchTicketEntropyReader{value: 3}
		ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
		defer cancel()
		ticket, issueErr := newLaunchTicketService(t, fixture, serviceClock, entropy).CreateLaunchTicket(ctx, created.ID, initiatorID)
		if rollbackErr := blocking.Rollback(); rollbackErr != nil {
			t.Fatal(rollbackErr)
		}
		if !errors.Is(issueErr, context.DeadlineExceeded) || ticket.Token != "" {
			t.Fatalf("lock timeout=(%+v,%v), want deadline", ticket, issueErr)
		}
		if serviceClock.calls != 0 || entropy.reads != 0 {
			t.Fatalf("lock timeout sampled clock/generated entropy: clock=%d entropy=%d", serviceClock.calls, entropy.reads)
		}
		assertTableCount(t, fixture.db, "launch_tickets", 0)
	})
}

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
			wantTimestamp := time.UnixMilli(fixture.clock.Now().UTC().UnixMilli()).UTC()
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
			if status != StatusCancelled || revision != 1 || updatedAt != fixture.clock.Now().UTC().UnixMilli() || finishedAt != fixture.clock.Now().UTC().UnixMilli() || winner.Valid || result.Valid {
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
			if eventType != protocol.TypePlatformMatchCancelled || actionID.Valid || !storedActor.Valid || storedActor.String != actorID || payload != `{}` || createdAt != fixture.clock.Now().UTC().UnixMilli() {
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
	if _, err := fixture.db.Exec(`INSERT INTO match_events(match_id,revision,event_type,payload_json,created_at) VALUES (?,1,'platform.audit','{}',?)`, created.ID, fixture.now.UnixMilli()); err != nil {
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
			if _, err := f.db.Exec(`UPDATE matches SET status='finished',finished_at=? WHERE id=?`, f.now.UnixMilli(), id); err != nil {
				t.Fatalf("finish match: %v", err)
			}
			return id
		}, actor: initiatorID, want: ErrMatchNotCancellable},
		{name: "accepted move", setup: func(t *testing.T, f fixture, _ *Service, id string) string {
			payload, _ := json.Marshal(map[string]any{"x": 7, "y": 7})
			if _, err := f.db.Exec(`INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at) VALUES (?,1,?,?,?, ?,?)`, id, gomoku.MoveAccepted, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", initiatorID, string(payload), f.now.UnixMilli()); err != nil {
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

func TestCancelRejectsEveryCorruptActiveSlotSetBeforeLifecycleWrites(t *testing.T) {
	tests := []struct {
		name    string
		corrupt func(t *testing.T, fixture fixture, matchID string)
	}{
		{
			name: "missing player slot",
			corrupt: func(t *testing.T, fixture fixture, _ string) {
				if _, err := fixture.db.Exec(`DELETE FROM active_game_slots WHERE game_id=? AND user_id=?`, gomoku.GameID, opponentID); err != nil {
					t.Fatalf("remove player slot: %v", err)
				}
			},
		},
		{
			name: "replacement third user",
			corrupt: func(t *testing.T, fixture fixture, _ string) {
				if _, err := fixture.db.Exec(`UPDATE active_game_slots SET user_id=? WHERE game_id=? AND user_id=?`, thirdID, gomoku.GameID, opponentID); err != nil {
					t.Fatalf("replace slot user: %v", err)
				}
			},
		},
		{
			name: "extra third user",
			corrupt: func(t *testing.T, fixture fixture, matchID string) {
				if _, err := fixture.db.Exec(`INSERT INTO active_game_slots(game_id,user_id,match_id) VALUES (?,?,?)`, gomoku.GameID, thirdID, matchID); err != nil {
					t.Fatalf("insert extra slot: %v", err)
				}
			},
		},
		{
			name: "wrong game",
			corrupt: func(t *testing.T, fixture fixture, _ string) {
				if _, err := fixture.db.Exec(`UPDATE active_game_slots SET game_id='chess' WHERE game_id=? AND user_id=?`, gomoku.GameID, opponentID); err != nil {
					t.Fatalf("replace slot game: %v", err)
				}
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newFixture(t)
			service := fixture.service(t, bytes.NewReader([]byte{0}))
			created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatalf("Create: %v", err)
			}
			test.corrupt(t, fixture, created.ID)
			before := readActiveSlots(t, fixture.db)

			event, err := service.Cancel(context.Background(), created.ID, initiatorID)
			if !errors.Is(err, ErrInternal) || event.MatchID != "" {
				t.Fatalf("Cancel=(%+v,%v), want zero event and internal", event, err)
			}
			if err.Error() != ErrInternal.Error() {
				t.Fatalf("slot corruption leaked: %q", err)
			}
			var status string
			var revision int64
			var finishedAt sql.NullInt64
			if err := fixture.db.QueryRow(`SELECT status,revision,finished_at FROM matches WHERE id=?`, created.ID).Scan(&status, &revision, &finishedAt); err != nil {
				t.Fatalf("read match: %v", err)
			}
			if status != StatusActive || revision != 0 || finishedAt.Valid {
				t.Fatalf("lifecycle changed despite corrupt slots: (%s,%d,%v)", status, revision, finishedAt)
			}
			assertTableCount(t, fixture.db, "match_events", 0)
			after := readActiveSlots(t, fixture.db)
			if fmt.Sprint(after) != fmt.Sprint(before) {
				t.Fatalf("corrupt slots changed: before=%v after=%v", before, after)
			}
		})
	}
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
	if _, err := nilService.Snapshot(context.Background(), "44444444-4444-4444-8444-444444444444"); !errors.Is(err, ErrInvalidConfiguration) {
		t.Fatalf("nil Snapshot error=%v", err)
	}
	if _, _, err := nilService.ApplyAction(context.Background(), ActionRequest{}); !errors.Is(err, ErrInvalidConfiguration) {
		t.Fatalf("nil ApplyAction error=%v", err)
	}
	if err := nilService.SetPlayerOnline(context.Background(), "44444444-4444-4444-8444-444444444444", initiatorID); !errors.Is(err, ErrInvalidConfiguration) {
		t.Fatalf("nil SetPlayerOnline error=%v", err)
	}
	if err := nilService.SetPlayerOffline(context.Background(), "44444444-4444-4444-8444-444444444444", initiatorID); !errors.Is(err, ErrInvalidConfiguration) {
		t.Fatalf("nil SetPlayerOffline error=%v", err)
	}
	if events, err := nilService.AbandonExpired(context.Background()); !errors.Is(err, ErrInvalidConfiguration) || len(events) != 0 {
		t.Fatalf("nil AbandonExpired=(%+v,%v)", events, err)
	}
	if err := nilService.MarkActiveMatchesOfflineOnBoot(context.Background()); !errors.Is(err, ErrInvalidConfiguration) {
		t.Fatalf("nil MarkActiveMatchesOfflineOnBoot error=%v", err)
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
	allowed := map[string]bool{"matches": true, "match_players": true, "active_game_slots": true, "match_events": true, "launch_tickets": true}
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

type storedSlot struct {
	GameID  string
	UserID  string
	MatchID string
}

func readActiveSlots(t *testing.T, db *sql.DB) []storedSlot {
	t.Helper()
	rows, err := db.Query(`SELECT game_id,user_id,match_id FROM active_game_slots ORDER BY game_id,user_id,match_id`)
	if err != nil {
		t.Fatalf("query active slots: %v", err)
	}
	defer rows.Close()
	var slots []storedSlot
	for rows.Next() {
		var slot storedSlot
		if err := rows.Scan(&slot.GameID, &slot.UserID, &slot.MatchID); err != nil {
			t.Fatalf("scan active slot: %v", err)
		}
		slots = append(slots, slot)
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("iterate active slots: %v", err)
	}
	return slots
}

func TestApplyActionEnforcesAllocatedColorsTurnOccupancyAndRevision(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	assertRejected := func(name string, request ActionRequest, want error) {
		t.Helper()
		t.Run(name, func(t *testing.T) {
			event, snapshot, err := service.ApplyAction(context.Background(), request)
			if !errors.Is(err, want) || event.MatchID != "" || snapshot.Match.ID != "" {
				t.Fatalf("ApplyAction=(%+v,%+v,%v), want zero results and %v", event, snapshot, err, want)
			}
			if err.Error() != want.Error() {
				t.Fatalf("action error leaked details: %q", err)
			}
		})
	}
	assertRejected("database white cannot open", moveRequest(created.ID, opponentID, 1, 0, 7, 7), gomoku.ErrNotYourTurn)

	first, snapshot, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 2, 0, 7, 7))
	if err != nil {
		t.Fatalf("first ApplyAction: %v", err)
	}
	if first.MatchID != created.ID || first.Revision != 1 || first.Type != gomoku.MoveAccepted || first.ActionID == nil || *first.ActionID != actionID(2) || first.ActorUserID == nil || *first.ActorUserID != initiatorID {
		t.Fatalf("first event=%+v", first)
	}
	wantPayload := fmt.Sprintf(`{"x":7,"y":7,"color":"black","userId":%q}`, initiatorID)
	if string(first.Payload) != wantPayload || snapshot.Match.Revision != 1 || snapshot.Game.Revision != 1 {
		t.Fatalf("first payload/snapshot=%s %+v", first.Payload, snapshot)
	}
	var storedRevision, eventRevision int64
	if err := fixture.db.QueryRow(`SELECT revision FROM matches WHERE id=?`, created.ID).Scan(&storedRevision); err != nil {
		t.Fatal(err)
	}
	if err := fixture.db.QueryRow(`SELECT revision FROM match_events WHERE match_id=?`, created.ID).Scan(&eventRevision); err != nil {
		t.Fatal(err)
	}
	if storedRevision != 1 || eventRevision != 1 {
		t.Fatalf("atomic revisions match=%d event=%d", storedRevision, eventRevision)
	}

	assertRejected("black cannot move twice", moveRequest(created.ID, initiatorID, 3, 1, 8, 7), gomoku.ErrNotYourTurn)
	assertRejected("occupied cell", moveRequest(created.ID, opponentID, 4, 1, 7, 7), gomoku.ErrCellOccupied)
	assertRejected("stale revision", moveRequest(created.ID, opponentID, 5, 0, 8, 7), ErrStaleRevision)
	assertTableCount(t, fixture.db, "match_events", 1)
}

func TestApplyActionUsesRandomlyAllocatedBlackPlayerInsteadOfInitiatorSeat(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{1}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	event, snapshot, err := service.ApplyAction(context.Background(), moveRequest(created.ID, opponentID, 6, 0, 5, 5))
	if err != nil {
		t.Fatalf("allocated black opener: %v", err)
	}
	if event.ActorUserID == nil || *event.ActorUserID != opponentID || !bytes.Contains(event.Payload, []byte(`"color":"black"`)) || snapshot.Players[0].Color != ColorWhite || snapshot.Players[1].Color != ColorBlack {
		t.Fatalf("event/snapshot=%+v %+v", event, snapshot)
	}
}

func TestApplyActionIdempotencyUsesCanonicalRequestSemanticsAndDefensiveCopies(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	request := moveRequest(created.ID, initiatorID, 10, 0, 3, 4)
	first, firstSnapshot, err := service.ApplyAction(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	request.ExpectedRevision = 0 // a committed action wins over stale validation
	request.Payload = json.RawMessage("{ \"y\" : 4, \"x\" : 3 }")
	retry, retrySnapshot, err := service.ApplyAction(context.Background(), request)
	if err != nil {
		t.Fatalf("idempotent retry: %v", err)
	}
	if !reflect.DeepEqual(first, retry) || !reflect.DeepEqual(firstSnapshot, retrySnapshot) {
		t.Fatalf("retry differs:\n%+v\n%+v\n%+v\n%+v", first, retry, firstSnapshot, retrySnapshot)
	}
	first.Payload[0] = '!'
	firstSnapshot.Game.State[0] = '!'
	retryAgain, snapshotAgain, err := service.ApplyAction(context.Background(), request)
	if err != nil || retryAgain.Payload[0] != '{' || snapshotAgain.Game.State[0] != '{' {
		t.Fatalf("stored result aliased caller bytes: event=%s snapshot=%s err=%v", retryAgain.Payload, snapshotAgain.Game.State, err)
	}

	conflicts := []ActionRequest{
		moveRequest(created.ID, initiatorID, 10, 1, 4, 4),
		{MatchID: created.ID, ActorUserID: initiatorID, ActionID: actionID(10), ExpectedRevision: 1, Type: protocol.TypeGomokuResignRequested, Payload: json.RawMessage(`{}`)},
	}
	for _, conflict := range conflicts {
		event, snapshot, err := service.ApplyAction(context.Background(), conflict)
		if !errors.Is(err, ErrActionConflict) || event.MatchID != "" || snapshot.Match.ID != "" || err.Error() != ErrActionConflict.Error() {
			t.Fatalf("conflict=(%+v,%+v,%v)", event, snapshot, err)
		}
	}
	assertTableCount(t, fixture.db, "match_events", 1)
}

func TestApplyActionConflictPrecedesUnrelatedHistoryAndSlotValidation(t *testing.T) {
	t.Run("different move ignores corrupt subsequent history", func(t *testing.T) {
		fixture := newFixture(t)
		service := fixture.service(t, bytes.NewReader([]byte{0}))
		created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		committed := moveRequest(created.ID, initiatorID, 30, 0, 1, 1)
		if _, _, err := service.ApplyAction(context.Background(), committed); err != nil {
			t.Fatal(err)
		}
		if _, _, err := service.ApplyAction(context.Background(), moveRequest(created.ID, opponentID, 31, 1, 2, 2)); err != nil {
			t.Fatal(err)
		}
		if _, err := fixture.db.Exec(`UPDATE match_events SET payload_json='{' WHERE match_id=? AND revision=2`, created.ID); err != nil {
			t.Fatal(err)
		}
		committed.Payload = json.RawMessage(`{"x":3,"y":3}`)
		assertActionConflict(t, service, committed)
	})

	t.Run("different move ignores corrupt preceding history", func(t *testing.T) {
		fixture := newFixture(t)
		service := fixture.service(t, bytes.NewReader([]byte{0}))
		created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		if _, _, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 32, 0, 1, 1)); err != nil {
			t.Fatal(err)
		}
		committed := moveRequest(created.ID, opponentID, 33, 1, 2, 2)
		if _, _, err := service.ApplyAction(context.Background(), committed); err != nil {
			t.Fatal(err)
		}
		if _, err := fixture.db.Exec(`UPDATE match_events SET payload_json='{' WHERE match_id=? AND revision=1`, created.ID); err != nil {
			t.Fatal(err)
		}
		committed.Payload = json.RawMessage(`{"x":4,"y":4}`)
		assertActionConflict(t, service, committed)
	})

	t.Run("different type ignores corrupt active slots", func(t *testing.T) {
		fixture := newFixture(t)
		service := fixture.service(t, bytes.NewReader([]byte{0}))
		created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		committed := moveRequest(created.ID, initiatorID, 34, 0, 1, 1)
		if _, _, err := service.ApplyAction(context.Background(), committed); err != nil {
			t.Fatal(err)
		}
		if _, err := fixture.db.Exec(`DELETE FROM active_game_slots WHERE game_id=? AND user_id=?`, gomoku.GameID, opponentID); err != nil {
			t.Fatal(err)
		}
		conflict := resignRequest(created.ID, initiatorID, 34, 0)
		assertActionConflict(t, service, conflict)
	})

	t.Run("different move ignores corrupt slots after resignation", func(t *testing.T) {
		fixture := newFixture(t)
		service := fixture.service(t, bytes.NewReader([]byte{0}))
		created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		if _, _, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 35, 0, 1, 1)); err != nil {
			t.Fatal(err)
		}
		committed := resignRequest(created.ID, opponentID, 36, 1)
		if _, _, err := service.ApplyAction(context.Background(), committed); err != nil {
			t.Fatal(err)
		}
		if _, err := fixture.db.Exec(`INSERT INTO active_game_slots(game_id,user_id,match_id) VALUES (?,?,?)`, gomoku.GameID, opponentID, created.ID); err != nil {
			t.Fatal(err)
		}
		conflict := moveRequest(created.ID, opponentID, 36, 0, 4, 4)
		assertActionConflict(t, service, conflict)
	})
}

func TestApplyActionSameSemanticsStillFailsClosedOnCorruptHistoryOrSlots(t *testing.T) {
	tests := []struct {
		name    string
		corrupt func(*testing.T, fixture, string)
	}{
		{name: "history", corrupt: func(t *testing.T, fixture fixture, matchID string) {
			if _, err := fixture.db.Exec(`UPDATE match_events SET payload_json='{' WHERE match_id=?`, matchID); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "slots", corrupt: func(t *testing.T, fixture fixture, matchID string) {
			if _, err := fixture.db.Exec(`DELETE FROM active_game_slots WHERE game_id=? AND user_id=?`, gomoku.GameID, opponentID); err != nil {
				t.Fatal(err)
			}
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newFixture(t)
			service := fixture.service(t, bytes.NewReader([]byte{0}))
			created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatal(err)
			}
			committed := moveRequest(created.ID, initiatorID, 37, 0, 1, 1)
			if _, _, err := service.ApplyAction(context.Background(), committed); err != nil {
				t.Fatal(err)
			}
			test.corrupt(t, fixture, created.ID)
			event, snapshot, err := service.ApplyAction(context.Background(), committed)
			if !errors.Is(err, ErrInternal) || event.MatchID != "" || snapshot.Match.ID != "" || err.Error() != ErrInternal.Error() {
				t.Fatalf("same semantic retry=(%+v,%+v,%v), want zero/internal", event, snapshot, err)
			}
		})
	}
}

func assertActionConflict(t *testing.T, service *Service, request ActionRequest) {
	t.Helper()
	event, snapshot, err := service.ApplyAction(context.Background(), request)
	if !errors.Is(err, ErrActionConflict) || event.MatchID != "" || snapshot.Match.ID != "" || err.Error() != ErrActionConflict.Error() {
		t.Fatalf("ApplyAction=(%+v,%+v,%v), want zero/action conflict", event, snapshot, err)
	}
}

func TestSnapshotRebuildsMovesAndFailsClosedOnCorruptHistory(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 20, 0, 2, 2)); err != nil {
		t.Fatal(err)
	}
	got, err := service.Snapshot(context.Background(), created.ID)
	if err != nil {
		t.Fatalf("Snapshot: %v", err)
	}
	if got.Match.ID != created.ID || got.Match.Revision != 1 || got.Game.Revision != 1 || len(got.Players) != 2 || got.Players[0].Color != ColorBlack || got.Players[1].Color != ColorWhite {
		t.Fatalf("snapshot=%+v", got)
	}
	got.Game.State[0] = '!'
	again, err := service.Snapshot(context.Background(), created.ID)
	if err != nil || again.Game.State[0] != '{' {
		t.Fatalf("snapshot aliases storage: %s %v", again.Game.State, err)
	}

	corruptions := []struct {
		name string
		sql  string
		args []any
	}{
		{name: "revision gap", sql: `UPDATE match_events SET revision=2 WHERE match_id=?`, args: []any{created.ID}},
		{name: "wrong actor", sql: `UPDATE match_events SET actor_user_id=? WHERE match_id=?`, args: []any{opponentID, created.ID}},
		{name: "wrong color", sql: `UPDATE match_events SET payload_json=replace(payload_json,'"black"','"white"') WHERE match_id=?`, args: []any{created.ID}},
		{name: "match revision", sql: `UPDATE matches SET revision=2 WHERE id=?`, args: []any{created.ID}},
	}
	for _, corruption := range corruptions {
		t.Run(corruption.name, func(t *testing.T) {
			local := newFixture(t)
			localService := local.service(t, bytes.NewReader([]byte{0}))
			match, err := localService.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatal(err)
			}
			if _, _, err := localService.ApplyAction(context.Background(), moveRequest(match.ID, initiatorID, 21, 0, 2, 2)); err != nil {
				t.Fatal(err)
			}
			args := append([]any(nil), corruption.args...)
			for index, value := range args {
				if value == created.ID {
					args[index] = match.ID
				}
			}
			if _, err := local.db.Exec(corruption.sql, args...); err != nil {
				t.Fatalf("corrupt: %v", err)
			}
			got, err := localService.Snapshot(context.Background(), match.ID)
			if !errors.Is(err, ErrInternal) || got.Match.ID != "" || err.Error() != ErrInternal.Error() {
				t.Fatalf("Snapshot=(%+v,%v), want zero internal", got, err)
			}
		})
	}
}

func TestApplyActionFiveAndResignationFinishAtomicallyAndReleaseSlots(t *testing.T) {
	t.Run("five", func(t *testing.T) {
		fixture := newFixture(t)
		service := fixture.service(t, bytes.NewReader([]byte{0}))
		created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		moves := [][2]int{{0, 0}, {0, 1}, {1, 0}, {1, 1}, {2, 0}, {2, 1}, {3, 0}, {3, 1}, {4, 0}}
		var event Event
		var snapshot Snapshot
		for index, point := range moves {
			actor := initiatorID
			if index%2 == 1 {
				actor = opponentID
			}
			event, snapshot, err = service.ApplyAction(context.Background(), moveRequest(created.ID, actor, 100+index, int64(index), point[0], point[1]))
			if err != nil {
				t.Fatalf("move %d: %v", index, err)
			}
		}
		if event.Revision != 9 || snapshot.Match.Status != StatusFinished || !stringPointerEquals(snapshot.Match.Result, ResultFive) || !stringPointerEquals(snapshot.Match.WinnerUserID, initiatorID) || snapshot.Match.FinishedAt == nil {
			t.Fatalf("five terminal=%+v event=%+v", snapshot.Match, event)
		}
		assertTableCount(t, fixture.db, "active_game_slots", 0)
	})

	t.Run("resignation only after first move", func(t *testing.T) {
		fixture := newFixture(t)
		service := fixture.service(t, bytes.NewReader([]byte{0}))
		created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		resign := resignRequest(created.ID, opponentID, 200, 0)
		if event, snapshot, err := service.ApplyAction(context.Background(), resign); !errors.Is(err, ErrInvalidRequest) || event.MatchID != "" || snapshot.Match.ID != "" {
			t.Fatalf("zero move resignation=(%+v,%+v,%v)", event, snapshot, err)
		}
		if _, _, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 201, 0, 7, 7)); err != nil {
			t.Fatal(err)
		}
		resign.ExpectedRevision = 1
		resign.ActionID = actionID(202)
		event, snapshot, err := service.ApplyAction(context.Background(), resign)
		if err != nil {
			t.Fatal(err)
		}
		if event.Type != protocol.TypeGomokuResigned || event.Revision != 2 || snapshot.Match.Status != StatusFinished || !stringPointerEquals(snapshot.Match.Result, ResultResignation) || !stringPointerEquals(snapshot.Match.WinnerUserID, initiatorID) {
			t.Fatalf("resignation=%+v %+v", event, snapshot.Match)
		}
		want := fmt.Sprintf(`{"userId":%q,"winnerUserId":%q}`, opponentID, initiatorID)
		if string(event.Payload) != want {
			t.Fatalf("resignation payload=%s want=%s", event.Payload, want)
		}
		assertTableCount(t, fixture.db, "active_game_slots", 0)
	})
}

func TestApplyActionEitherPlayerCanResignAndRetryCommittedResult(t *testing.T) {
	for _, resigner := range []string{initiatorID, opponentID} {
		t.Run(resigner, func(t *testing.T) {
			fixture := newFixture(t)
			service := fixture.service(t, bytes.NewReader([]byte{0}))
			created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatal(err)
			}
			if _, _, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 250, 0, 7, 7)); err != nil {
				t.Fatal(err)
			}
			request := resignRequest(created.ID, resigner, 251, 1)
			first, firstSnapshot, err := service.ApplyAction(context.Background(), request)
			if err != nil {
				t.Fatal(err)
			}
			winner := opponentID
			if resigner == opponentID {
				winner = initiatorID
			}
			if !stringPointerEquals(firstSnapshot.Match.WinnerUserID, winner) || !stringPointerEquals(firstSnapshot.Match.Result, ResultResignation) {
				t.Fatalf("resignation winner=%+v", firstSnapshot.Match)
			}
			request.ExpectedRevision = 0
			request.Payload = json.RawMessage(" { } ")
			retry, retrySnapshot, err := service.ApplyAction(context.Background(), request)
			if err != nil || !reflect.DeepEqual(first, retry) || !reflect.DeepEqual(firstSnapshot, retrySnapshot) {
				t.Fatalf("resign retry=(%+v,%+v,%v), first=(%+v,%+v)", retry, retrySnapshot, err, first, firstSnapshot)
			}
			assertTableCount(t, fixture.db, "match_events", 2)
		})
	}
}

func TestApplyActionFullBoardDrawStress(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	var black, white [][2]int
	for y := 0; y < 15; y++ {
		for x := 0; x < 15; x++ {
			if (x+2*y)%4 < 2 {
				black = append(black, [2]int{x, y})
			} else {
				white = append(white, [2]int{x, y})
			}
		}
	}
	for revision := 0; revision < 225; revision++ {
		actor, point := initiatorID, black[revision/2]
		if revision%2 == 1 {
			actor, point = opponentID, white[revision/2]
		}
		_, snapshot, err := service.ApplyAction(context.Background(), moveRequest(created.ID, actor, 1000+revision, int64(revision), point[0], point[1]))
		if err != nil {
			t.Fatalf("draw move %d: %v", revision+1, err)
		}
		if revision == 224 && (snapshot.Match.Status != StatusFinished || !stringPointerEquals(snapshot.Match.Result, ResultDraw) || snapshot.Match.WinnerUserID != nil) {
			t.Fatalf("draw terminal=%+v", snapshot.Match)
		}
	}
	assertTableCount(t, fixture.db, "match_events", 225)
	assertTableCount(t, fixture.db, "active_game_slots", 0)
}

func TestApplyActionConcurrentSameAndDifferentActions(t *testing.T) {
	t.Run("same action is one durable event and two successes", func(t *testing.T) {
		fixture := newFixture(t)
		service := fixture.service(t, bytes.NewReader([]byte{0}))
		created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		request := moveRequest(created.ID, initiatorID, 300, 0, 1, 1)
		results := runConcurrentActions(service, request, request)
		for _, result := range results {
			if result.err != nil || result.event.Revision != 1 || result.snapshot.Match.Revision != 1 {
				t.Fatalf("same action result=%+v", result)
			}
		}
		assertTableCount(t, fixture.db, "match_events", 1)
	})

	t.Run("different actions have one winner and one stale", func(t *testing.T) {
		fixture := newFixture(t)
		service := fixture.service(t, bytes.NewReader([]byte{0}))
		created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		results := runConcurrentActions(service,
			moveRequest(created.ID, initiatorID, 301, 0, 1, 1),
			moveRequest(created.ID, initiatorID, 302, 0, 2, 2),
		)
		successes, stale := 0, 0
		for _, result := range results {
			if result.err == nil {
				successes++
			} else if errors.Is(result.err, ErrStaleRevision) && result.event.MatchID == "" && result.snapshot.Match.ID == "" {
				stale++
			} else {
				t.Fatalf("different action result=%+v", result)
			}
		}
		if successes != 1 || stale != 1 {
			t.Fatalf("successes=%d stale=%d", successes, stale)
		}
		assertTableCount(t, fixture.db, "match_events", 1)
	})
}

func TestApplyActionWriteFailuresRollbackWithoutBroadcastEvent(t *testing.T) {
	tests := []struct {
		name    string
		trigger string
	}{
		{name: "event insert", trigger: `CREATE TRIGGER fail_action_event BEFORE INSERT ON match_events BEGIN SELECT RAISE(ABORT,'event'); END`},
		{name: "match cas", trigger: `CREATE TRIGGER fail_action_match BEFORE UPDATE ON matches BEGIN SELECT RAISE(ABORT,'match'); END`},
		{name: "terminal match cas", trigger: `CREATE TRIGGER fail_terminal_match BEFORE UPDATE ON matches WHEN NEW.status='finished' BEGIN SELECT RAISE(ABORT,'terminal'); END`},
		{name: "terminal slot delete", trigger: `CREATE TRIGGER fail_action_slot BEFORE DELETE ON active_game_slots BEGIN SELECT RAISE(ABORT,'slot'); END`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newFixture(t)
			service := fixture.service(t, bytes.NewReader([]byte{0}))
			created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatal(err)
			}
			if strings.HasPrefix(test.name, "terminal") {
				for index, point := range [][2]int{{0, 0}, {0, 1}, {1, 0}, {1, 1}, {2, 0}, {2, 1}, {3, 0}, {3, 1}} {
					actor := initiatorID
					if index%2 == 1 {
						actor = opponentID
					}
					if _, _, err := service.ApplyAction(context.Background(), moveRequest(created.ID, actor, 400+index, int64(index), point[0], point[1])); err != nil {
						t.Fatal(err)
					}
				}
			}
			if _, err := fixture.db.Exec(test.trigger); err != nil {
				t.Fatal(err)
			}
			beforeEvents := tableCount(t, fixture.db, "match_events")
			beforeRevision := int64(beforeEvents)
			action := moveRequest(created.ID, initiatorID, 499, beforeRevision, 4, 0)
			if beforeRevision%2 == 1 {
				action.ActorUserID = opponentID
			}
			event, snapshot, err := service.ApplyAction(context.Background(), action)
			if !errors.Is(err, ErrInternal) || event.MatchID != "" || snapshot.Match.ID != "" || err.Error() != ErrInternal.Error() {
				t.Fatalf("ApplyAction=(%+v,%+v,%v), want no broadcast/internal", event, snapshot, err)
			}
			if got := tableCount(t, fixture.db, "match_events"); got != beforeEvents {
				t.Fatalf("event count=%d want rollback to %d", got, beforeEvents)
			}
			var revision int64
			if err := fixture.db.QueryRow(`SELECT revision FROM matches WHERE id=?`, created.ID).Scan(&revision); err != nil || revision != beforeRevision {
				t.Fatalf("match revision=%d err=%v want=%d", revision, err, beforeRevision)
			}
		})
	}
}

func TestApplyActionRejectsMalformedEnvelopeAndPayloadWithoutWrites(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	valid := moveRequest(created.ID, initiatorID, 600, 0, 1, 2)
	tests := []struct {
		name   string
		mutate func(*ActionRequest)
	}{
		{name: "negative revision", mutate: func(request *ActionRequest) { request.ExpectedRevision = -1 }},
		{name: "uppercase action id", mutate: func(request *ActionRequest) { request.ActionID = strings.ToUpper(request.ActionID) }},
		{name: "non canonical action id", mutate: func(request *ActionRequest) { request.ActionID = strings.ReplaceAll(request.ActionID, "-", "") }},
		{name: "unknown type", mutate: func(request *ActionRequest) { request.Type = "gomoku.move.maybe" }},
		{name: "missing coordinate", mutate: func(request *ActionRequest) { request.Payload = json.RawMessage(`{"x":1}`) }},
		{name: "unknown field", mutate: func(request *ActionRequest) { request.Payload = json.RawMessage(`{"x":1,"y":2,"z":3}`) }},
		{name: "duplicate field", mutate: func(request *ActionRequest) { request.Payload = json.RawMessage(`{"x":1,"x":1,"y":2}`) }},
		{name: "fractional coordinate", mutate: func(request *ActionRequest) { request.Payload = json.RawMessage(`{"x":1.0,"y":2}`) }},
		{name: "oversize payload", mutate: func(request *ActionRequest) {
			request.Payload = json.RawMessage(`{"x":1,"y":2,"padding":"` + strings.Repeat("x", 1024) + `"}`)
		}},
		{name: "resign payload not empty", mutate: func(request *ActionRequest) {
			request.Type = protocol.TypeGomokuResignRequested
			request.Payload = json.RawMessage(`{"confirm":true}`)
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := valid
			request.Payload = append(json.RawMessage(nil), valid.Payload...)
			test.mutate(&request)
			event, snapshot, err := service.ApplyAction(context.Background(), request)
			if !errors.Is(err, ErrInvalidRequest) || event.MatchID != "" || snapshot.Match.ID != "" || err.Error() != ErrInvalidRequest.Error() {
				t.Fatalf("ApplyAction=(%+v,%+v,%v), want invalid request", event, snapshot, err)
			}
		})
	}
	assertTableCount(t, fixture.db, "match_events", 0)
}

func TestSnapshotComposesPlatformCancellationWithoutFeedingItToRules(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.Cancel(context.Background(), created.ID, initiatorID); err != nil {
		t.Fatal(err)
	}
	snapshot, err := service.Snapshot(context.Background(), created.ID)
	if err != nil {
		t.Fatalf("Snapshot cancelled: %v", err)
	}
	if snapshot.Match.Status != StatusCancelled || snapshot.Match.Revision != 1 || snapshot.Match.FinishedAt == nil || snapshot.Match.Result != nil || snapshot.Match.WinnerUserID != nil || snapshot.Game.Revision != 0 {
		t.Fatalf("cancelled snapshot=%+v", snapshot)
	}
	var state struct {
		Status string `json:"status"`
	}
	if err := json.Unmarshal(snapshot.Game.State, &state); err != nil || state.Status != StatusActive {
		t.Fatalf("cancelled game state=%s err=%v", snapshot.Game.State, err)
	}
}

func TestApplyActionTerminalSlotCorruptionFailsBeforeEventInsert(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	for index, point := range [][2]int{{0, 0}, {0, 1}, {1, 0}, {1, 1}, {2, 0}, {2, 1}, {3, 0}, {3, 1}} {
		actor := initiatorID
		if index%2 == 1 {
			actor = opponentID
		}
		if _, _, err := service.ApplyAction(context.Background(), moveRequest(created.ID, actor, 700+index, int64(index), point[0], point[1])); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := fixture.db.Exec(`DELETE FROM active_game_slots WHERE game_id=? AND user_id=?`, gomoku.GameID, opponentID); err != nil {
		t.Fatal(err)
	}
	event, snapshot, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 799, 8, 4, 0))
	if !errors.Is(err, ErrInternal) || event.MatchID != "" || snapshot.Match.ID != "" {
		t.Fatalf("terminal with corrupt slot=(%+v,%+v,%v)", event, snapshot, err)
	}
	assertTableCount(t, fixture.db, "match_events", 8)
	var status string
	var revision int64
	if err := fixture.db.QueryRow(`SELECT status,revision FROM matches WHERE id=?`, created.ID).Scan(&status, &revision); err != nil || status != StatusActive || revision != 8 {
		t.Fatalf("match=(%s,%d,%v)", status, revision, err)
	}
}

func TestSnapshotAndNonTerminalActionFailClosedOnActiveSlotCorruption(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := fixture.db.Exec(`DELETE FROM active_game_slots WHERE game_id=? AND user_id=?`, gomoku.GameID, opponentID); err != nil {
		t.Fatal(err)
	}
	if snapshot, err := service.Snapshot(context.Background(), created.ID); !errors.Is(err, ErrInternal) || snapshot.Match.ID != "" {
		t.Fatalf("Snapshot=(%+v,%v), want zero/internal", snapshot, err)
	}
	event, snapshot, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 798, 0, 4, 4))
	if !errors.Is(err, ErrInternal) || event.MatchID != "" || snapshot.Match.ID != "" {
		t.Fatalf("ApplyAction=(%+v,%+v,%v), want zero/internal", event, snapshot, err)
	}
	assertTableCount(t, fixture.db, "match_events", 0)
}

func TestApplyActionCommitFailureRollsBackAndReturnsNoBroadcastEvent(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := fixture.db.Exec(`
CREATE TRIGGER fail_action_at_commit AFTER INSERT ON match_events
BEGIN
  INSERT INTO launch_tickets(token_hash,match_id,user_id,game_id,expires_at,created_at)
  VALUES ('deferred-commit-failure','ffffffff-ffff-4fff-8fff-ffffffffffff','11111111-1111-4111-8111-111111111111','gomoku',1,1);
END`); err != nil {
		t.Fatal(err)
	}
	fixture.db.SetMaxOpenConns(1)
	connection, err := fixture.db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := connection.ExecContext(context.Background(), `PRAGMA defer_foreign_keys=ON`); err != nil {
		connection.Close()
		t.Fatal(err)
	}
	if err := connection.Close(); err != nil {
		t.Fatal(err)
	}

	event, snapshot, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 800, 0, 1, 1))
	if !errors.Is(err, ErrInternal) || event.MatchID != "" || snapshot.Match.ID != "" || err.Error() != ErrInternal.Error() {
		t.Fatalf("commit failure=(%+v,%+v,%v), want zero/internal", event, snapshot, err)
	}
	assertTableCount(t, fixture.db, "match_events", 0)
	assertTableCount(t, fixture.db, "active_game_slots", 2)
	var revision int64
	if err := fixture.db.QueryRow(`SELECT revision FROM matches WHERE id=?`, created.ID).Scan(&revision); err != nil || revision != 0 {
		t.Fatalf("revision=%d err=%v", revision, err)
	}
	assertTableCount(t, fixture.db, "launch_tickets", 0)
}

func TestSnapshotRejectsRevisionOverflowAndCorruptActionIdentity(t *testing.T) {
	tests := []struct {
		name  string
		setup func(*testing.T, fixture, string)
	}{
		{name: "revision overflow", setup: func(t *testing.T, fixture fixture, matchID string) {
			if _, err := fixture.db.Exec(`UPDATE matches SET revision=? WHERE id=?`, int64(^uint64(0)>>1), matchID); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "non canonical stored action id", setup: func(t *testing.T, fixture fixture, matchID string) {
			if _, err := fixture.db.Exec(`UPDATE match_events SET action_id=upper(action_id) WHERE match_id=?`, matchID); err != nil {
				t.Fatal(err)
			}
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newFixture(t)
			service := fixture.service(t, bytes.NewReader([]byte{0}))
			created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatal(err)
			}
			if test.name != "revision overflow" {
				if _, _, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 900, 0, 1, 1)); err != nil {
					t.Fatal(err)
				}
			}
			test.setup(t, fixture, created.ID)
			snapshot, err := service.Snapshot(context.Background(), created.ID)
			if !errors.Is(err, ErrInternal) || snapshot.Match.ID != "" || err.Error() != ErrInternal.Error() {
				t.Fatalf("Snapshot=(%+v,%v), want zero/internal", snapshot, err)
			}
		})
	}
}

func TestSnapshotRejectsDuplicateMoveAndLifecycleMetadataCorruption(t *testing.T) {
	tests := []struct {
		name  string
		setup func(*testing.T, fixture, string)
	}{
		{name: "duplicate occupied move", setup: func(t *testing.T, fixture fixture, matchID string) {
			payload := fmt.Sprintf(`{"x":1,"y":1,"color":"white","userId":%q}`, opponentID)
			if _, err := fixture.db.Exec(`
INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at)
VALUES (?,2,?,?,?,?,?)`, matchID, gomoku.MoveAccepted, actionID(902), opponentID, payload, fixture.now.UnixMilli()); err != nil {
				t.Fatal(err)
			}
			if _, err := fixture.db.Exec(`UPDATE matches SET revision=2 WHERE id=?`, matchID); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "terminal metadata disagrees with rules", setup: func(t *testing.T, fixture fixture, matchID string) {
			if _, err := fixture.db.Exec(`UPDATE matches SET status='finished',result='draw',finished_at=updated_at WHERE id=?`, matchID); err != nil {
				t.Fatal(err)
			}
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newFixture(t)
			service := fixture.service(t, bytes.NewReader([]byte{0}))
			created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatal(err)
			}
			if _, _, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 901, 0, 1, 1)); err != nil {
				t.Fatal(err)
			}
			test.setup(t, fixture, created.ID)
			snapshot, err := service.Snapshot(context.Background(), created.ID)
			if !errors.Is(err, ErrInternal) || snapshot.Match.ID != "" || err.Error() != ErrInternal.Error() {
				t.Fatalf("Snapshot=(%+v,%v), want zero/internal", snapshot, err)
			}
		})
	}
}

func TestMatchLifecyclePersistsAndReturnsUTCUnixMilliseconds(t *testing.T) {
	t.Run("create and active action", func(t *testing.T) {
		fixture := newFixture(t)
		service := fixture.service(t, bytes.NewReader([]byte{0}))
		created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		wantCreate := time.UnixMilli(fixture.now.UTC().UnixMilli()).UTC()
		if !created.CreatedAt.Equal(wantCreate) || !created.UpdatedAt.Equal(wantCreate) {
			t.Fatalf("create returned times=%v/%v want=%v", created.CreatedAt, created.UpdatedAt, wantCreate)
		}
		var createdAt, updatedAt int64
		if err := fixture.db.QueryRow(`SELECT created_at,updated_at FROM matches WHERE id=?`, created.ID).Scan(&createdAt, &updatedAt); err != nil {
			t.Fatal(err)
		}
		if createdAt != fixture.now.UTC().UnixMilli() || updatedAt != fixture.now.UTC().UnixMilli() {
			t.Fatalf("create stored milliseconds=%d/%d want=%d", createdAt, updatedAt, fixture.now.UTC().UnixMilli())
		}

		fixture.clock.Advance(1234*time.Millisecond + 567*time.Microsecond)
		request := moveRequest(created.ID, initiatorID, 950, 0, 5, 5)
		event, snapshot, err := service.ApplyAction(context.Background(), request)
		if err != nil {
			t.Fatal(err)
		}
		wantAction := time.UnixMilli(fixture.clock.Now().UTC().UnixMilli()).UTC()
		if !event.CreatedAt.Equal(wantAction) || !snapshot.Match.UpdatedAt.Equal(wantAction) {
			t.Fatalf("active action returned times=%v/%v want=%v", event.CreatedAt, snapshot.Match.UpdatedAt, wantAction)
		}
		var eventCreatedAt int64
		if err := fixture.db.QueryRow(`SELECT created_at FROM match_events WHERE match_id=? AND revision=1`, created.ID).Scan(&eventCreatedAt); err != nil {
			t.Fatal(err)
		}
		if err := fixture.db.QueryRow(`SELECT updated_at FROM matches WHERE id=?`, created.ID).Scan(&updatedAt); err != nil {
			t.Fatal(err)
		}
		if eventCreatedAt != fixture.clock.Now().UTC().UnixMilli() || updatedAt != fixture.clock.Now().UTC().UnixMilli() {
			t.Fatalf("active action stored milliseconds=%d/%d want=%d", eventCreatedAt, updatedAt, fixture.clock.Now().UTC().UnixMilli())
		}
		request.ExpectedRevision = 0
		retry, reloaded, err := service.ApplyAction(context.Background(), request)
		if err != nil || !retry.CreatedAt.Equal(wantAction) || !reloaded.Match.CreatedAt.Equal(wantCreate) || !reloaded.Match.UpdatedAt.Equal(wantAction) {
			t.Fatalf("idempotent read times event=%v created=%v updated=%v err=%v", retry.CreatedAt, reloaded.Match.CreatedAt, reloaded.Match.UpdatedAt, err)
		}
	})

	t.Run("terminal action", func(t *testing.T) {
		fixture := newFixture(t)
		service := fixture.service(t, bytes.NewReader([]byte{0}))
		created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		for index, point := range [][2]int{{0, 0}, {0, 1}, {1, 0}, {1, 1}, {2, 0}, {2, 1}, {3, 0}, {3, 1}} {
			actor := initiatorID
			if index%2 == 1 {
				actor = opponentID
			}
			if _, _, err := service.ApplyAction(context.Background(), moveRequest(created.ID, actor, 960+index, int64(index), point[0], point[1])); err != nil {
				t.Fatal(err)
			}
		}
		fixture.clock.Advance(2345*time.Millisecond + 678*time.Microsecond)
		event, snapshot, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 969, 8, 4, 0))
		if err != nil {
			t.Fatal(err)
		}
		want := time.UnixMilli(fixture.clock.Now().UTC().UnixMilli()).UTC()
		if !event.CreatedAt.Equal(want) || !snapshot.Match.UpdatedAt.Equal(want) || snapshot.Match.FinishedAt == nil || !snapshot.Match.FinishedAt.Equal(want) {
			t.Fatalf("terminal returned times event=%v updated=%v finished=%v want=%v", event.CreatedAt, snapshot.Match.UpdatedAt, snapshot.Match.FinishedAt, want)
		}
		var eventCreatedAt, updatedAt, finishedAt int64
		if err := fixture.db.QueryRow(`SELECT created_at FROM match_events WHERE match_id=? AND revision=9`, created.ID).Scan(&eventCreatedAt); err != nil {
			t.Fatal(err)
		}
		if err := fixture.db.QueryRow(`SELECT updated_at,finished_at FROM matches WHERE id=?`, created.ID).Scan(&updatedAt, &finishedAt); err != nil {
			t.Fatal(err)
		}
		wantMillis := fixture.clock.Now().UTC().UnixMilli()
		if eventCreatedAt != wantMillis || updatedAt != wantMillis || finishedAt != wantMillis {
			t.Fatalf("terminal stored milliseconds=%d/%d/%d want=%d", eventCreatedAt, updatedAt, finishedAt, wantMillis)
		}
		reloaded, err := service.Snapshot(context.Background(), created.ID)
		if err != nil || !reloaded.Match.UpdatedAt.Equal(want) || reloaded.Match.FinishedAt == nil || !reloaded.Match.FinishedAt.Equal(want) {
			t.Fatalf("terminal reloaded times updated=%v finished=%v err=%v", reloaded.Match.UpdatedAt, reloaded.Match.FinishedAt, err)
		}
	})

	t.Run("cancel", func(t *testing.T) {
		fixture := newFixture(t)
		service := fixture.service(t, bytes.NewReader([]byte{0}))
		created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		fixture.clock.Advance(3456*time.Millisecond + 789*time.Microsecond)
		event, err := service.Cancel(context.Background(), created.ID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		want := time.UnixMilli(fixture.clock.Now().UTC().UnixMilli()).UTC()
		if !event.CreatedAt.Equal(want) {
			t.Fatalf("cancel returned event time=%v want=%v", event.CreatedAt, want)
		}
		var eventCreatedAt, updatedAt, finishedAt int64
		if err := fixture.db.QueryRow(`SELECT created_at FROM match_events WHERE match_id=? AND revision=1`, created.ID).Scan(&eventCreatedAt); err != nil {
			t.Fatal(err)
		}
		if err := fixture.db.QueryRow(`SELECT updated_at,finished_at FROM matches WHERE id=?`, created.ID).Scan(&updatedAt, &finishedAt); err != nil {
			t.Fatal(err)
		}
		wantMillis := fixture.clock.Now().UTC().UnixMilli()
		if eventCreatedAt != wantMillis || updatedAt != wantMillis || finishedAt != wantMillis {
			t.Fatalf("cancel stored milliseconds=%d/%d/%d want=%d", eventCreatedAt, updatedAt, finishedAt, wantMillis)
		}
		reloaded, err := service.Snapshot(context.Background(), created.ID)
		if err != nil || !reloaded.Match.UpdatedAt.Equal(want) || reloaded.Match.FinishedAt == nil || !reloaded.Match.FinishedAt.Equal(want) {
			t.Fatalf("cancel reloaded times updated=%v finished=%v err=%v", reloaded.Match.UpdatedAt, reloaded.Match.FinishedAt, err)
		}
	})
}

func TestPresenceServiceStartsOfflineClockOnlyWhenBothPlayersAreOffline(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	presence, err := NewPresence(service, fixture.clock)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	firstConnection := "10000000-0000-4000-8000-000000000001"
	secondConnection := "10000000-0000-4000-8000-000000000002"
	if err := presence.Connect(ctx, created.ID, initiatorID, firstConnection); err != nil {
		t.Fatal(err)
	}
	if err := presence.Connect(ctx, created.ID, opponentID, secondConnection); err != nil {
		t.Fatal(err)
	}
	if err := presence.Disconnect(ctx, created.ID, initiatorID, firstConnection); err != nil {
		t.Fatal(err)
	}
	assertBothOfflineSince(t, fixture.db, created.ID, nil)
	if err := presence.Disconnect(ctx, created.ID, opponentID, secondConnection); err != nil {
		t.Fatal(err)
	}
	wantOffline := fixture.clock.Now().UTC().UnixMilli()
	assertBothOfflineSince(t, fixture.db, created.ID, &wantOffline)

	fixture.clock.Advance(time.Hour)
	if err := service.SetPlayerOffline(ctx, created.ID, initiatorID); err != nil {
		t.Fatal(err)
	}
	assertBothOfflineSince(t, fixture.db, created.ID, &wantOffline)
	if err := presence.Connect(ctx, created.ID, initiatorID, firstConnection); err != nil {
		t.Fatal(err)
	}
	assertBothOfflineSince(t, fixture.db, created.ID, nil)
}

func TestPresenceServiceRechecksMembershipAndActiveLifecycle(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	for _, method := range []func(context.Context, string, string) error{service.SetPlayerOnline, service.SetPlayerOffline} {
		if err := method(context.Background(), created.ID, thirdID); !errors.Is(err, ErrInvalidRequest) || err.Error() != ErrInvalidRequest.Error() {
			t.Fatalf("non-player error=%v", err)
		}
		if err := method(context.Background(), "ffffffff-ffff-4fff-8fff-ffffffffffff", initiatorID); !errors.Is(err, ErrMatchNotFound) || err.Error() != ErrMatchNotFound.Error() {
			t.Fatalf("unknown match error=%v", err)
		}
	}
	if _, err := service.Cancel(context.Background(), created.ID, initiatorID); err != nil {
		t.Fatal(err)
	}
	finishedOffline := fixture.clock.Now().Add(-time.Hour).UnixMilli()
	if _, err := fixture.db.Exec(`UPDATE matches SET both_offline_since=? WHERE id=?`, finishedOffline, created.ID); err != nil {
		t.Fatal(err)
	}
	if err := service.SetPlayerOnline(context.Background(), created.ID, initiatorID); err != nil {
		t.Fatal(err)
	}
	if err := service.SetPlayerOffline(context.Background(), created.ID, opponentID); err != nil {
		t.Fatal(err)
	}
	assertBothOfflineSince(t, fixture.db, created.ID, &finishedOffline)
}

func TestAbandonExpiredUsesExactTwentyFourHourBoundaryAndReturnsCommittedEvent(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.SetPlayerOffline(context.Background(), created.ID, initiatorID); err != nil {
		t.Fatal(err)
	}
	fixture.clock.Advance(24*time.Hour - time.Second)
	if events, err := service.AbandonExpired(context.Background()); err != nil || len(events) != 0 {
		t.Fatalf("before boundary=(%+v,%v)", events, err)
	}
	assertTableCount(t, fixture.db, "active_game_slots", 2)
	fixture.clock.Advance(time.Second)
	events, err := service.AbandonExpired(context.Background())
	if err != nil || len(events) != 1 {
		t.Fatalf("at boundary=(%+v,%v)", events, err)
	}
	event := events[0]
	wantTime := time.UnixMilli(fixture.clock.Now().UTC().UnixMilli()).UTC()
	if event.MatchID != created.ID || event.Revision != 1 || event.Type != protocol.TypePlatformMatchAbandoned || event.ActionID != nil || event.ActorUserID != nil || string(event.Payload) != `{}` || !event.CreatedAt.Equal(wantTime) {
		t.Fatalf("event=%+v want committed abandonment at %v", event, wantTime)
	}
	assertTableCount(t, fixture.db, "active_game_slots", 0)
	snapshot, err := service.Snapshot(context.Background(), created.ID)
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.Match.Status != StatusAbandoned || snapshot.Match.Revision != 1 || snapshot.Match.Result != nil || snapshot.Match.WinnerUserID != nil || snapshot.Match.FinishedAt == nil || !snapshot.Match.FinishedAt.Equal(wantTime) || !snapshot.Match.UpdatedAt.Equal(wantTime) || snapshot.Game.Revision != 0 {
		t.Fatalf("abandoned snapshot=%+v", snapshot)
	}
	assertBothOfflineSince(t, fixture.db, created.ID, nil)
	if again, err := service.AbandonExpired(context.Background()); err != nil || len(again) != 0 {
		t.Fatalf("repeat abandonment=(%+v,%v)", again, err)
	}
}

func TestAbandonExpiredPreservesGameHistoryAndAdvancesMatchRevision(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 980, 0, 7, 7)); err != nil {
		t.Fatal(err)
	}
	if err := service.SetPlayerOffline(context.Background(), created.ID, opponentID); err != nil {
		t.Fatal(err)
	}
	fixture.clock.Advance(24 * time.Hour)
	events, err := service.AbandonExpired(context.Background())
	if err != nil || len(events) != 1 || events[0].Revision != 2 {
		t.Fatalf("AbandonExpired=(%+v,%v)", events, err)
	}
	snapshot, err := service.Snapshot(context.Background(), created.ID)
	if err != nil || snapshot.Match.Revision != 2 || snapshot.Game.Revision != 1 || snapshot.Match.Status != StatusAbandoned {
		t.Fatalf("snapshot=%+v err=%v", snapshot, err)
	}
}

func TestAbandonExpiredLeavesTerminalAndNotYetExpiredMatchesUntouched(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0, 0}))
	terminal, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.Cancel(context.Background(), terminal.ID, initiatorID); err != nil {
		t.Fatal(err)
	}
	if _, err := fixture.db.Exec(`UPDATE matches SET both_offline_since=? WHERE id=?`, fixture.now.Add(-48*time.Hour).UnixMilli(), terminal.ID); err != nil {
		t.Fatal(err)
	}
	active, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.SetPlayerOffline(context.Background(), active.ID, initiatorID); err != nil {
		t.Fatal(err)
	}
	fixture.clock.Advance(24*time.Hour - time.Millisecond)
	if events, err := service.AbandonExpired(context.Background()); err != nil || len(events) != 0 {
		t.Fatalf("AbandonExpired=(%+v,%v)", events, err)
	}
	var terminalStatus string
	var terminalRevision int64
	if err := fixture.db.QueryRow(`SELECT status,revision FROM matches WHERE id=?`, terminal.ID).Scan(&terminalStatus, &terminalRevision); err != nil || terminalStatus != StatusCancelled || terminalRevision != 1 {
		t.Fatalf("terminal=%s/%d err=%v", terminalStatus, terminalRevision, err)
	}
	assertTableCount(t, fixture.db, "active_game_slots", 2)
}

func TestMarkActiveMatchesOfflineOnBootFillsOnlyNullAndPreservesExistingClock(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0, 0}))
	first, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := service.Cancel(context.Background(), first.ID, initiatorID); err != nil {
		t.Fatal(err)
	}
	second, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	existing := fixture.clock.Now().Add(-6 * time.Hour).UTC().UnixMilli()
	if _, err := fixture.db.Exec(`UPDATE matches SET both_offline_since=? WHERE id=?`, existing, second.ID); err != nil {
		t.Fatal(err)
	}
	fixture.clock.Advance(time.Hour)
	if err := service.MarkActiveMatchesOfflineOnBoot(context.Background()); err != nil {
		t.Fatal(err)
	}
	assertBothOfflineSince(t, fixture.db, first.ID, nil)
	assertBothOfflineSince(t, fixture.db, second.ID, &existing)
	thirdFixture := newFixture(t)
	thirdService := thirdFixture.service(t, bytes.NewReader([]byte{0}))
	third, err := thirdService.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	thirdFixture.clock.Advance(1234*time.Millisecond + 567*time.Microsecond)
	if err := thirdService.MarkActiveMatchesOfflineOnBoot(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := thirdFixture.clock.Now().UTC().UnixMilli()
	assertBothOfflineSince(t, thirdFixture.db, third.ID, &want)
}

func TestAbandonExpiredConcurrentScansCommitExactlyOneEvent(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := fixture.db.Exec(`UPDATE matches SET both_offline_since=? WHERE id=?`, fixture.now.Add(-24*time.Hour).UnixMilli(), created.ID); err != nil {
		t.Fatal(err)
	}
	start := make(chan struct{})
	results := make(chan struct {
		events []Event
		err    error
	}, 2)
	for index := 0; index < 2; index++ {
		go func() {
			<-start
			events, err := service.AbandonExpired(context.Background())
			results <- struct {
				events []Event
				err    error
			}{events, err}
		}()
	}
	close(start)
	returned := 0
	for index := 0; index < 2; index++ {
		result := <-results
		if result.err != nil {
			t.Fatalf("concurrent abandon: %v", result.err)
		}
		returned += len(result.events)
	}
	if returned != 1 {
		t.Fatalf("returned events=%d want 1", returned)
	}
	assertTableCount(t, fixture.db, "match_events", 1)
	assertTableCount(t, fixture.db, "active_game_slots", 0)
}

func TestAbandonExpiredCorruptionAndCommitFailureRollbackWithoutPublishableEvent(t *testing.T) {
	t.Run("corrupt slots", func(t *testing.T) {
		fixture := newFixture(t)
		service := fixture.service(t, bytes.NewReader([]byte{0}))
		created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := fixture.db.Exec(`UPDATE matches SET both_offline_since=? WHERE id=?`, fixture.now.Add(-24*time.Hour).UnixMilli(), created.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := fixture.db.Exec(`DELETE FROM active_game_slots WHERE user_id=?`, opponentID); err != nil {
			t.Fatal(err)
		}
		events, err := service.AbandonExpired(context.Background())
		if !errors.Is(err, ErrInternal) || len(events) != 0 || err.Error() != ErrInternal.Error() {
			t.Fatalf("AbandonExpired=(%+v,%v)", events, err)
		}
		assertTableCount(t, fixture.db, "match_events", 0)
		var status string
		var revision int64
		if err := fixture.db.QueryRow(`SELECT status,revision FROM matches WHERE id=?`, created.ID).Scan(&status, &revision); err != nil || status != StatusActive || revision != 0 {
			t.Fatalf("match=%s/%d err=%v", status, revision, err)
		}
	})

	t.Run("deferred commit failure", func(t *testing.T) {
		fixture := newFixture(t)
		service := fixture.service(t, bytes.NewReader([]byte{0}))
		created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := fixture.db.Exec(`UPDATE matches SET both_offline_since=? WHERE id=?`, fixture.now.Add(-24*time.Hour).UnixMilli(), created.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := fixture.db.Exec(`
CREATE TRIGGER fail_abandon_at_commit AFTER INSERT ON match_events
BEGIN
  INSERT INTO launch_tickets(token_hash,match_id,user_id,game_id,expires_at,created_at)
  VALUES ('abandon-commit-failure','ffffffff-ffff-4fff-8fff-ffffffffffff','11111111-1111-4111-8111-111111111111','gomoku',1,1);
END`); err != nil {
			t.Fatal(err)
		}
		fixture.db.SetMaxOpenConns(1)
		connection, err := fixture.db.Conn(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if _, err := connection.ExecContext(context.Background(), `PRAGMA defer_foreign_keys=ON`); err != nil {
			connection.Close()
			t.Fatal(err)
		}
		if err := connection.Close(); err != nil {
			t.Fatal(err)
		}
		events, err := service.AbandonExpired(context.Background())
		if !errors.Is(err, ErrInternal) || len(events) != 0 || err.Error() != ErrInternal.Error() {
			t.Fatalf("AbandonExpired=(%+v,%v)", events, err)
		}
		assertTableCount(t, fixture.db, "match_events", 0)
		assertTableCount(t, fixture.db, "active_game_slots", 2)
	})
}

func TestPresenceLifecycleMethodsHonorCancelledContextWithoutWrites(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := service.SetPlayerOnline(ctx, created.ID, initiatorID); !errors.Is(err, context.Canceled) {
		t.Fatalf("SetPlayerOnline=%v", err)
	}
	if err := service.SetPlayerOffline(ctx, created.ID, initiatorID); !errors.Is(err, context.Canceled) {
		t.Fatalf("SetPlayerOffline=%v", err)
	}
	if events, err := service.AbandonExpired(ctx); !errors.Is(err, context.Canceled) || len(events) != 0 {
		t.Fatalf("AbandonExpired=(%+v,%v)", events, err)
	}
	if err := service.MarkActiveMatchesOfflineOnBoot(ctx); !errors.Is(err, context.Canceled) {
		t.Fatalf("MarkActiveMatchesOfflineOnBoot=%v", err)
	}
	assertBothOfflineSince(t, fixture.db, created.ID, nil)
}

func assertBothOfflineSince(t *testing.T, db *sql.DB, matchID string, want *int64) {
	t.Helper()
	var got sql.NullInt64
	if err := db.QueryRow(`SELECT both_offline_since FROM matches WHERE id=?`, matchID).Scan(&got); err != nil {
		t.Fatal(err)
	}
	if want == nil {
		if got.Valid {
			t.Fatalf("both_offline_since=%d want NULL", got.Int64)
		}
		return
	}
	if !got.Valid || got.Int64 != *want {
		t.Fatalf("both_offline_since=%v want %d", got, *want)
	}
}

type concurrentActionResult struct {
	event    Event
	snapshot Snapshot
	err      error
}

func runConcurrentActions(service *Service, requests ...ActionRequest) []concurrentActionResult {
	start := make(chan struct{})
	results := make(chan concurrentActionResult, len(requests))
	var workers sync.WaitGroup
	for _, request := range requests {
		request := request
		workers.Add(1)
		go func() {
			defer workers.Done()
			<-start
			event, snapshot, err := service.ApplyAction(context.Background(), request)
			results <- concurrentActionResult{event: event, snapshot: snapshot, err: err}
		}()
	}
	close(start)
	workers.Wait()
	close(results)
	collected := make([]concurrentActionResult, 0, len(requests))
	for result := range results {
		collected = append(collected, result)
	}
	return collected
}

func TestResumeCredentialLaunchTicketIsAtomicSingleUseAndSlides(t *testing.T) {
	fixture := newFixture(t)
	credentialRandom := bytes.NewReader(append(bytes.Repeat([]byte{1}, 32), bytes.Repeat([]byte{2}, 32)...))
	service, err := NewServiceWithConfig(fixture.db, fixture.registry, fixture.clock, ServiceConfig{
		ColorRandom: bytes.NewReader([]byte{0}), LaunchTicketRandom: credentialRandom,
		TokenPepper: "resume-credential-test-pepper-at-least-thirty-two-bytes",
	})
	if err != nil {
		t.Fatal(err)
	}
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	ticket, err := service.CreateLaunchTicket(context.Background(), created.ID, initiatorID)
	if err != nil {
		t.Fatal(err)
	}
	connected, err := service.ConnectCredential(context.Background(), CredentialRequest{LaunchTicket: ticket.Token})
	if err != nil {
		t.Fatalf("ConnectCredential launch: %v", err)
	}
	wantInitialExpiry := time.UnixMilli(fixture.clock.Now().UTC().Add(30 * time.Minute).UnixMilli()).UTC()
	if connected.UserID != initiatorID || connected.MatchID != created.ID || connected.GameID != gomoku.GameID || connected.ResumeToken == "" || connected.ResumeExpiresAt != wantInitialExpiry {
		t.Fatalf("credential=%+v", connected)
	}
	if second, err := service.ConnectCredential(context.Background(), CredentialRequest{LaunchTicket: ticket.Token}); !errors.Is(err, ErrTicketInvalid) || second.ResumeToken != "" {
		t.Fatalf("ticket reuse=(%+v,%v)", second, err)
	}
	var consumed sql.NullInt64
	if err := fixture.db.QueryRow(`SELECT consumed_at FROM launch_tickets`).Scan(&consumed); err != nil || !consumed.Valid || consumed.Int64 != fixture.clock.Now().UTC().UnixMilli() {
		t.Fatalf("consumed=%v err=%v", consumed, err)
	}
	var storedHash string
	if err := fixture.db.QueryRow(`SELECT token_hash FROM resume_tokens`).Scan(&storedHash); err != nil || storedHash == connected.ResumeToken || strings.Contains(fmt.Sprint(service), connected.ResumeToken) {
		t.Fatalf("stored resume hash=%q err=%v service=%v", storedHash, err, service)
	}
	launchDomainHash, _ := hashLaunchTicket("resume-credential-test-pepper-at-least-thirty-two-bytes", connected.ResumeToken)
	if storedHash == launchDomainHash {
		t.Fatal("resume token reused the launch-ticket hash domain")
	}

	fixture.clock.Advance(29 * time.Minute)
	resumed, err := service.ConnectCredential(context.Background(), CredentialRequest{ResumeToken: connected.ResumeToken})
	if err != nil {
		t.Fatalf("resume: %v", err)
	}
	wantSlidExpiry := time.UnixMilli(fixture.clock.Now().UTC().Add(30 * time.Minute).UnixMilli()).UTC()
	if resumed.ResumeToken != connected.ResumeToken || resumed.ResumeExpiresAt != wantSlidExpiry {
		t.Fatalf("sliding credential=%+v", resumed)
	}
	var lastUsed, expires int64
	if err := fixture.db.QueryRow(`SELECT last_used_at,expires_at FROM resume_tokens`).Scan(&lastUsed, &expires); err != nil || lastUsed != fixture.clock.Now().UTC().UnixMilli() || expires != resumed.ResumeExpiresAt.UnixMilli() {
		t.Fatalf("stored sliding=(%d,%d,%v)", lastUsed, expires, err)
	}
}

func TestResumeCredentialRejectsInvalidExpiredAndTerminalTokensWithoutMutation(t *testing.T) {
	fixture := newFixture(t)
	service, err := NewServiceWithConfig(fixture.db, fixture.registry, fixture.clock, ServiceConfig{
		ColorRandom: bytes.NewReader([]byte{0}), LaunchTicketRandom: bytes.NewReader(bytes.Repeat([]byte{3}, 96)),
		TokenPepper: "resume-rejection-test-pepper-at-least-thirty-two-bytes",
	})
	if err != nil {
		t.Fatal(err)
	}
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	ticket, _ := service.CreateLaunchTicket(context.Background(), created.ID, initiatorID)
	credential, err := service.ConnectCredential(context.Background(), CredentialRequest{LaunchTicket: ticket.Token})
	if err != nil {
		t.Fatal(err)
	}
	invalid := []struct {
		request CredentialRequest
		want    error
	}{
		{request: CredentialRequest{}, want: ErrInvalidRequest},
		{request: CredentialRequest{LaunchTicket: ticket.Token, ResumeToken: credential.ResumeToken}, want: ErrInvalidRequest},
		{request: CredentialRequest{ResumeToken: "not-base64"}, want: ErrResumeExpired},
		{request: CredentialRequest{ResumeToken: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{4}, 32))}, want: ErrResumeExpired},
		{request: CredentialRequest{LaunchTicket: "not-base64"}, want: ErrTicketInvalid},
		{request: CredentialRequest{LaunchTicket: base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{5}, 32))}, want: ErrTicketInvalid},
	}
	for _, test := range invalid {
		if _, err := service.ConnectCredential(context.Background(), test.request); !errors.Is(err, test.want) {
			t.Fatalf("request=%+v err=%v want=%v", test.request, err, test.want)
		}
	}
	fixture.clock.Advance(30 * time.Minute)
	if _, err := service.ConnectCredential(context.Background(), CredentialRequest{ResumeToken: credential.ResumeToken}); !errors.Is(err, ErrResumeExpired) {
		t.Fatalf("expired resume err=%v", err)
	}
	if _, err := fixture.db.Exec(`UPDATE resume_tokens SET expires_at=? WHERE match_id=?`, fixture.clock.Now().Add(time.Hour).UnixMilli(), created.ID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 990, 0, 0, 0)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := service.ApplyAction(context.Background(), resignRequest(created.ID, opponentID, 991, 1)); err != nil {
		t.Fatal(err)
	}
	if _, err := service.ConnectCredential(context.Background(), CredentialRequest{ResumeToken: credential.ResumeToken}); !errors.Is(err, ErrResumeExpired) {
		t.Fatalf("terminal resume err=%v", err)
	}
	var revoked sql.NullInt64
	if err := fixture.db.QueryRow(`SELECT revoked_at FROM resume_tokens`).Scan(&revoked); err != nil || !revoked.Valid {
		t.Fatalf("revoked=%v err=%v", revoked, err)
	}
}

func TestResumeCredentialRetriesCollisionAndRollsBackFailures(t *testing.T) {
	const pepper = "resume-transaction-test-pepper-at-least-thirty-two-bytes"
	t.Run("hash collision", func(t *testing.T) {
		fixture := newFixture(t)
		blocks := append(bytes.Repeat([]byte{4}, 32), bytes.Repeat([]byte{5}, 32)...)
		blocks = append(blocks, bytes.Repeat([]byte{6}, 32)...)
		service, err := NewServiceWithConfig(fixture.db, fixture.registry, fixture.clock, ServiceConfig{
			ColorRandom: bytes.NewReader([]byte{0}), LaunchTicketRandom: bytes.NewReader(blocks), TokenPepper: pepper,
		})
		if err != nil {
			t.Fatal(err)
		}
		created, _ := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		ticket, err := service.CreateLaunchTicket(context.Background(), created.ID, initiatorID)
		if err != nil {
			t.Fatal(err)
		}
		collisionToken := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{5}, 32))
		collisionHash, _ := hashCredential(pepper, collisionToken, resumeTokenHashDomain)
		now := fixture.clock.Now().UTC().UnixMilli()
		if _, err := fixture.db.Exec(`INSERT INTO resume_tokens(token_hash,match_id,user_id,expires_at,last_used_at,created_at) VALUES (?,?,?,?,?,?)`, collisionHash, created.ID, opponentID, now+int64(time.Hour/time.Millisecond), now, now); err != nil {
			t.Fatal(err)
		}
		credential, err := service.ConnectCredential(context.Background(), CredentialRequest{LaunchTicket: ticket.Token})
		if err != nil {
			t.Fatal(err)
		}
		if credential.ResumeToken == collisionToken || credential.ResumeToken != base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{6}, 32)) {
			t.Fatalf("collision was not retried: %+v", credential)
		}
		var count int
		if err := fixture.db.QueryRow(`SELECT COUNT(*) FROM resume_tokens`).Scan(&count); err != nil || count != 2 {
			t.Fatalf("resume rows=%d err=%v", count, err)
		}
	})

	t.Run("deferred commit failure", func(t *testing.T) {
		fixture := newFixture(t)
		service, err := NewServiceWithConfig(fixture.db, fixture.registry, fixture.clock, ServiceConfig{
			ColorRandom: bytes.NewReader([]byte{0}), LaunchTicketRandom: bytes.NewReader(distinctBlocks(7, 8)), TokenPepper: pepper,
		})
		if err != nil {
			t.Fatal(err)
		}
		created, _ := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		ticket, _ := service.CreateLaunchTicket(context.Background(), created.ID, initiatorID)
		if _, err := fixture.db.Exec(`
CREATE TABLE resume_commit_guard (
  marker TEXT PRIMARY KEY,
  missing_user_id TEXT NOT NULL REFERENCES users(id) DEFERRABLE INITIALLY DEFERRED
);
CREATE TRIGGER fail_resume_at_commit AFTER INSERT ON resume_tokens
BEGIN
  INSERT INTO resume_commit_guard(marker,missing_user_id)
  VALUES (NEW.token_hash,'ffffffff-ffff-4fff-8fff-ffffffffffff');
END;`); err != nil {
			t.Fatal(err)
		}
		fixture.db.SetMaxOpenConns(1)
		connection, err := fixture.db.Conn(context.Background())
		if err != nil {
			t.Fatal(err)
		}
		if _, err := connection.ExecContext(context.Background(), `PRAGMA defer_foreign_keys=ON`); err != nil {
			_ = connection.Close()
			t.Fatal(err)
		}
		if err := connection.Close(); err != nil {
			t.Fatal(err)
		}
		credential, err := service.ConnectCredential(context.Background(), CredentialRequest{LaunchTicket: ticket.Token})
		if !errors.Is(err, ErrInternal) || credential.ResumeToken != "" {
			t.Fatalf("commit failure=(%+v,%v)", credential, err)
		}
		var consumed sql.NullInt64
		if err := fixture.db.QueryRow(`SELECT consumed_at FROM launch_tickets`).Scan(&consumed); err != nil || consumed.Valid {
			t.Fatalf("ticket mutated after failed commit: %v err=%v", consumed, err)
		}
		var count int
		if err := fixture.db.QueryRow(`SELECT COUNT(*) FROM resume_tokens`).Scan(&count); err != nil || count != 0 {
			t.Fatalf("resume rows=%d err=%v", count, err)
		}
	})

	t.Run("busy cancellation and overflow", func(t *testing.T) {
		fixture := newFixture(t)
		service, err := NewServiceWithConfig(fixture.db, fixture.registry, fixture.clock, ServiceConfig{
			ColorRandom: bytes.NewReader([]byte{0}), LaunchTicketRandom: bytes.NewReader(distinctBlocks(9, 10)), TokenPepper: pepper,
		})
		if err != nil {
			t.Fatal(err)
		}
		created, _ := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
		ticket, _ := service.CreateLaunchTicket(context.Background(), created.ID, initiatorID)
		blocking, err := fixture.db.BeginTx(context.Background(), nil)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := blocking.Exec(`UPDATE users SET updated_at=updated_at WHERE id=?`, initiatorID); err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
		credential, connectErr := service.ConnectCredential(ctx, CredentialRequest{LaunchTicket: ticket.Token})
		cancel()
		_ = blocking.Rollback()
		if !errors.Is(connectErr, context.DeadlineExceeded) || credential.ResumeToken != "" {
			t.Fatalf("busy connect=(%+v,%v)", credential, connectErr)
		}
		cancelled, cancelNow := context.WithCancel(context.Background())
		cancelNow()
		if credential, err = service.ConnectCredential(cancelled, CredentialRequest{LaunchTicket: ticket.Token}); !errors.Is(err, context.Canceled) || credential.ResumeToken != "" {
			t.Fatalf("cancelled connect=(%+v,%v)", credential, err)
		}
		var consumed sql.NullInt64
		if err := fixture.db.QueryRow(`SELECT consumed_at FROM launch_tickets`).Scan(&consumed); err != nil || consumed.Valid {
			t.Fatalf("busy/cancel consumed=%v err=%v", consumed, err)
		}

		overflowService, err := NewServiceWithConfig(fixture.db, fixture.registry, clock.NewFake(time.UnixMilli(math.MaxInt64-1)), ServiceConfig{
			ColorRandom: bytes.NewReader([]byte{0}), LaunchTicketRandom: bytes.NewReader(distinctBlocks(11, 12)), TokenPepper: pepper,
		})
		if err != nil {
			t.Fatal(err)
		}
		if credential, err = overflowService.ConnectCredential(context.Background(), CredentialRequest{LaunchTicket: ticket.Token}); !errors.Is(err, ErrInternal) || credential.ResumeToken != "" {
			t.Fatalf("overflow connect=(%+v,%v)", credential, err)
		}

		blocking, err = fixture.db.BeginTx(context.Background(), nil)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := blocking.Exec(`UPDATE users SET updated_at=updated_at WHERE id=?`, initiatorID); err != nil {
			t.Fatal(err)
		}
		type connectResult struct {
			credential ConnectionCredential
			err        error
		}
		result := make(chan connectResult, 1)
		go func() {
			connected, connectErr := service.ConnectCredential(context.Background(), CredentialRequest{LaunchTicket: ticket.Token})
			result <- connectResult{credential: connected, err: connectErr}
		}()
		time.Sleep(40 * time.Millisecond)
		fixture.clock.Advance(30 * time.Second)
		if err := blocking.Rollback(); err != nil {
			t.Fatal(err)
		}
		connected := <-result
		wantExpiry := time.UnixMilli(fixture.clock.Now().UTC().Add(resumeTokenLifetime).UnixMilli()).UTC()
		if connected.err != nil || connected.credential.ResumeExpiresAt != wantExpiry {
			t.Fatalf("post-lock clock=(%+v,%v) want expiry %v", connected.credential, connected.err, wantExpiry)
		}
		if strings.Contains(fmt.Sprintf("%+v %#v", CredentialRequest{LaunchTicket: ticket.Token}, connected.credential), ticket.Token) || strings.Contains(fmt.Sprintf("%+v", connected.credential), connected.credential.ResumeToken) {
			t.Fatal("credential formatting exposed a secret")
		}
	})
}

func TestLaunchCredentialBindsTicketUserMatchAndGameWithoutConsumption(t *testing.T) {
	const fourthID = "44444444-4444-4444-8444-444444444444"
	tests := []struct {
		name   string
		tamper func(*testing.T, fixture, LaunchTicket, string)
	}{
		{name: "user", tamper: func(t *testing.T, fixture fixture, ticket LaunchTicket, _ string) {
			if _, err := fixture.db.Exec(`UPDATE launch_tickets SET user_id=? WHERE token_hash=(SELECT token_hash FROM launch_tickets LIMIT 1)`, thirdID); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "match", tamper: func(t *testing.T, fixture fixture, ticket LaunchTicket, otherMatchID string) {
			if _, err := fixture.db.Exec(`UPDATE launch_tickets SET match_id=? WHERE token_hash=(SELECT token_hash FROM launch_tickets LIMIT 1)`, otherMatchID); err != nil {
				t.Fatal(err)
			}
		}},
		{name: "game", tamper: func(t *testing.T, fixture fixture, ticket LaunchTicket, _ string) {
			if _, err := fixture.db.Exec(`UPDATE launch_tickets SET game_id='other-game' WHERE token_hash=(SELECT token_hash FROM launch_tickets LIMIT 1)`); err != nil {
				t.Fatal(err)
			}
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			fixture := newFixture(t)
			fixture.addUser(t, fourthID, "Fourth", true)
			service, err := NewServiceWithConfig(fixture.db, fixture.registry, fixture.clock, ServiceConfig{
				ColorRandom: bytes.NewReader([]byte{0, 0}), LaunchTicketRandom: bytes.NewReader(distinctBlocks(31, 32)),
				TokenPepper: "ticket-binding-test-pepper-at-least-thirty-two-bytes",
			})
			if err != nil {
				t.Fatal(err)
			}
			created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
			if err != nil {
				t.Fatal(err)
			}
			other, err := service.Create(context.Background(), gomoku.GameID, thirdID, fourthID)
			if err != nil {
				t.Fatal(err)
			}
			ticket, err := service.CreateLaunchTicket(context.Background(), created.ID, initiatorID)
			if err != nil {
				t.Fatal(err)
			}
			test.tamper(t, fixture, ticket, other.ID)
			credential, connectErr := service.ConnectCredential(context.Background(), CredentialRequest{LaunchTicket: ticket.Token})
			if !errors.Is(connectErr, ErrTicketInvalid) || credential.ResumeToken != "" {
				t.Fatalf("tampered ticket=(%+v,%v)", credential, connectErr)
			}
			var consumed sql.NullInt64
			if err := fixture.db.QueryRow(`SELECT consumed_at FROM launch_tickets`).Scan(&consumed); err != nil || consumed.Valid {
				t.Fatalf("tampered ticket consumed=%v err=%v", consumed, err)
			}
			var resumes int
			if err := fixture.db.QueryRow(`SELECT COUNT(*) FROM resume_tokens`).Scan(&resumes); err != nil || resumes != 0 {
				t.Fatalf("resume rows=%d err=%v", resumes, err)
			}
		})
	}
}

func distinctBlocks(values ...byte) []byte {
	result := make([]byte, 0, len(values)*32)
	for _, value := range values {
		result = append(result, bytes.Repeat([]byte{value}, 32)...)
	}
	return result
}

func TestHubUsesFrozenConnectionDeadlinesAndCredentialMessages(t *testing.T) {
	fixture := newFixture(t)
	service, err := NewServiceWithConfig(fixture.db, fixture.registry, fixture.clock, ServiceConfig{
		ColorRandom: bytes.NewReader([]byte{0}), LaunchTicketRandom: bytes.NewReader(distinctBlocks(41, 42)),
		TokenPepper: "hub-defaults-test-pepper-at-least-thirty-two-bytes",
	})
	if err != nil {
		t.Fatal(err)
	}
	presence, err := NewPresence(service, fixture.clock)
	if err != nil {
		t.Fatal(err)
	}
	hub, err := NewHub(service, presence, fixture.clock)
	if err != nil {
		t.Fatal(err)
	}
	if hub.firstMessageTimeout != 5*time.Second || hub.heartbeatInterval != 15*time.Second || hub.activityTimeout != 45*time.Second {
		t.Fatalf("hub deadlines=(%s,%s,%s)", hub.firstMessageTimeout, hub.heartbeatInterval, hub.activityTimeout)
	}
	wantMessages := map[string]string{
		"invalid_request": "The request is invalid",
		"ticket_invalid":  "The launch ticket is invalid",
		"resume_expired":  "The resume session has expired",
	}
	for code, want := range wantMessages {
		if got := fixedErrorMessage(code); got != want {
			t.Fatalf("fixedErrorMessage(%q)=%q want %q", code, got, want)
		}
	}
}

func TestHubPublishesConcurrentRevisionsInOrderAndDeduplicates(t *testing.T) {
	connection := &hubConnection{ready: true, send: make(chan []byte, 4), matchID: initiatorID}
	hub := &Hub{matches: map[string]*hubMatch{
		initiatorID: {connections: map[*hubConnection]struct{}{connection: {}}, pendingEvents: make(map[int64][]byte), gameID: gomoku.GameID},
	}}
	event := func(revision int64) Event {
		return Event{MatchID: initiatorID, Revision: revision, Type: protocol.TypePlatformMatchCancelled, Payload: json.RawMessage(`{}`)}
	}
	hub.Publish(initiatorID, event(2))
	if len(connection.send) != 0 {
		t.Fatal("out-of-order revision was published before its predecessor")
	}
	hub.Publish(initiatorID, event(1))
	for want := int64(1); want <= 2; want++ {
		data := <-connection.send
		envelope, err := protocol.Decode(data)
		if err != nil || envelope.Revision == nil || *envelope.Revision != want {
			t.Fatalf("published revision %d: %s err=%v", want, data, err)
		}
	}
	hub.Publish(initiatorID, event(2))
	if len(connection.send) != 0 {
		t.Fatal("duplicate committed revision was broadcast twice")
	}
}

func TestHubSendQueueIsBoundedAndNonblocking(t *testing.T) {
	connection := &hubConnection{send: make(chan []byte, 1)}
	if !connection.enqueue([]byte("first")) {
		t.Fatal("first enqueue failed")
	}
	started := time.Now()
	if connection.enqueue([]byte("second")) {
		t.Fatal("full queue accepted a second message")
	}
	if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
		t.Fatalf("full queue blocked for %s", elapsed)
	}
}

func TestHubSlowQueueDoesNotBlockAnotherConnection(t *testing.T) {
	slow := &hubConnection{ready: true, send: make(chan []byte, 1)}
	slow.send <- []byte("already full")
	fast := &hubConnection{ready: true, send: make(chan []byte, 2)}
	match := &hubMatch{
		connections:   map[*hubConnection]struct{}{slow: {}, fast: {}},
		pendingEvents: map[int64][]byte{1: []byte(`{"revision":1}`)},
		gameID:        gomoku.GameID,
	}
	hub := &Hub{}
	started := time.Now()
	closed := hub.flushPublishedLocked(match)
	if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
		t.Fatalf("slow queue blocked fan-out for %s", elapsed)
	}
	if len(closed) != 1 || closed[0] != slow {
		t.Fatalf("slow connections=%v", closed)
	}
	select {
	case message := <-fast.send:
		if string(message) != `{"revision":1}` {
			t.Fatalf("fast message=%s", message)
		}
	default:
		t.Fatal("fast connection did not receive the event")
	}
}

func TestHubSnapshotObservedAheadResnapshotsExistingPeerBeforeReady(t *testing.T) {
	existing := &hubConnection{ready: true, send: make(chan []byte, 2), matchID: initiatorID}
	existing.revision.Store(0)
	joining := &hubConnection{send: make(chan []byte, 2), matchID: initiatorID}
	joining.revision.Store(2)
	hub := &Hub{matches: map[string]*hubMatch{
		initiatorID: {
			connections:   map[*hubConnection]struct{}{existing: {}, joining: {}},
			pendingEvents: make(map[int64][]byte),
			gameID:        gomoku.GameID,
		},
	}}
	snapshot := []byte(`{"revision":2,"type":"platform.snapshot"}`)
	if ready, stale := hub.markReady(joining, 2, snapshot); !ready || stale {
		t.Fatal("joining connection did not become ready")
	}
	if existing.revision.Load() != 2 || joining.revision.Load() != 2 {
		t.Fatalf("revisions existing=%d joining=%d", existing.revision.Load(), joining.revision.Load())
	}
	select {
	case message := <-existing.send:
		if string(message) != string(snapshot) {
			t.Fatalf("existing resnapshot=%s", message)
		}
	default:
		t.Fatal("existing peer was left behind the observed snapshot")
	}
}

func TestHubOlderConcurrentSnapshotMustBeRetriedBeforeReady(t *testing.T) {
	joining := &hubConnection{send: make(chan []byte, 2), matchID: initiatorID}
	hub := &Hub{matches: map[string]*hubMatch{
		initiatorID: {
			connections:       map[*hubConnection]struct{}{joining: {}},
			publishedRevision: 2,
			pendingEvents:     make(map[int64][]byte),
			gameID:            gomoku.GameID,
		},
	}}
	ready, stale := hub.markReady(joining, 0, []byte(`{"revision":0}`))
	if ready || !stale || joining.ready {
		t.Fatalf("older snapshot ready=%t stale=%t connectionReady=%t", ready, stale, joining.ready)
	}
}

func TestHubRuntimeSnapshotNeverRegressesPublishedConnectionWatermark(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	_, snapshotAtOne, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 9991, 0, 7, 7))
	if err != nil {
		t.Fatal(err)
	}
	connection := &hubConnection{send: make(chan []byte, 2)}
	connection.revision.Store(2) // event revision 2 won the scheduling race
	connection.enqueueSnapshot(snapshotAtOne)
	if connection.revision.Load() != 2 {
		t.Fatalf("runtime snapshot rolled watermark back to %d", connection.revision.Load())
	}
	if len(connection.send) != 0 {
		t.Fatal("runtime snapshot older than the published event was queued")
	}
}

func TestHubStaleResponseQueuesErrorThenNonRegressingSnapshotAfterNewerEvent(t *testing.T) {
	fixture := newFixture(t)
	service := fixture.service(t, bytes.NewReader([]byte{0}))
	created, err := service.Create(context.Background(), gomoku.GameID, initiatorID, opponentID)
	if err != nil {
		t.Fatal(err)
	}
	_, snapshotAtOne, err := service.ApplyAction(context.Background(), moveRequest(created.ID, initiatorID, 9992, 0, 7, 7))
	if err != nil {
		t.Fatal(err)
	}
	eventAtTwo, snapshotAtTwo, err := service.ApplyAction(context.Background(), moveRequest(created.ID, opponentID, 9993, 1, 8, 8))
	if err != nil {
		t.Fatal(err)
	}
	eventMessage, err := eventEnvelope(gomoku.GameID, eventAtTwo)
	if err != nil {
		t.Fatal(err)
	}
	connection := &hubConnection{
		send: make(chan []byte, 3), gameID: gomoku.GameID, matchID: created.ID,
	}
	if result := connection.enqueueState(eventMessage, 2); result != enqueueStateQueued {
		t.Fatalf("event enqueue=%d", result)
	}
	if result := connection.enqueueErrorAndSnapshot("stale_revision", actionID(9994), snapshotAtOne); result != enqueueStateStale {
		t.Fatalf("older stale pair enqueue=%d", result)
	}
	if result := connection.enqueueErrorAndSnapshot("stale_revision", actionID(9994), snapshotAtTwo); result != enqueueStateQueued {
		t.Fatalf("latest stale pair enqueue=%d", result)
	}
	if connection.revision.Load() != 2 || len(connection.send) != 3 {
		t.Fatalf("watermark=%d queued=%d", connection.revision.Load(), len(connection.send))
	}
	wantTypes := []string{protocol.TypeGomokuMoveAccepted, protocol.TypePlatformError, protocol.TypePlatformSnapshot}
	for index, wantType := range wantTypes {
		var envelope protocol.Envelope
		if err := json.Unmarshal(<-connection.send, &envelope); err != nil {
			t.Fatal(err)
		}
		if envelope.Type != wantType || envelope.Revision == nil || *envelope.Revision != 2 {
			t.Fatalf("message[%d]=%+v", index, envelope)
		}
	}
}

func moveRequest(matchID, actorID string, actionNumber int, expectedRevision int64, x, y int) ActionRequest {
	return ActionRequest{
		MatchID:          matchID,
		ActorUserID:      actorID,
		ActionID:         actionID(actionNumber),
		ExpectedRevision: expectedRevision,
		Type:             gomoku.MoveRequested,
		Payload:          json.RawMessage(fmt.Sprintf(`{"x":%d,"y":%d}`, x, y)),
	}
}

func resignRequest(matchID, actorID string, actionNumber int, expectedRevision int64) ActionRequest {
	return ActionRequest{
		MatchID:          matchID,
		ActorUserID:      actorID,
		ActionID:         actionID(actionNumber),
		ExpectedRevision: expectedRevision,
		Type:             protocol.TypeGomokuResignRequested,
		Payload:          json.RawMessage(`{}`),
	}
}

func actionID(number int) string {
	return fmt.Sprintf("aaaaaaaa-aaaa-4aaa-8aaa-%012x", number)
}

func stringPointerEquals(value *string, want string) bool {
	return value != nil && *value == want
}

func tableCount(t *testing.T, db *sql.DB, table string) int {
	t.Helper()
	allowed := map[string]bool{"matches": true, "match_players": true, "active_game_slots": true, "match_events": true, "launch_tickets": true}
	if !allowed[table] {
		t.Fatalf("unsafe table %q", table)
	}
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM ` + table).Scan(&count); err != nil {
		t.Fatal(err)
	}
	return count
}
