//! Unconnected strong edit ownership. No TLS role, policy hook or writer is enabled.
use crate::{
    cached_authorization::{CachedAuthorization, Scope},
    editor_commit_fence::{
        BoundDatabase, CommitFence, DrainedScope, FenceError, RetiredWriter, Ticket, WriterLifetime,
    },
};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

/// Already authenticated native context. Never populated from phone header claims.
#[derive(Clone)]
pub(crate) struct EditContext {
    event_id: String,
    authority: [u8; 16],
    phone_id: String,
    epoch: u64,
}
impl EditContext {
    pub(crate) fn new(
        event_id: String,
        authority: [u8; 16],
        phone_id: String,
        epoch: u64,
    ) -> Result<Self, FenceError> {
        if !crate::runtime::identity(&event_id)
            || !crate::runtime::identity(&phone_id)
            || epoch == 0
        {
            return Err(FenceError::InvalidTicket);
        }
        Ok(Self {
            event_id,
            authority,
            phone_id,
            epoch,
        })
    }
}
#[derive(Clone, PartialEq, Eq)]
pub(crate) struct EditIntent {
    operation: String,
    expected_revision: u64,
    profile: [u8; 16],
    control: [u8; 16],
    label: Option<String>,
}
impl EditIntent {
    pub(crate) fn new(
        operation: String,
        expected_revision: u64,
        profile: [u8; 16],
        control: [u8; 16],
        label: Option<String>,
    ) -> Result<Self, FenceError> {
        if !crate::runtime::identity(&operation) || label.as_ref().is_some_and(|v| v.len() > 128) {
            return Err(FenceError::InvalidTicket);
        }
        Ok(Self {
            operation,
            expected_revision,
            profile,
            control,
            label,
        })
    }
}
/// No Drop completion. The native coordinator owns this even if TLS disappears.
pub(crate) struct PendingEdit {
    authorization: CachedAuthorization,
    fence: Arc<CommitFence>,
    ticket: Ticket,
    writer: Arc<WriterLifetime>,
    context: EditContext,
    intent: EditIntent,
    proof: Mutex<Option<DrainedScope>>,
}
struct Registry {
    retired: bool,
    pending: Option<Arc<PendingEdit>>,
    completed: Weak<PendingEdit>,
}
pub(crate) struct EditorCoordinator {
    writer: Arc<WriterLifetime>,
    database: BoundDatabase,
    state: Mutex<Registry>,
}
pub(crate) struct EditorAttachment {
    authorization: CachedAuthorization,
    fence: Arc<CommitFence>,
    coordinator: Arc<EditorCoordinator>,
}
/// Capture/close under short policy locks; only this closed handle can wait.
pub(crate) struct ClosedEditorScope {
    authorization: CachedAuthorization,
    fence: Arc<CommitFence>,
    coordinator: Arc<EditorCoordinator>,
    retained: Option<Arc<PendingEdit>>,
}
/// Must remain owned through the entire success OR error acknowledgement send.
/// It contains no callback and cannot send or authorize a phone response itself.
#[derive(Clone)]
pub(crate) struct EditAckProof {
    _authorization: CachedAuthorization,
    _drained: DrainedScope,
    _retained: Option<Arc<PendingEdit>>,
}
impl EditorCoordinator {
    pub(crate) fn new(writer: Arc<WriterLifetime>, database: BoundDatabase) -> Arc<Self> {
        Arc::new(Self {
            writer,
            database,
            state: Mutex::new(Registry {
                retired: false,
                pending: None,
                completed: Weak::new(),
            }),
        })
    }
    /// The caller must register this attachment in its epoch policy owner before
    /// enabling edits. Current policy paths do not call this prerequisite.
    pub(crate) fn attach(self: &Arc<Self>, authorization: CachedAuthorization) -> EditorAttachment {
        EditorAttachment {
            authorization,
            fence: CommitFence::new(self.writer.clone()),
            coordinator: self.clone(),
        }
    }
    pub(crate) fn begin_dispatch(&self, edit: &Arc<PendingEdit>) -> Result<(), FenceError> {
        let _scope = edit.authorization.guard().map_err(|_| FenceError::Closed)?;
        let state = self.state.lock().map_err(|_| FenceError::Unavailable)?;
        if state.retired {
            return Err(FenceError::Closed);
        }
        if !state
            .pending
            .as_ref()
            .is_some_and(|current| Arc::ptr_eq(current, edit))
            || !Arc::ptr_eq(&edit.writer, &self.writer)
        {
            return Err(FenceError::InvalidTicket);
        }
        edit.fence.dispatch(&edit.ticket, self.writer.identity())
    }
    /// Caller has strictly correlated an ACTUAL synchronous owner response,
    /// not timeout/EOF/not-dispatched/kill. This never interprets receipt bytes.
    pub(crate) fn actual_owner_completed(
        &self,
        edit: &Arc<PendingEdit>,
        owner: [u8; 16],
        event: &str,
        intent: &EditIntent,
    ) -> Result<(), FenceError> {
        let mut state = self.state.lock().map_err(|_| FenceError::Unavailable)?;
        if !state
            .pending
            .as_ref()
            .is_some_and(|current| Arc::ptr_eq(current, edit))
            || owner != edit.writer.identity()
            || event != edit.context.event_id
            || intent != &edit.intent
        {
            return Err(FenceError::InvalidTicket);
        }
        edit.fence.definitive_completion(&edit.ticket, owner)?;
        state.completed = Arc::downgrade(edit);
        state.pending = None;
        Ok(())
    }
    /// Policy captures this under short locks AFTER actual scope retirement.
    /// The closed handle alone exposes waiting; TLS-local ownership is irrelevant.
    pub(crate) fn close_retired_scope(
        self: &Arc<Self>,
        scope: Arc<Scope>,
    ) -> Result<Option<ClosedEditorScope>, FenceError> {
        if scope.is_live() {
            return Err(FenceError::Closed);
        }
        let mut state = self.state.lock().map_err(|_| FenceError::Unavailable)?;
        let retained = state
            .pending
            .as_ref()
            .filter(|edit| edit.authorization.retains_scope(&scope))
            .cloned()
            .or_else(|| {
                state
                    .completed
                    .upgrade()
                    .filter(|edit| edit.authorization.retains_scope(&scope))
            });
        let Some(edit) = retained else {
            return Ok(None);
        };
        edit.fence.close_admission()?;
        if !edit.fence.has_pending()?
            && state
                .pending
                .as_ref()
                .is_some_and(|current| Arc::ptr_eq(current, &edit))
        {
            state.completed = Arc::downgrade(&edit);
            state.pending = None;
        }
        Ok(Some(ClosedEditorScope {
            authorization: edit.authorization.clone(),
            fence: edit.fence.clone(),
            coordinator: self.clone(),
            retained: Some(edit),
        }))
    }
    /// Snapshot first, then inspect the input gate outside the coordinator lock.
    /// Matching live/poisoned authorization cannot become a no-edit proof.
    pub(crate) fn close_retired_phone(
        self: &Arc<Self>,
        phone: &str,
    ) -> Result<Option<ClosedEditorScope>, FenceError> {
        let edit = {
            let state = self.state.lock().map_err(|_| FenceError::Unavailable)?;
            state
                .pending
                .as_ref()
                .filter(|e| e.context.phone_id == phone)
                .cloned()
                .or_else(|| {
                    state
                        .completed
                        .upgrade()
                        .filter(|e| e.context.phone_id == phone)
                })
        };
        let Some(edit) = edit else { return Ok(None) };
        match edit.authorization.guard() {
            Err("phone_authentication_rejected") => {}
            _ => return Err(FenceError::Closed),
        }
        edit.fence.close_admission()?;
        Ok(Some(ClosedEditorScope {
            authorization: edit.authorization.clone(),
            fence: edit.fence.clone(),
            coordinator: self.clone(),
            retained: Some(edit),
        }))
    }
    pub(crate) fn retired_writer_if_any(&self) -> Result<Option<RetiredWriter>, FenceError> {
        self.writer.retired_if_any()
    }
    /// Only a stored orphan lease on this exact writer/entry is a reaping proof.
    pub(crate) fn orphan_completion_proof(
        &self,
        edit: &Arc<PendingEdit>,
    ) -> Result<Option<EditAckProof>, FenceError> {
        if !Arc::ptr_eq(&edit.writer, &self.writer) {
            return Err(FenceError::InvalidTicket);
        }
        let proof = edit
            .proof
            .lock()
            .map_err(|_| FenceError::Unavailable)?
            .clone();
        Ok(proof.map(|proof| EditAckProof {
            _authorization: edit.authorization.clone(),
            _drained: proof,
            _retained: Some(edit.clone()),
        }))
    }
    /// Includes parent `not-dispatched`: after native publication this is still
    /// uncertain, not a definitive owner response. Never clears the registry.
    pub(crate) fn uncertain_dispatch(
        &self,
        edit: &Arc<PendingEdit>,
    ) -> Result<RetiredWriter, FenceError> {
        let mut state = self.state.lock().map_err(|_| FenceError::Unavailable)?;
        if !state
            .pending
            .as_ref()
            .is_some_and(|current| Arc::ptr_eq(current, edit))
        {
            return Err(FenceError::InvalidTicket);
        }
        state.retired = true;
        let retired = self.writer.retire()?;
        edit.fence.close_admission()?;
        Ok(retired)
    }
    /// Close future dispatch BEFORE any parent-loss/orphan probe. No IO or wait.
    pub(crate) fn retire_writer(&self) -> Result<RetiredWriter, FenceError> {
        let mut state = self.state.lock().map_err(|_| FenceError::Unavailable)?;
        state.retired = true;
        let retired = self.writer.retire()?;
        if let Some(edit) = &state.pending {
            edit.fence.close_admission()?;
        }
        Ok(retired)
    }
}
impl EditorAttachment {
    pub(crate) fn admit(
        &self,
        context: EditContext,
        intent: EditIntent,
    ) -> Result<Arc<PendingEdit>, FenceError> {
        let _scope = self.authorization.guard().map_err(|_| FenceError::Closed)?;
        let mut state = self
            .coordinator
            .state
            .lock()
            .map_err(|_| FenceError::Unavailable)?;
        if state.retired {
            return Err(FenceError::Closed);
        }
        if state.pending.is_some() {
            return Err(FenceError::Busy);
        }
        let ticket = self.fence.admit()?;
        let edit = Arc::new(PendingEdit {
            authorization: self.authorization.clone(),
            fence: self.fence.clone(),
            ticket,
            writer: self.coordinator.writer.clone(),
            context,
            intent,
            proof: Mutex::new(None),
        });
        state.pending = Some(edit.clone());
        Ok(edit)
    }
    pub(crate) fn close(self) -> Result<ClosedEditorScope, FenceError> {
        let mut state = self
            .coordinator
            .state
            .lock()
            .map_err(|_| FenceError::Unavailable)?;
        self.fence.close_admission()?;
        let retained = state
            .pending
            .as_ref()
            .filter(|edit| Arc::ptr_eq(&edit.fence, &self.fence))
            .cloned();
        // A reservation that never dispatched is now permanently cancelled.
        if retained.is_some() && !self.fence.has_pending()? {
            state.pending = None;
        }
        drop(state);
        Ok(ClosedEditorScope {
            authorization: self.authorization,
            fence: self.fence,
            coordinator: self.coordinator,
            retained,
        })
    }
}
impl ClosedEditorScope {
    pub(crate) fn retained_edit(&self) -> Option<&Arc<PendingEdit>> {
        self.retained.as_ref()
    }
    pub(crate) fn wait_for_ack(&self, budget: Duration) -> Result<EditAckProof, FenceError> {
        let proof = self.fence.wait_drained(budget)?;
        Ok(EditAckProof {
            _authorization: self.authorization.clone(),
            _drained: proof,
            _retained: self.retained.clone(),
        })
    }
    #[cfg(unix)]
    pub(crate) fn try_orphan_proof(
        &self,
        retired: &RetiredWriter,
    ) -> Result<EditAckProof, FenceError> {
        let edit = self.retained.as_ref().ok_or(FenceError::InvalidTicket)?;
        let drain = self
            .coordinator
            .database
            .try_orphan_drain(&self.fence, retired)?;
        let proof = drain.proof();
        // Publish a strong handoff owner before the local probe guard can drop.
        *edit.proof.lock().map_err(|_| FenceError::Unavailable)? = Some(proof.clone());
        let mut state = self
            .coordinator
            .state
            .lock()
            .map_err(|_| FenceError::Unavailable)?;
        if state
            .pending
            .as_ref()
            .is_some_and(|current| Arc::ptr_eq(current, edit))
        {
            state.completed = Arc::downgrade(edit);
            state.pending = None;
        }
        Ok(EditAckProof {
            _authorization: self.authorization.clone(),
            _drained: proof,
            _retained: Some(edit.clone()),
        })
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::{authorization_clock::Clock, cached_authorization::Scope};
    use rusqlite::Connection;
    use std::{
        fs,
        os::unix::fs::PermissionsExt,
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
            let p = std::env::temp_dir().canonicalize().unwrap().join(format!(
                "thumble-editor-pending-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&p).unwrap();
            fs::set_permissions(&p, fs::Permissions::from_mode(0o700)).unwrap();
            Self(p)
        }
        fn db(&self) -> Connection {
            let db = Connection::open(self.0.join("configuration-v1.sqlite3")).unwrap();
            db.execute_batch("PRAGMA application_id=1414021958;PRAGMA user_version=1;CREATE TABLE IF NOT EXISTS fixture(v INTEGER);").unwrap();
            fs::set_permissions(
                self.0.join("configuration-v1.sqlite3"),
                fs::Permissions::from_mode(0o600),
            )
            .unwrap();
            db
        }
        fn coordinator(&self) -> Arc<EditorCoordinator> {
            let writer = WriterLifetime::new([1; 16]);
            let bound = BoundDatabase::existing(&self.0, writer.clone()).unwrap();
            EditorCoordinator::new(writer, bound)
        }
        fn can_write(&self) -> bool {
            let db = Connection::open(self.0.join("configuration-v1.sqlite3")).unwrap();
            db.busy_timeout(Duration::ZERO).unwrap();
            db.execute_batch("BEGIN EXCLUSIVE;ROLLBACK").is_ok()
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn auth() -> (Arc<Scope>, CachedAuthorization) {
        let clock = Arc::new(Clock::new(100, 1100).unwrap());
        let scope = Scope::new(clock.clone());
        (scope.clone(), CachedAuthorization::new(scope, clock))
    }
    fn context() -> EditContext {
        EditContext::new("event-one".into(), [7; 16], "phone-a".into(), 1).unwrap()
    }
    fn intent() -> EditIntent {
        EditIntent::new(
            "operation-one".into(),
            1,
            [2; 16],
            [3; 16],
            Some("Jump".into()),
        )
        .unwrap()
    }
    #[test]
    fn registry_retains_actual_scope_after_tls_and_weak_store_disappear() {
        let root = Root::new();
        drop(root.db());
        let coordinator = root.coordinator();
        let (scope, authorization) = auth();
        let weak = Arc::downgrade(&scope);
        assert!(matches!(
            coordinator.close_retired_scope(scope.clone()),
            Err(FenceError::Closed)
        ));
        let attachment = coordinator.attach(authorization);
        let edit = attachment.admit(context(), intent()).unwrap();
        coordinator.begin_dispatch(&edit).unwrap();
        drop(scope);
        drop(attachment);
        drop(edit);
        assert!(weak.upgrade().is_some());
        let retired = coordinator.retire_writer().unwrap();
        let retained = coordinator.state.lock().unwrap().pending.clone().unwrap();
        assert_eq!(
            coordinator.begin_dispatch(&retained),
            Err(FenceError::Closed)
        );
        // A dropped TLS handle and parent EOF never finish this ticket.
        assert!(matches!(
            retained.fence.wait_drained(Duration::ZERO),
            Err(FenceError::Pending)
        ));
        let actual_scope = weak.upgrade().unwrap();
        actual_scope.retire().unwrap();
        let closed = coordinator
            .close_retired_scope(actual_scope)
            .unwrap()
            .unwrap();
        assert!(matches!(
            closed.wait_for_ack(Duration::ZERO),
            Err(FenceError::Pending)
        ));
        drop(closed);
        drop(retired);
        drop(retained);
        drop(coordinator);
        assert!(weak.upgrade().is_none());
    }
    #[test]
    fn queued_or_partial_dispatch_cannot_retarget_and_wrong_scope_close_cannot_erase_it() {
        let root = Root::new();
        drop(root.db());
        let coordinator = root.coordinator();
        let (_, authorization) = auth();
        let first = coordinator.attach(authorization.clone());
        let queued = first.admit(context(), intent()).unwrap();
        let unrelated = coordinator.attach(authorization.clone()).close().unwrap();
        assert!(unrelated.wait_for_ack(Duration::ZERO).is_ok());
        assert!(coordinator.state.lock().unwrap().pending.is_some());
        coordinator.begin_dispatch(&queued).unwrap();
        let closed = first.close().unwrap();
        let retired = coordinator.uncertain_dispatch(&queued).unwrap();
        assert!(matches!(
            closed.wait_for_ack(Duration::ZERO),
            Err(FenceError::Pending)
        ));
        assert_eq!(coordinator.begin_dispatch(&queued), Err(FenceError::Closed));
        assert!(matches!(
            coordinator
                .attach(authorization.clone())
                .admit(context(), intent()),
            Err(FenceError::Closed)
        ));
        // A replacement owner, even with copied scalar identity, cannot use old Arc ticket.
        let replacement = root.coordinator();
        assert_eq!(
            replacement.begin_dispatch(&queued),
            Err(FenceError::InvalidTicket)
        );
        drop(closed.try_orphan_proof(&retired).unwrap());
    }
    #[test]
    fn orphan_proof_is_published_to_all_waiters_and_last_reference_releases_db() {
        let root = Root::new();
        let owner = root.db();
        owner
            .execute_batch("PRAGMA locking_mode=EXCLUSIVE;BEGIN EXCLUSIVE;COMMIT;")
            .unwrap();
        let coordinator = root.coordinator();
        let (scope, authorization) = auth();
        let attachment = coordinator.attach(authorization.clone());
        let edit = attachment.admit(context(), intent()).unwrap();
        coordinator.begin_dispatch(&edit).unwrap();
        let closed = Arc::new(attachment.close().unwrap());
        let retired = coordinator.retire_writer().unwrap();
        assert!(matches!(
            closed.try_orphan_proof(&retired),
            Err(FenceError::Busy)
        ));
        assert!(matches!(
            closed.wait_for_ack(Duration::ZERO),
            Err(FenceError::Pending)
        ));
        // Existing input authorization gate remains available while commit waits.
        drop(authorization.guard().unwrap());
        let (tx, rx) = mpsc::sync_channel(2);
        let mut workers = Vec::new();
        for _ in 0..2 {
            let c = closed.clone();
            let t = tx.clone();
            workers.push(thread::spawn(move || {
                t.send(c.wait_for_ack(Duration::from_secs(2)).unwrap())
                    .unwrap()
            }));
        }
        drop(owner);
        let first = closed.try_orphan_proof(&retired).unwrap();
        let success_ack = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let error_ack = rx.recv_timeout(Duration::from_secs(2)).unwrap();
        for w in workers {
            w.join().unwrap();
        }
        assert!(!root.can_write());
        drop(first);
        drop(closed);
        drop(edit);
        scope.retire().unwrap();
        let late_waiter = coordinator
            .close_retired_scope(scope.clone())
            .unwrap()
            .unwrap();
        let late_error_ack = late_waiter.wait_for_ack(Duration::ZERO).unwrap();
        drop(late_waiter);
        drop(scope);
        drop(authorization);
        assert!(!root.can_write());
        drop(success_ack);
        assert!(!root.can_write());
        drop(error_ack);
        assert!(!root.can_write());
        drop(late_error_ack);
        assert!(root.can_write());
        // Coordinator remains alive: there is no self-retaining lease cycle.
        drop(coordinator);
    }
    #[test]
    fn only_matching_actual_completion_releases_and_reservations_close_without_dispatch() {
        let root = Root::new();
        drop(root.db());
        let coordinator = root.coordinator();
        let (_, authorization) = auth();
        let attachment = coordinator.attach(authorization.clone());
        let edit = attachment.admit(context(), intent()).unwrap();
        coordinator.begin_dispatch(&edit).unwrap();
        assert_eq!(
            coordinator.actual_owner_completed(&edit, [2; 16], "event-one", &intent()),
            Err(FenceError::InvalidTicket)
        );
        assert_eq!(
            coordinator.actual_owner_completed(&edit, [1; 16], "other", &intent()),
            Err(FenceError::InvalidTicket)
        );
        let changed_intent = EditIntent::new(
            "operation-one".into(),
            1,
            [2; 16],
            [3; 16],
            Some("Other".into()),
        )
        .unwrap();
        assert_eq!(
            coordinator.actual_owner_completed(&edit, [1; 16], "event-one", &changed_intent),
            Err(FenceError::InvalidTicket)
        );
        let closed = attachment.close().unwrap();
        assert!(matches!(
            closed.wait_for_ack(Duration::ZERO),
            Err(FenceError::Pending)
        ));
        coordinator
            .actual_owner_completed(&edit, [1; 16], "event-one", &intent())
            .unwrap();
        assert!(closed.wait_for_ack(Duration::ZERO).is_ok());
        let next = coordinator.attach(authorization);
        let queued = next.admit(context(), intent()).unwrap();
        let done = next.close().unwrap();
        assert!(done.wait_for_ack(Duration::ZERO).is_ok());
        assert_eq!(
            coordinator.begin_dispatch(&queued),
            Err(FenceError::InvalidTicket)
        );
    }
}
