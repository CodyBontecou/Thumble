//! Bounded test-only emitter. Calls the frozen pure mapper, never an SDK or OS API.
#![forbid(unsafe_code)]
use std::io::{self, BufRead, Read, Write};
use thumble_windows_candidate::{map_report, MappingError};
fn main() {
    if run().is_err() {
        eprintln!("candidate_emitter_invalid_input");
        std::process::exit(1);
    }
}
fn run() -> Result<(), ()> {
    let mut input = io::stdin().lock();
    let mut output = io::BufWriter::new(io::stdout().lock());
    for count in 0..=4096 {
        let mut line = String::new();
        let bytes = (&mut input)
            .take(128)
            .read_line(&mut line)
            .map_err(|_| ())?;
        if bytes == 0 {
            return output.flush().map_err(|_| ());
        }
        if count == 4096 || !line.ends_with('\n') {
            return Err(());
        }
        let line = line.trim_end_matches(['\r', '\n']);
        if line.len() != 40
            || !line
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(());
        }
        let mut report = [0; 20];
        for (index, byte) in report.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&line[index * 2..index * 2 + 2], 16).map_err(|_| ())?;
        }
        match map_report(&report) {
            Ok(state) => {
                write!(
                    output,
                    "{{\"version\":1,\"reportHex\":\"{line}\",\"axes\":["
                )
                .map_err(|_| ())?;
                for (index, axis) in state.axes().iter().enumerate() {
                    if index > 0 {
                        write!(output, ",").map_err(|_| ())?;
                    }
                    write!(
                        output,
                        "{{\"usage\":{},\"bits\":{}}}",
                        axis.axis as u16,
                        axis.unit.to_bits()
                    )
                    .map_err(|_| ())?;
                }
                writeln!(
                    output,
                    "],\"buttons\":{},\"hat\":{}}}",
                    state.buttons.api_mask(),
                    state.hat as u8
                )
                .map_err(|_| ())?;
            }
            Err(error) => {
                let code = match error {
                    MappingError::InvalidLength => "invalid-length",
                    MappingError::InvalidHeader => "invalid-header",
                    MappingError::ReservedButtonBit => "reserved-button-bit",
                    MappingError::ReservedBytes => "reserved-bytes",
                    MappingError::UnsupportedDpad => "unsupported-dpad",
                };
                writeln!(
                    output,
                    "{{\"version\":1,\"reportHex\":\"{line}\",\"error\":\"{code}\"}}"
                )
                .map_err(|_| ())?;
            }
        }
    }
    Err(())
}
