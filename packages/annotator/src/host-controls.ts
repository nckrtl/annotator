import { annotationMode, annotations } from "./state";
import {
    deliveryMode,
    localSessionCount,
    serviceConnection,
    removalError,
    serviceSettings,
    saveServiceSettings,
    type DeliveryMode,
} from "./sync";
import { transportAvailability } from "./transport";

const stores = [
    annotationMode.store,
    annotations.store,
    deliveryMode,
    localSessionCount,
    serviceConnection,
    removalError,
    transportAvailability,
];
function snapshot() {
    const visibleCount = annotations.value.length;
    return {
        active: annotationMode.value,
        count:
            deliveryMode.getSnapshot() === "server"
                ? Math.max(localSessionCount.getSnapshot(), visibleCount)
                : visibleCount,
        /** Open annotations on the current page. */
        pageCount: visibleCount,
        mode: deliveryMode.getSnapshot(),
        connection: serviceConnection.getSnapshot(),
        removalError: removalError.getSnapshot(),
        /** Last check result per transport id. */
        transports: transportAvailability.getSnapshot(),
    };
}
let cached = snapshot();
/** Stable snapshots can be consumed by any framework, without sharing React. */
export function getAnnotationState() {
    const next = snapshot();
    if (
        Object.keys(next).some(
            (key) => next[key as keyof typeof next] !== cached[key as keyof typeof cached],
        )
    )
        cached = next;
    return cached;
}
export function subscribeAnnotationState(listener: () => void): () => void {
    const unsubscribe = stores.map((store) => store.subscribe(listener));
    return () => unsubscribe.forEach((stop) => stop());
}
export function getAnnotationSettings() {
    return serviceSettings();
}
export function saveAnnotationSettings(settings: { mode: DeliveryMode; serviceUrl: string }): void {
    saveServiceSettings(settings.serviceUrl, settings.mode);
}
