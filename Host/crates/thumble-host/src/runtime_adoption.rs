use super::*;
use crate::profile_adoption::{NativeArtifactBridge, Upload};
use thumble_protocol::{
    AdoptionError, AdoptionMetadata, AdoptionReceipt, AdoptionResult, AdoptionStatus,
    ADOPTION_LEDGER_ENTRIES, ADOPTION_LEDGER_LIFETIME,
};

pub(super) struct AdoptionService {
    bridge: NativeArtifactBridge,
    pending: Mutex<HashMap<ConnectionId, Pending>>,
}
enum Pending {
    Upload(Upload),
    Committing(AdoptionMetadata),
}
impl Pending {
    fn metadata(&self) -> &AdoptionMetadata {
        match self {
            Self::Upload(u) => &u.metadata,
            Self::Committing(m) => m,
        }
    }
}
impl AdoptionService {
    pub(super) fn open() -> Option<Self> {
        Some(Self {
            bridge: NativeArtifactBridge::discover().ok()?,
            pending: Mutex::new(HashMap::new()),
        })
    }
}
pub(super) fn is_adoption(message: &ControllerMessage) -> bool {
    matches!(
        message.message_type,
        ControllerMessageType::ProfileArtifactAdoptionBegin
            | ControllerMessageType::ProfileArtifactAdoptionChunk
            | ControllerMessageType::ProfileArtifactAdoptionCommit
            | ControllerMessageType::ProfileArtifactAdoptionCancel
            | ControllerMessageType::ProfileArtifactAdoptionResult
    )
}
fn valid_envelope(message: &ControllerMessage) -> bool {
    let allowed = match message.message_type {
        ControllerMessageType::ProfileArtifactAdoptionBegin => {
            vec!["profileArtifactAdoptionMetadata"]
        }
        ControllerMessageType::ProfileArtifactAdoptionChunk => vec![
            "profileArtifactAdoptionOperationID",
            "profileArtifactAdoptionChunkIndex",
            "profileArtifactAdoptionChunkData",
        ],
        ControllerMessageType::ProfileArtifactAdoptionCommit
        | ControllerMessageType::ProfileArtifactAdoptionCancel => {
            vec!["profileArtifactAdoptionOperationID"]
        }
        _ => return false,
    };
    let Ok(Value::Object(fields)) = serde_json::to_value(message) else {
        return false;
    };
    allowed.iter().all(|key| fields.contains_key(*key))
        && fields
            .keys()
            .all(|key| key == "type" || key == "timestamp" || allowed.contains(&key.as_str()))
}
fn receipt(
    state: &PersistentState,
    metadata: &AdoptionMetadata,
    now: i64,
) -> Option<AdoptionResult> {
    receipt_in(
        &state.profile_artifact_adoptions,
        &state.server_id,
        metadata,
        now,
    )
}
fn receipt_in(
    entries: &[AdoptionReceipt],
    server: &str,
    metadata: &AdoptionMetadata,
    now: i64,
) -> Option<AdoptionResult> {
    let saved = entries.iter().find(|entry| {
        entry.metadata.operation_id == metadata.operation_id
            && now
                < entry
                    .completed_at_milliseconds
                    .saturating_add(ADOPTION_LEDGER_LIFETIME)
    })?;
    Some(if saved.metadata == *metadata {
        let mut result = saved.result.clone();
        result.status = AdoptionStatus::Replayed;
        result
    } else {
        AdoptionResult::new(
            metadata,
            server,
            AdoptionStatus::Failed,
            Some(AdoptionError::OperationConflict),
            vec![],
        )
    })
}
impl SharedRuntime {
    pub(super) fn local_adoption_status(
        &self,
        operation_id: Uuid,
        cancel: bool,
    ) -> Option<AdoptionResult> {
        let state = self
            .inner
            .lock()
            .expect("runtime mutex poisoned")
            .core
            .persistent_state()
            .clone();
        if let Some(entry) = state
            .profile_artifact_adoptions
            .iter()
            .find(|r| r.metadata.operation_id == operation_id)
        {
            if let Some(result) = receipt(&state, &entry.metadata, unix_millis()) {
                return Some(result);
            }
        }
        let service = self.adoption_service.as_ref()?;
        let mut pending = service.pending.lock().expect("adoption mutex poisoned");
        let (owner, metadata) = pending
            .iter()
            .find(|(_, p)| p.metadata().operation_id == operation_id)
            .map(|(id, p)| (*id, p.metadata().clone()))?;
        let result = AdoptionResult::new(
            &metadata,
            &state.server_id,
            if cancel {
                AdoptionStatus::Failed
            } else {
                AdoptionStatus::Accepted
            },
            cancel.then_some(AdoptionError::Disconnected),
            vec![],
        );
        if cancel {
            pending.remove(&owner);
        }
        drop(pending);
        if cancel {
            self.adoption_send(owner, result.clone());
        }
        Some(result)
    }
    pub(super) fn adoption_available(&self) -> bool {
        self.adoption_service.is_some() && self.configuration_write_enabled
    }
    fn adoption_send(&self, id: ConnectionId, result: AdoptionResult) {
        let mut inner = self.inner.lock().expect("runtime mutex poisoned");
        if !inner.core.is_authenticated(id) || !inner.connections.contains_key(&id) {
            return;
        }
        let mut message = ControllerMessage::new(
            ControllerMessageType::ProfileArtifactAdoptionResult,
            unix_millis(),
        );
        message.profile_artifact_adoption_result = Some(result);
        let _ = self.execute_effects(
            &mut inner,
            vec![Effect::SendMessage {
                connection_id: id,
                message: Box::new(message),
            }],
        );
    }
    pub(super) fn retire_adoption(&self, id: ConnectionId) {
        if let Some(service) = &self.adoption_service {
            service
                .pending
                .lock()
                .expect("adoption mutex poisoned")
                .remove(&id);
        }
    }
    pub(super) fn expire_adoptions(&self) {
        let Some(service) = &self.adoption_service else {
            return;
        };
        let mut pending = service.pending.lock().expect("adoption mutex poisoned");
        let expired = pending
            .iter()
            .filter_map(|(id, p)| match p {
                Pending::Upload(u) if u.expired(unix_millis()) => Some((*id, u.metadata.clone())),
                _ => None,
            })
            .collect::<Vec<_>>();
        for (id, _) in &expired {
            pending.remove(id);
        }
        drop(pending);
        for (id, metadata) in expired {
            self.adoption_send(
                id,
                AdoptionResult::new(
                    &metadata,
                    &metadata.intended_server_id,
                    AdoptionStatus::Failed,
                    Some(AdoptionError::UploadExpired),
                    vec![],
                ),
            );
        }
    }
    pub(super) fn handle_adoption_message(&self, id: ConnectionId, message: ControllerMessage) {
        let (server, receipts) = {
            let mut inner = self.inner.lock().expect("runtime mutex poisoned");
            self.guard_input_liveness(&mut inner);
            if !inner.core.is_authenticated(id) || !inner.connections.contains_key(&id) {
                return;
            }
            let state = inner.core.persistent_state();
            (
                state.server_id.clone(),
                state.profile_artifact_adoptions.clone(),
            )
        };
        let Some(service) = &self.adoption_service else {
            return;
        };
        let mut pending = service.pending.lock().expect("adoption mutex poisoned");
        let metadata = message
            .profile_artifact_adoption_metadata
            .clone()
            .or_else(|| {
                pending.get(&id).map(|p| p.metadata().clone()).or_else(|| {
                    receipts
                        .iter()
                        .find(|r| {
                            Some(r.metadata.operation_id)
                                == message.profile_artifact_adoption_operation_id
                        })
                        .map(|r| r.metadata.clone())
                })
            });
        let Some(metadata) = metadata else { return };
        let failure = |code| {
            AdoptionResult::new(
                &metadata,
                &server,
                AdoptionStatus::Failed,
                Some(code),
                vec![],
            )
        };
        let now = unix_millis();
        let result = (|| -> Result<Option<AdoptionResult>, AdoptionError> {
            if !self.adoption_available() {
                return Err(AdoptionError::Unsupported);
            }
            if !valid_envelope(&message) {
                return Err(AdoptionError::InvalidEnvelope);
            }
            metadata.validate(&server)?;
            if let Some(result) = receipt_in(&receipts, &server, &metadata, now) {
                return Ok((message.message_type
                    != ControllerMessageType::ProfileArtifactAdoptionChunk)
                    .then_some(result));
            }
            if message.message_type == ControllerMessageType::ProfileArtifactAdoptionBegin {
                if let Some(Pending::Upload(upload)) = pending.get(&id) {
                    if upload.expired(now) {
                        pending.remove(&id);
                    }
                }
                if let Some(old) = pending.get(&id) {
                    if old.metadata().operation_id != metadata.operation_id {
                        return Err(AdoptionError::UploadBusy);
                    }
                    if old.metadata() != &metadata {
                        return Err(AdoptionError::OperationConflict);
                    }
                    if matches!(old, Pending::Committing(_)) {
                        return Ok(None);
                    }
                }
                pending.clear(); // A replacement paired controller cannot retain another upload.
                pending.insert(id, Pending::Upload(Upload::begin(metadata.clone(), now)));
                return Ok(Some(AdoptionResult::new(
                    &metadata,
                    &server,
                    AdoptionStatus::Accepted,
                    None,
                    vec![],
                )));
            }
            if message.profile_artifact_adoption_operation_id != Some(metadata.operation_id) {
                return Err(AdoptionError::OperationConflict);
            }
            if message.message_type == ControllerMessageType::ProfileArtifactAdoptionCancel {
                pending.remove(&id);
                return Err(AdoptionError::Disconnected);
            }
            match message.message_type {
                ControllerMessageType::ProfileArtifactAdoptionChunk => {
                    let Some(Pending::Upload(upload)) = pending.get_mut(&id) else {
                        return Err(AdoptionError::OperationMissing);
                    };
                    upload.append(
                        message
                            .profile_artifact_adoption_chunk_index
                            .ok_or(AdoptionError::InvalidEnvelope)?,
                        message
                            .profile_artifact_adoption_chunk_data
                            .as_deref()
                            .ok_or(AdoptionError::InvalidEnvelope)?,
                        now,
                    )?;
                    Ok(None)
                }
                ControllerMessageType::ProfileArtifactAdoptionCommit => {
                    if let Some(Pending::Upload(upload)) = pending.get(&id) {
                        upload.ready(now)?;
                    }
                    let Some(value) = pending.remove(&id) else {
                        return Err(AdoptionError::OperationMissing);
                    };
                    let Pending::Upload(upload) = value else {
                        pending.insert(id, value);
                        return Ok(None);
                    };
                    let (metadata, bytes) = upload.complete(now)?;
                    pending.insert(id, Pending::Committing(metadata.clone()));
                    let jobs = self.skin_jobs.lock().expect("profile jobs poisoned");
                    if jobs
                        .as_ref()
                        .ok_or(AdoptionError::Unsupported)?
                        .try_send((
                            id,
                            skin_runtime::ProfileJob::Adoption(Box::new((metadata, bytes))),
                        ))
                        .is_err()
                    {
                        pending.remove(&id);
                        return Err(AdoptionError::UploadBusy);
                    }
                    Ok(None)
                }
                _ => Err(AdoptionError::InvalidEnvelope),
            }
        })();
        let result = match result {
            Ok(value) => value,
            Err(code) => {
                if matches!(
                    code,
                    AdoptionError::UploadExpired | AdoptionError::InvalidHash
                ) {
                    pending.remove(&id);
                }
                Some(failure(code))
            }
        };
        drop(pending);
        if let Some(result) = result {
            if result.status == AdoptionStatus::Replayed {
                self.adoption_snapshot(id);
            }
            self.adoption_send(id, result);
        }
    }
    fn adoption_snapshot(&self, id: ConnectionId) {
        let mut inner = self.inner.lock().expect("runtime mutex poisoned");
        if inner.core.is_authenticated(id) {
            let _ = self.handle_input_locked(
                &mut inner,
                id,
                ControllerMessage::new(ControllerMessageType::GamepadProfiles, unix_millis()),
                false,
            );
        }
    }
    pub(super) fn run_adoption_job(
        &self,
        id: ConnectionId,
        metadata: AdoptionMetadata,
        bytes: Vec<u8>,
    ) {
        let result = self.adopt_artifact(Some(id), &metadata, &bytes);
        if let Some(service) = &self.adoption_service {
            let mut pending = service.pending.lock().expect("adoption mutex poisoned");
            if matches!(pending.get(&id),Some(Pending::Committing(m)) if m == &metadata) {
                pending.remove(&id);
            }
        }
        self.adoption_send(id, result);
    }
    pub(super) fn adopt_artifact(
        &self,
        owner: Option<ConnectionId>,
        metadata: &AdoptionMetadata,
        bytes: &[u8],
    ) -> AdoptionResult {
        let state = self
            .inner
            .lock()
            .expect("runtime mutex poisoned")
            .core
            .persistent_state()
            .clone();
        let result = (|| -> Result<AdoptionResult, AdoptionError> {
            if let Some(id) = owner {
                let inner = self.inner.lock().expect("runtime mutex poisoned");
                if !inner.core.is_authenticated(id) || !inner.connections.contains_key(&id) {
                    return Err(AdoptionError::Disconnected);
                }
            }
            metadata.validate(&state.server_id)?;
            if !self.adoption_available() {
                return Err(AdoptionError::Unsupported);
            }
            if let Some(result) = receipt(&state, metadata, unix_millis()) {
                return Ok(result);
            }
            let service = self
                .adoption_service
                .as_ref()
                .ok_or(AdoptionError::Unsupported)?;
            let native_profiles = service.bridge.validate(bytes, metadata)?;
            let now = unix_millis();
            let (mut candidate, ids) =
                cli_profile::plan_profile_adoption(&state, metadata, bytes, &native_profiles, now)
                    .map_err(|_| AdoptionError::ImportFailed)?;
            let success = AdoptionResult::new(
                metadata,
                &state.server_id,
                AdoptionStatus::Succeeded,
                None,
                ids,
            );
            candidate.profile_artifact_adoptions.retain(|r| {
                now < r
                    .completed_at_milliseconds
                    .saturating_add(ADOPTION_LEDGER_LIFETIME)
            });
            candidate.profile_artifact_adoptions.push(AdoptionReceipt {
                metadata: metadata.clone(),
                result: success.clone(),
                completed_at_milliseconds: now,
            });
            if candidate.profile_artifact_adoptions.len() > ADOPTION_LEDGER_ENTRIES {
                candidate.profile_artifact_adoptions.remove(0);
            }
            let pending = service.pending.lock().expect("adoption mutex poisoned");
            if let Some(owner) = owner {
                if !matches!(pending.get(&owner),Some(Pending::Committing(m)) if m==metadata) {
                    return Err(AdoptionError::Disconnected);
                }
            }
            let mut inner = self.inner.lock().expect("runtime mutex poisoned");
            self.guard_input_liveness(&mut inner);
            if owner.is_some_and(|id| {
                !inner.core.is_authenticated(id) || !inner.connections.contains_key(&id)
            }) {
                return Err(AdoptionError::Disconnected);
            }
            let current = inner.core.persistent_state();
            if let Some(result) = receipt(current, metadata, unix_millis()) {
                return Ok(result);
            }
            if current.configuration_revision != state.configuration_revision
                || thumble_core::ConfigurationDocument::from_state(current).ok()
                    != thumble_core::ConfigurationDocument::from_state(&state).ok()
            {
                return Err(AdoptionError::ImportFailed);
            }
            candidate.trusted_clients = current.trusted_clients.clone();
            candidate
                .validate()
                .map_err(|_| AdoptionError::ImportFailed)?;
            let effects = inner.core.release_all_locally();
            self.execute_effects_with_output_errors(&mut inner, effects, true)
                .map_err(|_| AdoptionError::ImportFailed)?;
            inner
                .output
                .release_tracked()
                .map_err(|_| AdoptionError::ImportFailed)?;
            storage::save_atomic(&self.paths.state_file, &candidate)
                .map_err(|_| AdoptionError::ImportFailed)?;
            let effects = inner.core.install_validated_persisted_state(candidate);
            let _ = self.execute_effects(&mut inner, effects); // Durable receipt owns replay after delivery loss.
            drop(inner);
            drop(pending);
            Ok(success)
        })();
        let result = result.unwrap_or_else(|code| {
            AdoptionResult::new(
                metadata,
                &state.server_id,
                AdoptionStatus::Failed,
                Some(code),
                vec![],
            )
        });
        if let Some(owner) = owner {
            if result.status == AdoptionStatus::Replayed {
                self.adoption_snapshot(owner);
            }
        }
        result
    }
}
