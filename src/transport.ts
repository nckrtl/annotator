import { createStore } from "./core/store";
import type { Annotation } from "./types";

export type TransportAvailability = {
    state: "checking" | "available" | "unavailable";
    reason: string;
};

/** A live connection: `live` says whether changes arrive as events right now. */
export type TransportSubscription = { stop: () => void; live: () => boolean };

/** A text setting the transport needs, shown in the toolbar settings while it is selected. */
export type TransportField = {
    /** Used as the input's id; keep it unique on the page. */
    id: string;
    label: string;
    placeholder?: string;
    value: () => string;
    /** Called with the trimmed value when the user saves the settings. */
    save: (value: string) => void;
    /** Short help text under the input, such as where the value came from. */
    status?: () => string;
    /** Notify when `value` or `status` changes outside the settings form. */
    subscribe?: (listener: () => void) => () => void;
};

/**
 * Delivers annotations somewhere other than the local annotation server.
 * The local server is the built-in transport, selected as delivery mode "server".
 */
export type AnnotationTransport = {
    /** Delivery mode id. Stored in the tab's settings; must not be "server". */
    id: string;
    /** Name shown in the Delivery mode list. */
    label: string;
    /**
     * Read-only check that runs when settings open, before every write and before
     * subscribing. Delivery fails with `reason` while the transport is unavailable.
     */
    check?: () => Promise<TransportAvailability>;
    /** Store a new or edited annotation. Resolve with the stored record; reject to fail delivery. */
    submit: (annotation: Annotation) => Promise<unknown>;
    /** Every record the transport knows. Resolved or cancelled records remove pins. */
    list: () => Promise<unknown[]>;
    /** Retry a failed delivery. Without it, a retry submits the annotation again. */
    retry?: (annotation: Annotation) => Promise<unknown>;
    /** Call `refresh` when records change. While `live()` is true, periodic polling pauses. */
    subscribe?: (refresh: () => void) => TransportSubscription;
    fields?: TransportField[];
};

const UNAVAILABLE: TransportAvailability = { state: "unavailable", reason: "Not checked yet." };

export const transportAvailability = createStore<Record<string, TransportAvailability>>({});
let transports: AnnotationTransport[] = [];
let generation = 0;

export function configureTransports(list: AnnotationTransport[] = []): void {
    const ids = new Set<string>();
    for (const transport of list) {
        if (!transport.id || transport.id === "server" || ids.has(transport.id))
            throw new Error(`Invalid annotation transport id: "${transport.id}"`);
        ids.add(transport.id);
    }
    transports = list;
    generation++;
    transportAvailability.setState(
        Object.fromEntries(
            list.map((transport) => [
                transport.id,
                transport.check ? UNAVAILABLE : { state: "available" as const, reason: "" },
            ]),
        ),
    );
}

export function listTransports(): AnnotationTransport[] {
    return transports;
}

export function findTransport(id: string): AnnotationTransport | undefined {
    return transports.find((transport) => transport.id === id);
}

/** Run the transport's read-only check and publish the result for the settings UI. */
export async function checkTransport(id: string): Promise<TransportAvailability> {
    const transport = findTransport(id);
    if (!transport) return { state: "unavailable", reason: `Unknown delivery mode: ${id}` };
    if (!transport.check) return { state: "available", reason: "" };
    const current = generation;
    const publish = (result: TransportAvailability) => {
        if (current === generation)
            transportAvailability.setState({
                ...transportAvailability.getSnapshot(),
                [id]: result,
            });
    };
    publish({ state: "checking", reason: `Checking ${transport.label}…` });
    let result: TransportAvailability;
    try {
        result = await transport.check();
    } catch (error) {
        result = {
            state: "unavailable",
            reason: error instanceof Error ? error.message : `Cannot check ${transport.label}.`,
        };
    }
    publish(result);
    return result;
}
