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
use std::path::Path;

/// The size at which `annotator.log` moves to `annotator.previous.log`.
const LOG_LIMIT: u64 = 1_000_000;

/// Appends a line to ~/Library/Logs/Annotator/annotator.log and stderr. The log keeps at most
/// about two files of `LOG_LIMIT` bytes.
pub fn log(message: &str) {
    eprintln!("{message}");
    let dir = settings::home().join("Library/Logs/Annotator");
    let time = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    append_bounded(&dir, "annotator", &format!("{time} {message}"), LOG_LIMIT);
}

fn append_bounded(dir: &Path, name: &str, line: &str, limit: u64) {
    let _ = std::fs::create_dir_all(dir);
    let file = dir.join(format!("{name}.log"));
    if std::fs::metadata(&file).is_ok_and(|meta| meta.len() > limit) {
        let _ = std::fs::rename(&file, dir.join(format!("{name}.previous.log")));
    }
    if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(file) {
        let _ = writeln!(file, "{line}");
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

#[cfg(test)]
mod tests {
    #[test]
    fn log_moves_a_full_file_aside() {
        let dir = crate::testutil::temp_dir("annotator-log");
        for index in 0..30 {
            super::append_bounded(&dir, "test", &format!("line {index:02}"), 40);
        }
        let current = std::fs::read_to_string(dir.join("test.log")).unwrap();
        let previous = std::fs::read_to_string(dir.join("test.previous.log")).unwrap();
        assert!(current.len() <= 48 && previous.len() <= 48, "{current:?} {previous:?}");
        assert!(current.ends_with("line 29\n"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
