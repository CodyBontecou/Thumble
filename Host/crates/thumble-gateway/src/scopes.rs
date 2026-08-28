//! Per-tool scope model enforced by the gateway before any tool call is
//! forwarded through a device tunnel.
//!
//! The gateway scope check is the OUTER gate. The device-side
//! `--allow-input` / `--allow-config-write` flags remain the independent
//! fail-closed INNER gate; both must allow a privileged action.

pub const SCOPE_READ: &str = "thumble.read";
pub const SCOPE_DRAFT: &str = "thumble.draft";
pub const SCOPE_CONFIG: &str = "thumble.config";
pub const SCOPE_INPUT: &str = "thumble.input";
pub const SCOPE_OFFLINE_ACCESS: &str = "offline_access";

/// Tools that are never reachable through the remote relay regardless of
/// granted scope: `pairing_code` and `release_all` belong to the local
/// phone/lifecycle flow, and input injection is not grantable in v1.
const REMOTE_BLOCKED: &[&str] = &["pairing_code", "press_control", "release_all"];

fn tool_scope(tool: &str) -> Option<&'static str> {
    Some(match tool {
        "host_status"
        | "accessibility_status"
        | "configuration_status"
        | "list_profiles"
        | "list_controls"
        | "render_controller"
        | "query_catalog" => SCOPE_READ,
        "begin_configuration_draft"
        | "get_configuration_draft"
        | "edit_configuration_draft"
        | "rebase_configuration_draft"
        | "validate_configuration_draft"
        | "preview_configuration_draft"
        | "export_controller_preview"
        | "discard_configuration_draft" => SCOPE_DRAFT,
        "save_configuration_draft" | "select_profile" => SCOPE_CONFIG,
        _ => return None,
    })
}

/// Parse a space-delimited scope string into an ordered, deduplicated set of
/// known scopes. Unknown scopes are rejected to avoid silent over-granting.
pub fn parse_scopes(requested: &str) -> Result<Vec<String>, String> {
    let mut granted: Vec<String> = Vec::new();
    for scope in requested.split_whitespace() {
        match scope {
            SCOPE_READ | SCOPE_DRAFT | SCOPE_CONFIG | SCOPE_OFFLINE_ACCESS => {
                if !granted.iter().any(|s| s == scope) {
                    granted.push(scope.to_owned());
                }
            }
            SCOPE_INPUT => {
                return Err(format!(
                    "scope {SCOPE_INPUT} cannot be granted to remote connectors"
                ));
            }
            other => return Err(format!("unknown scope: {other}")),
        }
    }
    // draft implies read; config implies draft and read.
    if granted.iter().any(|s| s == SCOPE_CONFIG) && !granted.iter().any(|s| s == SCOPE_DRAFT) {
        granted.push(SCOPE_DRAFT.to_owned());
    }
    if granted.iter().any(|s| s == SCOPE_DRAFT) && !granted.iter().any(|s| s == SCOPE_READ) {
        granted.push(SCOPE_READ.to_owned());
    }
    if granted.is_empty() {
        granted.push(SCOPE_READ.to_owned());
    }
    Ok(granted)
}

/// Is `tool` callable with the granted scope set?
pub fn tool_allowed(tool: &str, granted_scopes: &str) -> Result<(), String> {
    if REMOTE_BLOCKED.contains(&tool) {
        return Err(format!(
            "tool {tool} is not available to remote connectors; it is local-only"
        ));
    }
    let required = tool_scope(tool)
        .ok_or_else(|| format!("unknown tool {tool}; use tools/list for the canonical catalog"))?;
    let granted = granted_scopes.split_whitespace().collect::<Vec<_>>();
    if granted.iter().any(|scope| scope == &required) {
        Ok(())
    } else {
        Err(format!(
            "tool {tool} requires the {required} scope, which this connection did not grant \
             (granted: {}); re-add the Thumble connector in ChatGPT and include {required} in the \
             requested scopes during authorization",
            if granted_scopes.is_empty() {
                "none"
            } else {
                granted_scopes
            }
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_tools_are_default_scope() {
        for tool in [
            "host_status",
            "accessibility_status",
            "configuration_status",
            "list_profiles",
            "list_controls",
            "render_controller",
            "query_catalog",
        ] {
            assert!(tool_allowed(tool, SCOPE_READ).is_ok());
        }
    }

    #[test]
    fn draft_tools_require_draft_scope() {
        assert!(tool_allowed("begin_configuration_draft", SCOPE_READ).is_err());
        assert!(tool_allowed("begin_configuration_draft", SCOPE_DRAFT).is_ok());
        assert!(tool_allowed("preview_configuration_draft", SCOPE_DRAFT).is_ok());
        assert!(tool_allowed("export_controller_preview", SCOPE_DRAFT).is_ok());
    }

    #[test]
    fn config_tools_require_config_scope() {
        assert!(tool_allowed("save_configuration_draft", SCOPE_DRAFT).is_err());
        assert!(tool_allowed("save_configuration_draft", SCOPE_CONFIG).is_ok());
        assert!(tool_allowed("select_profile", SCOPE_CONFIG).is_ok());
    }

    #[test]
    fn local_only_tools_are_blocked_at_any_scope() {
        for tool in ["pairing_code", "press_control", "release_all"] {
            assert!(tool_allowed(tool, SCOPE_CONFIG).is_err());
            assert!(tool_allowed(tool, SCOPE_INPUT).is_err());
        }
    }

    #[test]
    fn unknown_tools_are_rejected() {
        assert!(tool_allowed("run_shell", SCOPE_CONFIG).is_err());
    }

    #[test]
    fn scope_parsing_implies_and_rejects() {
        assert_eq!(
            parse_scopes(SCOPE_CONFIG).unwrap(),
            vec![SCOPE_CONFIG, SCOPE_DRAFT, SCOPE_READ]
        );
        assert_eq!(
            parse_scopes(SCOPE_DRAFT).unwrap(),
            vec![SCOPE_DRAFT, SCOPE_READ]
        );
        assert_eq!(parse_scopes("").unwrap(), vec![SCOPE_READ]);
        assert!(parse_scopes(SCOPE_INPUT).is_err());
        assert_eq!(
            parse_scopes("thumble.read offline_access").unwrap(),
            vec![SCOPE_READ, SCOPE_OFFLINE_ACCESS]
        );
        assert!(parse_scopes("thumble.admin").is_err());
        // Deduplicated.
        assert_eq!(
            parse_scopes("thumble.read thumble.read").unwrap(),
            vec![SCOPE_READ]
        );
    }
}
