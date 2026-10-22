//! Synthetic stdin-only parity witness. Never discovers or captures a window.
use std::io::{Read, Write};
use thumble_windows_optical_core::{decode_panel, ChannelOrder, Error, Orientation, Raster};
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
    let mut output = std::io::stdout().lock();
    match result {
        Ok(Some(panel)) => {
            output.write_all(&[1])?;
            output.write_all(&panel.frame)?;
            output.write_all(&panel.atlas_rgba)?;
        }
        Ok(None) => output.write_all(&[0])?,
        Err(Error::InvalidRaster) => output.write_all(&[2])?,
        Err(Error::ScanLimit) => output.write_all(&[3])?,
        Err(_) => return Err("unexpected_optical_error".into()),
    }
    Ok(())
}
