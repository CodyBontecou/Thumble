CREATE TABLE IF NOT EXISTS profile_revisions (
 account_id TEXT NOT NULL,
 profile_id TEXT NOT NULL,
 revision INTEGER NOT NULL CHECK(revision > 0),
 name TEXT NOT NULL,
 profile_json TEXT NOT NULL,
 created_at TEXT NOT NULL,
 PRIMARY KEY(account_id, profile_id, revision)
);
CREATE TABLE IF NOT EXISTS devices (
 id TEXT PRIMARY KEY,
 account_id TEXT NOT NULL,
 name TEXT NOT NULL,
 platform TEXT NOT NULL CHECK(platform IN ('ios','android')),
 width REAL NOT NULL,
 height REAL NOT NULL,
 token_hash TEXT NOT NULL UNIQUE,
 token_expires_at TEXT NOT NULL,
 created_at TEXT NOT NULL,
 last_seen_at TEXT NOT NULL,
 revoked_at TEXT
);
CREATE INDEX IF NOT EXISTS devices_account ON devices(account_id);
CREATE TABLE IF NOT EXISTS deliveries (
 id TEXT PRIMARY KEY,
 account_id TEXT NOT NULL,
 device_id TEXT NOT NULL REFERENCES devices(id),
 profile_id TEXT NOT NULL,
 profile_revision INTEGER NOT NULL,
 request_id TEXT NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('queued','received','rendered','failed','superseded')),
 created_at TEXT NOT NULL,
 updated_at TEXT NOT NULL,
 error TEXT,
 UNIQUE(account_id, request_id),
 FOREIGN KEY(account_id, profile_id, profile_revision) REFERENCES profile_revisions(account_id, profile_id, revision)
);
CREATE INDEX IF NOT EXISTS deliveries_device ON deliveries(device_id, state);
