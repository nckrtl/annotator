// Generic components that are not in ui.tsx yet. Kept free of Annotator types so they can move to Ofide.
import { useEffect, useLayoutEffect, useRef, type ReactNode, type RefObject } from "react";
import { LoaderCircle, TriangleAlert } from "lucide-react";

/** A small spinner for work of unknown length inside a row or a title bar. */
export function Spinner({ label, size = 14 }: { label: string; size?: number }) {
  return <LoaderCircle size={size} className="spin spinner" role="progressbar" aria-label={label}/>;
}

/** A line that needs attention: a drawn warning mark, then the text. */
export function Warning({ children }: { children: ReactNode }) {
  return <span className="warning"><TriangleAlert size={12} strokeWidth={2.2} aria-hidden="true"/><span>{children}</span></span>;
}

/** An inline confirmation in place of a modal alert: a title, details, and a destructive and a cancel button. */
export function Confirm({ title, detail, confirm, onConfirm, onCancel, busy }: { title: string; detail: ReactNode; confirm: string; onConfirm: () => void; onCancel: () => void; busy?: boolean }) {
  const cancel = useRef<HTMLButtonElement>(null);
  useEffect(() => cancel.current?.focus(), []);
  return <div className="confirm" role="alertdialog" aria-label={title} onKeyDown={event => { if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); onCancel(); } }}>
    <p className="confirm-title">{title}</p>
    <p className="confirm-detail">{detail}</p>
    <div className="confirm-actions">
      <button ref={cancel} onClick={onCancel} disabled={busy}>Cancel</button>
      <button className="destructive" onClick={onConfirm} disabled={busy}>{confirm}</button>
    </div>
  </div>;
}

/** Calls `report` with the content's natural height whenever it changes, for a window that follows its content.
 *  `measure` returns the height; by default the element's own height. */
export function useReportHeight(ref: RefObject<HTMLElement | null>, report: (height: number) => void, measure?: (element: HTMLElement) => number, watch: RefObject<HTMLElement | null>[] = []) {
  const last = useRef(0);
  const latest = useRef({ report, measure });
  latest.current = { report, measure };
  useLayoutEffect(() => {
    const element = ref.current;
    if (!element || typeof ResizeObserver === "undefined") return;
    const send = () => {
      const height = Math.ceil(latest.current.measure ? latest.current.measure(element) : element.getBoundingClientRect().height);
      if (height > 0 && height !== last.current) { last.current = height; latest.current.report(height); }
    };
    const observer = new ResizeObserver(send);
    observer.observe(element);
    for (const other of watch) if (other.current) observer.observe(other.current);
    send();
    return () => observer.disconnect();
    // The observed elements live as long as the view.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
}
