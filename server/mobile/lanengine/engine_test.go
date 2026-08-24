package lanengine

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"golang.org/x/sys/unix"

	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/protocol"
)

const (
	engineRoomID      = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	engineHostID      = "11111111-1111-4111-8111-111111111111"
	engineAttemptID   = "33333333-3333-4333-8333-333333333333"
	engineMoveID      = "55555555-5555-4555-8555-555555555555"
	enginePepper      = "engine-token-pepper-at-least-thirty-two-bytes"
	engineRoomKey     = "engine-private-room-key-canary"
	engineHostResume  = "engine-private-host-resume-canary"
	engineGuestResume = "engine-private-guest-resume-canary"
)

func TestEngineRejectsBlankRoot(t *testing.T) {
	for _, root := range []string{"", " \t\n "} {
		if _, err := NewEngine(root); !errors.Is(err, ErrInvalidConfiguration) {
			t.Fatalf("NewEngine(%q) error = %v", root, err)
		}
	}
}

func TestNormalizeNicknameUsesSharedMobileSafeRules(t *testing.T) {
	if got := NormalizeNickname("\u2003Alice 中\u2003"); got != `{"display":"Alice 中","normalized":"alice 中","valid":true}` {
		t.Fatalf("NormalizeNickname valid = %q", got)
	}
	if got := NormalizeNickname("A\u202eB"); got != `{"display":"","normalized":"","valid":false}` {
		t.Fatalf("NormalizeNickname invalid = %q", got)
	}
}

func TestEngineHasStableEmptyStatusAndStrictInputs(t *testing.T) {
	engine, err := NewEngine(t.TempDir())
	if err != nil {
		t.Fatalf("NewEngine valid root: %v", err)
	}
	if got := engine.Status(); got != `{"schemaVersion":1,"state":"empty"}` {
		t.Fatalf("Status() = %q", got)
	}

	validCreate := createJSON()
	invalid := []string{
		`{}`,
		validCreate + `{}`,
		strings.Replace(validCreate, `"schemaVersion":1`, `"schemaVersion":1.0`, 1),
		strings.Replace(validCreate, `"roomId":`, `"extra":true,"roomId":`, 1),
		strings.Replace(validCreate, `"roomId":"`+engineRoomID+`"`, `"roomId":"`+engineRoomID+`","roomId":"`+engineRoomID+`"`, 1),
	}
	for _, input := range invalid {
		if result, err := engine.CreateRoom(input); result != "" || !errors.Is(err, ErrInvalidConfiguration) {
			t.Fatalf("CreateRoom invalid = (%q, %v)", result, err)
		}
	}
	if result, err := engine.Start(`{}`); result != "" || !errors.Is(err, ErrInvalidConfiguration) {
		t.Fatalf("Start invalid = (%q, %v)", result, err)
	}
	if result, err := engine.IssueHostLaunch(); result != "" || !errors.Is(err, ErrNotRunning) {
		t.Fatalf("IssueHostLaunch before start = (%q, %v)", result, err)
	}
	if err := engine.Stop(); err != nil {
		t.Fatalf("idempotent Stop: %v", err)
	}
}

func TestEngineCloseRoomCancelsOnlyRevisionZeroAndStopsForCleanup(t *testing.T) {
	engine, err := NewEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := engine.CreateRoom(createJSON()); err != nil {
		t.Fatal(err)
	}
	created := decodeStatus(t, engine.Status())
	join := postJoin(t, created.Port)
	hostLaunchJSON, err := engine.IssueHostLaunch()
	if err != nil {
		t.Fatal(err)
	}
	hostLaunch := decodeLaunch(t, hostLaunchJSON)
	host := connectEngineWS(t, hostLaunch.WSURL, hostLaunch.LaunchTicket, engineHostResume)
	defer host.CloseNow()
	guest := connectEngineWS(t, hostLaunch.WSURL, join.LaunchTicket, engineGuestResume)
	defer guest.CloseNow()
	_ = readEngineEnvelope(t, host)
	_ = readEngineEnvelope(t, guest)
	closedJSON, err := engine.CloseRoom("cancel")
	if err != nil {
		t.Fatal(err)
	}
	closed := decodeStatus(t, closedJSON)
	if closed.State != "cancelled" || closed.GameRevision != 1 || closed.RoomID != engineRoomID {
		t.Fatalf("cancelled status = %#v", closed)
	}
	for _, connection := range []*websocket.Conn{host, guest} {
		event := readEngineEnvelope(t, connection)
		if event.Type != protocol.TypePlatformMatchCancelled || event.Revision == nil || *event.Revision != 1 {
			t.Fatalf("cancel broadcast = %#v", event)
		}
	}
	preparedJSON, err := engine.PrepareCleanup(false)
	if err != nil {
		t.Fatal(err)
	}
	prepared := decodeStatus(t, preparedJSON)
	if prepared.State != "cancelled" || engine.Status() != `{"schemaVersion":1,"state":"empty"}` {
		t.Fatalf("prepared cleanup = %#v status=%s", prepared, engine.Status())
	}
}

func TestEngineCloseRoomResignsHostThroughAuthoritativePipeline(t *testing.T) {
	root := t.TempDir()
	engine, err := NewEngine(root)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := engine.CreateRoom(createJSON()); err != nil {
		t.Fatal(err)
	}
	created := decodeStatus(t, engine.Status())
	join := postJoin(t, created.Port)
	activateRoomWithOneMove(t, engine, join)
	host := connectEngineWS(t, "ws://127.0.0.1:"+strconv.Itoa(created.Port)+"/lan/v1/ws", "", engineHostResume)
	defer host.CloseNow()
	guest := connectEngineWS(t, "ws://127.0.0.1:"+strconv.Itoa(created.Port)+"/lan/v1/ws", "", engineGuestResume)
	defer guest.CloseNow()
	_ = readEngineEnvelope(t, host)
	_ = readEngineEnvelope(t, guest)

	closedJSON, err := engine.CloseRoom("resign")
	if err != nil {
		t.Fatal(err)
	}
	closed := decodeStatus(t, closedJSON)
	if closed.State != "finished" || closed.GameRevision != 2 || closed.RoomID != engineRoomID {
		t.Fatalf("resigned status = %#v", closed)
	}
	for _, connection := range []*websocket.Conn{host, guest} {
		event := readEngineEnvelope(t, connection)
		if event.Type != protocol.TypeGomokuResigned || event.Revision == nil || *event.Revision != 2 {
			t.Fatalf("resign broadcast = %#v", event)
		}
	}
	if _, err := engine.PrepareCleanup(true); !errors.Is(err, ErrCleanupNotReady) {
		t.Fatalf("cleanup before host ack error = %v", err)
	}
	snapshot := engine.service.Snapshot()
	if snapshot.Result == nil || snapshot.Result.Reason != "resignation" {
		t.Fatalf("resignation result = %#v", snapshot.Result)
	}
	if err := engine.service.AcknowledgeResult(context.Background(), engineHostID, snapshot.Result.ResultHash); err != nil {
		t.Fatal(err)
	}
	if _, err := engine.PrepareCleanup(false); !errors.Is(err, ErrCleanupNotReady) {
		t.Fatalf("all-player cleanup before guest ack error = %v", err)
	}
	preparedJSON, err := engine.PrepareCleanup(true)
	if err != nil {
		t.Fatal(err)
	}
	if prepared := decodeStatus(t, preparedJSON); prepared.State != "finished" || prepared.GameRevision != 2 {
		t.Fatalf("prepared finished cleanup = %#v", prepared)
	}
}

func TestEngineCloseRoomRejectsWrongModeAndRevisionSemantics(t *testing.T) {
	engine, _ := NewEngine(t.TempDir())
	if _, err := engine.CreateRoom(createJSON()); err != nil {
		t.Fatal(err)
	}
	for _, mode := range []string{"", " cancel", "discard_corrupt", "other"} {
		if result, err := engine.CloseRoom(mode); result != "" || !errors.Is(err, ErrInvalidConfiguration) {
			t.Fatalf("CloseRoom(%q) = (%q, %v)", mode, result, err)
		}
	}
	if result, err := engine.CloseRoom("resign"); result != "" || !errors.Is(err, ErrInvalidConfiguration) {
		t.Fatalf("revision-zero resign = (%q, %v)", result, err)
	}
	if status := decodeStatus(t, engine.Status()); status.State != "waiting" || status.GameRevision != 0 {
		t.Fatalf("invalid close mutated room = %#v", status)
	}
	_ = engine.Stop()
}

func TestEngineRealSocketMoveStopReopenAndResume(t *testing.T) {
	root := t.TempDir()
	engine, err := NewEngine(root)
	if err != nil {
		t.Fatal(err)
	}
	createdJSON, err := engine.CreateRoom(createJSON())
	if err != nil {
		t.Fatal(err)
	}
	created := decodeStatus(t, createdJSON)
	if created.State != "waiting" || created.RoomID != engineRoomID || created.Port < 49152 || created.EndpointChanged || created.GameRevision != 0 {
		t.Fatalf("created status = %#v", created)
	}
	launchJSON, err := engine.IssueHostLaunch()
	if err != nil {
		t.Fatal(err)
	}
	hostLaunch := decodeLaunch(t, launchJSON)
	if hostLaunch.SchemaVersion != 1 || hostLaunch.MatchID != engineRoomID || hostLaunch.GameID != gomoku.GameID || hostLaunch.WSURL != "ws://127.0.0.1:"+strconv.Itoa(created.Port)+"/lan/v1/ws" || hostLaunch.LaunchTicket == "" {
		t.Fatalf("host launch semantics = schema=%d match=%q game=%q ws=%q ticketPresent=%v expires=%d", hostLaunch.SchemaVersion, hostLaunch.MatchID, hostLaunch.GameID, hostLaunch.WSURL, hostLaunch.LaunchTicket != "", hostLaunch.ExpiresAt)
	}

	join := postJoin(t, created.Port)
	host := connectEngineWS(t, hostLaunch.WSURL, hostLaunch.LaunchTicket, engineHostResume)
	defer host.CloseNow()
	guest := connectEngineWS(t, hostLaunch.WSURL, join.LaunchTicket, engineGuestResume)
	defer guest.CloseNow()
	hostSnapshot := readEngineEnvelope(t, host)
	guestSnapshot := readEngineEnvelope(t, guest)
	if hostSnapshot.Type != protocol.TypePlatformSnapshot || guestSnapshot.Type != protocol.TypePlatformSnapshot {
		t.Fatal("initial snapshots missing")
	}
	blackID := snapshotBlackID(t, guestSnapshot)
	actor := host
	if blackID == join.PlayerID {
		actor = guest
	}
	writeEngineEnvelope(t, actor, protocol.Envelope{
		ProtocolVersion: protocol.Version1, GameID: gomoku.GameID, MatchID: engineRoomID,
		ExpectedRevision: int64Ptr(0), Type: gomoku.MoveRequested, ActionID: engineMoveID, Payload: json.RawMessage(`{"x":4,"y":4}`),
	})
	beforeRestart := readCommittedSnapshot(t, host, guest)
	if err := engine.Stop(); err != nil {
		t.Fatal(err)
	}
	if got := engine.Status(); got != `{"schemaVersion":1,"state":"empty"}` {
		t.Fatalf("stopped status = %s", got)
	}

	reopened, err := NewEngine(root)
	if err != nil {
		t.Fatal(err)
	}
	startedJSON, err := reopened.Start(startJSON())
	if err != nil {
		t.Fatal(err)
	}
	started := decodeStatus(t, startedJSON)
	if started.RoomID != engineRoomID || started.GameRevision != 1 || started.Port != created.Port || started.EndpointChanged {
		t.Fatalf("reopened status = %#v", started)
	}
	resumed := connectEngineWS(t, "ws://127.0.0.1:"+strconv.Itoa(started.Port)+"/lan/v1/ws", "", engineGuestResume)
	defer resumed.CloseNow()
	afterRestart := readEngineEnvelope(t, resumed)
	if afterRestart.Type != protocol.TypePlatformSnapshot || string(afterRestart.Payload) != string(beforeRestart.Payload) || *afterRestart.Revision != 1 {
		t.Fatalf("recovered snapshot differs")
	}
	if err := reopened.Stop(); err != nil {
		t.Fatal(err)
	}
}

func TestEngineStopClosesUnauthenticatedWebSocketWithoutConsumingTicket(t *testing.T) {
	root := t.TempDir()
	engine, err := NewEngine(root)
	if err != nil {
		t.Fatal(err)
	}
	createdJSON, err := engine.CreateRoom(createJSON())
	if err != nil {
		t.Fatal(err)
	}
	created := decodeStatus(t, createdJSON)
	launchJSON, err := engine.IssueHostLaunch()
	if err != nil {
		t.Fatal(err)
	}
	launch := decodeLaunch(t, launchJSON)

	pending := dialPendingEngineWS(t, launch.WSURL)
	stopped := make(chan error, 1)
	go func() { stopped <- engine.Stop() }()
	select {
	case err := <-stopped:
		if err != nil {
			t.Fatalf("Stop: %v", err)
		}
	case <-time.After(750 * time.Millisecond):
		_ = pending.CloseNow()
		<-stopped
		t.Fatal("Stop blocked on an upgraded WebSocket awaiting its first credential frame")
	}

	readContext, cancelRead := context.WithTimeout(context.Background(), 500*time.Millisecond)
	_, _, readErr := pending.Read(readContext)
	cancelRead()
	if readErr == nil {
		t.Fatal("pending WebSocket peer remained open after Stop")
	}
	lateContext, cancelLate := context.WithTimeout(context.Background(), 500*time.Millisecond)
	_ = pending.Write(lateContext, websocket.MessageText, mustEngineJSON(t, map[string]any{
		"protocolVersion": 1,
		"type":            protocol.TypePlatformConnect,
		"payload": map[string]string{
			"launchTicket": launch.LaunchTicket,
			"resumeToken":  engineHostResume,
		},
	}))
	cancelLate()

	reopened, err := NewEngine(root)
	if err != nil {
		t.Fatal(err)
	}
	startedJSON, err := reopened.Start(startJSON())
	if err != nil {
		t.Fatal(err)
	}
	started := decodeStatus(t, startedJSON)
	if started.RoomID != engineRoomID || started.GameRevision != 0 || started.Port != created.Port {
		t.Fatal("reopened Engine did not recover the unchanged room endpoint")
	}
	connected := connectEngineWS(t, launch.WSURL, launch.LaunchTicket, engineHostResume)
	defer connected.CloseNow()
	if snapshot := readEngineEnvelope(t, connected); snapshot.Type != protocol.TypePlatformSnapshot || snapshot.Revision == nil || *snapshot.Revision != 0 {
		t.Fatal("ticket was consumed by the unauthenticated connection")
	}
	if err := reopened.Stop(); err != nil {
		t.Fatal(err)
	}
}

func TestEngineStartFallsBackWhenPersistedHighPortIsOccupied(t *testing.T) {
	root := t.TempDir()
	engine, _ := NewEngine(root)
	createdJSON, err := engine.CreateRoom(createJSON())
	if err != nil {
		t.Fatal(err)
	}
	created := decodeStatus(t, createdJSON)
	if err := engine.Stop(); err != nil {
		t.Fatal(err)
	}
	occupied, err := net.Listen("tcp4", "0.0.0.0:"+strconv.Itoa(created.Port))
	if err != nil {
		t.Fatal(err)
	}
	defer occupied.Close()
	reopened, _ := NewEngine(root)
	startedJSON, err := reopened.Start(startJSON())
	if err != nil {
		t.Fatal(err)
	}
	started := decodeStatus(t, startedJSON)
	if !started.EndpointChanged || started.Port == created.Port || started.Port < 49152 {
		t.Fatalf("fallback status = %#v", started)
	}
	manifest, err := osReadFile(filepath.Join(root, "active_room", "manifest.json"))
	if err != nil || !strings.Contains(string(manifest), `"endpoint":"0.0.0.0:`+strconv.Itoa(started.Port)+`"`) {
		t.Fatalf("rewritten manifest = %s, %v", manifest, err)
	}
	_ = reopened.Stop()
}

func TestEngineConcurrentStartAndStopAreIdempotent(t *testing.T) {
	root := t.TempDir()
	engine, _ := NewEngine(root)
	if _, err := engine.CreateRoom(createJSON()); err != nil {
		t.Fatal(err)
	}
	var wait sync.WaitGroup
	for range 8 {
		wait.Add(1)
		go func() { defer wait.Done(); _ = engine.Stop() }()
	}
	wait.Wait()
	for range 8 {
		wait.Add(1)
		go func() {
			defer wait.Done()
			if _, err := engine.Start(startJSON()); err != nil {
				t.Errorf("concurrent Start: %v", err)
			}
		}()
	}
	wait.Wait()
	if status := decodeStatus(t, engine.Status()); status.RoomID != engineRoomID || status.Port < 49152 {
		t.Fatalf("concurrent status = %#v", status)
	}
	_ = engine.Stop()
}

func TestEngineManifestIsOnlyPortHintAndCorruptJournalNeverListens(t *testing.T) {
	t.Run("invalid manifest falls back but journal remains authoritative", func(t *testing.T) {
		root := t.TempDir()
		engine, _ := NewEngine(root)
		createdJSON, err := engine.CreateRoom(createJSON())
		if err != nil {
			t.Fatal(err)
		}
		_ = decodeStatus(t, createdJSON)
		if err := engine.Stop(); err != nil {
			t.Fatal(err)
		}
		manifestPath := filepath.Join(root, "active_room", "manifest.json")
		if err := os.WriteFile(manifestPath, []byte(`{"schemaVersion":1,"roomId":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","gameId":"gomoku","createdAt":1,"endpoint":"0.0.0.0:50000","journalFormatVersion":1,"journalSequence":1}`), 0o600); err != nil {
			t.Fatal(err)
		}
		reopened, _ := NewEngine(root)
		startedJSON, err := reopened.Start(startJSON())
		if err != nil {
			t.Fatal(err)
		}
		started := decodeStatus(t, startedJSON)
		if started.State != "waiting" || started.RoomID != engineRoomID || started.GameRevision != 0 || !started.EndpointChanged || started.Port < 49152 {
			t.Fatalf("manifest influenced authoritative state: %#v", started)
		}
		_ = reopened.Stop()
	})

	t.Run("corrupt journal reports corrupt without listener", func(t *testing.T) {
		root := t.TempDir()
		engine, _ := NewEngine(root)
		createdJSON, err := engine.CreateRoom(createJSON())
		if err != nil {
			t.Fatal(err)
		}
		created := decodeStatus(t, createdJSON)
		if err := engine.Stop(); err != nil {
			t.Fatal(err)
		}
		recordPath := filepath.Join(root, "active_room", "0000000000000001.json")
		data, err := os.ReadFile(recordPath)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(recordPath, append(data, byte('x')), 0o600); err != nil {
			t.Fatal(err)
		}
		reopened, _ := NewEngine(root)
		statusJSON, err := reopened.Start(startJSON())
		if err != nil {
			t.Fatal(err)
		}
		status := decodeStatus(t, statusJSON)
		if status.State != "corrupt" || status.RoomID != engineRoomID || status.Port != 0 {
			t.Fatalf("corrupt status = %#v", status)
		}
		connection, dialErr := net.DialTimeout("tcp4", "127.0.0.1:"+strconv.Itoa(created.Port), 100*time.Millisecond)
		if dialErr == nil {
			_ = connection.Close()
			t.Fatal("corrupt recovery started a listener")
		}
		if result, issueErr := reopened.IssueHostLaunch(); result != "" || !errors.Is(issueErr, ErrNotRunning) {
			t.Fatalf("corrupt IssueHostLaunch = (%q, %v)", result, issueErr)
		}
		_ = reopened.Stop()
	})
}

func TestReadManifestFileRejectsOversizedRegularFile(t *testing.T) {
	manifestPath := filepath.Join(t.TempDir(), "manifest.json")
	if err := os.WriteFile(manifestPath, bytes.Repeat([]byte{'x'}, maximumJSONBytes+1), 0o600); err != nil {
		t.Fatal(err)
	}
	data, err := readManifestFile(manifestPath)
	if err == nil || len(data) != 0 {
		t.Fatalf("oversized manifest read = (%d bytes, error=%v), want bounded rejection", len(data), err)
	}
}

func TestEngineHostileManifestHintsFallbackPromptly(t *testing.T) {
	for _, test := range []struct {
		name    string
		install func(*testing.T, string, []byte)
	}{
		{
			name: "oversized regular file",
			install: func(t *testing.T, path string, _ []byte) {
				t.Helper()
				if err := os.WriteFile(path, bytes.Repeat([]byte{'x'}, maximumJSONBytes+1), 0o600); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "symlink",
			install: func(t *testing.T, path string, valid []byte) {
				t.Helper()
				target := filepath.Join(filepath.Dir(filepath.Dir(path)), "manifest-target.json")
				if err := os.WriteFile(target, valid, 0o600); err != nil {
					t.Fatal(err)
				}
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(target, path); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "fifo",
			install: func(t *testing.T, path string, _ []byte) {
				t.Helper()
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
				if err := unix.Mkfifo(path, 0o600); err != nil {
					t.Fatal(err)
				}
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			engine, _ := NewEngine(root)
			createdJSON, err := engine.CreateRoom(createJSON())
			if err != nil {
				t.Fatal(err)
			}
			created := decodeStatus(t, createdJSON)
			if err := engine.Stop(); err != nil {
				t.Fatal(err)
			}
			manifestPath := filepath.Join(root, "active_room", "manifest.json")
			validManifest, err := os.ReadFile(manifestPath)
			if err != nil {
				t.Fatal(err)
			}
			test.install(t, manifestPath, validManifest)

			reopened, _ := NewEngine(root)
			startedJSON, err := startEnginePromptly(t, reopened, manifestPath)
			if err != nil {
				t.Fatal(err)
			}
			started := decodeStatus(t, startedJSON)
			if started.RoomID != engineRoomID || started.GameRevision != 0 || !started.EndpointChanged || started.Port < minimumLANPort || started.Port > maximumLANPort {
				t.Fatalf("hostile manifest fallback status = state=%q room=%q revision=%d changed=%v port=%d", started.State, started.RoomID, started.GameRevision, started.EndpointChanged, started.Port)
			}
			if test.name == "symlink" && started.Port == created.Port {
				t.Fatal("symlink manifest was followed as a preferred endpoint")
			}
			_ = reopened.Stop()
		})
	}
}

func TestEngineCorruptJournalWithFIFOManifestNeverListens(t *testing.T) {
	root := t.TempDir()
	engine, _ := NewEngine(root)
	createdJSON, err := engine.CreateRoom(createJSON())
	if err != nil {
		t.Fatal(err)
	}
	created := decodeStatus(t, createdJSON)
	if err := engine.Stop(); err != nil {
		t.Fatal(err)
	}
	recordPath := filepath.Join(root, "active_room", "0000000000000001.json")
	data, err := os.ReadFile(recordPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(recordPath, append(data, byte('x')), 0o600); err != nil {
		t.Fatal(err)
	}
	manifestPath := filepath.Join(root, "active_room", "manifest.json")
	if err := os.Remove(manifestPath); err != nil {
		t.Fatal(err)
	}
	if err := unix.Mkfifo(manifestPath, 0o600); err != nil {
		t.Fatal(err)
	}
	reopened, _ := NewEngine(root)
	statusJSON, err := startEnginePromptly(t, reopened, manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	status := decodeStatus(t, statusJSON)
	if status.State != "corrupt" || status.RoomID != engineRoomID || status.Port != 0 {
		t.Fatalf("corrupt hostile-manifest status = state=%q room=%q port=%d", status.State, status.RoomID, status.Port)
	}
	connection, dialErr := net.DialTimeout("tcp4", "127.0.0.1:"+strconv.Itoa(created.Port), 100*time.Millisecond)
	if dialErr == nil {
		_ = connection.Close()
		t.Fatal("corrupt recovery with hostile manifest started a listener")
	}
	_ = reopened.Stop()
}

func TestEngineDeleteActiveRoomRequiresStoppedEngineAndRemovesOnlyResolvedTree(t *testing.T) {
	root := t.TempDir()
	engine, _ := NewEngine(root)
	if _, err := engine.CreateRoom(createJSON()); err != nil {
		t.Fatal(err)
	}
	if err := engine.DeleteActiveRoom(); !errors.Is(err, ErrCleanupNotReady) {
		t.Fatalf("DeleteActiveRoom while running error = %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "active_room", "manifest.json")); err != nil {
		t.Fatalf("running room was changed: %v", err)
	}
	if err := engine.Stop(); err != nil {
		t.Fatal(err)
	}
	if err := engine.DeleteActiveRoom(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(filepath.Join(root, "active_room")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("active room remains after delete: %v", err)
	}
}

func TestEngineStopFailureRetainsOwnerAndAuthorityUntilRetrySucceeds(t *testing.T) {
	root := t.TempDir()
	active := filepath.Join(root, "active_room")
	if err := os.MkdirAll(active, 0o700); err != nil {
		t.Fatal(err)
	}
	journalPath := filepath.Join(active, "0000000000000001.json")
	wantJournal := []byte("recoverable-authority")
	if err := os.WriteFile(journalPath, wantJournal, 0o600); err != nil {
		t.Fatal(err)
	}
	engine, _ := NewEngine(root)
	listener := &failOnceListener{closeError: errors.New("close failed")}
	engine.listener = listener
	engine.secrets = roomSecrets{RoomID: engineRoomID, HostResumeToken: engineHostResume}
	engine.port = minimumLANPort

	if err := engine.Stop(); !errors.Is(err, ErrInternal) {
		t.Fatalf("first Stop error = %v, want ErrInternal", err)
	}
	if listener.closeCalls != 1 || engine.listener != listener {
		t.Fatalf("failed listener ownership was lost: calls=%d owner=%T", listener.closeCalls, engine.listener)
	}
	if engine.secrets.RoomID != engineRoomID || engine.port != minimumLANPort {
		t.Fatal("recoverable authority was cleared after ambiguous stop failure")
	}
	if err := engine.DeleteActiveRoom(); !errors.Is(err, ErrCleanupNotReady) {
		t.Fatalf("DeleteActiveRoom after failed Stop error = %v, want ErrCleanupNotReady", err)
	}
	if got, err := os.ReadFile(journalPath); err != nil || !bytes.Equal(got, wantJournal) {
		t.Fatalf("journal changed after failed Stop: data=%q err=%v", got, err)
	}

	if err := engine.Stop(); err != nil {
		t.Fatalf("retry Stop error = %v", err)
	}
	if listener.closeCalls != 2 || engine.listener != nil {
		t.Fatalf("failed listener was not retried exactly once: calls=%d owner=%T", listener.closeCalls, engine.listener)
	}
	if err := engine.DeleteActiveRoom(); err != nil {
		t.Fatalf("DeleteActiveRoom after successful retry error = %v", err)
	}
}

func TestEngineDeleteActiveRoomRejectsSymlinkAndFIFOWithoutTouchingOutside(t *testing.T) {
	for _, hostile := range []string{"symlink", "fifo"} {
		t.Run(hostile, func(t *testing.T) {
			root := t.TempDir()
			active := filepath.Join(root, "active_room")
			nested := filepath.Join(active, "journal")
			if err := os.MkdirAll(nested, 0o700); err != nil {
				t.Fatal(err)
			}
			manifestPath := filepath.Join(active, "manifest.json")
			manifestBytes := []byte("manifest-authority")
			journalPath := filepath.Join(nested, "0000000000000001.json")
			journalBytes := []byte("journal-authority")
			if err := os.WriteFile(manifestPath, manifestBytes, 0o600); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(journalPath, journalBytes, 0o600); err != nil {
				t.Fatal(err)
			}
			outside := filepath.Join(t.TempDir(), "outside")
			if err := os.WriteFile(outside, []byte("preserve"), 0o600); err != nil {
				t.Fatal(err)
			}
			hostilePath := filepath.Join(active, "hostile")
			var err error
			if hostile == "symlink" {
				err = os.Symlink(outside, hostilePath)
			} else {
				err = unix.Mkfifo(hostilePath, 0o600)
			}
			if err != nil {
				t.Fatal(err)
			}
			engine, _ := NewEngine(root)
			if err := engine.DeleteActiveRoom(); !errors.Is(err, ErrInternal) {
				t.Fatalf("DeleteActiveRoom hostile error = %v", err)
			}
			if data, err := os.ReadFile(outside); err != nil || string(data) != "preserve" {
				t.Fatalf("outside file changed: data=%q err=%v", data, err)
			}
			if _, err := os.Lstat(hostilePath); err != nil {
				t.Fatalf("hostile evidence was removed: %v", err)
			}
			if data, err := os.ReadFile(manifestPath); err != nil || !bytes.Equal(data, manifestBytes) {
				t.Fatalf("manifest changed before hostile preflight failed: data=%q err=%v", data, err)
			}
			if data, err := os.ReadFile(journalPath); err != nil || !bytes.Equal(data, journalBytes) {
				t.Fatalf("journal changed before hostile preflight failed: data=%q err=%v", data, err)
			}
		})
	}
}

func TestOpenedDirectoryMustMatchInitialIdentityBeforeReadingChildren(t *testing.T) {
	initial := unix.Stat_t{Dev: 11, Ino: 22, Mode: unix.S_IFDIR | 0o700, Uid: 501}

	for name, opened := range map[string]unix.Stat_t{
		"device": {Dev: 12, Ino: 22, Mode: unix.S_IFDIR | 0o700, Uid: 501},
		"inode":  {Dev: 11, Ino: 23, Mode: unix.S_IFDIR | 0o700, Uid: 501},
		"type":   {Dev: 11, Ino: 22, Mode: unix.S_IFREG | 0o600, Uid: 501},
		"owner":  {Dev: 11, Ino: 22, Mode: unix.S_IFDIR | 0o700, Uid: 502},
	} {
		t.Run(name, func(t *testing.T) {
			if err := requireSameDirectoryIdentity(initial, opened, 501); err == nil {
				t.Fatal("requireSameDirectoryIdentity() error = nil")
			}
		})
	}

	if err := requireSameDirectoryIdentity(initial, initial, 501); err != nil {
		t.Fatalf("requireSameDirectoryIdentity() error = %v", err)
	}
	foreign := initial
	foreign.Uid = 502
	if err := requireSameDirectoryIdentity(foreign, foreign, 501); err == nil {
		t.Fatal("consistently foreign-owned directory was accepted")
	}
}

func TestUnlinkIdentityRequiresExpectedOwnerForRegularFiles(t *testing.T) {
	initial := unix.Stat_t{Dev: 11, Ino: 22, Mode: unix.S_IFREG | 0o600, Uid: 501}
	if err := requireSameOwnedEntryIdentity(initial, initial, 501); err != nil {
		t.Fatalf("owned regular identity error = %v", err)
	}
	foreign := initial
	foreign.Uid = 502
	if err := requireSameOwnedEntryIdentity(foreign, foreign, 501); err == nil {
		t.Fatal("consistently foreign-owned regular file was accepted")
	}
	changedOwner := initial
	changedOwner.Uid = 502
	if err := requireSameOwnedEntryIdentity(initial, changedOwner, 501); err == nil {
		t.Fatal("regular file owner change was accepted")
	}
}

func startEnginePromptly(t *testing.T, engine *Engine, fifoPath string) (string, error) {
	t.Helper()
	type result struct {
		status string
		err    error
	}
	completed := make(chan result, 1)
	go func() {
		status, err := engine.Start(startJSON())
		completed <- result{status: status, err: err}
	}()
	select {
	case value := <-completed:
		return value.status, value.err
	case <-time.After(500 * time.Millisecond):
		if info, err := os.Lstat(fifoPath); err == nil && info.Mode()&os.ModeNamedPipe != 0 {
			if descriptor, openErr := unix.Open(fifoPath, unix.O_WRONLY|unix.O_NONBLOCK|unix.O_CLOEXEC, 0); openErr == nil {
				_ = unix.Close(descriptor)
			}
		}
		select {
		case <-completed:
		case <-time.After(2 * time.Second):
		}
		t.Fatal("Engine.Start blocked while reading an untrusted manifest hint")
		return "", nil
	}
}

func TestEngineSecretBearingValuesAndStatusFormattingAreRedacted(t *testing.T) {
	engine, _ := NewEngine(t.TempDir())
	secrets := roomSecrets{RoomID: engineRoomID, HostPlayerID: engineHostID, TokenPepper: enginePepper, HostResumeToken: engineHostResume}
	create := createRoomRequest{roomSecrets: secrets, HostNickname: "private nickname", RoomKey: engineRoomKey, JoinExpiresAt: time.Now().Add(time.Hour).UnixMilli()}
	launch := launchResponse{SchemaVersion: 1, MatchID: engineRoomID, GameID: gomoku.GameID, LaunchTicket: "private-ticket", WSURL: "ws://127.0.0.1:50000/lan/v1/ws", ExpiresAt: 1}
	formatted := fmt.Sprintf("%+v %#v %+v %#v %+v %#v %+v %#v", engine, engine, secrets, secrets, create, create, launch, launch)
	for _, secret := range []string{enginePepper, engineHostResume, engineRoomKey, "private nickname", "private-ticket"} {
		if strings.Contains(formatted, secret) || strings.Contains(engine.Status(), secret) {
			t.Fatalf("formatted engine value exposed secret")
		}
	}
}

type engineStatus struct {
	SchemaVersion   int    `json:"schemaVersion"`
	State           string `json:"state"`
	RoomID          string `json:"roomId"`
	Port            int    `json:"port"`
	GameRevision    int64  `json:"gameRevision"`
	EndpointChanged bool   `json:"endpointChanged"`
}

type engineLaunch struct {
	SchemaVersion int    `json:"schemaVersion"`
	MatchID       string `json:"matchId"`
	GameID        string `json:"gameId"`
	LaunchTicket  string `json:"launchTicket"`
	WSURL         string `json:"wsUrl"`
	ExpiresAt     int64  `json:"expiresAt"`
}

type engineJoin struct {
	PlayerID     string `json:"playerId"`
	LaunchTicket string `json:"launchTicket"`
}

type failOnceListener struct {
	closeCalls int
	closeError error
}

func (*failOnceListener) Accept() (net.Conn, error) { return nil, net.ErrClosed }
func (*failOnceListener) Addr() net.Addr            { return &net.TCPAddr{} }
func (listener *failOnceListener) Close() error {
	listener.closeCalls++
	if listener.closeCalls == 1 {
		return listener.closeError
	}
	return nil
}

func createJSON() string {
	return fmt.Sprintf(`{"schemaVersion":1,"roomId":"%s","hostPlayerId":"%s","hostNickname":"Host","roomKey":"%s","tokenPepper":"%s","hostResumeToken":"%s","joinExpiresAt":%d}`,
		engineRoomID, engineHostID, engineRoomKey, enginePepper, engineHostResume, time.Now().Add(time.Hour).UnixMilli())
}

func startJSON() string {
	return fmt.Sprintf(`{"schemaVersion":1,"roomId":"%s","hostPlayerId":"%s","tokenPepper":"%s","hostResumeToken":"%s"}`,
		engineRoomID, engineHostID, enginePepper, engineHostResume)
}

func decodeStatus(t *testing.T, data string) engineStatus {
	t.Helper()
	var status engineStatus
	if err := json.Unmarshal([]byte(data), &status); err != nil || status.SchemaVersion != 1 {
		t.Fatalf("decode status %q: %v", data, err)
	}
	return status
}

func decodeLaunch(t *testing.T, data string) engineLaunch {
	t.Helper()
	var launch engineLaunch
	if err := json.Unmarshal([]byte(data), &launch); err != nil {
		t.Fatalf("decode launch response: %v", err)
	}
	return launch
}

func postJoin(t *testing.T, port int) engineJoin {
	t.Helper()
	body := fmt.Sprintf(`{"roomId":"%s","nickname":"Guest","joinAttemptId":"%s","candidateResumeToken":"%s","roomKey":"%s"}`,
		engineRoomID, engineAttemptID, engineGuestResume, engineRoomKey)
	request, err := http.NewRequest(http.MethodPost, "http://127.0.0.1:"+strconv.Itoa(port)+"/lan/v1/rooms/"+engineRoomID+"/join", strings.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 2 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(response.Body, 64*1024+1))
	if response.StatusCode != http.StatusOK {
		t.Fatalf("join status %d with %d-byte body", response.StatusCode, len(data))
	}
	var joined engineJoin
	if json.Unmarshal(data, &joined) != nil || joined.PlayerID == "" || joined.LaunchTicket == "" {
		t.Fatalf("join response semantics = playerPresent=%v ticketPresent=%v bodyBytes=%d", joined.PlayerID != "", joined.LaunchTicket != "", len(data))
	}
	return joined
}

func connectEngineWS(t *testing.T, wsURL, launchTicket, resumeToken string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	connection, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	payload := map[string]string{"resumeToken": resumeToken}
	if launchTicket != "" {
		payload["launchTicket"] = launchTicket
	}
	writeEngineEnvelope(t, connection, protocol.Envelope{ProtocolVersion: 1, Type: protocol.TypePlatformConnect, Payload: mustEngineJSON(t, payload)})
	if connected := readEngineEnvelope(t, connection); connected.Type != protocol.TypePlatformConnected {
		t.Fatalf("connected frame type=%q revision=%v", connected.Type, connected.Revision)
	}
	return connection
}

func dialPendingEngineWS(t *testing.T, wsURL string) *websocket.Conn {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
		connection, _, err := websocket.Dial(ctx, wsURL, nil)
		cancel()
		if err == nil {
			return connection
		}
		if time.Now().After(deadline) {
			t.Fatal("pending WebSocket endpoint did not become ready before deadline")
		}
		timer := time.NewTimer(10 * time.Millisecond)
		<-timer.C
	}
}

func readCommittedSnapshot(t *testing.T, host, guest *websocket.Conn) protocol.Envelope {
	t.Helper()
	for _, connection := range []*websocket.Conn{host, guest} {
		if event := readEngineEnvelope(t, connection); event.Type != gomoku.MoveAccepted || event.Revision == nil || *event.Revision != 1 {
			t.Fatalf("move event = %#v", event)
		}
	}
	writeEngineEnvelope(t, host, protocol.Envelope{
		ProtocolVersion: 1, GameID: gomoku.GameID, MatchID: engineRoomID,
		Type: protocol.TypePlatformSnapshotRequested, Payload: json.RawMessage(`{"currentRevision":0}`),
	})
	snapshot := readEngineEnvelope(t, host)
	if snapshot.Type != protocol.TypePlatformSnapshot || snapshot.Revision == nil || *snapshot.Revision != 1 {
		t.Fatalf("committed snapshot = %#v", snapshot)
	}
	return snapshot
}

func activateRoomWithOneMove(t *testing.T, engine *Engine, join engineJoin) {
	t.Helper()
	launchJSON, err := engine.IssueHostLaunch()
	if err != nil {
		t.Fatal(err)
	}
	launch := decodeLaunch(t, launchJSON)
	host := connectEngineWS(t, launch.WSURL, launch.LaunchTicket, engineHostResume)
	defer host.CloseNow()
	guest := connectEngineWS(t, launch.WSURL, join.LaunchTicket, engineGuestResume)
	defer guest.CloseNow()
	hostSnapshot := readEngineEnvelope(t, host)
	guestSnapshot := readEngineEnvelope(t, guest)
	if hostSnapshot.Type != protocol.TypePlatformSnapshot || guestSnapshot.Type != protocol.TypePlatformSnapshot {
		t.Fatal("initial snapshots missing")
	}
	actor := host
	if snapshotBlackID(t, guestSnapshot) == join.PlayerID {
		actor = guest
	}
	writeEngineEnvelope(t, actor, protocol.Envelope{
		ProtocolVersion: protocol.Version1, GameID: gomoku.GameID, MatchID: engineRoomID,
		ExpectedRevision: int64Ptr(0), Type: gomoku.MoveRequested, ActionID: engineMoveID,
		Payload: json.RawMessage(`{"x":4,"y":4}`),
	})
	_ = readCommittedSnapshot(t, host, guest)
}

func snapshotBlackID(t *testing.T, envelope protocol.Envelope) string {
	t.Helper()
	var payload struct {
		BlackUserID string `json:"blackUserId"`
	}
	if json.Unmarshal(envelope.Payload, &payload) != nil || payload.BlackUserID == "" {
		t.Fatal("snapshot black user missing")
	}
	return payload.BlackUserID
}

func writeEngineEnvelope(t *testing.T, connection *websocket.Conn, envelope protocol.Envelope) {
	t.Helper()
	data, err := json.Marshal(envelope)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := connection.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
}

func readEngineEnvelope(t *testing.T, connection *websocket.Conn) protocol.Envelope {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	messageType, data, err := connection.Read(ctx)
	if err != nil || messageType != websocket.MessageText {
		t.Fatalf("read frame = (%d, %v)", messageType, err)
	}
	envelope, err := protocol.Decode(data)
	if err != nil {
		t.Fatal(err)
	}
	return envelope
}

func mustEngineJSON(t *testing.T, value any) json.RawMessage {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func int64Ptr(value int64) *int64 { return &value }

func osReadFile(path string) ([]byte, error) { return os.ReadFile(path) }

func TestBoundPackageHasNoForbiddenImports(t *testing.T) {
	forbidden := []string{"modernc.org/sqlite", "/internal/auth", "/internal/users", "/internal/matches"}
	output := goListDeps(t, "me.zqydev/gamebox/server/mobile/lanengine")
	for _, fragment := range forbidden {
		if strings.Contains(output, fragment) {
			t.Fatalf("mobile dependency closure contains %q", fragment)
		}
	}
}

func goListDeps(t *testing.T, packagePath string) string {
	t.Helper()
	command := exec.Command("go", "list", "-deps", packagePath)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("go list -deps %s: %v\n%s", packagePath, err, output)
	}
	return string(output)
}
