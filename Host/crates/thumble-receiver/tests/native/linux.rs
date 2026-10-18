use super::*;
use evdev::{Device, EventType};
pub(super) fn open() -> Result<Witness, String> {
    let mut device = None;
    for _ in 0..200 {
        for (path, found) in evdev::enumerate() {
            if found.name() == Some("Thumble Keyboard and Mouse") {
                device = Some(Device::open(path).map_err(|e| e.to_string())?);
                break;
            }
        }
        if device.is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let mut device = device
        .ok_or("Cannot read Thumble's /dev/input event node; configure the test udev rule")?;
    device.set_nonblocking(true).map_err(|e| e.to_string())?;
    let events = Arc::new(Mutex::new(Vec::new()));
    let stop = Arc::new(AtomicBool::new(false));
    let recorded = events.clone();
    let done = stop.clone();
    let thread = std::thread::spawn(move || {
        while !done.load(Ordering::Acquire) {
            match device.fetch_events() {
                Ok(batch) => {
                    for event in batch {
                        let kind = if event.event_type() == EventType::KEY {
                            if event.code() >= 272 {
                                "button"
                            } else {
                                "key"
                            }
                        } else if event.event_type() == EventType::RELATIVE {
                            if event.code() == 0 || event.code() == 1 {
                                "move"
                            } else {
                                "scroll"
                            }
                        } else {
                            continue;
                        };
                        let code = if kind == "move" || kind == "scroll" {
                            0
                        } else {
                            event.code()
                        };
                        let value = if kind == "move" || kind == "scroll" {
                            if event.value() == 0 {
                                continue;
                            }
                            1
                        } else {
                            event.value()
                        };
                        recorded
                            .lock()
                            .unwrap()
                            .push(Observed { kind, code, value });
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => (),
                Err(_) => break,
            }
            std::thread::sleep(Duration::from_millis(2));
        }
    });
    Ok(Witness {
        events,
        stop,
        thread: Some(thread),
    })
}
