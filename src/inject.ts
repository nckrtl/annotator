import { mountAnnotation, type AnnotationOptions } from "./index";

declare global {
    interface Window {
        __AGENT_ANNOTATION__?: AnnotationOptions;
        AgentAnnotation?: { mountAnnotation: typeof mountAnnotation };
    }
}

// When an annotation server serves this script, its annotation endpoint sits next to it.
// The overlay probes it only when nothing else is configured.
const script = document.currentScript as HTMLScriptElement | null;
const discoverServerUrl = script?.src ? new URL("annotations", script.src).href : undefined;
const options = (): AnnotationOptions => ({ discoverServerUrl, ...window.__AGENT_ANNOTATION__ });

// A page can load this script twice (its own toolbar plus a host application). A second
// runtime would take every click while the first renders, so only the first one runs and
// a later load just passes its options on.
const running = window.AgentAnnotation;
if (running) {
    running.mountAnnotation(options());
} else {
    window.AgentAnnotation = { mountAnnotation };
    const start = () => mountAnnotation(options());
    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", start, { once: true });
    } else {
        start();
    }
}
