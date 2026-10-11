import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Mic, MicOff, CircleStop } from "lucide-react";
import { Spinner, useReportHeight } from "../components";
import { errorText, useEvents } from "../state";
import type { CommentTarget, OfideReply } from "../types";
import { DictationController, type DictationView } from "./dictation";

const off: DictationView = { dictation: { kind: "off" }, message: null };

/** CommentPanel.swift: the label of what was clicked, a comment field, Ofide dictation, Cancel and Submit. */
export default function Comment() {
  const [target, setTarget] = useState<CommentTarget | null>(null);
  const [text, setText] = useState("");
  const [view, setView] = useState<DictationView>(off);
  const field = useRef<HTMLTextAreaElement>(null);
  const panel = useRef<HTMLElement>(null);
  const textRef = useRef("");
  const controller = useRef<DictationController | null>(null);

  useReportHeight(panel, height => void invoke("resize_comment", { height }));

  function change(value: string) { textRef.current = value; setText(value); }

  function makeController(next: CommentTarget): DictationController {
    const config = next.dictation;
    const dictation = new DictationController(!!config, !!config?.autoStart, {
      ofide: action => invoke<OfideReply>("ofide", { action }),
      sleep: ms => new Promise(resolve => setTimeout(resolve, ms)),
      now: () => Date.now(),
      text: () => textRef.current,
      onChange: state => { if (controller.current === dictation) setView(state); },
      requestClose: () => { if (controller.current === dictation) void invoke("cancel_comment"); },
      focus: () => field.current?.focus(),
      alert: (title, message) => void invoke("alert", { title, message }).catch(() => console.error(title, message)),
    });
    return dictation;
  }

  function open(next: CommentTarget) {
    // A panel that opens while the last one still dictates cancels that dictation first.
    controller.current?.close();
    const dictation = makeController(next);
    controller.current = dictation;
    change("");
    setView(off);
    setTarget(next);
    requestAnimationFrame(() => field.current?.focus());
    void dictation.open();
  }

  useEvents({
    "comment-opened": (payload: CommentTarget) => open(payload),
    // A click on another element: finish the dictation, then hand the comment back.
    "comment-finish": () => void finishForMove(),
    // The core closed the panel (annotate mode ended): stop a running dictation.
    "comment-cancel": () => controller.current?.close(),
  });
  useEffect(() => { field.current?.focus(); }, []);

  async function finishForMove() {
    const dictation = controller.current;
    if (!dictation) { void invoke("comment_finish_done", { submit: false, text: "" }); return; }
    if (!(await dictation.finish())) {
      // The panel stays open and says why; nothing is submitted and no new element is selected.
      void invoke("comment_finish_done", { submit: false, text: textRef.current, keep: true });
      return;
    }
    if (controller.current !== dictation) return;
    const comment = textRef.current.trim();
    dictation.close();
    void invoke("comment_finish_done", { submit: comment.length > 0, text: comment });
  }

  async function submit() {
    const dictation = controller.current;
    if (!dictation || !(await dictation.submit())) return;
    void invoke("submit_comment", { text: textRef.current.trim() }).catch(error => console.error("submit_comment", errorText(error)));
  }

  function cancel() {
    controller.current?.close();
    void invoke("cancel_comment");
  }

  function onKey(event: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (event.key === "Escape") { event.preventDefault(); cancel(); return; }
    // ⇧↩ adds a line. A Return that confirms an input method's composition stays with it.
    if (event.key === "Enter" && !event.shiftKey && !event.nativeEvent.isComposing && event.keyCode !== 229) {
      event.preventDefault();
      void submit();
    }
  }

  const kind = view.dictation.kind;
  const canSubmit = text.trim().length > 0;
  return <main className="comment-panel" ref={panel} onKeyDown={event => { if (event.key === "Escape" && event.target !== field.current) { event.preventDefault(); cancel(); } }}>
    <p className="comment-label" title={target?.label}>{target?.label ?? ""}</p>
    {target?.mode === "window" && <p className="comment-notice warning">No element found here. This annotates the whole window.</p>}
    {target?.captureError && <p className="comment-notice error">No screenshot: {target.captureError}</p>}
    <textarea ref={field} className="comment-field" aria-label="Comment" value={text}
      onChange={event => change(event.target.value)} onKeyDown={onKey}/>
    <p className="comment-hint">{kind === "recording"
      ? "Listening. ↩ or a click on the next element stops and submits. Esc cancels the dictation."
      : "↩ submits. ⇧↩ adds a line. Esc cancels."}</p>
    <div className="comment-actions">
      <div className="dictation" aria-live="polite">
        {kind === "checking" && <Spinner label="Checking Ofide"/>}
        {view.dictation.kind === "unavailable" && <span className="dictation-unavailable"><MicOff size={13} aria-hidden="true"/><span>{view.dictation.message}</span></span>}
        {(kind === "idle" || kind === "recording" || kind === "transcribing") && <>
          <button className={`icon-button mic${kind === "recording" ? " recording" : ""}`} tabIndex={-1}
            disabled={kind === "transcribing"} onMouseDown={event => event.preventDefault()}
            aria-label={kind === "recording" ? "Stop dictation and paste" : "Dictate with Ofide"}
            title={kind === "recording" ? "Stop dictation and paste" : "Dictate with Ofide"}
            onClick={() => void controller.current?.toggle()}>
            {kind === "recording" ? <CircleStop size={16} aria-hidden="true"/> : <Mic size={15} aria-hidden="true"/>}
          </button>
          {kind === "transcribing" ? <span className="dictation-status">Transcribing…</span>
            : kind === "recording" ? <span className="dictation-status recording">Recording…</span>
            : view.message && <span className="dictation-status message">{view.message}</span>}
        </>}
      </div>
      <button title="Cancel this annotation and dictation." onClick={cancel}>Cancel</button>
      <button className="primary" title="↩" disabled={!canSubmit && kind !== "recording"} onClick={() => void submit()}>Submit</button>
    </div>
  </main>;
}
