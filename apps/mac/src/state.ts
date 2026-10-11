import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { AppState } from "./types";

/** Listens to events for the life of a component. Unlistens also when it unmounts before `listen` resolves. */
export function useEvents(handlers: Record<string, (payload: any) => void>, deps: unknown[] = []) {
  useEffect(() => {
    let disposed = false;
    const stops: UnlistenFn[] = [];
    for (const [name, handler] of Object.entries(handlers)) {
      void listen(name, event => handler(event.payload)).then(stop => { if (disposed) stop(); else stops.push(stop); });
    }
    return () => { disposed = true; stops.forEach(stop => stop()); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
}

/** The core's state: `get_state` once, then every `state` event. */
export function useAppState(): AppState | null {
  const [state, setState] = useState<AppState | null>(null);
  useEvents({ state: setState });
  useEffect(() => { void invoke<AppState>("get_state").then(setState).catch(error => console.error("get_state", error)); }, []);
  return state;
}

/** An error from `invoke` as text. */
export function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
