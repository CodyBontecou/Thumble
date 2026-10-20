//! Portable Thumble controller protocol messages and wire encoding.
//!
//! The JSON model mirrors `Sources/Shared/ControllerProtocol.swift`. Complex
//! control-plane payloads intentionally remain [`serde_json::Value`] values so
//! a Rust host can forward fields introduced by newer clients without losing
//! them.

mod adoption;
mod bounded_json;
pub use bounded_json::{bounded_json_size, encode_bounded_json, BoundedJsonError};
mod message;
pub use adoption::*;
mod profile_formats;
pub use profile_formats::*;
mod strict_json;
mod wire;

pub use strict_json::{decode_unique_json, validate_unique_json};

pub use message::{
    ButtonPressState, ControllerCapability, ControllerMessage, ControllerMessageType,
    ControllerPointerButton, ControllerPointerEventKind, GamepadProfileOrientationPreference,
    KeypadElementID, KeypadElementInputPart, VirtualGamepadStick, VirtualGamepadTrigger,
};
pub use wire::{ControllerWireCodec, ControllerWireCodecError};
