import { useCallback, useEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { ChevronRight, Check, Copy, X, Square, Circle, Minus, Ellipsis } from "lucide-react";

/** Grouped settings section, macOS System Settings style. */
export function Group({ title, footer, children, label }: { title?: string; footer?: ReactNode; children: ReactNode; label?: string }) {
  return <section className="group" aria-label={label ?? title}>
    {title && <h3 className="group-title">{title}</h3>}
    <div className="group-body">{children}</div>
    {footer && <p className="group-footer">{footer}</p>}
  </section>;
}

/** Text on the left, control on the right. A label row toggles its switch when clicked. */
export function Row({ title, detail, children, as = "label" }: { title: ReactNode; detail?: ReactNode; children?: ReactNode; as?: "label" | "div" }) {
  const Tag = as;
  return <Tag className="row">
    <span className="row-text"><span className="row-title">{title}</span>{detail && <span className="row-detail">{detail}</span>}</span>
    {children && <span className="row-control">{children}</span>}
  </Tag>;
}

export function Disclosure({ title, detail, children, className = "disclosure", open, onToggle }: { title: ReactNode; detail?: ReactNode; children: ReactNode; className?: string; open?: boolean; onToggle?: (open: boolean) => void }) {
  return <details className={className} open={open} onToggle={event => onToggle?.(event.currentTarget.open)}>
    <summary><span className="row-text"><span className="row-title">{title}</span>{detail && <span className="row-detail">{detail}</span>}</span><ChevronRight size={14} className="chevron" aria-hidden="true"/></summary>
    <div className="disclosure-body">{children}</div>
  </details>;
}

/** Segmented control; the selection indicator slides to the chosen segment. */
export function Segmented<T extends string>({ value, options, onChange, label }: { value: T; options: [T, string][]; onChange: (value: T) => void; label: string }) {
  const index = Math.max(0, options.findIndex(([key]) => key === value));
  return <div className="segmented" role="group" aria-label={label} style={{ "--count": options.length, "--index": index } as CSSProperties}>
    <span className="segmented-indicator" aria-hidden="true"/>
    {options.map(([key, text]) => <button key={key} type="button" className="plain" aria-pressed={value === key} onClick={() => onChange(key)}>{text}</button>)}
  </div>;
}

/** Copied state for a short confirmation; restarts when copying again. */
export function useCopied(ms = 1400): [string | undefined, (id: string) => void] {
  const [copied, setCopied] = useState<string>();
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined);
  useEffect(() => () => clearTimeout(timer.current), []);
  const mark = useCallback((id: string) => { setCopied(id); clearTimeout(timer.current); timer.current = setTimeout(() => setCopied(undefined), ms); }, [ms]);
  return [copied, mark];
}
/** Copy glyph that morphs into a check: crossfade, scale and a 2 px blur bridge. */
export function CopyGlyph({ copied, size = 13 }: { copied: boolean; size?: number }) {
  return <span className={`copy-glyph ${copied ? "is-copied" : ""}`} style={{ width: size, height: size }} aria-hidden="true"><Copy size={size}/><Check size={size} strokeWidth={2.4}/></span>;
}
export function CopyButton({ text, copy, label = "Copy" }: { text: string; copy: (text: string) => void; label?: string }) {
  const [copied, mark] = useCopied();
  return <button className="icon-button" aria-label={copied ? "Copied" : label} title={copied ? "Copied" : label} onClick={() => { copy(text); mark("x"); }}><CopyGlyph copied={!!copied} size={14}/></button>;
}

/** A sweeping bar for work of unknown length, or a filling bar when `value` (0–1) is known. */
export function Progress({ label, value }: { label: string; value?: number }) {
  if (value === undefined) return <span className="progress" role="progressbar" aria-label={label}/>;
  const clamped = Math.min(1, Math.max(0, value));
  return <span className="progress determinate" role="progressbar" aria-label={label} aria-valuemin={0} aria-valuemax={100}
    aria-valuenow={Math.round(clamped * 100)} style={{ "--value": clamped } as CSSProperties}/>;
}

export type Tone = "success" | "failed" | "cancelled" | "running" | "neutral";
/** Drawn status marks instead of unicode symbols. */
export function StatusIcon({ tone, label }: { tone: Tone; label: string }) {
  const Icon = { success: Check, failed: X, cancelled: Square, running: Circle, neutral: Minus }[tone];
  return <span className={`status-icon ${tone}`} role="img" aria-label={label}><Icon size={tone === "cancelled" ? 8 : tone === "running" ? 7 : 11} strokeWidth={2.6} fill={tone === "cancelled" || tone === "running" ? "currentColor" : "none"}/></span>;
}

export function Chevron() { return <ChevronRight size={14} className="chevron" aria-hidden="true"/>; }

export type MenuItem = { label: string; shortcut?: string; onSelect: () => void; separator?: boolean };
/** A "more" button with a pull-down menu: arrow keys move, Return chooses, Escape or a click outside closes. */
export function MoreMenu({ label, items }: { label: string; items: MenuItem[] }) {
  const [state, setState] = useState<"closed" | "open" | "closing">("closed");
  const root = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const close = useCallback(() => setState(current => current === "open" ? "closing" : current), []);
  useEffect(() => {
    if (state === "closing") { const timer = setTimeout(() => setState("closed"), 120); return () => clearTimeout(timer); }
    if (state !== "open") return;
    root.current?.querySelector<HTMLButtonElement>("[role=menuitem]")?.focus();
    const outside = (event: MouseEvent) => { if (!root.current?.contains(event.target as Node)) close(); };
    window.addEventListener("mousedown", outside);
    return () => window.removeEventListener("mousedown", outside);
  }, [state, close]);
  function onKey(event: React.KeyboardEvent) {
    const entries = [...(root.current?.querySelectorAll<HTMLButtonElement>("[role=menuitem]") ?? [])];
    const index = entries.indexOf(document.activeElement as HTMLButtonElement);
    if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); close(); trigger.current?.focus(); }
    else if (event.key === "ArrowDown" || event.key === "ArrowUp") { event.preventDefault(); entries[(index + (event.key === "ArrowDown" ? 1 : -1) + entries.length) % entries.length]?.focus(); }
  }
  return <div className="menu-root" ref={root} onKeyDown={state === "open" ? onKey : undefined}>
    <button ref={trigger} className="icon-button" aria-label={label} title={label} aria-haspopup="menu" aria-expanded={state === "open"} onClick={() => state === "open" ? close() : setState("open")}><Ellipsis size={16}/></button>
    {state !== "closed" && <div className="menu" role="menu" aria-label={label} data-state={state}>{items.map(item => <div key={item.label}>
      {item.separator && <hr/>}
      <button role="menuitem" className="plain" onClick={() => { close(); item.onSelect(); }}><span>{item.label}</span>{item.shortcut && <kbd>{item.shortcut}</kbd>}</button>
    </div>)}</div>}
  </div>;
}
