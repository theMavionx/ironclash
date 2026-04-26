import ReactDOM from "react-dom/client";
import App from "@/App";
import "@/index.css";
// Side-effect import: registers the global window.GodotBridge so the engine
// can attach to it during boot, regardless of which component mounts first.
import "@/bridge/godotBridge";

const root = document.getElementById("root");
if (!root) {
	throw new Error("Root element #root missing in index.html");
}
// NB: NOT wrapped in <React.StrictMode>. StrictMode dev-mode double-mounts
// every effect (mount → unmount → mount) to surface cleanup bugs; Godot's web
// engine cannot survive a tear-down + re-init within the same page lifetime
// (LDSO state, GL context, RIDs all leak) so the second mount produces hours
// of "RID allocations were leaked at exit" + a broken canvas.
ReactDOM.createRoot(root).render(<App />);
