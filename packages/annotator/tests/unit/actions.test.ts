import { afterEach, expect, it, vi } from "vite-plus/test";
import { startEdit, cancelDraft } from "../../src/actions";
import { draft } from "../../src/state";
import { annotationPayload } from "../../src/payload";
import type { Annotation } from "../../src/types";

const hitTest = vi.hoisted(() => vi.fn());
vi.mock("../../src/dom", () => ({
    deepElementFromPoint: hitTest,
    isAnnotationUi: () => false,
    isElementFixed: () => false,
}));
afterEach(() => {
    cancelDraft();
    vi.unstubAllGlobals();
});

it("edits the original element after scrolling and records the new box's scroll offsets", () => {
    class Element {
        getBoundingClientRect() {
            return { width: 120, height: 40 };
        }
    }
    const element = new Element();
    hitTest.mockReturnValue(element);
    vi.stubGlobal("HTMLElement", Element);
    vi.stubGlobal("window", {
        innerWidth: 1000,
        location: { href: "https://fixture.test/page", pathname: "/page" },
        scrollX: 30,
        scrollY: 600,
        requestAnimationFrame: () => 1,
        cancelAnimationFrame: () => {},
    });
    const annotation: Annotation = {
        id: "scroll-pin",
        x: 10,
        y: 700,
        timestamp: 1,
        comment: "Fix",
        element: "button",
        elementPath: "button",
        boundingBox: { x: 100, y: 320, width: 120, height: 40 },
        scrollOffset: { x: 10, y: 400 },
    };
    startEdit(annotation);
    expect(hitTest).toHaveBeenLastCalledWith(140, 140);
    expect(draft.value?.targetElement).toBe(element);
    expect(draft.value?.boundingBox).toEqual({ x: 80, y: 120, width: 120, height: 40 });
    expect(draft.value?.scrollOffset).toEqual({ x: 30, y: 600 });
    const edited = { ...annotation, ...annotationPayload(draft.value!, "Edited") };
    window.scrollY = 650;
    startEdit(edited);
    expect(hitTest).toHaveBeenLastCalledWith(140, 90);
    expect(draft.value?.boundingBox.y).toBe(70);
});
