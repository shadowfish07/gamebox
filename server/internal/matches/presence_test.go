package matches

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"me.zqydev/gamebox/server/internal/clock"
)

const (
	presenceMatchID   = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	presenceUserID    = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
	presenceOtherID   = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
	presenceOldConn   = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
	presenceNewConn   = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
	presenceOtherConn = "ffffffff-ffff-4fff-8fff-ffffffffffff"
)

type presenceCall struct {
	online  bool
	matchID string
	userID  string
}

type fakePresenceStore struct {
	mu       sync.Mutex
	calls    []presenceCall
	failNext error
	called   chan presenceCall
}

type reentrantPresenceStore struct {
	online  func(string, string) error
	offline func(string, string) error
}

func (store *reentrantPresenceStore) SetPlayerOnline(_ context.Context, matchID, userID string) error {
	if store.online == nil {
		return nil
	}
	return store.online(matchID, userID)
}

func (store *reentrantPresenceStore) SetPlayerOffline(_ context.Context, matchID, userID string) error {
	if store.offline == nil {
		return nil
	}
	return store.offline(matchID, userID)
}

type matchBlockingPresenceStore struct {
	blockedMatchID string
	entered        chan struct{}
	release        chan struct{}
	once           sync.Once
}

func (store *matchBlockingPresenceStore) SetPlayerOnline(_ context.Context, matchID, _ string) error {
	if matchID == store.blockedMatchID {
		store.once.Do(func() { close(store.entered) })
		<-store.release
	}
	return nil
}

func (*matchBlockingPresenceStore) SetPlayerOffline(context.Context, string, string) error {
	return nil
}

type gatedPresenceStore struct {
	entered chan presenceCall
	proceed chan struct{}
}

func (store *gatedPresenceStore) SetPlayerOnline(_ context.Context, matchID, userID string) error {
	store.entered <- presenceCall{online: true, matchID: matchID, userID: userID}
	<-store.proceed
	return nil
}

func (store *gatedPresenceStore) SetPlayerOffline(_ context.Context, matchID, userID string) error {
	store.entered <- presenceCall{matchID: matchID, userID: userID}
	<-store.proceed
	return nil
}

func (store *fakePresenceStore) SetPlayerOnline(_ context.Context, matchID, userID string) error {
	return store.record(presenceCall{online: true, matchID: matchID, userID: userID})
}

func (store *fakePresenceStore) SetPlayerOffline(_ context.Context, matchID, userID string) error {
	return store.record(presenceCall{matchID: matchID, userID: userID})
}

func (store *fakePresenceStore) record(call presenceCall) error {
	store.mu.Lock()
	defer store.mu.Unlock()
	if store.failNext != nil {
		err := store.failNext
		store.failNext = nil
		return err
	}
	store.calls = append(store.calls, call)
	if store.called != nil {
		select {
		case store.called <- call:
		default:
		}
	}
	return nil
}

func (store *fakePresenceStore) snapshotCalls() []presenceCall {
	store.mu.Lock()
	defer store.mu.Unlock()
	return append([]presenceCall(nil), store.calls...)
}

func TestPresenceTracksConnectionIdentityAndOnlyPersistsPlayerBoundaries(t *testing.T) {
	now := time.Date(2026, time.August, 19, 1, 2, 3, 456789000, time.FixedZone("test", 9*60*60))
	service := &fakePresenceStore{}
	presence, err := NewPresence(service, clock.NewFake(now))
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()

	if err := presence.Connect(ctx, presenceMatchID, presenceUserID, presenceOldConn); err != nil {
		t.Fatal(err)
	}
	if err := presence.Connect(ctx, presenceMatchID, presenceUserID, presenceNewConn); err != nil {
		t.Fatal(err)
	}
	if err := presence.Connect(ctx, presenceMatchID, presenceOtherID, presenceOtherConn); err != nil {
		t.Fatal(err)
	}
	if !presence.IsOnline(presenceMatchID, presenceUserID) || !presence.IsOnline(presenceMatchID, presenceOtherID) {
		t.Fatal("both players should be online")
	}
	if err := presence.Disconnect(ctx, presenceMatchID, presenceUserID, presenceOldConn); err != nil {
		t.Fatal(err)
	}
	if !presence.IsOnline(presenceMatchID, presenceUserID) {
		t.Fatal("closing the old connection overrode the replacement connection")
	}
	if err := presence.Disconnect(ctx, presenceMatchID, presenceUserID, presenceOldConn); err != nil {
		t.Fatalf("duplicate close must be idempotent: %v", err)
	}
	if err := presence.Disconnect(ctx, presenceMatchID, presenceUserID, presenceNewConn); err != nil {
		t.Fatal(err)
	}
	if presence.IsOnline(presenceMatchID, presenceUserID) {
		t.Fatal("first player should be offline")
	}
	if err := presence.Disconnect(ctx, presenceMatchID, presenceOtherID, presenceOtherConn); err != nil {
		t.Fatal(err)
	}

	want := []presenceCall{
		{online: true, matchID: presenceMatchID, userID: presenceUserID},
		{online: true, matchID: presenceMatchID, userID: presenceOtherID},
		{matchID: presenceMatchID, userID: presenceOtherID},
	}
	if got := service.snapshotCalls(); len(got) != len(want) {
		t.Fatalf("calls=%+v want=%+v", got, want)
	} else {
		for index := range want {
			if got[index] != want[index] {
				t.Fatalf("calls[%d]=%+v want=%+v", index, got[index], want[index])
			}
		}
	}
}

func TestPresenceStoreCallbacksCanReenterStateWithoutDeadlock(t *testing.T) {
	fakeClock := clock.NewFake(time.Now())
	store := &reentrantPresenceStore{}
	presence, err := NewPresence(store, fakeClock)
	if err != nil {
		t.Fatal(err)
	}
	store.online = func(matchID, userID string) error {
		if !presence.IsOnline(matchID, userID) {
			return errors.New("online boundary was not visible")
		}
		return nil
	}
	done := make(chan error, 1)
	go func() {
		done <- presence.Connect(context.Background(), presenceMatchID, presenceUserID, presenceOldConn)
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Connect=%v", err)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("PresenceStore callback deadlocked reentering IsOnline")
	}

	store.offline = func(matchID, userID string) error {
		if presence.IsOnline(matchID, userID) {
			return errors.New("offline boundary was not visible")
		}
		return nil
	}
	go func() {
		done <- presence.Disconnect(context.Background(), presenceMatchID, presenceUserID, presenceOldConn)
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Disconnect=%v", err)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("PresenceStore callback deadlocked reentering IsOnline")
	}
}

func TestPresenceReentrantPersistenceFailureRollsBackVisibleBoundary(t *testing.T) {
	fakeClock := clock.NewFake(time.Now())
	store := &reentrantPresenceStore{}
	presence, err := NewPresence(store, fakeClock)
	if err != nil {
		t.Fatal(err)
	}
	store.online = func(matchID, userID string) error {
		if !presence.IsOnline(matchID, userID) {
			t.Error("online state was not visible during persistence")
		}
		return errors.New("private online failure")
	}
	if err := presence.Connect(context.Background(), presenceMatchID, presenceUserID, presenceOldConn); !errors.Is(err, ErrInternal) || err.Error() != ErrInternal.Error() {
		t.Fatalf("Connect=%v", err)
	}
	if presence.IsOnline(presenceMatchID, presenceUserID) {
		t.Fatal("failed online boundary was not rolled back")
	}

	store.online = nil
	if err := presence.Connect(context.Background(), presenceMatchID, presenceUserID, presenceOldConn); err != nil {
		t.Fatal(err)
	}
	store.offline = func(matchID, userID string) error {
		if presence.IsOnline(matchID, userID) {
			t.Error("offline state was not visible during persistence")
		}
		return errors.New("private offline failure")
	}
	if err := presence.Disconnect(context.Background(), presenceMatchID, presenceUserID, presenceOldConn); !errors.Is(err, ErrInternal) || err.Error() != ErrInternal.Error() {
		t.Fatalf("Disconnect=%v", err)
	}
	if !presence.IsOnline(presenceMatchID, presenceUserID) {
		t.Fatal("failed offline boundary was not restored")
	}

	fakeClock.Advance(presenceConnectionTimeout + time.Millisecond)
	if err := presence.Sweep(context.Background()); !errors.Is(err, ErrInternal) || err.Error() != ErrInternal.Error() {
		t.Fatalf("Sweep=%v", err)
	}
	if !presence.IsOnline(presenceMatchID, presenceUserID) {
		t.Fatal("failed sweep boundary was not restored")
	}
}

func TestPresenceSlowPersistenceDoesNotBlockUnrelatedMatchStateOrHeartbeat(t *testing.T) {
	const (
		blockedMatchID = "01000000-0000-4000-8000-000000000001"
		touchedMatchID = "02000000-0000-4000-8000-000000000002"
		expiredMatchID = "03000000-0000-4000-8000-000000000003"
		newMatchID     = "04000000-0000-4000-8000-000000000004"
	)
	fakeClock := clock.NewFake(time.Now())
	store := &matchBlockingPresenceStore{
		blockedMatchID: blockedMatchID,
		entered:        make(chan struct{}),
		release:        make(chan struct{}),
	}
	presence, err := NewPresence(store, fakeClock)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if err := presence.Connect(ctx, touchedMatchID, presenceUserID, presenceOldConn); err != nil {
		t.Fatal(err)
	}
	if err := presence.Connect(ctx, expiredMatchID, presenceUserID, presenceOtherConn); err != nil {
		t.Fatal(err)
	}
	blockedDone := make(chan error, 1)
	go func() {
		blockedDone <- presence.Connect(ctx, blockedMatchID, presenceUserID, presenceNewConn)
	}()
	select {
	case <-store.entered:
	case <-time.After(time.Second):
		t.Fatal("blocking persistence did not start")
	}
	var releaseOnce sync.Once
	releaseBlocked := func() { releaseOnce.Do(func() { close(store.release) }) }
	defer releaseBlocked()

	fakeClock.Advance(presenceConnectionTimeout + time.Millisecond)
	touchDone := make(chan bool, 1)
	go func() { touchDone <- presence.Touch(touchedMatchID, presenceUserID, presenceOldConn) }()
	select {
	case touched := <-touchDone:
		if !touched {
			t.Fatal("heartbeat lost its registered connection")
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("heartbeat was blocked behind unrelated persistence")
	}

	newConnectDone := make(chan error, 1)
	go func() {
		newConnectDone <- presence.Connect(ctx, newMatchID, presenceOtherID, "05000000-0000-4000-8000-000000000005")
	}()
	select {
	case err := <-newConnectDone:
		if err != nil {
			t.Fatalf("unrelated Connect=%v", err)
		}
	case <-time.After(500 * time.Millisecond):
		t.Fatal("unrelated Connect was blocked behind slow persistence")
	}

	sweepDone := make(chan error, 1)
	go func() { sweepDone <- presence.Sweep(ctx) }()
	deadline := time.After(500 * time.Millisecond)
	expiredObserved := false
	for {
		onlineDone := make(chan bool, 1)
		go func() { onlineDone <- presence.IsOnline(expiredMatchID, presenceUserID) }()
		select {
		case online := <-onlineDone:
			if !online {
				if !presence.IsOnline(touchedMatchID, presenceUserID) {
					t.Fatal("sweep overtook the heartbeat and falsely expired it")
				}
				expiredObserved = true
			}
		case <-time.After(100 * time.Millisecond):
			t.Fatal("IsOnline was blocked behind unrelated persistence")
		}
		select {
		case <-deadline:
			t.Fatal("Sweep did not mutate the unrelated expired match")
		case <-time.After(time.Millisecond):
		}
		if expiredObserved {
			break
		}
	}
	releaseBlocked()
	select {
	case err := <-blockedDone:
		if err != nil {
			t.Fatalf("blocked Connect=%v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("blocked Connect did not finish after release")
	}
	select {
	case err := <-sweepDone:
		if err != nil {
			t.Fatalf("Sweep=%v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("Sweep did not finish after persistence release")
	}
}

func TestPresenceHeartbeatOnPersistingMatchPrecedesWaitingSweep(t *testing.T) {
	fakeClock := clock.NewFake(time.Now())
	store := &matchBlockingPresenceStore{
		blockedMatchID: presenceMatchID,
		entered:        make(chan struct{}),
		release:        make(chan struct{}),
	}
	presence, err := NewPresence(store, fakeClock)
	if err != nil {
		t.Fatal(err)
	}
	connectDone := make(chan error, 1)
	go func() {
		connectDone <- presence.Connect(context.Background(), presenceMatchID, presenceUserID, presenceOldConn)
	}()
	select {
	case <-store.entered:
	case <-time.After(time.Second):
		t.Fatal("blocking persistence did not start")
	}
	fakeClock.Advance(presenceConnectionTimeout + time.Millisecond)
	touchDone := make(chan bool, 1)
	go func() { touchDone <- presence.Touch(presenceMatchID, presenceUserID, presenceOldConn) }()
	select {
	case touched := <-touchDone:
		if !touched {
			close(store.release)
			t.Fatal("heartbeat could not touch the in-flight connection")
		}
	case <-time.After(500 * time.Millisecond):
		close(store.release)
		t.Fatal("heartbeat was blocked behind its match persistence")
	}
	sweepDone := make(chan error, 1)
	go func() { sweepDone <- presence.Sweep(context.Background()) }()
	assertDoesNotComplete(t, sweepDone, "Sweep overtook the in-flight match boundary")
	close(store.release)
	if err := <-connectDone; err != nil {
		t.Fatal(err)
	}
	if err := <-sweepDone; err != nil {
		t.Fatal(err)
	}
	if !presence.IsOnline(presenceMatchID, presenceUserID) {
		t.Fatal("Sweep expired a connection after its heartbeat had refreshed lastSeen")
	}
}

func TestPresenceSerializesSameMatchBoundaryWritesAcrossSweepConnectAndDisconnect(t *testing.T) {
	fakeClock := clock.NewFake(time.Now())
	store := &gatedPresenceStore{entered: make(chan presenceCall), proceed: make(chan struct{})}
	presence, err := NewPresence(store, fakeClock)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	connectionTwo := "06000000-0000-4000-8000-000000000006"
	connectionThree := "07000000-0000-4000-8000-000000000007"

	connectOne := make(chan error, 1)
	go func() { connectOne <- presence.Connect(ctx, presenceMatchID, presenceUserID, presenceOldConn) }()
	assertPresenceBoundaryCall(t, store, true)
	store.proceed <- struct{}{}
	if err := <-connectOne; err != nil {
		t.Fatal(err)
	}

	fakeClock.Advance(presenceConnectionTimeout + time.Millisecond)
	sweepDone := make(chan error, 1)
	go func() { sweepDone <- presence.Sweep(ctx) }()
	assertPresenceBoundaryCall(t, store, false)
	connectTwo := make(chan error, 1)
	go func() { connectTwo <- presence.Connect(ctx, presenceMatchID, presenceUserID, connectionTwo) }()
	assertDoesNotComplete(t, connectTwo, "Connect overtook the in-flight offline boundary")
	store.proceed <- struct{}{}
	if err := <-sweepDone; err != nil {
		t.Fatal(err)
	}
	assertPresenceBoundaryCall(t, store, true)
	store.proceed <- struct{}{}
	if err := <-connectTwo; err != nil {
		t.Fatal(err)
	}

	disconnectTwo := make(chan error, 1)
	go func() { disconnectTwo <- presence.Disconnect(ctx, presenceMatchID, presenceUserID, connectionTwo) }()
	assertPresenceBoundaryCall(t, store, false)
	connectThree := make(chan error, 1)
	go func() { connectThree <- presence.Connect(ctx, presenceMatchID, presenceUserID, connectionThree) }()
	assertDoesNotComplete(t, connectThree, "Connect overtook the in-flight Disconnect boundary")
	store.proceed <- struct{}{}
	if err := <-disconnectTwo; err != nil {
		t.Fatal(err)
	}
	assertPresenceBoundaryCall(t, store, true)
	store.proceed <- struct{}{}
	if err := <-connectThree; err != nil {
		t.Fatal(err)
	}
	if !presence.IsOnline(presenceMatchID, presenceUserID) {
		t.Fatal("latest connection should remain online")
	}
	presence.operationMu.Lock()
	operationCount := len(presence.operations)
	presence.operationMu.Unlock()
	if operationCount != 0 {
		t.Fatalf("idle operation locks=%d want 0", operationCount)
	}
}

func TestPresenceSameMatchOperationWaitHonorsContextAndCleansLock(t *testing.T) {
	fakeClock := clock.NewFake(time.Now())
	store := &matchBlockingPresenceStore{
		blockedMatchID: presenceMatchID,
		entered:        make(chan struct{}),
		release:        make(chan struct{}),
	}
	presence, err := NewPresence(store, fakeClock)
	if err != nil {
		t.Fatal(err)
	}
	connectDone := make(chan error, 1)
	go func() {
		connectDone <- presence.Connect(context.Background(), presenceMatchID, presenceUserID, presenceOldConn)
	}()
	select {
	case <-store.entered:
	case <-time.After(time.Second):
		t.Fatal("blocking persistence did not start")
	}
	waitCtx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	started := time.Now()
	err = presence.Disconnect(waitCtx, presenceMatchID, presenceUserID, presenceOldConn)
	if !errors.Is(err, context.DeadlineExceeded) || time.Since(started) > 500*time.Millisecond {
		close(store.release)
		t.Fatalf("waiting Disconnect=%v elapsed=%v", err, time.Since(started))
	}
	close(store.release)
	if err := <-connectDone; err != nil {
		t.Fatal(err)
	}
	presence.operationMu.Lock()
	operationCount := len(presence.operations)
	presence.operationMu.Unlock()
	if operationCount != 0 {
		t.Fatalf("operation locks after canceled waiter=%d want 0", operationCount)
	}
}

func assertPresenceBoundaryCall(t *testing.T, store *gatedPresenceStore, online bool) {
	t.Helper()
	select {
	case call := <-store.entered:
		if call.online != online || call.matchID != presenceMatchID || call.userID != presenceUserID {
			t.Fatalf("boundary call=%+v want online=%t", call, online)
		}
	case <-time.After(time.Second):
		t.Fatalf("missing online=%t boundary call", online)
	}
}

func assertDoesNotComplete(t *testing.T, result <-chan error, message string) {
	t.Helper()
	select {
	case err := <-result:
		t.Fatalf("%s: %v", message, err)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestPresenceTouchAndSweepUseStrictFortyFiveSecondTimeout(t *testing.T) {
	now := time.Date(2026, time.August, 19, 1, 2, 3, 987654321, time.UTC)
	fakeClock := clock.NewFake(now)
	service := &fakePresenceStore{}
	presence, err := NewPresence(service, fakeClock)
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if err := presence.Connect(ctx, presenceMatchID, presenceUserID, presenceOldConn); err != nil {
		t.Fatal(err)
	}
	if err := presence.Connect(ctx, presenceMatchID, presenceOtherID, presenceOtherConn); err != nil {
		t.Fatal(err)
	}
	fakeClock.Advance(45 * time.Second)
	if err := presence.Sweep(ctx); err != nil {
		t.Fatal(err)
	}
	if !presence.IsOnline(presenceMatchID, presenceUserID) || !presence.IsOnline(presenceMatchID, presenceOtherID) {
		t.Fatal("connections exactly 45 seconds old must remain online")
	}
	if !presence.Touch(presenceMatchID, presenceUserID, presenceOldConn) {
		t.Fatal("valid message/pong should touch an existing connection")
	}
	if presence.Touch(presenceMatchID, presenceUserID, presenceNewConn) {
		t.Fatal("touch must not resurrect an unknown connection")
	}
	fakeClock.Advance(time.Millisecond)
	if err := presence.Sweep(ctx); err != nil {
		t.Fatal(err)
	}
	if !presence.IsOnline(presenceMatchID, presenceUserID) || presence.IsOnline(presenceMatchID, presenceOtherID) {
		t.Fatal("only the untouched connection should expire")
	}
	if len(service.snapshotCalls()) != 2 {
		t.Fatalf("single player expiry while peer online persisted an offline boundary: %+v", service.snapshotCalls())
	}
	fakeClock.Advance(45*time.Second - time.Millisecond)
	if err := presence.Sweep(ctx); err != nil {
		t.Fatal(err)
	}
	if !presence.IsOnline(presenceMatchID, presenceUserID) {
		t.Fatal("touched connection at exact timeout should remain")
	}
	fakeClock.Advance(time.Millisecond)
	if err := presence.Sweep(ctx); err != nil {
		t.Fatal(err)
	}
	if presence.IsOnline(presenceMatchID, presenceUserID) {
		t.Fatal("connection older than 45 seconds should expire")
	}
	calls := service.snapshotCalls()
	if len(calls) != 3 || calls[2].online || calls[2].userID != presenceUserID {
		t.Fatalf("last-player expiry calls=%+v", calls)
	}
}

func TestPresenceWorkerSweepsOnInjectedTicksAndStopsOnCancellation(t *testing.T) {
	fakeClock := clock.NewFake(time.Date(2026, time.August, 19, 1, 2, 3, 0, time.UTC))
	service := &fakePresenceStore{called: make(chan presenceCall, 4)}
	presence, err := NewPresence(service, fakeClock)
	if err != nil {
		t.Fatal(err)
	}
	if presenceSweepInterval != 15*time.Second || presenceConnectionTimeout != 45*time.Second {
		t.Fatalf("intervals=%v/%v", presenceSweepInterval, presenceConnectionTimeout)
	}
	if err := presence.Connect(context.Background(), presenceMatchID, presenceUserID, presenceOldConn); err != nil {
		t.Fatal(err)
	}
	<-service.called
	fakeClock.Advance(45*time.Second + time.Millisecond)
	ctx, cancel := context.WithCancel(context.Background())
	ticks := make(chan time.Time)
	done := make(chan error, 1)
	go func() { done <- presence.run(ctx, ticks) }()
	ticks <- fakeClock.Now()
	select {
	case call := <-service.called:
		if call.online {
			t.Fatalf("worker call=%+v", call)
		}
	case <-time.After(time.Second):
		t.Fatal("worker did not sweep on tick")
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("worker cancellation=%v want nil", err)
		}
	case <-time.After(time.Second):
		t.Fatal("worker did not stop")
	}
}

func TestPresencePersistenceFailureRollsBackMemoryBoundary(t *testing.T) {
	fakeClock := clock.NewFake(time.Now())
	service := &fakePresenceStore{failNext: errors.New("private persistence detail")}
	presence, err := NewPresence(service, fakeClock)
	if err != nil {
		t.Fatal(err)
	}
	err = presence.Connect(context.Background(), presenceMatchID, presenceUserID, presenceOldConn)
	if !errors.Is(err, ErrInternal) || err.Error() != ErrInternal.Error() {
		t.Fatalf("Connect error=%v want sanitized internal", err)
	}
	if presence.IsOnline(presenceMatchID, presenceUserID) {
		t.Fatal("failed online boundary must not remain in memory")
	}
	if err := presence.Connect(context.Background(), presenceMatchID, presenceUserID, presenceOldConn); err != nil {
		t.Fatal(err)
	}
	service.mu.Lock()
	service.failNext = errors.New("private offline detail")
	service.mu.Unlock()
	if err := presence.Disconnect(context.Background(), presenceMatchID, presenceUserID, presenceOldConn); !errors.Is(err, ErrInternal) {
		t.Fatalf("Disconnect error=%v want internal", err)
	}
	if !presence.IsOnline(presenceMatchID, presenceUserID) {
		t.Fatal("failed offline boundary must restore the connection for retry")
	}
}

func TestPresenceSweepFailureRestoresOnlyFailedMatchAndCommitsUnrelatedBoundary(t *testing.T) {
	fakeClock := clock.NewFake(time.Now())
	service := &fakePresenceStore{}
	presence, err := NewPresence(service, fakeClock)
	if err != nil {
		t.Fatal(err)
	}
	otherMatchID := "99999999-9999-4999-8999-999999999999"
	if err := presence.Connect(context.Background(), presenceMatchID, presenceUserID, presenceOldConn); err != nil {
		t.Fatal(err)
	}
	if err := presence.Connect(context.Background(), otherMatchID, presenceUserID, presenceNewConn); err != nil {
		t.Fatal(err)
	}
	service.mu.Lock()
	service.failNext = errors.New("private sweep detail")
	service.mu.Unlock()
	fakeClock.Advance(presenceConnectionTimeout + time.Millisecond)
	if err := presence.Sweep(context.Background()); !errors.Is(err, ErrInternal) || err.Error() != ErrInternal.Error() {
		t.Fatalf("Sweep=%v", err)
	}
	firstOnline := presence.IsOnline(presenceMatchID, presenceUserID)
	otherOnline := presence.IsOnline(otherMatchID, presenceUserID)
	if firstOnline == otherOnline {
		t.Fatalf("online states=%t/%t want exactly the failed match restored", firstOnline, otherOnline)
	}
	if err := presence.Sweep(context.Background()); err != nil {
		t.Fatalf("retry Sweep=%v", err)
	}
	if presence.IsOnline(presenceMatchID, presenceUserID) || presence.IsOnline(otherMatchID, presenceUserID) {
		t.Fatal("retry did not expire the restored connection")
	}
}

func TestPresenceRejectsNilDependenciesAndMalformedKeys(t *testing.T) {
	fakeClock := clock.NewFake(time.Now())
	store := &fakePresenceStore{}
	tests := []struct {
		name  string
		store PresenceStore
		clock clock.Clock
	}{
		{name: "nil store", clock: fakeClock},
		{name: "typed nil store", store: (*fakePresenceStore)(nil), clock: fakeClock},
		{name: "nil clock", store: store},
		{name: "typed nil clock", store: store, clock: (*clock.Fake)(nil)},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			presence, err := NewPresence(test.store, test.clock)
			if presence != nil || !errors.Is(err, ErrInvalidConfiguration) || err.Error() != ErrInvalidConfiguration.Error() {
				t.Fatalf("NewPresence=(%v,%v)", presence, err)
			}
		})
	}
	presence, err := NewPresence(store, fakeClock)
	if err != nil {
		t.Fatal(err)
	}
	for _, call := range []func() error{
		func() error {
			return presence.Connect(context.Background(), "not-a-match", presenceUserID, presenceOldConn)
		},
		func() error {
			return presence.Connect(context.Background(), presenceMatchID, "not-a-user", presenceOldConn)
		},
		func() error {
			return presence.Connect(context.Background(), presenceMatchID, presenceUserID, "not-a-connection")
		},
		func() error {
			return presence.Disconnect(context.Background(), presenceMatchID, presenceUserID, "not-a-connection")
		},
		func() error { return presence.Sweep(nil) },
	} {
		if err := call(); !errors.Is(err, ErrInvalidRequest) || err.Error() != ErrInvalidRequest.Error() {
			t.Fatalf("malformed presence call=%v", err)
		}
	}
	var nilPresence *Presence
	if err := nilPresence.Connect(context.Background(), presenceMatchID, presenceUserID, presenceOldConn); !errors.Is(err, ErrInvalidConfiguration) {
		t.Fatalf("nil Connect=%v", err)
	}
	if nilPresence.Touch(presenceMatchID, presenceUserID, presenceOldConn) || nilPresence.IsOnline(presenceMatchID, presenceUserID) {
		t.Fatal("nil presence reported an online connection")
	}
}
