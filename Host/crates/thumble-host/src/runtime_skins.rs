use super::*;
use crate::skin_command::SkinCommand;
use crate::skins::{PreparedSkinProfileChange, SkinBridge, SkinError, SkinLibrary, SkinReference};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::json;
use thumble_protocol::ControllerCapability;
use unicode_normalization::UnicodeNormalization;

pub(super) enum ProfileJob {
    Skin(Box<ControllerMessage>),
    Appearance(Box<crate::phone_appearance::PhoneAppearanceRequest>),
    Layout(Box<crate::phone_layout::PhoneLayoutRequest>),
}

fn same_reference(a: &SkinReference, b: &SkinReference) -> bool {
    // Swift String identity is canonically equivalent. Do not permit removal
    // of a used archive through an alternate Unicode spelling of its version.
    a.identifier
        .trim()
        .eq_ignore_ascii_case(b.identifier.trim())
        && a.version.trim().nfc().eq(b.version.trim().nfc())
}

// The complete replay fits one bounded wire frame. Larger packages stay local
// rather than advertising a library the phone cannot recover on reconnect.
const MAXIMUM_SYNC_BYTES: usize = 4 * 1024 * 1024;

pub(super) struct SkinService {
    bridge: SkinBridge,
    library: SkinLibrary,
    mutation: Mutex<()>,
    replay: Mutex<Vec<String>>,
}
impl SkinService {
    pub(super) fn open(paths: &HostPaths) -> Result<Self, SkinError> {
        let bridge = SkinBridge::discover()?;
        let library = SkinLibrary::open(paths, bridge.clone())?;
        let mut replay = Vec::new();
        for info in library.list()? {
            if let Some(package) = library.load(&info.reference)? {
                replay.push(package.wire_archive());
            }
        }
        if replay.iter().map(String::len).sum::<usize>() > MAXIMUM_SYNC_BYTES {
            return Err(SkinError("skin_sync_limit"));
        }
        Ok(Self {
            bridge,
            library,
            mutation: Mutex::new(()),
            replay: Mutex::new(replay),
        })
    }
}

pub(super) fn is_skin_message(message: &ControllerMessage) -> bool {
    matches!(
        message.message_type,
        ControllerMessageType::SkinPackages
            | ControllerMessageType::SkinPackageRemoval
            | ControllerMessageType::GamepadProfileSkinSelection
    )
}

impl SharedRuntime {
    pub(super) fn handle_profile_job(&self, id: ConnectionId, job: ProfileJob) {
        let job = match job {
            ProfileJob::Layout(request) => {
                self.handle_phone_layout(id, *request);
                return;
            }
            other => other,
        };
        let ProfileJob::Appearance(request) = job else {
            if let ProfileJob::Skin(message) = job {
                self.handle_skin_message(id, *message);
            }
            return;
        };
        let result = (|| {
            let service = self
                .skin_service
                .as_ref()
                .ok_or("appearance_bridge_unavailable")?;
            let _mutation = service.mutation.try_lock().map_err(|_| "appearance_busy")?;
            self.skin_state(Some(id))
                .map_err(|_| "appearance_session_retired")?;
            let bridge =
                ConfigurationBridge::discover().map_err(|_| "appearance_bridge_unavailable")?;
            let prepared = request.prepare(&bridge, unix_millis())?;
            let mut inner = self.inner.lock().expect("runtime mutex poisoned");
            self.guard_input_liveness(&mut inner);
            if !inner.connections.contains_key(&id) || !inner.core.is_authenticated(id) {
                return Err("appearance_session_retired");
            }
            if let Some(candidate) = prepared.candidate(inner.core.persistent_state())? {
                let releases = inner.core.release_all();
                self.execute_effects(&mut inner, releases)
                    .map_err(|_| "appearance_input_release_failed")?;
                storage::save_atomic(&self.paths.state_file, &candidate)
                    .map_err(|_| "appearance_profile_save_failed")?;
                let effects = inner.core.install_validated_persisted_state(candidate);
                self.execute_effects(&mut inner, effects)
                    .map_err(|_| "appearance_delivery_failed")?;
            } else {
                self.handle_input_locked(
                    &mut inner,
                    id,
                    ControllerMessage::new(ControllerMessageType::GamepadProfiles, unix_millis()),
                    false,
                )
                .map_err(|_| "appearance_delivery_failed")?;
            }
            Ok::<(), &'static str>(())
        })();
        if let Err(code) = result {
            self.skin_error(id, code);
        }
    }

    fn handle_phone_layout(
        &self,
        id: ConnectionId,
        request: crate::phone_layout::PhoneLayoutRequest,
    ) {
        let result = (|| {
            let bridge = self
                .phone_layout_bridge
                .as_ref()
                .ok_or("phone_layout_bridge_unavailable")?;
            let _library_mutation = self
                .skin_service
                .as_ref()
                .map(|service| {
                    service
                        .mutation
                        .lock()
                        .map_err(|_| "phone_layout_skin_unavailable")
                })
                .transpose()?;
            let current = self
                .skin_state(Some(id))
                .map_err(|_| "phone_layout_session_retired")?;
            let request = request.rebase(current)?;
            let reference = request.skin_reference()?;
            let package = if let (Some(service), Some(reference)) = (&self.skin_service, reference)
            {
                service
                    .library
                    .load(&reference)
                    .map_err(|_| "phone_layout_package_unavailable")?
            } else {
                None
            };
            let prepared =
                request.prepare(bridge, package.as_ref().map(|v| v.archive()), unix_millis())?;
            let mut inner = self.inner.lock().expect("runtime mutex poisoned");
            self.guard_input_liveness(&mut inner);
            if !inner.connections.contains_key(&id) || !inner.core.is_authenticated(id) {
                return Err("phone_layout_session_retired");
            }
            if let Some(candidate) = prepared.candidate(inner.core.persistent_state())? {
                let releases = inner.core.release_all();
                self.execute_effects(&mut inner, releases)
                    .map_err(|_| "phone_layout_release_failed")?;
                storage::save_atomic(&self.paths.state_file, &candidate)
                    .map_err(|_| "phone_layout_save_failed")?;
                let effects = inner.core.install_validated_persisted_state(candidate);
                self.execute_effects(&mut inner, effects)
                    .map_err(|_| "phone_layout_delivery_failed")?;
            } else {
                self.handle_input_locked(
                    &mut inner,
                    id,
                    ControllerMessage::new(ControllerMessageType::GamepadProfiles, unix_millis()),
                    false,
                )
                .map_err(|_| "phone_layout_delivery_failed")?;
            }
            Ok::<(), &'static str>(())
        })();
        if let Err(code) = result {
            self.skin_error(id, code);
        }
    }

    fn skin_state(&self, connection: Option<ConnectionId>) -> Result<PersistentState, SkinError> {
        let inner = self.inner.lock().expect("runtime mutex poisoned");
        if connection.is_some_and(|id| {
            !inner.connections.contains_key(&id) || !inner.core.is_authenticated(id)
        }) {
            return Err(SkinError("skin_session_retired"));
        }
        Ok(inner.core.persistent_state().clone())
    }

    pub(super) fn skin_command(
        &self,
        command: SkinCommand,
        connection: Option<ConnectionId>,
    ) -> Result<Value, SkinError> {
        let service = self
            .skin_service
            .as_ref()
            .ok_or(SkinError("skin_bridge_unavailable"))?;
        let _mutation = service
            .mutation
            .try_lock()
            .map_err(|_| SkinError("skin_busy"))?;
        let state = self.skin_state(connection)?;
        match command {
            SkinCommand::List => Ok(json!({"packages":service.library.list()?})),
            SkinCommand::Export { reference } => {
                let package = service
                    .library
                    .load(&reference)?
                    .ok_or(SkinError("skin_not_installed"))?;
                Ok(json!({"package":package.info(),"archive":package.wire_archive()}))
            }
            SkinCommand::Import { archive, policy } => {
                if archive.len() > MAXIMUM_SYNC_BYTES {
                    return Err(SkinError("skin_sync_limit"));
                }
                let package = service.bridge.inspect_for_install(
                    STANDARD
                        .decode(&archive)
                        .map_err(|_| SkinError("invalid_skin_data"))?,
                    &policy,
                    &service.library.list()?,
                )?;
                let mut next = service.replay.lock().expect("skin cache poisoned").clone();
                // Native inspection canonicalizes identities. Rebuild only the
                // changed key; repeated imports leave the replay byte-identical.
                for info in service.library.list()? {
                    if info.storage_key == package.info().storage_key {
                        if let Some(old) = service.library.load(&info.reference)? {
                            next.retain(|v| v != &old.wire_archive());
                        }
                    }
                }
                next.push(package.wire_archive());
                if next.iter().map(String::len).sum::<usize>() > MAXIMUM_SYNC_BYTES {
                    return Err(SkinError("skin_sync_limit"));
                }
                // Recheck authentication after native work, before persistence.
                self.skin_state(connection)?;
                let changed = service.library.install(&package)?;
                *service.replay.lock().expect("skin cache poisoned") = next;
                self.broadcast_skin_replay();
                Ok(json!({"package":package.info(),"changed":changed}))
            }
            SkinCommand::Apply {
                reference,
                profile,
                appearance,
            } => self.change_skin(
                service,
                state,
                profile,
                (Some(reference), false),
                &appearance,
                connection,
            ),
            SkinCommand::Detach {
                profile,
                appearance,
            } => self.change_skin(
                service,
                state,
                profile,
                (None, true),
                &appearance,
                connection,
            ),
            SkinCommand::Remove { reference } => {
                let package = service
                    .library
                    .load(&reference)?
                    .ok_or(SkinError("skin_not_installed"))?;
                let mut inner = self.inner.lock().expect("runtime mutex poisoned");
                if connection.is_some_and(|id| !inner.core.is_authenticated(id)) {
                    return Err(SkinError("skin_session_retired"));
                }
                for profile in &inner.core.persistent_state().profiles {
                    if profile
                        .get("skinReference")
                        .and_then(|v| serde_json::from_value::<SkinReference>(v.clone()).ok())
                        .is_some_and(|v| same_reference(&v, &package.info().reference))
                    {
                        return Err(SkinError("skin_in_use"));
                    }
                }
                service.library.remove_validated(&package)?;
                service
                    .replay
                    .lock()
                    .expect("skin cache poisoned")
                    .retain(|v| v != &package.wire_archive());
                // Send the remaining authoritative library, matching native Mac.
                self.send_skin_replay_locked(&mut inner);
                Ok(json!({"removed":reference}))
            }
        }
    }

    fn change_skin(
        &self,
        service: &SkinService,
        state: PersistentState,
        selector: cli_profile::ProfileSelector,
        change: (Option<SkinReference>, bool),
        appearance: &str,
        connection: Option<ConnectionId>,
    ) -> Result<Value, SkinError> {
        let (reference, detach) = change;
        let id = cli_profile::resolve_runtime_profile(&state, &selector)
            .map_err(|_| SkinError("skin_profile_not_found"))?;
        let id = Uuid::parse_str(&id).map_err(|_| SkinError("skin_profile_not_found"))?;
        let old = state
            .profiles
            .iter()
            .find(|p| {
                p.get("id")
                    .and_then(Value::as_str)
                    .and_then(|v| Uuid::parse_str(v).ok())
                    == Some(id)
            })
            .ok_or(SkinError("skin_profile_not_found"))?;
        let reference = if detach {
            old.get("skinReference")
                .filter(|v| !v.is_null())
                .map(|v| {
                    serde_json::from_value(v.clone())
                        .map_err(|_| SkinError("invalid_skin_reference"))
                })
                .transpose()?
        } else {
            reference
        };
        let package = reference
            .as_ref()
            .map(|r| service.library.load(r))
            .transpose()?
            .flatten();
        let prepared = PreparedSkinProfileChange::prepare(
            &state,
            id,
            &service.bridge,
            package.as_ref(),
            detach,
            appearance,
            unix_millis(),
        )?;
        let mut inner = self.inner.lock().expect("runtime mutex poisoned");
        if connection.is_some_and(|id| !inner.core.is_authenticated(id)) {
            return Err(SkinError("skin_session_retired"));
        }
        if let Some(candidate) = prepared.candidate(inner.core.persistent_state())? {
            // No profile acknowledgement is emitted until atomic persistence succeeds.
            let releases = inner.core.release_all();
            self.execute_effects(&mut inner, releases)
                .map_err(|_| SkinError("skin_input_release_failed"))?;
            storage::save_atomic(&self.paths.state_file, &candidate)
                .map_err(|_| SkinError("skin_profile_save_failed"))?;
            let effects = inner.core.install_validated_persisted_state(candidate);
            self.execute_effects(&mut inner, effects)
                .map_err(|_| SkinError("skin_delivery_failed"))?;
        }
        Ok(
            json!({"profileID":id,"configurationRevision":inner.core.persistent_state().configuration_revision}),
        )
    }

    fn broadcast_skin_replay(&self) {
        let mut inner = self.inner.lock().expect("runtime mutex poisoned");
        self.send_skin_replay_locked(&mut inner);
    }
    fn send_skin_replay_locked(&self, inner: &mut RuntimeInner) {
        let Some(service) = &self.skin_service else {
            return;
        };
        let mut message =
            ControllerMessage::new(ControllerMessageType::SkinPackages, unix_millis());
        message.skin_packages = Some(service.replay.lock().expect("skin cache poisoned").clone());
        if let Ok(encoded) = ControllerWireCodec::encode(&message) {
            for (id, sender) in &inner.connections {
                if inner.core.is_authenticated(*id) {
                    let _ = sender.try_send(Outbound::Binary(encoded.clone()));
                }
            }
        }
    }
    pub(super) fn decorate_skin_snapshot(&self, message: &mut ControllerMessage) {
        if let Some(service) = &self.skin_service {
            if matches!(
                message.message_type,
                ControllerMessageType::PairingAccepted
                    | ControllerMessageType::GamepadProfiles
                    | ControllerMessageType::GamepadCustomization
                    | ControllerMessageType::Hello
            ) {
                let capabilities = message.capabilities.get_or_insert_with(Vec::new);
                for cap in [
                    ControllerCapability::SkinPackages,
                    ControllerCapability::GamepadProfileSkinSelection,
                ] {
                    if !capabilities.contains(&cap) {
                        capabilities.push(cap);
                    }
                }
                if message.message_type == ControllerMessageType::PairingAccepted {
                    message.skin_packages =
                        Some(service.replay.lock().expect("skin cache poisoned").clone());
                }
            }
        }
    }
    pub(super) fn handle_skin_message(&self, id: ConnectionId, message: ControllerMessage) {
        if self.skin_state(Some(id)).is_err() {
            return;
        }
        let result = (|| {
            match message.message_type {
                ControllerMessageType::SkinPackages => {
                    for archive in message
                        .skin_packages
                        .ok_or(SkinError("skin_packages_required"))?
                    {
                        // Each invalid archive is independent of the others.
                        if let Err(error) = self.skin_command(
                            SkinCommand::Import {
                                archive,
                                policy: "replaceSameVersion".into(),
                            },
                            Some(id),
                        ) {
                            self.skin_error(id, error.0);
                        }
                    }
                }
                ControllerMessageType::SkinPackageRemoval => {
                    let reference = serde_json::from_value(
                        message
                            .skin_reference
                            .ok_or(SkinError("skin_reference_required"))?,
                    )
                    .map_err(|_| SkinError("invalid_skin_reference"))?;
                    self.skin_command(SkinCommand::Remove { reference }, Some(id))?;
                }
                ControllerMessageType::GamepadProfileSkinSelection => {
                    let profile_id = message
                        .gamepad_profile_id
                        .and_then(|v| Uuid::parse_str(&v).ok())
                        .ok_or(SkinError("skin_profile_not_found"))?;
                    let profile = cli_profile::ProfileSelector::Id { profile_id };
                    let reference = message
                        .skin_reference
                        .filter(|v| !v.is_null())
                        .map(serde_json::from_value)
                        .transpose()
                        .map_err(|_| SkinError("invalid_skin_reference"))?;
                    let command = if let Some(reference) = reference {
                        SkinCommand::Apply {
                            reference,
                            profile,
                            appearance: "light".into(),
                        }
                    } else {
                        SkinCommand::Detach {
                            profile,
                            appearance: "light".into(),
                        }
                    };
                    self.skin_command(command, Some(id))?;
                }
                _ => (),
            }
            Ok::<(), SkinError>(())
        })();
        if let Err(error) = result {
            self.skin_error(id, error.0);
        }
    }
    fn skin_error(&self, id: ConnectionId, code: &str) {
        let inner = self.inner.lock().expect("runtime mutex poisoned");
        if inner.core.is_authenticated(id) {
            // Native Mac records skin failures locally without disconnecting the
            // controller. An unacknowledged selection stays in the phone journal.
            self.log(code);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_use_reference_identity_matches_native_canonical_strings() {
        let a = SkinReference {
            identifier: "COM.EXAMPLE.SKIN ".into(),
            version: "1.0.0-café".into(),
        };
        let mut b = SkinReference {
            identifier: "com.example.skin".into(),
            version: "1.0.0-cafe\u{301}".into(),
        };
        assert!(same_reference(&a, &b));
        b.version = "1.0.0-other".into();
        assert!(!same_reference(&a, &b));
    }
}
