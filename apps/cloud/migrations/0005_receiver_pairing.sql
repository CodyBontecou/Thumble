-- Only explicitly shared, short-lived pairing images. No raw LAN invitations.
CREATE TABLE receiver_pairing_sessions (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  name TEXT NOT NULL,
  publisher_hash TEXT NOT NULL,
  session_expires_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  sequence INTEGER NOT NULL DEFAULT 0,
  connected INTEGER NOT NULL DEFAULT 0,
  png TEXT,
  code_expires_at INTEGER
);
CREATE INDEX receiver_pairing_account ON receiver_pairing_sessions(account_id, session_expires_at);
CREATE TRIGGER deleted_pairing_insert BEFORE INSERT ON receiver_pairing_sessions
WHEN EXISTS (SELECT 1 FROM cloud_deleted_accounts WHERE account_id = NEW.account_id)
BEGIN SELECT RAISE(ABORT, 'account_deleted'); END;
CREATE TRIGGER deleted_pairing_update BEFORE UPDATE ON receiver_pairing_sessions
WHEN EXISTS (SELECT 1 FROM cloud_deleted_accounts WHERE account_id = NEW.account_id)
BEGIN SELECT RAISE(ABORT, 'account_deleted'); END;
