//! Offline planner: bounded manifest JSON on stdin, complete plan JSON on stdout.
use std::io::{self, Read, Write};
use thumble_core::{plan_game_controller, MAXIMUM_GAME_CONTROLLER_BYTES};

fn main() {
    if let Err(error) = run() {
        eprintln!("thumble game controller plan: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut input = Vec::new();
    io::stdin()
        .lock()
        .take((MAXIMUM_GAME_CONTROLLER_BYTES + 1) as u64)
        .read_to_end(&mut input)?;
    let plan = plan_game_controller(&input)?;
    let mut output = io::stdout().lock();
    serde_json::to_writer_pretty(&mut output, &plan)?;
    output.write_all(b"\n")?;
    Ok(())
}
