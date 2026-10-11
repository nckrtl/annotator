// The comment panel's Ofide dictation, ported from CommentPanelController (CommentPanel.swift).
// No React and no Tauri here: the panel passes in how to reach Ofide, time and the comment text,
// so tests can drive every path.

import type { OfideReply } from "../types";

export type Dictation =
  | { kind: "off" }
  | { kind: "checking" }
  | { kind: "unavailable"; message: string }
  | { kind: "idle" }
  | { kind: "recording" }
  | { kind: "transcribing" };

export type DictationView = { dictation: Dictation; message: string | null };

/** OfideResult. `unavailable` is a reply that never reached Ofide: no token, a bad URL, no proxy. */
export type OfideResult =
  | { kind: "ok" | "noDictation" | "silence" | "notRunning" | "unauthorized" }
  | { kind: "failed"; detail: string }
  | { kind: "unavailable"; message: string };

export function ofideResult(reply: OfideReply): OfideResult {
  if (reply.result === "failed") return { kind: "failed", detail: reply.message ?? "" };
  return { kind: reply.result };
}

/** OfideResult.message. */
export function resultMessage(result: OfideResult): string | null {
  switch (result.kind) {
    case "ok": return null;
    case "noDictation": return "No active dictation, or focus changed.";
    case "silence": return "Ofide heard only silence.";
    case "failed": return `Ofide failed: ${result.detail}`;
    case "notRunning": return "Ofide is not running.";
    case "unauthorized": return "Ofide rejected the Local API token. Check Ofide → Settings → Local API.";
    case "unavailable": return result.message;
  }
}

/** After a failed call: lose the button when Ofide itself is unusable, keep it otherwise. */
export function settle(result: OfideResult): Dictation {
  switch (result.kind) {
    case "notRunning": case "unauthorized": case "unavailable":
      return { kind: "unavailable", message: resultMessage(result) ?? "" };
    default: return { kind: "idle" };
  }
}

export type Snapshot = { status: string; cancelledAt?: number | null } | null;

export type DictationDeps = {
  /** Calls Ofide: `status`, `start`, `stop` or `cancel`. A rejection means Ofide cannot be reached. */
  ofide: (action: "status" | "start" | "stop" | "cancel") => Promise<OfideReply>;
  sleep: (ms: number) => Promise<void>;
  /** Milliseconds since 1970, as Ofide's `cancelledAt`. */
  now: () => number;
  /** The comment text as it is now. */
  text: () => string;
  onChange: (view: DictationView) => void;
  /** The panel must close: Ofide cancelled the recording (its own Esc). */
  requestClose: () => void;
  /** Ofide pastes into the focused field: keep it ours before a stop. */
  focus: () => void;
  /** Shows a failure that outlives the panel (`Could not cancel Ofide`). */
  alert: (title: string, message: string) => void;
  /** Serializes Ofide commands across panels. */
  chain?: { current: Promise<OfideResult> | null };
};

/** New panels wait for the previous cancellation, so a late cancel cannot stop a new recording. */
const sharedChain: { current: Promise<OfideResult> | null } = { current: null };

export class DictationController {
  private view: DictationView = { dictation: { kind: "off" }, message: null };
  private closing = false;
  private stopping = false;
  private submitted = false;
  private recordingStartedAt = 0;
  /** The comment text when the recording started. A paste shows up as a change from it. */
  private textBeforeRecording = "";
  private readonly chain: { current: Promise<OfideResult> | null };

  /** `enabled` is false when dictation is off in Settings; then nothing calls Ofide. */
  constructor(private readonly enabled: boolean, private readonly autoStart: boolean, private readonly deps: DictationDeps) {
    this.chain = deps.chain ?? sharedChain;
  }

  get state(): DictationView { return this.view; }
  get dictation(): Dictation { return this.view.dictation; }
  get isClosing(): boolean { return this.closing; }

  private is(kind: Dictation["kind"]) { return this.view.dictation.kind === kind; }
  private set(dictation: Dictation, message: string | null = this.view.message) {
    this.view = { dictation, message };
    this.deps.onChange(this.view);
  }
  private setMessage(message: string | null) { this.set(this.view.dictation, message); }

  private async call(action: "status" | "start" | "stop" | "cancel"): Promise<OfideResult> {
    try { return ofideResult(await this.deps.ofide(action)); }
    catch (error) { return { kind: "unavailable", message: String(error) }; }
  }

  /** Ofide's `/status`, or null when it does not answer. */
  private async snapshot(): Promise<Snapshot> {
    try {
      const reply = await this.deps.ofide("status");
      return reply.result === "ok" && reply.status ? { status: reply.status, cancelledAt: reply.cancelledAt } : null;
    } catch { return null; }
  }

  private canSubmit() { return this.deps.text().trim().length > 0; }

  /** When the panel opens: check Ofide, then start dictating if Settings say so. */
  async open(): Promise<void> {
    if (!this.enabled) return;
    this.set({ kind: "checking" });
    const result = await this.call("status");
    if (!this.is("checking")) return;
    this.set(result.kind === "ok" ? { kind: "idle" } : { kind: "unavailable", message: resultMessage(result) ?? "Ofide is not available." });
    if (result.kind === "ok" && this.autoStart) await this.startRecording();
  }

  /** The microphone button. */
  async toggle(): Promise<void> {
    if (this.is("idle")) await this.startRecording();
    else if (this.is("recording")) await this.finish();
  }

  async startRecording(): Promise<void> {
    if (this.closing || !this.enabled || !this.is("idle")) return;
    this.textBeforeRecording = this.deps.text();
    this.set({ kind: "recording" }, null);
    const previous = this.chain.current;
    const start = (async (): Promise<OfideResult> => {
      await previous;
      if (this.closing) return { kind: "noDictation" };
      this.recordingStartedAt = this.deps.now();
      return this.call("start");
    })();
    this.chain.current = start;
    const result = await start;
    if (this.closing) return;
    if (result.kind !== "ok") {
      this.set(settle(result), resultMessage(result));
      return;
    }
    await this.watch();
  }

  /** Follows Ofide while it records. Ofide can end the recording itself (its hotkey or pause
   *  detection); then it transcribes and pastes, and we wait for the text. */
  private async watch(): Promise<void> {
    while (this.is("recording") && !this.stopping) {
      const snapshot = await this.snapshot();
      if (this.closing || !this.is("recording") || this.stopping) return;
      if (snapshot?.cancelledAt != null && snapshot.cancelledAt >= this.recordingStartedAt) {
        this.set({ kind: "off" });
        this.close();
        this.deps.requestClose();
        return;
      }
      const state = snapshot?.status ?? null;
      if (state === "loading" || state === "arming" || state === "recording") {
        await this.deps.sleep(100);
        continue;
      }
      if (state === null) {
        this.set({ kind: "unavailable", message: "Ofide stopped answering." });
        return;
      }
      // Ofide ended the recording on its own.
      this.set({ kind: "transcribing" });
      let current: string | null = state;
      const deadline = this.deps.now() + 120_000;
      while (!this.closing && current === "transcribing" && this.deps.now() < deadline) {
        await this.deps.sleep(100);
        current = (await this.snapshot())?.status ?? null;
      }
      if (this.closing) return;
      const pasted = await this.waitForPaste();
      if (this.closing) return;
      this.set({ kind: "idle" }, pasted ? this.view.message : "Ofide finished without text. It was cancelled or heard only silence.");
      return;
    }
  }

  /** Waits up to 3 s for the comment to change from the text before recording, then for it to settle. */
  private async waitForPaste(): Promise<boolean> {
    const deadline = this.deps.now() + 3000;
    while (!this.closing && this.deps.text() === this.textBeforeRecording && this.deps.now() < deadline) await this.deps.sleep(50);
    if (this.closing || this.deps.text() === this.textBeforeRecording) return false;
    let last: string;
    do {
      last = this.deps.text();
      await this.deps.sleep(250);
    } while (!this.closing && this.deps.text() !== last);
    return !this.closing;
  }

  /** Stops a running dictation and waits until Ofide's paste lands in the comment field.
   *  True when there is no dictation or the paste arrived; false shows why in the panel. */
  async finish(): Promise<boolean> {
    if (this.closing) return false;
    await this.chain.current;
    if (this.closing) return false;
    // Ofide is already transcribing on its own: wait for the watcher to finish.
    while (!this.closing && this.is("transcribing") && !this.stopping) await this.deps.sleep(100);
    if (this.closing) return false;
    if (!this.is("recording") || !this.enabled) return this.view.message === null || this.deps.text() !== this.textBeforeRecording;
    this.stopping = true;
    try {
      this.set({ kind: "transcribing" }, null);
      this.deps.focus();
      const result = await this.call("stop");
      if (this.closing) return false;
      if (result.kind !== "ok") {
        this.set(settle(result), result.kind === "noDictation"
          ? "Ofide had no active recording. It may have been cancelled."
          : resultMessage(result));
        return false;
      }
      const pasted = await this.waitForPaste();
      this.set({ kind: "idle" }, pasted ? this.view.message : "Ofide sent a paste, but no text reached the comment field.");
      return pasted;
    } finally {
      this.stopping = false;
    }
  }

  /** ↩ or Submit. While recording, stop first and submit once the paste lands. True at most once:
   *  then the caller posts the comment and the panel closes. */
  async submit(): Promise<boolean> {
    if (this.submitted) return false;
    this.submitted = true;
    if (!(await this.finish()) || this.closing || !this.canSubmit()) {
      this.submitted = false;
      return false;
    }
    this.closing = true;
    return true;
  }

  /** The panel closes. Cancels a running dictation once; cancellation never requests a paste. */
  close(): void {
    if (this.closing) return;
    this.closing = true;
    if ((this.is("recording") || this.is("transcribing")) && this.enabled) {
      const previous = this.chain.current;
      this.chain.current = (async (): Promise<OfideResult> => {
        // A start already in flight must finish before we cancel it.
        const started = await previous;
        if (started?.kind === "noDictation") return { kind: "ok" };
        const result = await this.call("cancel");
        if (result.kind !== "ok" && result.kind !== "noDictation") {
          this.deps.alert("Could not cancel Ofide", resultMessage(result) ?? "Cancel the recording in Ofide.");
        }
        return result;
      })();
    }
    this.set({ kind: "off" });
  }
}
