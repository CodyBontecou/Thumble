use std::io;
use thumble_rewrite_wow_capture_windows::wire;
fn run() -> Result<(), &'static str> {
    let arguments = std::env::args().skip(1).collect::<Vec<_>>();
    #[cfg(windows)]
    {
        use thumble_rewrite_wow_capture_windows::{
            windows::{permission, Apartment, NativeProvider},
            Session,
        };
        let _apartment = Apartment::initialize().map_err(|_| "capture_unavailable")?;
        if arguments.is_empty()
            || arguments == ["--status"]
            || arguments == ["--request-permission"]
        {
            let request = arguments == ["--request-permission"];
            let command = if request {
                "wow-capture-permission-result"
            } else {
                "wow-capture-permission-status"
            };
            let bytes = serde_json::to_vec(
                &serde_json::json!({"version":1,"command":command,"status":permission(request)}),
            )
            .map_err(|_| "capture_unavailable")?;
            return wire::write_frame(&mut io::stdout().lock(), &bytes);
        }
        if arguments != ["--capture"] {
            return Err("invalid_capture_arguments");
        }
        let (mut session, mut provider) = (Session::default(), NativeProvider);
        let (mut input, mut output) = (io::stdin().lock(), io::stdout().lock());
        while let Some(bytes) = wire::read_frame(&mut input)? {
            let request = wire::Request::decode(&bytes)?;
            let result = session.perform(&request, &mut provider);
            wire::write_frame(&mut output, &wire::reply(&request, result)?)?;
        }
        Ok(())
    }
    #[cfg(not(windows))]
    {
        let _ = arguments;
        Err("capture_platform_unavailable")
    }
}
fn main() {
    if run().is_err() {
        let _ = wire::write_frame(
            &mut io::stdout().lock(),
            br#"{"version":1,"command":"wow-capture-protocol-error","status":"unavailable"}"#,
        );
        std::process::exit(1);
    }
}
