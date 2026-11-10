import { execFileSync, spawn } from "node:child_process";
import {
    mkdirSync,
    openSync,
    readFileSync,
    renameSync,
    rmSync,
    statSync,
    writeFileSync,
} from "node:fs";
import { dirname } from "node:path";

const SERVICE = "@nckrtl/annotator";
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export function readState(file) {
    try {
        const state = JSON.parse(readFileSync(file, "utf8"));
        return Number.isInteger(state?.pid) && typeof state.url === "string" ? state : null;
    } catch {
        return null;
    }
}

export function writeState(file, state) {
    mkdirSync(dirname(file), { recursive: true });
    const temporary = `${file}.${process.pid}.tmp`;
    writeFileSync(temporary, `${JSON.stringify(state, null, 4)}\n`);
    renameSync(temporary, file);
}

/** Remove the state file only when it still describes this process. */
export function clearState(file, pid) {
    if (readState(file)?.pid === pid) rmSync(file, { force: true });
}

function writtenAt(file) {
    try {
        return statSync(file).mtimeMs;
    } catch {
        return undefined;
    }
}

function alive(pid) {
    try {
        process.kill(pid, 0);
        return true;
    } catch (error) {
        return error.code === "EPERM";
    }
}

/**
 * False only when the PID surely belongs to another program. After a crash or a power loss the
 * system can give a server's old PID to something else; that must not block the store forever.
 * `writtenAt` is when the server wrote its lock or state file. A server starts before it writes
 * that file, so a process that started later is not that server.
 */
export function mayBeServer(pid, writtenAt) {
    if (process.platform === "win32") return true;
    try {
        const line = execFileSync("ps", ["-p", String(pid), "-o", "lstart=", "-o", "command="], {
            encoding: "utf8",
            timeout: 2000,
            env: { ...process.env, LC_ALL: "C" },
            stdio: ["ignore", "pipe", "ignore"],
        }).trim();
        // "Tue Nov 10 22:35:54 2026 node …": the start time is the first five words.
        const words = line.split(/\s+/);
        const started = Date.parse(words.slice(0, 5).join(" "));
        if (writtenAt !== undefined && Number.isFinite(started) && started > writtenAt + 2000)
            return false;
        return /node|bun|deno|annotator/i.test(words.slice(5).join(" "));
    } catch {
        return true;
    }
}

async function responds(url) {
    const service = async (target, read) => {
        const response = await fetch(target, { signal: AbortSignal.timeout(2000) });
        return response.ok && read(await response.json()) === SERVICE;
    };
    try {
        const health = new URL(url);
        health.pathname = health.pathname.replace(/\/annotations\/?$/, "/health");
        if (await service(health, (body) => body?.service)) return true;
        // An older server names itself only in its list.
        return await service(url, (body) => body?.meta?.service);
    } catch {
        return false;
    }
}

/** Report the server in the state file. A dead server's state file is removed. */
export async function status(file) {
    const state = readState(file);
    const live = state && alive(state.pid) && mayBeServer(state.pid, writtenAt(file));
    if (live && (await responds(state.url))) return { running: true, ...state };
    if (state && !live) rmSync(file, { force: true });
    return live
        ? { running: false, pid: state.pid, error: "The annotation server does not respond." }
        : { running: false };
}

/** Start `serve` in the background, detached from the caller, and wait until it answers. */
export async function start(file, serveArgs, script) {
    const current = await status(file);
    if (current.running) return current;
    if (current.pid)
        throw new Error(`Process ${current.pid} holds the state file but does not respond.`);
    mkdirSync(dirname(file), { recursive: true });
    const log = file.replace(/\.json$/, "") + ".log";
    const output = openSync(log, "a");
    const child = spawn(process.execPath, [script, "serve", ...serveArgs, "--state", file], {
        detached: true,
        stdio: ["ignore", output, output],
    });
    let exited = false;
    child.once("exit", () => (exited = true));
    child.unref();
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline && !exited) {
        await sleep(100);
        const state = readState(file);
        if (state?.pid === child.pid && (await responds(state.url)))
            return { running: true, ...state };
    }
    throw new Error(`The annotation server did not start. See ${log}.`);
}

/** Stop the server in the state file with SIGTERM, so it closes its store cleanly. */
export async function stop(file) {
    const state = readState(file);
    if (!state || !alive(state.pid) || !mayBeServer(state.pid, writtenAt(file))) {
        rmSync(file, { force: true });
        return { running: false, stopped: false };
    }
    // Never signal a process unless it is the annotation server named in the state file.
    if (!(await responds(state.url)))
        throw new Error(
            `Process ${state.pid} does not respond as an annotation server. Stop it manually.`,
        );
    process.kill(state.pid, "SIGTERM");
    const deadline = Date.now() + 5000;
    while (alive(state.pid) && Date.now() < deadline) await sleep(50);
    if (alive(state.pid)) throw new Error(`Process ${state.pid} did not stop.`);
    rmSync(file, { force: true });
    return { running: false, stopped: true };
}
