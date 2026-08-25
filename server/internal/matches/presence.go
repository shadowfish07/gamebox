package matches

import (
	"context"
	"errors"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"me.zqydev/gamebox/server/internal/clock"
)

const (
	presenceSweepInterval = 15 * time.Second
	// Shared with the WebSocket read deadline so transport closure and durable
	// presence expiry cannot drift to different inactivity policies.
	presenceConnectionTimeout = 45 * time.Second
	// Keep expiry persistence within the SQLite store's eight-connection
	// budget while retaining cross-match progress when one write is slow.
	presenceSweepConcurrency = 8
)

// PresenceStore is the narrow durable boundary used when an in-memory player
// changes between zero and one-or-more live connections.
type PresenceStore interface {
	SetPlayerOnline(ctx context.Context, matchID, userID string) error
	SetPlayerOffline(ctx context.Context, matchID, userID string) error
}

// presenceObserver receives committed in-memory player boundaries. Delivery is
// best effort and happens after the per-match operation lock is released so an
// observer may safely close another connection in the same match.
type presenceObserver interface {
	playerPresenceChanged(matchID, userID string, online bool)
}

type presenceConnectionKey struct {
	matchID      string
	userID       string
	connectionID string
}

type presenceMatchOperation struct {
	token chan struct{}
	refs  int
}

// Presence tracks transport connections, not user sessions. A user remains
// online while any distinct connection for the match remains live.
type Presence struct {
	mu                sync.Mutex
	connections       map[presenceConnectionKey]time.Time
	operationMu       sync.Mutex
	operations        map[string]*presenceMatchOperation
	notificationMu    sync.Mutex
	notificationTails map[string]chan struct{}
	observerMu        sync.RWMutex
	observer          presenceObserver
	store             PresenceStore
	clock             clock.Clock
}

func NewPresence(store PresenceStore, serviceClock clock.Clock) (*Presence, error) {
	if nilDependency(store) || nilDependency(serviceClock) {
		return nil, ErrInvalidConfiguration
	}
	return &Presence{
		connections:       make(map[presenceConnectionKey]time.Time),
		operations:        make(map[string]*presenceMatchOperation),
		notificationTails: make(map[string]chan struct{}),
		store:             store,
		clock:             serviceClock,
	}, nil
}

// Connect registers or refreshes one connection. The durable online boundary
// is written before the connection becomes observable to other goroutines.
func (presence *Presence) Connect(ctx context.Context, matchID, userID, connectionID string) error {
	if !presence.configured() {
		return ErrInvalidConfiguration
	}
	if ctx == nil || !canonicalUUID(matchID) || !canonicalUUID(userID) || !canonicalUUID(connectionID) {
		return ErrInvalidRequest
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	release, acquireErr := presence.acquireMatchOperation(ctx, matchID)
	if acquireErr != nil {
		return acquireErr
	}
	changed := false
	defer func() {
		var dispatch func()
		var delivered <-chan struct{}
		if changed {
			dispatch, delivered = presence.prepareNotification(matchID, userID, true)
		}
		release()
		if dispatch != nil {
			dispatch()
			<-delivered
		}
	}()

	presence.mu.Lock()
	key := presenceConnectionKey{matchID: matchID, userID: userID, connectionID: connectionID}
	if _, exists := presence.connections[key]; exists {
		presence.connections[key] = presence.clock.Now().UTC()
		presence.mu.Unlock()
		return nil
	}
	wasOnline := presence.playerOnlineLocked(matchID, userID)
	presence.connections[key] = presence.clock.Now().UTC()
	presence.mu.Unlock()
	if wasOnline {
		return nil
	}
	if err := presence.store.SetPlayerOnline(ctx, matchID, userID); err != nil {
		presence.mu.Lock()
		delete(presence.connections, key)
		presence.mu.Unlock()
		return sanitizePresenceError(ctx, err)
	}
	changed = true
	return nil
}

// Touch records activity from a valid message or pong. Unknown connection IDs
// cannot resurrect an expired or closed connection.
func (presence *Presence) Touch(matchID, userID, connectionID string) bool {
	if !presence.configured() {
		return false
	}
	key := presenceConnectionKey{matchID: matchID, userID: userID, connectionID: connectionID}
	presence.mu.Lock()
	defer presence.mu.Unlock()
	if _, exists := presence.connections[key]; !exists {
		return false
	}
	presence.connections[key] = presence.clock.Now().UTC()
	return true
}

// Disconnect is idempotent. It persists an offline timestamp only when the
// removed connection leaves both players without any connection in the match.
func (presence *Presence) Disconnect(ctx context.Context, matchID, userID, connectionID string) error {
	if !presence.configured() {
		return ErrInvalidConfiguration
	}
	if ctx == nil || !canonicalUUID(matchID) || !canonicalUUID(userID) || !canonicalUUID(connectionID) {
		return ErrInvalidRequest
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	release, acquireErr := presence.acquireMatchOperation(ctx, matchID)
	if acquireErr != nil {
		return acquireErr
	}
	changed := false
	defer func() {
		var dispatch func()
		if changed {
			dispatch, _ = presence.prepareNotification(matchID, userID, false)
		}
		release()
		if dispatch != nil {
			dispatch()
		}
	}()

	presence.mu.Lock()
	key := presenceConnectionKey{matchID: matchID, userID: userID, connectionID: connectionID}
	lastSeen, exists := presence.connections[key]
	if !exists {
		presence.mu.Unlock()
		return nil
	}
	delete(presence.connections, key)
	if presence.playerOnlineLocked(matchID, userID) {
		presence.mu.Unlock()
		return nil
	}
	if presence.matchOnlineLocked(matchID) {
		presence.mu.Unlock()
		changed = true
		return nil
	}
	presence.mu.Unlock()
	if err := presence.store.SetPlayerOffline(ctx, matchID, userID); err != nil {
		presence.mu.Lock()
		presence.connections[key] = lastSeen
		presence.mu.Unlock()
		return sanitizePresenceError(ctx, err)
	}
	changed = true
	return nil
}

func (presence *Presence) IsOnline(matchID, userID string) bool {
	if !presence.configured() {
		return false
	}
	presence.mu.Lock()
	defer presence.mu.Unlock()
	return presence.playerOnlineLocked(matchID, userID)
}

// onlineStates returns one coherent in-memory view for a platform handshake.
// Unknown users are represented as offline so callers can preserve the stable
// match player list without leaking unrelated connection state.
func (presence *Presence) onlineStates(matchID string, userIDs []string) map[string]bool {
	states := make(map[string]bool, len(userIDs))
	if !presence.configured() {
		return states
	}
	presence.mu.Lock()
	defer presence.mu.Unlock()
	for _, userID := range userIDs {
		states[userID] = presence.playerOnlineLocked(matchID, userID)
	}
	return states
}

// Sweep removes connections strictly older than the timeout. Matches are
// swept independently so slow persistence for one match cannot delay state
// mutation or boundary writes for another match.
func (presence *Presence) Sweep(ctx context.Context) error {
	if !presence.configured() {
		return ErrInvalidConfiguration
	}
	if ctx == nil {
		return ErrInvalidRequest
	}
	if err := ctx.Err(); err != nil {
		return err
	}

	now := presence.clock.Now().UTC()
	presence.mu.Lock()
	keysByMatch := make(map[string][]presenceConnectionKey)
	for key := range presence.connections {
		keysByMatch[key.matchID] = append(keysByMatch[key.matchID], key)
	}
	presence.mu.Unlock()
	matchIDs := make([]string, 0, len(keysByMatch))
	for matchID := range keysByMatch {
		matchIDs = append(matchIDs, matchID)
	}
	sort.Strings(matchIDs)
	type sweepResult struct {
		index int
		err   error
	}
	workerCount := min(len(matchIDs), presenceSweepConcurrency)
	if workerCount == 0 {
		return nil
	}
	results := make(chan sweepResult, workerCount)
	var nextJob atomic.Int64
	var workers sync.WaitGroup
	workers.Add(workerCount)
	for range workerCount {
		go func() {
			defer workers.Done()
			for {
				index := int(nextJob.Add(1) - 1)
				if index >= len(matchIDs) {
					return
				}
				matchID := matchIDs[index]
				results <- sweepResult{index: index, err: presence.sweepMatch(ctx, matchID, keysByMatch[matchID], now)}
			}
		}()
	}
	firstErrorIndex := len(matchIDs)
	var firstError error
	for range matchIDs {
		result := <-results
		if result.err != nil && result.index < firstErrorIndex {
			firstErrorIndex = result.index
			firstError = result.err
		}
	}
	workers.Wait()
	return firstError
}

func (presence *Presence) sweepMatch(ctx context.Context, matchID string, candidates []presenceConnectionKey, now time.Time) error {
	release, acquireErr := presence.acquireMatchOperation(ctx, matchID)
	if acquireErr != nil {
		return acquireErr
	}
	offlineUserIDs := make([]string, 0, 2)
	defer func() {
		dispatches := make([]func(), 0, len(offlineUserIDs))
		for _, userID := range offlineUserIDs {
			dispatch, _ := presence.prepareNotification(matchID, userID, false)
			dispatches = append(dispatches, dispatch)
		}
		release()
		for _, dispatch := range dispatches {
			dispatch()
		}
	}()

	expired := make(map[presenceConnectionKey]time.Time)
	presence.mu.Lock()
	for _, key := range candidates {
		lastSeen, exists := presence.connections[key]
		if exists && now.Sub(lastSeen) > presenceConnectionTimeout {
			expired[key] = lastSeen
			delete(presence.connections, key)
		}
	}
	expiredUserIDs := make([]string, 0, len(expired))
	seenUsers := make(map[string]struct{}, len(expired))
	for key := range expired {
		if _, seen := seenUsers[key.userID]; seen {
			continue
		}
		seenUsers[key.userID] = struct{}{}
		expiredUserIDs = append(expiredUserIDs, key.userID)
	}
	for _, userID := range expiredUserIDs {
		if !presence.playerOnlineLocked(matchID, userID) {
			offlineUserIDs = append(offlineUserIDs, userID)
		}
	}
	matchOnline := presence.matchOnlineLocked(matchID)
	presence.mu.Unlock()
	if len(expired) == 0 {
		return nil
	}
	sort.Strings(offlineUserIDs)
	if matchOnline {
		return nil
	}
	if err := presence.store.SetPlayerOffline(ctx, matchID, offlineUserIDs[0]); err != nil {
		presence.mu.Lock()
		for key, lastSeen := range expired {
			presence.connections[key] = lastSeen
		}
		presence.mu.Unlock()
		offlineUserIDs = offlineUserIDs[:0]
		return sanitizePresenceError(ctx, err)
	}
	return nil
}

func (presence *Presence) setObserver(observer presenceObserver) {
	presence.observerMu.Lock()
	presence.observer = observer
	presence.observerMu.Unlock()
}

func (presence *Presence) notify(matchID, userID string, online bool) {
	presence.observerMu.RLock()
	observer := presence.observer
	presence.observerMu.RUnlock()
	if observer != nil {
		observer.playerPresenceChanged(matchID, userID, online)
	}
}

// prepareNotification reserves this boundary's position while the caller still
// owns the match operation, then returns a dispatcher that starts only after
// the operation is released. Chaining completion channels preserves commit
// order without invoking a reentrant observer under the operation lock.
func (presence *Presence) prepareNotification(matchID, userID string, online bool) (func(), <-chan struct{}) {
	presence.notificationMu.Lock()
	predecessor := presence.notificationTails[matchID]
	done := make(chan struct{})
	presence.notificationTails[matchID] = done
	presence.notificationMu.Unlock()
	dispatch := func() {
		go func() {
			if predecessor != nil {
				<-predecessor
			}
			presence.notify(matchID, userID, online)
			close(done)
			presence.notificationMu.Lock()
			if presence.notificationTails[matchID] == done {
				delete(presence.notificationTails, matchID)
			}
			presence.notificationMu.Unlock()
		}()
	}
	return dispatch, done
}

// Run starts the production 15-second expiry worker and returns after
// cancellation or an unrecoverable persistence failure.
func (presence *Presence) Run(ctx context.Context) error {
	if !presence.configured() {
		return ErrInvalidConfiguration
	}
	if ctx == nil {
		return ErrInvalidRequest
	}
	ticker := time.NewTicker(presenceSweepInterval)
	defer ticker.Stop()
	return presence.run(ctx, ticker.C)
}

func (presence *Presence) run(ctx context.Context, ticks <-chan time.Time) error {
	if !presence.configured() || ctx == nil || ticks == nil {
		return ErrInvalidConfiguration
	}
	for {
		select {
		case <-ctx.Done():
			return nil
		case _, open := <-ticks:
			if !open {
				return nil
			}
			if err := presence.Sweep(ctx); err != nil {
				if ctx.Err() != nil {
					return nil
				}
				return err
			}
		}
	}
}

func (presence *Presence) playerOnlineLocked(matchID, userID string) bool {
	for key := range presence.connections {
		if key.matchID == matchID && key.userID == userID {
			return true
		}
	}
	return false
}

func (presence *Presence) matchOnlineLocked(matchID string) bool {
	for key := range presence.connections {
		if key.matchID == matchID {
			return true
		}
	}
	return false
}

func (presence *Presence) acquireMatchOperation(ctx context.Context, matchID string) (func(), error) {
	presence.operationMu.Lock()
	operation := presence.operations[matchID]
	if operation == nil {
		operation = &presenceMatchOperation{token: make(chan struct{}, 1)}
		presence.operations[matchID] = operation
	}
	operation.refs++
	presence.operationMu.Unlock()

	select {
	case operation.token <- struct{}{}:
		if err := ctx.Err(); err != nil {
			<-operation.token
			presence.releaseMatchOperation(matchID, operation)
			return nil, err
		}
		return func() {
			<-operation.token
			presence.releaseMatchOperation(matchID, operation)
		}, nil
	case <-ctx.Done():
		presence.releaseMatchOperation(matchID, operation)
		return nil, ctx.Err()
	}
}

func (presence *Presence) releaseMatchOperation(matchID string, operation *presenceMatchOperation) {
	presence.operationMu.Lock()
	defer presence.operationMu.Unlock()
	operation.refs--
	if operation.refs == 0 && presence.operations[matchID] == operation {
		delete(presence.operations, matchID)
	}
}

func (presence *Presence) configured() bool {
	return presence != nil && presence.connections != nil && presence.operations != nil &&
		presence.notificationTails != nil && !nilDependency(presence.store) && !nilDependency(presence.clock)
}

func sanitizePresenceError(ctx context.Context, err error) error {
	if ctx != nil && ctx.Err() != nil {
		return ctx.Err()
	}
	if errors.Is(err, context.Canceled) {
		return context.Canceled
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return context.DeadlineExceeded
	}
	switch {
	case errors.Is(err, ErrInvalidConfiguration):
		return ErrInvalidConfiguration
	case errors.Is(err, ErrInvalidRequest):
		return ErrInvalidRequest
	case errors.Is(err, ErrMatchNotFound):
		return ErrMatchNotFound
	default:
		return ErrInternal
	}
}
