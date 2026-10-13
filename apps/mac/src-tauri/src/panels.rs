//! Native panel lifecycle requests. Geometry and focus belong to the host.
use crate::{runtime::AppHandle, geometry::Rect};
pub fn hide_menu(app: &AppHandle) { let _ = app.emit("hide-menu", ()); }
pub fn hide_comment(app: &AppHandle) { let _ = app.emit("hide-comment", ()); }
pub fn show_comment(app: &AppHandle, frame: Rect) { let _ = app.emit("show-comment", frame); }
pub fn resize_menu(_app: &AppHandle, _height: f64) {}
pub fn resize_comment(_app: &AppHandle, _height: f64) {}
