/**
 * Dictation holds the screenshot back until its trigger is out: the POST is sent or the
 * speech connection records. A DOM render blocks the main thread, and doing it first
 * would delay both.
 */
let holds = 0;
let waiters: Array<() => void> = [];

export function holdCapture(): () => void {
    holds++;
    let released = false;

    return () => {
        if (released) return;
        released = true;
        holds--;
        if (holds > 0) return;
        const ready = waiters;
        waiters = [];
        ready.forEach((resolve) => resolve());
    };
}

/** Resolve when no dictation start is pending, or after `timeoutMs` at most. */
export function captureReady(timeoutMs: number): Promise<void> {
    if (holds === 0) return Promise.resolve();

    return new Promise((resolve) => {
        waiters.push(resolve);
        window.setTimeout(resolve, timeoutMs);
    });
}
