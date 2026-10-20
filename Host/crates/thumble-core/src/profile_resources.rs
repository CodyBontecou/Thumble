//! Binary-resource preparation for profile-owned appearance. This does not enable
//! version-5 authority or peer interchange; the configuration gate remains closed.

use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::sync::Arc;

const MAXIMUM_RESOURCE_BYTES: usize = crate::MAXIMUM_CONFIGURATION_DOCUMENT_BYTES;
const VERSION: &str = "appearanceResourceVersion";
const RESOURCES: &str = "appearanceResources";
const REFERENCE: &str = "resourceSHA256";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProfileResourceError {
    InvalidEnvelope,
    UnsupportedVersion,
    InvalidResource(String),
    MissingResource(String),
    TooLarge,
}

impl fmt::Display for ProfileResourceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidEnvelope => formatter.write_str("invalid profile resource envelope"),
            Self::UnsupportedVersion => formatter.write_str("unsupported profile resource version"),
            Self::InvalidResource(id) => write!(formatter, "invalid profile resource {id}"),
            Self::MissingResource(id) => write!(formatter, "missing profile resource {id}"),
            Self::TooLarge => {
                formatter.write_str("profile resources exceed the configuration budget")
            }
        }
    }
}

impl std::error::Error for ProfileResourceError {}

#[derive(Clone)]
pub struct ProfileResourceTable {
    entries: BTreeMap<String, Arc<[u8]>>,
}

impl fmt::Debug for ProfileResourceTable {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ProfileResourceTable")
            .field("resource_count", &self.entries.len())
            .field(
                "byte_count",
                &self.entries.values().map(|v| v.len()).sum::<usize>(),
            )
            .finish()
    }
}

impl ProfileResourceTable {
    /// Call after the import/wire boundary has checked duplicate JSON keys and
    /// total document size. Preserve the raw profile for lossless transactions.
    pub fn from_profile(profile: &Value) -> Result<Option<Self>, ProfileResourceError> {
        let object = profile
            .as_object()
            .ok_or(ProfileResourceError::InvalidEnvelope)?;
        if !object.contains_key(VERSION) && !object.contains_key(RESOURCES) {
            return Ok(None);
        }
        if !object.get("appearanceBank").is_some_and(Value::is_object) {
            return Err(ProfileResourceError::InvalidEnvelope);
        }
        if object.get(VERSION).and_then(Value::as_f64) != Some(1.0) {
            return Err(ProfileResourceError::UnsupportedVersion);
        }
        let resources = object
            .get(RESOURCES)
            .and_then(Value::as_object)
            .ok_or(ProfileResourceError::InvalidEnvelope)?;
        let mut byte_count = 0;
        let mut entries = BTreeMap::new();
        for (digest, encoded) in resources {
            let invalid = || ProfileResourceError::InvalidResource(digest.clone());
            let encoded = encoded.as_str().ok_or_else(invalid)?;
            if encoded.len() > MAXIMUM_RESOURCE_BYTES.div_ceil(3) * 4 {
                return Err(invalid());
            }
            let bytes = STANDARD.decode(encoded).map_err(|_| invalid())?;
            if STANDARD.encode(&bytes) != encoded
                || format!("{:x}", Sha256::digest(&bytes)) != *digest
            {
                return Err(invalid());
            }
            if bytes.len() > MAXIMUM_RESOURCE_BYTES - byte_count {
                return Err(ProfileResourceError::TooLarge);
            }
            byte_count += bytes.len();
            entries.insert(digest.clone(), Arc::from(bytes));
        }
        let table = Self { entries };
        table.referenced_ids(object)?;
        Ok(Some(table))
    }

    /// Every lookup shares the validated immutable allocation, including aliases
    /// used by several states. No image decoding or Base64 expansion occurs here.
    pub fn data(&self, reference: &Value) -> Result<Arc<[u8]>, ProfileResourceError> {
        let object = reference
            .as_object()
            .ok_or(ProfileResourceError::InvalidEnvelope)?;
        let digest = object
            .get(REFERENCE)
            .and_then(Value::as_str)
            .filter(|_| object.len() == 1)
            .ok_or(ProfileResourceError::InvalidEnvelope)?;
        self.entries
            .get(digest)
            .cloned()
            .ok_or_else(|| ProfileResourceError::MissingResource(digest.to_owned()))
    }

    /// Apply after removing launch/local-only fields from a portable copy.
    /// Unknown metadata and resources still referenced by it remain untouched.
    pub fn pruning_unused(&self, profile: &Value) -> Result<Value, ProfileResourceError> {
        let object = profile
            .as_object()
            .ok_or(ProfileResourceError::InvalidEnvelope)?;
        let used = self.referenced_ids(object)?;
        let mut result = object.clone();
        let resources = result
            .get_mut(RESOURCES)
            .and_then(Value::as_object_mut)
            .ok_or(ProfileResourceError::InvalidEnvelope)?;
        resources.retain(|digest, _| used.contains(digest));
        Ok(Value::Object(result))
    }

    fn referenced_ids(
        &self,
        object: &Map<String, Value>,
    ) -> Result<BTreeSet<String>, ProfileResourceError> {
        let mut pending: Vec<_> = object
            .iter()
            .filter(|(key, _)| *key != RESOURCES)
            .map(|(_, v)| v)
            .collect();
        let mut used = BTreeSet::new();
        while let Some(node) = pending.pop() {
            match node {
                Value::Object(object) if object.contains_key(REFERENCE) => {
                    self.data(node)?;
                    used.insert(object[REFERENCE].as_str().unwrap().to_owned());
                }
                Value::Object(object) => pending.extend(object.values()),
                Value::Array(values) => pending.extend(values),
                _ => {}
            }
        }
        Ok(used)
    }
}
