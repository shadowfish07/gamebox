package auth

import (
	"context"
	"database/sql"
)

type requestIdentityKey struct{}

// WithRequestIdentity binds mutating service transactions to the authenticated
// session, closing the gap between middleware authentication and commit.
func WithRequestIdentity(ctx context.Context, identity AccessIdentity) context.Context {
	return context.WithValue(ctx, requestIdentityKey{}, identity)
}
func GuardTransaction(ctx context.Context, tx *sql.Tx) error {
	identity, ok := ctx.Value(requestIdentityKey{}).(AccessIdentity)
	if !ok {
		return nil
	}
	var valid int
	err := tx.QueryRowContext(ctx, `SELECT 1 FROM users WHERE id=? AND auth_epoch=? AND enabled=1`, identity.UserID, identity.Epoch).Scan(&valid)
	if err == sql.ErrNoRows {
		return ErrUnauthorized
	}
	return err
}
