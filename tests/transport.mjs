import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { chromium } from "playwright";

// A host transport: availability checks, its settings field, metadata, and rechecks before writes.
const browser = await chromium.launch();
try {
    for (const scenario of ["available", "unavailable", "throws", "absent"]) {
        const page = await browser.newPage();
        let enabled = scenario !== "unavailable";
        const posts = [];
        await page.route("https://annotation.test/**", async (route) => {
            const path = new URL(route.request().url()).pathname;
            if (path === "/index.js") {
                return route.fulfill({
                    contentType: "text/javascript",
                    body: await readFile(new URL("../dist/index.js", import.meta.url)),
                });
            }
            if (path === "/status") {
                if (scenario === "throws") return route.abort("connectionrefused");
                return route.fulfill({ json: { enabled } });
            }
            if (path === "/remote") {
                if (route.request().method() === "POST") {
                    const body = route.request().postDataJSON();
                    posts.push(body);
                    return route.fulfill({ json: { data: { ...body, revision: 1 } } });
                }
                return route.fulfill({ json: { data: [] } });
            }
            const setup = `
                import { mountAnnotation } from "/index.js";
                const json = async (response) => {
                    const body = await response.json();
                    if (!response.ok) throw new Error("HTTP " + response.status);
                    return body;
                };
                let channel = "general";
                const remote = {
                    id: "remote",
                    label: "Remote",
                    check: async () => {
                        let status;
                        try {
                            status = await json(await fetch("/status"));
                        } catch {
                            throw new Error("Cannot reach Remote.");
                        }
                        return status.enabled
                            ? { state: "available", reason: "Remote available" }
                            : { state: "unavailable", reason: "Enable Remote first." };
                    },
                    submit: async (annotation) =>
                        (await json(await fetch("/remote", {
                            method: "POST",
                            headers: { "Content-Type": "application/json" },
                            body: JSON.stringify({ ...annotation, channel }),
                        }))).data,
                    list: async () => (await json(await fetch("/remote"))).data,
                    fields: [{
                        id: "remote-channel",
                        label: "Channel",
                        value: () => channel,
                        save: (value) => { channel = value; },
                        status: () => "Configured by host",
                    }],
                };
                mountAnnotation({
                    transports: ${scenario === "absent" ? "[]" : "[remote]"},
                    metadata: ({ element, pathname }) => ({ session: "s-1", tag: element.tagName, pathname }),
                    dictation: { autoStart: false },
                });`;
            return route.fulfill({
                contentType: "text/html",
                body: `<h1 style="padding:80px">Target</h1><script type="module">${setup}</script>`,
            });
        });
        await page.goto("https://annotation.test");
        await page.getByRole("button", { name: "Annotation settings", exact: true }).click();
        const mode = page.getByLabel("Delivery mode", { exact: true });
        if (scenario === "absent") {
            assert.deepEqual(await mode.locator("option").allTextContents(), ["Local server"]);
            assert.equal(await mode.inputValue(), "server");
            await page.close();
            continue;
        }
        const option = mode.locator('option[value="remote"]');
        assert.equal(await mode.inputValue(), "remote", "The first transport is the default");
        if (scenario === "available") {
            await page.waitForFunction(
                () =>
                    !document
                        .querySelector("#laravel-toolbar-annotation-host")
                        .shadowRoot.querySelector('option[value="remote"]').disabled,
            );
            assert.equal(await page.getByLabel("Channel", { exact: true }).inputValue(), "general");
            await page.getByText("Configured by host", { exact: true }).waitFor();
            await page.getByLabel("Channel", { exact: true }).fill("design");
            await page.getByRole("button", { name: "Save", exact: true }).click();
            await page.getByRole("button", { name: "Enter annotation mode", exact: true }).click();
            await page.locator("h1").click();
            await page.locator("textarea").fill("Make the title smaller");
            const delivered = page.waitForResponse(
                (response) =>
                    response.url().endsWith("/remote") && response.request().method() === "POST",
            );
            await page.locator("[data-annotation-submit]").click();
            await delivered;
            assert.equal(posts.length, 1);
            assert.equal(posts[0].channel, "design", "The saved field reaches the transport");
            assert.deepEqual(posts[0].metadata, { session: "s-1", tag: "H1", pathname: "/" });
            assert.equal(posts[0].threadId, undefined);
            // Recheck immediately before sending, even if settings previously passed.
            enabled = false;
            await page.locator("h1").click({ position: { x: 10, y: 10 } });
            await page.locator("textarea").fill("Blocked when Remote becomes unavailable");
            await page.locator("[data-annotation-submit]").click();
            await page.getByRole("button", { name: "Edit annotation 2", exact: true }).click();
            await page.getByRole("alert").filter({ hasText: "Enable Remote first." }).waitFor();
            assert.equal(posts.length, 1);
            await page.getByRole("button", { name: "Retry delivery", exact: true }).click();
            await page.getByRole("button", { name: "Retry delivery", exact: true }).waitFor();
            assert.equal(posts.length, 1);
        } else {
            const reason =
                scenario === "unavailable" ? "Enable Remote first." : "Cannot reach Remote.";
            await page.getByText(reason, { exact: true }).waitFor();
            assert.equal(await option.evaluate((element) => element.disabled), true, scenario);
            assert.equal(posts.length, 0);
        }
        await page.close();
    }
    console.log(
        "Transport: default mode, availability, unavailable and failing checks, settings field, metadata, and submission rechecks passed",
    );
} finally {
    await browser.close();
}
