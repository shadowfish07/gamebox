package room

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io/fs"
	"math"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/lan/journal"
	"me.zqydev/gamebox/server/internal/protocol"
)

func TestRecoveryMakesJoinAndActionResponseLossIdempotent(t *testing.T) {
	root := t.TempDir()
	service := openTestService(t, root, nil, 0)
	createTestRoom(t, service)
	firstJoin, err := service.Join(context.Background(), testJoinRequest())
	if err != nil {
		t.Fatal(err)
	}
	beforeMove := service.Snapshot()
	black := playerWithColor(t, beforeMove, ColorBlack)
	request := ActionRequest{PlayerID: black.PlayerID, ActionID: moveActionID, ExpectedRevision: 0, Type: gomoku.MoveRequested, Payload: json.RawMessage(`{"x":6,"y":6}`)}
	firstEvent, _, _, err := service.Apply(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.Close(); err != nil {
		t.Fatal(err)
	}

	recovered := openTestService(t, root, nil, 0)
	retryJoin, err := recovered.Join(context.Background(), testJoinRequest())
	if err != nil || retryJoin.Player.PlayerID != firstJoin.Player.PlayerID || retryJoin.LaunchTicket.Token == firstJoin.LaunchTicket.Token {
		t.Fatalf("recovered join = (%#v, %v), first %#v", retryJoin, err, firstJoin)
	}
	retryEvent, snapshot, _, err := recovered.Apply(context.Background(), request)
	if err != nil || retryEvent.Revision != firstEvent.Revision || snapshot.Revision != 1 || snapshot.Game.Revision != 1 {
		t.Fatalf("recovered action = (%#v, %#v, %v)", retryEvent, snapshot, err)
	}
	count := 0
	for _, record := range recovered.store.Records() {
		if record.ActionID != nil && *record.ActionID == moveActionID {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("move action journal count = %d, want 1", count)
	}
}

func TestJoinCrashBoundariesDoNotDuplicatePlayer(t *testing.T) {
	for _, test := range []struct {
		name       string
		failRename int
		failSync   int
	}{
		{name: "before rename", failRename: 2},
		{name: "after rename before directory sync", failSync: 2},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			ops := &faultOps{failRenameAt: test.failRename, failSyncAt: test.failSync}
			service := openTestService(t, root, ops, 0)
			createTestRoom(t, service)
			_, joinErr := service.Join(context.Background(), testJoinRequest())
			if !errors.Is(joinErr, errRoomInjected) {
				t.Fatalf("Join error = %v, want injected", joinErr)
			}
			if err := service.Close(); err != nil {
				t.Fatal(err)
			}
			recovered := openTestService(t, root, nil, 0)
			joined, err := recovered.Join(context.Background(), testJoinRequest())
			if err != nil || joined.Player.PlayerID == "" {
				t.Fatalf("recovered Join = (%#v, %v)", joined, err)
			}
			joinedRecords := 0
			for _, record := range recovered.store.Records() {
				if record.Type == recordPlayerJoined {
					joinedRecords++
				}
			}
			if joinedRecords != 1 || len(recovered.Snapshot().Players) != 2 {
				t.Fatalf("joined records/players = %d/%d", joinedRecords, len(recovered.Snapshot().Players))
			}
		})
	}
}

func TestActionCrashAfterDurableCommitBeforeResponseReplaysWithoutDuplicate(t *testing.T) {
	root := t.TempDir()
	ops := &faultOps{panicSyncAt: 4}
	service := openTestService(t, root, ops, 0)
	createTestRoom(t, service)
	_, _ = service.Join(context.Background(), testJoinRequest())
	black := playerWithColor(t, service.Snapshot(), ColorBlack)
	request := ActionRequest{PlayerID: black.PlayerID, ActionID: moveActionID, ExpectedRevision: 0, Type: gomoku.MoveRequested, Payload: json.RawMessage(`{"x":5,"y":5}`)}
	assertInjectedCrash(t, func() { _, _, _, _ = service.Apply(context.Background(), request) })
	if service.Snapshot().Revision != 0 {
		t.Fatalf("in-memory projection advanced across injected process crash: %d", service.Snapshot().Revision)
	}
	if err := service.Close(); err != nil {
		t.Fatal(err)
	}
	recovered := openTestService(t, root, nil, 0)
	event, snapshot, _, err := recovered.Apply(context.Background(), request)
	if err != nil || event.Revision != 1 || snapshot.Revision != 1 || snapshot.Game.Revision != 1 {
		t.Fatalf("retry committed move = (%#v, %#v, %v)", event, snapshot, err)
	}
	count := 0
	for _, record := range recovered.store.Records() {
		if record.ActionID != nil && *record.ActionID == moveActionID {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("committed move count = %d, want 1", count)
	}
}

func TestTerminalCrashAfterDurableCommitBeforeAnyAckReplaysOneResult(t *testing.T) {
	root := t.TempDir()
	ops := &faultOps{panicSyncAt: 5}
	service := openTestService(t, root, ops, 0)
	createTestRoom(t, service)
	guest, _ := service.Join(context.Background(), testJoinRequest())
	black := playerWithColor(t, service.Snapshot(), ColorBlack)
	_, _, _, err := service.Apply(context.Background(), ActionRequest{PlayerID: black.PlayerID, ActionID: moveActionID, ExpectedRevision: 0, Type: gomoku.MoveRequested, Payload: json.RawMessage(`{"x":4,"y":4}`)})
	if err != nil {
		t.Fatal(err)
	}
	resigner := guest.Player
	if resigner.PlayerID == black.PlayerID {
		resigner = service.Snapshot().Players[0]
	}
	request := ActionRequest{PlayerID: resigner.PlayerID, ActionID: resignActionID, ExpectedRevision: 1, Type: protocol.TypeGomokuResignRequested, Payload: json.RawMessage(`{}`)}
	assertInjectedCrash(t, func() { _, _, _, _ = service.Apply(context.Background(), request) })
	if service.Snapshot().Result != nil {
		t.Fatalf("in-memory result advanced across injected process crash: %#v", service.Snapshot().Result)
	}
	if err := service.Close(); err != nil {
		t.Fatal(err)
	}
	recovered := openTestService(t, root, nil, 0)
	_, _, result, err := recovered.Apply(context.Background(), request)
	if err != nil || result == nil || result.Reason != ResultResignation {
		t.Fatalf("retry terminal = (%#v, %v)", result, err)
	}
	terminalCount := 0
	for _, record := range recovered.store.Records() {
		if record.Type == recordRoomFinished {
			terminalCount++
		}
	}
	if terminalCount != 1 || len(recovered.Snapshot().ResultAcknowledgedPlayerIDs) != 0 {
		t.Fatalf("terminal/ack counts = %d/%d", terminalCount, len(recovered.Snapshot().ResultAcknowledgedPlayerIDs))
	}
}

func TestRecoveryPreservesTerminalCommitAndAcknowledgements(t *testing.T) {
	root := t.TempDir()
	service := openTestService(t, root, nil, 0)
	createTestRoom(t, service)
	guest, _ := service.Join(context.Background(), testJoinRequest())
	black := playerWithColor(t, service.Snapshot(), ColorBlack)
	_, _, _, _ = service.Apply(context.Background(), ActionRequest{PlayerID: black.PlayerID, ActionID: moveActionID, ExpectedRevision: 0, Type: gomoku.MoveRequested, Payload: json.RawMessage(`{"x":2,"y":2}`)})
	resigner := guest.Player
	if resigner.PlayerID == black.PlayerID {
		resigner = service.Snapshot().Players[0]
	}
	request := ActionRequest{PlayerID: resigner.PlayerID, ActionID: resignActionID, ExpectedRevision: 1, Type: protocol.TypeGomokuResignRequested, Payload: json.RawMessage(`{}`)}
	terminalEvent, _, firstResult, err := service.Apply(context.Background(), request)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.Close(); err != nil {
		t.Fatal(err)
	}
	recovered := openTestService(t, root, nil, 0)
	retryEvent, _, recoveredResult, err := recovered.Apply(context.Background(), request)
	if err != nil || !reflect.DeepEqual(retryEvent, terminalEvent) || !reflect.DeepEqual(recoveredResult, firstResult) {
		t.Fatalf("terminal recovery = (%#v, %#v, %v), want (%#v, %#v)", retryEvent, recoveredResult, err, terminalEvent, firstResult)
	}
	for _, player := range recovered.Snapshot().Players {
		if err := recovered.AcknowledgeResult(context.Background(), player.PlayerID, recoveredResult.ResultHash); err != nil {
			t.Fatal(err)
		}
	}
	if err := recovered.Close(); err != nil {
		t.Fatal(err)
	}
	again := openTestService(t, root, nil, 0)
	if !reflect.DeepEqual(again.Snapshot().Result, recoveredResult) || len(again.Snapshot().ResultAcknowledgedPlayerIDs) != 2 {
		t.Fatalf("second recovery snapshot = %#v", again.Snapshot())
	}
}

func TestRecoveryRejectsConsistentHashChainWithInvalidRoomSemanticsWithoutEditingFiles(t *testing.T) {
	tests := []struct {
		name  string
		draft func(*testing.T, *Service) journal.Draft
	}{
		{name: "unknown credential consumption", draft: func(t *testing.T, service *Service) journal.Draft {
			return journal.Draft{Type: recordCredentialConsumed, Payload: rawJSON(t, map[string]any{"roomId": testRoomID, "playerId": testHostID, "credentialDigest": strings64("a"), "consumedAt": int64(2_000)})}
		}},
		{name: "wrong room identity", draft: func(t *testing.T, service *Service) journal.Draft {
			return journal.Draft{Type: recordCredentialIssued, Payload: rawJSON(t, map[string]any{"roomId": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "playerId": testHostID, "credentialDigest": strings64("b"), "issuedAt": int64(2_000), "expiresAt": int64(62_000)})}
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			service := openTestService(t, root, nil, 0)
			createTestRoom(t, service)
			if _, err := service.store.Append(context.Background(), test.draft(t, service)); err != nil {
				t.Fatal(err)
			}
			if err := service.Close(); err != nil {
				t.Fatal(err)
			}
			before := snapshotFiles(t, root)
			_, err := Open(Config{Root: root, TokenPepper: testPepper})
			if !errors.Is(err, ErrRecoveryCorrupt) {
				t.Fatalf("Open error = %v, want recovery corrupt", err)
			}
			after := snapshotFiles(t, root)
			if !reflect.DeepEqual(after, before) {
				t.Fatalf("recovery edited sources: before=%v after=%v", before, after)
			}
		})
	}
}

func TestRecoveryRejectsJoinOutsideCreatedRoomWindow(t *testing.T) {
	for _, test := range []struct {
		name     string
		joinedAt int64
	}{
		{name: "before room creation", joinedAt: 999},
		{name: "after join deadline", joinedAt: 100_001},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			service := openTestService(t, root, nil, 0)
			created := createTestRoom(t, service)
			host := created.Snapshot.Players[0]
			guestColor := ColorBlack
			if host.Color == ColorBlack {
				guestColor = ColorWhite
			}
			payload := playerJoinedPayload{
				RoomID:        testRoomID,
				Player:        Player{PlayerID: "22222222-2222-4222-8222-222222222222", Nickname: "Guest", Seat: 1, Color: guestColor},
				JoinAttemptID: testJoinAttempt,
				ResumeDigest:  credentialDigest(testPepper, resumeDigestDomain, testGuestResume),
				JoinedAt:      test.joinedAt,
			}
			draft, err := makeDraft(recordPlayerJoined, nil, nil, payload)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := service.store.Append(context.Background(), draft); err != nil {
				t.Fatal(err)
			}
			assertRecoveryCorruptWithoutEdits(t, service, root)
		})
	}
}

func TestRecoveryRequiresExactOverflowSafeLaunchTicketLifetime(t *testing.T) {
	for _, test := range []struct {
		name      string
		issuedAt  int64
		expiresAt int64
	}{
		{name: "shortened", issuedAt: 2_000, expiresAt: 61_999},
		{name: "extended", issuedAt: 2_000, expiresAt: 62_001},
		{name: "overflow", issuedAt: math.MaxInt64 - launchTicketLifetimeMS + 1, expiresAt: math.MaxInt64},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			service := openTestService(t, root, nil, 0)
			createTestRoom(t, service)
			payload := credentialIssuedPayload{
				RoomID: testRoomID, PlayerID: testHostID, CredentialDigest: strings64("c"),
				IssuedAt: test.issuedAt, ExpiresAt: test.expiresAt,
			}
			draft, err := makeDraft(recordCredentialIssued, nil, nil, payload)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := service.store.Append(context.Background(), draft); err != nil {
				t.Fatal(err)
			}
			assertRecoveryCorruptWithoutEdits(t, service, root)
		})
	}
}

func TestRecoveryCredentialProofsAndOversizedRecordClassification(t *testing.T) {
	t.Run("token pepper proof", func(t *testing.T) {
		root := t.TempDir()
		service := openTestService(t, root, nil, 0)
		createTestRoom(t, service)
		if err := service.Close(); err != nil {
			t.Fatal(err)
		}
		before := snapshotFiles(t, root)
		if opened, err := Open(Config{Root: root, TokenPepper: "different-token-pepper-at-least-thirty-two-bytes"}); opened != nil || !errors.Is(err, ErrRecoveryCorrupt) {
			t.Fatalf("Open() = (%v, %v), want ErrRecoveryCorrupt", opened, err)
		}
		if after := snapshotFiles(t, root); !reflect.DeepEqual(after, before) {
			t.Fatalf("pepper recovery edited sources: before=%v after=%v", before, after)
		}
		recovered := openTestService(t, root, nil, 0)
		if recovered.Snapshot().RoomID != testRoomID {
			t.Fatalf("recovered room = %#v", recovered.Snapshot())
		}
	})

	t.Run("oversized committed record", func(t *testing.T) {
		root := t.TempDir()
		store, _, err := journal.Open(root, nil)
		if err != nil {
			t.Fatal(err)
		}
		if err := store.Close(); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "0000000000000001.json"), bytes.Repeat([]byte{'x'}, 2<<20), 0o600); err != nil {
			t.Fatal(err)
		}
		assertOpenCorruptWithoutEdits(t, root)
	})

	t.Run("operational root error stays operational", func(t *testing.T) {
		root := filepath.Join(t.TempDir(), "not-a-directory")
		if err := os.WriteFile(root, []byte("file"), 0o600); err != nil {
			t.Fatal(err)
		}
		opened, err := Open(Config{Root: root, TokenPepper: testPepper})
		if opened != nil || err == nil || errors.Is(err, ErrRecoveryCorrupt) {
			t.Fatalf("Open() = (%v, %v), want non-corruption operational error", opened, err)
		}
	})
}

func TestRecoveryRejectsDuplicateActionsRuleMismatchAndInvalidResultAck(t *testing.T) {
	t.Run("duplicate action id", func(t *testing.T) {
		root := t.TempDir()
		service := openTestService(t, root, nil, 0)
		createTestRoom(t, service)
		_, _ = service.Join(context.Background(), testJoinRequest())
		black := playerWithColor(t, service.Snapshot(), ColorBlack)
		_, _, _, err := service.Apply(context.Background(), ActionRequest{PlayerID: black.PlayerID, ActionID: moveActionID, ExpectedRevision: 0, Type: gomoku.MoveRequested, Payload: json.RawMessage(`{"x":1,"y":1}`)})
		if err != nil {
			t.Fatal(err)
		}
		committed := service.store.Records()[len(service.store.Records())-1]
		revision := int64(2)
		if _, err := service.store.Append(context.Background(), journal.Draft{Type: recordGameEvent, GameRevision: &revision, ActionID: committed.ActionID, Payload: committed.Payload}); err != nil {
			t.Fatal(err)
		}
		assertRecoveryCorruptWithoutEdits(t, service, root)
	})

	t.Run("gomoku rule mismatch", func(t *testing.T) {
		root := t.TempDir()
		service := openTestService(t, root, nil, 0)
		createTestRoom(t, service)
		_, _ = service.Join(context.Background(), testJoinRequest())
		black := playerWithColor(t, service.Snapshot(), ColorBlack)
		actionID := "77777777-7777-4777-8777-777777777777"
		requestPayload := json.RawMessage(`{"x":1,"y":1}`)
		fingerprint := actionFingerprint(black.PlayerID, gomoku.MoveRequested, requestPayload)
		eventPayload := rawJSON(t, map[string]any{"color": "black", "userId": black.PlayerID, "x": 2, "y": 2})
		event := Event{RoomID: testRoomID, Revision: 1, Type: gomoku.MoveAccepted, ActionID: actionID, ActorPlayerID: black.PlayerID, Payload: eventPayload, CommittedAt: 2_000}
		payload := actionRecordPayload{RoomID: testRoomID, Event: event, RequestType: gomoku.MoveRequested, RequestPayload: requestPayload, ActionFingerprint: fingerprint, ExpectedRevision: 0}
		revision := int64(1)
		draft, err := makeDraft(recordGameEvent, &revision, &actionID, payload)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := service.store.Append(context.Background(), draft); err != nil {
			t.Fatal(err)
		}
		assertRecoveryCorruptWithoutEdits(t, service, root)
	})

	t.Run("invalid result acknowledgement", func(t *testing.T) {
		root := t.TempDir()
		service := openTestService(t, root, nil, 0)
		createTestRoom(t, service)
		guest, _ := service.Join(context.Background(), testJoinRequest())
		black := playerWithColor(t, service.Snapshot(), ColorBlack)
		_, _, _, _ = service.Apply(context.Background(), ActionRequest{PlayerID: black.PlayerID, ActionID: moveActionID, ExpectedRevision: 0, Type: gomoku.MoveRequested, Payload: json.RawMessage(`{"x":1,"y":1}`)})
		resigner := guest.Player
		if resigner.PlayerID == black.PlayerID {
			resigner = service.Snapshot().Players[0]
		}
		_, _, _, err := service.Apply(context.Background(), ActionRequest{PlayerID: resigner.PlayerID, ActionID: resignActionID, ExpectedRevision: 1, Type: protocol.TypeGomokuResignRequested, Payload: json.RawMessage(`{}`)})
		if err != nil {
			t.Fatal(err)
		}
		payload := resultPersistedPayload{RoomID: testRoomID, PlayerID: testHostID, ResultHash: strings64("0"), PersistedAt: 2_000}
		draft, _ := makeDraft(recordResultPersisted, nil, nil, payload)
		if _, err := service.store.Append(context.Background(), draft); err != nil {
			t.Fatal(err)
		}
		assertRecoveryCorruptWithoutEdits(t, service, root)
	})
}

func TestRecoveryRejectsJournalGapAndHashTamperWithoutEditingSources(t *testing.T) {
	t.Run("gap", func(t *testing.T) {
		root := t.TempDir()
		service := openTestService(t, root, nil, 0)
		createTestRoom(t, service)
		_, _ = service.Join(context.Background(), testJoinRequest())
		if err := service.Close(); err != nil {
			t.Fatal(err)
		}
		if err := os.Remove(filepath.Join(root, "0000000000000002.json")); err != nil {
			t.Fatal(err)
		}
		assertOpenCorruptWithoutEdits(t, root)
	})

	t.Run("hash tamper", func(t *testing.T) {
		root := t.TempDir()
		service := openTestService(t, root, nil, 0)
		createTestRoom(t, service)
		if err := service.Close(); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(root, "0000000000000001.json")
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		index := bytes.Index(data, []byte(`"hash":"`)) + len(`"hash":"`)
		if index < len(`"hash":"`) || index >= len(data) {
			t.Fatalf("hash field not found: %s", data)
		}
		if data[index] == '0' {
			data[index] = '1'
		} else {
			data[index] = '0'
		}
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		assertOpenCorruptWithoutEdits(t, root)
	})
}

func TestRecoveryIgnoresManifestLag(t *testing.T) {
	root := t.TempDir()
	service := openTestService(t, root, nil, 0)
	createTestRoom(t, service)
	if err := service.store.WriteManifestProjection(testRoomID, gomoku.GameID, "127.0.0.1:32100", 1); err != nil {
		t.Fatal(err)
	}
	if _, err := service.Join(context.Background(), testJoinRequest()); err != nil {
		t.Fatal(err)
	}
	if err := service.Close(); err != nil {
		t.Fatal(err)
	}
	recovered := openTestService(t, root, nil, 0)
	if recovered.Snapshot().Status != StatusActive || len(recovered.Snapshot().Players) != 2 {
		t.Fatalf("manifest-lag recovery = %#v", recovered.Snapshot())
	}
}

var errRoomInjected = errors.New("injected room journal failure")

type faultOps struct {
	renames, syncs int
	failRenameAt   int
	failSyncAt     int
	panicSyncAt    int
}

func (*faultOps) WriteFileSync(path string, data []byte, mode fs.FileMode) (returnErr error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := file.Close(); returnErr == nil && closeErr != nil {
			returnErr = closeErr
		}
	}()
	if _, err := file.Write(data); err != nil {
		return err
	}
	return file.Sync()
}

func (ops *faultOps) Rename(oldPath, newPath string) error {
	ops.renames++
	if ops.renames == ops.failRenameAt {
		return errRoomInjected
	}
	return os.Rename(oldPath, newPath)
}

func (ops *faultOps) SyncDir(path string) error {
	ops.syncs++
	if ops.syncs == ops.failSyncAt {
		return errRoomInjected
	}
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	if err := directory.Sync(); err != nil {
		_ = directory.Close()
		return err
	}
	if err := directory.Close(); err != nil {
		return err
	}
	if ops.syncs == ops.panicSyncAt {
		panic(errRoomInjected)
	}
	return nil
}

func rawJSON(t *testing.T, value any) json.RawMessage {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func strings64(character string) string { return string(bytes.Repeat([]byte(character), 64)) }

func snapshotFiles(t *testing.T, root string) map[string]string {
	t.Helper()
	result := map[string]string{}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		data, err := os.ReadFile(filepath.Join(root, entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		result[entry.Name()] = string(data)
	}
	return result
}

func assertRecoveryCorruptWithoutEdits(t *testing.T, service *Service, root string) {
	t.Helper()
	if err := service.Close(); err != nil {
		t.Fatal(err)
	}
	assertOpenCorruptWithoutEdits(t, root)
}

func assertOpenCorruptWithoutEdits(t *testing.T, root string) {
	t.Helper()
	before := snapshotFiles(t, root)
	for attempt := 1; attempt <= 2; attempt++ {
		opened, err := Open(Config{Root: root, TokenPepper: testPepper})
		if opened != nil {
			_ = opened.Close()
		}
		if !errors.Is(err, ErrRecoveryCorrupt) {
			t.Fatalf("Open attempt %d error = %v, want recovery corrupt (and released root lock)", attempt, err)
		}
	}
	after := snapshotFiles(t, root)
	if !reflect.DeepEqual(after, before) {
		t.Fatal("recovery edited committed source files")
	}
}

func assertInjectedCrash(t *testing.T, operation func()) {
	t.Helper()
	panicked := false
	func() {
		defer func() {
			if recovered := recover(); recovered != nil {
				recoveredErr, ok := recovered.(error)
				if !ok || !errors.Is(recoveredErr, errRoomInjected) {
					t.Fatalf("panic = %v, want injected", recovered)
				}
				panicked = true
			}
		}()
		operation()
	}()
	if !panicked {
		t.Fatal("operation did not reach injected post-sync crash")
	}
}
