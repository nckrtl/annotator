import AnnotatorCore
import Foundation
import Observation

/// User settings, stored in UserDefaults.
@MainActor @Observable
final class Settings {
    static let defaultServerURL = "http://127.0.0.1:29703/annotations"

    /// Ofide and Ofide Dev differ in port and in where they keep the Local API token.
    enum OfideApp: String, CaseIterable, Identifiable {
        case ofide = "com.nckrtl.ofide"
        case ofideDev = "com.nckrtl.ofide.dev"

        var id: String { rawValue }
        var name: String { self == .ofide ? "Ofide" : "Ofide Dev" }
        var defaultURL: String { self == .ofide ? "http://127.0.0.1:12321" : "http://127.0.0.1:12322" }
    }

    private let defaults = UserDefaults.standard

    var serverAutoStart: Bool { didSet { defaults.set(serverAutoStart, forKey: "serverAutoStart") } }
    var serverURL: String { didSet { defaults.set(serverURL, forKey: "serverURL") } }
    var ofideEnabled: Bool { didSet { defaults.set(ofideEnabled, forKey: "ofideEnabled") } }
    var t3Enabled: Bool { didSet { defaults.set(t3Enabled, forKey: "t3Enabled") } }
    /// The data folder (`T3CODE_HOME`) of the Conn server that runs the sessions: the headless one by default.
    var t3Endpoint: String { didSet { defaults.set(t3Endpoint, forKey: "t3Endpoint") } }
    var t3Effort: String { didSet { defaults.set(t3Effort, forKey: "t3Effort") } }
    var t3Home: String { didSet { defaults.set(t3Home, forKey: "t3Home") } }
    /// The data folder of the Conn window that shows the sessions: `~/.t3` for the app, `~/.t3/desktop-dev` for dev.
    var t3WindowHome: String { didSet { defaults.set(t3WindowHome, forKey: "t3WindowHome") } }
    var t3Nudge: Bool { didSet { defaults.set(t3Nudge, forKey: "t3Nudge") } }
    /// The model for sessions whose project sets none, as `instance/model`.
    var t3DefaultModel: String { didSet { defaults.set(t3DefaultModel, forKey: "t3DefaultModel") } }
    var ofideAutoStart: Bool { didSet { defaults.set(ofideAutoStart, forKey: "ofideAutoStart") } }
    var ofideURL: String { didSet { defaults.set(ofideURL, forKey: "ofideURL") } }
    var ofideApp: OfideApp { didSet { defaults.set(ofideApp.rawValue, forKey: "ofideApp") } }
    var hotkey: Hotkey {
        didSet { defaults.set(try? JSONEncoder().encode(hotkey), forKey: "hotkey") }
    }

    /// Why the hotkey could not be registered. Not stored.
    var hotkeyError: String?

    init() {
        serverAutoStart = defaults.object(forKey: "serverAutoStart") as? Bool ?? true
        serverURL = defaults.string(forKey: "serverURL") ?? Settings.defaultServerURL
        ofideEnabled = defaults.object(forKey: "ofideEnabled") as? Bool ?? true
        ofideAutoStart = defaults.object(forKey: "ofideAutoStart") as? Bool ?? true
        t3Enabled = defaults.object(forKey: "t3Enabled") as? Bool ?? true
        t3Endpoint = defaults.string(forKey: "t3Endpoint") ?? "http://127.0.0.1:3780"
        t3Effort = defaults.string(forKey: "t3Effort") ?? "medium"
        t3Home = defaults.string(forKey: "t3Home") ?? "~/.t3/headless"
        t3WindowHome = defaults.string(forKey: "t3WindowHome") ?? "~/.t3/desktop-dev"
        t3Nudge = defaults.object(forKey: "t3Nudge") as? Bool ?? true
        t3DefaultModel = defaults.string(forKey: "t3DefaultModel") ?? "claudeAgent/claude-opus-5-5"
        if !defaults.bool(forKey: "opus55DefaultApplied") {
            t3DefaultModel = "claudeAgent/claude-opus-5-5"
            defaults.set("claudeAgent/claude-opus-5-5", forKey: "t3DefaultModel")
            defaults.set("medium", forKey: "t3Effort")
            defaults.set(true, forKey: "opus55DefaultApplied")
        }
        let ofideApp = defaults.string(forKey: "ofideApp").flatMap(OfideApp.init) ?? .ofide
        self.ofideApp = ofideApp
        ofideURL = defaults.string(forKey: "ofideURL") ?? ofideApp.defaultURL
        hotkey = defaults.data(forKey: "hotkey").flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
            ?? .standard
    }

    /// An http(s) URL with a host, or nil.
    static func validURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
            ["http", "https"].contains(url.scheme), url.host() != nil
        else { return nil }
        return url
    }

    var server: URL? { Settings.validURL(serverURL) }
    /// An Ofide client, or why there is none. Reads the token on every call, so a new token is picked up.
    func ofideClient() -> Result<OfideClient, OfideSetupError> {
        guard let url = Settings.validURL(ofideURL) else { return .failure(OfideSetupError("The Ofide URL in Settings is not valid.")) }
        do {
            let token = try OfideToken.read(OfideToken.file(bundleId: ofideApp.rawValue))
            return .success(OfideClient(base: url, token: token))
        } catch {
            return .failure(OfideSetupError(error.description))
        }
    }
}

struct OfideSetupError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
