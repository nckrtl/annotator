import { request } from "node:http";

const prefix = "/__annotate/local";

/** Forward browser requests to an annotation server on the development machine. */
export function annotationServerProxy() {
    return {
        name: "annotate-local-server",
        apply: "serve",
        transformIndexHtml() {
            return [
                {
                    tag: "meta",
                    attrs: { name: "annotate-local-server-proxy", content: prefix },
                    injectTo: "head",
                },
            ];
        },
        configureServer(server) {
            /** Ports of older annotation servers, and until when that answer is trusted. */
            const older = new Map();
            server.middlewares.use(async (req, res, next) => {
                const url = new URL(req.url ?? "/", "http://localhost");
                const match = url.pathname.match(
                    /^\/__annotate\/local\/(\d+)\/annotations(\/events|\/claim|\/complete|\/release|\/[^/?]+\/status|\/[A-Za-z0-9][A-Za-z0-9_-]{0,199})?$/,
                );
                if (!match) return next();
                const port = Number(match[1]);
                const json = (status, body) => {
                    res.writeHead(status, {
                        "Content-Type": "application/json",
                        "Cache-Control": "no-store",
                    });
                    res.end(JSON.stringify(body));
                };
                if (port < 1 || port > 65535)
                    return json(400, { error: "Invalid annotation server port" });
                if (req.headers.origin) {
                    try {
                        if (new URL(req.headers.origin).host !== req.headers.host)
                            return json(403, { error: "Use this development site's origin" });
                    } catch {
                        return json(403, { error: "Invalid browser origin" });
                    }
                }
                if (!["GET", "POST", "DELETE"].includes(req.method))
                    return json(405, { error: "Method not allowed" });
                try {
                    // Only bridge the annotation service, never arbitrary local applications.
                    const check = await fetch(`http://127.0.0.1:${port}/health`, {
                        signal: AbortSignal.timeout(3000),
                    });
                    const body = await check.json();
                    let known = check.ok && body.service === "@nckrtl/annotator";
                    // Whatever answers here now is not the older server seen before.
                    if (!check.ok || body.ok !== true) older.delete(port);
                    if (!known && check.ok && body.ok === true) {
                        // An older server names itself only in its list. That list is large,
                        // so remember the answer for a minute.
                        known = older.get(port) > Date.now();
                        if (!known) {
                            older.delete(port);
                            const list = await fetch(`http://127.0.0.1:${port}/annotations`, {
                                signal: AbortSignal.timeout(3000),
                            });
                            known =
                                list.ok &&
                                (await list.json()).meta?.service === "@nckrtl/annotator";
                            if (known) older.set(port, Date.now() + 60_000);
                        }
                    }
                    if (!known)
                        return json(502, {
                            error: "This port is not an annotation server. Restart annotator serve with the latest package.",
                        });
                    if (req.method === "GET" && !match[2]) {
                        const list = await fetch(
                            `http://127.0.0.1:${port}/annotations${url.search}`,
                            {
                                signal: AbortSignal.timeout(3000),
                            },
                        );
                        const records = await list.json();
                        if (list.ok && records.meta) {
                            records.meta.eventsUrl = `${prefix}/${port}/annotations/events`;
                            if (records.meta.skillUrl)
                                records.meta.skillUrl = `${prefix}/${port}/annotations/skill`;
                        }
                        return json(list.status, records);
                    }
                    const upstream = request(
                        {
                            hostname: "127.0.0.1",
                            port,
                            path: `/annotations${match[2] ?? ""}${url.search}`,
                            method: req.method,
                            headers: { "Content-Type": "application/json" },
                        },
                        (response) => {
                            res.writeHead(response.statusCode ?? 502, {
                                "Content-Type":
                                    response.headers["content-type"] ?? "application/json",
                                "Cache-Control": "no-store",
                            });
                            response.pipe(res);
                        },
                    );
                    upstream.on("error", () => {
                        if (!res.headersSent)
                            json(502, { error: "Annotation server disconnected" });
                        else res.end();
                    });
                    res.on("close", () => upstream.destroy());
                    req.pipe(upstream);
                } catch {
                    older.delete(port);
                    json(502, {
                        error: `Annotation server on port ${port} is unavailable on the development machine.`,
                    });
                }
            });
        },
    };
}
