import { afterEach, describe, expect, it, vi } from "vitest";
import { bootstrap } from "./bootstrap";
import type { AppId } from "./config";

export function referenceAppContract(appId: AppId) {
  describe(`${appId} startup`, () => {
    let dispose: (() => void) | undefined;
    afterEach(() => {
      dispose?.();
      dispose = undefined;
      vi.unstubAllGlobals();
      document.body.innerHTML = "";
    });
    it("loads its fixed configuration before fetching API and renders environment and release", async () => {
      document.body.innerHTML = '<div id="root"></div>';
      const fetcher = vi
        .fn()
        .mockResolvedValueOnce(
          new Response(
            JSON.stringify({
              schemaVersion: 1,
              appId,
              environment: "prod",
              version: "candidate-1",
              apiBaseUrl: "/api",
            }),
          ),
        )
        .mockResolvedValueOnce(
          new Response(
            JSON.stringify({
              project: "Omega",
              environment: "prod",
              version: "candidate-1",
              status: "ok",
            }),
          ),
        );
      vi.stubGlobal("fetch", fetcher);
      dispose = await bootstrap(appId);
      await vi.waitFor(() =>
        expect(document.body.textContent).toContain("接口状态：ok"),
      );
      expect(fetcher.mock.calls.map((call) => call[0])).toEqual([
        `/${appId}/runtime-config.json`,
        "/api/v1/ping",
      ]);
      expect(document.body.textContent).toContain("candidate-1");
      expect(document.body.textContent).toContain("prod");
    });
    it.each(["{}", "not json", '{"password":"never-display-this"}'])(
      "shows explicit failure and never contacts API for bad configuration",
      async (text) => {
        document.body.innerHTML = '<div id="root"></div>';
        const fetcher = vi.fn().mockResolvedValue(new Response(text));
        vi.stubGlobal("fetch", fetcher);
        dispose = await bootstrap(appId);
        expect(document.querySelector('[role="alert"]')?.textContent).toContain(
          "应用无法启动",
        );
        expect(document.body.textContent).not.toContain("never-display-this");
        expect(fetcher).toHaveBeenCalledTimes(1);
      },
    );
    it("shows explicit failure when public configuration is unavailable", async () => {
      document.body.innerHTML = '<div id="root"></div>';
      vi.stubGlobal(
        "fetch",
        vi.fn().mockResolvedValue(new Response("", { status: 404 })),
      );
      dispose = await bootstrap(appId);
      expect(document.querySelector('[role="alert"]')).not.toBeNull();
    });
  });
}
