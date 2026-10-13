//! Hosts the menu and comment webviews in native NSPanels, as Ofide's history.rs does.
//! An ordinary NSWindow cannot join another app's full-screen Space, and borderless windows
//! refuse key status. Tauri's windows stay hidden and keep the webviews and their events.

use objc2::runtime::{AnyClass, AnyObject, Bool, ClassBuilder, Sel};
use objc2::{class, msg_send, sel};
use objc2_foundation::{NSPoint, NSRect};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use crate::geometry::{comment_origin, Rect, Screen};
use tauri::{Emitter, Manager};

// NSWindowCollectionBehavior: all Spaces, stationary, ignoresCycle, fullScreenAuxiliary and
// canJoinAllApplications, so a panel opens over another app's full-screen Space.
const COLLECTION_BEHAVIOR: usize = (1 << 0) | (1 << 4) | (1 << 6) | (1 << 8) | (1 << 18);
/// NSPopUpMenuWindowLevel: above the helper's overlay, which uses the status bar level.
const POPUP_MENU_LEVEL: isize = 101;
/// The menu panel never grows taller than this; longer lists scroll inside it.
pub const MENU_MAX_HEIGHT: f64 = 640.0;
const NONACTIVATING_PANEL: usize = 1 << 7;

static MENU: AtomicUsize = AtomicUsize::new(0);
static COMMENT: AtomicUsize = AtomicUsize::new(0);
static MENU_SHOWN: Mutex<Option<Instant>> = Mutex::new(None);
static MENU_DISMISSED: Mutex<Option<Instant>> = Mutex::new(None);

fn recent(time: &Mutex<Option<Instant>>, ms: u64) -> bool {
    time.lock().ok().is_some_and(|t| t.is_some_and(|t| t.elapsed() < Duration::from_millis(ms)))
}

unsafe extern "C-unwind" fn can_become_key(_: &AnyObject, _: Sel) -> Bool {
    Bool::YES
}

/// The menu closes when it stops being key, like a menu.
unsafe extern "C-unwind" fn menu_resign_key(this: &AnyObject, _: Sel) {
    let _: () = msg_send![super(this, class!(NSPanel)), resignKeyWindow];
    // The click that opened the panel can end its key status at once; keep it open then.
    if recent(&MENU_SHOWN, 400) {
        return;
    }
    let _: () = msg_send![this, orderOut: std::ptr::null_mut::<AnyObject>()];
    *MENU_DISMISSED.lock().unwrap() = Some(Instant::now());
}

fn menu_class() -> &'static AnyClass {
    static CLASS: OnceLock<&'static AnyClass> = OnceLock::new();
    CLASS.get_or_init(|| {
        let mut builder = ClassBuilder::new(c"AnnotatorMenuPanel", class!(NSPanel)).expect("AnnotatorMenuPanel");
        unsafe {
            builder.add_method(sel!(canBecomeKeyWindow), can_become_key as unsafe extern "C-unwind" fn(_, _) -> _);
            builder.add_method(sel!(resignKeyWindow), menu_resign_key as unsafe extern "C-unwind" fn(_, _));
        }
        builder.register()
    })
}

/// The comment panel stays open when it loses key status: the user may look something up.
fn comment_class() -> &'static AnyClass {
    static CLASS: OnceLock<&'static AnyClass> = OnceLock::new();
    CLASS.get_or_init(|| {
        let mut builder = ClassBuilder::new(c"AnnotatorKeyPanel", class!(NSPanel)).expect("AnnotatorKeyPanel");
        unsafe {
            builder.add_method(sel!(canBecomeKeyWindow), can_become_key as unsafe extern "C-unwind" fn(_, _) -> _);
        }
        builder.register()
    })
}

/// Moves the webview of window `label` into a new panel of `class`.
fn wrap(app: &tauri::AppHandle, label: &str, class: &AnyClass) -> tauri::Result<*mut AnyObject> {
    let window = app.get_webview_window(label).expect("panel window");
    unsafe {
        let original = window.ns_window()? as *mut AnyObject;
        let frame: NSRect = msg_send![original, frame];
        let allocated: *mut AnyObject = msg_send![class, alloc];
        let panel: *mut AnyObject = msg_send![allocated,
            initWithContentRect: frame, styleMask: NONACTIVATING_PANEL, backing: 2usize, defer: false];
        assert!(!panel.is_null(), "panel for {label}");
        let _: () = msg_send![panel, setReleasedWhenClosed: false];
        let title: *mut AnyObject = msg_send![original, title];
        let _: () = msg_send![panel, setTitle: title];
        let _: () = msg_send![panel, setOpaque: false];
        let clear: *mut AnyObject = msg_send![class!(NSColor), clearColor];
        let _: () = msg_send![panel, setBackgroundColor: clear];
        let _: () = msg_send![panel, setHasShadow: true];
        let _: () = msg_send![panel, setLevel: POPUP_MENU_LEVEL];
        let _: () = msg_send![panel, setHidesOnDeactivate: false];
        let _: () = msg_send![panel, setMovable: false];
        let _: () = msg_send![panel, setCollectionBehavior: COLLECTION_BEHAVIOR];
        let content: *mut AnyObject = msg_send![original, contentView];
        let _: *mut AnyObject = msg_send![content, retain];
        let _: () = msg_send![original, setContentView: std::ptr::null_mut::<AnyObject>()];
        let _: () = msg_send![panel, setContentView: content];
        let _: () = msg_send![content, release];
        Ok(panel)
    }
}

pub fn setup(app: &tauri::AppHandle) -> tauri::Result<()> {
    MENU.store(wrap(app, "menu", menu_class())? as usize, Ordering::Relaxed);
    COMMENT.store(wrap(app, "comment", comment_class())? as usize, Ordering::Relaxed);
    Ok(())
}

fn panel(slot: &AtomicUsize) -> *mut AnyObject {
    slot.load(Ordering::Relaxed) as *mut AnyObject
}

/// Makes `panel` key and gives the webview of `label` the keyboard.
unsafe fn focus(app: &tauri::AppHandle, label: &str, panel: *mut AnyObject) {
    let _: () = msg_send![panel, makeKeyAndOrderFront: std::ptr::null_mut::<AnyObject>()];
    let address = panel as usize;
    if let Some(window) = app.get_webview_window(label) {
        let _ = window.with_webview(move |webview| {
            let panel = address as *mut AnyObject;
            let _: bool = msg_send![panel, makeFirstResponder: webview.inner() as *mut AnyObject];
        });
    }
}

/// The screen under the cursor and the cursor, in AppKit coordinates.
unsafe fn cursor_screen() -> (NSPoint, NSRect) {
    let cursor: NSPoint = msg_send![class!(NSEvent), mouseLocation];
    let screens: *mut AnyObject = msg_send![class!(NSScreen), screens];
    let count: usize = msg_send![screens, count];
    for index in 0..count {
        let screen: *mut AnyObject = msg_send![screens, objectAtIndex: index];
        let frame: NSRect = msg_send![screen, frame];
        if cursor.x >= frame.origin.x && cursor.x < frame.origin.x + frame.size.width
            && cursor.y >= frame.origin.y && cursor.y < frame.origin.y + frame.size.height
        {
            return (cursor, msg_send![screen, visibleFrame]);
        }
    }
    let main: *mut AnyObject = msg_send![class!(NSScreen), mainScreen];
    (cursor, msg_send![main, visibleFrame])
}

/// Opens the menu under the menu bar icon, or closes it.
pub fn toggle_menu(app: &tauri::AppHandle) {
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || unsafe {
        let panel = panel(&MENU);
        let visible: bool = msg_send![panel, isVisible];
        if visible {
            let _: () = msg_send![panel, orderOut: std::ptr::null_mut::<AnyObject>()];
            return;
        }
        // A click on the icon ends the panel's key status before this handler runs.
        // Treat that as the close, and ignore the click that caused it.
        if recent(&MENU_DISMISSED, 300) {
            return;
        }
        let (cursor, visible) = cursor_screen();
        let frame: NSRect = msg_send![panel, frame];
        let margin = 8.0;
        let min_x = visible.origin.x + margin;
        let max_x = visible.origin.x + visible.size.width - frame.size.width - margin;
        let x = (cursor.x - frame.size.width / 2.0).clamp(min_x, max_x.max(min_x));
        let y = visible.origin.y + visible.size.height - frame.size.height - 4.0;
        let _: () = msg_send![panel, setFrameOrigin: NSPoint::new(x, y)];
        *MENU_SHOWN.lock().unwrap() = Some(Instant::now());
        let _ = handle.emit_to("menu", "menu-opened", ());
        focus(&handle, "menu", panel);
        let opened = handle.clone();
        tauri::async_runtime::spawn(async move { crate::app::menu_opened(&opened) });
    });
}

pub fn hide_menu(app: &tauri::AppHandle) {
    let _ = app.run_on_main_thread(|| unsafe {
        let _: () = msg_send![panel(&MENU), orderOut: std::ptr::null_mut::<AnyObject>()];
    });
}

/// All screens in AppKit coordinates, the main one first, and the cursor.
unsafe fn screens() -> (Vec<Screen>, (f64, f64)) {
    let cursor: NSPoint = msg_send![class!(NSEvent), mouseLocation];
    let list: *mut AnyObject = msg_send![class!(NSScreen), screens];
    let count: usize = msg_send![list, count];
    let rect = |r: NSRect| Rect::new(r.origin.x, r.origin.y, r.size.width, r.size.height);
    let screens = (0..count).map(|index| {
        let screen: *mut AnyObject = msg_send![list, objectAtIndex: index];
        let frame: NSRect = msg_send![screen, frame];
        let visible: NSRect = msg_send![screen, visibleFrame];
        Screen { frame: rect(frame), visible: rect(visible) }
    }).collect();
    (screens, (cursor.x, cursor.y))
}

/// Activates Annotator, an accessory app, so its window takes the keyboard.
pub fn activate(app: &tauri::AppHandle) {
    let _ = app.run_on_main_thread(|| unsafe {
        let ns_app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let _: () = msg_send![ns_app, activateIgnoringOtherApps: true];
    });
}

/// Opens the comment panel next to `target` (global top-left points) and activates Annotator,
/// so typing and Ofide's ⌘V paste land in its field.
pub fn show_comment(app: &tauri::AppHandle, target: Rect) {
    let handle = app.clone();
    let _ = app.run_on_main_thread(move || unsafe {
        let panel = panel(&COMMENT);
        let (screens, cursor) = screens();
        let frame: NSRect = msg_send![panel, frame];
        let (x, y) = comment_origin(target, &screens, cursor, (frame.size.width, frame.size.height));
        let _: () = msg_send![panel, setFrameOrigin: NSPoint::new(x, y)];
        let ns_app: *mut AnyObject = msg_send![class!(NSApplication), sharedApplication];
        let _: () = msg_send![ns_app, activateIgnoringOtherApps: true];
        focus(&handle, "comment", panel);
    });
}

/// Sets a panel's height and keeps its top edge where it is.
unsafe fn set_height(panel: *mut AnyObject, height: f64) {
    let mut frame: NSRect = msg_send![panel, frame];
    if (frame.size.height - height).abs() < 0.5 {
        return;
    }
    frame.origin.y += frame.size.height - height;
    frame.size.height = height;
    let _: () = msg_send![panel, setFrame: frame, display: true];
}

/// The comment view reports its content height.
pub fn resize_comment(app: &tauri::AppHandle, height: f64) {
    let _ = app.run_on_main_thread(move || unsafe { set_height(panel(&COMMENT), height.max(40.0)) });
}

/// The menu view reports its content height; the panel follows up to MENU_MAX_HEIGHT.
pub fn resize_menu(app: &tauri::AppHandle, height: f64) {
    let _ = app.run_on_main_thread(move || unsafe { set_height(panel(&MENU), height.clamp(40.0, MENU_MAX_HEIGHT)) });
}

pub fn hide_comment(app: &tauri::AppHandle) {
    let _ = app.run_on_main_thread(|| unsafe {
        let _: () = msg_send![panel(&COMMENT), orderOut: std::ptr::null_mut::<AnyObject>()];
    });
}
