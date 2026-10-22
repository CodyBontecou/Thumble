use crate::{png, Status};
use serde::{Deserialize, Serialize};
use std::io::{Read, Write};
use thumble_rewrite_windows_optical::Panel;
pub const REQUEST_LIMIT: usize = 256;
pub const REPLY_LIMIT: usize = 4 * (2 * 1024 * 1024usize).div_ceil(3) + 1024;
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Request {
    version: u8,
    command: String,
    source: u32,
    generation: String,
    receipt: String,
}
fn counter(text: &str) -> Option<u64> {
    if text.is_empty()
        || text.len() > 20
        || text.starts_with('0')
        || !text.bytes().all(|b| b.is_ascii_digit())
    {
        return None;
    }
    text.parse().ok().filter(|value| *value > 0)
}
impl Request {
    pub fn decode(bytes: &[u8]) -> Result<Self, &'static str> {
        if bytes.len() > REQUEST_LIMIT || !bytes.is_ascii() {
            return Err("invalid_capture_request");
        }
        let value: Self = serde_json::from_slice(bytes).map_err(|_| "invalid_capture_request")?;
        if value.version != 1
            || value.command != "wow-capture"
            || value.source == 0
            || counter(&value.generation).is_none()
            || counter(&value.receipt).is_none()
        {
            return Err("invalid_capture_request");
        }
        Ok(value)
    }
    pub fn source(&self) -> u32 {
        self.source
    }
    pub fn generation_value(&self) -> u64 {
        counter(&self.generation).unwrap()
    }
    pub fn receipt_value(&self) -> u64 {
        counter(&self.receipt).unwrap()
    }
}
pub fn read_frame(input: &mut impl Read) -> Result<Option<Vec<u8>>, &'static str> {
    let mut header = [0u8; 4];
    match input.read(&mut header[..1]) {
        Ok(0) => return Ok(None),
        Ok(_) => (),
        Err(_) => return Err("capture_io_failed"),
    }
    input
        .read_exact(&mut header[1..])
        .map_err(|_| "capture_io_failed")?;
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > REQUEST_LIMIT {
        return Err("invalid_capture_request");
    }
    let mut bytes = vec![0; length];
    input
        .read_exact(&mut bytes)
        .map_err(|_| "capture_io_failed")?;
    Ok(Some(bytes))
}
pub fn write_frame(output: &mut impl Write, bytes: &[u8]) -> Result<(), &'static str> {
    if bytes.is_empty() || bytes.len() > REPLY_LIMIT || !bytes.is_ascii() {
        return Err("invalid_capture_reply");
    }
    output
        .write_all(&(bytes.len() as u32).to_be_bytes())
        .and_then(|_| output.write_all(bytes))
        .and_then(|_| output.flush())
        .map_err(|_| "capture_io_failed")
}
fn base64(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let word = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        out.push(TABLE[((word >> 18) & 63) as usize] as char);
        out.push(TABLE[((word >> 12) & 63) as usize] as char);
        out.push(if chunk.len() > 1 {
            TABLE[((word >> 6) & 63) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            TABLE[(word & 63) as usize] as char
        } else {
            '='
        });
    }
    out
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Reply<'a> {
    version: u8,
    command: &'static str,
    source: u32,
    generation: &'a str,
    receipt: &'a str,
    kind: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    status: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    frame_base64: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "atlasPNGBase64")]
    atlas_png_base64: Option<String>,
}
pub fn reply(request: &Request, result: Result<Panel, Status>) -> Result<Vec<u8>, &'static str> {
    let mut value = Reply {
        version: 1,
        command: "wow-capture-result",
        source: request.source,
        generation: &request.generation,
        receipt: &request.receipt,
        kind: "status",
        status: None,
        frame_base64: None,
        atlas_png_base64: None,
    };
    match result {
        Err(status) => value.status = Some(status.text()),
        Ok(panel) => {
            value.kind = "frame";
            value.frame_base64 = Some(base64(&panel.frame));
            value.atlas_png_base64 = Some(base64(&png::encode(&panel.atlas_rgba)?));
        }
    }
    let bytes = serde_json::to_vec(&value).map_err(|_| "invalid_capture_reply")?;
    if bytes.len() > REPLY_LIMIT {
        return Err("invalid_capture_reply");
    }
    Ok(bytes)
}
