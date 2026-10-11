// Development only: renders one window in a browser with a mocked Tauri layer, for layout
// checks. Open http://127.0.0.1:1430/preview.html?window=menu (menu, comment, settings,
// onboarding, detail-<id>). Not part of the app build.
import { mockIPC, mockWindows } from "@tauri-apps/api/mocks";
import type { AppState, QueueItem } from "./types";

const label = new URLSearchParams(location.search).get("window") ?? "menu";
const item = (number: number, status: string, comment: string, extra: Partial<QueueItem> = {}): QueueItem =>
  ({ id: `id-${number}`, number, status, comment, createdAt: Date.now() - number * 60000, ...extra });
const open = [
  item(217, "todo", "The sidebar title is clipped"),
  item(216, "in_progress", "Make the send button match the composer height", { claimedAt: Date.now() }),
  item(215, "todo", "Which spacing should this list use?", { question: true, summary: "Use 8 or 12 px between rows?" }),
];
const finished = [item(214, "done", "Let's reduce the line height.", { completedAt: Date.now() }), item(213, "done", "Align the icons")];
const state: AppState = {
  health: { tone: "ok", title: "Connected" },
  serverURL: "http://127.0.0.1:29703/annotations",
  localServer: { busy: false, running: true, hasLog: true },
  queueReachable: true,
  annotating: false,
  hotkey: { keyCode: 0, modifiers: 6144, display: "⌃⌥A" },
  permissions: { accessibility: true, screenRecording: true },
  queue: { todo: 2, inProgress: 1, done: 206, open, finished },
  pending: { count: 0 }, failedCount: 0,
  conn: { enabled: true, sessions: ["p1"] },
  projects: [{ id: "p1", name: "Conn Dev", root: "/Users/nckrtl/apps/conn" }, { id: "p2", name: "Ofide", root: "" }],
};
const settings = {
  serverAutoStart: true, serverURL: state.serverURL, ofideEnabled: true, ofideAutoStart: false,
  ofideURL: "http://127.0.0.1:12321", ofideApp: "com.nckrtl.ofide", t3Enabled: true, t3Endpoint: "http://127.0.0.1:3780",
  t3Effort: "medium", t3Home: "~/.t3/headless", t3WindowHome: "~/.t3/desktop-dev", t3Nudge: true,
  t3DefaultModel: "claudeAgent/claude-opus-5-5", hotkey: { keyCode: 0, modifiers: 6144 },
};
const routes = { projects: [
  { id: "p1", name: "Conn Dev", root: "/Users/nckrtl/apps/conn", bundleIds: ["com.nckrtl.conn.dev.conn"], titleContains: [], urlPrefixes: [], notes: "Do not restart it yourself.", t3Model: "", t3RuntimeMode: "full-access" },
  { id: "p2", name: "Ofide", root: "", bundleIds: ["com.nckrtl.ofide"], titleContains: [], urlPrefixes: [], notes: "", t3Model: "", t3RuntimeMode: "full-access" },
] };

mockWindows(label);
mockIPC((cmd, args) => {
  console.log("invoke", cmd, args);
  switch (cmd) {
    case "get_state": return state;
    case "get_settings": return settings;
    case "get_projects": return { routes, error: null, file: "/Users/nckrtl/.config/annotator/routes.json" };
    case "get_permissions": return state.permissions;
    case "get_queue": return [...open, ...finished];
    case "conn_token_saved": return true;
    case "last_target_app": return { name: "Conn (Dev)", bundleId: "com.nckrtl.conn.dev.conn", title: "Conn", url: null };
    case "ofide": return { result: "ok", status: { recording: false } };
    case "conn_pairing_url": return "http://127.0.0.1:3780/pair#token=example";
    case "clear_open": return { failed: 0 };
    default: return null;
  }
}, { shouldMockEvents: true });
await import("./main");
