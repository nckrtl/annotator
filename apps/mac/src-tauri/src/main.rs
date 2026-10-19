#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod annotations;
mod app;
mod commands;
mod geometry;
mod helper;
mod hotkey;
mod http;
mod local_server;
mod operator;
mod panels;
mod pending;
mod projects;
mod queue;
mod retention;
mod service_url;
mod settings;
#[cfg(test)]
mod testutil;
mod windows;
mod runtime;

use std::io::Write;
/// Appends a line to ~/Library/Logs/Annotator/annotator.log and stderr.
pub fn log(message: &str) {
    eprintln!("{message}");
    let dir = settings::home().join("Library/Logs/Annotator");
    let _ = std::fs::create_dir_all(&dir);
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(dir.join("annotator.log")) {
        let time = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
        let _ = writeln!(file, "{time} {message}");
    }
}

#[tokio::main]
async fn main() {
    use std::io::BufRead;
    crate::runtime::initialize();
    let app = crate::runtime::AppHandle::default();
    app.manage(helper::Helper::default());
    app::setup(&app);
    let reader = app.clone();
    tokio::task::spawn_blocking(move || {
        for line in std::io::stdin().lock().lines().map_while(Result::ok) {
            let request: serde_json::Value = match serde_json::from_str(&line) { Ok(v) => v, Err(e) => { log(&format!("Bad request: {e}")); continue; } };
            let app = reader.clone();
            crate::runtime::spawn(async move {
                let result = commands::dispatch(app.clone(), request["command"].as_str().unwrap_or(""), request["args"].clone()).await;
                let reply = match result {
                    Ok(value) => serde_json::json!({"id": request["id"], "result": value}),
                    Err(error) => serde_json::json!({"id": request["id"], "error": error}),
                };
                crate::runtime::write(&reply);
            });
        }
    }).await.ok();
    helper::stop(&app);
}
