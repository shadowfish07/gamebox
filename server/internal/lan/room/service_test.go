package room

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/lan/journal"
	"me.zqydev/gamebox/server/internal/nickname"
	"me.zqydev/gamebox/server/internal/protocol"
)

const (
	testRoomID       = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	testHostID       = "11111111-1111-4111-8111-111111111111"
	testPepper       = "room-test-token-pepper-at-least-thirty-two-bytes"
	testRoomKey      = "room-key-plaintext-canary"
	testHostResume   = "host-resume-token-plaintext-canary"
	testGuestResume  = "guest-resume-token-plaintext-canary"
	testJoinAttempt  = "33333333-3333-4333-8333-333333333333"
	testJoinAttempt2 = "44444444-4444-4444-8444-444444444444"
	moveActionID     = "55555555-5555-4555-8555-555555555555"
	resignActionID   = "66666666-6666-4666-8666-666666666666"
)

func TestCreateJoinLocksRoomAndRetriesOnlyExactCandidate(t *testing.T) {
	root := t.TempDir()
	service := openTestService(t, root, nil, 0)
	created := createTestRoom(t, service)
	if created.Snapshot.RoomID != testRoomID || created.Snapshot.Status != StatusWaiting || len(created.Snapshot.Players) != 1 {
		t.Fatalf("created snapshot = %#v", created.Snapshot)
	}
	host := created.Snapshot.Players[0]
	if host.PlayerID != testHostID || host.Seat != 0 || host.Nickname != "Host 中" {
		t.Fatalf("host = %#v", host)
	}

	joined, err := service.Join(context.Background(), testJoinRequest())
	if err != nil {
		t.Fatalf("Join: %v", err)
	}
	if joined.Player.PlayerID == "" || joined.Player.PlayerID == testHostID || joined.Player.Seat != 1 || joined.Player.Nickname != "Guest 🙂" || joined.LaunchTicket.Token == "" {
		t.Fatalf("joined = %#v", joined)
	}
	if joined.Player.Color == host.Color || service.Snapshot().Status != StatusActive || len(service.Snapshot().Players) != 2 {
		t.Fatalf("colors/status = host %q guest %q snapshot %#v", host.Color, joined.Player.Color, service.Snapshot())
	}

	retry, err := service.Join(context.Background(), testJoinRequest())
	if err != nil {
		t.Fatalf("retry exact join: %v", err)
	}
	if retry.Player.PlayerID != joined.Player.PlayerID || retry.LaunchTicket.Token == joined.LaunchTicket.Token {
		t.Fatalf("retry = %#v, first = %#v", retry, joined)
	}
	if _, err := service.Connect(context.Background(), ConnectCredential{LaunchTicket: joined.LaunchTicket.Token}); !errors.Is(err, ErrTicketInvalid) {
		t.Fatalf("superseded response-loss ticket error = %v", err)
	}
	different := testJoinRequest()
	different.JoinAttemptID = testJoinAttempt2
	if got, gotErr := service.Join(context.Background(), different); !errors.Is(gotErr, ErrRoomLocked) || got.Player.PlayerID != "" {
		t.Fatalf("different attempt = (%#v, %v), want room locked", got, gotErr)
	}
	different = testJoinRequest()
	different.CandidateResumeToken += "-different"
	if _, gotErr := service.Join(context.Background(), different); !errors.Is(gotErr, ErrRoomLocked) {
		t.Fatalf("different candidate error = %v, want room locked", gotErr)
	}
	assertJournalSecretsAbsent(t, service, testRoomKey, testPepper, testHostResume, testGuestResume, joined.LaunchTicket.Token, retry.LaunchTicket.Token)
	for name, content := range snapshotFiles(t, root) {
		for _, secret := range []string{testRoomKey, testPepper, testHostResume, testGuestResume, joined.LaunchTicket.Token, retry.LaunchTicket.Token} {
			if strings.Contains(content, secret) {
				t.Fatalf("journal file %s exposed credential", name)
			}
		}
	}
}

func TestSecretBearingValuesRedactFormattedOutput(t *testing.T) {
	service := openTestService(t, t.TempDir(), nil, 0)
	create := testCreateRequest()
	createTestRoom(t, service)
	join := testJoinRequest()
	joined, err := service.Join(context.Background(), join)
	if err != nil {
		t.Fatal(err)
	}
	values := []any{
		create,
		join,
		ConnectCredential{LaunchTicket: joined.LaunchTicket.Token, ResumeToken: testGuestResume},
		joined.LaunchTicket,
		joined,
		service,
	}
	for _, value := range values {
		formatted := fmt.Sprintf("%+v %#v", value, value)
		for _, secret := range []string{testRoomKey, testPepper, testHostResume, testGuestResume, joined.LaunchTicket.Token} {
			if strings.Contains(formatted, secret) {
				t.Fatalf("formatted %T exposed credential", value)
			}
		}
	}
}

func TestRandomColorAllocationSeedsFixedGomokuSeats(t *testing.T) {
	for _, test := range []struct {
		name      string
		colorByte byte
		wantHost  Color
	}{
		{name: "host black", colorByte: 0, wantHost: ColorBlack},
		{name: "host white", colorByte: 1, wantHost: ColorWhite},
	} {
		t.Run(test.name, func(t *testing.T) {
			service := openTestService(t, t.TempDir(), nil, test.colorByte)
			createTestRoom(t, service)
			joined, err := service.Join(context.Background(), testJoinRequest())
			if err != nil {
				t.Fatal(err)
			}
			snapshot := service.Snapshot()
			if snapshot.Players[0].Color != test.wantHost || snapshot.Players[1].Color == test.wantHost || snapshot.Game.Revision != 0 {
				t.Fatalf("seating = %#v game revision %d", snapshot.Players, snapshot.Game.Revision)
			}
			actor := snapshot.Players[0]
			if actor.Color != ColorBlack {
				actor = joined.Player
			}
			if _, _, _, err := service.Apply(context.Background(), ActionRequest{
				PlayerID: actor.PlayerID, ActionID: moveActionID, ExpectedRevision: 0,
				Type: gomoku.MoveRequested, Payload: json.RawMessage(`{"x":2,"y":3}`),
			}); err != nil {
				t.Fatalf("assigned black first move: %v", err)
			}
		})
	}
}

func TestLaunchTicketsAreSingleUseAndResumeTokensStayPlayerBound(t *testing.T) {
	service := openTestService(t, t.TempDir(), nil, 0)
	createTestRoom(t, service)
	guest, err := service.Join(context.Background(), testJoinRequest())
	if err != nil {
		t.Fatal(err)
	}
	connected, err := service.Connect(context.Background(), ConnectCredential{LaunchTicket: guest.LaunchTicket.Token})
	if err != nil || connected.PlayerID != guest.Player.PlayerID || connected.RoomID != testRoomID {
		t.Fatalf("Connect launch = (%#v, %v)", connected, err)
	}
	if _, err := service.Connect(context.Background(), ConnectCredential{LaunchTicket: guest.LaunchTicket.Token}); !errors.Is(err, ErrTicketInvalid) {
		t.Fatalf("reused launch error = %v", err)
	}
	if resumed, err := service.Connect(context.Background(), ConnectCredential{ResumeToken: testGuestResume}); err != nil || resumed.PlayerID != guest.Player.PlayerID {
		t.Fatalf("guest resume = (%#v, %v)", resumed, err)
	}
	if _, err := service.IssueLaunch(context.Background(), testHostID, testGuestResume); !errors.Is(err, ErrResumeInvalid) {
		t.Fatalf("cross-player resume error = %v", err)
	}
	hostTicket, err := service.IssueLaunch(context.Background(), testHostID, testHostResume)
	if err != nil || hostTicket.PlayerID != testHostID || hostTicket.Token == "" {
		t.Fatalf("host ticket = (%#v, %v)", hostTicket, err)
	}
	if _, err := service.Connect(context.Background(), ConnectCredential{LaunchTicket: hostTicket.Token, ResumeToken: testHostResume}); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("two credentials error = %v", err)
	}
}

func TestJoinRejectsWrongRoomKeyExpiredInviteAndResumeDigestCollision(t *testing.T) {
	t.Run("wrong room key", func(t *testing.T) {
		service := openTestService(t, t.TempDir(), nil, 0)
		createTestRoom(t, service)
		request := testJoinRequest()
		request.RoomKey = "different-room-key"
		if _, err := service.Join(context.Background(), request); !errors.Is(err, ErrRoomKeyInvalid) {
			t.Fatalf("Join wrong key error = %v", err)
		}
	})

	t.Run("expired invite", func(t *testing.T) {
		now := time.UnixMilli(1_000)
		service, err := Open(Config{Root: t.TempDir(), Clock: func() time.Time { return now }, ColorRandom: bytes.NewReader([]byte{0}), PlayerRandom: bytes.NewReader(bytes.Repeat([]byte{3}, 32)), CredentialRandom: bytes.NewReader(bytes.Repeat([]byte{4}, 64)), TokenPepper: testPepper})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = service.Close() })
		request := testCreateRequest()
		request.JoinExpiresAt = 2_000
		if _, err := service.Create(context.Background(), request); err != nil {
			t.Fatal(err)
		}
		now = time.UnixMilli(2_001)
		if _, err := service.Join(context.Background(), testJoinRequest()); !errors.Is(err, ErrJoinExpired) {
			t.Fatalf("Join expired error = %v", err)
		}
	})

	t.Run("resume digest collision", func(t *testing.T) {
		service := openTestService(t, t.TempDir(), nil, 0)
		createTestRoom(t, service)
		request := testJoinRequest()
		request.CandidateResumeToken = testHostResume
		if _, err := service.Join(context.Background(), request); !errors.Is(err, ErrInvalidRequest) {
			t.Fatalf("Join colliding resume error = %v", err)
		}
	})
}

func TestApplyChecksRevisionTurnAndActionIdempotency(t *testing.T) {
	service := openTestService(t, t.TempDir(), nil, 0)
	createTestRoom(t, service)
	guest, _ := service.Join(context.Background(), testJoinRequest())
	snapshot := service.Snapshot()
	black := snapshot.Players[0]
	if black.Color != ColorBlack {
		black = guest.Player
	}
	white := snapshot.Players[0]
	if white.Color != ColorWhite {
		white = guest.Player
	}
	request := ActionRequest{PlayerID: black.PlayerID, ActionID: moveActionID, ExpectedRevision: 0, Type: gomoku.MoveRequested, Payload: json.RawMessage(`{"x":7,"y":7}`)}
	event, after, result, err := service.Apply(context.Background(), request)
	if err != nil || event.Revision != 1 || after.Revision != 1 || result != nil || event.Type != gomoku.MoveAccepted {
		t.Fatalf("Apply move = (%#v, %#v, %#v, %v)", event, after, result, err)
	}
	replayed, retrySnapshot, _, err := service.Apply(context.Background(), request)
	if err != nil || replayed.Revision != event.Revision || string(replayed.Payload) != string(event.Payload) || retrySnapshot.Revision != 1 {
		t.Fatalf("Apply retry = (%#v, %#v, %v)", replayed, retrySnapshot, err)
	}
	conflict := request
	conflict.Payload = json.RawMessage(`{"x":8,"y":7}`)
	if _, _, _, err := service.Apply(context.Background(), conflict); !errors.Is(err, ErrActionConflict) {
		t.Fatalf("action conflict error = %v", err)
	}
	if _, _, _, err := service.Apply(context.Background(), ActionRequest{PlayerID: white.PlayerID, ActionID: "77777777-7777-4777-8777-777777777777", ExpectedRevision: 0, Type: gomoku.MoveRequested, Payload: json.RawMessage(`{"x":8,"y":7}`)}); !errors.Is(err, ErrStaleRevision) {
		t.Fatalf("stale revision error = %v", err)
	}
	if _, _, _, err := service.Apply(context.Background(), ActionRequest{PlayerID: black.PlayerID, ActionID: "88888888-8888-4888-8888-888888888888", ExpectedRevision: 1, Type: gomoku.MoveRequested, Payload: json.RawMessage(`{"x":8,"y":7}`)}); !errors.Is(err, gomoku.ErrNotYourTurn) {
		t.Fatalf("wrong turn error = %v", err)
	}
}

func TestApplyRejectsNonCanonicalActionPayloadsWithoutMutation(t *testing.T) {
	service := openTestService(t, t.TempDir(), nil, 0)
	createTestRoom(t, service)
	_, _ = service.Join(context.Background(), testJoinRequest())
	black := playerWithColor(t, service.Snapshot(), ColorBlack)
	invalid := []json.RawMessage{
		json.RawMessage(`{}`),
		json.RawMessage(`{"x":1}`),
		json.RawMessage(`{"x":1,"y":2,"z":3}`),
		json.RawMessage(`{"x":1,"x":2,"y":2}`),
		json.RawMessage(`{"x":1.0,"y":2}`),
		json.RawMessage(`{"x":1e0,"y":2}`),
		json.RawMessage(`{"x":null,"y":2}`),
	}
	before := service.Snapshot()
	for index, payload := range invalid {
		actionID := fmt.Sprintf("99999999-9999-4999-8999-%012d", index)
		if _, _, _, err := service.Apply(context.Background(), ActionRequest{PlayerID: black.PlayerID, ActionID: actionID, ExpectedRevision: 0, Type: gomoku.MoveRequested, Payload: payload}); !errors.Is(err, ErrInvalidRequest) {
			t.Fatalf("invalid payload %s error = %v", payload, err)
		}
	}
	if after := service.Snapshot(); after.Revision != before.Revision || !bytes.Equal(after.Game.State, before.Game.State) {
		t.Fatalf("invalid actions mutated snapshot: before=%#v after=%#v", before, after)
	}
}

func TestWinningMoveCommitsOneTerminalRecordWhoseHashIsResultHash(t *testing.T) {
	root := t.TempDir()
	service := openTestService(t, root, nil, 0)
	createTestRoom(t, service)
	_, _ = service.Join(context.Background(), testJoinRequest())
	black := playerWithColor(t, service.Snapshot(), ColorBlack)
	white := playerWithColor(t, service.Snapshot(), ColorWhite)
	var result *GameResult
	for turn := 0; turn < 9; turn++ {
		actor, x, y := black, turn/2, 7
		if turn%2 == 1 {
			actor, x, y = white, turn/2, 8
		}
		event, _, nextResult, err := service.Apply(context.Background(), ActionRequest{
			PlayerID: actor.PlayerID, ActionID: fmt.Sprintf("aaaaaaaa-bbbb-4ccc-8ddd-%012d", turn), ExpectedRevision: int64(turn),
			Type: gomoku.MoveRequested, Payload: json.RawMessage(fmt.Sprintf(`{"x":%d,"y":%d}`, x, y)),
		})
		if err != nil || event.Revision != int64(turn+1) {
			t.Fatalf("turn %d = (%#v, %v)", turn, event, err)
		}
		result = nextResult
	}
	if result == nil || result.Reason != ResultFive || result.WinnerPlayerID == nil || *result.WinnerPlayerID != black.PlayerID || result.Revision != 9 {
		t.Fatalf("winning result = %#v", result)
	}
	records := service.store.Records()
	terminal := records[len(records)-1]
	if terminal.Type != recordRoomFinished || terminal.GameRevision != nil || terminal.Hash != result.ResultHash {
		t.Fatalf("terminal record = %#v result %#v", terminal, result)
	}
	if err := service.Close(); err != nil {
		t.Fatal(err)
	}
	recovered := openTestService(t, root, nil, 0)
	if !reflect.DeepEqual(recovered.Snapshot().Result, result) || recovered.Snapshot().Game.Revision != 9 {
		t.Fatalf("recovered five = %#v", recovered.Snapshot())
	}
}

func TestSnapshotAndReturnValuesDoNotAliasAuthoritativeProjection(t *testing.T) {
	service := openTestService(t, t.TempDir(), nil, 0)
	created := createTestRoom(t, service)
	created.Snapshot.Players[0].Nickname = "mutated"
	created.Snapshot.Game.State[0] = '['
	joined, _ := service.Join(context.Background(), testJoinRequest())
	joined.Player.Nickname = "mutated guest"
	snapshot := service.Snapshot()
	snapshot.Players[0].Nickname = "again"
	snapshot.Game.State[0] = '['
	current := service.Snapshot()
	if current.Players[0].Nickname != "Host 中" || current.Players[1].Nickname != "Guest 🙂" || current.Game.State[0] != '{' {
		t.Fatalf("transport clone mutated authority: %#v state=%s", current.Players, current.Game.State)
	}
}

func TestConcurrentRevisionZeroActionsCommitExactlyOneMove(t *testing.T) {
	service := openTestService(t, t.TempDir(), nil, 0)
	createTestRoom(t, service)
	_, _ = service.Join(context.Background(), testJoinRequest())
	black := playerWithColor(t, service.Snapshot(), ColorBlack)
	requests := []ActionRequest{
		{PlayerID: black.PlayerID, ActionID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb1", ExpectedRevision: 0, Type: gomoku.MoveRequested, Payload: json.RawMessage(`{"x":1,"y":1}`)},
		{PlayerID: black.PlayerID, ActionID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbb2", ExpectedRevision: 0, Type: gomoku.MoveRequested, Payload: json.RawMessage(`{"x":2,"y":2}`)},
	}
	var wait sync.WaitGroup
	errorsOut := make(chan error, len(requests))
	for _, request := range requests {
		wait.Add(1)
		go func(request ActionRequest) {
			defer wait.Done()
			_, _, _, err := service.Apply(context.Background(), request)
			errorsOut <- err
		}(request)
	}
	wait.Wait()
	close(errorsOut)
	successes, stale := 0, 0
	for err := range errorsOut {
		if err == nil {
			successes++
		} else if errors.Is(err, ErrStaleRevision) {
			stale++
		} else {
			t.Fatalf("concurrent Apply error = %v", err)
		}
	}
	if successes != 1 || stale != 1 || service.Snapshot().Revision != 1 {
		t.Fatalf("concurrent results = success %d stale %d revision %d", successes, stale, service.Snapshot().Revision)
	}
}

func TestCancelIsHostOnlyAtRevisionZeroAndAbandonUsesResignationPipeline(t *testing.T) {
	t.Run("revision zero host cancel", func(t *testing.T) {
		service := openTestService(t, t.TempDir(), nil, 0)
		createTestRoom(t, service)
		guest, _ := service.Join(context.Background(), testJoinRequest())
		if _, err := service.Cancel(context.Background(), guest.Player.PlayerID); !errors.Is(err, ErrRoomNotCancellable) {
			t.Fatalf("guest cancel error = %v", err)
		}
		event, err := service.Cancel(context.Background(), testHostID)
		if err != nil || event.Type != protocol.TypePlatformMatchCancelled || event.Revision != 1 || service.Snapshot().Status != StatusCancelled {
			t.Fatalf("host cancel = (%#v, %v) snapshot %#v", event, err, service.Snapshot())
		}
	})

	t.Run("revision positive resignation", func(t *testing.T) {
		service := openTestService(t, t.TempDir(), nil, 0)
		createTestRoom(t, service)
		guest, _ := service.Join(context.Background(), testJoinRequest())
		black := playerWithColor(t, service.Snapshot(), ColorBlack)
		if _, _, _, err := service.Apply(context.Background(), ActionRequest{PlayerID: black.PlayerID, ActionID: moveActionID, ExpectedRevision: 0, Type: gomoku.MoveRequested, Payload: json.RawMessage(`{"x":1,"y":1}`)}); err != nil {
			t.Fatal(err)
		}
		if _, err := service.Cancel(context.Background(), testHostID); !errors.Is(err, ErrRoomNotCancellable) {
			t.Fatalf("revision positive Cancel error = %v", err)
		}
		resigner := guest.Player
		if resigner.PlayerID == black.PlayerID {
			resigner = service.Snapshot().Players[0]
		}
		event, snapshot, result, err := service.Apply(context.Background(), ActionRequest{
			PlayerID: resigner.PlayerID, ActionID: resignActionID, ExpectedRevision: 1,
			Type: protocol.TypeGomokuResignRequested, Payload: json.RawMessage(`{}`),
		})
		if err != nil || event.Type != protocol.TypeGomokuResigned || snapshot.Status != StatusFinished || result == nil || result.Reason != ResultResignation || result.Revision != 2 || result.ResultHash == "" {
			t.Fatalf("resign = (%#v, %#v, %#v, %v)", event, snapshot, result, err)
		}
		winner := opponentOf(t, snapshot, resigner.PlayerID)
		if result.WinnerPlayerID == nil || *result.WinnerPlayerID != winner.PlayerID {
			t.Fatalf("result winner = %#v want %s", result, winner.PlayerID)
		}
		if retry, _, retryResult, err := service.Apply(context.Background(), ActionRequest{PlayerID: resigner.PlayerID, ActionID: resignActionID, ExpectedRevision: 1, Type: protocol.TypeGomokuResignRequested, Payload: json.RawMessage(`{}`)}); err != nil || retry.Revision != event.Revision || retryResult.ResultHash != result.ResultHash {
			t.Fatalf("resign retry = (%#v, %#v, %v)", retry, retryResult, err)
		}
	})
}

func TestTerminalResultAcknowledgementsAreAuthenticatedAndIdempotent(t *testing.T) {
	service, result := terminalTestRoom(t)
	snapshot := service.Snapshot()
	if err := service.AcknowledgeResult(context.Background(), "99999999-9999-4999-8999-999999999999", result.ResultHash); !errors.Is(err, ErrInvalidRequest) {
		t.Fatalf("nonplayer ack error = %v", err)
	}
	if err := service.AcknowledgeResult(context.Background(), snapshot.Players[0].PlayerID, strings.Repeat("0", 64)); !errors.Is(err, ErrResultHashMismatch) {
		t.Fatalf("wrong hash ack error = %v", err)
	}
	for _, player := range snapshot.Players {
		if err := service.AcknowledgeResult(context.Background(), player.PlayerID, result.ResultHash); err != nil {
			t.Fatalf("ack %s: %v", player.PlayerID, err)
		}
		if err := service.AcknowledgeResult(context.Background(), player.PlayerID, result.ResultHash); err != nil {
			t.Fatalf("repeat ack %s: %v", player.PlayerID, err)
		}
	}
	if got := service.Snapshot().ResultAcknowledgedPlayerIDs; len(got) != 2 {
		t.Fatalf("acknowledged players = %v", got)
	}
	count := 0
	for _, record := range service.store.Records() {
		if record.Type == recordResultPersisted {
			count++
		}
	}
	if count != 2 {
		t.Fatalf("result.persisted record count = %d, want 2", count)
	}
}

func TestRoomNicknameValidationUsesSharedFixture(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "..", "..", "protocol", "fixtures", "nickname_cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Cases []struct {
			Name, Input string
			Valid       bool
		} `json:"cases"`
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	for _, test := range fixture.Cases {
		t.Run(test.Name, func(t *testing.T) {
			_, _, normalizeErr := nickname.Normalize(test.Input)
			request := testCreateRequest()
			request.HostNickname = test.Input
			service := openTestService(t, t.TempDir(), nil, 0)
			_, createErr := service.Create(context.Background(), request)
			if test.Valid && (normalizeErr != nil || createErr != nil) {
				t.Fatalf("valid fixture normalize/create = (%v, %v)", normalizeErr, createErr)
			}
			if !test.Valid && (!errors.Is(normalizeErr, nickname.ErrInvalid) || !errors.Is(createErr, ErrInvalidRequest)) {
				t.Fatalf("invalid fixture normalize/create = (%v, %v)", normalizeErr, createErr)
			}
		})
	}
}

func testCreateRequest() CreateRequest {
	return CreateRequest{RoomID: testRoomID, HostPlayerID: testHostID, HostNickname: " Host 中 ", RoomKey: testRoomKey, TokenPepper: testPepper, HostResumeToken: testHostResume, JoinExpiresAt: 100_000}
}

func testJoinRequest() JoinRequest {
	return JoinRequest{RoomID: testRoomID, Nickname: " Guest 🙂 ", JoinAttemptID: testJoinAttempt, CandidateResumeToken: testGuestResume, RoomKey: testRoomKey}
}

func createTestRoom(t *testing.T, service *Service) CreatedRoom {
	t.Helper()
	created, err := service.Create(context.Background(), testCreateRequest())
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	return created
}

func openTestService(t *testing.T, root string, ops journal.FileOps, color byte) *Service {
	t.Helper()
	credentialEntropy := make([]byte, 0, 32*32)
	for value := byte(1); value <= 32; value++ {
		credentialEntropy = append(credentialEntropy, bytes.Repeat([]byte{value}, 32)...)
	}
	playerEntropy := bytes.Repeat([]byte{0x33}, 16*8)
	service, err := Open(Config{Root: root, FileOps: ops, Clock: func() time.Time { return time.UnixMilli(1_000) }, ColorRandom: bytes.NewReader([]byte{color}), PlayerRandom: bytes.NewReader(playerEntropy), CredentialRandom: bytes.NewReader(credentialEntropy), TokenPepper: testPepper})
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = service.Close() })
	return service
}

func terminalTestRoom(t *testing.T) (*Service, *GameResult) {
	t.Helper()
	service := openTestService(t, t.TempDir(), nil, 0)
	createTestRoom(t, service)
	guest, err := service.Join(context.Background(), testJoinRequest())
	if err != nil {
		t.Fatal(err)
	}
	black := playerWithColor(t, service.Snapshot(), ColorBlack)
	if _, _, _, err := service.Apply(context.Background(), ActionRequest{PlayerID: black.PlayerID, ActionID: moveActionID, ExpectedRevision: 0, Type: gomoku.MoveRequested, Payload: json.RawMessage(`{"x":1,"y":1}`)}); err != nil {
		t.Fatal(err)
	}
	resigner := guest.Player
	if resigner.PlayerID == black.PlayerID {
		resigner = service.Snapshot().Players[0]
	}
	_, _, result, err := service.Apply(context.Background(), ActionRequest{PlayerID: resigner.PlayerID, ActionID: resignActionID, ExpectedRevision: 1, Type: protocol.TypeGomokuResignRequested, Payload: json.RawMessage(`{}`)})
	if err != nil {
		t.Fatal(err)
	}
	return service, result
}

func playerWithColor(t *testing.T, snapshot Snapshot, color Color) Player {
	t.Helper()
	for _, player := range snapshot.Players {
		if player.Color == color {
			return player
		}
	}
	t.Fatalf("no %s player in %#v", color, snapshot.Players)
	return Player{}
}

func opponentOf(t *testing.T, snapshot Snapshot, playerID string) Player {
	t.Helper()
	for _, player := range snapshot.Players {
		if player.PlayerID != playerID {
			return player
		}
	}
	t.Fatal("no opponent")
	return Player{}
}

func assertJournalSecretsAbsent(t *testing.T, service *Service, secrets ...string) {
	t.Helper()
	for _, record := range service.store.Records() {
		encoded := fmt.Sprintf("%+v", record)
		for _, secret := range secrets {
			if secret != "" && strings.Contains(encoded, secret) {
				t.Fatalf("journal record exposed secret %q: %s", secret, encoded)
			}
		}
	}
}
