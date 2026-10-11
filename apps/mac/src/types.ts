// The interface between the React views and the Rust core (docs/port.md §2).

export type Tone = "ok" | "warning" | "error";

export type Box = { x: number; y: number; width: number; height: number };

export type QueueItem = {
  id: string; number?: number; status: string; comment: string; createdAt?: number;
  claimedAt?: number; completedAt?: number; summary?: string; question?: boolean; element?: string;
  elementPath?: string; url?: string; pathname?: string; boundingBox?: Box; screenSize?: string;
  screenshot?: string | null; component?: string; react?: string; native?: any; agent?: string;
};

export type LocalServer = { busy: boolean; running: boolean; error?: string; hasLog: boolean };

export type QueueSummary = {
  todo: number; inProgress: number; done: number;
  /** To do and in progress, oldest first. */
  open: QueueItem[];
  /** Everything else, newest first. */
  finished: QueueItem[];
};

export type Permissions = { accessibility: boolean; screenRecording: boolean };

export type ProjectRef = { id: string; name: string; root: string };

export type AppState = {
  health: { tone: Tone; title: string };
  serverURL: string;
  localServer: null | LocalServer;
  queueReachable: boolean;
  annotating: boolean;
  hotkey: { keyCode: number; modifiers: number; display: string };
  hotkeyError?: string;
  permissions: Permissions;
  queue: null | QueueSummary;
  pending: { count: number; lastError?: string };
  failedCount: number;
  conn: { enabled: boolean; lastError?: string; sessions: string[] };
  projects: ProjectRef[];
  projectsError?: string;
};

export type DictationConfig = { url: string; app: string; autoStart: boolean };

export type CommentTarget = {
  label: string;
  mode: "element" | "window" | "region";
  captureError?: string;
  dictation: null | DictationConfig;
};

export type OfideApp = "com.nckrtl.ofide" | "com.nckrtl.ofide.dev";

/** Settings.swift, in camelCase. `hotkey.modifiers` are Carbon flags. */
export type Settings = {
  serverAutoStart: boolean;
  serverURL: string;
  ofideEnabled: boolean;
  ofideAutoStart: boolean;
  ofideURL: string;
  ofideApp: OfideApp;
  t3Enabled: boolean;
  t3Endpoint: string;
  t3Effort: string;
  t3Home: string;
  t3WindowHome: string;
  t3Nudge: boolean;
  t3DefaultModel: string;
  hotkey: { keyCode: number; modifiers: number };
};

/** Projects.swift `Project`. */
export type Project = {
  id: string;
  name: string;
  root: string;
  bundleIds: string[];
  titleContains: string[];
  urlPrefixes: string[];
  notes: string;
  t3Model: string;
  t3RuntimeMode: string;
};

export type Routes = { projects: Project[] };

/** `get_projects`: the routes file, or why it cannot be read (then `routes` is empty and edits are off). */
export type ProjectsFile = { routes: Routes; error?: string | null; file: string };

export type LastTargetApp = { name: string; bundleId: string | null; title: string | null; url: string | null };

/** `ofide {action}`: OfideClient's result. `status` and `cancelledAt` come from `/status` when it answered 200. */
export type OfideReply = {
  result: "ok" | "noDictation" | "silence" | "failed" | "notRunning" | "unauthorized";
  /** For `failed`: "<status> <detail>". */
  message?: string | null;
  status?: string | null;
  cancelledAt?: number | null;
};
