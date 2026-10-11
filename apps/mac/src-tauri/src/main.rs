#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
mod annotations;
mod app;
mod commands;
mod conn;
mod geometry;
mod helper;
mod hotkey;
mod http;
mod local_server;
mod ofide;
mod panels;
mod pending;
mod projects;
mod queue;
mod service_url;
mod settings;
#[cfg(test)]
mod testutil;
mod windows;

use std::io::Write;
use tauri::tray::{MouseButtonState, TrayIconBuilder, TrayIconEvent};

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

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(helper::Helper::default())
        .invoke_handler(tauri::generate_handler![
            commands::get_state,
            commands::toggle_annotating,
            commands::server_control,
            commands::show_server_log,
            commands::open_server,
            commands::open_settings,
            commands::open_onboarding,
            commands::open_annotation,
            commands::clear_open,
            commands::retry_now,
            commands::show_failed,
            commands::conn_start,
            commands::conn_open,
            commands::conn_pairing_url,
            commands::copy_prompt,
            commands::hide_menu,
            commands::quit_app,
            commands::resize_menu,
            commands::submit_comment,
            commands::cancel_comment,
            commands::comment_finish_done,
            commands::resize_comment,
            commands::ofide,
            commands::alert,
            commands::get_settings,
            commands::save_settings,
            commands::hotkey_recording,
            commands::conn_save_connection,
            commands::conn_token_saved,
            commands::get_projects,
            commands::save_projects,
            commands::choose_folder,
            commands::last_target_app,
            commands::request_permission,
            commands::open_privacy,
            commands::relaunch,
            commands::get_permissions,
            commands::get_queue,
            commands::get_screenshot,
            commands::delete_annotation,
            commands::helper,
            commands::log_message,
        ])
        .setup(|app| {
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            panels::setup(app.handle())?;
            TrayIconBuilder::with_id("annotator")
                .icon(tauri::image::Image::from_bytes(include_bytes!("../icons/tray.png"))?)
                .icon_as_template(true)
                .tooltip("Annotator")
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { button_state: MouseButtonState::Up, .. } = event {
                        panels::toggle_menu(tray.app_handle());
                    }
                })
                .build(app)?;
            app::setup(app.handle());
            log("Annotator started");
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("Annotator")
        .run(|app, event| match event {
            tauri::RunEvent::Exit => helper::stop(app),
            tauri::RunEvent::Reopen { .. } => app::reopen(app),
            // An accessory app keeps running when its last window closes.
            tauri::RunEvent::ExitRequested { api, code: None, .. } => api.prevent_exit(),
            _ => {}
        });
}
