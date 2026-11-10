import { afterEach, beforeEach, expect, it, vi } from "vite-plus/test";
import { loadAnnotations, saveAnnotations } from "../../src/store";
import type { Annotation } from "../../src/types";

const values = new Map<string, string>();

beforeEach(() => {
    values.clear();
    vi.stubGlobal("window", { location: { pathname: "/page" } });
    vi.stubGlobal("localStorage", {
        getItem: (key: string) => values.get(key) ?? null,
        setItem: (key: string, value: string) => void values.set(key, value),
    });
});
afterEach(() => vi.unstubAllGlobals());

const pin = (extra: Partial<Annotation>): Annotation => ({
    id: "pin",
    x: 1,
    y: 2,
    comment: "Text",
    element: "h1",
    elementPath: "h1",
    timestamp: Date.now(),
    screenshot: "data:image/jpeg;base64,AAAA",
    ...extra,
});

it("leaves the screenshot of a stored record out of the cache", () => {
    saveAnnotations([pin({ revision: 3 })], "/page");
    const [cached] = loadAnnotations("/page");
    expect(cached.comment).toBe("Text");
    expect(cached.revision).toBe(3);
    expect("screenshot" in cached).toBe(false);
});

it("keeps the screenshot while the record still has to be delivered", () => {
    saveAnnotations([pin({ id: "new" }), pin({ id: "failed", revision: 2, syncError: "Offline" })]);
    const cached = loadAnnotations();
    expect(cached.map((item) => item.screenshot)).toEqual([
        "data:image/jpeg;base64,AAAA",
        "data:image/jpeg;base64,AAAA",
    ]);
});
