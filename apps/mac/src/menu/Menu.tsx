import { useEffect, useRef, useState, type ReactNode } from "react";
import { invoke } from "@tauri-apps/api/core";
import { CircleCheck, ClipboardCopy, Highlighter, MessagesSquare, Pencil, Play, RotateCw, ScrollText, Square } from "lucide-react";
import { CopyGlyph, Disclosure, MoreMenu, useCopied } from "../ui";
import { Confirm, Spinner, Warning, useReportHeight } from "../components";
import { AnnotationStatus } from "../AnnotationStatus";
import { errorText, useAppState, useEvents } from "../state";
import type { AppState, QueueItem } from "../types";
import {
  clearConfirmation, clearFailure, connRows, deliveryLines, isInProgress, offlineNote, pairingCopied, promptEntries,
  queueSection, rowComment, rowNumber, rowTooltip, serverSection, toggleTitle, warnings,
} from "./sections";

const maxHeight = 640;

/** An action that opens something elsewhere: like a menu item, it closes the panel. */
function act(command: string, args?: Record<string, unknown>) {
  void invoke(command, args).catch(error => console.error(command, errorText(error)));
  void invoke("hide_menu");
}

/** The menu-bar panel: everything AppController.menuNeedsUpdate built, grouped so it stays compact. */
export default function Menu() {
  const state = useAppState();
  const panel = useRef<HTMLElement>(null);
  const scroll = useRef<HTMLDivElement>(null);
  const content = useRef<HTMLDivElement>(null);
  // Bumped on every opening, so confirmations and notes from the last time start closed.
  const [opening, setOpening] = useState(0);

  useReportHeight(panel, height => void invoke("resize_menu", { height: Math.min(height, maxHeight) }),
    element => element.offsetHeight - (scroll.current?.clientHeight ?? 0) + (content.current?.offsetHeight ?? 0), [content]);
  useEvents({ "menu-opened": () => { setOpening(value => value + 1); scroll.current?.scrollTo({ top: 0 }); } });
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.defaultPrevented) return;
      if (event.key === "Escape") void invoke("hide_menu");
      else if (event.metaKey && event.key === ",") { event.preventDefault(); act("open_settings", {}); }
      else if (event.metaKey && event.key.toLowerCase() === "q") { event.preventDefault(); void invoke("quit_app"); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return <main className="menu-panel" ref={panel}>
    <header className="menu-header">
      {state ? <span className={`health-dot ${state.health.tone}`} aria-hidden="true"/> : null}
      <div className="menu-heading-text">
        <h1 className="menu-health" title={state ? `Annotator: ${state.health.title}` : undefined}>{state?.health.title ?? "Annotator"}</h1>
        {state && <p className="menu-url" title={state.serverURL}>{state.serverURL}</p>}
      </div>
      <MoreMenu label="More" items={[
        { label: "Open Server URL", onSelect: () => act("open_server") },
        { label: "Settings…", shortcut: "⌘,", onSelect: () => act("open_settings", {}) },
        { label: "Quit Annotator", shortcut: "⌘Q", separator: true, onSelect: () => void invoke("quit_app") },
      ]}/>
    </header>
    <div className="menu-scroll" ref={scroll}>
      <div className="menu-content" ref={content}>
        {state && <MenuBody key={opening} state={state}/>}
      </div>
    </div>
  </main>;
}

function Item({ children, onClick, disabled, title, detail, trailing, indent }: { children: ReactNode; onClick?: () => void; disabled?: boolean; title?: string; detail?: ReactNode; trailing?: ReactNode; indent?: boolean }) {
  return <button className={`menu-item plain${indent ? " indent" : ""}`} onClick={onClick} disabled={disabled} title={title}>
    <span className="menu-item-text"><span className="menu-item-title">{children}</span>{detail && <span className="menu-item-detail">{detail}</span>}</span>
    {trailing}
  </button>;
}

function Info({ children }: { children: ReactNode }) {
  return <p className="menu-info">{children}</p>;
}

function Section({ children, label }: { children: ReactNode; label?: string }) {
  return <section className="menu-section" aria-label={label}>{children}</section>;
}

function MenuBody({ state }: { state: AppState }) {
  const server = serverSection(state);
  const offline = offlineNote(state);
  const warn = warnings(state);
  const delivery = deliveryLines(state);
  const [serverFailure, setServerFailure] = useState<{ title: string; detail: string } | null>(null);

  async function control(action: "start" | "stop" | "restart") {
    setServerFailure(null);
    try { await invoke("server_control", { action }); }
    catch (error) { setServerFailure({ title: `Could not ${action} the server`, detail: errorText(error) }); }
  }

  return <>
    <Section label="Server">
      {server.local ? <>
        <Item disabled={!server.control.action} onClick={() => server.control.action && void control(server.control.action)}
          trailing={server.control.action ? null : <Spinner label="Checking Server…" size={12}/>}>
          {server.control.action === "stop" ? <Square size={11} aria-hidden="true"/> : <Play size={11} aria-hidden="true"/>}{server.control.label}
        </Item>
        {server.restart && <Item disabled={server.restart.disabled} onClick={() => void control("restart")}><RotateCw size={11} aria-hidden="true"/>Restart Server</Item>}
        {server.error && <Info>{server.error}</Info>}
        {server.log && <Item onClick={() => act("show_server_log")}><ScrollText size={11} aria-hidden="true"/>View Server Log</Item>}
      </> : <Info>{server.info}</Info>}
      {serverFailure && <div className="menu-note error" role="alert"><p className="menu-note-title">{serverFailure.title}</p><p>{serverFailure.detail}</p></div>}
      {offline && <Info>{offline}</Info>}
    </Section>

    <Section label="Annotate">
      <Item onClick={() => act("toggle_annotating")} trailing={<kbd>{state.hotkey.display}</kbd>}>
        <Highlighter size={12} aria-hidden="true"/>{toggleTitle(state)}
      </Item>
      {warn.permissions && <Item onClick={() => act("open_onboarding")}><Warning>{warn.permissions}</Warning></Item>}
      {warn.shortcut && <Info><Warning>{warn.shortcut}</Warning></Info>}
    </Section>

    {state.queue && <QueueBlock state={state}/>}

    {(delivery.pending || delivery.refused) && <Section label="Delivery">
      {delivery.pending && <>
        <Info><Warning>{delivery.pending}</Warning></Info>
        {delivery.pendingError && <Info>{delivery.pendingError}</Info>}
        <Item onClick={() => void invoke("retry_now")}>Retry Now</Item>
      </>}
      {delivery.refused && <Item onClick={() => act("show_failed")}><Warning>{delivery.refused}</Warning></Item>}
    </Section>}

    <Section label="Agents">
      {state.conn.enabled && <ConnSessions state={state}/>}
      <AgentPrompts state={state}/>
    </Section>
  </>;
}

function AnnotationRow({ item }: { item: QueueItem }) {
  return <button className="menu-item plain annotation-row" title={rowTooltip(item)}
    onClick={() => act("open_annotation", { id: item.id })}>
    <AnnotationStatus item={item}/>
    <span className="annotation-text"><span className="annotation-number">{rowNumber(item)}</span>{rowComment(item)}</span>
    {isInProgress(item) && <Spinner label="In progress" size={13}/>}
  </button>;
}

function QueueBlock({ state }: { state: AppState }) {
  const queue = state.queue!;
  const section = queueSection(queue);
  const [clearing, setClearing] = useState<"idle" | "confirm" | "busy">("idle");
  const [failed, setFailed] = useState(0);
  const [clearError, setClearError] = useState<string | null>(null);
  const confirmation = clearConfirmation(queue);

  async function clear() {
    setClearing("busy");
    setClearError(null);
    try {
      const result = await invoke<{ failed: number }>("clear_open");
      setFailed(result?.failed ?? 0);
    } catch (error) { setClearError(errorText(error)); }
    setClearing("idle");
  }

  return <Section label="Annotations">
    <h2 className="menu-section-title">{section.header}</h2>
    {section.empty && <Info>{section.empty}</Info>}
    <div className="annotation-list">{section.open.map(item => <AnnotationRow key={item.id} item={item}/>)}</div>
    {section.openMore && <Info>{section.openMore}</Info>}
    {section.canClear && clearing === "idle" && <Item onClick={() => { setFailed(0); setClearError(null); setClearing("confirm"); }}>Clear Open Annotations…</Item>}
    {clearing !== "idle" && <Confirm title={confirmation.title} detail={confirmation.detail} confirm="Delete" busy={clearing === "busy"}
      onConfirm={() => void clear()} onCancel={() => setClearing("idle")}/>}
    {failed > 0 && <div className="menu-note error" role="alert"><p className="menu-note-title">{clearFailure(failed).title}</p><p>{clearFailure(failed).detail}</p></div>}
    {clearError && <div className="menu-note error" role="alert"><p>{clearError}</p></div>}
    {section.done && <Disclosure className="disclosure menu-disclosure" title={<><CircleCheck size={12} aria-hidden="true"/>{section.done.title}</>}>
      <div className="annotation-list">{section.done.items.map(item => <AnnotationRow key={item.id} item={item}/>)}</div>
      {section.done.more && <Info>{section.done.more}</Info>}
    </Disclosure>}
  </Section>;
}

function ConnSessions({ state }: { state: AppState }) {
  const conn = connRows(state);
  const [pairing, setPairing] = useState<{ ok: boolean; text: string } | null>(null);
  async function copyPairing() {
    setPairing(null);
    try {
      const url = await invoke<string | null>("conn_pairing_url");
      // A null URL means the core could not make one; it reports why in `conn.lastError`.
      if (url) setPairing({ ok: true, text: pairingCopied.detail });
    } catch (error) { setPairing({ ok: false, text: errorText(error) }); }
  }
  return <Disclosure className="disclosure menu-disclosure" title={<><MessagesSquare size={12} aria-hidden="true"/>Conn Sessions</>}>
    {conn.error && <Info><Warning>{conn.error}</Warning></Info>}
    {conn.rows.map(row => <div key={row.project.id} className="menu-group">
      <Item disabled={!!row.disabledHint} title={row.disabledHint ?? undefined} detail={row.disabledHint}
        onClick={() => act("conn_start", { projectId: row.project.id })}>{row.start}</Item>
      {row.open && <Item indent onClick={() => act("conn_open", { projectId: row.project.id })}>{row.open}</Item>}
    </div>)}
    {conn.empty && <Info>{conn.empty}</Info>}
    <hr className="menu-sep"/>
    <Item onClick={() => void copyPairing()}>Copy Pairing URL</Item>
    {pairing && <div className={`menu-note${pairing.ok ? "" : " error"}`} role="status">
      {pairing.ok && <p className="menu-note-title">{pairingCopied.title}</p>}<p>{pairing.text}</p>
    </div>}
    <Item onClick={() => act("open_settings", { tab: "projects" })}><Pencil size={11} aria-hidden="true"/>Edit Projects…</Item>
  </Disclosure>;
}

function AgentPrompts({ state }: { state: AppState }) {
  const entries = promptEntries(state);
  const [copied, markCopied] = useCopied();
  const [error, setError] = useState<string | null>(null);
  async function copy(scope: string) {
    setError(null);
    try { await invoke("copy_prompt", { scope }); markCopied(scope); }
    catch (failure) { setError(errorText(failure)); }
  }
  const entry = (item: { scope: string; label: string; hint: string | null }) =>
    <Item key={item.scope} title={item.hint ?? undefined} detail={item.hint} onClick={() => void copy(item.scope)}
      trailing={<span className={`copy-state${copied === item.scope ? " copied" : ""}`}><span>{copied === item.scope ? "Copied" : ""}</span><CopyGlyph copied={copied === item.scope} size={12}/></span>}>
      {item.label}
    </Item>;
  return <Disclosure className="disclosure menu-disclosure" title={<><ClipboardCopy size={12} aria-hidden="true"/>Copy Agent Prompt</>}>
    {state.projectsError && <Info><Warning>{state.projectsError}</Warning></Info>}
    {error && <Info><Warning>{error}</Warning></Info>}
    {entries.projects.map(entry)}
    {entries.projects.length > 0 && <hr className="menu-sep"/>}
    {entries.general.map(entry)}
    <hr className="menu-sep"/>
    <Item onClick={() => act("open_settings", { tab: "projects" })}><Pencil size={11} aria-hidden="true"/>Edit Projects…</Item>
  </Disclosure>;
}
