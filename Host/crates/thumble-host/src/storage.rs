use crate::paths::HostPaths;
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::Value as JsonValue;
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Cursor, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
#[cfg(target_os = "macos")]
use std::process::{Command, Stdio};
use thumble_core::{
    ButtonBindings, KeyBinding, OutputBinding, PersistentState,
    TrustedClient,
};
use uuid::Uuid;

// These legacy defaults identifiers are an interoperability contract with
// existing Thumble installations. They intentionally retain their pre-rename
// values so migration preserves server identity, pairing, and profiles.
const DEFAULTS_DOMAIN: &str = "com.codybontecou.PocketPadMac";
const SERVER_ID_KEY: &str = "PocketPadMac.serverIdentity.v1";
const TRUSTED_CLIENTS_KEY: &str = "PocketPadMac.trustedClients.v1";
const PROFILES_KEY: &str = "PocketPad.gamepadConfigurationProfiles.v1";
const CUSTOMIZATION_KEY: &str = "PocketPad.gamepadCustomization.v1";
const KEY_BINDINGS_V2_KEY: &str = "PocketPadMac.keyBindings.v2";
const KEY_BINDINGS_V1_KEY: &str = "PocketPadMac.keyBindings.v1";
const PROFILE_KEY_BINDINGS_KEY: &str = "PocketPadMac.profileKeyBindings.v1";
const OUTPUT_BINDINGS_KEY: &str = "PocketPadMac.outputBindings.v1";
const PROFILE_OUTPUT_BINDINGS_KEY: &str = "PocketPadMac.profileOutputBindings.v1";

pub fn load_or_migrate(paths: &HostPaths) -> Result<PersistentState, String> {
    paths
        .ensure_state_dir()
        .map_err(|error| format!("create state directory: {error}"))?;
    if paths.state_file.exists() {
        let mut state = load(&paths.state_file)?;
        let original_schema_version = state.schema_version;
        state
            .normalize()
            .map_err(|error| format!("normalize persistent state: {error}"))?;
        if state.schema_version != original_schema_version {
            save_atomic(&paths.state_file, &state)?;
        } else {
            restrict_file(&paths.state_file)?;
        }
        return Ok(state);
    }

    let generated_id = Uuid::new_v4().to_string();
    install_initial_state(paths, migration_source(paths)?, &generated_id)
}

fn install_initial_state(
    paths: &HostPaths,
    source: Option<Vec<u8>>,
    generated_id: &str,
) -> Result<PersistentState, String> {
    let mut state = match source {
        Some(source) => migrate_plist_bytes(&source, generated_id).map_err(|error| {
            format!(
                "legacy Thumble defaults were found but could not be migrated; no new state was written: {error}"
            )
        })?,
        None => PersistentState::minimal(generated_id.to_owned())
            .expect("a generated UUID is a valid server ID"),
    };
    state
        .normalize()
        .map_err(|error| format!("normalize migrated state: {error}"))?;
    save_atomic(&paths.state_file, &state)?;
    Ok(state)
}

pub fn load(path: &Path) -> Result<PersistentState, String> {
    const MAXIMUM_STATE_BYTES: u64 = 16 * 1024 * 1024;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path)
        .map_err(|error| format!("read {}: {error}", path.display()))?;
    let metadata = file
        .metadata()
        .map_err(|error| format!("inspect {}: {error}", path.display()))?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0
        || metadata.len() > MAXIMUM_STATE_BYTES
    {
        return Err(format!(
            "state file {} failed ownership, mode, type, or size validation",
            path.display()
        ));
    }
    let mut data = Vec::with_capacity(usize::try_from(metadata.len()).unwrap_or(0));
    file.take(MAXIMUM_STATE_BYTES.saturating_add(1))
        .read_to_end(&mut data)
        .map_err(|error| format!("read {}: {error}", path.display()))?;
    if data.len() as u64 > MAXIMUM_STATE_BYTES {
        return Err(format!(
            "state file {} exceeds its size limit",
            path.display()
        ));
    }
    thumble_protocol::decode_unique_json(&data).map_err(|error| format!("decode {}: {error}", path.display()))
}

pub fn redact_known_auth_tokens(path: &Path, text: &str) -> String {
    let Ok(state) = load(path) else {
        return text.to_owned();
    };
    state
        .trusted_clients
        .keys()
        .filter(|token| !token.is_empty())
        .fold(text.to_owned(), |redacted, token| {
            redacted.replace(token, "[REDACTED]")
        })
}

pub fn save_atomic(path: &Path, state: &PersistentState) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| format!("state path {} has no parent", path.display()))?;
    if let Ok(metadata) = fs::symlink_metadata(parent) {
        if metadata.file_type().is_symlink()
            || !metadata.is_dir()
            || metadata.uid() != unsafe { libc::geteuid() }
        {
            return Err("state directory failed ownership or symlink validation".to_owned());
        }
    }
    fs::create_dir_all(parent).map_err(|error| format!("create {}: {error}", parent.display()))?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("protect {}: {error}", parent.display()))?;
    let metadata = fs::symlink_metadata(parent)
        .map_err(|error| format!("inspect {}: {error}", parent.display()))?;
    if metadata.file_type().is_symlink()
        || !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err("state directory failed ownership or permission validation".to_owned());
    }

    let data = serde_json::to_vec_pretty(state)
        .map_err(|error| format!("encode persistent state: {error}"))?;
    let temporary = parent.join(format!(
        ".{}.{}.tmp",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("state"),
        Uuid::new_v4().simple()
    ));
    let result = (|| -> io::Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(&data)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.map_err(|error| format!("atomically write {}: {error}", path.display()))
}

pub fn migrate_plist_file(path: &Path, generated_id: &str) -> Result<PersistentState, String> {
    let data = fs::read(path).map_err(|error| format!("read {}: {error}", path.display()))?;
    migrate_plist_bytes(&data, generated_id)
}

pub fn migrate_plist_bytes(data: &[u8], generated_id: &str) -> Result<PersistentState, String> {
    let plist = plist::Value::from_reader(Cursor::new(data))
        .map_err(|error| format!("decode legacy defaults plist: {error}"))?;
    let dictionary = plist
        .as_dictionary()
        .ok_or_else(|| "legacy defaults plist is not a dictionary".to_owned())?;
    let server_id = match dictionary.get(SERVER_ID_KEY) {
        Some(value) => value
            .as_string()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .ok_or_else(|| format!("legacy key {SERVER_ID_KEY} is not a non-empty string"))?,
        None => generated_id,
    };
    let mut state = PersistentState::minimal(server_id.to_owned())
        .map_err(|error| format!("create migration fallback: {error}"))?;

    if let Some(data) = optional_data(dictionary, TRUSTED_CLIENTS_KEY)? {
        migrate_trusted_clients(data, &mut state)?;
    }
    let migrated_profiles = match optional_data(dictionary, PROFILES_KEY)? {
        Some(data) => migrate_profiles(data, &mut state)?,
        None => false,
    };
    if !migrated_profiles {
        if let Some(data) = optional_data(dictionary, CUSTOMIZATION_KEY)? {
            migrate_standalone_customization(data, &mut state)?;
        }
    }

    // Fresh construction may use the starter profile, but imported declarations
    // own their own maps. Never retain the constructor's unrelated UUIDs.
    initialize_owned_bindings(&mut state);

    if dictionary.contains_key(KEY_BINDINGS_V1_KEY) {
        return Err("obsolete input-binding storage is no longer supported; recreate the setup with element UUIDs".to_owned());
    }
    let migrated_key_bindings = optional_data(dictionary, KEY_BINDINGS_V2_KEY)?
        .map(|data| parse_bindings::<KeyBinding>(data).ok_or_else(||
            "invalid input-binding map; recreate the setup with element UUIDs".to_owned()))
        .transpose()?;
    if let Some(bindings) = migrated_key_bindings {
        state.key_bindings = bindings;
    }

    if let Some(data) = optional_data(dictionary, PROFILE_KEY_BINDINGS_KEY)? {
        state.profile_key_bindings =
            parse_profile_bindings::<KeyBinding>(data).ok_or_else(|| {
                format!("legacy key {PROFILE_KEY_BINDINGS_KEY} contains invalid binding JSON")
            })?;
    }

    let mut output_bindings = state.output_bindings.clone();
    overlay_keyboard_bindings(&mut output_bindings, &state.key_bindings);
    if let Some(data) = optional_data(dictionary, OUTPUT_BINDINGS_KEY)? {
        let migrated = parse_bindings::<OutputBinding>(data).ok_or_else(|| {
            format!("legacy key {OUTPUT_BINDINGS_KEY} contains invalid output JSON")
        })?;
        overlay_bindings(&mut output_bindings, &migrated);
    }
    state.output_bindings = output_bindings;

    let mut profile_output_bindings = state.profile_output_bindings.clone();
    for (profile_id, bindings) in &state.profile_key_bindings {
        let canonical = profile_output_bindings.keys().find(|id| id.eq_ignore_ascii_case(profile_id))
            .cloned().unwrap_or_else(|| profile_id.clone());
        overlay_keyboard_bindings(profile_output_bindings.entry(canonical).or_default(), bindings);
    }
    if let Some(data) = optional_data(dictionary, PROFILE_OUTPUT_BINDINGS_KEY)? {
        let migrated = parse_profile_bindings::<OutputBinding>(data).ok_or_else(|| {
            format!("legacy key {PROFILE_OUTPUT_BINDINGS_KEY} contains invalid output JSON")
        })?;
        for (profile_id, bindings) in migrated {
            let canonical = profile_output_bindings.keys().find(|id| id.eq_ignore_ascii_case(&profile_id))
                .cloned().unwrap_or(profile_id);
            overlay_bindings(profile_output_bindings.entry(canonical).or_default(), &bindings);
        }
    }
    state.profile_output_bindings = profile_output_bindings;

    state
        .normalize()
        .map_err(|error| format!("normalize legacy defaults: {error}"))?;
    Ok(state)
}

fn migration_source(paths: &HostPaths) -> Result<Option<Vec<u8>>, String> {
    #[cfg(target_os = "macos")]
    if paths
        .state_dir
        .ancestors()
        .nth(3)
        .is_some_and(effective_user_home_matches)
    {
        if let Some(exported) = export_defaults()? {
            return Ok(Some(exported));
        }
    }

    let preferences = paths
        .state_dir
        .ancestors()
        .nth(3)
        .map(|home| {
            home.join("Library/Preferences")
                .join(format!("{DEFAULTS_DOMAIN}.plist"))
        })
        .or_else(default_preferences_path);
    let Some(path) = preferences else {
        return Ok(None);
    };
    match fs::read(&path) {
        Ok(data) => Ok(Some(data)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!(
            "read detected legacy preferences {}: {error}",
            path.display()
        )),
    }
}

#[cfg(target_os = "macos")]
fn effective_user_home_matches(path: &Path) -> bool {
    // SAFETY: getpwuid returns process-global immutable storage. The bytes are
    // copied into a Path before the comparison.
    unsafe {
        let entry = libc::getpwuid(libc::geteuid());
        if entry.is_null() || (*entry).pw_dir.is_null() {
            return false;
        }
        use std::os::unix::ffi::OsStrExt;
        let bytes = std::ffi::CStr::from_ptr((*entry).pw_dir).to_bytes();
        path == Path::new(std::ffi::OsStr::from_bytes(bytes))
    }
}

#[cfg(target_os = "macos")]
fn export_defaults() -> Result<Option<Vec<u8>>, String> {
    let output = Command::new("/usr/bin/defaults")
        .args(["export", DEFAULTS_DOMAIN, "-"])
        .stdin(Stdio::null())
        .output()
        .map_err(|error| format!("export legacy defaults domain: {error}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!(
            "export legacy defaults domain failed with {}: {}",
            output.status,
            stderr.trim()
        ));
    }
    if output.stdout.is_empty() {
        return Err("legacy defaults export succeeded without data".to_owned());
    }
    Ok(Some(output.stdout))
}

fn default_preferences_path() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .filter(|home| !home.is_empty())
        .map(PathBuf::from)
        .map(|home| {
            home.join("Library/Preferences")
                .join(format!("{DEFAULTS_DOMAIN}.plist"))
        })
}

fn optional_data<'a>(
    dictionary: &'a plist::Dictionary,
    key: &str,
) -> Result<Option<&'a [u8]>, String> {
    match dictionary.get(key) {
        None => Ok(None),
        Some(value) => value
            .as_data()
            .map(Some)
            .ok_or_else(|| format!("legacy key {key} is not Data")),
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyTrustedClient {
    token: String,
    #[serde(alias = "name")]
    client_name: String,
    created_at: i64,
    last_seen_at: i64,
}

fn migrate_trusted_clients(data: &[u8], state: &mut PersistentState) -> Result<(), String> {
    let clients = serde_json::from_slice::<Vec<LegacyTrustedClient>>(data)
        .map_err(|error| format!("decode legacy trusted clients: {error}"))?;
    for client in clients {
        let token = client.token.trim();
        if token.is_empty() {
            return Err("legacy trusted client contains an empty token".to_owned());
        }
        state.trusted_clients.insert(
            token.to_owned(),
            TrustedClient {
                name: if client.client_name.trim().is_empty() {
                    "Client".to_owned()
                } else {
                    client.client_name
                },
                created_at: client.created_at,
                last_seen_at: client.last_seen_at,
            },
        );
    }
    Ok(())
}

fn migrate_profiles(data: &[u8], state: &mut PersistentState) -> Result<bool, String> {
    let value = thumble_protocol::decode_unique_json::<JsonValue>(data)
        .map_err(|error| format!("decode legacy profile store: {error}"))?;
    let object = value
        .as_object()
        .ok_or_else(|| "legacy profile store is not a JSON object".to_owned())?;
    let profiles = object
        .get("profiles")
        .and_then(JsonValue::as_array)
        .ok_or_else(|| "legacy profile store has no profiles array".to_owned())?;
    for profile in profiles {
        if profile
            .get("id")
            .and_then(JsonValue::as_str)
            .is_none_or(|id| id.trim().is_empty())
        {
            return Err("legacy profile store contains a profile without an ID".to_owned());
        }
    }
    if profiles.is_empty() {
        return Err("saved profile catalogs must not be empty; obsolete setups are not reconstructed".to_owned());
    }
    {
        let mut migrated = profiles.clone();
        for profile in &mut migrated {
            let profile = profile
                .as_object_mut()
                .ok_or_else(|| "legacy profile is not a JSON object".to_owned())?;
            if !profile.contains_key("customization") {
                return Err("profiles must declare a primary customization and element UUIDs; obsolete setups are not reconstructed".to_owned());
            }
            for key in [
                "customization",
                "landscapeCustomization",
                "portraitCustomization",
            ] {
                if let Some(customization) = profile.get_mut(key) {
                    ensure_customization_elements(customization)?;
                }
            }
        }
        state.profiles = migrated;
    }
    state.active_profile_id = object.get("activeProfileID").and_then(JsonValue::as_str)
        .ok_or_else(|| "saved profile catalogs must declare an active profile UUID".to_owned())?.to_owned();
    state.default_profile_id = object.get("defaultProfileID").and_then(JsonValue::as_str)
        .ok_or_else(|| "saved profile catalogs must declare a default profile UUID".to_owned())?.to_owned();
    Ok(true)
}

fn migrate_standalone_customization(
    data: &[u8],
    state: &mut PersistentState,
) -> Result<(), String> {
    let customization = thumble_protocol::decode_unique_json::<JsonValue>(data)
        .map_err(|error| format!("decode legacy standalone customization: {error}"))?;
    if !customization.is_object() {
        return Err("legacy standalone customization is not a JSON object".to_owned());
    }
    let mut customization = customization;
    ensure_customization_elements(&mut customization)?;
    let profile = state
        .profiles
        .first_mut()
        .and_then(JsonValue::as_object_mut)
        .ok_or_else(|| "migration fallback profile is malformed".to_owned())?;
    profile.insert(
        "name".to_owned(),
        JsonValue::String("Current Setup".to_owned()),
    );
    profile.insert("customization".to_owned(), customization);
    Ok(())
}

fn ensure_customization_elements(customization: &mut JsonValue) -> Result<(), String> {
    let profile = serde_json::json!({"customization": customization});
    if !thumble_core::validate_element_identities(&profile) {
        return Err("named input slots are no longer supported; recreate this setup with element UUIDs".to_owned());
    }
    Ok(())
}

fn swift_dictionary_value<'a>(
    dictionary: Option<&'a JsonValue>,
    key: &str,
) -> Option<&'a JsonValue> {
    match dictionary? {
        JsonValue::Object(object) => object.get(key),
        JsonValue::Array(entries) => entries
            .chunks_exact(2)
            .find_map(|entry| (entry[0].as_str() == Some(key)).then_some(&entry[1])),
        _ => None,
    }
}

fn normalized_binding_json(mut value: JsonValue) -> JsonValue {
    fn visit(value: &mut JsonValue) {
        match value {
            JsonValue::Object(object) => {
                if let Some(raw) = object
                    .get("modifiers")
                    .and_then(JsonValue::as_object)
                    .and_then(|modifiers| modifiers.get("rawValue"))
                    .and_then(JsonValue::as_u64)
                {
                    object.insert("modifiers".to_owned(), JsonValue::from(raw));
                }
                for child in object.values_mut() {
                    visit(child);
                }
            }
            JsonValue::Array(array) => array.iter_mut().for_each(visit),
            _ => {}
        }
    }
    visit(&mut value);
    value
}

fn parse_bindings<T: DeserializeOwned>(data: &[u8]) -> Option<ButtonBindings<T>> {
    let value = thumble_protocol::decode_unique_json::<JsonValue>(data).ok()?;
    serde_json::from_value(normalized_binding_json(value)).ok()
}

fn parse_profile_bindings<T: DeserializeOwned>(
    data: &[u8],
) -> Option<BTreeMap<String, ButtonBindings<T>>> {
    let value = thumble_protocol::decode_unique_json::<JsonValue>(data).ok()?;
    let maps: BTreeMap<String, ButtonBindings<T>> = serde_json::from_value(normalized_binding_json(value)).ok()?;
    let mut seen = std::collections::BTreeSet::new();
    for id in maps.keys() {
        let parsed = uuid::Uuid::parse_str(id).ok()?;
        if !parsed.hyphenated().to_string().eq_ignore_ascii_case(id) || !seen.insert(parsed) { return None; }
    }
    Some(maps)
}

fn initialize_owned_bindings(state: &mut PersistentState) {
    state.profile_key_bindings.clear();
    state.profile_output_bindings.clear();
    for profile in &state.profiles {
        let Some(id) = profile.get("id").and_then(JsonValue::as_str) else { continue; };
        let outputs = thumble_core::profile_owned_outputs(profile);
        let mut keys = ButtonBindings::default();
        for (input, output) in outputs.iter_ids() {
            if let Some(keyboard) = &output.keyboard { keys.insert(input, keyboard.clone()); }
        }
        state.profile_key_bindings.insert(id.to_owned(), keys);
        state.profile_output_bindings.insert(id.to_owned(), outputs);
    }
    state.key_bindings = state.profile_key_bindings.iter()
        .find(|(id, _)| id.eq_ignore_ascii_case(&state.active_profile_id))
        .map(|(_, bindings)| bindings.clone()).unwrap_or_default();
    state.output_bindings = state.profile_output_bindings.iter()
        .find(|(id, _)| id.eq_ignore_ascii_case(&state.active_profile_id))
        .map(|(_, bindings)| bindings.clone()).unwrap_or_default();
}

fn overlay_keyboard_bindings(outputs: &mut ButtonBindings<OutputBinding>, keys: &ButtonBindings<KeyBinding>) {
    for (id, keyboard) in keys.iter_ids() {
        let mut output = outputs.get(&id).cloned().unwrap_or_default();
        output.keyboard = Some(keyboard.clone());
        outputs.insert(id, output);
    }
}

fn overlay_bindings<T: Clone>(target: &mut ButtonBindings<T>, overlay: &ButtonBindings<T>) {
    for (button, binding) in overlay.iter_ids() {
        target.insert(button, binding.clone());
    }
}

fn restrict_file(path: &Path) -> Result<(), String> {
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("protect {}: {error}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use plist::{Dictionary, Value};
    use serde_json::json;
    use tempfile::tempdir;

    const PRIMARY: &str = "00000000-0000-0000-0000-000000000105";
    const SECONDARY: &str = "00000000-0000-0000-0000-000000000106";
    const MENU: &str = "00000000-0000-0000-0000-00000000010A";
    const EXTRA: &str = "BC157B10-AC03-4630-BB24-DF26A326541A";

    fn fixture_plist() -> Vec<u8> {
        let profile_id = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
        let trusted = json!([{
            "token": "fixture-auth-token",
            "clientName": "Fixture iPhone",
            "createdAt": 111,
            "lastSeenAt": 222
        }]);
        let profiles = json!({
            "profiles": [{
                "id": profile_id,
                "name": "Imported",
                "customization": {"elements": [
                    {"id":PRIMARY,"kind":"button"}, {"id":SECONDARY,"kind":"button"},
                    {"id":MENU,"kind":"button"}, {"id":EXTRA,"kind":"button"}
                ]},
                "futureField": {"survives": true}
            }],
            "activeProfileID": profile_id,
            "defaultProfileID": profile_id
        });
        let key_bindings = json!({
            PRIMARY: {"keyCode": 49, "modifiers": {"rawValue": 3}},
            EXTRA: {"keyCode": 7, "modifiers": 0}
        });
        let profile_key_bindings = json!({
            profile_id: {SECONDARY: {"keyCode": 40, "modifiers": 8}}
        });
        let output_bindings = json!({
            PRIMARY: {"keyboard": {"keyCode": 36, "modifiers": 1}, "gamepadButtons": ["south"]}
        });
        let profile_output_bindings = json!({
            profile_id: {MENU: {"keyboard": {"keyCode": 53, "modifiers": 0}, "gamepadButtons": []}}
        });

        let mut dictionary = Dictionary::new();
        dictionary.insert(
            SERVER_ID_KEY.to_owned(),
            Value::String("SERVER-FIXTURE-ID".to_owned()),
        );
        dictionary.insert(
            TRUSTED_CLIENTS_KEY.to_owned(),
            Value::Data(serde_json::to_vec(&trusted).unwrap()),
        );
        dictionary.insert(
            PROFILES_KEY.to_owned(),
            Value::Data(serde_json::to_vec(&profiles).unwrap()),
        );
        dictionary.insert(
            KEY_BINDINGS_V2_KEY.to_owned(),
            Value::Data(serde_json::to_vec(&key_bindings).unwrap()),
        );
        dictionary.insert(
            PROFILE_KEY_BINDINGS_KEY.to_owned(),
            Value::Data(serde_json::to_vec(&profile_key_bindings).unwrap()),
        );
        dictionary.insert(
            OUTPUT_BINDINGS_KEY.to_owned(),
            Value::Data(serde_json::to_vec(&output_bindings).unwrap()),
        );
        dictionary.insert(
            PROFILE_OUTPUT_BINDINGS_KEY.to_owned(),
            Value::Data(serde_json::to_vec(&profile_output_bindings).unwrap()),
        );
        let mut bytes = Vec::new();
        plist::to_writer_xml(&mut bytes, &Value::Dictionary(dictionary)).unwrap();
        bytes
    }

    #[test]
    fn current_uuid_xml_defaults_import_preserves_every_independent_layer() {
        let state = migrate_plist_bytes(&fixture_plist(), "generated-fallback").unwrap();
        let profile_id = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";

        assert_eq!(state.server_id, "SERVER-FIXTURE-ID");
        assert_eq!(
            state.trusted_clients["fixture-auth-token"].name,
            "Fixture iPhone"
        );
        assert_eq!(state.active_profile_id, profile_id);
        assert_eq!(state.default_profile_id, profile_id);
        assert_eq!(state.profiles[0]["futureField"]["survives"], true);
        assert_eq!(state.key_bindings.get_raw(PRIMARY).unwrap().modifiers, 3);
        assert_eq!(
            state.key_bindings.get_raw(EXTRA).unwrap().key_code,
            7
        );
        assert_eq!(
            state.profile_key_bindings[profile_id]
                .get_raw(SECONDARY)
                .unwrap()
                .modifiers,
            8
        );
        assert_eq!(
            state
                .output_bindings
                .get_raw(PRIMARY)
                .unwrap()
                .keyboard
                .as_ref()
                .unwrap()
                .key_code,
            36
        );
        assert!(state
            .output_bindings
            .get_raw(PRIMARY)
            .unwrap()
            .gamepad_buttons
            .contains("south"));
        assert_eq!(
            state.profile_output_bindings[profile_id]
                .get_raw(SECONDARY)
                .unwrap()
                .keyboard
                .as_ref()
                .unwrap()
                .key_code,
            40
        );
        assert_eq!(
            state.profile_output_bindings[profile_id]
                .get_raw(MENU)
                .unwrap()
                .keyboard
                .as_ref()
                .unwrap()
                .key_code,
            53
        );
    }

    #[test]
    fn defaults_profile_without_primary_declarations_is_rejected_without_writing_state() {
        let directory = tempdir().unwrap();
        let paths = HostPaths::new(directory.path().join("state"), directory.path().join("control.sock"));
        paths.ensure_state_dir().unwrap();
        let profile_id = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE";
        let profiles = json!({"profiles":[{"id":profile_id,"name":"Missing declaration"}],
            "activeProfileID":profile_id,"defaultProfileID":profile_id});
        let mut defaults = Dictionary::new();
        defaults.insert(PROFILES_KEY.to_owned(), Value::Data(serde_json::to_vec(&profiles).unwrap()));
        let mut source = Vec::new();
        plist::to_writer_xml(&mut source, &Value::Dictionary(defaults)).unwrap();
        assert!(install_initial_state(&paths, Some(source), "server").is_err());
        assert!(!paths.state_file.exists());
    }

    #[test]
    fn obsolete_numeric_binding_storage_is_rejected_instead_of_recovered() {
        let mut root = Dictionary::new();
        root.insert(
            KEY_BINDINGS_V2_KEY.to_owned(),
            Value::Data(b"not json".to_vec()),
        );
        root.insert(
            KEY_BINDINGS_V1_KEY.to_owned(),
            Value::Data(br#"{"jump":{"keyCode":49,"modifiers":2}}"#.to_vec()),
        );
        let mut bytes = Vec::new();
        plist::to_writer_xml(&mut bytes, &Value::Dictionary(root.clone())).unwrap();

        let error = migrate_plist_bytes(&bytes, "fallback").unwrap_err();
        assert!(error.contains("obsolete input-binding storage"), "{error}");
        root.remove(KEY_BINDINGS_V1_KEY);
        let mut malformed = Vec::new();
        plist::to_writer_xml(&mut malformed, &Value::Dictionary(root)).unwrap();
        assert!(migrate_plist_bytes(&malformed, "fallback").unwrap_err().contains("invalid input-binding map"));
    }

    #[test]
    fn malformed_critical_piece_fails_closed_before_state_installation() {
        let mut root = Dictionary::new();
        root.insert(
            SERVER_ID_KEY.to_owned(),
            Value::String("kept-server".to_owned()),
        );
        root.insert(
            TRUSTED_CLIENTS_KEY.to_owned(),
            Value::Data(b"not json".to_vec()),
        );
        root.insert(
            KEY_BINDINGS_V2_KEY.to_owned(),
            Value::Data(br#"{"jump":{"keyCode":49,"modifiers":0}}"#.to_vec()),
        );
        let mut bytes = Vec::new();
        plist::to_writer_xml(&mut bytes, &Value::Dictionary(root)).unwrap();

        let directory = tempdir().unwrap();
        let paths = HostPaths::new(
            directory.path().to_path_buf(),
            directory.path().join("control.sock"),
        );
        let error = install_initial_state(&paths, Some(bytes), "fallback").unwrap_err();
        assert!(error.contains("trusted clients"), "{error}");
        assert!(!paths.state_file.exists());
    }

    #[test]
    fn obsolete_pre_profile_routing_is_rejected_before_installation() {
        let customization = json!({
            "labelOverrides": ["attack", "Strike"],
            "buttonCustomizations": ["jump", {"isHidden": true}],
            "customButtons": [{
                "id": "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF",
                "mappedButton": "custom3",
                "label": "Orb",
                "layout": {},
                "controlKind": "button"
            }],
            "futureCustomizationField": {"survives": true}
        });
        let key_bindings = json!({
            "jump": {"keyCode": 49, "modifiers": 2},
            "attack": {"keyCode": 40, "modifiers": 0},
            "custom3": {"keyCode": 7, "modifiers": 1}
        });
        let partial_outputs = json!({
            "attack": {"gamepadButtons": []}
        });
        let mut root = Dictionary::new();
        root.insert(
            CUSTOMIZATION_KEY.to_owned(),
            Value::Data(serde_json::to_vec(&customization).unwrap()),
        );
        root.insert(
            KEY_BINDINGS_V2_KEY.to_owned(),
            Value::Data(serde_json::to_vec(&key_bindings).unwrap()),
        );
        root.insert(
            OUTPUT_BINDINGS_KEY.to_owned(),
            Value::Data(serde_json::to_vec(&partial_outputs).unwrap()),
        );
        let mut bytes = Vec::new();
        plist::to_writer_xml(&mut bytes, &Value::Dictionary(root)).unwrap();

        assert!(migrate_plist_bytes(&bytes, "fallback").is_err());
        let directory = tempdir().unwrap();
        let paths = HostPaths::new(directory.path().to_path_buf(), directory.path().join("control.sock"));
        assert!(install_initial_state(&paths, Some(bytes), "fallback").is_err());
        assert!(!paths.state_file.exists());
    }

    #[test]
    fn known_auth_tokens_are_removed_from_errors_and_logs() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("state.json");
        let mut state = PersistentState::minimal("server").unwrap();
        state.trusted_clients.insert(
            "secret-auth-token".to_owned(),
            TrustedClient {
                name: "Phone".to_owned(),
                created_at: 1,
                last_seen_at: 2,
            },
        );
        save_atomic(&path, &state).unwrap();
        assert_eq!(
            redact_known_auth_tokens(&path, "failure secret-auth-token detail"),
            "failure [REDACTED] detail"
        );
    }

    #[test]
    fn literal_duplicate_saved_keys_and_default_maps_reject_without_writes() {
        let raw = serde_json::to_string(&PersistentState::minimal("server").unwrap()).unwrap();
        let original = "\"kind\":\"button\"";
        assert!(raw.contains(original));
        let before = raw.replacen(original, "\"kind\":\"joystick\",\"kind\":\"button\"", 1).into_bytes();
        let directory = tempdir().unwrap();
        let paths = HostPaths::new(directory.path().to_path_buf(), directory.path().join("control.sock"));
        paths.ensure_state_dir().unwrap();
        fs::write(&paths.state_file, &before).unwrap();
        fs::set_permissions(&paths.state_file, fs::Permissions::from_mode(0o600)).unwrap();
        assert!(load_or_migrate(&paths).is_err());
        assert_eq!(fs::read(&paths.state_file).unwrap(), before);
        let id = "00000000-0000-0000-0000-000000000105";
        let binding = r#"{"keyCode":49,"modifiers":0}"#;
        let ambiguous = format!(r#"{{"{id}":{binding},"{id}":{binding}}}"#);
        assert!(parse_bindings::<KeyBinding>(ambiguous.as_bytes()).is_none());
        let ambiguous_profiles = format!(r#"{{"4B6B62C7-367D-44C7-BA78-2AC30E6E22F4":{ambiguous}}}"#);
        assert!(parse_profile_bindings::<KeyBinding>(ambiguous_profiles.as_bytes()).is_none());
    }

    #[test]
    fn existing_invalid_references_are_rejected_without_rewriting_saved_state() {
        let valid = serde_json::to_value(PersistentState::minimal("server").unwrap()).unwrap();
        let other = "4B6B62C7-367D-44C7-BA78-2AC30E6E22F4";
        let mut cases = Vec::new();
        let mut empty = valid.clone();
        empty["profiles"] = json!([]);
        cases.push(empty);
        for field in ["activeProfileID", "defaultProfileID"] {
            let mut dangling = valid.clone();
            dangling[field] = json!(other);
            cases.push(dangling);
        }
        let mut duplicate = valid.clone();
        let profile = duplicate["profiles"][0].clone();
        duplicate["profiles"].as_array_mut().unwrap().push(profile);
        cases.push(duplicate);
        for field in ["profileKeyBindings", "profileOutputBindings"] {
            let mut orphan = valid.clone();
            orphan[field][other] = json!({});
            cases.push(orphan);
        }
        for (index, document) in cases.into_iter().enumerate() {
            let directory = tempdir().unwrap();
            let paths = HostPaths::new(directory.path().to_path_buf(), directory.path().join("control.sock"));
            paths.ensure_state_dir().unwrap();
            let before = serde_json::to_vec(&document).unwrap();
            fs::write(&paths.state_file, &before).unwrap();
            fs::set_permissions(&paths.state_file, fs::Permissions::from_mode(0o600)).unwrap();
            assert!(load_or_migrate(&paths).is_err(), "accepted reference case {index}");
            assert_eq!(fs::read(&paths.state_file).unwrap(), before);
        }
    }

    #[test]
    fn defaults_references_reject_before_initial_installation() {
        let state = PersistentState::minimal("server").unwrap();
        let valid = json!({"profiles":state.profiles,"activeProfileID":state.active_profile_id,"defaultProfileID":state.default_profile_id});
        let mut cases = Vec::new();
        let mut empty = valid.clone();
        empty["profiles"] = json!([]);
        cases.push(empty);
        for field in ["activeProfileID", "defaultProfileID"] {
            let mut missing = valid.clone();
            missing.as_object_mut().unwrap().remove(field);
            cases.push(missing);
            let mut dangling = valid.clone();
            dangling[field] = json!("4B6B62C7-367D-44C7-BA78-2AC30E6E22F4");
            cases.push(dangling);
        }
        let mut duplicate = valid.clone();
        let profile = duplicate["profiles"][0].clone();
        duplicate["profiles"].as_array_mut().unwrap().push(profile);
        cases.push(duplicate);
        for (index, profiles) in cases.into_iter().enumerate() {
            let directory = tempdir().unwrap();
            let paths = HostPaths::new(directory.path().join("state"), directory.path().join("control.sock"));
            paths.ensure_state_dir().unwrap();
            let mut defaults = Dictionary::new();
            defaults.insert(PROFILES_KEY.to_owned(), Value::Data(serde_json::to_vec(&profiles).unwrap()));
            let mut source = Vec::new();
            plist::to_writer_xml(&mut source, &Value::Dictionary(defaults)).unwrap();
            let before = source.clone();
            assert!(install_initial_state(&paths, Some(source), "server").is_err(), "accepted defaults reference case {index}");
            assert!(!paths.state_file.exists());
            assert!(!before.is_empty());
        }
    }

    #[test]
    fn missing_defaults_maps_derive_only_from_each_profiles_owned_outputs() {
        let first = "4B6B62C7-367D-44C7-BA78-2AC30E6E22F4";
        let second = "B16C0A67-B9EA-42CA-966B-9F23A09CDE8B";
        let input = "82782DD6-D823-44AD-B9FC-9655E16160B1";
        let profiles = json!({"profiles":[
            {"id":first,"name":"Owned","customization":{"elements":[{"id":input,"kind":"button","output":{"keyboard":{"keyCode":49,"modifiersRawValue":8},"gamepadButtons":["south"]}}]}},
            {"id":second,"name":"Blank","customization":{"elements":[]}}
        ],"activeProfileID":first,"defaultProfileID":first});
        let mut defaults = Dictionary::new();
        defaults.insert(PROFILES_KEY.to_owned(), Value::Data(serde_json::to_vec(&profiles).unwrap()));
        let mut source = Vec::new();
        plist::to_writer_xml(&mut source, &Value::Dictionary(defaults)).unwrap();
        let imported = migrate_plist_bytes(&source, "server").unwrap();
        assert_eq!(imported.key_bindings.len(), 1);
        assert_eq!(imported.key_bindings.get_raw(input).unwrap(), &KeyBinding::new(49, 8));
        assert_eq!(imported.output_bindings.len(), 1);
        assert!(imported.output_bindings.get_raw(input).unwrap().gamepad_buttons.contains("south"));
        assert_eq!(imported.profile_key_bindings[first].len(), 1);
        assert_eq!(imported.profile_output_bindings[first].len(), 1);
        assert!(imported.profile_key_bindings[second].is_empty());
        assert!(imported.profile_output_bindings[second].is_empty());
        assert_eq!(imported.profiles.len(), 2);
    }

    #[test]
    fn existing_obsolete_state_is_rejected_without_rewriting_the_file() {
        let directory = tempdir().unwrap();
        let paths = HostPaths::new(
            directory.path().to_path_buf(),
            directory.path().join("control.sock"),
        );
        paths.ensure_state_dir().unwrap();
        let state = PersistentState::minimal("server").unwrap();
        let mut legacy = serde_json::to_value(state).unwrap();
        legacy["schemaVersion"] = json!(1);
        legacy
            .as_object_mut()
            .unwrap()
            .remove("configurationRevision");
        fs::write(&paths.state_file, serde_json::to_vec(&legacy).unwrap()).unwrap();
        fs::set_permissions(&paths.state_file, fs::Permissions::from_mode(0o600)).unwrap();

        let before = fs::read(&paths.state_file).unwrap();
        assert!(load_or_migrate(&paths).unwrap_err().contains("unsupported persistent-state schema version 1"));
        assert_eq!(fs::read(&paths.state_file).unwrap(), before);
    }

    #[test]
    fn atomic_state_file_is_private_and_round_trips() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("state.json");
        let state = PersistentState::minimal("server").unwrap();
        save_atomic(&path, &state).unwrap();
        assert_eq!(load(&path).unwrap(), state);
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}
