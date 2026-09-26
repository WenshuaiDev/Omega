import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import type { RuntimeConfig } from "./config";

interface Ping {
  project: string;
  environment: string;
  version: string;
  status: string;
}
function App({ config }: { config: RuntimeConfig }) {
  const [ping, setPing] = useState<Ping>();
  const [error, setError] = useState(false);
  useEffect(() => {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);
    void fetch(`${config.apiBaseUrl}/v1/ping`, {
      signal: controller.signal,
      cache: "no-store",
    })
      .then(async (response) => {
        if (!response.ok) throw new Error("API unavailable");
        const value: unknown = await response.json();
        if (
          !value ||
          typeof value !== "object" ||
          !["project", "environment", "version", "status"].every(
            (key) =>
              typeof (value as Record<string, unknown>)[key] === "string",
          )
        ) {
          throw new Error("Invalid API response");
        }
        setPing(value as Ping);
      })
      .catch(() => setError(true))
      .finally(() => clearTimeout(timeout));
    return () => {
      clearTimeout(timeout);
      controller.abort();
    };
  }, [config]);
  return (
    <main>
      <header>
        <span className="eyebrow">OMEGA / 工程基座</span>
        <nav aria-label="参考应用">
          <a href="/web/">Web</a>
          <a href="/console/">Console</a>
        </nav>
      </header>
      <section>
        <p className="eyebrow">REFERENCE APPLICATION</p>
        <h1>{config.appId === "web" ? "Web 参考应用" : "Console 参考应用"}</h1>
        <p>统一入口、运行时配置与应用接口的最小验证。</p>
      </section>
      <dl>
        <div>
          <dt>项目</dt>
          <dd>Omega</dd>
        </div>
        <div>
          <dt>应用</dt>
          <dd>{config.appId}</dd>
        </div>
        <div>
          <dt>环境</dt>
          <dd>{config.environment}</dd>
        </div>
        <div>
          <dt>发布版本</dt>
          <dd>{config.version}</dd>
        </div>
      </dl>
      <section className="connection" aria-live="polite">
        <h2>接口连接</h2>
        <p>
          {error
            ? "接口不可用，请稍后刷新重试。"
            : ping
              ? `接口状态：${ping.status}`
              : "正在连接接口…"}
        </p>
        {ping && (
          <dl>
            <div>
              <dt>服务项目</dt>
              <dd>{ping.project}</dd>
            </div>
            <div>
              <dt>服务环境</dt>
              <dd>{ping.environment}</dd>
            </div>
            <div>
              <dt>服务版本</dt>
              <dd>{ping.version}</dd>
            </div>
          </dl>
        )}
      </section>
      <footer>
        当前路径：{window.location.pathname} ·{" "}
        <a href={`/${config.appId}/status/details`}>深层路由示例</a>
      </footer>
    </main>
  );
}
export function mount(element: HTMLElement, config: RuntimeConfig): () => void {
  element.removeAttribute("role");
  const root = createRoot(element);
  root.render(<App config={config} />);
  return () => root.unmount();
}
