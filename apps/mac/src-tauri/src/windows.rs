//! Window requests are rendered by the SwiftUI host.
use crate::runtime::AppHandle;
use serde_json::json;
pub fn open_settings(app: &AppHandle, tab: Option<String>) { let _ = app.emit("navigate", json!({"page": if tab.as_deref() == Some("projects") { "projects" } else { "settings" }})); }
pub fn open_onboarding(app: &AppHandle) { let _ = app.emit("onboarding", ()); }
pub fn open_detail(app: &AppHandle, id: &str, _number: Option<i64>) { let _ = app.emit("navigate", json!({"page": "all", "id": id})); }
