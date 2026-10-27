import type { DictationSettings } from "./dictation";
import { triggerDictation } from "./dictation-trigger";
import { recordDictationTiming } from "./post-dictation";
import type { AnnotationDraft } from "./types";

let handler: ((next: AnnotationDraft) => void) | null = null;

export function onOutsideAnnotationClick(callback: (next: AnnotationDraft) => void): () => void {
    handler = callback;
    return () => {
        if (handler === callback) handler = null;
    };
}

export function requestAnnotationMove(next: AnnotationDraft): boolean {
    if (!handler) return false;
    handler(next);
    return true;
}

/** Listen before stopping so a paste arriving before the stop response is retained. */
export async function stopAndWaitForPaste(
    field: HTMLTextAreaElement,
    settings: DictationSettings,
    signal: AbortSignal,
): Promise<string> {
    let changed = false;
    let changedAt = 0;
    const input = () => {
        changed = true;
        changedAt = Date.now();
    };
    field.addEventListener("input", input);
    const deadline = AbortSignal.any([signal, AbortSignal.timeout(15000)]);
    field.focus();
    let responseAt: number | undefined;
    performance.clearMeasures("annotate:paste-wait");
    try {
        await triggerDictation(settings, "stop", deadline);
        responseAt = performance.now();
        while (true) {
            deadline.throwIfAborted();
            if (changed && Date.now() - changedAt >= 500) {
                const text = field.value.trim();
                if (!text) throw new Error("No text was pasted. The annotation is still open.");
                return text;
            }
            await new Promise((resolve) => window.setTimeout(resolve, 50));
        }
    } catch (error) {
        if (!signal.aborted && deadline.aborted)
            throw new Error(
                "Timed out waiting for dictation to paste. The annotation is still open.",
            );
        throw error;
    } finally {
        if (responseAt !== undefined) recordDictationTiming("annotate:paste-wait", responseAt);
        field.removeEventListener("input", input);
    }
}
