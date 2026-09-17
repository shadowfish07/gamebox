ALTER TABLE users ADD COLUMN auth_epoch TEXT NOT NULL DEFAULT '';
ALTER TABLE refresh_tokens ADD COLUMN revoked_reason TEXT;
CREATE TABLE device_transfers (
 code_hash TEXT PRIMARY KEY NOT NULL,
 user_id TEXT NOT NULL REFERENCES users(id),
 snapshot TEXT NOT NULL,
 expires_at INTEGER NOT NULL,
 receiver_hash TEXT,
 response BLOB,
 redeemed_at INTEGER
);
CREATE INDEX idx_device_transfers_user ON device_transfers(user_id);
CREATE TABLE transfer_attempts (
 bucket TEXT PRIMARY KEY NOT NULL,
 window INTEGER NOT NULL,
 attempts INTEGER NOT NULL
);
