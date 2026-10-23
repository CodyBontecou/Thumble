//! Offline inspection only. Never construct OutputOwner or call Factory::create.
use serde::Serialize;
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    version: u8,
    kind: &'static str,
    platform: &'static str,
    backend: &'static str,
    physical_output_enabled: bool,
    runtime_integrated: bool,
    macos: Mac,
    windows: Windows,
    os_device_authorization: &'static str,
    gameplay_verified: bool,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Mac {
    dormant_adapter_compiled: bool,
    signed_claim: &'static str,
}
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Windows {
    candidate: &'static str,
    candidate_version: &'static str,
    upstream_commit: &'static str,
    profile: &'static str,
    sdk_linked: bool,
    backend_available: bool,
    driver: &'static str,
}
#[cfg(all(target_os = "macos", feature = "output-doctor-macos"))]
fn inspect(factory: &mut impl thumble_rewrite_output_core::Factory) -> &'static str {
    use thumble_rewrite_output_core::Fault;
    // Contract: this method remains a pure signed-claim inspection. No factory
    // create, output owner, native device or permission prompt is allowed here.
    match factory.authorization() {
        Ok(()) => "present",
        Err(Fault::MissingEntitlement) => "absent",
        Err(_) => "inspection-failed",
    }
}
pub fn capabilities() -> Capabilities {
    #[cfg(all(target_os = "macos", feature = "output-doctor-macos"))]
    let signed_claim = inspect(&mut thumble_rewrite_output_core::macos::MacFactory);
    #[cfg(all(target_os = "macos", not(feature = "output-doctor-macos")))]
    let signed_claim = "not-compiled";
    #[cfg(not(target_os = "macos"))]
    let signed_claim = "not-applicable";
    Capabilities {
        version: 1,
        kind: "output-capabilities",
        platform: if cfg!(target_os = "macos") {
            "macos"
        } else if cfg!(windows) {
            "windows"
        } else if cfg!(target_os = "linux") {
            "linux"
        } else {
            "unsupported"
        },
        backend: "recording",
        physical_output_enabled: false,
        runtime_integrated: false,
        macos: Mac {
            dormant_adapter_compiled: cfg!(all(
                target_os = "macos",
                feature = "output-doctor-macos"
            )),
            signed_claim,
        },
        windows: Windows {
            candidate: "hidmaestro",
            candidate_version: "2.0.3",
            upstream_commit: "63cc6481f9e82fc8600bda8aaa65cb3271113a19",
            profile: "xbox-360-wired",
            sdk_linked: false,
            backend_available: false,
            driver: "not-inspected",
        },
        os_device_authorization: "not-inspected",
        gameplay_verified: false,
    }
}
pub fn run(args: &[String]) -> Result<(), &'static str> {
    if args.len() != 1 || args[0] != "output-capabilities" {
        return Err("invalid_output_doctor_arguments");
    }
    println!(
        "{}",
        serde_json::to_string(&capabilities()).map_err(|_| "output_doctor_failed")?
    );
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn offline_capabilities_never_claim_output_authorization_or_driver_inspection() {
        let v = serde_json::to_value(capabilities()).unwrap();
        assert_eq!(v["backend"], "recording");
        assert_eq!(v["physicalOutputEnabled"], false);
        assert_eq!(v["runtimeIntegrated"], false);
        assert_eq!(v["osDeviceAuthorization"], "not-inspected");
        assert_eq!(v["gameplayVerified"], false);
        assert_eq!(v["windows"]["driver"], "not-inspected");
        assert_eq!(v["windows"]["sdkLinked"], false);
        assert_eq!(v["windows"]["backendAvailable"], false);
    }
    #[cfg(all(target_os = "macos", feature = "output-macos"))]
    #[test]
    fn macos_output_build_reports_its_compiled_adapter_without_activation() {
        let value = capabilities();
        assert!(value.macos.dormant_adapter_compiled);
        assert_ne!(value.macos.signed_claim, "not-compiled");
        assert!(!value.physical_output_enabled);
        assert!(!value.runtime_integrated);
        assert!(!value.gameplay_verified);
    }
    #[test]
    fn arguments_do_not_accept_directories_or_activation_flags() {
        assert_eq!(
            run(&["output-capabilities".into(), "--enable-input".into()]),
            Err("invalid_output_doctor_arguments")
        );
    }
    #[cfg(all(target_os = "macos", feature = "output-doctor-macos"))]
    #[test]
    fn claim_inspection_cannot_reach_device_constructor() {
        use thumble_rewrite_output_core::{Device, Factory, Fault};
        struct Fake(Result<(), Fault>);
        impl Factory for Fake {
            fn authorization(&mut self) -> Result<(), Fault> {
                self.0
            }
            fn create(&mut self) -> Result<Box<dyn Device>, Fault> {
                panic!("doctor must never create a device")
            }
        }
        assert_eq!(inspect(&mut Fake(Ok(()))), "present");
        assert_eq!(inspect(&mut Fake(Err(Fault::MissingEntitlement))), "absent");
        assert_eq!(
            inspect(&mut Fake(Err(Fault::Creation))),
            "inspection-failed"
        );
    }
}
