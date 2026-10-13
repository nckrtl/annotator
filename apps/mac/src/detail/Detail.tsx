import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { Maximize2 } from "lucide-react";
import { Spinner } from "../components";
import { AnnotationStatus } from "../AnnotationStatus";
import { errorText, useEvents } from "../state";
import { isInProgress, needsAnswer, statusText } from "../menu/sections";
import type { QueueItem } from "../types";

type Property = { label: string; value: string | null | undefined; wraps?: boolean };

const date = (milliseconds?: number) => milliseconds === undefined || milliseconds === null ? null
  : new Date(milliseconds).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "medium" });

/** The rows of AnnotationDetailView.properties; rows without a value are left out. */
export function properties(item: QueueItem): Property[] {
  const summary = item.summary ? item.summary : null;
  const app = item.native?.app;
  const box = item.boundingBox;
  const rows: Property[] = [
    { label: "Comment", value: item.comment, wraps: true },
    { label: needsAnswer(item) ? "Agent asks" : "Agent", value: summary, wraps: true },
    { label: "Project", value: item.native?.project },
    { label: "Element", value: item.element },
    { label: "Component", value: item.component },
    { label: "React", value: item.react },
    { label: "Selector", value: item.native?.dom?.selector },
    { label: "Path", value: item.elementPath },
    { label: "URL", value: item.url },
    { label: "Window", value: item.pathname },
    { label: "App", value: app ? `${app.name} (${app.bundleId ?? "no bundle id"})` : null },
    { label: "Mode", value: item.native?.mode },
    { label: "Box", value: box ? `x ${Math.trunc(box.x)}, y ${Math.trunc(box.y)}, ${Math.trunc(box.width)} × ${Math.trunc(box.height)} pt` : null },
    { label: "Screen", value: item.screenSize },
    { label: "Created", value: date(item.createdAt) },
    { label: "Claimed", value: date(item.claimedAt) },
    { label: "Completed", value: date(item.completedAt) },
    { label: "ID", value: item.id },
  ];
  return rows.filter(row => row.value !== null && row.value !== undefined);
}

/** AnnotationDetail.swift: one annotation with its screenshot and every property. Follows the live queue. */
export default function Detail({ id }: { id: string }) {
  const [items, setItems] = useState<QueueItem[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [lightbox, setLightbox] = useState(false);
  // The live queue does not keep screenshots. Read this one once.
  const [screenshot, setScreenshot] = useState<string | null>(null);
  useEvents({ queue: (payload: QueueItem[]) => { setItems(payload); setError(null); } });
  useEffect(() => { void invoke<QueueItem[]>("get_queue").then(setItems).catch(failure => setError(errorText(failure))); }, []);
  useEffect(() => { void invoke<string | null>("get_screenshot", { id }).then(setScreenshot).catch(() => setScreenshot(null)); }, [id]);
  const item = items?.find(entry => entry.id === id);
  if (!items) return <main className="detail-window"><p className="detail-missing">{error ?? ""}</p></main>;
  if (!item) return <main className="detail-window"><p className="detail-missing">This annotation is no longer on the server.</p></main>;
  return <main className="detail-window">
    <header className="detail-title" data-tauri-drag-region>
      <h1 data-tauri-drag-region>Annotation #{item.number ?? "?"}</h1>
      <span className="detail-status" title={statusText(item)}>
        {isInProgress(item) ? <Spinner label={statusText(item)}/> : <AnnotationStatus item={item} size={16}/>}
      </span>
    </header>
    <div className="detail-body scroll">
      {screenshot ? <Preview src={screenshot} open={() => setLightbox(true)}/> : <p className="detail-muted">No screenshot.</p>}
      <dl className="properties">{properties(item).map(row => <div key={row.label} className="property">
        <dt>{row.label}</dt>
        <dd className={row.wraps ? "wraps" : "line"} title={row.wraps ? undefined : row.value ?? ""}>{row.value}</dd>
      </div>)}</dl>
    </div>
    {lightbox && screenshot && <Lightbox src={screenshot} close={() => setLightbox(false)}/>}
  </main>;
}

/** ScreenshotPreview: the full content width, aspect kept. Images taller than 16:9 show their top part
 *  in a 16:9 box with "Cropped". A click opens the full-size view. */
function Preview({ src, open }: { src: string; open: () => void }) {
  const [aspect, setAspect] = useState<number | null>(null);
  const ratio = 16 / 9;
  const tall = aspect !== null && aspect < ratio;
  return <button className={`preview plain${tall ? " tall" : ""}`} style={{ aspectRatio: aspect === null ? undefined : String(Math.max(aspect, ratio)) }} onClick={open} aria-label="Click to view the full image">
    <img src={src} alt="Screenshot" onLoad={event => { const image = event.currentTarget; if (image.naturalHeight > 0) setAspect(image.naturalWidth / image.naturalHeight); }}/>
    {tall && <span className="preview-badge">Cropped</span>}
    <span className="preview-hover"><span><Maximize2 size={13} aria-hidden="true"/>Click to view the full image</span></span>
  </button>;
}

/** Lightbox.swift: the image at the size it had on screen over a blurred, dimmed backdrop. A click or Esc closes. */
function Lightbox({ src, close }: { src: string; close: () => void }) {
  const [size, setSize] = useState<{ width: number; height: number } | null>(null);
  const root = useRef<HTMLDivElement>(null);
  useEffect(() => {
    root.current?.focus();
    const onKey = (event: KeyboardEvent) => { if (event.key === "Escape") { event.preventDefault(); close(); } };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [close]);
  function measure(image: HTMLImageElement) {
    // Captures are made at the display's pixel density, so pixels ÷ scale is the size it had on screen.
    const scale = window.devicePixelRatio || 1;
    const natural = { width: image.naturalWidth / scale, height: image.naturalHeight / scale };
    const fit = Math.min(1, window.innerWidth * 0.92 / natural.width, window.innerHeight * 0.92 / natural.height);
    setSize({ width: natural.width * fit, height: natural.height * fit });
  }
  return <div className="lightbox" ref={root} tabIndex={-1} role="dialog" aria-label="Screenshot" onClick={close}>
    <img src={src} alt="Screenshot" style={size ?? { visibility: "hidden" }} onLoad={event => measure(event.currentTarget)}/>
  </div>;
}
