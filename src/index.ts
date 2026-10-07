import { configureAnnotationService } from "./sync";
import { configureTransports, type AnnotationTransport } from "./transport";
import { configureToolbarData, type ToolbarData } from "./core/request-history";
import { configureHostHooks, type AnnotationMetadataHook, type CaptureHook } from "./hooks";
import { ensureAnnotationRuntime, teardownAnnotationRuntime } from "./runtime";
import type { DictationInput } from "./dictation-settings";

export type AnnotationOptions = {
    floatingControl?: boolean;
    /** Local annotation server endpoint, such as the URL printed by `annotator serve`. */
    serverUrl?: string;
    /** Same-origin endpoint probed when nothing is configured. inject.js sets it to its own server. */
    discoverServerUrl?: string;
    /** Extra delivery modes. The local server is always available as "server". */
    transports?: AnnotationTransport[];
    /** Delivery mode for a tab without a saved choice: "server" or a transport id. */
    delivery?: string;
    /** Extra context stored on each new annotation, such as a host session id. */
    metadata?: AnnotationMetadataHook;
    /** Supply real pixels for the screenshot, for example from Electron or CDP. */
    capture?: CaptureHook;
    dictation?: DictationInput;
    getToolbarData?: () => ToolbarData;
};

/** Mount once per page; repeated calls update configuration without duplicating controls. */
export function mountAnnotation(options: AnnotationOptions = {}) {
    configureTransports(options.transports);
    configureHostHooks(options);
    configureAnnotationService({
        serverUrl: options.serverUrl,
        delivery: options.delivery,
        discoverUrl: options.discoverServerUrl,
    });
    configureToolbarData(options.getToolbarData);
    ensureAnnotationRuntime(options);
    return { destroy: teardownAnnotationRuntime };
}

export {
    clearAllAnnotations,
    clearPageAnnotations,
    ensureAnnotationRuntime,
    teardownAnnotationRuntime,
    toggleAnnotationMode,
    setAnnotationMode,
} from "./runtime";
export type { Annotation, AnnotationRect } from "./types";
export type { DictationSettings } from "./dictation";
export type { ToolbarData } from "./core/request-history";
export type { AnnotationMetadataHook, AnnotationMetadataTarget, CaptureHook } from "./hooks";
export type {
    AnnotationTransport,
    TransportAvailability,
    TransportField,
    TransportSubscription,
} from "./transport";

export {
    getAnnotationState,
    subscribeAnnotationState,
    getAnnotationSettings,
    saveAnnotationSettings,
} from "./host-controls";
export { checkAnnotationServer, type DeliveryMode } from "./sync";
export { checkTransport } from "./transport";
