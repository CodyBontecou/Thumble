//! Pure Windows capture preparation. No OS API, capture permission or game identity proof.
#![forbid(unsafe_code)]
mod pixels;
pub use pixels::{decode_panel, ChannelOrder, Orientation, Panel, Raster};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Error {
    InvalidRaster,
    ScanLimit,
    InvalidInventory,
    GameNotVisible,
    MultipleGameWindows,
    SourceChanged,
    InvalidReceipt,
}
/// Pointer-width HWND is private metadata, never the observer's uint32 source number.
/// Values must ultimately come from a reviewed native OS identity/eligibility adapter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WindowIdentity {
    pub handle: u64,
    pub process_id: u32,
    pub process_started: u64,
    pub executable_file_id: u128,
}
impl WindowIdentity {
    fn valid(self) -> bool {
        self.handle != 0
            && self.process_id != 0
            && self.process_started != 0
            && self.executable_file_id != 0
    }
}
#[derive(Clone, Copy)]
pub struct WindowCandidate {
    pub identity: WindowIdentity,
    /// Trusted future adapter's exact client eligibility result; NOT a basename match.
    pub eligible_client: bool,
    pub visible: bool,
    pub minimized: bool,
    pub top_level: bool,
    pub width: u32,
    pub height: u32,
}
/// Pure inventory policy only. It does not itself query or authenticate a Windows process.
pub fn select_window(windows: &[WindowCandidate]) -> Result<WindowIdentity, Error> {
    if windows.len() > 128 || windows.iter().any(|w| !w.identity.valid()) {
        return Err(Error::InvalidInventory);
    }
    let mut selected = None;
    for w in windows {
        if !w.eligible_client
            || !w.visible
            || w.minimized
            || !w.top_level
            || w.width < 320
            || w.height < 320
        {
            continue;
        }
        if w.width > 8192
            || w.height > 8192
            || u64::from(w.width) * u64::from(w.height) > 16_777_216
        {
            return Err(Error::InvalidInventory);
        }
        if selected.replace(w.identity).is_some() {
            return Err(Error::MultipleGameWindows);
        }
    }
    selected.ok_or(Error::GameNotVisible)
}
/// Issued by the application supervisor; the native core never advances these counters.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Receipt {
    pub source: u32,
    pub generation: u64,
    pub receipt: u64,
}
pub struct CaptureBinding {
    receipt: Receipt,
    window: WindowIdentity,
}
pub struct CapturedPanel {
    pub receipt: Receipt,
    pub panel: Panel,
}
impl CaptureBinding {
    pub fn new(receipt: Receipt, window: WindowIdentity) -> Result<Self, Error> {
        if receipt.source == 0 || receipt.generation == 0 || receipt.receipt == 0 {
            return Err(Error::InvalidReceipt);
        }
        if !window.valid() {
            return Err(Error::InvalidInventory);
        }
        Ok(Self { receipt, window })
    }
    /// A future OS adapter must re-query identity around acquisition, not trust caller pixels.
    /// The receipt and atlas are returned together from this same decode operation.
    pub fn decode(
        &self,
        acquired_from: WindowIdentity,
        raster: Raster<'_>,
    ) -> Result<Option<CapturedPanel>, Error> {
        if acquired_from != self.window {
            return Err(Error::SourceChanged);
        }
        Ok(decode_panel(raster)?.map(|panel| CapturedPanel {
            receipt: self.receipt,
            panel,
        }))
    }
}
#[cfg(test)]
mod tests;
