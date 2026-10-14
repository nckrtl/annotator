//! Annotator's state and flows (AppController.swift). Windows are views of `AppState`, which is
//! emitted as the `state` event after every change.

use crate::annotations::{without_screenshot, AnnotationClient, Item};
use crate::geometry::Rect;
use crate::hotkey::{self, Slot};
use crate::local_server::{self, LocalServer};
use crate::ofide::OperatorQueue;
use crate::pending::{PendingStore, Submitter};
use crate::projects::{ProjectsStore, Routes};
use crate::queue::{Connection, QueueMonitor};
use crate::settings::{home, Settings};
use crate::{helper, panels, windows};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};


#[derive(Debug, Clone, Copy, Default, PartialEq, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Permissions {
    pub accessibility: bool,
    pub screen_recording: bool,
}

impl Permissions {
    pub fn all(&self) -> bool {
        self.accessibility && self.screen_recording
    }
}

#[derive(Default)]
pub struct ServerState {
    pub busy: bool,
    pub running: bool,
    pub error: Option<String>,
}

/// The open comment: the record the helper built, waiting for its comment.
pub struct Comment {
    pub record: Value,
}

pub struct Core {
    pub settings: Settings,
    pub hotkey_error: Option<String>,
    pub permissions: Permissions,
    /// The helper answered at least once since launch.
    pub permissions_known: bool,
    pub annotating: bool,
    pub server: ServerState,
    pub projects: ProjectsStore,
    pub comment: Option<Comment>,
    /// A click elsewhere is moving the comment: when it started and where to select next.
    pub moving: Option<(Instant, f64, f64)>,
    /// The record of the last submitted annotation, to fill in project rules.
    pub last_target: Option<Value>,
    pub helper_error: Option<String>,
    /// Open the Screen Recording pane when the next answer still lacks the permission.
    pub screen_pane_pending: bool,
    /// The queue connection last used to decide whether to ask the local server if it runs.
    pub server_watch: Option<Connection>,
}

pub struct Shared {
    pub core: Mutex<Core>,
    pub queue: Arc<QueueMonitor>,
    pub submitter: Arc<Submitter>,
    pub ofide: OperatorQueue,
    pub permission_waiters: Mutex<Vec<tokio::sync::oneshot::Sender<Permissions>>>,
}

pub fn shared(app: &crate::runtime::AppHandle) -> Arc<Shared> {
    app.state::<Shared>()
}

fn with<T>(app: &crate::runtime::AppHandle, f: impl FnOnce(&mut Core) -> T) -> T {
    let state = shared(app);
    let mut core = state.core.lock().unwrap();
    f(&mut core)
}

pub fn settings(app: &crate::runtime::AppHandle) -> Settings {
    with(app, |core| core.settings.clone())
}

pub fn client(app: &crate::runtime::AppHandle) -> Option<AnnotationClient> {
    settings(app).server().map(AnnotationClient::new)
}

fn local_server(settings: &Settings) -> Option<LocalServer> {
    settings.server().and_then(|url| LocalServer::new(&url, &home()))
}

// MARK: - Setup

pub fn setup(app: &crate::runtime::AppHandle) {
    let settings = Settings::load(&Settings::file());
    let on_change = app.clone();
    let submitter = Arc::new(Submitter::new(PendingStore::standard(), move || emit_state(&on_change)));
    let changed = app.clone();
    let reachable = app.clone();
    let queue = QueueMonitor::new(move || queue_changed(&changed), move || {
        let app = reachable.clone();
        crate::runtime::spawn(async move { retry_pending(&app).await });
    });
    app.manage(Shared {
        core: Mutex::new(Core {
            settings,
            hotkey_error: None,
            permissions: Permissions::default(),
            permissions_known: false,
            annotating: false,
            server: ServerState::default(),
            projects: ProjectsStore::new(Routes::standard_file()),
            comment: None,
            moving: None,
            last_target: None,
            helper_error: None,
            screen_pane_pending: false,
            server_watch: None,
        }),
        queue,
        submitter,
        ofide: OperatorQueue::default(),
        permission_waiters: Mutex::default(),
    });

    // The helper answers with `online` and `permissions`; onboarding opens when one is missing.
    if let Err(error) = helper::send(app, &json!({"action": "permissions"})) {
        with(app, |core| core.helper_error = Some(error.clone()));
        crate::log(&error);
    }
    refresh_server_status(app, settings_auto_start(app));
    register_hotkey(app);
    shared(app).queue.start(client(app));
    let retry = app.clone();
    crate::runtime::spawn(async move { retry_pending(&retry).await });
    emit_state(app);
}

fn settings_auto_start(app: &crate::runtime::AppHandle) -> bool {
    with(app, |core| core.settings.server_auto_start)
}

// MARK: - State

/// One status for the menu's first line and the tray tooltip.
/// Error: the server cannot be used. Warning: something needs attention. Ok: all good.
pub fn health(connection: &Connection, pending: usize, failed: usize, permissions: bool, hotkey_error: bool,
    helper_error: bool) -> (&'static str, String) {
    match connection {
        Connection::Unreachable(message) => return ("error", message.clone()),
        Connection::WrongServer => return ("error", "Not an @nckrtl/annotator server".into()),
        Connection::InvalidUrl => return ("error", "The server URL in Settings is not valid".into()),
        Connection::Connecting => return ("warning", "Connecting…".into()),
        Connection::Live | Connection::Polling => {}
    }
    if pending > 0 { return ("warning", format!("Connected · {pending} not sent yet")); }
    if failed > 0 { return ("warning", format!("Connected · {failed} refused")); }
    if !permissions { return ("warning", "Connected · permissions missing".into()); }
    if hotkey_error { return ("warning", "Connected · shortcut not registered".into()); }
    if helper_error { return ("warning", "Connected · native helper stopped".into()); }
    ("ok", if *connection == Connection::Live { "Connected".into() } else { "Connected · polling every 3 s".into() })
}

pub fn app_state(app: &crate::runtime::AppHandle) -> Value {
    let state = shared(app);
    let connection = state.queue.connection();
    let summary = state.queue.summary();
    let counts = state.submitter.counts();
    let core = state.core.lock().unwrap();
    let (tone, title) = health(&connection, counts.pending, counts.failed, core.permissions.all(),
        core.hotkey_error.is_some(), core.helper_error.is_some());
    let local = local_server(&core.settings).map(|server| json!({
        "busy": core.server.busy, "running": core.server.running, "error": core.server.error,
        "hasLog": server.log().exists(),
    }));
    let queue = summary.map(|s| json!({
        "todo": s.todo, "inProgress": s.in_progress, "done": s.done,
        "open": s.open,
        "finished": s.finished,
    }));
    let projects = &core.projects.routes.projects;
    json!({
        "health": {"tone": tone, "title": title},
        "serverURL": core.settings.server_url,
        "localServer": local,
        "queueReachable": !matches!(connection, Connection::Unreachable(_)),
        "annotating": core.annotating,
        "commentOpen": core.comment.is_some(),
        "hotkey": {"keyCode": core.settings.hotkey.key_code, "modifiers": core.settings.hotkey.modifiers,
            "display": core.settings.hotkey.display()},
        "hotkeyError": core.hotkey_error,
        "permissions": core.permissions,
        "queue": queue,
        "pending": {"count": counts.pending, "lastError": counts.last_retry_error},
        "failedCount": counts.failed,
        "projects": projects.iter().map(|p| json!({"id": p.id, "name": p.name, "root": p.root})).collect::<Vec<_>>(),
        "projectsError": core.projects.error,
        "helperError": core.helper_error,
    })
}

/// Emits `state` to every window and updates the menu bar item.
pub fn emit_state(app: &crate::runtime::AppHandle) {
    if app.try_state::<Shared>().is_none() {
        return;
    }
    let state = app_state(app);
    let _ = app.emit("state", &state);
}


/// The queue or the connection changed.
fn queue_changed(app: &crate::runtime::AppHandle) {
    emit_state(app);
    let _ = app.emit("queue", shared(app).queue.items());
    // Ask the local server only when the connection changes, not on every queue event.
    let connection = shared(app).queue.connection();
    let changed = with(app, |core| {
        let changed = core.server_watch.as_ref() != Some(&connection);
        core.server_watch = Some(connection.clone());
        changed
    });
    if changed && !matches!(connection, Connection::Connecting | Connection::InvalidUrl) {
        refresh_server_status(app, false);
    }
}

pub async fn retry_pending(app: &crate::runtime::AppHandle) {
    let submitter = shared(app).submitter.clone();
    submitter.retry_pending(client(app)).await;
}

// MARK: - System helpers

/// A native alert. Annotator activates first, as an accessory app.
pub fn alert(app: &crate::runtime::AppHandle, title: &str, message: &str) {
    let _ = app.emit("alert", json!({"title": title, "message": message}));
}

pub fn copy(text: &str) -> Result<(), String> {
    use std::io::Write;
    let mut child = std::process::Command::new("/usr/bin/pbcopy").stdin(std::process::Stdio::piped()).spawn()
        .map_err(|e| format!("Could not copy: {e}"))?;
    child.stdin.take().ok_or("Could not copy")?.write_all(text.as_bytes()).map_err(|e| format!("Could not copy: {e}"))?;
    child.wait().map_err(|e| format!("Could not copy: {e}"))?;
    Ok(())
}

/// Opens a URL or a file with its default app, like NSWorkspace.open.
pub fn open(target: &str) -> Result<(), String> {
    let status = std::process::Command::new("/usr/bin/open").arg(target).status().map_err(|e| e.to_string())?;
    if status.success() { Ok(()) } else { Err(format!("Could not open {target}.")) }
}

// MARK: - Local server

/// Reads whether the local server runs; with `auto_start`, starts it unless another server answers.
pub fn refresh_server_status(app: &crate::runtime::AppHandle, auto_start: bool) {
    let server = with(app, |core| {
        let server = local_server(&core.settings).filter(|_| !core.server.busy)?;
        core.server.busy = true;
        Some(server)
    });
    let Some(server) = server else { return };
    let app = app.clone();
    crate::runtime::spawn(async move {
        let result = async {
            let status = server.run("status").await?;
            let same = || local_server(&settings(&app)).is_some_and(|s| s.state() == server.state());
            if !same() {
                return Ok(());
            }
            with(&app, |core| {
                core.server.running = status.running;
                core.server.error = None;
            });
            if auto_start && !status.running {
                // An existing external server can serve the queue without becoming ours.
                let url = settings(&app).server();
                if url.is_some() && !local_server::answers(url.as_ref().unwrap()).await {
                    let started = server.run("start").await?;
                    with(&app, |core| core.server.running = started.running);
                    shared(&app).queue.start(client(&app));
                }
            }
            Ok::<(), String>(())
        }.await;
        with(&app, |core| {
            if let Err(error) = result {
                core.server.error = Some(error);
            }
            core.server.busy = false;
        });
        emit_state(&app);
    });
}

/// `start`, `stop` or `restart`.
pub async fn server_control(app: &crate::runtime::AppHandle, command: &str) -> Result<(), String> {
    if !matches!(command, "start" | "stop" | "restart") {
        return Err(format!("Unknown server action: {command}"));
    }
    let server = with(app, |core| {
        let server = local_server(&core.settings).filter(|_| !core.server.busy)?;
        core.server.busy = true;
        core.server.error = None;
        Some(server)
    });
    let Some(server) = server else { return Ok(()) };
    emit_state(app);
    let result = async {
        if command == "restart" {
            server.run("stop").await?;
        }
        server.run(if command == "restart" { "start" } else { command }).await
    }.await;
    let outcome = match result {
        Ok(outcome) => {
            if local_server(&settings(app)).is_some_and(|s| s.state() == server.state()) {
                with(app, |core| core.server.running = outcome.running);
            }
            shared(app).queue.start(client(app));
            Ok(())
        }
        Err(error) => {
            with(app, |core| core.server.error = Some(error.clone()));
            alert(app, &format!("Could not {command} the server"), &error);
            Err(error)
        }
    };
    with(app, |core| core.server.busy = false);
    emit_state(app);
    outcome
}

pub fn show_server_log(app: &crate::runtime::AppHandle) -> Result<(), String> {
    let server = local_server(&settings(app)).ok_or("Start and stop are available for a local HTTP server.")?;
    open(&server.log().to_string_lossy())
}

// MARK: - Hotkeys

pub fn register_hotkey(app: &crate::runtime::AppHandle) {
    let hotkey = settings(app).hotkey;
    let error = hotkey::register(app, Slot::Toggle, hotkey.key_code, hotkey.modifiers)
        .map(|message| format!("{}: {message}", hotkey.display()));
    if let Some(error) = &error {
        crate::log(&format!("Shortcut not registered: {error}"));
    }
    with(app, |core| core.hotkey_error = error);
    emit_state(app);
}

/// Esc is a global hotkey while hovering, so it works without taking focus from the app underneath.
/// Keep it through the comment so Operator cannot take Escape away from Annotator.
fn register_escape(app: &crate::runtime::AppHandle) {
    let _ = hotkey::register(app, Slot::Escape, 53, 0);
}

pub fn hotkey_pressed(app: &crate::runtime::AppHandle, slot: Slot) {
    match slot {
        Slot::Toggle => toggle(app),
        Slot::Escape => stop_annotating(app),
    }
}

// MARK: - Annotate mode

pub fn toggle(app: &crate::runtime::AppHandle) {
    if with(app, |core| core.annotating || core.comment.is_some()) { stop_annotating(app) } else { start_annotating(app) }
}

fn start_annotating(app: &crate::runtime::AppHandle) {
    if !with(app, |core| core.permissions.all()) {
        let _ = helper::send(app, &json!({"action": "permissions"}));
        windows::open_onboarding(app);
        return;
    }
    if let Err(error) = helper::send(app, &json!({"action": "annotate", "on": true})) {
        crate::log(&error);
        with(app, |core| core.helper_error = Some(error));
        emit_state(app);
        return;
    }
    with(app, |core| core.annotating = true);
    register_escape(app);
    emit_state(app);
}

/// Ends selection. A frozen screen stays behind the comment as a backdrop, so a closed menu still shows.
pub fn release_overlay(app: &crate::runtime::AppHandle) {
    let _ = helper::send(app, &json!({"action": "annotate", "on": false, "backdrop": true}));
    let commenting = with(app, |core| { core.annotating = false; core.moving = None; core.comment.is_some() });
    if commenting { register_escape(app); } else { hotkey::unregister(app, Slot::Escape); }
    emit_state(app);
}

pub fn stop_annotating(app: &crate::runtime::AppHandle) {
    drop_comment(app);
    let _ = helper::send(app, &json!({"action": "annotate", "on": false}));
    with(app, |core| core.annotating = false);
    hotkey::unregister(app, Slot::Escape);
    emit_state(app);
}

/// Closes the comment panel without resuming the overlay; the view cancels Operator.
fn drop_comment(app: &crate::runtime::AppHandle) {
    let had = with(app, |core| {
        core.moving = None;
        core.comment.take().is_some()
    });
    if had {
        panels::hide_comment(app);
        let _ = app.emit_to("comment", "comment-cancel", ());
    }
}

// MARK: - Helper events

pub fn helper_event(app: &crate::runtime::AppHandle, event: Value) {
    if app.try_state::<Shared>().is_none() {
        return;
    }
    match event["type"].as_str().unwrap_or_default() {
        "online" => {
            with(app, |core| core.helper_error = None);
            let _ = helper::send(app, &json!({"action": "permissions"}));
            emit_state(app);
        }
        "permissions" => permissions_changed(app, Permissions {
            accessibility: event["accessibility"].as_bool().unwrap_or(false),
            screen_recording: event["screenRecording"].as_bool().unwrap_or(false),
        }),
        "selected" => selected(app, event),
        "clickWhileFrozen" => move_comment(app, event["x"].as_f64().unwrap_or(0.0), event["y"].as_f64().unwrap_or(0.0)),
        "escape" | "overlay-timeout" => stop_annotating(app),
        "log" => crate::log(&format!("helper: {}", event["message"].as_str().unwrap_or_default())),
        "error" => {
            let message = event["message"].as_str().unwrap_or("The native helper failed.").to_string();
            crate::log(&format!("helper error: {message}"));
            with(app, |core| core.helper_error = Some(message));
            emit_state(app);
        }
        other => crate::log(&format!("helper sent an unknown event: {other}")),
    }
}

/// The helper stopped: the overlay is gone, so annotate mode ends.
pub fn helper_stopped(app: &crate::runtime::AppHandle, message: Option<String>) {
    if app.try_state::<Shared>().is_none() {
        return;
    }
    drop_comment(app);
    with(app, |core| {
        core.annotating = false;
        core.helper_error = message;
    });
    hotkey::unregister(app, Slot::Escape);
    emit_state(app);
}

fn permissions_changed(app: &crate::runtime::AppHandle, permissions: Permissions) {
    let (first, open_pane) = with(app, |core| {
        let first = !core.permissions_known;
        core.permissions_known = true;
        core.permissions = permissions;
        let open_pane = core.screen_pane_pending && !permissions.screen_recording;
        core.screen_pane_pending = false;
        (first, open_pane)
    });
    for waiter in shared(app).permission_waiters.lock().unwrap().drain(..) {
        let _ = waiter.send(permissions);
    }
    if open_pane {
        let _ = open(&privacy_url("screenRecording"));
    }
    if first && !permissions.all() {
        windows::open_onboarding(app);
    }
    emit_state(app);
}

/// Asks the helper and waits up to 2 s; the last known answer otherwise.
pub async fn fresh_permissions(app: &crate::runtime::AppHandle) -> Permissions {
    let (sender, receiver) = tokio::sync::oneshot::channel();
    shared(app).permission_waiters.lock().unwrap().push(sender);
    if helper::send(app, &json!({"action": "permissions"})).is_ok() {
        if let Ok(Ok(permissions)) = tokio::time::timeout(Duration::from_secs(2), receiver).await {
            return permissions;
        }
    }
    with(app, |core| core.permissions)
}

pub fn privacy_url(kind: &str) -> String {
    let pane = if kind == "accessibility" { "Privacy_Accessibility" } else { "Privacy_ScreenCapture" };
    format!("x-apple.systempreferences:com.apple.preference.security?{pane}")
}

/// Accessibility: prompt, which adds Annotator to the list, and open the pane. Screen Recording:
/// request, and open the pane when macOS does not grant it.
pub fn request_permission(app: &crate::runtime::AppHandle, kind: &str) -> Result<(), String> {
    if kind == "accessibility" {
        helper::send(app, &json!({"action": "requestAccessibility"}))?;
        open(&privacy_url(kind))
    } else {
        with(app, |core| core.screen_pane_pending = true);
        helper::send(app, &json!({"action": "requestScreenCapture"}))
    }
}

// MARK: - Comment

fn selected(app: &crate::runtime::AppHandle, event: Value) {
    hotkey::unregister(app, Slot::Escape);
    let Some(record) = event.get("record").filter(|r| r.is_object()).cloned() else {
        crate::log("The helper sent a selection without a record.");
        return;
    };
    let frame: Option<Rect> = serde_json::from_value(event["frame"].clone()).ok();
    let settings = settings(app);
    let opened = with(app, |core| {
        if !core.annotating {
            return false;
        }
        core.comment = Some(Comment { record });
        core.moving = None;
        true
    });
    if !opened {
        return;
    }
    release_overlay(app);
    let dictation = settings.ofide_enabled.then(|| json!({
        "autoStart": settings.ofide_auto_start,
    }));
    let target = json!({
        "label": event["label"].as_str().unwrap_or_default(),
        "mode": event["mode"].as_str().unwrap_or("element"),
        "bundleId": event["record"]["native"]["app"]["bundleId"].as_str(),
        "captureError": event["captureError"].as_str(),
        "dictation": dictation,
    });
    let _ = app.emit_to("comment", "comment-opened", target);
    panels::show_comment(app, frame.unwrap_or(Rect::new(0.0, 0.0, 0.0, 0.0)));
    emit_state(app);
}

/// Close the panel. Normal selections already released the overlay.
fn comment_closed(app: &crate::runtime::AppHandle) {
    panels::hide_comment(app);
    hotkey::unregister(app, Slot::Escape);
    let annotating = with(app, |core| {
        core.moving = None;
        core.annotating
    });
    if annotating {
        let _ = helper::send(app, &json!({"action": "resume"}));
        register_escape(app);
    } else {
        let _ = helper::send(app, &json!({"action": "annotate", "on": false}));
    }
    emit_state(app);
}

/// Closes the panel at once and posts in the background. The menu shows the result.
pub fn submit_comment(app: &crate::runtime::AppHandle, text: &str) -> Result<(), String> {
    let text = text.trim().to_string();
    if text.is_empty() {
        return Err("Write a comment first.".into());
    }
    let Some(mut record) = with(app, |core| {
        let mut comment = core.comment.take()?;
        // Pick up edits made to routes.json by hand.
        core.projects.reload();
        comment.record["comment"] = json!(text);
        if comment.record["native"].is_object() {
            comment.record["native"]["project"] = json!(core.projects.project_name(&comment.record));
        }
        core.last_target = Some(without_screenshot(&comment.record));
        Some(comment.record)
    }) else {
        return Ok(()); // Already posted.
    };
    comment_closed(app);
    let id = record["id"].as_str().unwrap_or_default().to_string();
    if id.is_empty() {
        record["id"] = json!(uuid::Uuid::new_v4().to_string());
    }
    let id = record["id"].as_str().unwrap_or_default().to_string();
    let body = serde_json::to_vec(&record).map_err(|e| format!("Could not encode the record: {e}"))?;
    let app = app.clone();
    crate::runtime::spawn(async move {
        let submitter = shared(&app).submitter.clone();
        let result = submitter.submit(&id, body, client(&app)).await;
        crate::log(&format!("Annotation {id}: {}", result.message()));
        emit_state(&app);
    });
    Ok(())
}

pub fn cancel_comment(app: &crate::runtime::AppHandle) {
    stop_annotating(app);
    panels::hide_comment(app);
}

/// Like the web annotator: a click elsewhere stops dictation, waits for the paste, submits the
/// open comment, and opens a new one at the click. The view finishes dictation first.
fn move_comment(app: &crate::runtime::AppHandle, x: f64, y: f64) {
    let start = with(app, |core| {
        // A finish that never answered does not block clicks forever (a stop waits at most 125 s).
        let busy = core.moving.is_some_and(|(at, _, _)| at.elapsed() < Duration::from_secs(130));
        if core.comment.is_none() || busy {
            return false;
        }
        core.moving = Some((Instant::now(), x, y));
        true
    });
    if start {
        let _ = app.emit_to("comment", "comment-finish", ());
    }
}

/// The view finished dictation. `keep`: it failed, so the panel stays open and says why.
pub fn comment_finish_done(app: &crate::runtime::AppHandle, submit: bool, text: &str, keep: bool) {
    let Some((_, x, y)) = with(app, |core| core.moving.take()) else { return };
    if keep {
        return;
    }
    if with(app, |core| core.comment.is_some()) {
        if submit && !text.trim().is_empty() {
            let _ = submit_comment(app, text);
        } else {
            cancel_comment(app);
        }
    }
    hotkey::unregister(app, Slot::Escape);
    if with(app, |core| core.annotating) {
        let _ = helper::send(app, &json!({"action": "selectAt", "x": x, "y": y}));
    }
}

// MARK: - Menu

pub fn menu_opened(app: &crate::runtime::AppHandle) {
    let _ = helper::send(app, &json!({"action": "permissions"}));
    with(app, |core| core.projects.reload());
    emit_state(app);
}

/// Deletes every to-do and in-progress annotation on the server. Done ones stay.
pub async fn clear_open(app: &crate::runtime::AppHandle) -> usize {
    let (Some(summary), Some(client)) = (shared(app).queue.summary(), client(app)) else { return 0 };
    let mut failed = 0;
    for item in &summary.open {
        if !client.delete(item.id()).await {
            failed += 1;
        }
    }
    shared(app).queue.refresh_now(Some(client));
    failed
}

pub fn open_annotation(app: &crate::runtime::AppHandle, id: &str) -> Result<(), String> {
    // Window labels allow only a-z, A-Z, 0-9, `-`, `/`, `:` and `_`; server ids are a subset.
    if !crate::annotations::is_valid_id(id) {
        return Err(format!("Not an annotation id: {id}"));
    }
    let number = shared(app).queue.summary().and_then(|s| s.item(id).and_then(|i| i.number()));
    windows::open_detail(app, id, number);
    // The new window reads the list with get_queue; send it too for windows that missed it.
    queue_changed_detail_only(app);
    Ok(())
}

fn queue_changed_detail_only(app: &crate::runtime::AppHandle) {
    let items = shared(app).queue.items();
    let _ = app.emit("queue", items);
}

pub fn save_settings(app: &crate::runtime::AppHandle, new: Settings) -> Result<Settings, String> {
    let (old, merged) = with(app, |core| {
        let merged = core.settings.merged(new);
        (core.settings.clone(), merged)
    });
    merged.save(&Settings::file())?;
    with(app, |core| core.settings = merged.clone());
    if old.server_url != merged.server_url {
        with(app, |core| core.server.running = false);
        refresh_server_status(app, false);
        shared(app).queue.start(client(app));
    }
    if old.hotkey != merged.hotkey {
        register_hotkey(app);
    }
    emit_state(app);
    Ok(merged)
}

pub fn relaunch(app: &crate::runtime::AppHandle) { let _ = app.emit("relaunch", ()); }

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn health_order() {
        let live = Connection::Live;
        assert_eq!(health(&Connection::WrongServer, 1, 1, false, true, true), ("error", "Not an @nckrtl/annotator server".into()));
        assert_eq!(health(&Connection::Unreachable("Server unreachable: x".into()), 0, 0, true, false, false),
            ("error", "Server unreachable: x".into()));
        assert_eq!(health(&Connection::InvalidUrl, 0, 0, true, false, false).1, "The server URL in Settings is not valid");
        assert_eq!(health(&Connection::Connecting, 0, 0, true, false, false), ("warning", "Connecting…".into()));
        assert_eq!(health(&live, 2, 1, false, true, false), ("warning", "Connected · 2 not sent yet".into()));
        assert_eq!(health(&live, 0, 1, false, true, false), ("warning", "Connected · 1 refused".into()));
        assert_eq!(health(&live, 0, 0, false, true, false), ("warning", "Connected · permissions missing".into()));
        assert_eq!(health(&live, 0, 0, true, true, false), ("warning", "Connected · shortcut not registered".into()));
        assert_eq!(health(&live, 0, 0, true, false, false), ("ok", "Connected".into()));
        assert_eq!(health(&Connection::Polling, 0, 0, true, false, false), ("ok", "Connected · polling every 3 s".into()));
    }

    #[test]
    fn privacy_panes() {
        assert_eq!(privacy_url("accessibility"), "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility");
        assert_eq!(privacy_url("screenRecording"), "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture");
    }
}
