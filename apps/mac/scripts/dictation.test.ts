import { expect, test } from "bun:test";
import { DictationController, type DictationView } from "../src/comment/dictation";
import type { OfideReply } from "../src/types";

type Action = "status" | "start" | "stop" | "cancel";

/** A fake Ofide and clock. `sleep` advances the clock and yields a macrotask, so loops run fast. */
function harness(options: { enabled?: boolean; autoStart?: boolean; reply?: (action: Action, h: Harness) => OfideReply | Promise<OfideReply> } = {}) {
  const h = {
    clock: 1_000_000,
    text: "",
    calls: [] as Action[],
    views: [] as DictationView[],
    closed: 0,
    alerts: [] as [string, string][],
    ofideStatus: "recording" as string | null,
    cancelledAt: null as number | null,
    controller: null as unknown as DictationController,
  };
  const defaultReply = (action: Action): OfideReply => {
    if (action === "status") return h.ofideStatus === null ? { result: "notRunning" } : { result: "ok", status: h.ofideStatus, cancelledAt: h.cancelledAt };
    return { result: "ok" };
  };
  h.controller = new DictationController(options.enabled ?? true, options.autoStart ?? false, {
    ofide: async action => { h.calls.push(action); return (options.reply ?? defaultReply)(action, h as Harness); },
    sleep: ms => { h.clock += ms; return new Promise(resolve => setTimeout(resolve, 0)); },
    now: () => h.clock,
    text: () => h.text,
    onChange: view => h.views.push(view),
    requestClose: () => { h.closed++; },
    focus: () => {},
    alert: (title, message) => h.alerts.push([title, message]),
    chain: { current: null },
  });
  return h;
}
type Harness = ReturnType<typeof harness>;

const tick = () => new Promise(resolve => setTimeout(resolve, 0));
async function until(condition: () => boolean, limit = 2000) {
  for (let i = 0; i < limit && !condition(); i++) await tick();
  expect(condition()).toBe(true);
}
const kind = (h: Harness) => h.controller.dictation.kind;
const count = (h: Harness, action: Action) => h.calls.filter(call => call === action).length;

test("dictation off: no calls to Ofide", async () => {
  const h = harness({ enabled: false });
  await h.controller.open();
  expect(kind(h)).toBe("off");
  expect(h.calls).toEqual([]);
  expect(await h.controller.submit()).toBe(false); // empty comment
  h.text = "Fix it";
  expect(await h.controller.submit()).toBe(true);
});

test("checking, then idle without auto start", async () => {
  const h = harness();
  await h.controller.open();
  expect(h.views[0].dictation.kind).toBe("checking");
  expect(kind(h)).toBe("idle");
  expect(h.calls).toEqual(["status"]);
});

test("Ofide unreachable at open: unavailable with the reason", async () => {
  const h = harness({ reply: () => { throw "No Ofide Local API token at /x/control.json. Turn on Local API in Ofide → Settings."; } });
  await h.controller.open();
  expect(h.controller.dictation).toEqual({ kind: "unavailable", message: "No Ofide Local API token at /x/control.json. Turn on Local API in Ofide → Settings." });
});

test("Ofide not running at open", async () => {
  const h = harness({ reply: () => ({ result: "notRunning" }) });
  await h.controller.open();
  expect(h.controller.dictation).toEqual({ kind: "unavailable", message: "Ofide is not running." });
});

test("auto start records and polls status every 100 ms", async () => {
  const h = harness({ autoStart: true });
  void h.controller.open();
  await until(() => count(h, "status") >= 4);
  expect(kind(h)).toBe("recording");
  expect(count(h, "start")).toBe(1);
  const before = h.clock;
  await until(() => count(h, "status") >= 6);
  expect(h.clock - before).toBeGreaterThanOrEqual(100);
  h.controller.close();
});

test("a failed start keeps the button and says why", async () => {
  const h = harness({ reply: action => action === "start" ? { result: "failed", message: "500 Boom" } : { result: "ok", status: "ready" } });
  await h.controller.open();
  await h.controller.startRecording();
  expect(h.controller.state).toEqual({ dictation: { kind: "idle" }, message: "Ofide failed: 500 Boom" });
});

test("submit while recording stops, waits for the paste to settle, then submits once", async () => {
  const h = harness({
    reply: (action, h) => {
      if (action === "stop") {
        // The paste lands a little later, in two parts.
        setTimeout(() => { h.text = "Make it"; setTimeout(() => { h.text = "Make it blue"; }, 0); }, 0);
        return { result: "ok" };
      }
      return { result: "ok", status: "recording" };
    },
  });
  await h.controller.open();
  void h.controller.startRecording();
  await until(() => count(h, "status") >= 3);
  const first = h.controller.submit();
  const second = h.controller.submit();
  expect(await second).toBe(false);
  expect(await first).toBe(true);
  expect(h.text).toBe("Make it blue");
  expect(count(h, "stop")).toBe(1);
  expect(count(h, "cancel")).toBe(0);
  expect(h.controller.isClosing).toBe(true);
});

test("no paste within 3 s: the panel stays open and says so", async () => {
  const h = harness();
  h.text = "Before";
  await h.controller.open();
  void h.controller.startRecording();
  await until(() => count(h, "status") >= 3);
  const start = h.clock;
  expect(await h.controller.submit()).toBe(false);
  expect(h.clock - start).toBeGreaterThanOrEqual(3000);
  expect(h.controller.state).toEqual({ dictation: { kind: "idle" }, message: "Ofide sent a paste, but no text reached the comment field." });
  expect(h.controller.isClosing).toBe(false);
  // The typed text still submits after that.
  h.text = "Before, edited";
  expect(await h.controller.submit()).toBe(true);
});

test("stop without an active recording", async () => {
  const h = harness({ reply: action => action === "stop" ? { result: "noDictation" } : { result: "ok", status: "recording" } });
  await h.controller.open();
  void h.controller.startRecording();
  await until(() => count(h, "status") >= 2);
  expect(await h.controller.finish()).toBe(false);
  expect(h.controller.state).toEqual({ dictation: { kind: "idle" }, message: "Ofide had no active recording. It may have been cancelled." });
});

test("cancel calls /dictate/cancel once", async () => {
  const h = harness();
  await h.controller.open();
  void h.controller.startRecording();
  await until(() => count(h, "status") >= 2);
  h.controller.close();
  h.controller.close();
  await until(() => count(h, "cancel") === 1);
  for (let i = 0; i < 20; i++) await tick();
  expect(count(h, "cancel")).toBe(1);
  expect(kind(h)).toBe("off");
  expect(h.alerts).toEqual([]);
});

test("a cancel that fails shows an alert", async () => {
  const h = harness({ reply: action => action === "cancel" ? { result: "failed", message: "500 Nope" } : { result: "ok", status: "recording" } });
  await h.controller.open();
  void h.controller.startRecording();
  await until(() => count(h, "status") >= 2);
  h.controller.close();
  await until(() => h.alerts.length === 1);
  expect(h.alerts[0]).toEqual(["Could not cancel Ofide", "Ofide failed: 500 Nope"]);
});

test("closing before nothing records sends no cancel", async () => {
  const h = harness();
  await h.controller.open();
  h.controller.close();
  for (let i = 0; i < 5; i++) await tick();
  expect(count(h, "cancel")).toBe(0);
});

test("Ofide's own Esc (cancelledAt after the start) closes the panel without a cancel", async () => {
  const h = harness();
  await h.controller.open();
  void h.controller.startRecording();
  await until(() => count(h, "status") >= 3);
  h.cancelledAt = h.clock;
  await until(() => h.closed === 1);
  expect(kind(h)).toBe("off");
  expect(h.controller.isClosing).toBe(true);
  expect(count(h, "cancel")).toBe(0);
});

test("an older cancelledAt is ignored", async () => {
  const h = harness();
  h.cancelledAt = h.clock - 5000;
  await h.controller.open();
  void h.controller.startRecording();
  await until(() => count(h, "status") >= 5);
  expect(h.closed).toBe(0);
  expect(kind(h)).toBe("recording");
  h.controller.close();
});

test("Ofide ends the recording itself: transcribing, then the paste", async () => {
  const h = harness();
  await h.controller.open();
  void h.controller.startRecording();
  await until(() => count(h, "status") >= 3);
  h.ofideStatus = "transcribing";
  await until(() => kind(h) === "transcribing");
  h.ofideStatus = "ready";
  h.text = "Pasted";
  await until(() => kind(h) === "idle");
  expect(h.controller.state.message).toBeNull();
  expect(count(h, "stop")).toBe(0);
});

test("Ofide ends the recording with no text", async () => {
  const h = harness();
  await h.controller.open();
  void h.controller.startRecording();
  await until(() => count(h, "status") >= 2);
  h.ofideStatus = "ready";
  await until(() => kind(h) === "idle");
  expect(h.controller.state.message).toBe("Ofide finished without text. It was cancelled or heard only silence.");
});

test("Ofide stops answering while recording", async () => {
  const h = harness();
  await h.controller.open();
  void h.controller.startRecording();
  await until(() => count(h, "status") >= 2);
  h.ofideStatus = null;
  await until(() => kind(h) === "unavailable");
  expect(h.controller.dictation).toEqual({ kind: "unavailable", message: "Ofide stopped answering." });
});

test("submit waits for a transcription Ofide started itself", async () => {
  const h = harness();
  await h.controller.open();
  void h.controller.startRecording();
  await until(() => count(h, "status") >= 2);
  h.ofideStatus = "transcribing";
  await until(() => kind(h) === "transcribing");
  const submitted = h.controller.submit();
  await tick();
  h.ofideStatus = "ready";
  h.text = "Done by Ofide";
  expect(await submitted).toBe(true);
  expect(count(h, "stop")).toBe(0);
});

test("a new panel waits for the last cancel before it starts", async () => {
  const chain = { current: null as Promise<any> | null };
  const order: string[] = [];
  let release!: () => void;
  const gate = new Promise<void>(resolve => { release = resolve; });
  const make = () => new DictationController(true, false, {
    ofide: async action => {
      order.push(action);
      if (action === "cancel") await gate;
      return { result: "ok", status: "recording" };
    },
    sleep: () => new Promise(resolve => setTimeout(resolve, 0)), now: () => Date.now(), text: () => "",
    onChange: () => {}, requestClose: () => {}, focus: () => {}, alert: () => {}, chain,
  });
  const first = make();
  await first.open();
  void first.startRecording();
  await until(() => order.filter(action => action === "status").length >= 2);
  first.close();
  const second = make();
  await second.open();
  void second.startRecording();
  for (let i = 0; i < 10; i++) await tick();
  expect(order.lastIndexOf("start")).toBe(order.indexOf("start"));
  release();
  await until(() => order.filter(action => action === "start").length === 2);
  expect(order.indexOf("cancel")).toBeLessThan(order.lastIndexOf("start"));
  second.close();
});
