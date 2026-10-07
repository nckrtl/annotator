import type { AnnotationRect } from "./types";

export type AnnotationMetadataTarget = { element: HTMLElement; url: string; pathname: string };

/** Return extra fields for a new annotation. They are stored under `metadata` and sent with it. */
export type AnnotationMetadataHook = (
    target: AnnotationMetadataTarget,
) => Record<string, unknown> | undefined;

/** Capture the viewport area `rect` (CSS pixels) as an image: a Blob or a data URL. */
export type CaptureHook = (rect: AnnotationRect) => Promise<Blob | string>;

let metadataHook: AnnotationMetadataHook | undefined;
let captureHook: CaptureHook | undefined;

export function configureHostHooks(options: {
    metadata?: AnnotationMetadataHook;
    capture?: CaptureHook;
}): void {
    metadataHook = options.metadata;
    captureHook = options.capture;
}

export function annotationMetadata(
    target: AnnotationMetadataTarget,
): Record<string, unknown> | undefined {
    if (!metadataHook) return undefined;
    try {
        const metadata = metadataHook(target);
        return metadata && Object.keys(metadata).length > 0 ? metadata : undefined;
    } catch (error) {
        console.error("Annotation metadata hook failed", error);
        return undefined;
    }
}

export function hostCapture(): CaptureHook | undefined {
    return captureHook;
}
