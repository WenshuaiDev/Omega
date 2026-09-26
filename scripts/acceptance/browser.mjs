import { chromium } from "playwright-core";
import { readFile, writeFile, mkdir } from "node:fs/promises";
import { createRequire } from "node:module";
import { randomUUID, createHash } from "node:crypto";

const require = createRequire(import.meta.url);
const evidence = "/evidence";
const base = "http://127.0.0.1:8080";
const sourceFile = "/fixtures/App.tsx";
const cases = [];
const events = [];
const original = new Map();
const contexts = [];
let browser;
let activeCase = "browser-launch";
const hash = (value) => createHash("sha256").update(value).digest("hex");
function assert(value, message) {
  if (!value) throw new Error(message);
}
function publicURL(value) {
  const url = new URL(value);
  url.search = "";
  return url.toString();
}
function record(name, detail) {
  cases.push({
    case: name,
    status: "PASS",
    finished_at: new Date().toISOString(),
    detail,
  });
}
async function waitFor(fn, message) {
  const end = Date.now() + 15000;
  while (Date.now() < end) {
    if (await fn()) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error(message);
}
async function pageFor(app) {
  const context = await browser.newContext();
  contexts.push(context);
  await context.tracing.start({
    screenshots: true,
    snapshots: true,
    sources: false,
  });
  const page = await context.newPage();
  const observation = {
    app,
    page,
    context,
    requests: [],
    sockets: [],
    frames: [],
    navigations: 0,
    errors: [],
  };
  page.on("request", (request) =>
    observation.requests.push(publicURL(request.url())),
  );
  page.on("websocket", (socket) => {
    observation.sockets.push(publicURL(socket.url()));
    socket.on("framereceived", (frame) => {
      const payload = String(frame.payload);
      observation.frames.push(payload);
    });
  });
  page.on("framenavigated", (frame) => {
    if (frame === page.mainFrame()) observation.navigations++;
  });
  page.on("pageerror", (error) => observation.errors.push(error.message));
  page.on("console", (message) => {
    if (message.type() === "error") observation.errors.push(message.text());
  });
  return observation;
}
async function healthy(observation) {
  const { app, page } = observation;
  await page.goto(`${base}/${app}/`, {
    waitUntil: "domcontentloaded",
    timeout: 20000,
  });
  await page
    .getByRole("heading", {
      name: app === "web" ? "Web 参考应用" : "Console 参考应用",
      exact: true,
    })
    .waitFor();
  await page.getByText("接口状态：ok", { exact: true }).waitFor();
}
async function saveObservation(observation, name) {
  const { page, context, ...data } = observation;
  await page.screenshot({ path: `${evidence}/${name}.png`, fullPage: true });
  await writeFile(
    `${evidence}/${name}.json`,
    JSON.stringify({ ...data, url: page.url() }, null, 2),
  );
  events.push({ evidence: name, app: data.app });
}

await mkdir(evidence, { recursive: true });
try {
  for (const file of [
    sourceFile,
    "/fixtures/web.json",
    "/fixtures/console.json",
  ]) {
    original.set(file, await readFile(file));
  }
  browser = await chromium.launch({ headless: true });
  await writeFile(
    `${evidence}/browser-version.json`,
    JSON.stringify(
      {
        playwright: require("playwright-core/package.json").version,
        chromium: browser.version(),
        node: process.version,
        platform: process.platform,
        arch: process.arch,
      },
      null,
      2,
    ),
  );
  const observations = [];
  for (const app of ["web", "console"]) {
    activeCase = `${app}-healthy`;
    const observation = await pageFor(app);
    observations.push(observation);
    await healthy(observation);
    await saveObservation(observation, `${app}-initial`);
    record(
      activeCase,
      "Actual React UI and DB-backed API status rendered through Nginx.",
    );
  }
  activeCase = "both-apps-hmr";
  const anchor = "统一入口、运行时配置与应用接口的最小验证。";
  const source = original.get(sourceFile).toString();
  assert(
    source.split(anchor).length === 2,
    "HMR source anchor must occur exactly once",
  );
  const marker = `OMEGA-04-${randomUUID()}`;
  const sentinel = randomUUID();
  for (const observation of observations) {
    await waitFor(
      () =>
        observation.sockets.some(
          (url) => new URL(url).pathname === `/${observation.app}/hmr`,
        ),
      "HMR socket did not connect via Nginx",
    );
    assert(
      observation.sockets.every(
        (url) => new URL(url).host === new URL(base).host,
      ),
      "HMR bypassed the edge origin",
    );
    await observation.page.evaluate((value) => {
      window.__omegaAcceptanceDocument = value;
    }, sentinel);
    observation.navigations = 0;
    observation.frames = [];
  }
  await writeFile(sourceFile, source.replace(anchor, marker));
  for (const observation of observations) {
    await observation.page
      .getByText(marker, { exact: true })
      .waitFor({ timeout: 20000 });
    assert(
      (await observation.page.evaluate(
        () => window.__omegaAcceptanceDocument,
      )) === sentinel,
      "HMR replaced the document",
    );
    assert(
      observation.navigations === 0,
      "HMR unexpectedly navigated/reloaded the page",
    );
    assert(
      observation.frames.some((frame) => frame.includes('"type":"update"')),
      "No real HMR update frame was observed",
    );
    await saveObservation(observation, `${observation.app}-hmr`);
  }
  await writeFile(sourceFile, original.get(sourceFile));
  for (const observation of observations) {
    await observation.page
      .getByText(anchor, { exact: true })
      .waitFor({ timeout: 20000 });
    assert(
      observation.navigations === 0,
      "Restoring HMR source reloaded the page",
    );
  }
  record(
    activeCase,
    "Both visible DOMs updated through edge WebSockets; document sentinels retained and navigation counts zero.",
  );
  for (const observation of observations) {
    const { app, page } = observation;
    activeCase = `${app}-deep-route`;
    await page.getByRole("link", { name: "深层路由示例" }).click();
    await page.waitForURL(`${base}/${app}/status/details`);
    await page.reload({ waitUntil: "domcontentloaded" });
    await page.getByText("接口状态：ok", { exact: true }).waitFor();
    assert(
      new URL(page.url()).pathname === `/${app}/status/details`,
      "deep route was lost on reload",
    );
    assert(observation.errors.length === 0, "healthy browser emitted an error");
    await saveObservation(observation, `${app}-deep-route`);
    record(
      activeCase,
      "Visible link navigation and explicit deep-route reload rendered app/API successfully.",
    );
    for (const fault of ["wrong-app", "malformed-json"]) {
      activeCase = `${app}-config-${fault}`;
      const file = `/fixtures/${app}.json`;
      const value = JSON.parse(original.get(file).toString());
      value.appId = app === "web" ? "console" : "web";
      await writeFile(
        file,
        fault === "wrong-app" ? JSON.stringify(value) : "{invalid",
      );
      const rejected = await pageFor(app);
      await rejected.page.goto(`${base}/${app}/`, {
        waitUntil: "networkidle",
        timeout: 20000,
      });
      await rejected.page
        .getByRole("alert")
        .filter({ hasText: "公开配置加载或校验失败" })
        .waitFor();
      assert(
        rejected.requests.some(
          (url) => new URL(url).pathname === `/${app}/runtime-config.json`,
        ),
        "config was not requested",
      );
      assert(
        !rejected.requests.some((url) =>
          new URL(url).pathname.startsWith("/api/"),
        ),
        "bad config attempted an API fallback",
      );
      await saveObservation(rejected, `${app}-config-${fault}`);
      record(
        activeCase,
        "Explicit boot failure, actual invalid JSON response, and zero attempted API requests.",
      );
      await writeFile(file, original.get(file));
      const recovered = await pageFor(app);
      await healthy(recovered);
      await saveObservation(recovered, `${app}-recovered-${fault}`);
      record(
        `${app}-recovered-${fault}`,
        "Fresh page after exact config restoration renders APIok.",
      );
    }
  }
} catch (error) {
  cases.push({
    case: activeCase,
    status: "FAIL",
    finished_at: new Date().toISOString(),
    detail: error.message,
  });
  console.error(`Browser acceptance failed at ${activeCase}: ${error.message}`);
  process.exitCode = 1;
} finally {
  const restored = {};
  for (const [file, bytes] of original) {
    try {
      await writeFile(file, bytes);
      restored[file] = hash(await readFile(file)) === hash(bytes);
      if (!restored[file]) process.exitCode = 1;
    } catch (error) {
      restored[file] = false;
      process.exitCode = 1;
    }
  }
  for (let index = 0; index < contexts.length; index++) {
    const context = contexts[index];
    try {
      for (const [pageIndex, page] of context.pages().entries()) {
        await page.screenshot({
          path: `${evidence}/final-${index}-${pageIndex}.png`,
          fullPage: true,
        });
      }
      await context.tracing.stop({ path: `${evidence}/trace-${index}.zip` });
    } catch {
      /* Preserve the original failure even when a crashed browser cannot write a trace. */
    }
    await context.close().catch(() => {});
  }
  await browser?.close();
  await writeFile(
    `${evidence}/results.json`,
    JSON.stringify(
      {
        exit_code: process.exitCode ?? 0,
        cases,
        events,
        restored,
        entry_kind:
          "actual edge network namespace; host published ingress tested separately",
        native_platform_acceptance:
          "pending #20 unless a separate complete native run is recorded",
      },
      null,
      2,
    ),
  );
}
