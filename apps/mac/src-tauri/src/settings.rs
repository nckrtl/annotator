//! User settings (Settings.swift, Hotkey.swift), stored as JSON in
//! `~/Library/Application Support/com.nckrtl.annotator/settings.json`.

use crate::service_url;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const DEFAULT_SERVER_URL: &str = "http://127.0.0.1:29703/annotations";
pub const OFIDE: &str = "com.nckrtl.ofide";
pub const OPERATOR_URL: &str = "http://127.0.0.1:12321";

/// Carbon modifier flags, as `RegisterEventHotKey` takes them.
pub const CMD: u32 = 1 << 8;
pub const SHIFT: u32 = 1 << 9;
pub const OPTION: u32 = 1 << 11;
pub const CONTROL: u32 = 1 << 12;

/// A global shortcut: a virtual key code plus Carbon modifier flags.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Hotkey {
    pub key_code: u32,
    pub modifiers: u32,
}

impl Hotkey {
    /// ⌃⌥A. Key code 0 is kVK_ANSI_A.
    pub const STANDARD: Hotkey = Hotkey { key_code: 0, modifiers: CONTROL | OPTION };

    /// A shortcut needs at least one of ⌃, ⌥ or ⌘, or it would swallow normal typing.
    pub fn is_valid(&self) -> bool {
        self.modifiers & (CONTROL | OPTION | CMD) != 0
    }

    pub fn display(&self) -> String {
        let mut text = String::new();
        if self.modifiers & CONTROL != 0 { text.push('⌃'); }
        if self.modifiers & OPTION != 0 { text.push('⌥'); }
        if self.modifiers & SHIFT != 0 { text.push('⇧'); }
        if self.modifiers & CMD != 0 { text.push('⌘'); }
        text + &key_name(self.key_code)
    }
}

impl Default for Hotkey {
    fn default() -> Self {
        Hotkey::STANDARD
    }
}

/// The key on a US keyboard for a virtual key code (kVK_*).
pub fn key_name(code: u32) -> String {
    const LETTERS: [(u32, &str); 50] = [
        (0, "A"), (1, "S"), (2, "D"), (3, "F"), (4, "H"), (5, "G"), (6, "Z"), (7, "X"), (8, "C"), (9, "V"),
        (11, "B"), (12, "Q"), (13, "W"), (14, "E"), (15, "R"), (16, "Y"), (17, "T"), (18, "1"), (19, "2"),
        (20, "3"), (21, "4"), (22, "6"), (23, "5"), (24, "="), (25, "9"), (26, "7"), (27, "-"), (28, "8"),
        (29, "0"), (30, "]"), (31, "O"), (32, "U"), (33, "["), (34, "I"), (35, "P"), (36, "↩"), (37, "L"),
        (38, "J"), (39, "'"), (40, "K"), (41, ";"), (42, "\\"), (43, ","), (44, "/"), (45, "N"), (46, "M"),
        (47, "."), (48, "⇥"), (49, "Space"), (50, "`"),
    ];
    const OTHERS: [(u32, &str); 41] = [
        (51, "⌫"), (53, "⎋"), (65, "Keypad ."), (67, "Keypad *"), (69, "Keypad +"), (75, "Keypad /"),
        (76, "⌤"), (78, "Keypad -"), (81, "Keypad ="), (82, "Keypad 0"), (83, "Keypad 1"), (84, "Keypad 2"),
        (85, "Keypad 3"), (86, "Keypad 4"), (87, "Keypad 5"), (88, "Keypad 6"), (89, "Keypad 7"),
        (91, "Keypad 8"), (92, "Keypad 9"), (96, "F5"), (97, "F6"), (98, "F7"), (99, "F3"), (100, "F8"),
        (101, "F9"), (103, "F11"), (105, "F13"), (107, "F14"), (109, "F10"), (111, "F12"), (113, "F15"),
        (115, "↖"), (116, "⇞"), (117, "⌦"), (118, "F4"), (119, "↘"), (120, "F2"), (121, "⇟"), (122, "F1"),
        (123, "←"), (124, "→"),
    ];
    if let Some((_, name)) = LETTERS.iter().chain(OTHERS.iter()).find(|(c, _)| *c == code) {
        return name.to_string();
    }
    match code {
        64 => "F17".into(),
        79 => "F18".into(),
        80 => "F19".into(),
        90 => "F20".into(),
        106 => "F16".into(),
        125 => "↓".into(),
        126 => "↑".into(),
        _ => format!("Key {code}"),
    }
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub server_auto_start: bool,
    #[serde(rename = "serverURL")]
    pub server_url: String,
    #[serde(rename = "operatorEnabled", alias = "ofideEnabled")]
    pub ofide_enabled: bool,
    #[serde(rename = "operatorAutoStart", alias = "ofideAutoStart")]
    pub ofide_auto_start: bool,
    pub t3_enabled: bool,
    /// The Conn server that runs the sessions.
    pub t3_endpoint: String,
    pub t3_effort: String,
    /// The data folder (`T3CODE_HOME`) of the Conn server on this Mac.
    pub t3_home: String,
    /// The data folder of the Conn window that shows the sessions.
    pub t3_window_home: String,
    /// Off for new installs: annotations are not sent onward unless the user asks. A saved choice is kept.
    pub t3_nudge: bool,
    /// The model for sessions whose project sets none, as `instance/model`.
    pub t3_default_model: String,
    pub hotkey: Hotkey,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            server_auto_start: true,
            server_url: DEFAULT_SERVER_URL.into(),
            ofide_enabled: true,
            ofide_auto_start: true,
            t3_enabled: true,
            t3_endpoint: "http://127.0.0.1:3780".into(),
            t3_effort: "medium".into(),
            t3_home: "~/.t3/headless".into(),
            t3_window_home: "~/.t3/desktop-dev".into(),
            t3_nudge: false,
            t3_default_model: "claudeAgent/claude-opus-5-5".into(),
            hotkey: Hotkey::STANDARD,
        }
    }
}

pub fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| "/".into()))
}

/// `~` and `~/…` expanded against the home folder.
pub fn expand_tilde(path: &str) -> PathBuf {
    if path == "~" {
        home()
    } else if let Some(rest) = path.strip_prefix("~/") {
        home().join(rest)
    } else {
        PathBuf::from(path)
    }
}

pub fn support_directory() -> PathBuf {
    home().join("Library/Application Support/com.nckrtl.annotator")
}

impl Settings {
    pub fn file() -> PathBuf {
        support_directory().join("settings.json")
    }

    pub fn server(&self) -> Option<url::Url> {
        service_url::parse(&self.server_url)
    }

    /// Operator carries the Local API token, so its URL must be on this machine.
    pub fn ofide(&self) -> Option<url::Url> {
        service_url::loopback(OPERATOR_URL)
    }

    /// A missing file gives the defaults. A broken file is kept aside, so it is never lost silently.
    pub fn load(file: &Path) -> Settings {
        let Ok(data) = std::fs::read(file) else { return Settings::default() };
        let parsed = (|| -> Result<Settings, serde_json::Error> {
            let mut value: serde_json::Value = serde_json::from_slice(&data)?;
            let original = value.clone();
            if let Some(fields) = value.as_object_mut() {
                for (old, new) in [("ofideEnabled", "operatorEnabled"), ("ofideAutoStart", "operatorAutoStart")] {
                    if let Some(choice) = fields.remove(old) { fields.entry(new).or_insert(choice); }
                }
                fields.remove("ofideApp"); fields.remove("ofideURL");
            }
            let settings = serde_json::from_value(value.clone())?;
            if value != original {
                // Keep unrelated/unknown preferences; only the retired dictation keys migrate.
                if let Err(error) = write_atomic(file, &serde_json::to_vec_pretty(&value)?) { crate::log(&error); }
            }
            Ok(settings)
        })();
        match parsed {
            Ok(settings) => settings,
            Err(error) => {
                let aside = file.with_extension("json.broken");
                let _ = std::fs::rename(file, &aside);
                crate::log(&format!("Could not read {}: {error}. Moved it to {} and used the defaults.",
                    file.display(), aside.display()));
                Settings::default()
            }
        }
    }

    pub fn save(&self, file: &Path) -> Result<(), String> {
        write_atomic(file, &serde_json::to_vec_pretty(self).map_err(|e| e.to_string())?)
    }

    /// Applies an edit like SettingsView.apply: invalid URLs and an invalid shortcut keep the old value.
    pub fn merged(&self, mut new: Settings) -> Settings {
        if new.server().is_none() { new.server_url = self.server_url.clone(); }
        if !new.hotkey.is_valid() { new.hotkey = self.hotkey; }
        new
    }
}

/// Writes through a temporary file in the same folder, so a crash never leaves half a file.
pub fn write_atomic(file: &Path, data: &[u8]) -> Result<(), String> {
    let folder = file.parent().ok_or("No folder")?;
    std::fs::create_dir_all(folder).map_err(|e| format!("Could not create {}: {e}", folder.display()))?;
    let temporary = folder.join(format!(".{}.tmp", uuid::Uuid::new_v4()));
    std::fs::write(&temporary, data).map_err(|e| format!("Could not write {}: {e}", file.display()))?;
    std::fs::rename(&temporary, file).map_err(|e| {
        let _ = std::fs::remove_file(&temporary);
        format!("Could not write {}: {e}", file.display())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrates_retired_app_without_losing_choices() {
        for enabled in [false, true] {
            let dir = crate::testutil::temp_dir("operator-migration");
            let file = dir.join("settings.json");
            write_atomic(&file, serde_json::json!({
                "ofideEnabled": enabled, "ofideAutoStart": false,
                "ofideURL": "http://127.0.0.1:12322", "ofideApp": "com.nckrtl.ofide.dev",
                "t3Nudge": true, "unusedAppearance": "keep"
            }).to_string().as_bytes()).unwrap();
            let settings = Settings::load(&file);
            assert_eq!(settings.ofide_enabled, enabled);
            assert!(!settings.ofide_auto_start);
            assert!(settings.t3_nudge);
            assert_eq!(settings.ofide().unwrap().as_str(), "http://127.0.0.1:12321/");
            let saved: serde_json::Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
            assert_eq!(saved["operatorEnabled"], enabled);
            assert_eq!(saved["unusedAppearance"], "keep");
            for old in ["ofideEnabled", "ofideAutoStart", "ofideURL", "ofideApp"] { assert!(saved.get(old).is_none()); }
            assert_eq!(Settings::load(&file), settings);
            std::fs::remove_dir_all(dir).unwrap();
        }
    }

    #[test]
    fn display() {
        assert_eq!(Hotkey::STANDARD.display(), "⌃⌥A");
        assert_eq!(Hotkey { key_code: 1, modifiers: CMD | SHIFT }.display(), "⇧⌘S");
        assert_eq!(Hotkey { key_code: 49, modifiers: CONTROL }.display(), "⌃Space");
        assert_eq!(Hotkey { key_code: 36, modifiers: CMD | OPTION }.display(), "⌥⌘↩");
        assert_eq!(Hotkey { key_code: 90, modifiers: CONTROL }.display(), "⌃F20");
        assert_eq!(Hotkey { key_code: 126, modifiers: CONTROL }.display(), "⌃↑");
    }

    #[test]
    fn carbon_flags() {
        assert_eq!(Hotkey::STANDARD.modifiers, (1 << 12) | (1 << 11));
    }

    #[test]
    fn needs_a_modifier() {
        assert!(!Hotkey { key_code: 0, modifiers: SHIFT }.is_valid());
        assert!(Hotkey::STANDARD.is_valid());
    }

    #[test]
    fn defaults_and_partial_files() {
        let settings: Settings = serde_json::from_str(r#"{"serverURL":"http://localhost:1/annotations"}"#).unwrap();
        assert_eq!(settings.server_url, "http://localhost:1/annotations");
        assert!(settings.server_auto_start);
        assert_eq!(settings.hotkey, Hotkey::STANDARD);
        assert_eq!(settings.t3_default_model, "claudeAgent/claude-opus-5-5");
        assert!(!settings.t3_nudge);
        let saved: Settings = serde_json::from_str(r#"{"t3Nudge":true}"#).unwrap();
        assert!(saved.t3_nudge);
        let json = serde_json::to_value(Settings::default()).unwrap();
        for key in ["serverAutoStart", "serverURL", "operatorEnabled", "operatorAutoStart",
            "t3Enabled", "t3Endpoint", "t3Effort", "t3Home", "t3WindowHome", "t3Nudge", "t3DefaultModel"] {
            assert!(json.get(key).is_some(), "{key}");
        }
        assert_eq!(json["hotkey"], serde_json::json!({"keyCode": 0, "modifiers": 6144}));
    }

    #[test]
    fn merge_keeps_invalid_values_out() {
        let old = Settings::default();
        let mut new = old.clone();
        new.server_url = "http://example.com/annotations".into();
        new.hotkey = Hotkey { key_code: 1, modifiers: SHIFT };
        new.t3_nudge = true;
        let merged = old.merged(new);
        assert_eq!(merged.server_url, DEFAULT_SERVER_URL);
        assert_eq!(merged.hotkey, Hotkey::STANDARD);
        assert!(merged.t3_nudge);
    }
}
