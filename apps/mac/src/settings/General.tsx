import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Disclosure, Group, Row } from "../ui";
import { Spinner } from "../components";
import { errorText, useAppState } from "../state";
import { hotkeyDisplay, hotkeyFromEvent, isValidHotkey } from "../hotkey";
import type { OfideApp, Settings } from "../types";

export const defaultServerURL = "http://127.0.0.1:29703/annotations";
const ofideApps: [OfideApp, string, string][] = [
  ["com.nckrtl.ofide", "Ofide", "http://127.0.0.1:12321"],
  ["com.nckrtl.ofide.dev", "Ofide Dev", "http://127.0.0.1:12322"],
];
const ofideDefault = (app: OfideApp) => ofideApps.find(([id]) => id === app)?.[2] ?? ofideApps[0][2];
const efforts: [string, string][] = [["low", "Low"], ["medium", "Medium"], ["high", "High"], ["max", "Max"]];

const loopbackHosts = ["localhost", "127.0.0.1", "[::1]"];

/** ServiceURL.parse: an http(s) URL with a host and no user name, query, or fragment.
 *  Plain http only on localhost, 127.0.0.1 and ::1. */
export function validURL(text: string): URL | null {
  try {
    const url = new URL(text.trim());
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    if (!url.hostname || url.username || url.password) return null;
    // An empty `?` or `#` leaves search and hash empty, but stays in href.
    if (url.search || url.hash || url.href.includes("?") || url.href.includes("#")) return null;
    if (url.protocol === "http:" && !loopbackHosts.includes(url.hostname)) return null;
    return url;
  } catch { return null; }
}

/** ServiceURL.loopback: validURL on this machine. Ofide's token never leaves the Mac. */
export function loopbackURL(text: string): URL | null {
  const url = validURL(text);
  return url && loopbackHosts.includes(url.hostname) ? url : null;
}

/** T3ModelSelection: `provider/model`, both parts non-empty. */
export function validModel(text: string): boolean {
  const trimmed = text.trim();
  const slash = trimmed.indexOf("/");
  return slash > 0 && slash < trimmed.length - 1;
}

/** SettingsView.swift. Switches and pickers save at once; the two URLs save with Save or ↩. */
export default function General() {
  const state = useAppState();
  const [settings, setSettings] = useState<Settings | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => { void invoke<Settings>("get_settings").then(setSettings).catch(failure => setError(errorText(failure))); }, []);
  if (error) return <p className="settings-error" role="alert">{error}</p>;
  if (!settings) return null;
  return <GeneralForm initial={settings} state={state} onSaved={setSettings}/>;
}

function GeneralForm({ initial, state, onSaved }: { initial: Settings; state: ReturnType<typeof useAppState>; onSaved: (settings: Settings) => void }) {
  const [settings, setSettings] = useState(initial);
  const [serverDraft, setServerDraft] = useState(initial.serverURL);
  const [ofideDraft, setOfideDraft] = useState(initial.ofideURL);
  const [endpointDraft, setEndpointDraft] = useState(initial.t3Endpoint);
  const [tokenDraft, setTokenDraft] = useState("");
  const [connectionMessage, setConnectionMessage] = useState<string | null>(null);
  const [tokenSaved, setTokenSaved] = useState<boolean | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const latest = useRef(settings);
  latest.current = settings;

  useEffect(() => {
    void invoke<boolean>("conn_token_saved", { endpoint: settings.t3Endpoint }).then(setTokenSaved).catch(() => setTokenSaved(null));
  }, [settings.t3Endpoint]);

  async function save(next: Settings) {
    latest.current = next;
    setSettings(next);
    try {
      await invoke("save_settings", { settings: next });
      setSaveError(null);
      onSaved(next);
    } catch (failure) { setSaveError(errorText(failure)); }
  }
  const update = (patch: Partial<Settings>) => void save({ ...latest.current, ...patch });

  /** Save, or ↩ in a field: the valid URL drafts. */
  function apply() {
    const patch: Partial<Settings> = {};
    if (validURL(serverDraft) && serverDraft !== latest.current.serverURL) patch.serverURL = serverDraft;
    if (loopbackURL(ofideDraft) && ofideDraft !== latest.current.ofideURL) patch.ofideURL = ofideDraft;
    if (Object.keys(patch).length) update(patch);
  }

  async function saveConnection() {
    try {
      const message = await invoke<string>("conn_save_connection", { endpoint: endpointDraft, token: tokenDraft });
      setConnectionMessage(message);
      if (message === "Connection saved.") {
        setTokenDraft("");
        const saved = await invoke<Settings>("get_settings");
        latest.current = saved;
        setSettings(saved);
        setEndpointDraft(saved.t3Endpoint);
        void invoke<boolean>("conn_token_saved", { endpoint: saved.t3Endpoint }).then(setTokenSaved).catch(() => {});
      }
    } catch (failure) { setConnectionMessage(errorText(failure)); }
  }

  const server = state?.localServer ?? null;
  const serverControlsOff = !server || server.busy || serverDraft !== settings.serverURL;
  const control = (action: "start" | "stop" | "restart") => void invoke("server_control", { action }).catch(() => {});

  return <form className="settings-form" onSubmit={event => { event.preventDefault(); apply(); }}>
    <Group title="Annotation server" footer="The server keeps running when Annotator quits. Save a changed URL before using the controls.">
      <Row title="Start local server when Annotator opens">
        <input type="checkbox" aria-label="Start local server when Annotator opens" checked={settings.serverAutoStart} onChange={event => update({ serverAutoStart: event.target.checked })}/>
      </Row>
      {server && <div className="block">
        <div className="button-row">
          <button type="button" disabled={serverControlsOff} onClick={() => control(server.running ? "stop" : "start")}>{server.running ? "Stop Server" : "Start Server"}</button>
          {server.running && <button type="button" disabled={serverControlsOff} onClick={() => control("restart")}>Restart Server</button>}
          <button type="button" disabled={serverControlsOff || !server.hasLog} onClick={() => void invoke("show_server_log")}>View Logs</button>
          {server.busy && <Spinner label="Working"/>}
        </div>
        {server.error && <p className="error-text selectable">{server.error}</p>}
      </div>}
      <label className="block field">URL
        <input aria-label="Server URL" value={serverDraft} placeholder={defaultServerURL} onChange={event => setServerDraft(event.target.value)}/>
        {!validURL(serverDraft) && <span className="error-text">Use https, or http on 127.0.0.1 or localhost. No user name, query, or fragment.</span>}
      </label>
    </Group>

    <Group title="Shortcut">
      <ShortcutRow settings={settings} hotkeyError={state?.hotkeyError} onChange={hotkey => update({ hotkey })}/>
    </Group>

    <Group title="Dictation" footer="Annotator reads the Local API token from the app's control.json.">
      <Row title="Enable Ofide dictation">
        <input type="checkbox" aria-label="Enable Ofide dictation" checked={settings.ofideEnabled} onChange={event => update({ ofideEnabled: event.target.checked })}/>
      </Row>
      <Row title="Start dictating when the comment panel opens">
        <input type="checkbox" aria-label="Start dictating when the comment panel opens" disabled={!settings.ofideEnabled} checked={settings.ofideAutoStart} onChange={event => update({ ofideAutoStart: event.target.checked })}/>
      </Row>
      <Row title="App" as="div">
        <select aria-label="App" disabled={!settings.ofideEnabled} value={settings.ofideApp} onChange={event => {
          const app = event.target.value as OfideApp;
          setOfideDraft(ofideDefault(app));
          update({ ofideApp: app, ofideURL: ofideDefault(app) });
        }}>{ofideApps.map(([id, name]) => <option key={id} value={id}>{name}</option>)}</select>
      </Row>
      <label className="block field">URL
        <input aria-label="Ofide URL" value={ofideDraft} placeholder={ofideDefault(settings.ofideApp)} disabled={!settings.ofideEnabled} onChange={event => setOfideDraft(event.target.value)}/>
        {settings.ofideEnabled && !loopbackURL(ofideDraft) && <span className="error-text">Use http or https on 127.0.0.1 or localhost, with no user name, query, or fragment.</span>}
      </label>
    </Group>

    <Group title="Conn">
      <Row title="Start agent sessions in Conn">
        <input type="checkbox" aria-label="Start agent sessions in Conn" checked={settings.t3Enabled} onChange={event => update({ t3Enabled: event.target.checked })}/>
      </Row>
      <div className="block">
        <label className="field">Server endpoint
          <input aria-label="Server endpoint" value={endpointDraft} placeholder="http://127.0.0.1:3780" onChange={event => setEndpointDraft(event.target.value)}
            onKeyDown={event => { if (event.key === "Enter") { event.preventDefault(); void saveConnection(); } }}/>
        </label>
        <label className="field">Access token
          <input aria-label="Access token" type="password" value={tokenDraft} placeholder="Leave blank to keep the saved token" autoComplete="off"
            onChange={event => setTokenDraft(event.target.value)}
            onKeyDown={event => { if (event.key === "Enter") { event.preventDefault(); void saveConnection(); } }}/>
          {tokenSaved !== null && <span>{tokenSaved ? "A token is saved in Keychain for this endpoint." : "No token is saved for this endpoint."}</span>}
        </label>
        <div className="button-row"><button type="button" onClick={() => void saveConnection()}>Save Connection</button></div>
        {connectionMessage && <p className="status-text" role="status">{connectionMessage}</p>}
        <p className="selectable">Set up and run Conn yourself. On that server, use: t3 auth session issue --token-only --label annotator --ttl 30d --base-dir &lt;your Conn data folder&gt;. Paste the token here; it is stored in Keychain.</p>
        <p>Pairing links are created on the Conn server with t3 pair. They connect a Conn window and are separate from Annotator’s access token.</p>
      </div>
      <Disclosure title="Local Conn window (optional)">
        <label className="field">Server data folder
          <input aria-label="Server data folder" value={settings.t3Home} onChange={event => update({ t3Home: event.target.value })}/>
        </label>
        <label className="field">Window data folder
          <input aria-label="Window data folder" value={settings.t3WindowHome} onChange={event => update({ t3WindowHome: event.target.value })}/>
        </label>
        <p className="note">Used only by Open Session and Copy Pairing URL for a server on this Mac.</p>
      </Disclosure>
      <label className="block field">Default model
        <input aria-label="Default model" value={settings.t3DefaultModel} placeholder="claudeAgent/claude-opus-5-5" disabled={!settings.t3Enabled}
          onChange={event => update({ t3DefaultModel: event.target.value })}/>
        {settings.t3DefaultModel !== "" && !validModel(settings.t3DefaultModel) && <span className="error-text">Write it as provider/model, such as claudeAgent/claude-opus-5-5.</span>}
      </label>
      <Row title="Effort" as="div">
        <select aria-label="Effort" value={settings.t3Effort} onChange={event => update({ t3Effort: event.target.value })}>
          {efforts.map(([value, name]) => <option key={value} value={value}>{name}</option>)}
        </select>
      </Row>
      <Row title="Send new annotations to an idle session">
        <input type="checkbox" aria-label="Send new annotations to an idle session" disabled={!settings.t3Enabled} checked={settings.t3Nudge} onChange={event => update({ t3Nudge: event.target.checked })}/>
      </Row>
    </Group>

    {saveError && <p className="error-text" role="alert">{saveError}</p>}
    <div className="form-footer"><button type="submit" className="primary">Save</button></div>
  </form>;
}

/** Toggle annotate mode: a button that records the next shortcut. Esc cancels. The core pauses the
 *  global shortcut meanwhile (`hotkey_recording`), so pressing the current one records it. */
function ShortcutRow({ settings, hotkeyError, onChange }: { settings: Settings; hotkeyError?: string; onChange: (hotkey: Settings["hotkey"]) => void }) {
  const [recording, setRecording] = useState(false);
  const stop = useRef<(() => void) | null>(null);
  const latest = useRef(onChange);
  latest.current = onChange;

  function finish() {
    if (!stop.current) return;
    stop.current();
    stop.current = null;
    setRecording(false);
    void invoke("hotkey_recording", { recording: false }).catch(() => {});
  }
  function start() {
    if (stop.current) return;
    setRecording(true);
    void invoke("hotkey_recording", { recording: true }).catch(() => {});
    const onKey = (event: KeyboardEvent) => {
      event.preventDefault();
      event.stopPropagation();
      if (event.code === "Escape") { finish(); return; }
      const hotkey = hotkeyFromEvent(event);
      if (!hotkey || !isValidHotkey(hotkey)) return;
      latest.current(hotkey);
      finish();
    };
    window.addEventListener("keydown", onKey, true);
    window.addEventListener("blur", finish);
    stop.current = () => { window.removeEventListener("keydown", onKey, true); window.removeEventListener("blur", finish); };
  }
  useEffect(() => () => finish(), []);

  return <>
    <Row title="Toggle annotate mode" as="div">
      <button type="button" className={`shortcut-field${recording ? " recording" : ""}`} aria-label="Toggle annotate mode shortcut"
        onClick={() => recording ? finish() : start()}>{recording ? "Press a shortcut…" : hotkeyDisplay(settings.hotkey)}</button>
    </Row>
    {hotkeyError && <p className="block error-text">{hotkeyError}</p>}
  </>;
}
