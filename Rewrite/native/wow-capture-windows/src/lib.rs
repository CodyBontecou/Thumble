pub mod png;
#[cfg(windows)]
pub mod windows;
pub mod wire;
use thumble_rewrite_windows_optical::{Panel, WindowIdentity};
use wire::Request;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    PermissionRequired,
    GameNotVisible,
    MultipleGameWindows,
    PanelNotVisible,
    Unavailable,
}
impl Status {
    pub fn text(self) -> &'static str {
        match self {
            Self::PermissionRequired => "permission-required",
            Self::GameNotVisible => "game-not-visible",
            Self::MultipleGameWindows => "multiple-game-windows",
            Self::PanelNotVisible => "panel-not-visible",
            Self::Unavailable => "unavailable",
        }
    }
}
/// Entirely private native identity. None of these fields cross the child boundary.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    pub process: WindowIdentity,
    pub executable: String,
    pub volume: u64,
    pub file_size: u64,
    pub modified: u64,
    pub window_rect: [i32; 4],
    pub client_rect: [i32; 4],
    pub frame_rect: [i32; 4],
    pub dpi: u32,
}
pub struct Capture {
    pub panel: Option<Panel>,
    pub width: u32,
    pub height: u32,
}
/// Native adapter authenticates OS observations; fake implementations are test-only.
pub trait Provider {
    fn inventory(&mut self) -> Result<Vec<Identity>, Status>;
    fn capture(&mut self, identity: &Identity) -> Result<Capture, Status>;
}
#[derive(Default)]
pub struct Session {
    context: Option<(u32, u64)>,
    last_receipt: u64,
    selected: Option<Identity>,
    size: Option<(u32, u32)>,
    invalidated: bool,
}
impl Session {
    pub fn perform(
        &mut self,
        request: &Request,
        provider: &mut impl Provider,
    ) -> Result<Panel, Status> {
        let context = (request.source(), request.generation_value());
        if self.invalidated
            || self.context.is_some_and(|previous| previous != context)
            || request.receipt_value() <= self.last_receipt
        {
            self.invalidated = true;
            return Err(Status::Unavailable);
        }
        self.context = Some(context);
        self.last_receipt = request.receipt_value();
        let result = self.acquire(provider);
        if matches!(result, Err(Status::Unavailable)) {
            self.invalidated = true;
        }
        result
    }
    fn acquire(&mut self, provider: &mut impl Provider) -> Result<Panel, Status> {
        let before = provider.inventory()?;
        if before.len() != 1 {
            if self.selected.is_some() {
                self.invalidated = true;
            }
            return Err(if before.is_empty() {
                Status::GameNotVisible
            } else {
                Status::MultipleGameWindows
            });
        }
        let identity = &before[0];
        if self.selected.as_ref().is_some_and(|old| old != identity) {
            return Err(Status::Unavailable);
        }
        self.selected = Some(identity.clone());
        let captured = provider.capture(identity)?;
        if !(320..=8192).contains(&captured.width)
            || !(320..=8192).contains(&captured.height)
            || u64::from(captured.width) * u64::from(captured.height) > 16_777_216
        {
            return Err(Status::Unavailable);
        }
        let size = (captured.width, captured.height);
        if self.size.is_some_and(|old| old != size) {
            return Err(Status::Unavailable);
        }
        self.size = Some(size);
        let after = provider.inventory()?;
        if after.len() != 1 || after[0] != *identity {
            return Err(Status::Unavailable);
        }
        captured.panel.ok_or(Status::PanelNotVisible)
    }
}
/// Retained policy limits client roots to _classic_era_ / _forever_. The Windows
/// filename/version strings identify eligibility, NOT executable authenticity.
pub fn eligible_path(path: &str, product: &str, original: &str) -> bool {
    let path = path.replace('/', "\\").to_ascii_lowercase();
    let mut components = path.split('\\').filter(|part| !part.is_empty());
    let rooted = path.as_bytes().get(1) == Some(&b':') && path.as_bytes().get(2) == Some(&b'\\');
    let client = components.any(|part| matches!(part, "_classic_era_" | "_forever_"));
    rooted
        && !path.split('\\').any(|part| matches!(part, "." | ".."))
        && !path.contains('\0')
        && client
        && product == "World of Warcraft"
        && matches!(
            original.to_ascii_lowercase().as_str(),
            "wow.exe" | "wowclassic.exe"
        )
        && path
            .rsplit('\\')
            .next()
            .is_some_and(|name| name == original.to_ascii_lowercase())
}
#[cfg(test)]
mod tests;
