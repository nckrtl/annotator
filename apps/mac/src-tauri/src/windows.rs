//! Normal titled windows, created on demand: `settings`, `onboarding` and `detail-<id>`. Opening one
//! again brings it to the front. Annotator is an accessory app, so it activates first.

use tauri::{Emitter, Manager, WebviewUrl, WebviewWindowBuilder};

struct Spec<'a> {
    label: &'a str,
    title: &'a str,
    url: String,
    size: (f64, f64),
    resizable: bool,
    overlay_title: bool,
    /// Ofide's window shell: no title bar, a vibrant sidebar under the traffic lights, and the
    /// view's own title on the right. Resizable down to `min`.
    shell: Option<(f64, f64)>,
}

/// Shows the window, or creates it. Returns true when it already existed.
fn show(app: &tauri::AppHandle, spec: Spec) -> bool {
    crate::panels::hide_menu(app);
    crate::panels::activate(app);
    if let Some(window) = app.get_webview_window(spec.label) {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
        return true;
    }
    let mut builder = WebviewWindowBuilder::new(app, spec.label, WebviewUrl::App(spec.url.into()))
        .title(spec.title)
        .inner_size(spec.size.0, spec.size.1)
        .resizable(spec.resizable)
        .minimizable(false)
        .maximizable(false)
        .closable(true)
        .center()
        .focused(true);
    if let Some((width, height)) = spec.shell {
        use tauri::window::{Effect, EffectState, EffectsBuilder};
        // Traffic lights center on the 52-point header (Tauri places their top at y − 10).
        builder = builder
            .title_bar_style(tauri::TitleBarStyle::Overlay)
            .hidden_title(true)
            .traffic_light_position(tauri::LogicalPosition::new(20.0, 28.0))
            .transparent(true)
            .effects(EffectsBuilder::new().effect(Effect::Sidebar).state(EffectState::FollowsWindowActiveState).build())
            .min_inner_size(width, height)
            .maximizable(true);
    } else if spec.overlay_title {
        // The view draws its own title bar with the status in it, like the Swift app.
        builder = builder.title_bar_style(tauri::TitleBarStyle::Overlay).hidden_title(true);
    }
    if let Err(error) = builder.build() {
        crate::log(&format!("Could not open the {} window: {error}", spec.label));
    }
    false
}

/// `tab`: `general` or `projects`.
pub fn open_settings(app: &tauri::AppHandle, tab: Option<String>) {
    let tab = match tab.as_deref() {
        Some("projects") => "projects",
        _ => "general",
    };
    let existed = show(app, Spec {
        label: "settings", title: "Annotator Settings", url: format!("index.html?tab={tab}"),
        size: (840.0, 600.0), resizable: true, overlay_title: false, shell: Some((700.0, 480.0)),
    });
    if existed {
        let _ = app.emit_to("settings", "settings-tab", tab);
    }
}

pub fn open_onboarding(app: &tauri::AppHandle) {
    show(app, Spec {
        label: "onboarding", title: "Annotator Permissions", url: "index.html".into(),
        size: (460.0, 320.0), resizable: false, overlay_title: false, shell: None,
    });
}

/// One window per annotation, labelled `detail-<id>`.
pub fn open_detail(app: &tauri::AppHandle, id: &str, number: Option<i64>) {
    let label = format!("detail-{id}");
    let title = format!("Annotation #{}", number.map(|n| n.to_string()).unwrap_or_else(|| "?".into()));
    show(app, Spec {
        label: &label, title: &title, url: "index.html".into(), size: (680.0, 720.0), resizable: true, overlay_title: true, shell: None,
    });
}
