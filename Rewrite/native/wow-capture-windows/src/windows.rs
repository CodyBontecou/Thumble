//! Live Win32/WGC adapter. Tests never instantiate this provider or invoke it.
use crate::{Capture, Identity, Provider, Status};
use std::{ffi::c_void, sync::mpsc, time::Duration};
use thumble_rewrite_windows_optical::{
    decode_panel, ChannelOrder, Orientation, Raster, WindowIdentity,
};
use windows::{
    core::{factory, Interface, BOOL, HSTRING, PCWSTR, PWSTR},
    Foundation::TypedEventHandler,
    Graphics::{
        Capture::{
            Direct3D11CaptureFramePool, GraphicsCaptureAccess, GraphicsCaptureAccessKind,
            GraphicsCaptureItem, GraphicsCaptureSession,
        },
        DirectX::{Direct3D11::IDirect3DDevice, DirectXPixelFormat},
    },
    Security::Authorization::AppCapabilityAccess::{AppCapability, AppCapabilityAccessStatus},
    Win32::{
        Foundation::{CloseHandle, FILETIME, HANDLE, HMODULE, HWND, LPARAM, RECT},
        Graphics::{
            Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_FEATURE_LEVEL_11_0},
            Direct3D11::*,
            Dwm::{DwmGetWindowAttribute, DWMWA_EXTENDED_FRAME_BOUNDS},
            Dxgi::{Common::DXGI_FORMAT_B8G8R8A8_UNORM, IDXGIDevice},
        },
        Storage::FileSystem::*,
        System::{
            Threading::*,
            WinRT::{
                Direct3D11::{CreateDirect3D11DeviceFromDXGIDevice, IDirect3DDxgiInterfaceAccess},
                Graphics::Capture::IGraphicsCaptureItemInterop,
                RoInitialize, RoUninitialize, RO_INIT_MULTITHREADED,
            },
        },
        UI::{
            HiDpi::{
                GetDpiForWindow, SetThreadDpiAwarenessContext,
                DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
            },
            WindowsAndMessaging::*,
        },
    },
};
fn unavailable(_: windows::core::Error) -> Status {
    Status::Unavailable
}
fn win_permission(error: windows::core::Error) -> Status {
    if error.code().0 as u32 == 0x80070005 {
        Status::PermissionRequired
    } else {
        Status::Unavailable
    }
}
struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}
pub struct Apartment;
impl Apartment {
    pub fn initialize() -> Result<Self, Status> {
        unsafe { RoInitialize(RO_INIT_MULTITHREADED) }.map_err(unavailable)?;
        Ok(Self)
    }
}
impl Drop for Apartment {
    fn drop(&mut self) {
        unsafe {
            RoUninitialize();
        }
    }
}
pub fn permission(request: bool) -> &'static str {
    if request {
        match GraphicsCaptureAccess::RequestAccessAsync(GraphicsCaptureAccessKind::Programmatic)
            .and_then(|operation| operation.get())
        {
            Ok(AppCapabilityAccessStatus::Allowed) => "authorized",
            Ok(_) => "permission-required",
            Err(_) => "unavailable",
        }
    } else {
        match AppCapability::Create(&HSTRING::from("graphicsCaptureProgrammatic"))
            .and_then(|capability| capability.CheckAccess())
        {
            Ok(AppCapabilityAccessStatus::Allowed) => "authorized",
            Ok(
                AppCapabilityAccessStatus::UserPromptRequired
                | AppCapabilityAccessStatus::DeniedByUser
                | AppCapabilityAccessStatus::DeniedBySystem,
            ) => "permission-required",
            _ => "not-inspected",
        }
    }
}
fn timestamp(time: FILETIME) -> u64 {
    (u64::from(time.dwHighDateTime) << 32) | u64::from(time.dwLowDateTime)
}
fn process_start(process: HANDLE) -> Result<u64, Status> {
    let (mut created, mut exit, mut kernel, mut user) = (
        FILETIME::default(),
        FILETIME::default(),
        FILETIME::default(),
        FILETIME::default(),
    );
    unsafe { GetProcessTimes(process, &mut created, &mut exit, &mut kernel, &mut user) }
        .map_err(unavailable)?;
    let started = timestamp(created);
    if started == 0 {
        return Err(Status::Unavailable);
    }
    Ok(started)
}
fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16().chain(Some(0)).collect()
}
fn version(path: &[u16]) -> Result<(String, String), Status> {
    unsafe {
        let size = GetFileVersionInfoSizeW(PCWSTR(path.as_ptr()), None) as usize;
        if size == 0 || size > 1024 * 1024 {
            return Err(Status::Unavailable);
        }
        let mut buffer = vec![0u32; size.div_ceil(4)];
        GetFileVersionInfoW(
            PCWSTR(path.as_ptr()),
            None,
            size as u32,
            buffer.as_mut_ptr().cast(),
        )
        .map_err(unavailable)?;
        let query = |key: &str| -> Result<(*mut c_void, usize), Status> {
            let key = wide(key);
            let mut pointer = std::ptr::null_mut();
            let mut length = 0;
            if !VerQueryValueW(
                buffer.as_ptr().cast(),
                PCWSTR(key.as_ptr()),
                &mut pointer,
                &mut length,
            )
            .as_bool()
            {
                return Err(Status::Unavailable);
            }
            let at = pointer as usize;
            let base = buffer.as_ptr() as usize;
            if at < base || at >= base + size {
                return Err(Status::Unavailable);
            }
            Ok((pointer, length as usize))
        };
        let (translations, length) = query("\\VarFileInfo\\Translation")?;
        if !(4..=64).contains(&length)
            || length % 4 != 0
            || (translations as usize) + length > (buffer.as_ptr() as usize) + size
        {
            return Err(Status::Unavailable);
        }
        for record in std::slice::from_raw_parts(translations.cast::<u8>(), length).chunks_exact(4)
        {
            let lang = u16::from_le_bytes([record[0], record[1]]);
            let page = u16::from_le_bytes([record[2], record[3]]);
            let string = |field: &str| -> Result<String, Status> {
                let (pointer, units) =
                    query(&format!("\\StringFileInfo\\{lang:04x}{page:04x}\\{field}"))?;
                if units == 0
                    || units > 1024
                    || pointer as usize % 2 != 0
                    || (pointer as usize) + units * 2 > (buffer.as_ptr() as usize) + size
                {
                    return Err(Status::Unavailable);
                }
                let text = std::slice::from_raw_parts(pointer.cast::<u16>(), units);
                if text.last() != Some(&0) {
                    return Err(Status::Unavailable);
                }
                String::from_utf16(&text[..units - 1]).map_err(|_| Status::Unavailable)
            };
            if let (Ok(product), Ok(original)) = (string("ProductName"), string("OriginalFilename"))
            {
                return Ok((product, original));
            }
        }
        Err(Status::Unavailable)
    }
}
struct Bound {
    identity: Identity,
    _process: Handle,
    _file: Handle,
}
fn inspect(hwnd: HWND) -> Result<Option<Bound>, Status> {
    unsafe {
        if !IsWindowVisible(hwnd).as_bool()
            || IsIconic(hwnd).as_bool()
            || GetAncestor(hwnd, GA_ROOT) != hwnd
        {
            return Ok(None);
        }
        let mut pid = 0;
        if GetWindowThreadProcessId(hwnd, Some(&mut pid)) == 0 || pid == 0 {
            return Ok(None);
        }
        // Other protected/vanished applications are not inferred to be games.
        let Ok(handle) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else {
            return Ok(None);
        };
        let process = Handle(handle);
        let mut path = vec![0u16; 32768];
        let mut length = path.len() as u32;
        if QueryFullProcessImageNameW(
            handle,
            PROCESS_NAME_WIN32,
            PWSTR(path.as_mut_ptr()),
            &mut length,
        )
        .is_err()
        {
            return Ok(None);
        }
        if length == 0 || length as usize >= path.len() {
            return Err(Status::Unavailable);
        }
        path.truncate(length as usize);
        let executable = String::from_utf16(&path).map_err(|_| Status::Unavailable)?;
        let normalized = executable.replace('/', "\\").to_ascii_lowercase();
        if !normalized
            .split('\\')
            .any(|part| matches!(part, "_classic_era_" | "_forever_"))
        {
            return Ok(None);
        }
        let name = normalized.rsplit('\\').next().unwrap_or("");
        if !matches!(name, "wow.exe" | "wowclassic.exe") {
            return Ok(None);
        }
        let start = process_start(handle)?;
        path.push(0);
        // Share reads only: no replacement/writer while the privately discovered
        // EXE is inspected and (during capture) its handle remains retained.
        let file = Handle(
            CreateFileW(
                PCWSTR(path.as_ptr()),
                FILE_READ_ATTRIBUTES.0,
                FILE_SHARE_READ,
                None,
                OPEN_EXISTING,
                FILE_FLAG_OPEN_REPARSE_POINT,
                None,
            )
            .map_err(unavailable)?,
        );
        let mut info = BY_HANDLE_FILE_INFORMATION::default();
        GetFileInformationByHandle(file.0, &mut info).map_err(unavailable)?;
        if info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY.0 | FILE_ATTRIBUTE_REPARSE_POINT.0)
            != 0
        {
            return Err(Status::Unavailable);
        }
        let mut id = FILE_ID_INFO::default();
        GetFileInformationByHandleEx(
            file.0,
            FileIdInfo,
            (&mut id as *mut FILE_ID_INFO).cast(),
            std::mem::size_of::<FILE_ID_INFO>() as u32,
        )
        .map_err(unavailable)?;
        let file_id = u128::from_le_bytes(id.FileId.Identifier);
        let file_size = (u64::from(info.nFileSizeHigh) << 32) | u64::from(info.nFileSizeLow);
        if file_id == 0 || file_size == 0 {
            return Err(Status::Unavailable);
        }
        let mut resolved = vec![0u16; 32768];
        let count = GetFinalPathNameByHandleW(
            file.0,
            &mut resolved,
            GETFINALPATHNAMEBYHANDLE_FLAGS(FILE_NAME_NORMALIZED.0 | VOLUME_NAME_DOS.0),
        ) as usize;
        if count == 0 || count >= resolved.len() {
            return Err(Status::Unavailable);
        }
        let final_path = String::from_utf16(&resolved[..count]).map_err(|_| Status::Unavailable)?;
        let final_path = final_path
            .strip_prefix(r"\\?\")
            .ok_or(Status::Unavailable)?;
        // A parent junction/alias cannot smuggle a different resolved client
        // root into the retained path policy. No alternate path is selected.
        if !final_path.eq_ignore_ascii_case(&executable) {
            return Err(Status::Unavailable);
        }
        let (product, original) = version(&path)?;
        if !crate::eligible_path(&executable, &product, &original) {
            return Ok(None);
        }
        let (mut window, mut client, mut frame) =
            (RECT::default(), RECT::default(), RECT::default());
        GetWindowRect(hwnd, &mut window).map_err(unavailable)?;
        GetClientRect(hwnd, &mut client).map_err(unavailable)?;
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_EXTENDED_FRAME_BOUNDS,
            (&mut frame as *mut RECT).cast(),
            std::mem::size_of::<RECT>() as u32,
        )
        .map_err(unavailable)?;
        let dpi = GetDpiForWindow(hwnd);
        let width = i64::from(frame.right) - i64::from(frame.left);
        let height = i64::from(frame.bottom) - i64::from(frame.top);
        if width < 320 || height < 320 {
            return Ok(None);
        }
        if dpi == 0 || width > 8192 || height > 8192 || width * height > 16_777_216 {
            return Err(Status::Unavailable);
        }
        let mut after = 0;
        if process_start(handle)? != start
            || GetWindowThreadProcessId(hwnd, Some(&mut after)) == 0
            || after != pid
        {
            return Err(Status::Unavailable);
        }
        let rect = |r: RECT| [r.left, r.top, r.right, r.bottom];
        Ok(Some(Bound {
            identity: Identity {
                process: WindowIdentity {
                    handle: hwnd.0 as usize as u64,
                    process_id: pid,
                    process_started: start,
                    executable_file_id: file_id,
                },
                executable,
                volume: id.VolumeSerialNumber,
                file_size,
                modified: timestamp(info.ftLastWriteTime),
                window_rect: rect(window),
                client_rect: rect(client),
                frame_rect: rect(frame),
                dpi,
            },
            _process: process,
            _file: file,
        }))
    }
}
pub struct NativeProvider;
impl Provider for NativeProvider {
    fn inventory(&mut self) -> Result<Vec<Identity>, Status> {
        struct Inventory {
            count: usize,
            windows: Vec<Identity>,
            failed: bool,
        }
        unsafe extern "system" fn callback(hwnd: HWND, param: LPARAM) -> BOOL {
            let state = unsafe { &mut *(param.0 as *mut Inventory) };
            state.count += 1;
            if state.count > 4096 {
                state.failed = true;
                return BOOL(0);
            }
            match inspect(hwnd) {
                Ok(Some(window)) => {
                    state.windows.push(window.identity);
                    if state.windows.len() == 2 {
                        return BOOL(0);
                    }
                }
                Ok(None) => (),
                Err(_) => {
                    state.failed = true;
                    return BOOL(0);
                }
            }
            BOOL(1)
        }
        let mut state = Inventory {
            count: 0,
            windows: vec![],
            failed: false,
        };
        // Pixel geometry is collected in a per-monitor-aware thread context,
        // avoiding DPI virtualization without changing another process's mode.
        let old =
            unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
        if old.0.is_null() {
            return Err(Status::Unavailable);
        }
        let enumeration = unsafe {
            EnumWindows(
                Some(callback),
                LPARAM((&mut state as *mut Inventory) as isize),
            )
        };
        unsafe {
            SetThreadDpiAwarenessContext(old);
        }
        if state.failed || (enumeration.is_err() && state.windows.len() != 2) {
            return Err(Status::Unavailable);
        }
        Ok(state.windows)
    }
    fn capture(&mut self, identity: &Identity) -> Result<Capture, Status> {
        // Reacquire and retain native handles across the WGC wait. This also
        // closes the inventory→CreateForWindow race before any pixel request.
        let hwnd = HWND(identity.process.handle as usize as *mut c_void);
        let old =
            unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
        if old.0.is_null() {
            return Err(Status::Unavailable);
        }
        let result = (|| {
            let bound = inspect(hwnd)?.ok_or(Status::Unavailable)?;
            if bound.identity != *identity {
                return Err(Status::Unavailable);
            }
            let captured = capture_window(hwnd)?;
            let after = inspect(hwnd)?.ok_or(Status::Unavailable)?;
            if after.identity != *identity {
                return Err(Status::Unavailable);
            }
            Ok(captured)
        })();
        unsafe {
            SetThreadDpiAwarenessContext(old);
        }
        result
    }
}
struct Stream {
    session: GraphicsCaptureSession,
    pool: Direct3D11CaptureFramePool,
    token: i64,
}
impl Drop for Stream {
    fn drop(&mut self) {
        let _ = self.pool.RemoveFrameArrived(self.token);
        let _ = self.session.Close();
        let _ = self.pool.Close();
    }
}
struct Frame(windows::Graphics::Capture::Direct3D11CaptureFrame);
impl Drop for Frame {
    fn drop(&mut self) {
        let _ = self.0.Close();
    }
}
struct Mapping<'a> {
    context: &'a ID3D11DeviceContext,
    texture: &'a ID3D11Texture2D,
}
impl Drop for Mapping<'_> {
    fn drop(&mut self) {
        unsafe {
            self.context.Unmap(self.texture, 0);
        }
    }
}
fn capture_window(hwnd: HWND) -> Result<Capture, Status> {
    if !GraphicsCaptureSession::IsSupported().map_err(unavailable)? {
        return Err(Status::Unavailable);
    }
    let interop: IGraphicsCaptureItemInterop =
        factory::<GraphicsCaptureItem, IGraphicsCaptureItemInterop>().map_err(unavailable)?;
    let item: GraphicsCaptureItem =
        unsafe { interop.CreateForWindow(hwnd) }.map_err(win_permission)?;
    let size = item.Size().map_err(unavailable)?;
    if !(320..=8192).contains(&size.Width)
        || !(320..=8192).contains(&size.Height)
        || i64::from(size.Width) * i64::from(size.Height) > 16_777_216
    {
        return Err(Status::Unavailable);
    }
    let (mut device, mut context) = (None, None);
    unsafe {
        D3D11CreateDevice(
            None,
            D3D_DRIVER_TYPE_HARDWARE,
            HMODULE::default(),
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            Some(&[D3D_FEATURE_LEVEL_11_0]),
            D3D11_SDK_VERSION,
            Some(&mut device),
            None,
            Some(&mut context),
        )
    }
    .map_err(unavailable)?;
    let device = device.ok_or(Status::Unavailable)?;
    let context = context.ok_or(Status::Unavailable)?;
    let dxgi: IDXGIDevice = device.cast().map_err(unavailable)?;
    let direct: IDirect3DDevice = unsafe { CreateDirect3D11DeviceFromDXGIDevice(&dxgi) }
        .and_then(|value| value.cast())
        .map_err(unavailable)?;
    let pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
        &direct,
        DirectXPixelFormat::B8G8R8A8UIntNormalized,
        2,
        size,
    )
    .map_err(unavailable)?;
    let session = pool.CreateCaptureSession(&item).map_err(win_permission)?;
    let (sender, receiver) = mpsc::sync_channel::<()>(1);
    let token = pool
        .FrameArrived(&TypedEventHandler::new(move |_, _| {
            let _ = sender.try_send(());
            Ok(())
        }))
        .map_err(unavailable)?;
    let stream = Stream {
        session,
        pool,
        token,
    };
    // Border and capture-policy defaults are intentionally left untouched.
    stream.session.StartCapture().map_err(win_permission)?;
    receiver
        .recv_timeout(Duration::from_millis(750))
        .map_err(|_| Status::Unavailable)?;
    let frame = Frame(stream.pool.TryGetNextFrame().map_err(unavailable)?);
    let content = frame.0.ContentSize().map_err(unavailable)?;
    if content.Width != size.Width || content.Height != size.Height {
        return Err(Status::Unavailable);
    }
    let access: IDirect3DDxgiInterfaceAccess = frame
        .0
        .Surface()
        .and_then(|surface| surface.cast())
        .map_err(unavailable)?;
    let texture: ID3D11Texture2D = unsafe { access.GetInterface() }.map_err(unavailable)?;
    let mut desc = D3D11_TEXTURE2D_DESC::default();
    unsafe {
        texture.GetDesc(&mut desc);
    }
    if desc.Width != size.Width as u32
        || desc.Height != size.Height as u32
        || desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM
        || desc.SampleDesc.Count != 1
        || desc.ArraySize != 1
        || desc.MipLevels != 1
    {
        return Err(Status::Unavailable);
    }
    desc.Usage = D3D11_USAGE_STAGING;
    desc.BindFlags = 0;
    desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ.0 as u32;
    desc.MiscFlags = 0;
    let mut staging = None;
    unsafe { device.CreateTexture2D(&desc, None, Some(&mut staging)) }.map_err(unavailable)?;
    let staging = staging.ok_or(Status::Unavailable)?;
    unsafe {
        context.CopyResource(&staging, &texture);
    }
    let mut mapped = D3D11_MAPPED_SUBRESOURCE::default();
    unsafe { context.Map(&staging, 0, D3D11_MAP_READ, 0, Some(&mut mapped)) }
        .map_err(unavailable)?;
    let _mapping = Mapping {
        context: &context,
        texture: &staging,
    };
    let length = (mapped.RowPitch as usize)
        .checked_mul(desc.Height as usize)
        .ok_or(Status::Unavailable)?;
    if mapped.pData.is_null() || mapped.RowPitch < desc.Width * 4 || length > 64 * 1024 * 1024 {
        return Err(Status::Unavailable);
    }
    // SAFETY: successful read-only D3D map remains live through decode, bounded
    // by the validated texture dimensions and row pitch; no window copy escapes.
    let bytes = unsafe { std::slice::from_raw_parts(mapped.pData.cast::<u8>(), length) };
    let panel = decode_panel(Raster {
        width: desc.Width,
        height: desc.Height,
        stride: mapped.RowPitch as usize,
        channels: ChannelOrder::Bgra,
        orientation: Orientation::TopLeft,
        bytes,
    })
    .map_err(|_| Status::Unavailable)?;
    Ok(Capture {
        panel,
        width: desc.Width,
        height: desc.Height,
    })
}
