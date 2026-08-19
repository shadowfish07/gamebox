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

func TestPresenceSweepFailureRestoresAllUnprocessedExpiredMatches(t *testing.T) {
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
	if !presence.IsOnline(presenceMatchID, presenceUserID) || !presence.IsOnline(otherMatchID, presenceUserID) {
		t.Fatal("failed sweep silently discarded an unprocessed match connection")
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
