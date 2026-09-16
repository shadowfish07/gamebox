package matches

import (
	"context"
	"database/sql"
)

type connectionCredentialKey struct{}
type connectionCredential struct{ epoch, userID string }

func validConnectionCredential(ctx context.Context, db interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, c connectionCredential) bool {
	var present int
	return db.QueryRowContext(ctx, `SELECT 1 FROM users WHERE auth_epoch=? AND id=? AND enabled=1`, c.epoch, c.userID).Scan(&present) == nil
}
func (c *hubConnection) credentialValid() bool {
	return validConnectionCredential(c.ctx, c.hub.service.db, connectionCredential{c.authEpoch, c.userID})
}

// Disconnect only revoked sessions: a receiver may already have reconnected
// when an idempotent HTTP retry finishes.
func (h *Hub) DisconnectRevokedUser(_ context.Context, userID string) {
	h.mu.Lock()
	var list []*hubConnection
	for _, m := range h.matches {
		for c := range m.connections {
			if c.userID == userID {
				list = append(list, c)
			}
		}
	}
	h.mu.Unlock()
	for _, c := range list {
		// The redemption request may have been cancelled after commit. Each
		// connection owns its credential check independently of that request.
		if !c.credentialValid() {
			c.close()
		}
	}
}
