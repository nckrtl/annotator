// What the menu panel shows, derived from AppState as AppController.menuNeedsUpdate builds it.
// Pure, so the texts and limits are tested without React.

import type { AppState, ProjectRef, QueueItem, QueueSummary } from "../types";

export const openLimit = 25;
export const doneLimit = 50;

export const isOpen = (item: QueueItem) => item.status === "todo" || item.status === "in_progress";
export const isInProgress = (item: QueueItem) => item.status === "in_progress";
export const needsAnswer = (item: QueueItem) => item.status === "todo" && item.question === true;

export type RowIcon = "question" | "todo" | "inProgress" | "done";
/** AnnotationRowView.symbol. */
export function rowIcon(item: QueueItem): RowIcon {
  if (needsAnswer(item)) return "question";
  if (item.status === "todo") return "todo";
  if (item.status === "in_progress") return "inProgress";
  return "done";
}

export function rowNumber(item: QueueItem): string { return `#${item.number ?? "?"}`; }
/** The comment on one line. */
export function rowComment(item: QueueItem): string { return item.comment.replace(/\n/g, " "); }
export function rowTooltip(item: QueueItem): string {
  return needsAnswer(item) ? `The agent asked a question: ${item.summary ?? ""}` : item.comment;
}

/** AnnotationDetailView.statusText. */
export function statusText(item: QueueItem): string {
  if (needsAnswer(item)) return "Question for you";
  switch (item.status) {
    case "todo": return "To do";
    case "in_progress": return "In progress";
    case "done": return "Done";
    default: return item.status.split(/(\s+)/).map(word => word.charAt(0).toUpperCase() + word.slice(1).toLowerCase()).join("");
  }
}

export type QueueSection = {
  header: string;
  open: QueueItem[];
  /** "Nothing open." when the list is empty. */
  empty: string | null;
  openMore: string | null;
  canClear: boolean;
  done: null | { title: string; items: QueueItem[]; more: string | null };
};

const more = (count: number, limit: number) => count > limit ? `${count - limit} more on the server` : null;

export function queueSection(queue: QueueSummary): QueueSection {
  return {
    header: `Open ${queue.todo} · In progress ${queue.inProgress}`,
    open: queue.open.slice(0, openLimit),
    empty: queue.open.length === 0 ? "Nothing open." : null,
    openMore: more(queue.open.length, openLimit),
    canClear: queue.open.length > 0,
    done: queue.finished.length === 0 ? null : {
      title: `Done (${queue.done})`,
      items: queue.finished.slice(0, doneLimit),
      more: more(queue.finished.length, doneLimit),
    },
  };
}

/** The NSAlert of AppController.clearOpen. */
export function clearConfirmation(queue: QueueSummary): { title: string; detail: string } {
  let detail = `${queue.todo} to do and ${queue.inProgress} in progress will be removed from the server. `;
  if (queue.inProgress > 0) detail += "Agents working on them can no longer complete them. ";
  return { title: `Delete ${queue.open.length} open annotation(s)?`, detail: detail + "Done annotations stay. This cannot be undone." };
}

export function clearFailure(failed: number): { title: string; detail: string } {
  return {
    title: `${failed} annotation(s) could not be deleted`,
    detail: "The server did not accept the request. Check that it is running, then try again.",
  };
}

export type ServerControl = { label: string; action: "start" | "stop" | null };
export type ServerSection =
  | { local: false; info: string }
  | { local: true; control: ServerControl; restart: null | { disabled: boolean }; error: string | null; log: boolean };

export function serverSection(state: AppState): ServerSection {
  const server = state.localServer;
  if (!server) return { local: false, info: "Start and stop are available for a local HTTP server." };
  return {
    local: true,
    control: {
      label: server.busy ? "Checking Server…" : server.running ? "Stop Server" : "Start Server",
      action: server.busy ? null : server.running ? "stop" : "start",
    },
    restart: server.running ? { disabled: server.busy } : null,
    error: server.error ?? null,
    log: server.hasLog,
  };
}

/** Shown when the server cannot be reached and nothing waits to be sent yet. */
export function offlineNote(state: AppState): string | null {
  return !state.queueReachable && state.pending.count === 0 ? "New annotations are saved locally and sent when the server is back." : null;
}

export function toggleTitle(state: AppState): string { return state.annotating ? "Stop Annotating" : "Start Annotating"; }

export function warnings(state: AppState): { permissions: string | null; shortcut: string | null } {
  return {
    permissions: state.permissions.accessibility && state.permissions.screenRecording ? null : "Permissions missing. Fix…",
    shortcut: state.hotkeyError ? `Shortcut ${state.hotkeyError}` : null,
  };
}

export function deliveryLines(state: AppState): { pending: string | null; pendingError: string | null; refused: string | null } {
  return {
    pending: state.pending.count > 0 ? `${state.pending.count} annotation(s) not sent yet` : null,
    pendingError: state.pending.count > 0 ? state.pending.lastError ?? null : null,
    refused: state.failedCount > 0 ? `${state.failedCount} annotation(s) refused by the server. Show…` : null,
  };
}

/** AXElementInfo.truncate. */
export function truncate(text: string, limit: number): string {
  const chars = [...text];
  return chars.length <= limit ? text : chars.slice(0, limit - 1).join("") + "…";
}

export type ConnRow = { project: ProjectRef; start: string; disabledHint: string | null; open: string | null };

/** AppController.t3Menu: start a session per project, or open the one already running. */
export function connRows(state: AppState): { error: string | null; rows: ConnRow[]; empty: string | null } {
  const rows = state.projects.map(project => {
    const has = state.conn.sessions.includes(project.id);
    return {
      project,
      start: has ? `New Session for ${project.name}` : project.name,
      disabledHint: project.root ? null : "Set a folder for this project first.",
      open: has ? `Open ${project.name} Session` : null,
    };
  });
  return {
    error: state.conn.lastError ? truncate(state.conn.lastError, 90) : null,
    rows,
    empty: state.projects.length === 0 ? "Add a project first." : null,
  };
}

export const pairingCopied = {
  title: "Pairing URL copied",
  detail: "In Conn, open Settings › Connections › Add environment, choose the remote option and paste it. It works once and expires in 15 minutes.",
};

export type PromptEntry = { scope: string; label: string; hint: string | null };
/** AppController.promptMenu: one prompt per project, plus the inbox and everything. */
export function promptEntries(state: AppState): { projects: PromptEntry[]; general: PromptEntry[] } {
  return {
    projects: state.projects.map(project => ({
      scope: project.id, label: project.name,
      hint: project.root ? null : "This project has no folder yet; the agent will ask you.",
    })),
    general: [
      { scope: "inbox", label: "Inbox (no project)", hint: null },
      { scope: "all", label: "All Annotations", hint: null },
    ],
  };
}
