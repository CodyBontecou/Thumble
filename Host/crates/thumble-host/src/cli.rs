use crate::control::{
    send_request, AccessibilityAction, ControlRequest, ControlResponse, HostStatus,
};
use crate::paths::{HostPaths, CONTROL_SOCKET_ENV, STATE_DIR_ENV};
use crate::platform;
use crate::runtime::{instance_lock_held, run_runtime, RuntimeOptions};
use clap::{Args, Parser, Subcommand};
use fs2::FileExt;
use serde_json::json;
use std::fs::{File, OpenOptions};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::time::Duration;

#[derive(Debug, Parser)]
#[command(
    name = "thumble-host",
    version,
    about = "Standalone Thumble macOS receiver"
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<HostCommand>,
}

#[derive(Debug, Subcommand)]
pub enum HostCommand {
    /// Run the receiver in the foreground.
    Run(RuntimeArgs),
    /// Start a detached per-user receiver.
    Start(RuntimeArgs),
    /// Stop the running receiver.
    Stop,
    /// Restart the detached receiver, preserving active runtime options.
    Restart,
    /// Show receiver status.
    Status {
        #[arg(long)]
        json: bool,
    },
    /// Show or rotate the six-digit pairing code.
    PairingCode {
        #[arg(long)]
        rotate: bool,
        #[arg(long)]
        json: bool,
    },
    /// Inspect or request macOS Accessibility permission.
    Accessibility(AccessibilityArgs),
    /// List installed profiles.
    Profiles {
        #[arg(long)]
        json: bool,
    },
    /// List executable controls in the active profile.
    Controls {
        #[arg(long)]
        json: bool,
    },
    /// Select an installed profile by ID.
    SelectProfile {
        profile_id: String,
        #[arg(long)]
        json: bool,
    },
    /// Tap an exact opaque ID returned by `controls`.
    PressControl {
        control_id: String,
        #[arg(long)]
        json: bool,
    },
    /// Release every keyboard and pointer hold.
    ReleaseAll,
}

#[derive(Debug, Clone, Copy, Args)]
pub struct RuntimeArgs {
    #[arg(long, default_value_t = 8765)]
    pub port: u16,
    #[arg(long)]
    pub no_bonjour: bool,
    #[arg(long)]
    pub no_input: bool,
    /// Allow revision-checked configuration draft commits.
    #[arg(long)]
    pub allow_config_write: bool,
}

impl Default for RuntimeArgs {
    fn default() -> Self {
        Self {
            port: 8765,
            no_bonjour: false,
            no_input: false,
            allow_config_write: false,
        }
    }
}

impl From<RuntimeArgs> for RuntimeOptions {
    fn from(arguments: RuntimeArgs) -> Self {
        Self {
            port: arguments.port,
            bonjour: !arguments.no_bonjour,
            input: !arguments.no_input,
            configuration_write: arguments.allow_config_write,
        }
    }
}

#[derive(Debug, Args)]
pub struct AccessibilityArgs {
    #[command(subcommand)]
    pub action: AccessibilityCommand,
    #[arg(long, global = true)]
    pub json: bool,
}

#[derive(Debug, Clone, Copy, Subcommand)]
pub enum AccessibilityCommand {
    Status,
    Prompt,
    Open,
}

pub async fn execute(cli: Cli, paths: HostPaths) -> Result<(), String> {
    match cli
        .command
        .unwrap_or(HostCommand::Run(RuntimeArgs::default()))
    {
        HostCommand::Run(arguments) => run_runtime(paths, arguments.into()).await,
        HostCommand::Start(arguments) => detached_start(&paths, arguments.into()).await,
        HostCommand::Stop => stop(&paths).await,
        HostCommand::Restart => restart(&paths).await,
        HostCommand::Status { json } => status(&paths, json).await,
        HostCommand::PairingCode { rotate, json } => pairing_code(&paths, rotate, json).await,
        HostCommand::Accessibility(arguments) => accessibility(&paths, arguments).await,
        HostCommand::Profiles { json } => profiles(&paths, json).await,
        HostCommand::Controls { json } => controls(&paths, json).await,
        HostCommand::SelectProfile { profile_id, json } => {
            select_profile(&paths, profile_id, json).await
        }
        HostCommand::PressControl { control_id, json } => {
            press_control(&paths, control_id, json).await
        }
        HostCommand::ReleaseAll => release_all(&paths).await,
    }
}

async fn detached_start(paths: &HostPaths, options: RuntimeOptions) -> Result<(), String> {
    let _start_guard = StartGuard::acquire(paths)?;
    if instance_lock_held(paths)? {
        return Err("Thumble Host is already running".to_owned());
    }
    paths
        .ensure_state_dir()
        .map_err(|error| format!("create host state directory: {error}"))?;
    let executable = std::env::current_exe()
        .and_then(std::fs::canonicalize)
        .map_err(|error| format!("resolve stable host executable path: {error}"))?;
    let log = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(&paths.log_file)
        .map_err(|error| format!("open detached host log: {error}"))?;
    std::fs::set_permissions(&paths.log_file, std::fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("protect detached host log: {error}"))?;
    let error_log = log
        .try_clone()
        .map_err(|error| format!("clone detached host log: {error}"))?;
    let mut command = Command::new(executable);
    command
        .arg("run")
        .arg("--port")
        .arg(options.port.to_string())
        .env(STATE_DIR_ENV, &paths.state_dir)
        .env(CONTROL_SOCKET_ENV, &paths.control_socket)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(error_log));
    if !options.bonjour {
        command.arg("--no-bonjour");
    }
    if !options.input {
        command.arg("--no-input");
    }
    if options.configuration_write {
        command.arg("--allow-config-write");
    }
    // SAFETY: pre_exec performs only the async-signal-safe setsid syscall.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(std::io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command
        .spawn()
        .map_err(|error| format!("start detached host: {error}"))?;

    for _ in 0..50 {
        if let Ok(response) = send_request(&paths.control_socket, &ControlRequest::Status).await {
            if response.ok {
                let port = response.status.map_or(options.port, |status| status.port);
                println!("Thumble Host started on port {port}");
                return Ok(());
            }
        }
        if let Some(status) = child
            .try_wait()
            .map_err(|error| format!("inspect detached host: {error}"))?
        {
            return Err(format!(
                "detached Thumble Host exited with {status}; see {}",
                paths.log_file.display()
            ));
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    let _ = child.kill();
    let _ = child.wait();
    Err(format!(
        "detached Thumble Host did not become ready and was terminated; see {}",
        paths.log_file.display()
    ))
}

async fn stop(paths: &HostPaths) -> Result<(), String> {
    let response = match send_request(&paths.control_socket, &ControlRequest::Stop).await {
        Ok(response) => response,
        Err(_) if !instance_lock_held(paths)? => {
            println!("Thumble Host is not running");
            return Ok(());
        }
        Err(error) => return Err(error),
    };
    require_ok(response)?;
    for _ in 0..50 {
        if !instance_lock_held(paths)? {
            println!("Thumble Host stopped");
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    Err("Thumble Host did not stop within 5 seconds".to_owned())
}

async fn restart(paths: &HostPaths) -> Result<(), String> {
    let existing = send_request(&paths.control_socket, &ControlRequest::Status)
        .await
        .ok()
        .and_then(|response| response.status);
    if existing.is_some() {
        stop(paths).await?;
    }
    let options = existing.map_or_else(RuntimeOptions::default, |status| RuntimeOptions {
        port: status.requested_port,
        bonjour: status.bonjour.enabled,
        input: status.input_enabled,
        configuration_write: status.configuration_write_enabled,
    });
    detached_start(paths, options).await
}

async fn status(paths: &HostPaths, json_output: bool) -> Result<(), String> {
    match send_request(&paths.control_socket, &ControlRequest::Status).await {
        Ok(response) => {
            let response = require_ok(response)?;
            let status = response
                .status
                .ok_or_else(|| "host returned no status".to_owned())?;
            if json_output {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&status)
                        .map_err(|error| format!("encode status: {error}"))?
                );
            } else {
                print_human_status(&status);
            }
            Ok(())
        }
        Err(_) if !instance_lock_held(paths)? => {
            if json_output {
                println!("{}", json!({"running": false}));
            } else {
                println!("Thumble Host is not running");
            }
            Ok(())
        }
        Err(error) => Err(error),
    }
}

async fn pairing_code(paths: &HostPaths, rotate: bool, json_output: bool) -> Result<(), String> {
    let response = require_ok(
        send_request(
            &paths.control_socket,
            &ControlRequest::PairingCode { rotate },
        )
        .await?,
    )?;
    let code = response
        .pairing_code
        .ok_or_else(|| "host returned no pairing code".to_owned())?;
    if json_output {
        println!("{}", json!({"pairingCode": code, "rotated": rotate}));
    } else {
        println!("{code}");
    }
    Ok(())
}

async fn accessibility(paths: &HostPaths, arguments: AccessibilityArgs) -> Result<(), String> {
    let action = match arguments.action {
        AccessibilityCommand::Status => AccessibilityAction::Status,
        AccessibilityCommand::Prompt => AccessibilityAction::Prompt,
        AccessibilityCommand::Open => AccessibilityAction::Open,
    };
    let trusted = match send_request(
        &paths.control_socket,
        &ControlRequest::Accessibility { action },
    )
    .await
    {
        Ok(response) => require_ok(response)?.accessibility_trusted,
        Err(_) if !instance_lock_held(paths)? => Some(match action {
            AccessibilityAction::Status => platform::accessibility_trusted(),
            AccessibilityAction::Prompt => platform::prompt_accessibility(),
            AccessibilityAction::Open => {
                platform::open_accessibility_settings()?;
                platform::accessibility_trusted()
            }
        }),
        Err(error) => return Err(error),
    }
    .unwrap_or_else(platform::accessibility_trusted);
    if arguments.json {
        println!("{}", json!({"trusted": trusted}));
    } else {
        println!(
            "Accessibility: {}",
            if trusted { "trusted" } else { "not trusted" }
        );
    }
    Ok(())
}

async fn profiles(paths: &HostPaths, json_output: bool) -> Result<(), String> {
    let response =
        require_ok(send_request(&paths.control_socket, &ControlRequest::ListProfiles).await?)?;
    let active_profile_id = response.active_profile_id.unwrap_or_default();
    let profiles = response.profiles.unwrap_or_default();
    if json_output {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "activeProfileID": active_profile_id,
                "profiles": profiles
            }))
            .map_err(|error| format!("encode profiles: {error}"))?
        );
    } else {
        for profile in profiles {
            let markers = match (profile.active, profile.default) {
                (true, true) => " [active, default]",
                (true, false) => " [active]",
                (false, true) => " [default]",
                (false, false) => "",
            };
            println!("{}\t{}{}", profile.id, profile.name, markers);
        }
    }
    Ok(())
}

async fn controls(paths: &HostPaths, json_output: bool) -> Result<(), String> {
    let response =
        require_ok(send_request(&paths.control_socket, &ControlRequest::ListControls).await?)?;
    let active_profile_id = response.active_profile_id.unwrap_or_default();
    let controls = response.controls.unwrap_or_default();
    if json_output {
        println!(
            "{}",
            serde_json::to_string_pretty(&json!({
                "activeProfileID": active_profile_id,
                "controls": controls
            }))
            .map_err(|error| format!("encode controls: {error}"))?
        );
    } else {
        for control in controls {
            let part = serde_json::to_value(control.part)
                .ok()
                .and_then(|value| value.as_str().map(str::to_owned))
                .unwrap_or_else(|| "unknown".to_owned());
            println!(
                "{}\t{}\t{}:{part}",
                control.control_id, control.label, control.kind
            );
        }
    }
    Ok(())
}

async fn select_profile(
    paths: &HostPaths,
    profile_id: String,
    json_output: bool,
) -> Result<(), String> {
    let response = require_ok(
        send_request(
            &paths.control_socket,
            &ControlRequest::SelectProfile { profile_id },
        )
        .await?,
    )?;
    let selected = response.selected_profile_id.unwrap_or_default();
    let changed = response.profile_changed.unwrap_or(false);
    if json_output {
        println!("{}", json!({"profileID": selected, "changed": changed}));
    } else {
        println!("Selected profile {selected}");
    }
    Ok(())
}

async fn press_control(
    paths: &HostPaths,
    control_id: String,
    json_output: bool,
) -> Result<(), String> {
    let response = require_ok(
        send_request(
            &paths.control_socket,
            &ControlRequest::PressControl { control_id },
        )
        .await?,
    )?;
    let pressed = response.pressed_control_id.unwrap_or_default();
    if json_output {
        println!("{}", json!({"controlID": pressed, "executed": true}));
    } else {
        println!("Pressed control {pressed}");
    }
    Ok(())
}

async fn release_all(paths: &HostPaths) -> Result<(), String> {
    let response =
        require_ok(send_request(&paths.control_socket, &ControlRequest::ReleaseAll).await?)?;
    if response.released == Some(true) {
        println!("Released all Thumble input");
    }
    Ok(())
}

struct StartGuard(File);

impl StartGuard {
    fn acquire(paths: &HostPaths) -> Result<Self, String> {
        paths
            .ensure_state_dir()
            .map_err(|error| format!("create host state directory: {error}"))?;
        let path = paths.state_dir.join("start.lock");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .open(&path)
            .map_err(|error| format!("open lifecycle lock: {error}"))?;
        file.try_lock_exclusive()
            .map_err(|_| "Thumble Host start is already in progress".to_owned())?;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
            .map_err(|error| format!("protect lifecycle lock: {error}"))?;
        Ok(Self(file))
    }
}

impl Drop for StartGuard {
    fn drop(&mut self) {
        let _ = FileExt::unlock(&self.0);
    }
}

fn require_ok(response: ControlResponse) -> Result<ControlResponse, String> {
    if response.ok {
        Ok(response)
    } else {
        Err(response
            .error
            .unwrap_or_else(|| "host control request failed".to_owned()))
    }
}

fn print_human_status(status: &HostStatus) {
    println!(
        "Thumble Host {} (pid {})",
        if status.core.running {
            "is running"
        } else {
            "is stopping"
        },
        status.pid
    );
    println!("Port: {}", status.port);
    println!("Pairing code: {}", status.pairing_code);
    println!(
        "Service: {} ({})",
        status.service_name, status.bonjour.state
    );
    println!(
        "Accessibility: {}",
        if status.accessibility_trusted {
            "trusted"
        } else {
            "not trusted"
        }
    );
    println!("Client: {}", status.core.status_text);
    for url in &status.urls {
        println!("URL: {url}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn no_subcommand_means_foreground_run_with_defaults() {
        let cli = Cli::try_parse_from(["thumble-host"]).unwrap();
        assert!(cli.command.is_none());
        let command = cli
            .command
            .unwrap_or(HostCommand::Run(RuntimeArgs::default()));
        let HostCommand::Run(arguments) = command else {
            panic!("default command must be run");
        };
        assert_eq!(arguments.port, 8765);
        assert!(!arguments.no_bonjour);
        assert!(!arguments.no_input);
        assert!(!arguments.allow_config_write);
    }

    #[test]
    fn explicit_runtime_flags_parse_for_run_and_start() {
        for subcommand in ["run", "start"] {
            let cli = Cli::try_parse_from([
                "thumble-host",
                subcommand,
                "--port",
                "0",
                "--no-bonjour",
                "--no-input",
                "--allow-config-write",
            ])
            .unwrap();
            let arguments = match cli.command.unwrap() {
                HostCommand::Run(arguments) | HostCommand::Start(arguments) => arguments,
                _ => panic!("runtime command expected"),
            };
            assert_eq!(arguments.port, 0);
            assert!(arguments.no_bonjour);
            assert!(arguments.no_input);
            assert!(arguments.allow_config_write);
        }
    }

    #[test]
    fn profile_and_control_commands_parse_opaque_ids() {
        let cli =
            Cli::try_parse_from(["thumble-host", "select-profile", "profile-a", "--json"]).unwrap();
        let HostCommand::SelectProfile { profile_id, json } = cli.command.unwrap() else {
            panic!("select-profile command expected");
        };
        assert_eq!(profile_id, "profile-a");
        assert!(json);

        let cli = Cli::try_parse_from(["thumble-host", "press-control", "element:id#joystick_up"])
            .unwrap();
        let HostCommand::PressControl { control_id, json } = cli.command.unwrap() else {
            panic!("press-control command expected");
        };
        assert_eq!(control_id, "element:id#joystick_up");
        assert!(!json);
    }

    #[test]
    fn accessibility_json_is_accepted_after_nested_action() {
        let cli =
            Cli::try_parse_from(["thumble-host", "accessibility", "status", "--json"]).unwrap();
        let HostCommand::Accessibility(arguments) = cli.command.unwrap() else {
            panic!("accessibility command expected");
        };
        assert!(arguments.json);
    }
}
