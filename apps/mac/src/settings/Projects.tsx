import { useEffect, useRef, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { ChevronDown, ChevronUp, Minus, Plus } from "lucide-react";
import { errorText, useEvents } from "../state";
import type { LastTargetApp, Project, ProjectsFile, Routes } from "../types";

export const runtimeModes = ["full-access", "auto-accept-edits", "auto", "approval-required"];
export const inbox = "Inbox";

export function newProject(): Project {
  return { id: crypto.randomUUID().toLowerCase(), name: "New project", root: "", bundleIds: [], titleContains: [], urlPrefixes: [], notes: "", t3Model: "", t3RuntimeMode: "full-access" };
}

/** A comma-separated field as a list: trimmed, without empty entries. */
export function parseList(text: string): string[] {
  return text.split(",").map(value => value.trim()).filter(Boolean);
}

/** Moves one project up or down; the first matching project wins, so the order matters. */
export function move(projects: Project[], index: number, by: -1 | 1): Project[] {
  const to = index + by;
  if (to < 0 || to >= projects.length) return projects;
  const next = [...projects];
  [next[index], next[to]] = [next[to], next[index]];
  return next;
}

/** ProjectsView.swift: which windows belong to which project, where its code lives, and notes for agents.
 *  Every change saves the file at once, as ProjectsStore.update. A broken file is shown, never overwritten. */
export default function Projects() {
  const [file, setFile] = useState<ProjectsFile | null>(null);
  const [selection, setSelection] = useState<string | null>(null);
  const [lastTarget, setLastTarget] = useState<LastTargetApp | null>(null);
  const latest = useRef<ProjectsFile | null>(null);
  latest.current = file;

  async function reload() {
    try {
      const loaded = await invoke<ProjectsFile>("get_projects");
      setFile(loaded);
      setSelection(current => current && loaded.routes.projects.some(project => project.id === current) ? current : loaded.routes.projects[0]?.id ?? null);
    } catch (error) { setFile({ routes: { projects: [] }, error: errorText(error), file: latest.current?.file ?? "" }); }
  }
  const readLastTarget = () => void invoke<LastTargetApp | null>("last_target_app").then(setLastTarget).catch(() => setLastTarget(null));
  useEffect(() => { void reload(); readLastTarget(); }, []);
  // A new annotation may change "the last annotation"; the window regains focus after one.
  useEffect(() => {
    const onFocus = () => readLastTarget();
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, []);
  useEvents({ state: () => readLastTarget() });

  async function update(change: (routes: Routes) => Routes) {
    const current = latest.current;
    if (!current || current.error) return;
    const routes = change(current.routes);
    const next = { ...current, routes };
    latest.current = next;
    setFile(next);
    try {
      const error = await invoke<string | null>("save_projects", { routes });
      if (error) setFile(value => value && { ...value, error });
    } catch (failure) { setFile(value => value && { ...value, error: errorText(failure) }); }
  }

  if (!file) return null;
  const projects = file.routes.projects;
  const index = projects.findIndex(project => project.id === selection);
  const locked = !!file.error;
  return <div className="projects">
    {file.error && <div className="projects-error" role="alert">
      <p>{file.error}</p>
      <button type="button" onClick={() => void reload()}>Read the file again</button>
    </div>}
    <div className="projects-split">
      <div className="project-list">
        <ul className="project-items" role="listbox" aria-label="Projects">
          {projects.map(project => <li key={project.id}>
            <button className="nav-item plain" role="option" aria-selected={project.id === selection} aria-current={project.id === selection ? "page" : undefined}
              disabled={locked} onClick={() => setSelection(project.id)}>
              <span className="project-name">{project.name === "" ? "Untitled" : project.name}</span>
            </button>
          </li>)}
        </ul>
        <div className="project-list-actions">
          <button className="icon-button" aria-label="Add project" title="Add project" disabled={locked} onClick={() => {
            const project = newProject();
            void update(routes => ({ projects: [...routes.projects, project] }));
            setSelection(project.id);
          }}><Plus size={14}/></button>
          <button className="icon-button" aria-label="Remove project" title="Remove project" disabled={locked || selection === null} onClick={() => {
            const remaining = projects.filter(project => project.id !== selection);
            void update(() => ({ projects: remaining }));
            setSelection(remaining[0]?.id ?? null);
          }}><Minus size={14}/></button>
          {index >= 0 && <>
            <button className="icon-button" aria-label="Move up" title="Move up" disabled={locked || index === 0}
              onClick={() => void update(routes => ({ projects: move(routes.projects, index, -1) }))}><ChevronUp size={14}/></button>
            <button className="icon-button" aria-label="Move down" title="Move down" disabled={locked || index === projects.length - 1}
              onClick={() => void update(routes => ({ projects: move(routes.projects, index, 1) }))}><ChevronDown size={14}/></button>
          </>}
        </div>
      </div>
      {index >= 0
        // A fresh editor per project, so drafts never carry over to the next one.
        ? <Editor key={projects[index].id} project={projects[index]} disabled={locked} lastTarget={lastTarget}
            onChange={project => void update(routes => ({ projects: routes.projects.map(item => item.id === project.id ? project : item) }))}/>
        : <p className="projects-empty">{projects.length === 0 ? "Add a project to route annotations to their own agent session." : "Select a project."}</p>}
    </div>
    <p className="group-footer">Annotations that match no project go to {inbox}. The first matching project wins. Saved in {file.file}.</p>
  </div>;
}

function Editor({ project, disabled, lastTarget, onChange }: { project: Project; disabled: boolean; lastTarget: LastTargetApp | null; onChange: (project: Project) => void }) {
  const set = (patch: Partial<Project>) => onChange({ ...project, ...patch });
  async function choose() {
    const path = await invoke<string | null>("choose_folder").catch(() => null);
    if (path) set({ root: path });
  }
  return <fieldset className="project-editor" disabled={disabled}>
    <label className="field">Name<input aria-label="Name" value={project.name} onChange={event => set({ name: event.target.value })}/></label>
    <label className="field">Folder
      <span className="inline-form">
        <input aria-label="Folder" value={project.root} placeholder="~/apps/my-project" onChange={event => set({ root: event.target.value })}/>
        <button type="button" onClick={() => void choose()}>Choose…</button>
      </span>
    </label>
    <ListField label="Bundle ids" prompt="com.example.app" values={project.bundleIds} onChange={bundleIds => set({ bundleIds })}/>
    <ListField label="Window title contains" prompt="Settings" values={project.titleContains} onChange={titleContains => set({ titleContains })}/>
    <ListField label="URL starts with" prompt="http://localhost:5733/" values={project.urlPrefixes} onChange={urlPrefixes => set({ urlPrefixes })}/>
    {lastTarget && <div><button type="button" onClick={() => { if (lastTarget.bundleId) set({ bundleIds: [lastTarget.bundleId] }); }}>Use {lastTarget.name} from the last annotation</button></div>}
    <p className="note">Separate several values with commas. Each kind you fill in must match. A Conn model reads like codex/gpt-6.1-sol.</p>
    <label className="field">Conn model<input aria-label="Conn model" value={project.t3Model} placeholder="The default model from General" onChange={event => set({ t3Model: event.target.value })}/></label>
    <label className="field">Conn permissions
      <select aria-label="Conn permissions" value={project.t3RuntimeMode} onChange={event => set({ t3RuntimeMode: event.target.value })}>
        {runtimeModes.map(mode => <option key={mode} value={mode}>{mode}</option>)}
      </select>
    </label>
    <label className="field">Notes for the agent
      <textarea aria-label="Notes for the agent" rows={5} value={project.notes} onChange={event => set({ notes: event.target.value })}/>
      <span>How to run the app, where the code is, which checks to run. Added to the copied prompt.</span>
    </label>
  </fieldset>;
}

/** A list of strings edited as one comma-separated field. Saved on Return or when the field loses focus,
 *  so a half-typed value is not cleaned up while typing. */
function ListField({ label, prompt, values, onChange }: { label: string; prompt: string; values: string[]; onChange: (values: string[]) => void }) {
  const [draft, setDraft] = useState(values.join(", "));
  const focused = useRef(false);
  const joined = values.join(", ");
  useEffect(() => { if (!focused.current) setDraft(joined); }, [joined]);
  function commit() {
    const parsed = parseList(draft);
    if (parsed.join("\n") !== values.join("\n")) onChange(parsed);
    setDraft(parsed.join(", "));
  }
  return <label className="field">{label}
    <input aria-label={label} value={draft} placeholder={prompt}
      onFocus={() => { focused.current = true; }}
      onBlur={() => { focused.current = false; commit(); }}
      onChange={event => setDraft(event.target.value)}
      onKeyDown={event => { if (event.key === "Enter") { event.preventDefault(); commit(); } }}/>
  </label>;
}
