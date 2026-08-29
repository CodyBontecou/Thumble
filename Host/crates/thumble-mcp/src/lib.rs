mod channel;
mod rate_limit;
pub mod relay;
pub mod server;
mod skin_preview;

pub use channel::{HostChannel, SharedHostChannel, UnixHostChannel};

use std::ffi::OsStr;

pub use server::ThumbleMcp;

/// Input injection is fail-closed. Only the exact value `1` enables the
/// environment opt-in; values such as `true`, an empty string, or malformed
/// Unicode remain disabled.
pub fn environment_allows_input(value: Option<&OsStr>) -> bool {
    value == Some(OsStr::new("1"))
}

/// The canonical Thumble setting takes precedence whenever it is present.
/// The legacy setting is accepted only to avoid silently changing an existing
/// local client configuration.
pub fn environment_allows_input_with_legacy(
    canonical: Option<&OsStr>,
    legacy: Option<&OsStr>,
) -> bool {
    environment_allows_input(canonical.or(legacy))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn input_environment_opt_in_is_exact_and_fail_closed() {
        assert!(environment_allows_input(Some(OsStr::new("1"))));
        for value in [
            None,
            Some(OsStr::new("")),
            Some(OsStr::new("true")),
            Some(OsStr::new("0")),
        ] {
            assert!(!environment_allows_input(value));
        }
    }

    #[test]
    fn canonical_input_environment_takes_precedence_over_legacy_alias() {
        assert!(environment_allows_input_with_legacy(
            None,
            Some(OsStr::new("1"))
        ));
        assert!(!environment_allows_input_with_legacy(
            Some(OsStr::new("0")),
            Some(OsStr::new("1"))
        ));
    }
}
