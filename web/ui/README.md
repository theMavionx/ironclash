# Ironclash UI (React)

Browser UI overlay that wraps the Godot 4.3 web build. The canvas is rendered
by the Godot engine; React layers HUD / menus / toasts on top and exchanges
events with GDScript through `window.GodotBridge`.

## Stack

- **Vite 6** — dev server with COOP/COEP headers required by Godot's WASM
  threads, plus a tiny middleware that serves `../godot-export/*` at `/godot/*`
  so a fresh Godot export shows up live.
- **React 19** + **TypeScript 5**
- **Tailwind 3** — utility CSS, palette stub in `tailwind.config.js`.

## Scripts

| Command         | Purpose                                                 |
| --------------- | ------------------------------------------------------- |
| `npm run dev`   | Dev server at <http://localhost:5173>                   |
| `npm run build` | Type-check + production build into `dist/`              |
| `npm run preview` | Serve the built bundle locally to smoke-test         |
| `npm run lint`  | ESLint pass over `src/`                                 |

## First run

```bash
cd web/ui
npm install
npm run dev
```

The dev server will warn `Failed to load game` until you run a Godot Web
export into `../godot-export/`. See `../godot-export/README.md` for the
one-time editor setup.

## Bridge cheatsheet

GDScript → React:

```gdscript
WebBridge.send_event("health_changed", {"hp": 27, "max": 100})
```

React → GDScript:

```tsx
import { emitToGodot } from "@/hooks/useGodotEvent";
emitToGodot("ui_pause", { reason: "menu_open" });

// or subscribe to game events:
useGodotEvent<HealthChangedPayload>("health_changed", (p) => setHp(p));
```

Add new event names to `src/bridge/eventTypes.ts` so both sides typecheck.

## Layout

```
src/
  bridge/
    godotBridge.ts     — installs window.GodotBridge, pub/sub
    eventTypes.ts      — typed event names + payload shapes
  hooks/
    useGodotEvent.ts   — React subscribe/emit
  components/
    GameCanvas.tsx     — mounts <canvas>, boots Godot engine, shows progress
    HUD.tsx            — sample overlay (HP + ammo) wired to bridge events
  App.tsx              — composes canvas + overlay layer
  main.tsx             — React root
  index.css            — Tailwind directives + canvas tweaks
```
