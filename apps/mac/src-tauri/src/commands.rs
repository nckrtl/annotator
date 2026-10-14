//! The commands the windows invoke (docs/port.md §2). Each one is a thin wrapper around app.rs.

use crate::app::{self, shared};
use crate::projects::{agent_prompt, Routes, Scope};
use crate::settings::{home, Settings};
use crate::{helper, ofide, panels, windows};
use serde_json::{json, Value};
use crate::runtime::AppHandle;

// MARK: - Menu

pub fn get_state(app: AppHandle) -> Value {
    app::app_state(&app)
}

pub fn toggle_annotating(app: AppHandle) {
    panels::hide_menu(&app);
    app::toggle(&app);
}

pub async fn server_control(app: AppHandle, action: String) -> Result<(), String> {
    app::server_control(&app, &action).await
}

pub fn show_server_log(app: AppHandle) -> Result<(), String> {
    panels::hide_menu(&app);
    app::show_server_log(&app)
}

pub fn open_server(app: AppHandle) -> Result<(), String> {
    panels::hide_menu(&app);
    let url = app::settings(&app).server().ok_or("The server URL in Settings is not valid")?;
    app::open(url.as_str())
}

pub fn open_settings(app: AppHandle, tab: Option<String>) {
    windows::open_settings(&app, tab);
}

pub fn open_onboarding(app: AppHandle) {
    windows::open_onboarding(&app);
}

pub fn open_annotation(app: AppHandle, id: String) -> Result<(), String> {
    app::open_annotation(&app, &id)
}

pub async fn clear_open(app: AppHandle) -> Value {
    json!({"failed": app::clear_open(&app).await})
}

pub fn retry_now(app: AppHandle) {
    crate::runtime::spawn(async move { app::retry_pending(&app).await });
}

pub fn show_failed(app: AppHandle) -> Result<(), String> {
    panels::hide_menu(&app);
    let folder = shared(&app).submitter.store.failed_directory();
    let _ = std::fs::create_dir_all(&folder);
    app::open(&folder.to_string_lossy())
}

fn project(app: &AppHandle, id: &str) -> Result<crate::projects::Project, String> {
    app::shared(app).core.lock().unwrap().projects.routes.projects.iter().find(|p| p.id == id).cloned()
        .ok_or_else(|| format!("No project with id {id}."))
}

/// `scope`: `inbox`, `all` or a project id.
pub fn copy_prompt(app: AppHandle, scope: String) -> Result<(), String> {
    let server = app::settings(&app).server_url;
    let text = match scope.as_str() {
        "inbox" => agent_prompt(&server, &Scope::Inbox),
        "all" => agent_prompt(&server, &Scope::All),
        id => agent_prompt(&server, &Scope::Project(&project(&app, id)?)),
    };
    app::copy(&text)
}

pub fn hide_menu(app: AppHandle) {
    panels::hide_menu(&app);
}

pub fn quit_app(app: AppHandle) {
    app.exit(0);
}

pub fn resize_menu(app: AppHandle, height: f64) {
    panels::resize_menu(&app, height);
}

// MARK: - Comment

pub fn submit_comment(app: AppHandle, text: String) -> Result<(), String> {
    app::submit_comment(&app, &text)
}

pub fn cancel_comment(app: AppHandle) {
    app::cancel_comment(&app);
}

pub fn resize_comment(app: AppHandle, height: f64) {
    panels::resize_comment(&app, height);
}

/// Proxies Operator's Local API: `status`, `start`, `stop` or `cancel`. Rejects only for setup errors.
pub async fn ofide(app: AppHandle, action: String) -> Result<Value, String> {
    let settings = app::settings(&app);
    let base = settings.ofide().ok_or("The Operator URL in Settings is not valid.")?;
    let token = ofide::read_token(&ofide::token_file(crate::settings::OFIDE, &home()))?;
    let client = ofide::OperatorClient::new(base, token);
    let answer = shared(&app).ofide.run(&client, &action).await?;
    if action != "status" {
        crate::log(&format!("Operator {action}: {}", answer.result.name()));
    }
    Ok(answer.json())
}

pub fn alert(app: AppHandle, title: String, message: String) {
    app::alert(&app, &title, &message);
}

// MARK: - Settings

pub fn get_settings(app: AppHandle) -> Settings {
    app::settings(&app)
}

pub fn save_settings(app: AppHandle, settings: Settings) -> Result<Settings, String> {
    app::save_settings(&app, settings)
}

/// Pauses the toggle shortcut while the recorder listens.
pub fn hotkey_recording(app: AppHandle, recording: bool) {
    if recording {
        crate::hotkey::unregister(&app, crate::hotkey::Slot::Toggle);
    } else {
        app::register_hotkey(&app);
    }
}

pub fn get_projects(app: AppHandle) -> Value {
    let state = shared(&app);
    let mut core = state.core.lock().unwrap();
    core.projects.reload();
    json!({"routes": core.projects.routes, "error": core.projects.error, "file": core.projects.file.to_string_lossy()})
}

/// Null on success, or why the file was not saved.
pub fn save_projects(app: AppHandle, routes: Routes) -> Option<String> {
    let result = shared(&app).core.lock().unwrap().projects.update(routes);
    app::emit_state(&app);
    result.err()
}


/// The app of the last annotation, to fill in a project's app rule quickly.
pub fn last_target_app(app: AppHandle) -> Value {
    let record = shared(&app).core.lock().unwrap().last_target.clone();
    let Some(record) = record else { return Value::Null };
    let native = &record["native"];
    json!({"name": native["app"]["name"], "bundleId": native["app"]["bundleId"]})
}

// MARK: - Onboarding

pub fn request_permission(app: AppHandle, kind: String) -> Result<(), String> {
    app::request_permission(&app, &kind)
}

pub fn open_privacy(kind: String) -> Result<(), String> {
    app::open(&app::privacy_url(&kind))
}

pub fn relaunch(app: AppHandle) {
    app::relaunch(&app);
}

pub async fn get_permissions(app: AppHandle) -> app::Permissions {
    app::fresh_permissions(&app).await
}

// MARK: - Detail

pub fn get_queue(app: AppHandle) -> Vec<Value> {
    shared(&app).queue.items()
}

/// The screenshot of one record. The live queue does not keep them.
pub async fn get_screenshot(app: AppHandle, id: String) -> Option<String> {
    app::client(&app)?.screenshot(&id).await
}

pub async fn delete_annotation(app: AppHandle, id: String) -> Result<(), String> {
    let client = app::client(&app).ok_or("The server URL in Settings is not valid")?;
    let deleted = client.delete(&id).await;
    shared(&app).queue.refresh_now(Some(client));
    if deleted {
        Ok(())
    } else {
        Err("The server did not accept the request. Check that it is running, then try again.".into())
    }
}

// MARK: - Development

pub fn helper(app: AppHandle, command: Value) -> Result<(), String> {
    helper::send(&app, &command)
}

pub fn log_message(message: String) {
    crate::log(&message);
}

pub async fn dispatch(app: AppHandle, command: &str, args: Value) -> Result<Value, String> {
 match command {
"get_state" => {  serde_json::to_value(get_state(app.clone())).map_err(|e| e.to_string()) },
"toggle_annotating" => {  serde_json::to_value(toggle_annotating(app.clone())).map_err(|e| e.to_string()) },
"server_control" => { let action: String = serde_json::from_value(args["action"].clone()).map_err(|e| format!("action: {e}"))?; serde_json::to_value(server_control(app.clone(), action).await?).map_err(|e| e.to_string()) },
"show_server_log" => {  serde_json::to_value(show_server_log(app.clone())?).map_err(|e| e.to_string()) },
"open_server" => {  serde_json::to_value(open_server(app.clone())?).map_err(|e| e.to_string()) },
"open_settings" => { let tab: Option<String> = serde_json::from_value(args["tab"].clone()).map_err(|e| format!("tab: {e}"))?; serde_json::to_value(open_settings(app.clone(), tab)).map_err(|e| e.to_string()) },
"open_onboarding" => {  serde_json::to_value(open_onboarding(app.clone())).map_err(|e| e.to_string()) },
"open_annotation" => { let id: String = serde_json::from_value(args["id"].clone()).map_err(|e| format!("id: {e}"))?; serde_json::to_value(open_annotation(app.clone(), id)?).map_err(|e| e.to_string()) },
"clear_open" => {  serde_json::to_value(clear_open(app.clone()).await).map_err(|e| e.to_string()) },
"retry_now" => {  serde_json::to_value(retry_now(app.clone())).map_err(|e| e.to_string()) },
"show_failed" => {  serde_json::to_value(show_failed(app.clone())?).map_err(|e| e.to_string()) },
"copy_prompt" => { let scope: String = serde_json::from_value(args["scope"].clone()).map_err(|e| format!("scope: {e}"))?; serde_json::to_value(copy_prompt(app.clone(), scope)?).map_err(|e| e.to_string()) },
"hide_menu" => {  serde_json::to_value(hide_menu(app.clone())).map_err(|e| e.to_string()) },
"quit_app" => {  serde_json::to_value(quit_app(app.clone())).map_err(|e| e.to_string()) },
"resize_menu" => { let height: f64 = serde_json::from_value(args["height"].clone()).map_err(|e| format!("height: {e}"))?; serde_json::to_value(resize_menu(app.clone(), height)).map_err(|e| e.to_string()) },
"submit_comment" => { let text: String = serde_json::from_value(args["text"].clone()).map_err(|e| format!("text: {e}"))?; serde_json::to_value(submit_comment(app.clone(), text)?).map_err(|e| e.to_string()) },
"release_overlay" => { app::release_overlay(&app); Ok(Value::Null) },
"stop_annotating" => { app::stop_annotating(&app); Ok(Value::Null) },
"cancel_comment" => {  serde_json::to_value(cancel_comment(app.clone())).map_err(|e| e.to_string()) },
"resize_comment" => { let height: f64 = serde_json::from_value(args["height"].clone()).map_err(|e| format!("height: {e}"))?; serde_json::to_value(resize_comment(app.clone(), height)).map_err(|e| e.to_string()) },
"ofide" => { let action: String = serde_json::from_value(args["action"].clone()).map_err(|e| format!("action: {e}"))?; serde_json::to_value(ofide(app.clone(), action).await?).map_err(|e| e.to_string()) },
"alert" => { let title: String = serde_json::from_value(args["title"].clone()).map_err(|e| format!("title: {e}"))?; let message: String = serde_json::from_value(args["message"].clone()).map_err(|e| format!("message: {e}"))?; serde_json::to_value(alert(app.clone(), title, message)).map_err(|e| e.to_string()) },
"get_settings" => {  serde_json::to_value(get_settings(app.clone())).map_err(|e| e.to_string()) },
"save_settings" => { let settings: Settings = serde_json::from_value(args["settings"].clone()).map_err(|e| format!("settings: {e}"))?; serde_json::to_value(save_settings(app.clone(), settings)?).map_err(|e| e.to_string()) },
"hotkey_recording" => { let recording: bool = serde_json::from_value(args["recording"].clone()).map_err(|e| format!("recording: {e}"))?; serde_json::to_value(hotkey_recording(app.clone(), recording)).map_err(|e| e.to_string()) },
"get_projects" => {  serde_json::to_value(get_projects(app.clone())).map_err(|e| e.to_string()) },
"save_projects" => { let routes: Routes = serde_json::from_value(args["routes"].clone()).map_err(|e| format!("routes: {e}"))?; serde_json::to_value(save_projects(app.clone(), routes)).map_err(|e| e.to_string()) },
"last_target_app" => {  serde_json::to_value(last_target_app(app.clone())).map_err(|e| e.to_string()) },
"request_permission" => { let kind: String = serde_json::from_value(args["kind"].clone()).map_err(|e| format!("kind: {e}"))?; serde_json::to_value(request_permission(app.clone(), kind)?).map_err(|e| e.to_string()) },
"open_privacy" => { let kind: String = serde_json::from_value(args["kind"].clone()).map_err(|e| format!("kind: {e}"))?; serde_json::to_value(open_privacy(kind)?).map_err(|e| e.to_string()) },
"relaunch" => {  serde_json::to_value(relaunch(app.clone())).map_err(|e| e.to_string()) },
"get_permissions" => {  serde_json::to_value(get_permissions(app.clone()).await).map_err(|e| e.to_string()) },
"get_queue" => {  serde_json::to_value(get_queue(app.clone())).map_err(|e| e.to_string()) },
"get_screenshot" => { let id: String = serde_json::from_value(args["id"].clone()).map_err(|e| format!("id: {e}"))?; serde_json::to_value(get_screenshot(app.clone(), id).await).map_err(|e| e.to_string()) },
"delete_annotation" => { let id: String = serde_json::from_value(args["id"].clone()).map_err(|e| format!("id: {e}"))?; serde_json::to_value(delete_annotation(app.clone(), id).await?).map_err(|e| e.to_string()) },
"helper" => { let command: Value = serde_json::from_value(args["command"].clone()).map_err(|e| format!("command: {e}"))?; serde_json::to_value(helper(app.clone(), command)?).map_err(|e| e.to_string()) },
"log_message" => { let message: String = serde_json::from_value(args["message"].clone()).map_err(|e| format!("message: {e}"))?; serde_json::to_value(log_message(message)).map_err(|e| e.to_string()) },
"comment_origin" => {
    let target = serde_json::from_value(args["target"].clone()).map_err(|e| e.to_string())?;
    let screens: Vec<crate::geometry::Screen> = serde_json::from_value(args["screens"].clone()).map_err(|e| e.to_string())?;
    let mouse: (f64, f64) = serde_json::from_value(args["mouse"].clone()).map_err(|e| e.to_string())?;
    let size: (f64, f64) = serde_json::from_value(args["size"].clone()).map_err(|e| e.to_string())?;
    Ok(json!(crate::geometry::comment_origin(target, &screens, mouse, size)))
},
"menu_opened" => { app::menu_opened(&app); Ok(Value::Null) },
"hotkey_pressed" => { app::hotkey_pressed(&app, if args["slot"] == 2 { crate::hotkey::Slot::Escape } else { crate::hotkey::Slot::Toggle }); Ok(Value::Null) },
"hotkey_error" => { shared(&app).core.lock().unwrap().hotkey_error = args["message"].as_str().map(str::to_owned); app::emit_state(&app); Ok(Value::Null) },
_ => Err(format!("Unknown command: {command}")),
} }
