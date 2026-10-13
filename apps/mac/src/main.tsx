import type { JSX } from "react";
import { createRoot } from "react-dom/client";
import { isTauri } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import Menu from "./menu/Menu";
import Comment from "./comment/Comment";
import Settings from "./settings/Settings";
import Onboarding from "./onboarding/Onboarding";
import Detail from "./detail/Detail";
import "./app.css";

// One entry for every window; the window label picks the view. Detail windows are `detail-<id>`.
const label = getCurrentWindow().label;
const views: Record<string, () => JSX.Element> = { menu: Menu, comment: Comment, settings: Settings, onboarding: Onboarding };
const kind = label.startsWith("detail-") ? "detail" : label;
document.documentElement.dataset.window = kind;
// The browser preview paints the sidebar; in the app the window's material shows through.
if (isTauri()) document.documentElement.classList.add("tauri");
const View = views[label];
createRoot(document.getElementById("root")!).render(
  kind === "detail" ? <Detail id={label.slice("detail-".length)}/> : View ? <View/> : <p>Unknown window: {label}</p>);
