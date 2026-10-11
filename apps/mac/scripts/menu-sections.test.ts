import { expect, test } from "bun:test";
import {
  clearConfirmation, clearFailure, connRows, deliveryLines, offlineNote, promptEntries, queueSection, rowComment, rowIcon,
  rowNumber, rowTooltip, serverSection, statusText, toggleTitle, truncate, warnings,
} from "../src/menu/sections";
import type { AppState, QueueItem, QueueSummary } from "../src/types";

const item = (number: number, status = "todo", extra: Partial<QueueItem> = {}): QueueItem => ({ id: `id-${number}`, number, status, comment: `Comment ${number}`, ...extra });
const summary = (open: QueueItem[], finished: QueueItem[] = []): QueueSummary => ({
  todo: open.filter(entry => entry.status === "todo").length,
  inProgress: open.filter(entry => entry.status === "in_progress").length,
  done: finished.length, open, finished,
});
const state = (patch: Partial<AppState> = {}): AppState => ({
  health: { tone: "ok", title: "Connected" }, serverURL: "http://127.0.0.1:29703/annotations", localServer: null,
  queueReachable: true, annotating: false, hotkey: { keyCode: 0, modifiers: 6144, display: "⌃⌥A" },
  permissions: { accessibility: true, screenRecording: true }, queue: null, pending: { count: 0 }, failedCount: 0,
  conn: { enabled: true, sessions: [] }, projects: [], ...patch,
});

test("rows: status icon, number, comment on one line, tooltip", () => {
  expect(rowIcon(item(1))).toBe("todo");
  expect(rowIcon(item(1, "in_progress"))).toBe("inProgress");
  expect(rowIcon(item(1, "done"))).toBe("done");
  expect(rowIcon(item(1, "todo", { question: true, summary: "Which one?" }))).toBe("question");
  expect(rowIcon(item(1, "done", { question: true }))).toBe("done");
  expect(rowNumber(item(7))).toBe("#7");
  expect(rowNumber({ id: "x", status: "todo", comment: "" })).toBe("#?");
  expect(rowComment(item(1, "todo", { comment: "two\nlines" }))).toBe("two lines");
  expect(rowTooltip(item(1, "todo", { question: true, summary: "Which one?" }))).toBe("The agent asked a question: Which one?");
  expect(rowTooltip(item(1))).toBe("Comment 1");
  expect(statusText(item(1, "in_progress"))).toBe("In progress");
  expect(statusText(item(1, "todo", { question: true }))).toBe("Question for you");
});

test("counts and the open list", () => {
  const section = queueSection(summary([item(1), item(2, "in_progress"), item(3)]));
  expect(section.header).toBe("Open 2 · In progress 1");
  expect(section.open.map(entry => entry.number)).toEqual([1, 2, 3]);
  expect(section.empty).toBeNull();
  expect(section.openMore).toBeNull();
  expect(section.canClear).toBe(true);
  expect(section.done).toBeNull();
});

test("nothing open", () => {
  const section = queueSection(summary([], [item(1, "done")]));
  expect(section.header).toBe("Open 0 · In progress 0");
  expect(section.empty).toBe("Nothing open.");
  expect(section.canClear).toBe(false);
  expect(section.done?.title).toBe("Done (1)");
});

test("more on the server: 25 open and 50 done at most", () => {
  const open = Array.from({ length: 30 }, (_, index) => item(index + 1));
  const finished = Array.from({ length: 53 }, (_, index) => item(100 + index, "done"));
  const section = queueSection(summary(open, finished));
  expect(section.open).toHaveLength(25);
  expect(section.openMore).toBe("5 more on the server");
  expect(section.done?.items).toHaveLength(50);
  expect(section.done?.more).toBe("3 more on the server");
  expect(section.done?.title).toBe("Done (53)");
  expect(queueSection(summary(open.slice(0, 25))).openMore).toBeNull();
});

test("clear confirmation says what the alert said", () => {
  expect(clearConfirmation(summary([item(1), item(2)]))).toEqual({
    title: "Delete 2 open annotation(s)?",
    detail: "2 to do and 0 in progress will be removed from the server. Done annotations stay. This cannot be undone.",
  });
  expect(clearConfirmation(summary([item(1), item(2, "in_progress")])).detail).toBe(
    "1 to do and 1 in progress will be removed from the server. Agents working on them can no longer complete them. Done annotations stay. This cannot be undone.");
  expect(clearFailure(2)).toEqual({ title: "2 annotation(s) could not be deleted", detail: "The server did not accept the request. Check that it is running, then try again." });
});

test("server lines", () => {
  expect(serverSection(state())).toEqual({ local: false, info: "Start and stop are available for a local HTTP server." });
  expect(serverSection(state({ localServer: { busy: true, running: false, hasLog: false } }))).toMatchObject({ control: { label: "Checking Server…", action: null }, restart: null, log: false });
  expect(serverSection(state({ localServer: { busy: false, running: false, hasLog: true } }))).toMatchObject({ control: { label: "Start Server", action: "start" }, log: true });
  expect(serverSection(state({ localServer: { busy: false, running: true, hasLog: true, error: "boom" } }))).toMatchObject({ control: { label: "Stop Server", action: "stop" }, restart: { disabled: false }, error: "boom" });
  expect(offlineNote(state({ queueReachable: false }))).toBe("New annotations are saved locally and sent when the server is back.");
  expect(offlineNote(state({ queueReachable: false, pending: { count: 1 } }))).toBeNull();
  expect(offlineNote(state())).toBeNull();
});

test("toggle, warnings and delivery", () => {
  expect(toggleTitle(state())).toBe("Start Annotating");
  expect(toggleTitle(state({ annotating: true }))).toBe("Stop Annotating");
  expect(warnings(state())).toEqual({ permissions: null, shortcut: null });
  expect(warnings(state({ permissions: { accessibility: true, screenRecording: false }, hotkeyError: "⌃⌥A: taken" })))
    .toEqual({ permissions: "Permissions missing. Fix…", shortcut: "Shortcut ⌃⌥A: taken" });
  expect(deliveryLines(state({ pending: { count: 2, lastError: "down" }, failedCount: 1 }))).toEqual({
    pending: "2 annotation(s) not sent yet", pendingError: "down", refused: "1 annotation(s) refused by the server. Show…",
  });
});

test("Conn sessions and prompts per project", () => {
  const projects = [{ id: "a", name: "Mail", root: "~/apps/mail" }, { id: "b", name: "Web", root: "" }];
  const conn = connRows(state({ projects, conn: { enabled: true, sessions: ["a"], lastError: "x".repeat(120) } }));
  expect(conn.rows.map(row => [row.start, row.open, row.disabledHint])).toEqual([
    ["New Session for Mail", "Open Mail Session", null],
    ["Web", null, "Set a folder for this project first."],
  ]);
  expect(conn.error).toBe("x".repeat(89) + "…");
  expect(conn.empty).toBeNull();
  expect(connRows(state()).empty).toBe("Add a project first.");
  expect(truncate("short", 90)).toBe("short");

  const prompts = promptEntries(state({ projects }));
  expect(prompts.projects.map(entry => [entry.scope, entry.label, entry.hint])).toEqual([
    ["a", "Mail", null], ["b", "Web", "This project has no folder yet; the agent will ask you."],
  ]);
  expect(prompts.general.map(entry => [entry.scope, entry.label])).toEqual([["inbox", "Inbox (no project)"], ["all", "All Annotations"]]);
});
