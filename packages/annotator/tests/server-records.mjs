// Origins, single records, edits and scoped removal on a real server.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, utimes, writeFile } from "node:fs/promises";
import { hostname, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createServer, request } from "node:http";
import { annotationServerProxy } from "../bin/vite.mjs";

const dir = await mkdtemp(join(tmpdir(), "annotate-records-"));
const script = resolve("bin/serve.mjs");
const children = [];
async function start(extra = [], cwd = process.cwd()) {
    const child = spawn(process.execPath, [script, "serve", ...extra], {
        cwd,
        stdio: ["ignore", "pipe", "pipe"],
    });
    children.push(child);
    let output = "";
    child.stderr.on("data", (data) => (output += data));
    const url = await new Promise((done, fail) => {
        const timer = setTimeout(() => fail(new Error(`Startup timed out\n${output}`)), 5000);
        child.stdout.on("data", (data) => {
            output += data;
            const match = output.match(/Annotation server URL: (\S+)/);
            if (match) {
                clearTimeout(timer);
                done(match[1]);
            }
        });
        child.once("exit", (code) => {
            clearTimeout(timer);
            fail(new Error(`Server exited ${code}\n${output}`));
        });
    });
    return { child, url, output: () => output };
}
const post = (url, body) =>
    fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
    });
const list = async (url) => (await (await fetch(url)).json()).data;
/** fetch() normalises the path, so a broken percent-escape needs a raw request. */
const raw = (url, method, path, headers = {}) =>
    new Promise((done, fail) => {
        const target = new URL(url);
        const options = { host: target.hostname, port: target.port, method, path, headers };
        const req = request(options, (res) => {
            res.resume();
            done(res.statusCode);
        });
        req.on("error", fail);
        req.end(method === "POST" ? "{}" : undefined);
    });

try {
    const store = join(dir, "store");
    const server = await start(["--store", store]);
    const { url } = server;

    // Rebinding needs a name an attacker can point here. An address and "localhost" are safe on
    // any port, so agents in a VM, a container or behind a port forward connect. Every other
    // name is refused, also this machine's own: a hostile network can answer for it.
    const port = new URL(url).port;
    for (const host of [
        `127.0.0.1:${port}`,
        "localhost:2222",
        "192.168.64.1:8080",
        "10.44.0.6",
        "[fd00::1]:9000",
        "LOCALHOST:29703",
    ])
        assert.equal(await raw(url, "GET", "/health", { Host: host }), 200, host);
    for (const host of [
        "evil.example",
        `rebind.example:${port}`,
        "localhost.evil.example",
        "app.localhost",
        "localhost.",
        "host.docker.internal",
        hostname(),
        hostname().replace(/\.local$/, ""),
    ])
        assert.equal(await raw(url, "GET", "/health", { Host: host }), 403, host);
    const named = await start(["--allow-host", "Tunnel.Example", "--store", join(dir, "named")]);
    assert.equal(await raw(named.url, "GET", "/health", { Host: "tunnel.example:443" }), 200);
    assert.equal(await raw(named.url, "GET", "/health", { Host: "other.example" }), 403);
    assert.equal((await (await fetch(url)).json()).meta.removesBySite, true);

    // Pages on this machine connect without a flag. Pages elsewhere do not.
    for (const origin of [
        "http://localhost:5173",
        "https://localhost",
        "http://127.0.0.1:8000",
        "http://127.0.0.2:3000",
        "http://[::1]:3000",
    ]) {
        const response = await fetch(url, {
            method: "OPTIONS",
            headers: { Origin: origin, "Access-Control-Request-Private-Network": "true" },
        });
        assert.equal(response.status, 204, origin);
        assert.equal(response.headers.get("access-control-allow-origin"), origin);
        assert.equal(response.headers.get("access-control-allow-private-network"), "true");
        assert.equal((await fetch(url, { headers: { Origin: origin } })).status, 200, origin);
    }
    for (const origin of [
        "https://evil.example",
        "http://app.localhost:8080",
        `http://${hostname()}:5173`,
        "http://localhost.evil.example",
        "https://127.0.0.1.evil.example",
        "null",
        "file://",
    ]) {
        const response = await fetch(url, { headers: { Origin: origin } });
        assert.equal(response.status, 403, origin);
        assert.equal(response.headers.get("access-control-allow-origin"), null, origin);
    }
    // A plain-text POST needs no preflight in a browser. The origin check still stops it.
    const simple = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "text/plain", Origin: "https://evil.example" },
        body: JSON.stringify({ id: "injected", comment: "Injected" }),
    });
    assert.equal(simple.status, 403);
    assert.deepEqual(await list(url), []);
    // The overlay script holds no data: any page may load it, with or without CORS.
    const injectUrl = new URL("/inject.js", url);
    for (const headers of [{ Origin: "https://app.example" }, { "Sec-Fetch-Site": "cross-site" }]) {
        const response = await fetch(injectUrl, { headers });
        assert.equal(response.status, 200);
        assert.match(response.headers.get("content-type"), /javascript/);
        await response.arrayBuffer();
    }
    assert.equal((await fetch(url, { headers: { "Sec-Fetch-Site": "cross-site" } })).status, 403);

    // The server sets its own fields; a client cannot.
    const created = await post(url, {
        id: "pin-1",
        comment: "First text",
        url: "https://one.test/page",
        pathname: "/page",
        screenshot: "data:image/jpeg;base64,AAAA",
        number: 99,
        status: "done",
        revision: 50,
        question: true,
        summary: "Planted",
        claimedAt: 1,
        completedAt: 2,
    });
    assert.equal(created.status, 201);
    const first = (await created.json()).data;
    assert.equal(first.number, 1);
    assert.equal(first.status, "todo");
    assert.equal(first.revision, 1);
    for (const field of ["question", "summary", "claimedAt", "completedAt"])
        assert.equal(first[field], undefined, field);
    assert.equal(
        (await post(`${url}/claim`, {})).status,
        200,
        "A planted question cannot hide work",
    );
    assert.equal((await post(`${url}/release`, { id: "pin-1" })).status, 200);

    // The same comment is a retry: nothing changes.
    const before = (await list(url)).find((a) => a.id === "pin-1");
    const retry = await post(url, { id: "pin-1", comment: "First text" });
    assert.equal(retry.status, 200);
    assert.deepEqual((await retry.json()).data, before);

    // A new comment edits a todo record and keeps what the request leaves out.
    const edit = await post(url, { id: "pin-1", comment: "Edited text", pathname: "/page" });
    assert.equal(edit.status, 200);
    const edited = (await edit.json()).data;
    assert.equal(edited.comment, "Edited text");
    assert.equal(edited.number, 1);
    assert.equal(edited.status, "todo");
    assert.ok(edited.revision > before.revision);
    assert.equal(edited.screenshot, "data:image/jpeg;base64,AAAA");
    assert.equal(edited.createdAt, before.createdAt);
    const deadline = Date.now() + 5000;
    while (!server.output().includes("#1 edited: Edited text")) {
        assert.ok(Date.now() < deadline, server.output());
        await new Promise((done) => setTimeout(done, 10));
    }

    // Claimed or finished work can no longer be edited, and says so.
    assert.equal((await post(`${url}/claim`, { id: "pin-1" })).status, 200);
    const locked = await post(url, { id: "pin-1", comment: "Too late" });
    assert.equal(locked.status, 409);
    assert.match((await locked.json()).error, /in progress\. It can no longer be edited\.$/);
    assert.equal((await post(url, { id: "pin-1", comment: "Edited text" })).status, 200);
    assert.equal((await post(`${url}/complete`, { id: "pin-1" })).status, 200);
    const finished = await post(url, { id: "pin-1", comment: "Much too late" });
    assert.equal(finished.status, 409);
    assert.match((await finished.json()).error, /is done\./);
    assert.equal((await list(url))[0].comment, "Edited text");

    // One full record, and a list without the images.
    const one = await fetch(`${url}/pin-1`);
    assert.equal(one.status, 200);
    assert.equal((await one.json()).data.screenshot, "data:image/jpeg;base64,AAAA");
    assert.equal((await fetch(`${url}/missing`)).status, 404);
    const slim = await (await fetch(`${url}?screenshots=0`)).json();
    assert.equal(slim.meta.service, "@nckrtl/annotator");
    assert.equal(slim.data.length, 1);
    assert.equal(slim.data[0].comment, "Edited text");
    assert.equal("screenshot" in slim.data[0], false);
    assert.equal((await list(url))[0].screenshot, "data:image/jpeg;base64,AAAA");

    // A broken percent-escape is a bad id, not a server error.
    assert.equal(await raw(url, "DELETE", "/annotations/%E0%A4%A"), 422);
    assert.equal(await raw(url, "POST", "/annotations/%E0%A4%A/status"), 422);
    assert.equal(await raw(url, "GET", "/annotations/%E0%A4%A"), 404);

    // Removal by site leaves other sites and desktop apps alone.
    await post(url, { id: "pin-2", comment: "Same site", url: "https://one.test/other" });
    await post(url, { id: "pin-3", comment: "Other site", url: "https://two.test/page" });
    await post(url, { id: "pin-4", comment: "Desktop app", url: "app://com.apple.mail" });
    await post(url, { id: "pin-5", comment: "No address" });
    const removal = await fetch(`${url}?origin=${encodeURIComponent("https://one.test")}`, {
        method: "DELETE",
    });
    assert.deepEqual((await removal.json()).data.removedIds.sort(), ["pin-1", "pin-2"]);
    assert.deepEqual(
        (await list(url)).map((a) => a.id),
        ["pin-3", "pin-4", "pin-5"],
    );
    assert.equal(server.output().includes("All annotations removed"), false);
    const nothing = await fetch(`${url}?origin=null`, { method: "DELETE" });
    assert.deepEqual((await nothing.json()).data.removedIds, []);

    // The skill text stays valid shell in a folder with a quote or a dollar sign.
    const odd = join(dir, "it's $& here");
    await mkdir(odd);
    const quoted = await start(["--store", join(dir, "quoted")], odd);
    const skill = await (await fetch(new URL("/skill", quoted.url))).text();
    const line = skill.split("\n").find((text) => text.startsWith("PROJECT_ROOT="));
    assert.ok(line.endsWith("it'\\''s $& here'"), line);
    assert.ok(line.startsWith("PROJECT_ROOT='/"), line);

    // A lock left by a crashed server does not block the store when its PID now
    // belongs to another program. PID 1 is always alive and never a server.
    const stale = join(dir, "stale");
    await mkdir(stale);
    await writeFile(join(stale, ".server.pid"), "1");
    const reused = await start(["--store", stale]);
    assert.equal((await fetch(reused.url)).status, 200);
    assert.equal(await readFile(join(stale, ".server.pid"), "utf8"), String(reused.child.pid));
    // The same holds when the PID now belongs to another Node.js program: that program started
    // after the lock was written, so it cannot be the server that wrote it.
    const later = join(dir, "later");
    await mkdir(later);
    const other = spawn(process.execPath, ["-e", "setTimeout(() => {}, 60000)"]);
    children.push(other);
    await writeFile(join(later, ".server.pid"), String(other.pid));
    const hourAgo = new Date(Date.now() - 3_600_000);
    await utimes(join(later, ".server.pid"), hourAgo, hourAgo);
    const afterReuse = await start(["--store", later]);
    assert.equal((await fetch(afterReuse.url)).status, 200);
    // A lock held by a running server still blocks.
    await assert.rejects(start(["--store", stale]), /already served by another process/);
    // The Vite bridge also accepts a server from before /health named the service.
    const older = createServer((req, res) => {
        res.setHeader("Content-Type", "application/json");
        res.end(
            req.url === "/health"
                ? '{"ok":true}'
                : '{"data":[],"meta":{"service":"@nckrtl/annotator","eventsUrl":"annotations/events"}}',
        );
    });
    await new Promise((done) => older.listen(0, "127.0.0.1", done));
    const stranger = createServer((req, res) => res.end('{"ok":true,"data":[]}'));
    await new Promise((done) => stranger.listen(0, "127.0.0.1", done));
    let bridge;
    annotationServerProxy().configureServer({
        middlewares: { use: (handler) => (bridge = handler) },
    });
    const viaBridge = (target) =>
        new Promise((done) => {
            const res = {
                headersSent: false,
                on() {},
                writeHead(status) {
                    this.status = status;
                    this.headersSent = true;
                },
                end(body) {
                    done({ status: this.status, body: JSON.parse(body) });
                },
            };
            const req = {
                url: `/__annotate/local/${target.address().port}/annotations`,
                headers: { host: "localhost:5173" },
                method: "GET",
            };
            void bridge(req, res, () => done({ status: 0 }));
        });
    const bridged = await viaBridge(older);
    assert.equal(bridged.status, 200);
    assert.match(bridged.body.meta.eventsUrl, /^\/__annotate\/local\/\d+\/annotations\/events$/);
    assert.equal((await viaBridge(stranger)).status, 502);
    older.close();
    stranger.close();
    console.log("server records: passed");
} finally {
    for (const child of children) child.kill("SIGTERM");
    await rm(dir, { recursive: true, force: true });
}
