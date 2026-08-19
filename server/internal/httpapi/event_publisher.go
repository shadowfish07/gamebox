package httpapi

import "me.zqydev/gamebox/server/internal/matches"

// MatchEventPublisher is the only transport boundary HTTP cancellation needs.
// Cancel has already committed when Publish is called, so publication is a
// best-effort fan-out operation rather than a second source of business truth.
type MatchEventPublisher interface {
	Publish(matchID string, event matches.Event)
}
