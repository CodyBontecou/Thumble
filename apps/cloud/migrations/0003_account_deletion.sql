-- A minimal security tombstone blocks signed JWT reuse and concurrent writes.
-- Contains only the already-hashed account ID and deletion timestamp.
CREATE TABLE cloud_deleted_accounts (
  account_id TEXT PRIMARY KEY,
  deleted_at TEXT NOT NULL
);
CREATE TRIGGER deleted_profile_insert BEFORE INSERT ON profile_revisions
WHEN EXISTS (SELECT 1 FROM cloud_deleted_accounts WHERE account_id = NEW.account_id)
BEGIN SELECT RAISE(ABORT, 'account_deleted'); END;
CREATE TRIGGER deleted_profile_update BEFORE UPDATE ON profile_revisions
WHEN EXISTS (SELECT 1 FROM cloud_deleted_accounts WHERE account_id = NEW.account_id)
BEGIN SELECT RAISE(ABORT, 'account_deleted'); END;
CREATE TRIGGER deleted_device_insert BEFORE INSERT ON devices
WHEN EXISTS (SELECT 1 FROM cloud_deleted_accounts WHERE account_id = NEW.account_id)
BEGIN SELECT RAISE(ABORT, 'account_deleted'); END;
CREATE TRIGGER deleted_device_update BEFORE UPDATE ON devices
WHEN EXISTS (SELECT 1 FROM cloud_deleted_accounts WHERE account_id = NEW.account_id)
BEGIN SELECT RAISE(ABORT, 'account_deleted'); END;
CREATE TRIGGER deleted_delivery_insert BEFORE INSERT ON deliveries
WHEN EXISTS (SELECT 1 FROM cloud_deleted_accounts WHERE account_id = NEW.account_id)
BEGIN SELECT RAISE(ABORT, 'account_deleted'); END;
CREATE TRIGGER deleted_delivery_update BEFORE UPDATE ON deliveries
WHEN EXISTS (SELECT 1 FROM cloud_deleted_accounts WHERE account_id = NEW.account_id)
BEGIN SELECT RAISE(ABORT, 'account_deleted'); END;
-- No product surface uses provider avatars. Remove earlier copied URLs.
UPDATE "user" SET image = NULL WHERE image IS NOT NULL;
-- An authorization request authenticated before deletion must not leave a new
-- orphaned authorization code after its user is gone.
CREATE TRIGGER deleted_verification_insert BEFORE INSERT ON verification
WHEN CASE WHEN json_valid(NEW.value) THEN json_extract(NEW.value, '$.userId') IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM "user" WHERE id = json_extract(NEW.value, '$.userId')) ELSE 0 END
BEGIN SELECT RAISE(ABORT, 'account_deleted'); END;
