//! The first connected gamepad as the raw Xbox packet Skate 3 reads.
//!
//! gilrs reads evdev on Linux (where Steam Input presents a Deck or any pad as
//! an Xbox pad) and XInput on Windows and Proton. On macOS Apple's
//! GameController framework goes first: Steam switches a Bluetooth PS5 pad to
//! its full report, which raw HID (and so gilrs) can no longer read.

use std::cell::RefCell;

use gilrs::{Axis, Button, Gilrs};
use skate_bridge::bridge::Controls;

// XInput's button bits, the layout the host's raw packet uses.
const DPAD_UP: u16 = 0x0001;
const DPAD_DOWN: u16 = 0x0002;
const DPAD_LEFT: u16 = 0x0004;
const DPAD_RIGHT: u16 = 0x0008;
const START: u16 = 0x0010;
const BACK: u16 = 0x0020;
const LEFT_THUMB: u16 = 0x0040;
const RIGHT_THUMB: u16 = 0x0080;
const LEFT_SHOULDER: u16 = 0x0100;
const RIGHT_SHOULDER: u16 = 0x0200;
const A: u16 = 0x1000;
const B: u16 = 0x2000;
const X: u16 = 0x4000;
const Y: u16 = 0x8000;

const BUTTONS: [(Button, u16); 14] = [
    (Button::DPadUp, DPAD_UP),
    (Button::DPadDown, DPAD_DOWN),
    (Button::DPadLeft, DPAD_LEFT),
    (Button::DPadRight, DPAD_RIGHT),
    (Button::Start, START),
    (Button::Select, BACK),
    (Button::LeftThumb, LEFT_THUMB),
    (Button::RightThumb, RIGHT_THUMB),
    (Button::LeftTrigger, LEFT_SHOULDER),
    (Button::RightTrigger, RIGHT_SHOULDER),
    (Button::South, A),
    (Button::East, B),
    (Button::West, X),
    (Button::North, Y),
];

thread_local! {
    // Lua always calls in on the same thread, so the pad lives there.
    static PADS: RefCell<Option<Result<Gilrs, String>>> = const { RefCell::new(None) };
}

pub struct Pad {
    pub controls: Controls,
    pub name: Option<String>,
}

/// Polls the pads and returns the first connected one's state.
pub fn poll() -> Result<Pad, String> {
    #[cfg(target_os = "macos")]
    if let Some(pad) = apple::poll() {
        return Ok(pad);
    }
    PADS.with(|pads| {
        let mut pads = pads.borrow_mut();
        let gilrs = pads
            .get_or_insert_with(|| Gilrs::new().map_err(|e| e.to_string()))
            .as_mut()
            .map_err(|e| e.clone())?;
        while gilrs.next_event().is_some() {}
        let Some((_, pad)) = gilrs.gamepads().find(|(_, p)| p.is_connected()) else {
            return Ok(Pad {
                controls: Controls::default(),
                name: None,
            });
        };
        let mut buttons = 0;
        for (button, bit) in BUTTONS {
            if pad.is_pressed(button) {
                buttons |= bit;
            }
        }
        let trigger = |b| {
            let v = pad.button_data(b).map(|d| d.value()).unwrap_or(0.);
            (v.clamp(0., 1.) * 255.).round() as u8
        };
        let stick = |x, y| [axis(pad.value(x)), axis(pad.value(y))];
        Ok(Pad {
            controls: Controls {
                buttons,
                triggers: [
                    trigger(Button::LeftTrigger2),
                    trigger(Button::RightTrigger2),
                ],
                left: stick(Axis::LeftStickX, Axis::LeftStickY),
                right: stick(Axis::RightStickX, Axis::RightStickY),
            },
            name: Some(pad.name().to_owned()),
        })
    })
}

/// -1..1 as XInput's signed 16-bit stick range (up is positive in both).
fn axis(v: f32) -> i16 {
    (v.clamp(-1., 1.) * f32::from(i16::MAX)).round() as i16
}

#[cfg(target_os = "macos")]
mod apple {
    use objc2_game_controller::{GCController, GCControllerButtonInput, GCControllerDirectionPad, GCDevice};

    use super::*;

    /// The first controller with a full gamepad profile, if any.
    pub fn poll() -> Option<Pad> {
        // SAFETY: read-only queries of the framework's live controller state.
        unsafe {
            let controllers = GCController::controllers();
            let (controller, pad) = controllers
                .iter()
                .find_map(|c| c.extendedGamepad().map(|p| (c, p)))?;
            let pressed = |b: &GCControllerButtonInput| b.isPressed();
            let dpad = pad.dpad();
            let mut buttons = 0;
            for (on, bit) in [
                (pressed(&dpad.up()), DPAD_UP),
                (pressed(&dpad.down()), DPAD_DOWN),
                (pressed(&dpad.left()), DPAD_LEFT),
                (pressed(&dpad.right()), DPAD_RIGHT),
                (pressed(&pad.buttonMenu()), START),
                (pad.buttonOptions().is_some_and(|b| pressed(&b)), BACK),
                (pad.leftThumbstickButton().is_some_and(|b| pressed(&b)), LEFT_THUMB),
                (pad.rightThumbstickButton().is_some_and(|b| pressed(&b)), RIGHT_THUMB),
                (pressed(&pad.leftShoulder()), LEFT_SHOULDER),
                (pressed(&pad.rightShoulder()), RIGHT_SHOULDER),
                (pressed(&pad.buttonA()), A),
                (pressed(&pad.buttonB()), B),
                (pressed(&pad.buttonX()), X),
                (pressed(&pad.buttonY()), Y),
            ] {
                if on {
                    buttons |= bit;
                }
            }
            let trigger = |b: &GCControllerButtonInput| (b.value().clamp(0., 1.) * 255.).round() as u8;
            let stick = |s: &GCControllerDirectionPad| [axis(s.xAxis().value()), axis(s.yAxis().value())];
            let name = controller
                .vendorName()
                .map(|n| n.to_string())
                .unwrap_or_else(|| "Controller".to_owned());
            Some(Pad {
                controls: Controls {
                    buttons,
                    triggers: [trigger(&pad.leftTrigger()), trigger(&pad.rightTrigger())],
                    left: stick(&pad.leftThumbstick()),
                    right: stick(&pad.rightThumbstick()),
                },
                name: Some(name),
            })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sticks_cover_the_xinput_range() {
        assert_eq!(axis(1.), i16::MAX);
        assert_eq!(axis(-1.), -i16::MAX);
        assert_eq!(axis(0.), 0);
        assert_eq!(axis(5.), i16::MAX);
    }
}
