//! Carbon registration lives on the SwiftUI host's main thread.
use crate::runtime::AppHandle;
use serde_json::json;
#[derive(Clone, Copy)]
pub enum Slot { Toggle = 1, Escape = 2 }
pub fn register(app: &AppHandle, slot: Slot, key_code: u32, modifiers: u32) -> Option<String> {
    let _ = app.emit("register-hotkey", json!({"slot": slot as u32, "keyCode": key_code, "modifiers": modifiers}));
    None
}
pub fn unregister(app: &AppHandle, slot: Slot) { let _ = app.emit("unregister-hotkey", slot as u32); }
