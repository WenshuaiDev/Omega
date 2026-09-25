import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

const projectName: string = "Omega";
const root = document.getElementById("root");
if (!root) throw new Error("Missing application root");

createRoot(root).render(
  <StrictMode>
    <main>
      <h1>{projectName}</h1>
      <p>工程起点 · example-web</p>
    </main>
  </StrictMode>,
);
