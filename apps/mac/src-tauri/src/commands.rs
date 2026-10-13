//! The commands the windows invoke (docs/port.md §2). Each one is a thin wrapper around app.rs.

use crate::app::{self, shared};
use crate::conn::{self, keychain};
use crate::projects::{agent_prompt, Routes, Scope};
use crate::settings::{home, Settings};
use crate::{helper, ofide, panels, windows};
use serde_json::{json, Value};
use tauri::AppHandle;

// MARK: - Menu

#[tauri::command]
pub fn get_state(app: AppHandle) -> Value {
    app::app_state(&app)
}

#[tauri::command]
pub fn toggle_annotating(app: AppHandle) {
    panels::hide_menu(&app);
    app::toggle(&app);
}

#[tauri::command]
pub async fn server_control(app: AppHandle, action: String) -> Result<(), String> {
    app::server_control(&app, &action).await
}

#[tauri::command]
pub fn show_server_log(app: AppHandle) -> Result<(), String> {
    panels::hide_menu(&app);
    app::show_server_log(&app)
}

#[tauri::command]
pub fn open_server(app: AppHandle) -> Result<(), String> {
    panels::hide_menu(&app);
    let url = app::settings(&app).server().ok_or("The server URL in Settings is not valid")?;
    app::open(url.as_str())
}

#[tauri::command]
pub fn open_settings(app: AppHandle, tab: Option<String>) {
    windows::open_settings(&app, tab);
}

#[tauri::command]
pub fn open_onboarding(app: AppHandle) {
    windows::open_onboarding(&app);
}

#[tauri::command]
pub fn open_annotation(app: AppHandle, id: String) -> Result<(), String> {
    app::open_annotation(&app, &id)
}

#[tauri::command]
pub async fn clear_open(app: AppHandle) -> Value {
    json!({"failed": app::clear_open(&app).await})
}

#[tauri::command]
pub fn retry_now(app: AppHandle) {
    tauri::async_runtime::spawn(async move { app::retry_pending(&app).await });
}

#[tauri::command]
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

#[tauri::command]
pub async fn conn_start(app: AppHandle, project_id: String) -> Result<(), String> {
    let project = project(&app, &project_id)?;
    let settings = app::settings(&app);
    let prompt = agent_prompt(&settings.server_url, &Scope::Project(&project));
    let conn = shared(&app).conn.clone();
    let result = conn.start(&settings, &project, &prompt).await.map(|_| ());
    app::emit_state(&app);
    if let Err(message) = &result {
        app::alert(&app, "Conn", message);
    }
    result
}

#[tauri::command]
pub async fn conn_open(app: AppHandle, project_id: String) -> Result<(), String> {
    panels::hide_menu(&app);
    let project = project(&app, &project_id)?;
    let conn = shared(&app).conn.clone();
    let result = conn.open(&app::settings(&app), &project).await;
    app::emit_state(&app);
    if let Err(message) = &result {
        app::alert(&app, "Conn", message);
    }
    result
}

/// For adding the session server in a Conn window: Settings › Connections › Add environment.
#[tauri::command]
pub async fn conn_pairing_url(app: AppHandle) -> Result<String, String> {
    let conn = shared(&app).conn.clone();
    let result = conn.pairing_url(&app::settings(&app)).await;
    app::emit_state(&app);
    match result {
        Ok(url) => {
            app::copy(&url)?;
            app::alert(&app, "Pairing URL copied",
                "In Conn, open Settings › Connections › Add environment, choose the remote option and paste it. It works once and expires in 15 minutes.");
            Ok(url)
        }
        Err(message) => {
            app::alert(&app, "Conn", &message);
            Err(message)
        }
    }
}

/// `scope`: `inbox`, `all` or a project id.
#[tauri::command]
pub fn copy_prompt(app: AppHandle, scope: String) -> Result<(), String> {
    let server = app::settings(&app).server_url;
    let text = match scope.as_str() {
        "inbox" => agent_prompt(&server, &Scope::Inbox),
        "all" => agent_prompt(&server, &Scope::All),
        id => agent_prompt(&server, &Scope::Project(&project(&app, id)?)),
    };
    app::copy(&text)
}

#[tauri::command]
pub fn hide_menu(app: AppHandle) {
    panels::hide_menu(&app);
}

#[tauri::command]
pub fn quit_app(app: AppHandle) {
    app.exit(0);
}

#[tauri::command]
pub fn resize_menu(app: AppHandle, height: f64) {
    panels::resize_menu(&app, height);
}

// MARK: - Comment

#[tauri::command]
pub fn submit_comment(app: AppHandle, text: String) -> Result<(), String> {
    app::submit_comment(&app, &text)
}

#[tauri::command]
pub fn cancel_comment(app: AppHandle) {
    app::cancel_comment(&app);
}

#[tauri::command]
pub fn comment_finish_done(app: AppHandle, submit: bool, text: String, keep: Option<bool>) {
    app::comment_finish_done(&app, submit, &text, keep.unwrap_or(false));
}

#[tauri::command]
pub fn resize_comment(app: AppHandle, height: f64) {
    panels::resize_comment(&app, height);
}

/// Proxies Ofide's Local API: `status`, `start`, `stop` or `cancel`. Rejects only for setup errors.
#[tauri::command]
pub async fn ofide(app: AppHandle, action: String) -> Result<Value, String> {
    let settings = app::settings(&app);
    let base = settings.ofide().ok_or("The Ofide URL in Settings is not valid.")?;
    let token = ofide::read_token(&ofide::token_file(&settings.ofide_app, &home()))?;
    let client = ofide::OfideClient::new(base, token);
    let answer = shared(&app).ofide.run(&client, &action).await?;
    if action != "status" {
        crate::log(&format!("Ofide {action}: {}", answer.result.name()));
    }
    Ok(answer.json())
}

#[tauri::command]
pub fn alert(app: AppHandle, title: String, message: String) {
    app::alert(&app, &title, &message);
}

// MARK: - Settings

#[tauri::command]
pub fn get_settings(app: AppHandle) -> Settings {
    app::settings(&app)
}

#[tauri::command]
pub fn save_settings(app: AppHandle, settings: Settings) -> Result<Settings, String> {
    app::save_settings(&app, settings)
}

/// Pauses the toggle shortcut while the recorder listens.
#[tauri::command]
pub fn hotkey_recording(app: AppHandle, recording: bool) {
    if recording {
        crate::hotkey::unregister(&app, crate::hotkey::Slot::Toggle);
    } else {
        app::register_hotkey(&app);
    }
}

#[tauri::command]
pub fn conn_save_connection(app: AppHandle, endpoint: String, token: String) -> Result<String, String> {
    let endpoint = conn::endpoint(&endpoint)?;
    if !token.is_empty() {
        keychain::save(&token, &endpoint).map_err(|e| e.to_string())?;
    }
    let mut settings = app::settings(&app);
    settings.t3_endpoint = endpoint;
    app::save_settings(&app, settings)?;
    Ok("Connection saved.".into())
}

#[tauri::command]
pub fn conn_token_saved(endpoint: String) -> bool {
    matches!(keychain::read(&endpoint), Ok(Some(_)))
}

#[tauri::command]
pub fn get_projects(app: AppHandle) -> Value {
    let state = shared(&app);
    let mut core = state.core.lock().unwrap();
    core.projects.reload();
    json!({"routes": core.projects.routes, "error": core.projects.error, "file": core.projects.file.to_string_lossy()})
}

/// Null on success, or why the file was not saved.
#[tauri::command]
pub fn save_projects(app: AppHandle, routes: Routes) -> Option<String> {
    let result = shared(&app).core.lock().unwrap().projects.update(routes);
    app::emit_state(&app);
    result.err()
}

#[tauri::command]
pub async fn choose_folder(app: AppHandle) -> Option<String> {
    use tauri_plugin_dialog::DialogExt;
    let folder = app.dialog().file().blocking_pick_folder()?;
    folder.into_path().ok().map(|path| path.to_string_lossy().into_owned())
}

/// The app and window of the last annotation, to fill in project rules quickly.
#[tauri::command]
pub fn last_target_app(app: AppHandle) -> Value {
    let record = shared(&app).core.lock().unwrap().last_target.clone();
    let Some(record) = record else { return Value::Null };
    let native = &record["native"];
    json!({"name": native["app"]["name"], "bundleId": native["app"]["bundleId"],
        "title": native["window"]["title"], "url": native["webUrl"]})
}

// MARK: - Onboarding

#[tauri::command]
pub fn request_permission(app: AppHandle, kind: String) -> Result<(), String> {
    app::request_permission(&app, &kind)
}

#[tauri::command]
pub fn open_privacy(kind: String) -> Result<(), String> {
    app::open(&app::privacy_url(&kind))
}

#[tauri::command]
pub fn relaunch(app: AppHandle) {
    app::relaunch(&app);
}

#[tauri::command]
pub async fn get_permissions(app: AppHandle) -> app::Permissions {
    app::fresh_permissions(&app).await
}

// MARK: - Detail

#[tauri::command]
pub fn get_queue(app: AppHandle) -> Vec<Value> {
    shared(&app).queue.items()
}

/// The screenshot of one record. The live queue does not keep them.
#[tauri::command]
pub async fn get_screenshot(app: AppHandle, id: String) -> Option<String> {
    app::client(&app)?.screenshot(&id).await
}

#[tauri::command]
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

#[tauri::command]
pub fn helper(app: AppHandle, command: Value) -> Result<(), String> {
    helper::send(&app, &command)
}

#[tauri::command(rename_all = "snake_case")]
pub fn log_message(message: String) {
    crate::log(&message);
}
