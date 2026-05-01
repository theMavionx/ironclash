# Godot Web Export Output

This folder is the **target** for Godot's HTML5 export. Configure once in the
Godot Editor, then export here every time you want a new build.

## One-time setup (in Godot Editor)

1. **Project → Export** → click **Add...** → **Web**.
2. **Export Path**: `web/godot-export/index.html` (relative to the project root).
3. **Options → HTML → Export Type**: keep `Regular`. Threads: optional (only
   matters if you use Web Workers).
4. **Save** the preset. The first build also requires:
   - **Editor → Manage Export Templates** → Download the matching version.

## Exporting

In the editor's **Export** dialog:

- Select the **Web** preset.
- Click **Export Project** (uncheck *Export With Debug* for release builds).
- Wait — Godot writes `index.html`, `<name>.js`, `<name>.wasm`, `<name>.pck`,
  and a `<name>.audio.worklet.js` here.

The React project at `../ui/` is wired to **serve these files at `/godot/`**
during development (Vite proxies them). After every Godot export, restart
`npm run dev` if it does not pick up the new files automatically.

## What goes here

The contents of this folder are **not committed** (see root `.gitignore`).
Only `.gitkeep` and this README are tracked, so the path stays valid for
contributors who clone the repo.

## Troubleshooting

- **CORS / SharedArrayBuffer errors**: Vite is configured with COOP/COEP
  headers in `web/ui/vite.config.ts` so the WASM threads can run. If you
  serve the build elsewhere, replicate those headers. The current COEP value
  is `credentialless` so third-party no-cors scripts can load without breaking
  cross-origin isolation.
- **Missing `index.pck`**: re-export. The export name must match what
  `GameCanvas.tsx` expects (default: `index`).
