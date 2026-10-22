use crate::Error;
#[derive(Clone, Copy)]
pub enum ChannelOrder {
    Rgba,
    Bgra,
}
#[derive(Clone, Copy)]
pub enum Orientation {
    TopLeft,
    BottomLeft,
}
/// Borrowed transient window pixels. Row padding/channel/orientation normalize on read;
/// there is no second whole-window allocation and no window pixels in the result.
#[derive(Clone, Copy)]
pub struct Raster<'a> {
    pub width: u32,
    pub height: u32,
    pub stride: usize,
    pub channels: ChannelOrder,
    pub orientation: Orientation,
    pub bytes: &'a [u8],
}
pub struct Panel {
    pub frame: [u8; 512],
    /// Exactly 256 * 256 * 4 top-left RGBA bytes; this is NOT PNG data.
    pub atlas_rgba: Vec<u8>,
}
struct Image<'a> {
    raster: Raster<'a>,
    reads: usize,
}
impl Image<'_> {
    fn rgb(&mut self, x: usize, y: usize) -> Result<Option<[u8; 4]>, Error> {
        self.reads += 1;
        if self.reads > 4_194_304 {
            return Err(Error::ScanLimit);
        }
        Ok(self.pixel(x, y))
    }
    fn pixel(&self, x: usize, y: usize) -> Option<[u8; 4]> {
        let r = self.raster;
        if x >= r.width as usize || y >= r.height as usize {
            return None;
        }
        let row = match r.orientation {
            Orientation::TopLeft => y,
            Orientation::BottomLeft => r.height as usize - 1 - y,
        };
        let p = &r.bytes[row * r.stride + x * 4..][..4];
        Some(match r.channels {
            ChannelOrder::Rgba => [p[0], p[1], p[2], p[3]],
            ChannelOrder::Bgra => [p[2], p[1], p[0], p[3]],
        })
    }
    fn cyan(&mut self, x: usize, y: usize) -> Result<bool, Error> {
        Ok(self
            .rgb(x, y)?
            .is_some_and(|p| p[0] < 35 && p[1] > 210 && p[2] > 210))
    }
    fn magenta(&mut self, x: usize, y: usize) -> Result<bool, Error> {
        Ok(self
            .rgb(x, y)?
            .is_some_and(|p| p[0] > 210 && p[1] < 35 && p[2] > 210))
    }
    fn gray(&mut self, x: usize, y: usize) -> Result<Option<i32>, Error> {
        Ok(self
            .rgb(x, y)?
            .filter(|p| {
                (i32::from(p[0]) - i32::from(p[1])).abs() < 8
                    && (i32::from(p[1]) - i32::from(p[2])).abs() < 8
            })
            .map(|p| i32::from(p[0])))
    }
}
fn valid_frame(b: &[u8; 512]) -> bool {
    if b[..5] != [84, 72, 87, 76, 1] {
        return false;
    }
    let u16at = |i| usize::from(u16::from_le_bytes([b[i], b[i + 1]]));
    let (page, count, len, total) = (u16at(13), u16at(15), u16at(17), u16at(19));
    if total == 0
        || total > 32768
        || count != total.div_ceil(487)
        || page >= count
        || len != (total - page * 487).min(487)
        || b[25 + len..].iter().any(|v| *v != 0)
    {
        return false;
    }
    let (mut a, mut sum) = (1u32, 0u32);
    for v in b[..21].iter().chain(&b[25..25 + len]) {
        a = (a + u32::from(*v)) % 65521;
        sum = (sum + a) % 65521;
    }
    (sum << 16 | a) == u32::from_le_bytes(b[21..25].try_into().unwrap())
}
pub fn decode_panel(raster: Raster<'_>) -> Result<Option<Panel>, Error> {
    let (w, h) = (raster.width as usize, raster.height as usize);
    if w == 0
        || h == 0
        || w > 8192
        || h > 8192
        || w * h > 16_777_216
        || raster.stride < w * 4
        || raster.stride > w * 4 + 4096
        || raster
            .stride
            .checked_mul(h)
            .is_none_or(|n| n > 64 * 1024 * 1024 || n != raster.bytes.len())
    {
        return Err(Error::InvalidRaster);
    }
    let mut image = Image { raster, reads: 0 };
    for y in 0..h.min(512) {
        let mut x = 0;
        while x < w.min(512) {
            if !image.cyan(x, y)? {
                x += 1;
                continue;
            }
            let origin = x;
            while x < w && image.cyan(x, y)? {
                x += 1;
            }
            let marker_width = x - origin;
            if !(4..=48).contains(&marker_width)
                || (y > 0 && image.cyan(origin + marker_width / 2, y - 1)?)
            {
                continue;
            }
            let mut marker_end = x;
            for marker in 1..4 {
                let start = marker_end;
                while marker_end < w
                    && if marker % 2 == 0 {
                        image.cyan(marker_end, y)?
                    } else {
                        image.magenta(marker_end, y)?
                    }
                {
                    marker_end += 1;
                }
                if marker_end.abs_diff(start).abs_diff(marker_width) > 1 {
                    break;
                }
            }
            let approximate = (marker_end - origin) as f64 / 24.0;
            let search_start = origin + (230.0 * approximate).floor() as usize;
            let search_end = w.min(origin + (270.0 * approximate).ceil() as usize);
            let mut right_end = None;
            for scan in search_start..search_end {
                if !image.cyan(scan, y)? {
                    continue;
                }
                let mut edge = scan;
                let mut valid = true;
                for marker in 0..4 {
                    let start = edge;
                    while edge < w
                        && if marker % 2 == 0 {
                            image.cyan(edge, y)?
                        } else {
                            image.magenta(edge, y)?
                        }
                    {
                        edge += 1;
                    }
                    if ((edge - start) as f64 - 4.0 * approximate).abs() > 2.0 {
                        valid = false;
                        break;
                    }
                }
                if valid {
                    right_end = Some(edge);
                    break;
                }
            }
            let Some(right_end) = right_end else {
                continue;
            };
            let unit = (right_end - origin) as f64 / 256.0;
            let px = |dx: f64| origin + (dx * unit).floor() as usize;
            let py = |dy: f64| y + (dy * unit).floor() as usize;
            let (end_x, end_y) = (px(256.0), py(320.0));
            if end_x > w || end_y > h {
                continue;
            }
            let mut valid = true;
            for marker in 0..4 {
                let (left, right, row) = (
                    px((marker * 6 + 3) as f64),
                    px((240 + marker * 4 + 2) as f64),
                    py(3.0),
                );
                let good = if marker % 2 == 0 {
                    image.cyan(left, row)? && image.cyan(right, row)?
                } else {
                    image.magenta(left, row)? && image.magenta(right, row)?
                };
                if !good {
                    valid = false;
                    break;
                }
            }
            if !valid {
                continue;
            }
            let mut palette = Vec::with_capacity(16);
            for index in 0..16 {
                let Some(value) = image.gray(px((24 + index * 6 + 3) as f64), py(3.0))? else {
                    break;
                };
                palette.push(value);
            }
            if palette.len() != 16
                || palette[0] >= 25
                || palette[15] <= 230
                || palette.windows(2).any(|p| p[1] - p[0] < 5)
            {
                continue;
            }
            let mut frame = [0u8; 512];
            for index in 0..1024 {
                let Some(value) = image.gray(
                    px((index % 64) as f64 * 3.0 + 1.5),
                    py(8.0 + (index / 64) as f64 * 3.0 + 1.5),
                )?
                else {
                    valid = false;
                    break;
                };
                let mut nearest = 0;
                for entry in 1..16 {
                    if (palette[entry] - value).abs() < (palette[nearest] - value).abs() {
                        nearest = entry;
                    }
                }
                if (palette[nearest] - value).abs() > 7 {
                    valid = false;
                    break;
                }
                frame[index / 2] |= if index % 2 == 0 {
                    (nearest as u8) << 4
                } else {
                    nearest as u8
                };
            }
            if !valid || !valid_frame(&frame) {
                continue;
            }
            let (ax, ay) = (px(0.0), py(64.0));
            let (cw, ch) = (end_x - ax, end_y - ay);
            if cw == 0 || ch == 0 {
                continue;
            }
            let mut atlas_rgba = Vec::with_capacity(256 * 256 * 4);
            for row in 0..256 {
                for col in 0..256 {
                    let sx = ax + (((col as f64 + 0.5) * cw as f64) / 256.0).floor() as usize;
                    let sy = ay + (((row as f64 + 0.5) * ch as f64) / 256.0).floor() as usize;
                    atlas_rgba.extend_from_slice(&image.pixel(sx, sy).ok_or(Error::InvalidRaster)?);
                }
            }
            return Ok(Some(Panel { frame, atlas_rgba }));
        }
    }
    Ok(None)
}
