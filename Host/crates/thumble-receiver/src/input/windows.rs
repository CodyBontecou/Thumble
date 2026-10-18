use super::{Event, Sink};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::*;
pub struct Windows;
impl Sink for Windows {
    fn emit(&mut self, event: Event) -> Result<(), String> {
        let mut input: INPUT = unsafe { std::mem::zeroed() };
        match event {
            Event::Key(key, down) => {
                input.r#type = INPUT_KEYBOARD;
                input.Anonymous.ki = KEYBDINPUT {
                    wVk: 0,
                    wScan: key.scan & 0xff,
                    dwFlags: KEYEVENTF_SCANCODE
                        | if down { 0 } else { KEYEVENTF_KEYUP }
                        | if key.scan & 0x100 != 0 {
                            KEYEVENTF_EXTENDEDKEY
                        } else {
                            0
                        },
                    time: 0,
                    dwExtraInfo: 0,
                };
            }
            other => {
                let (dx, dy, mouse_data, dw_flags) = match other {
                    Event::Move(x, y) => (x, y, 0, MOUSEEVENTF_MOVE),
                    Event::Scroll(x, y) => {
                        // Send each wheel axis separately (one mouseData field).
                        if x != 0 {
                            send_mouse(0, 0, x as u32, MOUSEEVENTF_HWHEEL)?;
                        }
                        if y == 0 {
                            return Ok(());
                        }
                        (0, 0, y as u32, MOUSEEVENTF_WHEEL)
                    }
                    Event::Button(code, down) => (
                        0,
                        0,
                        0,
                        match (code, down) {
                            (272, true) => MOUSEEVENTF_LEFTDOWN,
                            (272, false) => MOUSEEVENTF_LEFTUP,
                            (273, true) => MOUSEEVENTF_RIGHTDOWN,
                            (273, false) => MOUSEEVENTF_RIGHTUP,
                            (274, true) => MOUSEEVENTF_MIDDLEDOWN,
                            (274, false) => MOUSEEVENTF_MIDDLEUP,
                            _ => return Err("Unsupported pointer button".into()),
                        },
                    ),
                    _ => unreachable!(),
                };
                return send_mouse(dx, dy, mouse_data, dw_flags);
            }
        }
        send(&input)
    }
}
fn send_mouse(dx: i32, dy: i32, data: u32, flags: u32) -> Result<(), String> {
    let input = INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx,
                dy,
                mouseData: data,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };
    send(&input)
}
fn send(input: &INPUT) -> Result<(), String> {
    // SAFETY: input is initialized with the union variant matching its type.
    if unsafe { SendInput(1, input, std::mem::size_of::<INPUT>() as i32) } == 1 {
        Ok(())
    } else {
        Err(format!("Windows SendInput failed: {}. Windows blocks input into elevated apps and secure desktops from a normal user receiver.",std::io::Error::last_os_error()))
    }
}
