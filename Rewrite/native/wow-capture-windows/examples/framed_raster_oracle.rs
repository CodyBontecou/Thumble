//! Synthetic stdin-only parity witness. Never discovers or captures a window.
use std::io::Read;
use thumble_rewrite_windows_optical::{decode_panel, ChannelOrder, Orientation, Raster};
use thumble_rewrite_wow_capture_windows::{wire, Status};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut bytes = Vec::new();
    std::io::stdin()
        .take(64 * 1024 * 1024 + 21)
        .read_to_end(&mut bytes)?;
    if bytes.len() < 20
        || bytes.len() > 64 * 1024 * 1024 + 20
        || &bytes[..4] != b"TWOP"
        || bytes[14..20].iter().any(|v| *v != 0)
        || bytes[12] > 1
        || bytes[13] > 1
    {
        return Err("invalid_synthetic_raster".into());
    }
    let u32at = |i| u32::from_le_bytes(bytes[i..i + 4].try_into().unwrap());
    // width/height use u16; stride u32; header remains exactly 20 bytes.
    let width = u32::from(u16::from_le_bytes(bytes[4..6].try_into().unwrap()));
    let height = u32::from(u16::from_le_bytes(bytes[6..8].try_into().unwrap()));
    let result = decode_panel(Raster {
        width,
        height,
        stride: u32at(8) as usize,
        channels: if bytes[12] == 0 {
            ChannelOrder::Rgba
        } else {
            ChannelOrder::Bgra
        },
        orientation: if bytes[13] == 0 {
            Orientation::TopLeft
        } else {
            Orientation::BottomLeft
        },
        bytes: &bytes[20..],
    });
    let request=wire::Request::decode(br#"{"version":1,"command":"wow-capture","source":4294967295,"generation":"18446744073709551615","receipt":"1"}"#)?;
    let result = match result {
        Ok(Some(panel)) => Ok(panel),
        Ok(None) => Err(Status::PanelNotVisible),
        Err(_) => Err(Status::Unavailable),
    };
    wire::write_frame(
        &mut std::io::stdout().lock(),
        &wire::reply(&request, result)?,
    )?;
    Ok(())
}
