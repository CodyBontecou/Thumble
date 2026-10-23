//! Private write-lifetime prerequisite; not connected to any phone role.
//!
//! Dispatch must target this exact owner lifetime. A retired owner is never
//! reopened/replaced for queued work. Definitive completion is trusted only after
//! correlation with an actual owner response, never a local promise rejection.
//! Dropping a ticket, timeout, EOF, or kill issuance does not complete a write.
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum FenceError {
    Closed,
    Busy,
    InvalidTicket,
    Pending,
    UnsafeDatabase,
    IdentityChanged,
    Unavailable,
    Unsupported,
}
struct WriterState {
    retired: bool,
    pending: bool,
}
pub(crate) struct WriterLifetime {
    identity: [u8; 16],
    state: Mutex<WriterState>,
}
pub(crate) struct RetiredWriter(Arc<WriterLifetime>);
impl WriterLifetime {
    pub(crate) fn new(identity: [u8; 16]) -> Arc<Self> {
        Arc::new(Self {
            identity,
            state: Mutex::new(WriterState {
                retired: false,
                pending: false,
            }),
        })
    }
    /// Future dispatch is permanently disabled, including reserved queued work.
    pub(crate) fn retire(self: &Arc<Self>) -> Result<RetiredWriter, FenceError> {
        self.state
            .lock()
            .map_err(|_| FenceError::Unavailable)?
            .retired = true;
        Ok(RetiredWriter(self.clone()))
    }
}
#[derive(Clone, Copy)]
struct Pending {
    id: u64,
    dispatched: bool,
}
struct State {
    closed: bool,
    next: u64,
    pending: Option<Pending>,
}
pub(crate) struct CommitFence {
    writer: Arc<WriterLifetime>,
    state: Mutex<State>,
    changed: Condvar,
}
pub(crate) struct Ticket {
    fence: Arc<CommitFence>,
    id: u64,
}
/// No Drop implementation: losing this value must leave pending work fenced.
pub(crate) struct DrainedScope {
    _fence: Arc<CommitFence>,
}
impl CommitFence {
    pub(crate) fn new(writer: Arc<WriterLifetime>) -> Arc<Self> {
        Arc::new(Self {
            writer,
            state: Mutex::new(State {
                closed: false,
                next: 1,
                pending: None,
            }),
            changed: Condvar::new(),
        })
    }
    pub(crate) fn admit(self: &Arc<Self>) -> Result<Ticket, FenceError> {
        let mut writer = self
            .writer
            .state
            .lock()
            .map_err(|_| FenceError::Unavailable)?;
        let mut state = self.state.lock().map_err(|_| FenceError::Unavailable)?;
        if writer.retired || state.closed {
            return Err(FenceError::Closed);
        }
        if writer.pending {
            return Err(FenceError::Busy);
        }
        let id = state.next;
        state.next = id.checked_add(1).ok_or(FenceError::Unavailable)?;
        state.pending = Some(Pending {
            id,
            dispatched: false,
        });
        writer.pending = true;
        Ok(Ticket {
            fence: self.clone(),
            id,
        })
    }
    /// Call BEFORE any event/pipe bytes can be queued. Parent and child must also
    /// reject a different/retired owner identity; this local gate is not IPC proof.
    pub(crate) fn dispatch(
        self: &Arc<Self>,
        ticket: &Ticket,
        owner: [u8; 16],
    ) -> Result<(), FenceError> {
        if !Arc::ptr_eq(self, &ticket.fence) || owner != self.writer.identity {
            return Err(FenceError::InvalidTicket);
        }
        let writer = self
            .writer
            .state
            .lock()
            .map_err(|_| FenceError::Unavailable)?;
        let mut state = self.state.lock().map_err(|_| FenceError::Unavailable)?;
        if writer.retired || state.closed {
            return Err(FenceError::Closed);
        }
        let pending = state
            .pending
            .as_mut()
            .filter(|p| p.id == ticket.id && !p.dispatched)
            .ok_or(FenceError::InvalidTicket)?;
        pending.dispatched = true;
        Ok(())
    }
    /// Only a strictly correlated, actual owner completion may call this method.
    pub(crate) fn definitive_completion(
        self: &Arc<Self>,
        ticket: &Ticket,
        owner: [u8; 16],
    ) -> Result<(), FenceError> {
        if !Arc::ptr_eq(self, &ticket.fence) || owner != self.writer.identity {
            return Err(FenceError::InvalidTicket);
        }
        let mut writer = self
            .writer
            .state
            .lock()
            .map_err(|_| FenceError::Unavailable)?;
        let mut state = self.state.lock().map_err(|_| FenceError::Unavailable)?;
        if !state
            .pending
            .is_some_and(|p| p.id == ticket.id && p.dispatched)
        {
            return Err(FenceError::InvalidTicket);
        }
        state.pending = None;
        writer.pending = false;
        self.changed.notify_all();
        Ok(())
    }
    /// Close admissions before draining. Undispatched reservations cannot later
    /// start; dispatched work remains pending even when its Ticket was dropped.
    pub(crate) fn close_admission(&self) -> Result<(), FenceError> {
        let mut writer = self
            .writer
            .state
            .lock()
            .map_err(|_| FenceError::Unavailable)?;
        let mut state = self.state.lock().map_err(|_| FenceError::Unavailable)?;
        state.closed = true;
        if state.pending.is_some_and(|p| !p.dispatched) {
            state.pending = None;
            writer.pending = false;
            self.changed.notify_all();
        }
        Ok(())
    }
    /// Pending is not an acknowledgment result. Timeout never releases a ticket.
    /// This wait holds no writer/input/trust/policy mutex while blocked.
    pub(crate) fn wait_drained(
        self: &Arc<Self>,
        budget: Duration,
    ) -> Result<DrainedScope, FenceError> {
        let until = Instant::now()
            .checked_add(budget)
            .ok_or(FenceError::Unavailable)?;
        let mut state = self.state.lock().map_err(|_| FenceError::Unavailable)?;
        if !state.closed {
            return Err(FenceError::Closed);
        }
        while state.pending.is_some() {
            let left = until.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(FenceError::Pending);
            }
            state = self
                .changed
                .wait_timeout(state, left)
                .map_err(|_| FenceError::Unavailable)?
                .0;
        }
        Ok(DrainedScope {
            _fence: self.clone(),
        })
    }
}

#[cfg(unix)]
mod database {
    use super::*;
    use rusqlite::{Connection, Error, ErrorCode, OpenFlags};
    use std::{
        fs::{self, File, OpenOptions},
        os::unix::fs::{MetadataExt, OpenOptionsExt},
        path::{Path, PathBuf},
    };
    /// SQLite's own VFS compares the opened database inode to its current path.
    /// Pair this with our startup identity check so opening a substituted inode
    /// cannot masquerade as the original after the path is restored.
    pub(super) fn connection_unchanged(connection: &Connection) -> Result<(), FenceError> {
        let mut moved: libc::c_int = 0;
        // Both pointers refer to live objects for this synchronous SQLite call.
        let status = unsafe {
            rusqlite::ffi::sqlite3_file_control(
                connection.handle(),
                c"main".as_ptr(),
                rusqlite::ffi::SQLITE_FCNTL_HAS_MOVED,
                (&mut moved as *mut libc::c_int).cast(),
            )
        };
        if status != rusqlite::ffi::SQLITE_OK {
            return Err(FenceError::Unavailable);
        }
        if moved != 0 {
            return Err(FenceError::IdentityChanged);
        }
        Ok(())
    }
    pub(crate) struct BoundDatabase {
        path: PathBuf,
        identity: (u64, u64),
        writer: Arc<WriterLifetime>,
    }
    /// Keep this guard alive through orphan-drain acknowledgments. It holds the
    /// existing DB transaction, not any input/trust/policy/global mutex.
    pub(crate) struct OrphanDrain {
        _connection: Connection,
        _file: File,
        _scope: DrainedScope,
    }
    impl BoundDatabase {
        pub(crate) fn existing(
            root: &Path,
            writer: Arc<WriterLifetime>,
        ) -> Result<Self, FenceError> {
            if !root.is_absolute()
                || fs::canonicalize(root).map_err(|_| FenceError::UnsafeDatabase)? != root
            {
                return Err(FenceError::UnsafeDatabase);
            }
            for at in root.ancestors() {
                if fs::symlink_metadata(at)
                    .map_err(|_| FenceError::UnsafeDatabase)?
                    .file_type()
                    .is_symlink()
                {
                    return Err(FenceError::UnsafeDatabase);
                }
            }
            let root_meta = fs::symlink_metadata(root).map_err(|_| FenceError::UnsafeDatabase)?;
            if !root_meta.is_dir()
                || root_meta.uid() != unsafe { libc::geteuid() }
                || root_meta.mode() & 0o077 != 0
            {
                return Err(FenceError::UnsafeDatabase);
            }
            let path = root.join("configuration-v1.sqlite3");
            let file = Self::open(&path)?;
            let m = file.metadata().map_err(|_| FenceError::Unavailable)?;
            Ok(Self {
                path,
                identity: (m.dev(), m.ino()),
                writer,
            })
        }
        fn open(path: &Path) -> Result<File, FenceError> {
            let file = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW)
                .open(path)
                .map_err(|_| FenceError::UnsafeDatabase)?;
            let m = file.metadata().map_err(|_| FenceError::UnsafeDatabase)?;
            if !m.is_file()
                || m.nlink() != 1
                || m.uid() != unsafe { libc::geteuid() }
                || m.mode() & 0o077 != 0
            {
                return Err(FenceError::UnsafeDatabase);
            }
            Ok(file)
        }
        fn checked_file(&self) -> Result<File, FenceError> {
            // Recheck ancestors on recovery as well as at trusted startup.
            for at in self
                .path
                .parent()
                .ok_or(FenceError::UnsafeDatabase)?
                .ancestors()
            {
                if fs::symlink_metadata(at)
                    .map_err(|_| FenceError::UnsafeDatabase)?
                    .file_type()
                    .is_symlink()
                {
                    return Err(FenceError::UnsafeDatabase);
                }
            }
            let root = self.path.parent().ok_or(FenceError::UnsafeDatabase)?;
            let metadata = fs::symlink_metadata(root).map_err(|_| FenceError::UnsafeDatabase)?;
            if !metadata.is_dir()
                || metadata.uid() != unsafe { libc::geteuid() }
                || metadata.mode() & 0o077 != 0
            {
                return Err(FenceError::UnsafeDatabase);
            }
            let file = Self::open(&self.path)?;
            let m = file.metadata().map_err(|_| FenceError::Unavailable)?;
            if (m.dev(), m.ino()) != self.identity {
                return Err(FenceError::IdentityChanged);
            }
            Ok(file)
        }
        pub(crate) fn try_orphan_drain(
            &self,
            fence: &Arc<CommitFence>,
            retired: &RetiredWriter,
        ) -> Result<OrphanDrain, FenceError> {
            if !Arc::ptr_eq(&self.writer, &retired.0) || !Arc::ptr_eq(&self.writer, &fence.writer) {
                return Err(FenceError::InvalidTicket);
            }
            if !self
                .writer
                .state
                .lock()
                .map_err(|_| FenceError::Unavailable)?
                .retired
            {
                return Err(FenceError::Closed);
            }
            {
                let state = fence.state.lock().map_err(|_| FenceError::Unavailable)?;
                if !state.closed {
                    return Err(FenceError::Closed);
                }
                if !state.pending.is_some_and(|p| p.dispatched) {
                    return Err(FenceError::InvalidTicket);
                }
            }
            let file = self.checked_file()?;
            let connection = Connection::open_with_flags(
                &self.path,
                OpenFlags::SQLITE_OPEN_READ_WRITE
                    | OpenFlags::SQLITE_OPEN_NO_MUTEX
                    | OpenFlags::SQLITE_OPEN_NOFOLLOW,
            )
            .map_err(|_| FenceError::Unavailable)?;
            connection
                .busy_timeout(Duration::ZERO)
                .map_err(|_| FenceError::Unavailable)?;
            match connection.execute_batch("BEGIN EXCLUSIVE") {
                Ok(()) => {}
                Err(Error::SqliteFailure(e, _))
                    if matches!(e.code, ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked) =>
                {
                    return Err(FenceError::Busy)
                }
                Err(_) => return Err(FenceError::Unavailable),
            }
            self.checked_file()?;
            connection_unchanged(&connection)?;
            let application: i64 = connection
                .pragma_query_value(None, "application_id", |r| r.get(0))
                .map_err(|_| FenceError::UnsafeDatabase)?;
            let version: i64 = connection
                .pragma_query_value(None, "user_version", |r| r.get(0))
                .map_err(|_| FenceError::UnsafeDatabase)?;
            if application != 0x54484346 || version != 1 {
                return Err(FenceError::UnsafeDatabase);
            }
            let mut writer = self
                .writer
                .state
                .lock()
                .map_err(|_| FenceError::Unavailable)?;
            let mut state = fence.state.lock().map_err(|_| FenceError::Unavailable)?;
            state.pending = None;
            writer.pending = false;
            fence.changed.notify_all();
            drop(state);
            drop(writer);
            Ok(OrphanDrain {
                _connection: connection,
                _file: file,
                _scope: DrainedScope {
                    _fence: fence.clone(),
                },
            })
        }
    }
}
#[cfg(unix)]
pub(crate) type BoundDatabase = database::BoundDatabase;
#[cfg(not(unix))]
pub(crate) struct BoundDatabase;
#[cfg(not(unix))]
impl BoundDatabase {
    pub(crate) fn existing(
        _: &std::path::Path,
        _: Arc<WriterLifetime>,
    ) -> Result<Self, FenceError> {
        Err(FenceError::Unsupported)
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use rusqlite::Connection;
    use std::{
        fs,
        os::unix::fs::{symlink, PermissionsExt},
        path::PathBuf,
        sync::{
            atomic::{AtomicU64, Ordering},
            mpsc,
        },
        thread,
    };
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let path = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "thumble-editor-fence-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&path).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
            Self(path)
        }
        fn database(&self) -> Connection {
            let db = Connection::open(self.0.join("configuration-v1.sqlite3")).unwrap();
            db.execute_batch("PRAGMA application_id=1414021958; PRAGMA user_version=1; CREATE TABLE IF NOT EXISTS fixture(value INTEGER); INSERT INTO fixture VALUES(0);").unwrap();
            fs::set_permissions(
                self.0.join("configuration-v1.sqlite3"),
                fs::Permissions::from_mode(0o600),
            )
            .unwrap();
            db
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn pending() -> (Arc<WriterLifetime>, Arc<CommitFence>, Ticket) {
        let writer = WriterLifetime::new([1; 16]);
        let fence = CommitFence::new(writer.clone());
        let ticket = fence.admit().unwrap();
        fence.dispatch(&ticket, [1; 16]).unwrap();
        (writer, fence, ticket)
    }
    #[test]
    fn queued_reservation_cannot_dispatch_after_close_or_retarget_a_new_owner() {
        let writer = WriterLifetime::new([1; 16]);
        let old = CommitFence::new(writer.clone());
        let queued = old.admit().unwrap();
        old.close_admission().unwrap();
        assert_eq!(old.dispatch(&queued, [1; 16]), Err(FenceError::Closed));
        assert!(old.wait_drained(Duration::ZERO).is_ok());
        let next = CommitFence::new(writer.clone());
        let ticket = next.admit().unwrap();
        next.dispatch(&ticket, [1; 16]).unwrap();
        assert!(matches!(
            CommitFence::new(writer.clone()).admit(),
            Err(FenceError::Busy)
        ));
        next.definitive_completion(&ticket, [1; 16]).unwrap();
        writer.retire().unwrap();
        assert_eq!(old.dispatch(&queued, [1; 16]), Err(FenceError::Closed));
        let replacement = CommitFence::new(WriterLifetime::new([2; 16]));
        let fresh = replacement.admit().unwrap();
        assert_eq!(
            replacement.dispatch(&fresh, [1; 16]),
            Err(FenceError::InvalidTicket)
        );
        assert_eq!(
            replacement.dispatch(&queued, [2; 16]),
            Err(FenceError::InvalidTicket)
        );
    }
    #[test]
    fn only_correlated_definitive_completion_drains_and_dropping_ticket_is_not_proof() {
        let (writer, fence, ticket) = pending();
        fence.close_admission().unwrap();
        assert!(matches!(
            fence.wait_drained(Duration::ZERO),
            Err(FenceError::Pending)
        ));
        assert_eq!(
            fence.definitive_completion(&ticket, [2; 16]),
            Err(FenceError::InvalidTicket)
        );
        let foreign = CommitFence::new(WriterLifetime::new([1; 16]));
        assert_eq!(
            foreign.definitive_completion(&ticket, [1; 16]),
            Err(FenceError::InvalidTicket)
        );
        fence.definitive_completion(&ticket, [1; 16]).unwrap();
        assert!(fence.wait_drained(Duration::ZERO).is_ok());
        assert_eq!(
            fence.definitive_completion(&ticket, [1; 16]),
            Err(FenceError::InvalidTicket)
        );
        let other = CommitFence::new(writer);
        let dropped = other.admit().unwrap();
        other.dispatch(&dropped, [1; 16]).unwrap();
        drop(dropped);
        other.close_admission().unwrap();
        assert!(matches!(
            other.wait_drained(Duration::ZERO),
            Err(FenceError::Pending)
        ));
    }
    #[test]
    fn orphan_busy_never_acknowledges_and_recovery_holds_db_without_global_input_policy_locks() {
        let root = Root::new();
        let db = root.database();
        db.execute_batch("PRAGMA locking_mode=EXCLUSIVE; BEGIN EXCLUSIVE; COMMIT;")
            .unwrap();
        let (writer, fence, ticket) = pending();
        drop(ticket);
        let bound = BoundDatabase::existing(&root.0, writer.clone()).unwrap();
        let input = Arc::new(Mutex::new(()));
        let policy = Arc::new(Mutex::new(()));
        let (entered, seen) = mpsc::sync_channel(1);
        let (retry, again) = mpsc::sync_channel(1);
        let (ack, result) = mpsc::sync_channel::<bool>(1);
        let (release, held) = mpsc::sync_channel(1);
        let scope = fence.clone();
        let i = input.clone();
        let p = policy.clone();
        let worker = thread::spawn(move || {
            let retired = {
                let _input = i.lock().unwrap();
                let _policy = p.lock().unwrap();
                scope.close_admission().unwrap();
                writer.retire().unwrap()
            };
            assert!(matches!(
                bound.try_orphan_drain(&scope, &retired),
                Err(FenceError::Busy)
            ));
            entered.send(()).unwrap();
            again.recv_timeout(Duration::from_secs(2)).unwrap();
            let guard = bound.try_orphan_drain(&scope, &retired).unwrap();
            ack.send(true).unwrap();
            held.recv_timeout(Duration::from_secs(2)).unwrap();
            drop(guard);
        });
        seen.recv_timeout(Duration::from_secs(2)).unwrap();
        // An admitted writer can still commit, so neither success nor error ack
        // is emitted. BUSY never clears the pending ticket.
        db.execute("INSERT INTO fixture VALUES(1)", []).unwrap();
        assert!(result.try_recv().is_err());
        assert!(matches!(
            fence.wait_drained(Duration::ZERO),
            Err(FenceError::Pending)
        ));
        assert!(input.try_lock().is_ok());
        assert!(policy.try_lock().is_ok());
        drop(db);
        retry.send(()).unwrap();
        assert!(result.recv_timeout(Duration::from_secs(2)).unwrap());
        let new = Connection::open(root.0.join("configuration-v1.sqlite3")).unwrap();
        new.busy_timeout(Duration::ZERO).unwrap();
        assert!(new.execute_batch("BEGIN EXCLUSIVE").is_err());
        drop(new);
        release.send(()).unwrap();
        worker.join().unwrap();
        assert!(fence.wait_drained(Duration::ZERO).is_ok());
        let reopened = Connection::open(root.0.join("configuration-v1.sqlite3")).unwrap();
        reopened.execute_batch("BEGIN EXCLUSIVE;ROLLBACK").unwrap();
    }
    #[test]
    fn missing_or_unsafe_database_is_never_created_or_treated_as_writer_exit() {
        let root = Root::new();
        let (writer, fence, _ticket) = pending();
        assert!(matches!(
            BoundDatabase::existing(&root.0, writer.clone()),
            Err(FenceError::UnsafeDatabase)
        ));
        assert!(!root.0.join("configuration-v1.sqlite3").exists());
        drop(root.database());
        let bound = BoundDatabase::existing(&root.0, writer.clone()).unwrap();
        fence.close_admission().unwrap();
        let retired = writer.retire().unwrap();
        let path = root.0.join("configuration-v1.sqlite3");
        let old = root.0.join("old.sqlite3");
        fs::rename(&path, &old).unwrap();
        fs::copy(&old, &path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(matches!(
            bound.try_orphan_drain(&fence, &retired),
            Err(FenceError::IdentityChanged)
        ));
        assert!(matches!(
            fence.wait_drained(Duration::ZERO),
            Err(FenceError::Pending)
        ));
        fs::remove_file(&path).unwrap();
        symlink(&old, &path).unwrap();
        assert!(matches!(
            bound.try_orphan_drain(&fence, &retired),
            Err(FenceError::UnsafeDatabase)
        ));
        fs::remove_file(&path).unwrap();
        fs::rename(&old, &path).unwrap();
        let hard = root.0.join("hard.sqlite3");
        fs::hard_link(&path, &hard).unwrap();
        assert!(matches!(
            bound.try_orphan_drain(&fence, &retired),
            Err(FenceError::UnsafeDatabase)
        ));
        fs::remove_file(hard).unwrap();
        let alias = root.0.join("alias");
        symlink(&root.0, &alias).unwrap();
        assert!(matches!(
            BoundDatabase::existing(&alias, writer),
            Err(FenceError::UnsafeDatabase)
        ));
    }
    #[test]
    fn recovery_requires_closed_admission_retired_matching_owner_and_valid_schema() {
        let root = Root::new();
        drop(root.database());
        let (writer, fence, _ticket) = pending();
        let bound = BoundDatabase::existing(&root.0, writer.clone()).unwrap();
        let retired = writer.retire().unwrap();
        assert!(matches!(
            bound.try_orphan_drain(&fence, &retired),
            Err(FenceError::Closed)
        ));
        fence.close_admission().unwrap();
        let other = WriterLifetime::new([1; 16]).retire().unwrap();
        assert!(matches!(
            bound.try_orphan_drain(&fence, &other),
            Err(FenceError::InvalidTicket)
        ));
        let db = Connection::open(root.0.join("configuration-v1.sqlite3")).unwrap();
        db.execute_batch("PRAGMA user_version=2").unwrap();
        drop(db);
        assert!(matches!(
            bound.try_orphan_drain(&fence, &retired),
            Err(FenceError::UnsafeDatabase)
        ));
        assert!(matches!(
            fence.wait_drained(Duration::ZERO),
            Err(FenceError::Pending)
        ));
    }
    #[test]
    fn opened_substitute_is_detected_even_when_original_startup_path_is_restored() {
        let root = Root::new();
        drop(root.database());
        let original = root.0.join("configuration-v1.sqlite3");
        let saved = root.0.join("saved.sqlite3");
        let substitute = root.0.join("substitute.sqlite3");
        fs::rename(&original, &saved).unwrap();
        fs::copy(&saved, &original).unwrap();
        let opened = Connection::open(&original).unwrap();
        opened.execute_batch("BEGIN EXCLUSIVE").unwrap();
        fs::rename(&original, &substitute).unwrap();
        fs::rename(&saved, &original).unwrap();
        assert_eq!(
            database::connection_unchanged(&opened),
            Err(FenceError::IdentityChanged)
        );
    }
}
