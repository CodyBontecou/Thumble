use crate::cli_profile::ProfileSelector;
use crate::skins::SkinReference;
use serde::{Deserialize, Serialize};

/// Local IPC and authenticated phone requests share the same receiver authority.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "kebab-case", deny_unknown_fields)]
pub enum SkinCommand {
    List,
    Import {
        archive: String,
        #[serde(default = "newer_only")]
        policy: String,
    },
    Export {
        reference: SkinReference,
    },
    Apply {
        reference: SkinReference,
        profile: ProfileSelector,
        #[serde(default = "light")]
        appearance: String,
    },
    Detach {
        profile: ProfileSelector,
        #[serde(default = "light")]
        appearance: String,
    },
    Remove {
        reference: SkinReference,
    },
}
fn light() -> String {
    "light".into()
}

fn newer_only() -> String {
    "newerOnly".into()
}
