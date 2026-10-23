//! Policy capture is short; draining and acknowledgement ownership are explicit.
use crate::{
    cached_authorization::Scope,
    editor_commit_fence::FenceError,
    editor_pending::{ClosedEditorScope, EditAckProof, EditorCoordinator, PendingEdit},
};
use std::{io::Write, sync::Arc, time::Duration};

pub(crate) trait OrphanReaper: Send + Sync {
    fn reap(&self, edit: &Arc<PendingEdit>) -> Result<(), &'static str>;
}
impl OrphanReaper for crate::authenticated_control::editor::Bridge {
    fn reap(&self, edit: &Arc<PendingEdit>) -> Result<(), &'static str> {
        self.reap_orphan_completed(edit)
    }
}
#[derive(Clone)]
pub(crate) struct PolicyEditor {
    pub(crate) coordinator: Arc<EditorCoordinator>,
    pub(crate) reaper: Arc<dyn OrphanReaper>,
}
impl PolicyEditor {
    pub(crate) fn for_bridge(
        bridge: &Arc<crate::authenticated_control::editor::Bridge>,
    ) -> Result<Option<Self>, &'static str> {
        Ok(bridge.try_coordinator()?.map(|coordinator| Self {
            coordinator,
            reaper: bridge.clone(),
        }))
    }
}
pub(crate) struct CapturedPolicy {
    scope: Option<Arc<Scope>>,
    closed: Option<ClosedEditorScope>,
    editor: Option<PolicyEditor>,
}
/// Intentionally neither serializable nor reducible to a boolean. The actual
/// sender owns this value until success/error bytes AND flush have completed.
pub(crate) struct AckGuard {
    _scope: Option<Arc<Scope>>,
    _proof: Option<EditAckProof>,
}
impl CapturedPolicy {
    /// Caller holds existing short mutation/store locks after scope retirement.
    pub(crate) fn capture(
        scope: Option<Arc<Scope>>,
        phone: &str,
        editor: Option<PolicyEditor>,
    ) -> Result<Self, FenceError> {
        let closed = match &editor {
            Some(editor) => match &scope {
                Some(scope) => match editor.coordinator.close_retired_scope(scope.clone())? {
                    some @ Some(_) => some,
                    None => editor.coordinator.close_retired_phone(phone)?,
                },
                None => editor.coordinator.close_retired_phone(phone)?,
            },
            None => None,
        };
        Ok(Self {
            scope,
            closed,
            editor,
        })
    }
    /// Call outside ALL policy/store/input/coordinator locks and off the parent
    /// stdin dispatcher: an owner completion may still arrive on that dispatcher.
    pub(crate) fn drain(self, budget: Duration) -> Result<AckGuard, FenceError> {
        if let Some(scope) = &self.scope {
            scope
                .wait_management_delivery()
                .map_err(|_| FenceError::Unavailable)?;
        }
        let proof = match &self.closed {
            None => None,
            Some(closed) => {
                let proof = match closed.wait_for_ack(budget) {
                    Ok(proof) => proof,
                    Err(FenceError::Pending) => {
                        let editor = self.editor.as_ref().ok_or(FenceError::Unavailable)?;
                        let retired = editor
                            .coordinator
                            .retired_writer_if_any()?
                            .ok_or(FenceError::Pending)?;
                        #[cfg(unix)]
                        {
                            closed.try_orphan_proof(&retired)?
                        }
                        #[cfg(not(unix))]
                        {
                            let _ = retired;
                            return Err(FenceError::Unsupported);
                        }
                    }
                    Err(error) => return Err(error),
                };
                if let (Some(editor), Some(edit)) = (&self.editor, closed.retained_edit()) {
                    if let Some(retained) = editor.coordinator.orphan_completion_proof(edit)? {
                        // Strong typed proof spans bridge reaping; no metadata lock
                        // covers the callback. Failure withholds either kind of ACK.
                        editor
                            .reaper
                            .reap(edit)
                            .map_err(|_| FenceError::Unavailable)?;
                        drop(retained);
                    }
                }
                Some(proof)
            }
        };
        Ok(AckGuard {
            _scope: self.scope,
            _proof: proof,
        })
    }
}
pub(crate) struct GuardedLine {
    pub(crate) line: String,
    pub(crate) guard: Option<AckGuard>,
}
impl GuardedLine {
    pub(crate) fn plain(line: String) -> Self {
        Self { line, guard: None }
    }
    pub(crate) fn write(self, output: &mut impl Write) -> std::io::Result<()> {
        let Self { line, guard } = self;
        let result = writeln!(output, "{line}").and_then(|_| output.flush());
        drop(guard);
        result
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::{
        authorization_clock::Clock,
        cached_authorization::CachedAuthorization,
        editor_commit_fence::{BoundDatabase, WriterLifetime},
        editor_pending::{EditContext, EditIntent},
    };
    use rusqlite::Connection;
    use std::{
        fs,
        os::unix::fs::PermissionsExt,
        path::PathBuf,
        sync::{
            atomic::{AtomicU64, Ordering},
            mpsc, Mutex,
        },
        thread,
    };
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Fixture {
        root: PathBuf,
        coordinator: Arc<EditorCoordinator>,
        scope: Arc<Scope>,
        auth: CachedAuthorization,
        edit: Arc<PendingEdit>,
        intent: EditIntent,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::current_dir()
                .unwrap()
                .join("target/policy-tests")
                .join(format!(
                    "{}-{}",
                    std::process::id(),
                    NEXT.fetch_add(1, Ordering::Relaxed)
                ));
            fs::create_dir_all(&root).unwrap();
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
            let db = Connection::open(root.join("configuration-v1.sqlite3")).unwrap();
            db.execute_batch("PRAGMA application_id=1414021958;PRAGMA user_version=1;CREATE TABLE fixture(v INTEGER);").unwrap();
            fs::set_permissions(
                root.join("configuration-v1.sqlite3"),
                fs::Permissions::from_mode(0o600),
            )
            .unwrap();
            drop(db);
            let writer = WriterLifetime::new([1; 16]);
            let coordinator = EditorCoordinator::new(
                writer.clone(),
                BoundDatabase::existing(&root, writer).unwrap(),
            );
            let clock = Arc::new(Clock::new(100, 1100).unwrap());
            let scope = Scope::new(clock.clone());
            let auth = CachedAuthorization::new(scope.clone(), clock);
            let intent = EditIntent::new(
                "operation".into(),
                1,
                [2; 16],
                [3; 16],
                Some("label".into()),
            )
            .unwrap();
            let edit = coordinator
                .attach(auth.clone())
                .admit(
                    EditContext::new("event".into(), [4; 16], "phone".into(), 1).unwrap(),
                    intent.clone(),
                )
                .unwrap();
            coordinator.begin_dispatch(&edit).unwrap();
            Self {
                root,
                coordinator,
                scope,
                auth,
                edit,
                intent,
            }
        }
        fn writable(&self) -> bool {
            writable(&self.root)
        }
        fn capture(&self, reaper: Arc<dyn OrphanReaper>) -> CapturedPolicy {
            self.scope.retire().unwrap();
            CapturedPolicy::capture(
                Some(self.scope.clone()),
                "phone",
                Some(PolicyEditor {
                    coordinator: self.coordinator.clone(),
                    reaper,
                }),
            )
            .unwrap()
        }
    }
    fn writable(root: &std::path::Path) -> bool {
        let db = Connection::open(root.join("configuration-v1.sqlite3")).unwrap();
        db.busy_timeout(Duration::ZERO).unwrap();
        db.execute_batch("BEGIN EXCLUSIVE;ROLLBACK").is_ok()
    }
    struct Reaper(Mutex<Option<Arc<PendingEdit>>>);
    impl OrphanReaper for Reaper {
        fn reap(&self, edit: &Arc<PendingEdit>) -> Result<(), &'static str> {
            let mut retained = self.0.lock().unwrap();
            if retained.as_ref().is_some_and(|e| !Arc::ptr_eq(e, edit)) {
                return Err("wrong_edit");
            }
            *retained = None;
            Ok(())
        }
    }
    #[test]
    fn policy_wait_leaves_dispatcher_and_input_gate_free_and_does_not_retire_healthy_writer() {
        let f = Fixture::new();
        let captured = f.capture(Arc::new(Reaper(Mutex::new(None))));
        assert!(f.coordinator.retired_writer_if_any().unwrap().is_none());
        let (tx, rx) = mpsc::sync_channel(1);
        let worker =
            thread::spawn(move || tx.send(captured.drain(Duration::from_secs(2))).unwrap());
        // Parent stdin dispatcher is free to deliver this actual completion.
        assert_eq!(f.auth.guard().err(), Some("phone_authentication_rejected"));
        f.coordinator
            .actual_owner_completed(&f.edit, [1; 16], "event", &f.intent)
            .unwrap();
        assert!(rx.recv_timeout(Duration::from_secs(1)).unwrap().is_ok());
        worker.join().unwrap();
        assert!(f.coordinator.retired_writer_if_any().unwrap().is_none());
    }
    #[test]
    fn fallback_rejects_live_matching_phone_and_wrong_phone_cannot_close_it() {
        let f = Fixture::new();
        assert!(matches!(
            f.coordinator.close_retired_phone("phone"),
            Err(FenceError::Closed)
        ));
        assert!(f
            .coordinator
            .close_retired_phone("other")
            .unwrap()
            .is_none());
        assert!(f.coordinator.retired_writer_if_any().unwrap().is_none());
        f.scope.retire().unwrap();
        assert!(f
            .coordinator
            .close_retired_phone("phone")
            .unwrap()
            .is_some());
    }
    #[test]
    fn orphan_busy_withholds_guard_and_repeated_waiter_retains_exact_shared_lease() {
        let f = Fixture::new();
        let owner = Connection::open(f.root.join("configuration-v1.sqlite3")).unwrap();
        owner
            .execute_batch("PRAGMA locking_mode=EXCLUSIVE;BEGIN EXCLUSIVE;COMMIT;")
            .unwrap();
        let reaper = Arc::new(Reaper(Mutex::new(Some(f.edit.clone()))));
        let captured = f.capture(reaper.clone());
        f.coordinator.retire_writer().unwrap();
        assert!(matches!(
            captured.drain(Duration::ZERO),
            Err(FenceError::Busy)
        ));
        assert!(reaper.0.lock().unwrap().is_some());
        drop(owner);
        let first = CapturedPolicy::capture(
            None,
            "phone",
            Some(PolicyEditor {
                coordinator: f.coordinator.clone(),
                reaper: reaper.clone(),
            }),
        )
        .unwrap()
        .drain(Duration::ZERO)
        .unwrap();
        assert!(reaper.0.lock().unwrap().is_none());
        let late = CapturedPolicy::capture(
            None,
            "phone",
            Some(PolicyEditor {
                coordinator: f.coordinator.clone(),
                reaper: reaper.clone(),
            }),
        )
        .unwrap()
        .drain(Duration::ZERO)
        .unwrap();
        assert!(!f.writable());
        drop(first);
        assert!(!f.writable());
        // The fixture itself retains the edit until explicitly released below.
        let root = f.root.clone();
        let coordinator = f.coordinator.clone();
        drop(f);
        assert!(!writable(&root));
        drop(late);
        assert!(writable(&root));
        drop(coordinator);
        fs::remove_dir_all(root).unwrap();
    }
    struct ObservedWriter {
        root: PathBuf,
        entered: mpsc::SyncSender<()>,
        release: mpsc::Receiver<()>,
        fail: bool,
    }
    impl Write for ObservedWriter {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            assert!(!writable(&self.root));
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            assert!(!writable(&self.root));
            self.entered.send(()).unwrap();
            self.release.recv().unwrap();
            assert!(!writable(&self.root));
            if self.fail {
                Err(std::io::Error::other("blocked flush failed"))
            } else {
                Ok(())
            }
        }
    }
    #[test]
    fn actual_output_write_and_flush_own_success_and_error_guards() {
        for (payload, fail) in [("success", false), ("error", false), ("error", true)] {
            let f = Fixture::new();
            let reaper = Arc::new(Reaper(Mutex::new(Some(f.edit.clone()))));
            let captured = f.capture(reaper.clone());
            f.coordinator.retire_writer().unwrap();
            let guard = captured.drain(Duration::ZERO).unwrap();
            let root = f.root.clone();
            let edit = f.edit.clone();
            let coordinator = f.coordinator.clone();
            let (entered, observed) = mpsc::sync_channel(1);
            let (release, waiting) = mpsc::sync_channel(1);
            let line = GuardedLine {
                line: payload.into(),
                guard: Some(guard),
            };
            let writer_root = root.clone();
            let worker = thread::spawn(move || {
                line.write(&mut ObservedWriter {
                    root: writer_root,
                    entered,
                    release: waiting,
                    fail,
                })
            });
            observed.recv_timeout(Duration::from_secs(1)).unwrap();
            // Remove all ordinary edit owners while the real flush is blocked.
            drop(edit);
            drop(f.edit.clone());
            assert!(!writable(&root));
            release.send(()).unwrap();
            assert_eq!(worker.join().unwrap().is_err(), fail);
            // Fixture still owns its edit; drop it without deleting DB first.
            drop(f);
            assert!(writable(&root));
            drop(coordinator);
            drop(reaper);
            fs::remove_dir_all(root).unwrap();
        }
    }
}
