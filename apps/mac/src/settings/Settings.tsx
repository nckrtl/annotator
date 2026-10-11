import { useState } from "react";
import { Folder, Settings2 } from "lucide-react";
import { useEvents } from "../state";
import General from "./General";
import Projects from "./Projects";

type Tab = "general" | "projects";
const tabs: [Tab, string, typeof Settings2][] = [["general", "General", Settings2], ["projects", "Projects", Folder]];

/** Annotator Settings: a sidebar with General and Projects, like Ofide's main window. */
export default function Settings() {
  const [tab, setTab] = useState<Tab>(() => new URLSearchParams(location.search).get("tab") === "projects" ? "projects" : "general");
  const [scrolled, setScrolled] = useState(false);
  // `open_settings {tab}` on an open window selects the tab.
  useEvents({ "settings-tab": (payload: Tab) => { if (payload === "general" || payload === "projects") setTab(payload); } });
  const title = tabs.find(([key]) => key === tab)![1];
  return <div className="window">
    <aside className="sidebar">
      <div className="titlebar-space" data-tauri-drag-region/>
      <nav className="nav" aria-label="Settings sections">
        <div className="nav-group">{tabs.map(([key, label, Icon]) =>
          <button key={key} className="nav-item plain" aria-current={tab === key ? "page" : undefined} onClick={() => { setTab(key); setScrolled(false); }}>
            <Icon size={15} strokeWidth={1.9}/><span>{label}</span>
          </button>)}
        </div>
      </nav>
    </aside>
    <section className="content" aria-label={title}>
      <header className={`content-header${scrolled ? " scrolled" : ""}`} data-tauri-drag-region>
        <div className="content-title" data-tauri-drag-region><h1 data-tauri-drag-region>{title}</h1></div>
      </header>
      <div className="content-body scroll" key={tab} onScroll={event => setScrolled(event.currentTarget.scrollTop > 2)}>
        {tab === "general" ? <General/> : <Projects/>}
      </div>
    </section>
  </div>;
}
