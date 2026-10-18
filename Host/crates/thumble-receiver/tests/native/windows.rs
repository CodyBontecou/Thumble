use super::*;
use windows_sys::Win32::{
    Foundation::*,
    UI::{Input::KeyboardAndMouse::SetFocus, WindowsAndMessaging::*},
};
// Observe only the test window's messages, never global keyboard hooks.
unsafe extern "system" fn window_proc(
    window: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let pointer =
        unsafe { GetWindowLongPtrW(window, GWLP_USERDATA) } as *const Arc<Mutex<Vec<Observed>>>;
    if !pointer.is_null() {
        let event = match message {
            WM_KEYDOWN | WM_KEYUP => match wparam as u16 {
                0x41 => Some(("key", 30, if message == WM_KEYDOWN { 1 } else { 0 })),
                0x53 => Some(("key", 31, if message == WM_KEYDOWN { 1 } else { 0 })),
                0x11 => Some(("key", 29, if message == WM_KEYDOWN { 1 } else { 0 })),
                _ => None,
            },
            WM_MOUSEMOVE => Some(("move", 0, 1)),
            WM_MOUSEWHEEL | WM_MOUSEHWHEEL => Some(("scroll", 0, 1)),
            WM_LBUTTONDOWN => Some(("button", 272, 1)),
            WM_LBUTTONUP => Some(("button", 272, 0)),
            _ => None,
        };
        if let Some((kind, code, value)) = event {
            unsafe { &*pointer }
                .lock()
                .unwrap()
                .push(Observed { kind, code, value });
        }
    }
    unsafe { DefWindowProcW(window, message, wparam, lparam) }
}
pub(super) fn open() -> Result<Witness, String> {
    let events = Arc::new(Mutex::new(Vec::new()));
    let stop = Arc::new(AtomicBool::new(false));
    let recorded = events.clone();
    let done = stop.clone();
    let (ready, initialized) = std::sync::mpsc::channel();
    let thread = std::thread::spawn(move || unsafe {
        let class = "STATIC\0".encode_utf16().collect::<Vec<_>>();
        let title = "Thumble native input witness\0"
            .encode_utf16()
            .collect::<Vec<_>>();
        let window = CreateWindowExW(
            WS_EX_TOPMOST,
            class.as_ptr(),
            title.as_ptr(),
            WS_OVERLAPPEDWINDOW | WS_VISIBLE,
            50,
            50,
            600,
            500,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null(),
        );
        if window.is_null() {
            let _ = ready.send(Err(format!(
                "Create test window: {}",
                std::io::Error::last_os_error()
            )));
            return;
        }
        let recorded = Box::new(recorded);
        SetWindowLongPtrW(
            window,
            GWLP_USERDATA,
            (&*recorded as *const Arc<Mutex<Vec<Observed>>>) as isize,
        );
        SetWindowLongPtrW(window, GWLP_WNDPROC, window_proc as *const () as isize);
        ShowWindow(window, SW_SHOW);
        SetForegroundWindow(window);
        SetFocus(window);
        SetCursorPos(250, 250);
        if GetForegroundWindow() != window {
            DestroyWindow(window);
            let _=ready.send(Err("No interactive foreground desktop. Use an unlocked interactive Windows runner for native delivery; build/loopback success alone is insufficient.".into()));
            return;
        }
        let _ = ready.send(Ok(()));
        while !done.load(Ordering::Acquire) {
            let mut message: MSG = std::mem::zeroed();
            while PeekMessageW(&mut message, std::ptr::null_mut(), 0, 0, PM_REMOVE) != 0 {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        DestroyWindow(window);
    });
    initialized
        .recv_timeout(Duration::from_secs(5))
        .map_err(|e| e.to_string())??;
    Ok(Witness {
        events,
        stop,
        thread: Some(thread),
    })
}
