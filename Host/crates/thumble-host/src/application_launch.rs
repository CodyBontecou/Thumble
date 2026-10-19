//! One in-flight application launch. Resolution and activation never own the input mutex.
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::PathBuf;
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

#[derive(Clone)]
pub struct ApplicationTarget {
    pub(crate) bookmark: Option<String>,
    pub(crate) path: Option<String>,
    pub(crate) bundle: Option<String>,
}

impl ApplicationTarget {
    pub fn from_profile(profile: &Value) -> Result<Self, &'static str> {
        let target = profile
            .get("launchTarget")
            .filter(|v| v.is_object())
            .ok_or("no_launch_target")?;
        if target
            .get("kind")
            .and_then(Value::as_str)
            .unwrap_or("application")
            != "application"
        {
            return Err("unsupported_launch_target");
        }
        fn text(value: &Value, key: &str, limit: usize) -> Result<Option<String>, &'static str> {
            let Some(value) = value.get(key).filter(|v| !v.is_null()) else {
                return Ok(None);
            };
            let value = value.as_str().ok_or("invalid_launch_target")?.trim();
            if value.len() > limit || value.contains('\0') {
                return Err("invalid_launch_target");
            }
            Ok((!value.is_empty()).then(|| value.to_owned()))
        }
        let target = Self {
            bookmark: text(target, "bookmarkData", 1024 * 1024)?,
            path: text(target, "filePath", 32 * 1024)?,
            bundle: text(target, "bundleIdentifier", 1024)?,
        };
        if target.bookmark.is_none() && target.path.is_none() && target.bundle.is_none() {
            return Err("application_not_found");
        }
        Ok(target)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum LaunchPhase {
    Resolving,
    ReleasingInput,
    Launched,
    Failed,
}

/// No paths, bookmarks, application names, or platform diagnostic strings leave the worker.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchStatus {
    #[serde(rename = "launchID")]
    pub launch_id: String,
    #[serde(rename = "profileID")]
    pub profile_id: String,
    pub phase: LaunchPhase,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
}

#[derive(Default)]
struct State {
    status: Option<LaunchStatus>,
    busy: bool,
    ready: Option<mpsc::SyncSender<bool>>,
}

#[derive(Default)]
pub struct ApplicationLauncher {
    state: Arc<Mutex<State>>,
}

impl ApplicationLauncher {
    pub fn status(&self) -> Option<LaunchStatus> {
        self.state
            .lock()
            .expect("launch mutex poisoned")
            .status
            .clone()
    }

    pub fn record_failure(&self, profile_id: String, code: &'static str) {
        let mut state = self.state.lock().expect("launch mutex poisoned");
        if !state.busy {
            state.status = Some(LaunchStatus {
                launch_id: uuid::Uuid::new_v4().to_string(),
                profile_id,
                phase: LaunchPhase::Failed,
                error_code: Some(code.into()),
            });
        }
    }

    pub fn request(
        &self,
        profile_id: String,
        target: ApplicationTarget,
    ) -> Result<LaunchStatus, &'static str> {
        self.request_using(
            profile_id,
            target,
            crate::platform::resolve_application,
            crate::platform::open_application,
        )
    }

    fn request_using(
        &self,
        profile_id: String,
        target: ApplicationTarget,
        resolve: impl FnOnce(&ApplicationTarget) -> Result<PathBuf, &'static str> + Send + 'static,
        open: impl FnOnce(&std::path::Path) -> Result<(), &'static str> + Send + 'static,
    ) -> Result<LaunchStatus, &'static str> {
        let mut state = self.state.lock().expect("launch mutex poisoned");
        if state.busy {
            return Err("application_launch_busy");
        }
        let status = LaunchStatus {
            launch_id: uuid::Uuid::new_v4().to_string(),
            profile_id,
            phase: LaunchPhase::Resolving,
            error_code: None,
        };
        state.busy = true;
        state.status = Some(status.clone());
        let shared = self.state.clone();
        if std::thread::Builder::new()
            .name("application-launch".into())
            .spawn(move || {
                let result = resolve(&target).and_then(|path| {
                    let (send, receive) = mpsc::sync_channel(1);
                    {
                        let mut state = shared.lock().expect("launch mutex poisoned");
                        state.status.as_mut().unwrap().phase = LaunchPhase::ReleasingInput;
                        state.ready = Some(send);
                    }
                    match receive.recv_timeout(Duration::from_secs(10)) {
                        Ok(true) => open(&path),
                        Ok(false) => Err("input_release_failed"),
                        Err(_) => Err("application_launch_timed_out"),
                    }
                });
                let mut state = shared.lock().expect("launch mutex poisoned");
                state.ready = None;
                state.busy = false;
                let status = state.status.as_mut().unwrap();
                match result {
                    Ok(()) => status.phase = LaunchPhase::Launched,
                    Err(code) => {
                        status.phase = LaunchPhase::Failed;
                        status.error_code = Some(code.into());
                    }
                }
            })
            .is_err()
        {
            state.busy = false;
            let status = state.status.as_mut().unwrap();
            status.phase = LaunchPhase::Failed;
            status.error_code = Some("application_launch_worker_failed".into());
            return Err("application_launch_worker_failed");
        }
        Ok(status)
    }

    /// Runtime must neutralize input before permitting the worker to activate the application.
    pub fn take_ready(&self) -> Option<mpsc::SyncSender<bool>> {
        self.state
            .lock()
            .expect("launch mutex poisoned")
            .ready
            .take()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn target() -> ApplicationTarget {
        ApplicationTarget::from_profile(&json!({"launchTarget":{"filePath":"/fixture/App.app"}}))
            .unwrap()
    }
    fn wait(launcher: &ApplicationLauncher, phase: LaunchPhase) {
        let deadline = std::time::Instant::now() + Duration::from_secs(2);
        while launcher.status().unwrap().phase != phase {
            assert!(
                std::time::Instant::now() < deadline,
                "launch worker timed out"
            );
            std::thread::sleep(Duration::from_millis(2));
        }
    }
    #[test]
    fn activation_waits_for_neutralization_and_rejects_concurrent_launches() {
        let launcher = ApplicationLauncher::default();
        let (sent, received) = mpsc::channel();
        let first = launcher
            .request_using(
                "profile".into(),
                target(),
                |_| Ok(PathBuf::from("/fixture/App.app")),
                move |_| {
                    sent.send(()).unwrap();
                    Ok(())
                },
            )
            .unwrap();
        wait(&launcher, LaunchPhase::ReleasingInput);
        assert_eq!(
            launcher.request_using(
                "other".into(),
                target(),
                |_| unreachable!(),
                |_| unreachable!()
            ),
            Err("application_launch_busy")
        );
        assert!(received.try_recv().is_err());
        launcher.take_ready().unwrap().send(true).unwrap();
        received.recv_timeout(Duration::from_secs(2)).unwrap();
        wait(&launcher, LaunchPhase::Launched);
        assert_eq!(launcher.status().unwrap().launch_id, first.launch_id);
        assert!(!serde_json::to_string(&launcher.status())
            .unwrap()
            .contains("fixture"));
    }
    #[test]
    fn failed_resolution_does_not_request_input_release() {
        let launcher = ApplicationLauncher::default();
        launcher
            .request_using(
                "profile".into(),
                target(),
                |_| Err("application_not_found"),
                |_| unreachable!(),
            )
            .unwrap();
        wait(&launcher, LaunchPhase::Failed);
        assert!(launcher.take_ready().is_none());
        assert_eq!(
            launcher.status().unwrap().error_code.as_deref(),
            Some("application_not_found")
        );
    }
    #[test]
    fn failed_neutralization_prevents_activation_and_can_retry() {
        let launcher = ApplicationLauncher::default();
        for _ in 0..2 {
            launcher
                .request_using(
                    "profile".into(),
                    target(),
                    |_| Ok(PathBuf::new()),
                    |_| unreachable!(),
                )
                .unwrap();
            wait(&launcher, LaunchPhase::ReleasingInput);
            launcher.take_ready().unwrap().send(false).unwrap();
            wait(&launcher, LaunchPhase::Failed);
            assert_eq!(
                launcher.status().unwrap().error_code.as_deref(),
                Some("input_release_failed")
            );
        }
    }
    #[test]
    fn parses_only_bounded_application_target_metadata() {
        assert!(ApplicationTarget::from_profile(&json!({})).is_err());
        assert!(ApplicationTarget::from_profile(
            &json!({"launchTarget":{"kind":"url","filePath":"https://example.com"}})
        )
        .is_err());
        assert!(
            ApplicationTarget::from_profile(&json!({"launchTarget":{"filePath":123}})).is_err()
        );
        assert!(ApplicationTarget::from_profile(
            &json!({"launchTarget":{"bookmarkData":"x".repeat(1024*1024+1)}})
        )
        .is_err());
        let t = ApplicationTarget::from_profile(&json!({"launchTarget":{"bookmarkData":"bookmark","filePath":" /fixture/App.app ","bundleIdentifier":"com.fixture.App","iconPNGData":"ignored"}})).unwrap();
        assert_eq!(t.path.as_deref(), Some("/fixture/App.app"));
        assert_eq!(t.bundle.as_deref(), Some("com.fixture.App"));
        assert_eq!(t.bookmark.as_deref(), Some("bookmark"));
    }
}
