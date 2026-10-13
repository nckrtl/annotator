import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { Group, Row, StatusIcon } from "../ui";
import type { Permissions } from "../types";

type Kind = "accessibility" | "screenRecording";

/** Permissions.swift OnboardingView: which permissions are missing and how to grant them. Checks every second. */
export default function Onboarding() {
  const [permissions, setPermissions] = useState<Permissions | null>(null);
  useEffect(() => {
    const read = () => void invoke<Permissions>("get_permissions").then(setPermissions).catch(error => console.error("get_permissions", error));
    read();
    const timer = setInterval(read, 1000);
    return () => clearInterval(timer);
  }, []);

  async function grant(kind: Kind) {
    const after = await invoke<Permissions>("request_permission", { kind }).catch(() => null);
    if (after) setPermissions(after);
    // Accessibility adds Annotator to the list in Settings, so the user only has to flip the switch.
    // Screen Recording asks first, and opens Settings only when macOS does not ask.
    if (kind === "accessibility" || !after?.screenRecording) void invoke("open_privacy", { kind });
  }

  const all = !!permissions?.accessibility && !!permissions.screenRecording;
  const row = (kind: Kind, title: string, reason: string, action: string) => {
    const granted = permissions?.[kind];
    return <Row as="div" title={<span className="permission-title"><StatusIcon tone={granted === undefined ? "neutral" : granted ? "success" : "failed"} label={granted ? "Granted" : "Missing"}/>{title}</span>}
      detail={granted === undefined ? "" : granted ? "Granted." : "Missing. " + reason}>
      {granted === false && <button onClick={() => void grant(kind)}>{action}</button>}
    </Row>;
  };
  return <main className="onboarding-window">
    <h1>Annotator needs two permissions</h1>
    <Group label="Permissions">
      {row("accessibility", "Accessibility", "Finds the element under the cursor.", "Open Settings")}
      {row("screenRecording", "Screen Recording", "Captures a screenshot of what you annotate.", "Grant")}
    </Group>
    <p className="lead">After you grant Screen Recording, macOS may need you to relaunch Annotator.</p>
    <div className="onboarding-buttons">
      <button onClick={() => void invoke("relaunch")}>Relaunch Annotator</button>
      <button className="primary" autoFocus onClick={() => void getCurrentWindow().close()}>{all ? "Done" : "Close"}</button>
    </div>
  </main>;
}
