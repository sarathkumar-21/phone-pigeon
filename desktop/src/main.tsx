import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./styles.css";
import { installMock } from "./lib/mock";

// A plain browser (design preview) has no Tauri runtime: use sample data.
if (!("__TAURI_INTERNALS__" in window)) installMock();

ReactDOM.createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
