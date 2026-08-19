package httpapi_test

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/protocol"
	"me.zqydev/gamebox/server/internal/testutil"
)

const e2eTimeout = 5 * time.Second

type expectedMoveEvent struct {
	matchID, actionID string
	actorID           string
	blackID, whiteID  string
	revision          int64
	x, y              int
}

type envelopeRead struct {
	envelope protocol.Envelope
	err      error
}

func TestDurableTwoPlayerMatchHappyPath(t *testing.T) {
	t.Parallel()

	serviceClock := clock.NewFake(time.Date(2026, time.August, 20, 8, 0, 0, 0, time.UTC))
	server := startServer(t, filepath.Join(t.TempDir(), "gamebox.sqlite"), serviceClock, 1)
	defer closeServer(t, server)

	ctx, cancel := context.WithTimeout(context.Background(), e2eTimeout)
	defer cancel()
	invites, err := server.CreateInvites(ctx, 2)
	if err != nil {
		t.Fatalf("create invites: %v", err)
	}
	alice, err := server.API.Register(ctx, invites[0], "Alice")
	if err != nil {
		t.Fatalf("register Alice: %v", err)
	}
	bob, err := server.API.Register(ctx, invites[1], "Bob")
	if err != nil {
		t.Fatalf("register Bob: %v", err)
	}
	assertInvitesAreStoredOnlyAsDigests(t, server, invites)

	created, err := server.API.CreateGomokuMatch(ctx, alice.AccessToken, bob.User.ID)
	if err != nil {
		t.Fatalf("create match: %v", err)
	}
	aliceTicket, err := server.API.CreateLaunchTicket(ctx, alice.AccessToken, created.ID)
	if err != nil {
		t.Fatalf("Alice launch ticket: %v", err)
	}
	bobTicket, err := server.API.CreateLaunchTicket(ctx, bob.AccessToken, created.ID)
	if err != nil {
		t.Fatalf("Bob launch ticket: %v", err)
	}

	aliceWS, err := server.DialWebSocket(ctx)
	if err != nil {
		t.Fatalf("dial Alice: %v", err)
	}
	aliceHandshake, err := aliceWS.ConnectLaunch(ctx, aliceTicket.LaunchTicket)
	if err != nil {
		t.Fatalf("connect Alice: %v", err)
	}
	bobWS, err := server.DialWebSocket(ctx)
	if err != nil {
		t.Fatalf("dial Bob: %v", err)
	}
	bobHandshake, err := bobWS.ConnectLaunch(ctx, bobTicket.LaunchTicket)
	if err != nil {
		t.Fatalf("connect Bob: %v", err)
	}
	if !snapshotsEqual(aliceHandshake.Snapshot, bobHandshake.Snapshot) {
		t.Fatalf("initial snapshots differ: Alice=%+v Bob=%+v", aliceHandshake.Snapshot, bobHandshake.Snapshot)
	}

	clients := map[string]*testutil.WebSocketClient{alice.User.ID: aliceWS, bob.User.ID: bobWS}
	black := aliceHandshake.Snapshot.BlackUserID
	white := aliceHandshake.Snapshot.WhiteUserID
	if clients[black] == nil || clients[white] == nil || black == white {
		t.Fatalf("invalid random colors black=%q white=%q", black, white)
	}
	winningMoves := []struct {
		userID string
		x      int
		y      int
	}{
		{black, 0, 0}, {white, 0, 1},
		{black, 1, 0}, {white, 1, 1},
		{black, 2, 0}, {white, 2, 1},
		{black, 3, 0}, {white, 3, 1},
		{black, 4, 0},
	}
	for index, move := range winningMoves {
		revision := int64(index)
		if err := clients[move.userID].SendMove(ctx, created.ID, actionID(index+1), revision, move.x, move.y); err != nil {
			t.Fatalf("send move %d: %v", index+1, err)
		}
		aliceEvent, err := aliceWS.ReadEnvelope(ctx)
		if err != nil {
			t.Fatalf("Alice read move %d: %v", index+1, err)
		}
		bobEvent, err := bobWS.ReadEnvelope(ctx)
		if err != nil {
			t.Fatalf("Bob read move %d: %v", index+1, err)
		}
		assertSameMoveEvent(t, aliceEvent, bobEvent, expectedMoveEvent{
			matchID: created.ID, actionID: actionID(index + 1), actorID: move.userID,
			blackID: black, whiteID: white, revision: revision + 1, x: move.x, y: move.y,
		})
	}

	terminalAlice := requestSnapshot(t, ctx, aliceWS, created.ID, int64(len(winningMoves)))
	terminalBob := requestSnapshot(t, ctx, bobWS, created.ID, int64(len(winningMoves)))
	if !snapshotsEqual(terminalAlice, terminalBob) || terminalAlice.Status != "finished" || terminalAlice.Result == nil || *terminalAlice.Result != "five" || terminalAlice.WinnerUserID == nil || *terminalAlice.WinnerUserID != black {
		t.Fatalf("terminal snapshots Alice=%+v Bob=%+v", terminalAlice, terminalBob)
	}
	for _, session := range []testutil.Session{alice, bob} {
		status, err := server.API.GomokuStatus(ctx, session.AccessToken)
		if err != nil || status.State != "idle" || status.Match != nil {
			t.Fatalf("terminal status for %s=(%+v,%v)", session.User.ID, status, err)
		}
	}

	again, err := server.API.CreateGomokuMatch(ctx, bob.AccessToken, alice.User.ID)
	if err != nil || again.ID == created.ID {
		t.Fatalf("create after slot release=(%+v,%v)", again, err)
	}
	assertSecretsAbsent(t, server.Logs(), append([]string{alice.AccessToken, alice.RefreshToken, bob.AccessToken, bob.RefreshToken, aliceTicket.LaunchTicket, bobTicket.LaunchTicket, aliceHandshake.Connected.ResumeToken, bobHandshake.Connected.ResumeToken}, invites...)...)
}

func TestGomokuSnapshotDecoderRequiresExactBoardAndPayloadFields(t *testing.T) {
	t.Parallel()

	const (
		matchID = "11111111-1111-4111-8111-111111111111"
		blackID = "22222222-2222-4222-8222-222222222222"
		whiteID = "33333333-3333-4333-8333-333333333333"
	)
	validPayload := func() map[string]any {
		return map[string]any{
			"status":       "active",
			"board":        make([]int, gomoku.BoardSize*gomoku.BoardSize),
			"boardSize":    gomoku.BoardSize,
			"blackUserId":  blackID,
			"whiteUserId":  whiteID,
			"nextColor":    "black",
			"winnerUserId": nil,
			"result":       nil,
		}
	}
	envelope := func(t *testing.T, payload map[string]any) protocol.Envelope {
		t.Helper()
		encoded, err := json.Marshal(payload)
		if err != nil {
			t.Fatal(err)
		}
		revision := int64(0)
		return protocol.Envelope{
			ProtocolVersion: protocol.Version1, GameID: gomoku.GameID, MatchID: matchID,
			Revision: &revision, Type: protocol.TypePlatformSnapshot, Payload: encoded,
		}
	}
	if snapshot, err := testutil.DecodeGomokuSnapshot(envelope(t, validPayload())); err != nil || snapshot.BoardSize != gomoku.BoardSize {
		t.Fatalf("valid snapshot=(%+v,%v)", snapshot, err)
	}

	tests := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{name: "missing board", mutate: func(payload map[string]any) { delete(payload, "board") }},
		{name: "short board", mutate: func(payload map[string]any) { payload["board"] = make([]int, gomoku.BoardSize*gomoku.BoardSize-1) }},
		{name: "long board", mutate: func(payload map[string]any) { payload["board"] = make([]int, gomoku.BoardSize*gomoku.BoardSize+1) }},
		{name: "missing winner", mutate: func(payload map[string]any) { delete(payload, "winnerUserId") }},
		{name: "missing result", mutate: func(payload map[string]any) { delete(payload, "result") }},
		{name: "unknown field", mutate: func(payload map[string]any) { payload["privateState"] = true }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			payload := validPayload()
			test.mutate(payload)
			if snapshot, err := testutil.DecodeGomokuSnapshot(envelope(t, payload)); err == nil {
				t.Fatalf("malformed snapshot accepted: %+v", snapshot)
			}
		})
	}
}

func TestThreeMoveSnapshotValidatorRejectsAnyUnexpectedState(t *testing.T) {
	t.Parallel()

	const (
		matchID = "11111111-1111-4111-8111-111111111111"
		blackID = "22222222-2222-4222-8222-222222222222"
		whiteID = "33333333-3333-4333-8333-333333333333"
	)
	valid := testutil.GomokuSnapshot{
		GameID: gomoku.GameID, MatchID: matchID, Revision: 3, Status: "active",
		BoardSize: gomoku.BoardSize, BlackUserID: blackID, WhiteUserID: whiteID,
		NextColor: "white",
	}
	valid.Board[0*gomoku.BoardSize+0] = 1
	valid.Board[1*gomoku.BoardSize+0] = 2
	valid.Board[0*gomoku.BoardSize+1] = 1
	if err := validateThreeMoveSnapshot(valid, matchID, blackID, whiteID); err != nil {
		t.Fatalf("valid three-move snapshot: %v", err)
	}

	tests := []struct {
		name   string
		mutate func(*testutil.GomokuSnapshot)
	}{
		{name: "match", mutate: func(snapshot *testutil.GomokuSnapshot) { snapshot.MatchID = whiteID }},
		{name: "revision", mutate: func(snapshot *testutil.GomokuSnapshot) { snapshot.Revision = 2 }},
		{name: "status", mutate: func(snapshot *testutil.GomokuSnapshot) { snapshot.Status = "finished" }},
		{name: "next color", mutate: func(snapshot *testutil.GomokuSnapshot) { snapshot.NextColor = "black" }},
		{name: "actor colors", mutate: func(snapshot *testutil.GomokuSnapshot) {
			snapshot.BlackUserID, snapshot.WhiteUserID = snapshot.WhiteUserID, snapshot.BlackUserID
		}},
		{name: "missing move", mutate: func(snapshot *testutil.GomokuSnapshot) { snapshot.Board[1*gomoku.BoardSize+0] = 0 }},
		{name: "wrong move color", mutate: func(snapshot *testutil.GomokuSnapshot) { snapshot.Board[1*gomoku.BoardSize+0] = 1 }},
		{name: "extra move", mutate: func(snapshot *testutil.GomokuSnapshot) { snapshot.Board[14*gomoku.BoardSize+14] = 2 }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			mutated := valid
			test.mutate(&mutated)
			if err := validateThreeMoveSnapshot(mutated, matchID, blackID, whiteID); err == nil {
				t.Fatalf("unexpected snapshot accepted: %+v", mutated)
			}
		})
	}
}

func TestMoveEventValidatorBindsBothBroadcastsToExactAction(t *testing.T) {
	t.Parallel()

	const (
		matchID = "11111111-1111-4111-8111-111111111111"
		action  = "44444444-4444-4444-8444-444444444444"
		blackID = "22222222-2222-4222-8222-222222222222"
		whiteID = "33333333-3333-4333-8333-333333333333"
	)
	want := expectedMoveEvent{
		matchID: matchID, actionID: action, actorID: blackID,
		blackID: blackID, whiteID: whiteID, revision: 1, x: 7, y: 8,
	}
	revision := want.revision
	payload, err := json.Marshal(struct {
		X      int    `json:"x"`
		Y      int    `json:"y"`
		Color  string `json:"color"`
		UserID string `json:"userId"`
	}{X: want.x, Y: want.y, Color: "black", UserID: want.actorID})
	if err != nil {
		t.Fatal(err)
	}
	valid := protocol.Envelope{
		ProtocolVersion: protocol.Version1, GameID: gomoku.GameID, MatchID: matchID,
		Revision: &revision, Type: protocol.TypeGomokuMoveAccepted, ActionID: action, Payload: payload,
	}
	if err := validateSameMoveEvent(valid, valid, want); err != nil {
		t.Fatalf("valid broadcasts: %v", err)
	}

	tests := []struct {
		name   string
		mutate func(*protocol.Envelope, *protocol.Envelope)
	}{
		{name: "wrong match", mutate: func(left, _ *protocol.Envelope) { left.MatchID = whiteID }},
		{name: "wrong action", mutate: func(left, _ *protocol.Envelope) { left.ActionID = matchID }},
		{name: "wrong revision", mutate: func(left, _ *protocol.Envelope) { other := int64(2); left.Revision = &other }},
		{name: "wrong event type", mutate: func(left, _ *protocol.Envelope) { left.Type = protocol.TypePlatformSnapshot }},
		{name: "wrong actor", mutate: func(left, _ *protocol.Envelope) {
			left.Payload = []byte(`{"x":7,"y":8,"color":"black","userId":"` + whiteID + `"}`)
		}},
		{name: "wrong color", mutate: func(left, _ *protocol.Envelope) {
			left.Payload = []byte(`{"x":7,"y":8,"color":"white","userId":"` + blackID + `"}`)
		}},
		{name: "wrong x", mutate: func(left, _ *protocol.Envelope) {
			left.Payload = []byte(`{"x":6,"y":8,"color":"black","userId":"` + blackID + `"}`)
		}},
		{name: "wrong y", mutate: func(left, _ *protocol.Envelope) {
			left.Payload = []byte(`{"x":7,"y":9,"color":"black","userId":"` + blackID + `"}`)
		}},
		{name: "noncanonical payload", mutate: func(left, _ *protocol.Envelope) {
			left.Payload = []byte(`{"userId":"` + blackID + `","color":"black","y":8,"x":7}`)
		}},
		{name: "peer differs", mutate: func(_, right *protocol.Envelope) { right.ActionID = matchID }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			left, right := valid, valid
			test.mutate(&left, &right)
			if err := validateSameMoveEvent(left, right, want); err == nil {
				t.Fatalf("mutated broadcasts accepted: left=%+v right=%+v", left, right)
			}
		})
	}
}

func TestNoEnvelopeWindowRejectsMessagesAndReadFailures(t *testing.T) {
	t.Parallel()

	quiet := make(chan envelopeRead)
	if err := requireNoEnvelopeBefore(quiet, 5*time.Millisecond); err != nil {
		t.Fatalf("quiet peer: %v", err)
	}
	tests := []struct {
		name    string
		outcome envelopeRead
	}{
		{name: "early event", outcome: envelopeRead{envelope: protocol.Envelope{Type: protocol.TypeGomokuMoveAccepted}}},
		{name: "closed peer", outcome: envelopeRead{err: io.EOF}},
		{name: "malformed message", outcome: envelopeRead{err: errors.New("invalid_json: malformed websocket envelope")}},
		{name: "binary message", outcome: envelopeRead{err: errors.New("unexpected websocket message type")}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reads := make(chan envelopeRead, 1)
			reads <- test.outcome
			if err := requireNoEnvelopeBefore(reads, time.Second); err == nil {
				t.Fatalf("read outcome accepted: %+v", test.outcome)
			}
		})
	}
}

func TestDurableMatchRestoresAfterCompleteServerAndDatabaseRestart(t *testing.T) {
	t.Parallel()

	databasePath := filepath.Join(t.TempDir(), "gamebox.sqlite")
	serviceClock := clock.NewFake(time.Date(2026, time.August, 20, 9, 0, 0, 0, time.UTC))
	first := startServer(t, databasePath, serviceClock, 2)
	firstClosed := false
	t.Cleanup(func() {
		if !firstClosed {
			closeServer(t, first)
		}
	})

	ctx, cancel := context.WithTimeout(context.Background(), e2eTimeout)
	defer cancel()
	invites, err := first.CreateInvites(ctx, 2)
	if err != nil {
		t.Fatal(err)
	}
	alice, err := first.API.Register(ctx, invites[0], "Restart Alice")
	if err != nil {
		t.Fatal(err)
	}
	bob, err := first.API.Register(ctx, invites[1], "Restart Bob")
	if err != nil {
		t.Fatal(err)
	}
	created, err := first.API.CreateGomokuMatch(ctx, alice.AccessToken, bob.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	aliceTicket, err := first.API.CreateLaunchTicket(ctx, alice.AccessToken, created.ID)
	if err != nil {
		t.Fatal(err)
	}
	bobTicket, err := first.API.CreateLaunchTicket(ctx, bob.AccessToken, created.ID)
	if err != nil {
		t.Fatal(err)
	}
	aliceWS, err := first.DialWebSocket(ctx)
	if err != nil {
		t.Fatal(err)
	}
	aliceHandshake, err := aliceWS.ConnectLaunch(ctx, aliceTicket.LaunchTicket)
	if err != nil {
		t.Fatal(err)
	}
	bobWS, err := first.DialWebSocket(ctx)
	if err != nil {
		t.Fatal(err)
	}
	bobHandshake, err := bobWS.ConnectLaunch(ctx, bobTicket.LaunchTicket)
	if err != nil {
		t.Fatal(err)
	}
	if !snapshotsEqual(aliceHandshake.Snapshot, bobHandshake.Snapshot) {
		t.Fatalf("initial snapshots differ: %+v / %+v", aliceHandshake.Snapshot, bobHandshake.Snapshot)
	}
	black, white := aliceHandshake.Snapshot.BlackUserID, aliceHandshake.Snapshot.WhiteUserID
	clients := map[string]*testutil.WebSocketClient{alice.User.ID: aliceWS, bob.User.ID: bobWS}
	preRestartMoves := []struct {
		userID string
		x      int
		y      int
	}{{black, 0, 0}, {white, 0, 1}, {black, 1, 0}}
	for index, move := range preRestartMoves {
		if err := clients[move.userID].SendMove(ctx, created.ID, actionID(100+index), int64(index), move.x, move.y); err != nil {
			t.Fatal(err)
		}
		assertSameMoveEvent(t, mustReadEnvelope(t, ctx, aliceWS), mustReadEnvelope(t, ctx, bobWS), expectedMoveEvent{
			matchID: created.ID, actionID: actionID(100 + index), actorID: move.userID,
			blackID: black, whiteID: white, revision: int64(index + 1), x: move.x, y: move.y,
		})
	}
	beforeRestart := requestSnapshot(t, ctx, aliceWS, created.ID, 3)
	if err := validateThreeMoveSnapshot(beforeRestart, created.ID, black, white); err != nil {
		t.Fatalf("pre-restart snapshot: %v: %+v", err, beforeRestart)
	}
	if err := aliceWS.Close(); err != nil {
		t.Errorf("close Alice websocket: %v", err)
	}
	if err := bobWS.Close(); err != nil {
		t.Errorf("close Bob websocket: %v", err)
	}
	closeServer(t, first)
	if pingErr := first.DB.PingContext(ctx); pingErr == nil {
		t.Fatal("first database remained usable after complete close")
	}
	if _, requestErr := first.API.Me(ctx, alice.AccessToken); requestErr == nil {
		t.Fatal("first HTTP listener remained usable after complete close")
	}
	firstClosed = true

	second := startServer(t, databasePath, serviceClock, 3)
	defer closeServer(t, second)
	aliceTicketAfterRestart, err := second.API.CreateLaunchTicket(ctx, alice.AccessToken, created.ID)
	if err != nil {
		t.Fatalf("Alice fresh launch ticket: %v", err)
	}
	bobTicketAfterRestart, err := second.API.CreateLaunchTicket(ctx, bob.AccessToken, created.ID)
	if err != nil {
		t.Fatalf("Bob fresh launch ticket: %v", err)
	}
	aliceAfterRestart, err := second.DialWebSocket(ctx)
	if err != nil {
		t.Fatal(err)
	}
	aliceRestored, err := aliceAfterRestart.ConnectLaunch(ctx, aliceTicketAfterRestart.LaunchTicket)
	if err != nil {
		t.Fatalf("restore Alice: %v", err)
	}
	bobAfterRestart, err := second.DialWebSocket(ctx)
	if err != nil {
		t.Fatal(err)
	}
	bobRestored, err := bobAfterRestart.ConnectLaunch(ctx, bobTicketAfterRestart.LaunchTicket)
	if err != nil {
		t.Fatalf("restore Bob: %v", err)
	}
	if !snapshotsEqual(beforeRestart, aliceRestored.Snapshot) || !snapshotsEqual(aliceRestored.Snapshot, bobRestored.Snapshot) || aliceRestored.Snapshot.Revision != 3 {
		t.Fatalf("restored snapshots before=%+v Alice=%+v Bob=%+v", beforeRestart, aliceRestored.Snapshot, bobRestored.Snapshot)
	}
	for actor, snapshot := range map[string]testutil.GomokuSnapshot{
		"Alice": aliceRestored.Snapshot,
		"Bob":   bobRestored.Snapshot,
	} {
		if err := validateThreeMoveSnapshot(snapshot, created.ID, black, white); err != nil {
			t.Fatalf("%s restored snapshot: %v: %+v", actor, err, snapshot)
		}
	}

	restoredClients := map[string]*testutil.WebSocketClient{alice.User.ID: aliceAfterRestart, bob.User.ID: bobAfterRestart}
	postRestartMoves := []struct {
		userID string
		x      int
		y      int
	}{{white, 1, 1}, {black, 2, 0}, {white, 2, 1}, {black, 3, 0}, {white, 3, 1}, {black, 4, 0}}
	for index, move := range postRestartMoves {
		revision := int64(3 + index)
		if err := restoredClients[move.userID].SendMove(ctx, created.ID, actionID(200+index), revision, move.x, move.y); err != nil {
			t.Fatal(err)
		}
		assertSameMoveEvent(t, mustReadEnvelope(t, ctx, aliceAfterRestart), mustReadEnvelope(t, ctx, bobAfterRestart), expectedMoveEvent{
			matchID: created.ID, actionID: actionID(200 + index), actorID: move.userID,
			blackID: black, whiteID: white, revision: revision + 1, x: move.x, y: move.y,
		})
	}
	terminalAlice := requestSnapshot(t, ctx, aliceAfterRestart, created.ID, 9)
	terminalBob := requestSnapshot(t, ctx, bobAfterRestart, created.ID, 9)
	if !snapshotsEqual(terminalAlice, terminalBob) || terminalAlice.Status != "finished" || terminalAlice.Result == nil || *terminalAlice.Result != "five" || terminalAlice.WinnerUserID == nil || *terminalAlice.WinnerUserID != black {
		t.Fatalf("terminal after restart Alice=%+v Bob=%+v", terminalAlice, terminalBob)
	}
	assertSecretsAbsent(t, first.Logs()+second.Logs(), aliceTicket.LaunchTicket, bobTicket.LaunchTicket, aliceTicketAfterRestart.LaunchTicket, bobTicketAfterRestart.LaunchTicket, aliceHandshake.Connected.ResumeToken, bobHandshake.Connected.ResumeToken, aliceRestored.Connected.ResumeToken, bobRestored.Connected.ResumeToken)
}

func TestConcurrentInitiatorsCompeteForOneOpponentAtomically(t *testing.T) {
	t.Parallel()

	server := startServer(t, filepath.Join(t.TempDir(), "gamebox.sqlite"), clock.NewFake(time.Date(2026, time.August, 20, 10, 0, 0, 0, time.UTC)), 4)
	defer closeServer(t, server)
	ctx, cancel := context.WithTimeout(context.Background(), e2eTimeout)
	defer cancel()
	invites, err := server.CreateInvites(ctx, 3)
	if err != nil {
		t.Fatal(err)
	}
	sessions := make([]testutil.Session, 3)
	for index, nickname := range []string{"Initiator One", "Initiator Two", "Shared Opponent"} {
		sessions[index], err = server.API.Register(ctx, invites[index], nickname)
		if err != nil {
			t.Fatalf("register %s: %v", nickname, err)
		}
	}

	type createResult struct {
		initiator int
		match     testutil.CreatedMatch
		err       error
	}
	start := make(chan struct{})
	results := make(chan createResult, 2)
	var workers sync.WaitGroup
	for initiator := 0; initiator < 2; initiator++ {
		workers.Add(1)
		go func(index int) {
			defer workers.Done()
			<-start
			match, createErr := server.API.CreateGomokuMatch(ctx, sessions[index].AccessToken, sessions[2].User.ID)
			results <- createResult{initiator: index, match: match, err: createErr}
		}(initiator)
	}
	close(start)
	workers.Wait()
	close(results)

	var succeeded, failed *createResult
	for outcome := range results {
		outcome := outcome
		if outcome.err == nil {
			if succeeded != nil {
				t.Fatalf("both concurrent creates succeeded: %+v and %+v", *succeeded, outcome)
			}
			succeeded = &outcome
		} else {
			if failed != nil {
				t.Fatalf("both concurrent creates failed: %+v and %+v", *failed, outcome)
			}
			failed = &outcome
		}
	}
	if succeeded == nil || failed == nil || succeeded.match.ID == "" || failed.match.ID != "" {
		t.Fatalf("concurrent results success=%+v failure=%+v", succeeded, failed)
	}
	var apiFailure *testutil.APIError
	if !errors.As(failed.err, &apiFailure) || apiFailure.Status != 409 || apiFailure.Code != "opponent_busy" {
		t.Fatalf("loser error=%T %v", failed.err, failed.err)
	}

	for _, session := range sessions {
		user, meErr := server.API.Me(ctx, session.AccessToken)
		if meErr != nil || user != session.User {
			t.Fatalf("session changed for %s: user=%+v err=%v", session.User.ID, user, meErr)
		}
	}
	var consumedInvites, refreshSessions int
	if err := server.DB.QueryRow(`SELECT COUNT(*) FROM invite_codes WHERE consumed_by IS NOT NULL AND consumed_at IS NOT NULL`).Scan(&consumedInvites); err != nil {
		t.Fatal(err)
	}
	if err := server.DB.QueryRow(`SELECT COUNT(*) FROM refresh_tokens WHERE revoked_at IS NULL`).Scan(&refreshSessions); err != nil {
		t.Fatal(err)
	}
	if consumedInvites != 3 || refreshSessions != 3 {
		t.Fatalf("identity rows changed by match race: invites=%d refresh=%d", consumedInvites, refreshSessions)
	}
	winnerStatus, err := server.API.GomokuStatus(ctx, sessions[succeeded.initiator].AccessToken)
	if err != nil || winnerStatus.State != "active" || winnerStatus.Match == nil || winnerStatus.Match.ID != succeeded.match.ID {
		t.Fatalf("winning initiator status=(%+v,%v)", winnerStatus, err)
	}
	loserStatus, err := server.API.GomokuStatus(ctx, sessions[failed.initiator].AccessToken)
	if err != nil || loserStatus.State != "idle" || loserStatus.Match != nil {
		t.Fatalf("losing initiator status=(%+v,%v)", loserStatus, err)
	}
	assertSecretsAbsent(t, server.Logs(), append([]string{sessions[0].AccessToken, sessions[1].AccessToken, sessions[2].AccessToken}, invites...)...)
}

func TestActionCommitFailureRollsBackWithoutPeerBroadcast(t *testing.T) {
	t.Parallel()

	server := startServer(t, filepath.Join(t.TempDir(), "gamebox.sqlite"), clock.NewFake(time.Date(2026, time.August, 20, 11, 0, 0, 0, time.UTC)), 5)
	defer closeServer(t, server)
	ctx, cancel := context.WithTimeout(context.Background(), e2eTimeout)
	defer cancel()
	invites, err := server.CreateInvites(ctx, 2)
	if err != nil {
		t.Fatal(err)
	}
	alice, err := server.API.Register(ctx, invites[0], "Commit Alice")
	if err != nil {
		t.Fatal(err)
	}
	bob, err := server.API.Register(ctx, invites[1], "Commit Bob")
	if err != nil {
		t.Fatal(err)
	}
	created, err := server.API.CreateGomokuMatch(ctx, alice.AccessToken, bob.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	aliceTicket, err := server.API.CreateLaunchTicket(ctx, alice.AccessToken, created.ID)
	if err != nil {
		t.Fatal(err)
	}
	bobTicket, err := server.API.CreateLaunchTicket(ctx, bob.AccessToken, created.ID)
	if err != nil {
		t.Fatal(err)
	}
	aliceWS, err := server.DialWebSocket(ctx)
	if err != nil {
		t.Fatal(err)
	}
	aliceHandshake, err := aliceWS.ConnectLaunch(ctx, aliceTicket.LaunchTicket)
	if err != nil {
		t.Fatal(err)
	}
	bobWS, err := server.DialWebSocket(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := bobWS.ConnectLaunch(ctx, bobTicket.LaunchTicket); err != nil {
		t.Fatal(err)
	}

	const databaseFailureMarker = "private-deferred-action-commit-marker"
	if _, err := server.DB.Exec(`
CREATE TRIGGER fail_e2e_action_at_commit AFTER INSERT ON match_events
BEGIN
  INSERT INTO launch_tickets(token_hash,match_id,user_id,game_id,expires_at,created_at)
  VALUES ('` + databaseFailureMarker + `','ffffffff-ffff-4fff-8fff-ffffffffffff','11111111-1111-4111-8111-111111111111','gomoku',1,1);
END`); err != nil {
		t.Fatal(err)
	}
	server.DB.SetMaxOpenConns(1)
	connection, err := server.DB.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := connection.ExecContext(ctx, `PRAGMA defer_foreign_keys=ON`); err != nil {
		_ = connection.Close()
		t.Fatal(err)
	}
	if err := connection.Close(); err != nil {
		t.Fatal(err)
	}

	clients := map[string]*testutil.WebSocketClient{alice.User.ID: aliceWS, bob.User.ID: bobWS}
	actorID := aliceHandshake.Snapshot.BlackUserID
	actor := clients[actorID]
	peer := bobWS
	if actor == bobWS {
		peer = aliceWS
	}
	peerReads := readEnvelopeAsync(ctx, peer)
	failedActionID := actionID(300)
	if err := actor.SendMove(ctx, created.ID, failedActionID, 0, 7, 7); err != nil {
		t.Fatal(err)
	}
	failure := mustReadEnvelope(t, ctx, actor)
	var failurePayload struct {
		Code    string         `json:"code"`
		Message string         `json:"message"`
		Details map[string]any `json:"details"`
	}
	if failure.Type != protocol.TypePlatformError || failure.Revision == nil || *failure.Revision != 0 || failure.ActionID != failedActionID || json.Unmarshal(failure.Payload, &failurePayload) != nil || failurePayload.Code != "internal_error" || failurePayload.Details == nil {
		t.Fatalf("action failure envelope=%+v payload=%s", failure, failure.Payload)
	}
	if err := requireNoEnvelopeBefore(peerReads, 150*time.Millisecond); err != nil {
		t.Fatalf("peer no-broadcast window: %v", err)
	}
	if err := peer.RequestSnapshot(ctx, created.ID, 0); err != nil {
		t.Fatalf("peer request snapshot barrier: %v", err)
	}
	unchanged := decodeSnapshotRead(t, ctx, peerReads)
	assertEmptyActiveSnapshot(t, unchanged, created.ID)

	queuedReads := readEnvelopeAsync(ctx, peer)
	if err := requireNoEnvelopeBefore(queuedReads, 50*time.Millisecond); err != nil {
		t.Fatalf("peer queued-event window: %v", err)
	}
	if err := peer.RequestSnapshot(ctx, created.ID, 0); err != nil {
		t.Fatalf("peer second snapshot barrier: %v", err)
	}
	assertEmptyActiveSnapshot(t, decodeSnapshotRead(t, ctx, queuedReads), created.ID)
	assertEmptyActiveSnapshot(t, requestSnapshot(t, ctx, actor, created.ID, 0), created.ID)
	var revision, events, injectedRows int
	if err := server.DB.QueryRow(`SELECT revision FROM matches WHERE id=?`, created.ID).Scan(&revision); err != nil {
		t.Fatal(err)
	}
	if err := server.DB.QueryRow(`SELECT COUNT(*) FROM match_events WHERE match_id=?`, created.ID).Scan(&events); err != nil {
		t.Fatal(err)
	}
	if err := server.DB.QueryRow(`SELECT COUNT(*) FROM launch_tickets WHERE token_hash=?`, databaseFailureMarker).Scan(&injectedRows); err != nil {
		t.Fatal(err)
	}
	if revision != 0 || events != 0 || injectedRows != 0 {
		t.Fatalf("failed commit persisted revision=%d events=%d injected=%d", revision, events, injectedRows)
	}
	assertSecretsAbsent(t, server.Logs()+string(failure.Payload), databaseFailureMarker, aliceTicket.LaunchTicket, bobTicket.LaunchTicket)
}

func TestServerCloseRetriesAfterDeadlineDuringBlockedDisconnect(t *testing.T) {
	t.Parallel()

	server := startServer(t, filepath.Join(t.TempDir(), "gamebox.sqlite"), clock.NewFake(time.Date(2026, time.August, 20, 11, 30, 0, 0, time.UTC)), 10)
	closed := false
	t.Cleanup(func() {
		if !closed {
			closeServer(t, server)
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), e2eTimeout)
	defer cancel()
	invites, err := server.CreateInvites(ctx, 2)
	if err != nil {
		t.Fatal(err)
	}
	alice, err := server.API.Register(ctx, invites[0], "Close Alice")
	if err != nil {
		t.Fatal(err)
	}
	bob, err := server.API.Register(ctx, invites[1], "Close Bob")
	if err != nil {
		t.Fatal(err)
	}
	created, err := server.API.CreateGomokuMatch(ctx, alice.AccessToken, bob.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	ticket, err := server.API.CreateLaunchTicket(ctx, alice.AccessToken, created.ID)
	if err != nil {
		t.Fatal(err)
	}
	client, err := server.DialWebSocket(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.ConnectLaunch(ctx, ticket.LaunchTicket); err != nil {
		t.Fatal(err)
	}

	lockConnection, err := server.DB.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := lockConnection.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		_ = lockConnection.Close()
		t.Fatal(err)
	}
	var releaseOnce sync.Once
	releaseLock := func() {
		releaseOnce.Do(func() {
			_, _ = lockConnection.ExecContext(context.Background(), `ROLLBACK`)
			_ = lockConnection.Close()
		})
	}
	defer releaseLock()

	shortContext, stopShortClose := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer stopShortClose()
	firstClose := make(chan error, 1)
	go func() { firstClose <- server.Close(shortContext) }()
	select {
	case closeErr := <-firstClose:
		if !errors.Is(closeErr, context.DeadlineExceeded) {
			t.Fatalf("first Close error=%v want context deadline", closeErr)
		}
	case <-time.After(250 * time.Millisecond):
		releaseLock()
		closeErr := <-firstClose
		t.Fatalf("first Close did not honor its deadline; eventual error=%v", closeErr)
	}
	releaseLock()

	retryContext, stopRetry := context.WithTimeout(context.Background(), e2eTimeout)
	defer stopRetry()
	if err := server.Close(retryContext); err != nil {
		t.Fatalf("retry Close: %v", err)
	}
	closed = true
	if err := server.DB.PingContext(retryContext); err == nil {
		t.Fatal("database remained usable after successful retry Close")
	}
	if server.Presence.IsOnline(created.ID, alice.User.ID) {
		t.Fatal("websocket handler remained online after successful retry Close")
	}
	closedReadContext, stopClosedRead := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer stopClosedRead()
	if envelope, err := client.ReadEnvelope(closedReadContext); err == nil {
		t.Fatalf("websocket remained readable after successful retry Close: %+v", envelope)
	} else if errors.Is(err, context.DeadlineExceeded) {
		t.Fatal("websocket read timed out instead of observing a closed connection")
	}
	alreadyCanceled, cancelAgain := context.WithCancel(context.Background())
	cancelAgain()
	if err := server.Close(alreadyCanceled); err != nil {
		t.Fatalf("idempotent Close after finalization: %v", err)
	}
}

func TestServerConcurrentCloseDrainsLateHandshake(t *testing.T) {
	t.Parallel()

	server := startServer(t, filepath.Join(t.TempDir(), "gamebox.sqlite"), clock.NewFake(time.Date(2026, time.August, 20, 11, 45, 0, 0, time.UTC)), 11)
	closed := false
	t.Cleanup(func() {
		if !closed {
			closeServer(t, server)
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), e2eTimeout)
	defer cancel()
	invites, err := server.CreateInvites(ctx, 2)
	if err != nil {
		t.Fatal(err)
	}
	alice, err := server.API.Register(ctx, invites[0], "Handshake Alice")
	if err != nil {
		t.Fatal(err)
	}
	bob, err := server.API.Register(ctx, invites[1], "Handshake Bob")
	if err != nil {
		t.Fatal(err)
	}
	created, err := server.API.CreateGomokuMatch(ctx, alice.AccessToken, bob.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	ticket, err := server.API.CreateLaunchTicket(ctx, alice.AccessToken, created.ID)
	if err != nil {
		t.Fatal(err)
	}
	client, err := server.DialWebSocket(ctx)
	if err != nil {
		t.Fatal(err)
	}

	const closeCallers = 8
	start := make(chan struct{})
	closeResults := make(chan error, closeCallers)
	var closers sync.WaitGroup
	for range closeCallers {
		closers.Add(1)
		go func() {
			defer closers.Done()
			<-start
			closeContext, stopClose := context.WithTimeout(context.Background(), e2eTimeout)
			defer stopClose()
			closeResults <- server.Close(closeContext)
		}()
	}
	handshakeResult := make(chan error, 1)
	go func() {
		<-start
		_, connectErr := client.ConnectLaunch(ctx, ticket.LaunchTicket)
		handshakeResult <- connectErr
	}()
	close(start)
	closers.Wait()
	close(closeResults)
	for closeErr := range closeResults {
		if closeErr != nil {
			t.Fatalf("concurrent Close: %v", closeErr)
		}
	}
	closed = true
	select {
	case <-handshakeResult:
	case <-ctx.Done():
		t.Fatalf("late handshake was not drained: %v", ctx.Err())
	}
	if err := server.DB.PingContext(ctx); err == nil {
		t.Fatal("database remained usable after concurrent Close")
	}
	if server.Presence.IsOnline(created.ID, alice.User.ID) {
		t.Fatal("late handshake remained online after concurrent Close")
	}
	if _, err := server.API.Me(ctx, alice.AccessToken); err == nil {
		t.Fatal("HTTP listener remained usable after concurrent Close")
	}
}

func TestExpiredResumeTokenIsRejectedWithoutSlidingOrDisclosure(t *testing.T) {
	t.Parallel()

	serviceClock := clock.NewFake(time.Date(2026, time.August, 20, 12, 0, 0, 0, time.UTC))
	server := startServer(t, filepath.Join(t.TempDir(), "gamebox.sqlite"), serviceClock, 6)
	defer closeServer(t, server)
	ctx, cancel := context.WithTimeout(context.Background(), e2eTimeout)
	defer cancel()
	invites, err := server.CreateInvites(ctx, 2)
	if err != nil {
		t.Fatal(err)
	}
	alice, err := server.API.Register(ctx, invites[0], "Resume Alice")
	if err != nil {
		t.Fatal(err)
	}
	bob, err := server.API.Register(ctx, invites[1], "Resume Bob")
	if err != nil {
		t.Fatal(err)
	}
	created, err := server.API.CreateGomokuMatch(ctx, alice.AccessToken, bob.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	ticket, err := server.API.CreateLaunchTicket(ctx, alice.AccessToken, created.ID)
	if err != nil {
		t.Fatal(err)
	}
	connectedClient, err := server.DialWebSocket(ctx)
	if err != nil {
		t.Fatal(err)
	}
	handshake, err := connectedClient.ConnectLaunch(ctx, ticket.LaunchTicket)
	if err != nil {
		t.Fatal(err)
	}
	if err := connectedClient.Close(); err != nil {
		t.Errorf("close initial websocket: %v", err)
	}
	var beforeExpiresAt, beforeLastUsed int64
	if err := server.DB.QueryRow(`SELECT expires_at,last_used_at FROM resume_tokens WHERE match_id=? AND user_id=?`, created.ID, alice.User.ID).Scan(&beforeExpiresAt, &beforeLastUsed); err != nil {
		t.Fatal(err)
	}
	serviceClock.Advance(30 * time.Minute)
	expiredClient, err := server.DialWebSocket(ctx)
	if err != nil {
		t.Fatal(err)
	}
	_, resumeErr := expiredClient.ConnectResume(ctx, handshake.Connected.ResumeToken)
	var webSocketFailure *testutil.WebSocketError
	if !errors.As(resumeErr, &webSocketFailure) || webSocketFailure.Code != "resume_expired" {
		t.Fatalf("expired resume error=%T %v", resumeErr, resumeErr)
	}
	var afterExpiresAt, afterLastUsed int64
	if err := server.DB.QueryRow(`SELECT expires_at,last_used_at FROM resume_tokens WHERE match_id=? AND user_id=?`, created.ID, alice.User.ID).Scan(&afterExpiresAt, &afterLastUsed); err != nil {
		t.Fatal(err)
	}
	if afterExpiresAt != beforeExpiresAt || afterLastUsed != beforeLastUsed {
		t.Fatalf("expired resume slid expiry/last-used: before=(%d,%d) after=(%d,%d)", beforeExpiresAt, beforeLastUsed, afterExpiresAt, afterLastUsed)
	}
	if stringsContainsAny(resumeErr.Error()+server.Logs(), ticket.LaunchTicket, handshake.Connected.ResumeToken) {
		t.Fatalf("credential disclosed by resume failure: error=%v logs=%s", resumeErr, server.Logs())
	}
}

func TestEitherPlayerReconnectClearsDurableBothOfflineTimer(t *testing.T) {
	t.Parallel()

	serviceClock := clock.NewFake(time.Date(2026, time.August, 20, 13, 0, 0, 0, time.UTC))
	server := startServer(t, filepath.Join(t.TempDir(), "gamebox.sqlite"), serviceClock, 7)
	defer closeServer(t, server)
	ctx, cancel := context.WithTimeout(context.Background(), e2eTimeout)
	defer cancel()
	invites, err := server.CreateInvites(ctx, 2)
	if err != nil {
		t.Fatal(err)
	}
	alice, err := server.API.Register(ctx, invites[0], "Reconnect Alice")
	if err != nil {
		t.Fatal(err)
	}
	bob, err := server.API.Register(ctx, invites[1], "Reconnect Bob")
	if err != nil {
		t.Fatal(err)
	}
	created, err := server.API.CreateGomokuMatch(ctx, alice.AccessToken, bob.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	aliceTicket, err := server.API.CreateLaunchTicket(ctx, alice.AccessToken, created.ID)
	if err != nil {
		t.Fatal(err)
	}
	bobTicket, err := server.API.CreateLaunchTicket(ctx, bob.AccessToken, created.ID)
	if err != nil {
		t.Fatal(err)
	}
	aliceWS, err := server.DialWebSocket(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := aliceWS.ConnectLaunch(ctx, aliceTicket.LaunchTicket); err != nil {
		t.Fatal(err)
	}
	bobWS, err := server.DialWebSocket(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := bobWS.ConnectLaunch(ctx, bobTicket.LaunchTicket); err != nil {
		t.Fatal(err)
	}
	if err := aliceWS.Close(); err != nil {
		t.Errorf("close Alice: %v", err)
	}
	if err := bobWS.Close(); err != nil {
		t.Errorf("close Bob: %v", err)
	}
	offlineSince := waitBothOfflineSince(t, ctx, server.DB, created.ID, true)
	if !offlineSince.Valid || offlineSince.Int64 != serviceClock.Now().UnixMilli() {
		t.Fatalf("both_offline_since=%v want=%d", offlineSince, serviceClock.Now().UnixMilli())
	}

	serviceClock.Advance(5 * time.Minute)
	reconnectTicket, err := server.API.CreateLaunchTicket(ctx, alice.AccessToken, created.ID)
	if err != nil {
		t.Fatal(err)
	}
	reconnected, err := server.DialWebSocket(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := reconnected.ConnectLaunch(ctx, reconnectTicket.LaunchTicket); err != nil {
		t.Fatal(err)
	}
	cleared := waitBothOfflineSince(t, ctx, server.DB, created.ID, false)
	if cleared.Valid || !server.Presence.IsOnline(created.ID, alice.User.ID) || server.Presence.IsOnline(created.ID, bob.User.ID) {
		t.Fatalf("reconnect did not clear timer: offline=%v aliceOnline=%t bobOnline=%t", cleared, server.Presence.IsOnline(created.ID, alice.User.ID), server.Presence.IsOnline(created.ID, bob.User.ID))
	}
}

func TestBootRecoveryPreservesExistingBothOfflineTimer(t *testing.T) {
	t.Parallel()

	databasePath := filepath.Join(t.TempDir(), "gamebox.sqlite")
	serviceClock := clock.NewFake(time.Date(2026, time.August, 20, 14, 0, 0, 0, time.UTC))
	first := startServer(t, databasePath, serviceClock, 8)
	firstClosed := false
	t.Cleanup(func() {
		if !firstClosed {
			closeServer(t, first)
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), e2eTimeout)
	defer cancel()
	invites, err := first.CreateInvites(ctx, 2)
	if err != nil {
		t.Fatal(err)
	}
	alice, err := first.API.Register(ctx, invites[0], "Boot Alice")
	if err != nil {
		t.Fatal(err)
	}
	bob, err := first.API.Register(ctx, invites[1], "Boot Bob")
	if err != nil {
		t.Fatal(err)
	}
	created, err := first.API.CreateGomokuMatch(ctx, alice.AccessToken, bob.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	aliceTicket, err := first.API.CreateLaunchTicket(ctx, alice.AccessToken, created.ID)
	if err != nil {
		t.Fatal(err)
	}
	bobTicket, err := first.API.CreateLaunchTicket(ctx, bob.AccessToken, created.ID)
	if err != nil {
		t.Fatal(err)
	}
	aliceWS, err := first.DialWebSocket(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := aliceWS.ConnectLaunch(ctx, aliceTicket.LaunchTicket); err != nil {
		t.Fatal(err)
	}
	bobWS, err := first.DialWebSocket(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := bobWS.ConnectLaunch(ctx, bobTicket.LaunchTicket); err != nil {
		t.Fatal(err)
	}
	if err := aliceWS.Close(); err != nil {
		t.Errorf("close Alice: %v", err)
	}
	if err := bobWS.Close(); err != nil {
		t.Errorf("close Bob: %v", err)
	}
	beforeRestart := waitBothOfflineSince(t, ctx, first.DB, created.ID, true)
	if !beforeRestart.Valid || beforeRestart.Int64 != serviceClock.Now().UnixMilli() {
		t.Fatalf("offline timer before restart=%v", beforeRestart)
	}
	closeServer(t, first)
	firstClosed = true

	serviceClock.Advance(10 * time.Minute)
	second := startServer(t, databasePath, serviceClock, 9)
	defer closeServer(t, second)
	afterRestart := waitBothOfflineSince(t, ctx, second.DB, created.ID, true)
	if afterRestart.Int64 != beforeRestart.Int64 || afterRestart.Int64 == serviceClock.Now().UnixMilli() {
		t.Fatalf("boot reset offline timer: before=%v after=%v bootNow=%d", beforeRestart, afterRestart, serviceClock.Now().UnixMilli())
	}
	status, err := second.API.GomokuStatus(ctx, alice.AccessToken)
	if err != nil || status.State != "active" || status.Match == nil || status.Match.ID != created.ID {
		t.Fatalf("restored active status=(%+v,%v)", status, err)
	}
}

func startServer(t *testing.T, databasePath string, serviceClock *clock.Fake, entropySeed byte) *testutil.Server {
	t.Helper()
	server, err := testutil.StartServer(context.Background(), testutil.ServerConfig{
		DatabasePath:     databasePath,
		Clock:            serviceClock,
		ColorRandom:      bytes.NewReader(bytes.Repeat([]byte{entropySeed}, 1024)),
		CredentialRandom: bytes.NewReader(distinctEntropy(entropySeed+16, 128)),
	})
	if err != nil {
		t.Fatalf("start server: %v", err)
	}
	return server
}

func closeServer(t *testing.T, server *testutil.Server) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), e2eTimeout)
	defer cancel()
	if err := server.Close(ctx); err != nil {
		t.Errorf("close server: %v", err)
	}
}

func distinctEntropy(seed byte, blocks int) []byte {
	result := make([]byte, 0, blocks*32)
	for index := 0; index < blocks; index++ {
		block := make([]byte, 32)
		for position := range block {
			block[position] = seed + byte(index) + byte(position)
		}
		result = append(result, block...)
	}
	return result
}

func assertInvitesAreStoredOnlyAsDigests(t *testing.T, server *testutil.Server, invites []string) {
	t.Helper()
	rows, err := server.DB.Query(`SELECT code_hash FROM invite_codes ORDER BY code_hash`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var hashes []string
	for rows.Next() {
		var hash string
		if err := rows.Scan(&hash); err != nil {
			t.Fatal(err)
		}
		hashes = append(hashes, hash)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if len(hashes) != len(invites) {
		t.Fatalf("stored invite count=%d want=%d", len(hashes), len(invites))
	}
	for _, hash := range hashes {
		if len(hash) != 64 {
			t.Fatalf("stored invite digest length=%d", len(hash))
		}
		for _, invite := range invites {
			if hash == invite {
				t.Fatalf("invite stored in plaintext: %q", invite)
			}
		}
	}
}

func actionID(number int) string {
	return fmt.Sprintf("dddddddd-dddd-4ddd-8ddd-%012x", number)
}

func assertSameMoveEvent(t *testing.T, left, right protocol.Envelope, want expectedMoveEvent) {
	t.Helper()
	if err := validateSameMoveEvent(left, right, want); err != nil {
		t.Fatalf("move broadcasts: %v: left=%+v right=%+v", err, left, right)
	}
}

func validateSameMoveEvent(left, right protocol.Envelope, want expectedMoveEvent) error {
	color := ""
	switch want.actorID {
	case want.blackID:
		color = "black"
	case want.whiteID:
		color = "white"
	default:
		return errors.New("move actor has no expected color")
	}
	payload, err := json.Marshal(struct {
		X      int    `json:"x"`
		Y      int    `json:"y"`
		Color  string `json:"color"`
		UserID string `json:"userId"`
	}{X: want.x, Y: want.y, Color: color, UserID: want.actorID})
	if err != nil {
		return fmt.Errorf("encode expected move payload: %w", err)
	}
	for label, envelope := range map[string]protocol.Envelope{"left": left, "right": right} {
		if envelope.ProtocolVersion != protocol.Version1 || envelope.GameID != gomoku.GameID ||
			envelope.MatchID != want.matchID || envelope.Revision == nil || *envelope.Revision != want.revision ||
			envelope.ExpectedRevision != nil || envelope.Type != protocol.TypeGomokuMoveAccepted ||
			envelope.ActionID != want.actionID || !bytes.Equal(envelope.Payload, payload) {
			return fmt.Errorf("%s broadcast does not match exact move", label)
		}
	}
	return nil
}

func requestSnapshot(t *testing.T, ctx context.Context, client *testutil.WebSocketClient, matchID string, revision int64) testutil.GomokuSnapshot {
	t.Helper()
	if err := client.RequestSnapshot(ctx, matchID, revision); err != nil {
		t.Fatalf("request snapshot: %v", err)
	}
	snapshot, err := client.ReadSnapshot(ctx)
	if err != nil {
		t.Fatalf("read snapshot: %v", err)
	}
	return snapshot
}

func mustReadEnvelope(t *testing.T, ctx context.Context, client *testutil.WebSocketClient) protocol.Envelope {
	t.Helper()
	envelope, err := client.ReadEnvelope(ctx)
	if err != nil {
		t.Fatalf("read websocket envelope: %v", err)
	}
	return envelope
}

func readEnvelopeAsync(ctx context.Context, client *testutil.WebSocketClient) <-chan envelopeRead {
	reads := make(chan envelopeRead, 1)
	go func() {
		envelope, err := client.ReadEnvelope(ctx)
		reads <- envelopeRead{envelope: envelope, err: err}
	}()
	return reads
}

func requireNoEnvelopeBefore(reads <-chan envelopeRead, window time.Duration) error {
	if reads == nil || window <= 0 {
		return errors.New("invalid no-envelope window")
	}
	timer := time.NewTimer(window)
	defer timer.Stop()
	select {
	case outcome := <-reads:
		if outcome.err != nil {
			return fmt.Errorf("peer read failed before timeout: %w", outcome.err)
		}
		return fmt.Errorf("peer received envelope before timeout: type=%s", outcome.envelope.Type)
	case <-timer.C:
		return nil
	}
}

func decodeSnapshotRead(t *testing.T, ctx context.Context, reads <-chan envelopeRead) testutil.GomokuSnapshot {
	t.Helper()
	select {
	case outcome := <-reads:
		if outcome.err != nil {
			t.Fatalf("peer snapshot read: %v", outcome.err)
		}
		snapshot, err := testutil.DecodeGomokuSnapshot(outcome.envelope)
		if err != nil {
			t.Fatalf("peer snapshot envelope=%+v: %v", outcome.envelope, err)
		}
		return snapshot
	case <-ctx.Done():
		t.Fatalf("peer snapshot read: %v", ctx.Err())
		return testutil.GomokuSnapshot{}
	}
}

func assertEmptyActiveSnapshot(t *testing.T, snapshot testutil.GomokuSnapshot, matchID string) {
	t.Helper()
	if snapshot.GameID != gomoku.GameID || snapshot.MatchID != matchID || snapshot.Revision != 0 ||
		snapshot.Status != "active" || snapshot.BoardSize != gomoku.BoardSize ||
		snapshot.WinnerUserID != nil || snapshot.Result != nil || snapshot.NextColor != "black" {
		t.Fatalf("unexpected empty active snapshot: %+v", snapshot)
	}
	for index, cell := range snapshot.Board {
		if cell != 0 {
			t.Fatalf("empty snapshot board[%d]=%d", index, cell)
		}
	}
}

func snapshotsEqual(left, right testutil.GomokuSnapshot) bool {
	leftJSON, leftErr := json.Marshal(left)
	rightJSON, rightErr := json.Marshal(right)
	return leftErr == nil && rightErr == nil && bytes.Equal(leftJSON, rightJSON)
}

func validateThreeMoveSnapshot(snapshot testutil.GomokuSnapshot, matchID, blackID, whiteID string) error {
	if snapshot.GameID != gomoku.GameID || snapshot.MatchID != matchID || snapshot.Revision != 3 ||
		snapshot.Status != "active" || snapshot.BoardSize != gomoku.BoardSize ||
		snapshot.BlackUserID != blackID || snapshot.WhiteUserID != whiteID ||
		snapshot.NextColor != "white" || snapshot.WinnerUserID != nil || snapshot.Result != nil {
		return fmt.Errorf("unexpected snapshot metadata")
	}
	want := map[int]uint8{
		0*gomoku.BoardSize + 0: 1,
		0*gomoku.BoardSize + 1: 1,
		1*gomoku.BoardSize + 0: 2,
	}
	moveCount := 0
	for index, cell := range snapshot.Board {
		if cell != 0 {
			moveCount++
		}
		if cell != want[index] {
			return fmt.Errorf("board[%d]=%d want=%d", index, cell, want[index])
		}
	}
	if moveCount != len(want) {
		return fmt.Errorf("move count=%d want=%d", moveCount, len(want))
	}
	return nil
}

func assertSecretsAbsent(t *testing.T, logs string, secrets ...string) {
	t.Helper()
	for _, secret := range secrets {
		if secret != "" && bytes.Contains([]byte(logs), []byte(secret)) {
			t.Fatalf("logs leaked credential %q: %s", secret, logs)
		}
	}
}

func stringsContainsAny(value string, candidates ...string) bool {
	for _, candidate := range candidates {
		if candidate != "" && bytes.Contains([]byte(value), []byte(candidate)) {
			return true
		}
	}
	return false
}

func waitBothOfflineSince(t *testing.T, ctx context.Context, database *sql.DB, matchID string, wantValid bool) sql.NullInt64 {
	t.Helper()
	ticker := time.NewTicker(2 * time.Millisecond)
	defer ticker.Stop()
	for {
		var value sql.NullInt64
		if err := database.QueryRowContext(ctx, `SELECT both_offline_since FROM matches WHERE id=?`, matchID).Scan(&value); err != nil {
			t.Fatalf("read both_offline_since: %v", err)
		}
		if value.Valid == wantValid {
			return value
		}
		select {
		case <-ctx.Done():
			t.Fatalf("wait both_offline_since valid=%t: %v", wantValid, ctx.Err())
		case <-ticker.C:
		}
	}
}
