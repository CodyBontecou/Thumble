//! Fixed 256-square RGBA PNG encoder. No vendor code, filters, image input or
//! decompressor: bounded stored DEFLATE blocks keep same-capture bytes lossless.
fn crc(bytes: &[u8]) -> u32 {
    let mut value = !0u32;
    for byte in bytes {
        value ^= u32::from(*byte);
        for _ in 0..8 {
            value = (value >> 1) ^ if value & 1 != 0 { 0xedb88320 } else { 0 };
        }
    }
    !value
}
fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
    out.extend_from_slice(&(data.len() as u32).to_be_bytes());
    let start = out.len();
    out.extend_from_slice(kind);
    out.extend_from_slice(data);
    out.extend_from_slice(&crc(&out[start..]).to_be_bytes());
}
pub fn encode(rgba: &[u8]) -> Result<Vec<u8>, &'static str> {
    if rgba.len() != 256 * 256 * 4 {
        return Err("invalid_capture_atlas");
    }
    let mut filtered = Vec::with_capacity(256 * 1025);
    for row in rgba.chunks_exact(1024) {
        filtered.push(0);
        filtered.extend_from_slice(row);
    }
    let mut zlib = vec![0x78, 0x01];
    let chunks = filtered.chunks(65535);
    let count = chunks.len();
    for (index, block) in chunks.enumerate() {
        zlib.push(u8::from(index + 1 == count));
        let len = block.len() as u16;
        zlib.extend_from_slice(&len.to_le_bytes());
        zlib.extend_from_slice(&(!len).to_le_bytes());
        zlib.extend_from_slice(block);
    }
    let (mut a, mut b) = (1u32, 0u32);
    for byte in filtered {
        a = (a + u32::from(byte)) % 65521;
        b = (b + a) % 65521;
    }
    zlib.extend_from_slice(&((b << 16) | a).to_be_bytes());
    let mut out = b"\x89PNG\r\n\x1a\n".to_vec();
    let mut ihdr = Vec::new();
    ihdr.extend_from_slice(&256u32.to_be_bytes());
    ihdr.extend_from_slice(&256u32.to_be_bytes());
    ihdr.extend_from_slice(&[8, 6, 0, 0, 0]);
    chunk(&mut out, b"IHDR", &ihdr);
    chunk(&mut out, b"IDAT", &zlib);
    chunk(&mut out, b"IEND", &[]);
    Ok(out)
}
