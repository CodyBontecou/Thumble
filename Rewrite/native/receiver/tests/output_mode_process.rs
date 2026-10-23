//! Rejection paths only. These tests never request a physical output device.
use std::process::Command;
fn receiver(arguments: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_thumble-rewrite-receiver"))
        .args(arguments)
        .output()
        .unwrap()
}
#[test]
fn physical_mode_requires_exact_explicit_flag_before_opening_any_runtime() {
    for arguments in [
        vec!["run-macos-hid"],
        vec!["run-macos-hid", "/unused-runtime"],
        vec!["run-macos-hid", "/unused-runtime", "recording.jsonl"],
        vec![
            "run-macos-hid",
            "/unused-runtime",
            "--allow-physical-output",
            "extra",
        ],
    ] {
        let result = receiver(&arguments);
        assert!(!result.status.success());
        assert_eq!(result.stderr, b"physical_output_explicit_flag_required\n");
        assert!(result.stdout.is_empty());
    }
}
#[cfg(not(all(target_os = "macos", feature = "output-macos")))]
#[test]
fn unbuilt_physical_mode_fails_closed_even_with_explicit_flag() {
    let result = receiver(&[
        "run-macos-hid",
        "/unused-runtime",
        "--allow-physical-output",
    ]);
    assert!(!result.status.success());
    assert_eq!(result.stderr, b"physical_output_not_built\n");
    assert!(result.stdout.is_empty());
}
