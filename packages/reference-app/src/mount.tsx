import { createRoot } from "react-dom/client";
import { App } from "./App";
import type { RuntimeConfig } from "./config";

export function mount(element: HTMLElement, config: RuntimeConfig): () => void {
  element.removeAttribute("role");
  const root = createRoot(element);
  root.render(<App config={config} />);
  return () => root.unmount();
}
