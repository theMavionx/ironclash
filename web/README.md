# Web Build & UI

Browser delivery of Ironclash: the Godot game runs as a WebAssembly canvas,
React renders the surrounding UI, and a small JS↔GDScript bridge keeps the
two in sync.

## Layout

```
web/
├── godot-export/   ← Godot's HTML5 export target (.html .js .wasm .pck)
└── ui/             ← React + Vite project that hosts the canvas + overlay UI
```

Plus, in the engine project:

```
src/gameplay/web/web_bridge.gd   ← Autoloaded singleton, talks JavaScript via JavaScriptBridge
```

## End-to-end first run

1. **One-time** — in Godot Editor:
   - `Project → Export → Add… → Web` with **Export Path** = `web/godot-export/index.html`.
   - `Editor → Manage Export Templates` → install if missing.
   - Click **Export Project**.
2. **One-time** — install JS deps:
   ```bash
   cd web/ui
   npm install
   ```
3. **Every iteration**:
   ```bash
   # In one terminal: serve React + the latest Godot export
   cd web/ui && npm run dev
   # In Godot: re-export to web/godot-export/ whenever GDScript / scenes change.
   # The Vite middleware serves the new files immediately — just refresh the tab.
   ```

## Bridge contract

`WebBridge` (Godot autoload) exposes:

| Direction          | API                                                              |
| ------------------ | ---------------------------------------------------------------- |
| Godot → React      | `WebBridge.send_event(name, payload_dict)`                       |
| React → Godot      | `WebBridge.register_handler(name, callable)` (gameplay-side)     |
| React subscribes   | `useGodotEvent("name", payload => …)` or `godotBridge.subscribe` |
| React dispatches   | `emitToGodot("name", { … })` or `godotBridge.emit`               |

Event names + payload shapes live in `web/ui/src/bridge/eventTypes.ts`.
Mirror any addition there with the matching GDScript call so the wire stays
typed end-to-end.

## Production build (later)

```bash
cd web/ui && npm run build       # → web/ui/dist/
```

Serve `web/ui/dist/` plus `web/godot-export/` together from any static host
that can return the COOP/COEP headers Godot's WASM needs:

```
Cross-Origin-Embedder-Policy: require-corp
Cross-Origin-Opener-Policy:  same-origin
```
