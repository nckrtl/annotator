//! Global shortcuts through Carbon `RegisterEventHotKey` (HotKeyCenter.swift). They need no
//! permission, and macOS consumes the keystroke. Slot 1 toggles annotate mode; slot 2 is Esc while
//! hovering. All Carbon calls run on the main thread.

use std::ffi::c_void;
use std::ptr;
use std::sync::{mpsc, Mutex};
use std::time::Duration;

type Ref = *mut c_void;
#[repr(C)]
#[derive(Default)]
struct HotKeyId {
    signature: u32,
    id: u32,
}
#[repr(C)]
struct EventType {
    class: u32,
    kind: u32,
}
const SIGNATURE: u32 = u32::from_be_bytes(*b"ANNT");
const KEYBOARD: u32 = u32::from_be_bytes(*b"keyb");
const DIRECT_OBJECT: u32 = u32::from_be_bytes(*b"----");
const HOTKEY_ID: u32 = u32::from_be_bytes(*b"hkid");
const PRESSED: u32 = 5;
const NOT_HANDLED: i32 = -9874;
const EXISTS: i32 = -9878;

#[link(name = "Carbon", kind = "framework")]
extern "C" {
    fn GetApplicationEventTarget() -> Ref;
    fn InstallEventHandler(target: Ref, callback: unsafe extern "C" fn(Ref, Ref, Ref) -> i32,
        count: u32, events: *const EventType, data: Ref, handler: *mut Ref) -> i32;
    fn RegisterEventHotKey(code: u32, modifiers: u32, id: HotKeyId, target: Ref, options: u32, key: *mut Ref) -> i32;
    fn UnregisterEventHotKey(key: Ref) -> i32;
    fn GetEventParameter(event: Ref, name: u32, kind: u32, actual: *mut u32,
        size: u32, actual_size: *mut u32, data: Ref) -> i32;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Slot {
    Toggle = 1,
    Escape = 2,
}

struct State {
    handler: bool,
    keys: [Option<usize>; 3],
}
static STATE: Mutex<State> = Mutex::new(State { handler: false, keys: [None; 3] });

/// The message for a refused registration, as HotKeyCenter.swift words it.
pub fn message(code: i32) -> String {
    if code == EXISTS {
        "Another app already uses this shortcut.".into()
    } else {
        format!("macOS refused the shortcut (error {code}).")
    }
}

unsafe extern "C" fn pressed(_: Ref, event: Ref, data: Ref) -> i32 {
    let mut id = HotKeyId::default();
    if GetEventParameter(event, DIRECT_OBJECT, HOTKEY_ID, ptr::null_mut(),
        std::mem::size_of::<HotKeyId>() as u32, ptr::null_mut(), &mut id as *mut _ as Ref) != 0
        || id.signature != SIGNATURE
    {
        return NOT_HANDLED;
    }
    let slot = match id.id {
        1 => Slot::Toggle,
        2 => Slot::Escape,
        _ => return NOT_HANDLED,
    };
    let app = (*(data as *const tauri::AppHandle)).clone();
    // Never take Annotator's locks inside a Carbon callback on the main thread.
    tauri::async_runtime::spawn(async move { crate::app::hotkey_pressed(&app, slot) });
    0
}

/// Runs `f` on the main thread and waits for its result. On the main thread already, Tauri runs it at once.
fn on_main<T: Send + 'static>(app: &tauri::AppHandle, f: impl FnOnce(&tauri::AppHandle) -> T + Send + 'static) -> Option<T> {
    let (sender, receiver) = mpsc::channel();
    let handle = app.clone();
    app.run_on_main_thread(move || {
        let _ = sender.send(f(&handle));
    }).ok()?;
    receiver.recv_timeout(Duration::from_secs(2)).ok()
}

/// Registers `slot`, replacing what it had. Returns an error message when macOS refuses it.
pub fn register(app: &tauri::AppHandle, slot: Slot, key_code: u32, modifiers: u32) -> Option<String> {
    on_main(app, move |app| unsafe {
        let mut state = STATE.lock().unwrap();
        if let Some(key) = state.keys[slot as usize].take() {
            UnregisterEventHotKey(key as Ref);
        }
        let target = GetApplicationEventTarget();
        if !state.handler {
            // The handler and its AppHandle live as long as the app.
            let data = Box::into_raw(Box::new(app.clone()));
            let event = EventType { class: KEYBOARD, kind: PRESSED };
            let mut handler = ptr::null_mut();
            let code = InstallEventHandler(target, pressed, 1, &event, data as Ref, &mut handler);
            if code != 0 {
                drop(Box::from_raw(data));
                return Some(message(code));
            }
            state.handler = true;
        }
        let mut key = ptr::null_mut();
        let code = RegisterEventHotKey(key_code, modifiers, HotKeyId { signature: SIGNATURE, id: slot as u32 }, target, 0, &mut key);
        if code != 0 || key.is_null() {
            return Some(message(code));
        }
        state.keys[slot as usize] = Some(key as usize);
        None
    })
    .unwrap_or_else(|| Some("The shortcut could not be registered.".into()))
}

pub fn unregister(app: &tauri::AppHandle, slot: Slot) {
    let _ = on_main(app, move |_| unsafe {
        if let Some(key) = STATE.lock().unwrap().keys[slot as usize].take() {
            UnregisterEventHotKey(key as Ref);
        }
    });
}

#[cfg(test)]
mod tests {
    #[test]
    fn messages() {
        assert_eq!(super::message(-9878), "Another app already uses this shortcut.");
        assert_eq!(super::message(-50), "macOS refused the shortcut (error -50).");
    }
}
