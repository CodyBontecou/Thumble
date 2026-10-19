use super::{Event, Sink};
use evdev::{
    uinput::VirtualDevice, AttributeSet, EventType, InputEvent, KeyCode, RelativeAxisCode,
};

pub struct Linux {
    device: VirtualDevice,
    wheel_x: i32,
    wheel_y: i32,
}
impl Linux {
    pub fn open() -> Result<Self, String> {
        let keys = (0..=126)
            .filter_map(super::key)
            .map(|k| KeyCode::new(k.linux))
            .chain([KeyCode::BTN_LEFT, KeyCode::BTN_RIGHT, KeyCode::BTN_MIDDLE])
            .collect::<AttributeSet<_>>();
        let axes = [
            RelativeAxisCode::REL_X,
            RelativeAxisCode::REL_Y,
            RelativeAxisCode::REL_WHEEL,
            RelativeAxisCode::REL_HWHEEL,
            RelativeAxisCode::REL_WHEEL_HI_RES,
            RelativeAxisCode::REL_HWHEEL_HI_RES,
        ]
        .into_iter()
        .collect::<AttributeSet<_>>();
        let device = VirtualDevice::builder().and_then(|builder| builder.name("Thumble Keyboard and Mouse").with_keys(&keys))
            .and_then(|builder| builder.with_relative_axes(&axes)).and_then(|builder| builder.build())
            .map_err(|e| format!("Create Linux input device: {e}. Enable uinput and grant the logged-in user access to /dev/uinput (see docs/cross-platform-receiver.md); run the receiver without sudo."))?;
        Ok(Self {
            device,
            wheel_x: 0,
            wheel_y: 0,
        })
    }
}
impl Sink for Linux {
    fn emit(&mut self, event: Event) -> Result<(), String> {
        let events = match event {
            Event::Key(key, down) => vec![InputEvent::new(
                EventType::KEY.0,
                key.linux,
                i32::from(down),
            )],
            Event::Button(code, down) => {
                vec![InputEvent::new(EventType::KEY.0, code, i32::from(down))]
            }
            Event::Move(x, y) => vec![
                InputEvent::new(EventType::RELATIVE.0, RelativeAxisCode::REL_X.0, x),
                InputEvent::new(EventType::RELATIVE.0, RelativeAxisCode::REL_Y.0, y),
            ],
            Event::Scroll(x, y) => {
                self.wheel_x += x;
                self.wheel_y += y;
                let low_x = self.wheel_x / 120;
                let low_y = self.wheel_y / 120;
                self.wheel_x %= 120;
                self.wheel_y %= 120;
                vec![
                    InputEvent::new(
                        EventType::RELATIVE.0,
                        RelativeAxisCode::REL_HWHEEL_HI_RES.0,
                        x,
                    ),
                    InputEvent::new(
                        EventType::RELATIVE.0,
                        RelativeAxisCode::REL_WHEEL_HI_RES.0,
                        y,
                    ),
                    InputEvent::new(EventType::RELATIVE.0, RelativeAxisCode::REL_HWHEEL.0, low_x),
                    InputEvent::new(EventType::RELATIVE.0, RelativeAxisCode::REL_WHEEL.0, low_y),
                ]
            }
        };
        self.device
            .emit(&events)
            .map_err(|e| format!("Linux input delivery failed: {e}"))
    }
}
