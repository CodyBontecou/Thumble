//! Typed OAuth principals and protected resources.

use std::fmt;
use std::str::FromStr;

use rusqlite::types::{FromSql, FromSqlError, FromSqlResult, ToSqlOutput, ValueRef};
use rusqlite::{types::Value, ToSql};
use serde::{Deserialize, Deserializer, Serialize};

/// Maximum persisted principal identifier length.
pub const MAX_PRINCIPAL_ID_LEN: usize = 128;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PrincipalKind {
    Device,
    Builder,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ResourceKind {
    Relay,
    Builder,
}

macro_rules! sqlite_text_enum {
    ($type:ty, {$($variant:path => $text:literal),+ $(,)?}) => {
        impl fmt::Display for $type {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(match self {$($variant => $text),+})
            }
        }

        impl FromStr for $type {
            type Err = String;

            fn from_str(value: &str) -> Result<Self, Self::Err> {
                match value {$($text => Ok($variant),)+ _ => Err(format!("unknown {} value: {value}", stringify!($type))),}
            }
        }

        impl ToSql for $type {
            fn to_sql(&self) -> rusqlite::Result<ToSqlOutput<'_>> {
                Ok(ToSqlOutput::Owned(Value::Text(self.to_string())))
            }
        }

        impl FromSql for $type {
            fn column_result(value: ValueRef<'_>) -> FromSqlResult<Self> {
                let text = value.as_str()?;
                text.parse().map_err(|error: String| FromSqlError::Other(error.into()))
            }
        }
    };
}

sqlite_text_enum!(PrincipalKind, {
    PrincipalKind::Device => "device",
    PrincipalKind::Builder => "builder",
});
sqlite_text_enum!(ResourceKind, {
    ResourceKind::Relay => "relay",
    ResourceKind::Builder => "builder",
});

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
pub struct Principal {
    pub kind: PrincipalKind,
    pub id: String,
}

impl Principal {
    pub fn new(kind: PrincipalKind, id: impl Into<String>) -> Result<Self, String> {
        let id = id.into();
        validate_principal_id(&id)?;
        Ok(Self { kind, id })
    }

    pub fn validate(&self) -> Result<(), String> {
        validate_principal_id(&self.id)
    }

    pub fn device(id: impl Into<String>) -> Result<Self, String> {
        Self::new(PrincipalKind::Device, id)
    }

    pub fn builder(id: impl Into<String>) -> Result<Self, String> {
        Self::new(PrincipalKind::Builder, id)
    }
}

impl<'de> Deserialize<'de> for Principal {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct RawPrincipal {
            kind: PrincipalKind,
            id: String,
        }

        let raw = RawPrincipal::deserialize(deserializer)?;
        Principal::new(raw.kind, raw.id).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize)]
pub struct OAuthBinding {
    pub principal: Principal,
    pub resource: ResourceKind,
}

impl OAuthBinding {
    pub fn new(principal: Principal, resource: ResourceKind) -> Result<Self, String> {
        match (principal.kind, resource) {
            (PrincipalKind::Device, ResourceKind::Relay)
            | (PrincipalKind::Builder, ResourceKind::Builder) => Ok(Self {
                principal,
                resource,
            }),
            _ => Err("OAuth principal and resource kinds do not match".to_owned()),
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        self.principal.validate()?;
        match (self.principal.kind, self.resource) {
            (PrincipalKind::Device, ResourceKind::Relay)
            | (PrincipalKind::Builder, ResourceKind::Builder) => Ok(()),
            _ => Err("OAuth principal and resource kinds do not match".to_owned()),
        }
    }

    pub fn device_relay(device_id: impl Into<String>) -> Result<Self, String> {
        Self::new(Principal::device(device_id)?, ResourceKind::Relay)
    }

    pub fn builder(builder_id: impl Into<String>) -> Result<Self, String> {
        Self::new(Principal::builder(builder_id)?, ResourceKind::Builder)
    }
}

impl<'de> Deserialize<'de> for OAuthBinding {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct RawBinding {
            principal: Principal,
            resource: ResourceKind,
        }

        let raw = RawBinding::deserialize(deserializer)?;
        OAuthBinding::new(raw.principal, raw.resource).map_err(serde::de::Error::custom)
    }
}

fn validate_principal_id(id: &str) -> Result<(), String> {
    if id.is_empty() || id.len() > MAX_PRINCIPAL_ID_LEN {
        return Err(format!(
            "principal id must contain 1-{MAX_PRINCIPAL_ID_LEN} bytes"
        ));
    }
    if id.chars().any(char::is_control) {
        return Err("principal id must not contain control characters".to_owned());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn serde_and_sql_values_are_strict() {
        assert_eq!(
            serde_json::to_string(&PrincipalKind::Device).unwrap(),
            "\"device\""
        );
        assert!(serde_json::from_str::<PrincipalKind>("\"DEVICE\"").is_err());
        assert!(serde_json::from_str::<ResourceKind>("\"relay-extra\"").is_err());
        assert!("DEVICE".parse::<PrincipalKind>().is_err());
    }

    #[test]
    fn malformed_and_mixed_bindings_are_rejected() {
        assert!(Principal::device("").is_err());
        assert!(Principal::builder("x".repeat(MAX_PRINCIPAL_ID_LEN + 1)).is_err());
        assert!(
            OAuthBinding::new(Principal::device("dev_1").unwrap(), ResourceKind::Builder).is_err()
        );
        assert!(serde_json::from_str::<OAuthBinding>(
            r#"{"principal":{"kind":"builder","id":"builder_1"},"resource":"relay"}"#
        )
        .is_err());
        assert!(serde_json::from_str::<Principal>(
            r#"{"kind":"device","id":"dev_1","extra":true}"#
        )
        .is_err());
    }
}
