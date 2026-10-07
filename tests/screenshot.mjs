import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { chromium } from "playwright";

// A large page: the popup and the dictation trigger come first, the capture after, and it
// clones only the part of the page that can reach the crop.
const ROWS = 3000;
const rows = Array.from(
    { length: ROWS },
    (_, i) =>
        `<li class="row"><span class="n">${i}</span><b>Item ${i}</b><em>detail</em><a href="#">link</a><i>x</i></li>`,
).join("");

async function run(capture) {
    const browser = await chromium.launch();
    try {
        const page = await browser.newPage();
        const events = {};
        let submitted;
        await page.addInitScript(() => {
            // html-to-image clones every node it keeps; count them and note the first clone.
            const clone = Node.prototype.cloneNode;
            window.clones = 0;
            Node.prototype.cloneNode = function (...args) {
                if (this instanceof Element) {
                    window.clones++;
                    window.captureStarted ??= Date.now();
                }
                return clone.apply(this, args);
            };
        });
        await page.route("https://annotation.test/**", async (route) => {
            const url = new URL(route.request().url());
            if (url.pathname === "/index.js")
                return route.fulfill({
                    contentType: "text/javascript",
                    body: await readFile(new URL("../dist/index.js", import.meta.url)),
                });
            if (url.pathname === "/dictate") {
                events.dictation = Date.now();
                return route.fulfill({ status: 204 });
            }
            if (url.pathname === "/annotations") {
                if (route.request().method() === "POST") {
                    submitted = route.request().postDataJSON();
                    return route.fulfill({
                        status: 201,
                        json: { data: { ...submitted, number: 1, revision: 1, status: "todo" } },
                    });
                }
                return route.fulfill({ json: { data: [] } });
            }
            const hook =
                capture === "hook"
                    ? `capture: async (rect) => {
                          window.captureRect = rect;
                          const canvas = document.createElement("canvas");
                          canvas.width = rect.width;
                          canvas.height = rect.height;
                          const context = canvas.getContext("2d");
                          context.fillStyle = "#123456";
                          context.fillRect(0, 0, rect.width, rect.height);
                          return await new Promise((resolve) => canvas.toBlob(resolve, "image/png"));
                      },`
                    : capture === "failing-hook"
                      ? `capture: async () => { throw new Error("No pixels"); },`
                      : "";
            return route.fulfill({
                contentType: "text/html",
                body: `<!doctype html><style>.row{display:flex;gap:8px;padding:6px;border-bottom:1px solid #ddd;font:14px system-ui}.row:nth-child(odd){background:#f6f6f6}</style>
                    <h1 id="target" style="padding:40px">Annotate this heading</h1><ul>${rows}</ul>
                    <script type="module">
                        import { mountAnnotation } from "/index.js";
                        mountAnnotation({
                            serverUrl: "/annotations",
                            ${hook}
                            dictation: { provider: "post", postUrl: "/dictate", stopUrl: "/dictate-stop" },
                        });
                    </script>`,
            });
        });
        await page.goto("https://annotation.test/");
        await page.getByRole("button", { name: "Enter annotation mode" }).click();
        const elements = await page.evaluate(() => {
            window.clones = 0;
            window.captureStarted = undefined;
            const shadow = document.querySelector("#laravel-toolbar-annotation-host").shadowRoot;
            new MutationObserver((_, observer) => {
                if (!shadow.querySelector("[data-annotation-field]")) return;
                window.popupOpened = Date.now();
                observer.disconnect();
            }).observe(shadow, { childList: true, subtree: true });
            return document.getElementsByTagName("*").length;
        });
        const clicked = Date.now();
        // A person holds the button for about 100 ms; the old capture ran in that gap.
        const box = await page.locator("#target").boundingBox();
        await page.mouse.move(box.x + 20, box.y + 20);
        await page.mouse.down();
        await page.waitForTimeout(100);
        await page.mouse.up();
        await page.locator("[data-annotation-field]").waitFor();
        events.popup = await page.evaluate(() => window.popupOpened);
        await page.waitForFunction(() => window.captureStarted || window.captureRect, null, {
            timeout: 10_000,
        });
        await page.waitForTimeout(capture === "hook" ? 300 : 1500);
        await page.locator("[data-annotation-field]").fill("Smaller heading");
        await page.locator("[data-annotation-submit]").click();
        for (let tries = 0; !submitted && tries < 100; tries++) await page.waitForTimeout(50);
        const state = await page.evaluate(() => ({
            clones: window.clones,
            captureStarted: window.captureStarted,
            captureRect: window.captureRect,
        }));
        return { clicked, elements, events, submitted, ...state };
    } finally {
        await browser.close();
    }
}

const dom = await run("dom");
assert.ok(dom.events.dictation, "the dictation trigger is sent");
assert.ok(dom.captureStarted >= dom.events.popup, "the capture starts after the popup opens");
assert.ok(
    dom.captureStarted >= dom.events.dictation,
    "the capture starts after the dictation trigger",
);
assert.match(dom.submitted.screenshot ?? "", /^data:image\/jpeg;base64,/);
assert.ok(
    dom.clones < dom.elements / 4,
    `the crop filter skips rows below it (${dom.clones} of ${dom.elements} elements cloned)`,
);

const hooked = await run("hook");
assert.equal(hooked.captureStarted, undefined, "a host capture skips the DOM render");
assert.ok(hooked.captureRect.width > 0 && hooked.captureRect.height > 0);
assert.match(hooked.submitted.screenshot ?? "", /^data:image\/jpeg;base64,/);

const fallback = await run("failing-hook");
assert.ok(fallback.captureStarted, "a failing host capture falls back to the DOM render");
assert.match(fallback.submitted.screenshot ?? "", /^data:image\/jpeg;base64,/);

console.log(
    `Screenshot: popup ${dom.events.popup - dom.clicked} ms and dictation ${dom.events.dictation - dom.clicked} ms after the click, capture after both; ${dom.clones} of ${dom.elements} elements cloned; host capture and fallback passed.`,
);
