import { parseConfig } from "./config";
import type { AppId } from "./config";

export async function bootstrap(
  appId: AppId,
): Promise<(() => void) | undefined> {
  const element = document.getElementById("root");
  if (!element) throw new Error("缺少应用挂载点");
  try {
    const response = await fetch(`/${appId}/runtime-config.json`, {
      cache: "no-store",
      signal: AbortSignal.timeout(10000),
    });
    if (!response.ok) throw new Error("公开配置加载失败");
    const config = parseConfig(await response.text(), appId);
    // Neither React nor the request client is initialized before configuration validation.
    const { mount } = await import("./mount");
    return mount(element, config);
  } catch {
    element.setAttribute("role", "alert");
    element.textContent =
      "应用无法启动：公开配置加载或校验失败。请检查部署配置后刷新页面。";
    return undefined;
  }
}
