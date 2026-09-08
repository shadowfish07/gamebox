CREATE TABLE scratch_collections (
    user_id TEXT NOT NULL PRIMARY KEY REFERENCES users(id),
    counts_json TEXT NOT NULL,
    updated_at INTEGER NOT NULL
);
