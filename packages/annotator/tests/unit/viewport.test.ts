import { expect, it } from "vite-plus/test";
import { annotationViewportBox } from "../../src/viewport";
import type { Annotation } from "../../src/types";

const annotation: Annotation = {
    id: "pin",
    x: 10,
    y: 600,
    comment: "Fix",
    element: "button",
    elementPath: "button",
    timestamp: 1,
    boundingBox: { x: 100, y: 300, width: 120, height: 40 },
    scrollOffset: { x: 80, y: 400 },
    scrollPosition: "400px",
};
it("moves recorded boxes by both scroll deltas without changing the stored box", () => {
    expect(annotationViewportBox(annotation, { x: 100, y: 550 })).toEqual({
        x: 80,
        y: 150,
        width: 120,
        height: 40,
    });
    expect(annotation.boundingBox?.y).toBe(300);
});
it("keeps fixed boxes in viewport coordinates", () => {
    expect(annotationViewportBox({ ...annotation, isFixed: true }, { x: 100, y: 550 })).toEqual(
        annotation.boundingBox,
    );
});
it("reads the vertical scroll of older annotations", () => {
    expect(
        annotationViewportBox({ ...annotation, scrollOffset: undefined }, { x: 0, y: 550 })?.y,
    ).toBe(150);
    expect(
        annotationViewportBox(
            { ...annotation, scrollOffset: undefined, scrollPosition: undefined },
            { x: 0, y: 50 },
        )?.y,
    ).toBe(250);
});
