import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";
import fs from "node:fs";

// During dev we serve the Godot export sitting in ../godot-export/ at the
// virtual URL /godot/* — that way Godot writes once and React picks up
// without a copy step. SharedArrayBuffer needs the cross-origin isolation
// headers on every request (Godot's WASM threads will fail to start otherwise).
const GODOT_EXPORT_DIR: string = path.resolve(__dirname, "..", "godot-export");
const COOP_COEP_HEADERS: Record<string, string> = {
	"Cross-Origin-Embedder-Policy": "require-corp",
	"Cross-Origin-Opener-Policy": "same-origin",
	"Cross-Origin-Resource-Policy": "cross-origin",
};

const CONTENT_TYPES: Record<string, string> = {
	".html": "text/html; charset=utf-8",
	".js": "application/javascript; charset=utf-8",
	".wasm": "application/wasm",
	".pck": "application/octet-stream",
	".png": "image/png",
};

export default defineConfig({
	plugins: [
		react(),
		{
			name: "serve-godot-export",
			configureServer(server) {
				server.middlewares.use("/godot", (req, res, _next) => {
					const requested: string = (req.url ?? "/").split("?")[0];
					const safe: string = requested.replace(/\.\.+/g, "");

					// Synthetic manifest endpoint — React calls this first to discover
					// what Godot exported. We parse the GODOT_CONFIG block out of the
					// auto-generated <Project>.html so we inherit everything Godot
					// decided (gdextensionLibs, canvasResizePolicy, fileSizes, etc.)
					// without hardcoding any addon names.
					if (safe === "/_manifest.json") {
						res.setHeader("Content-Type", "application/json; charset=utf-8");
						res.setHeader("Cache-Control", "no-store");
						let base: string | null = null;
						let godotConfig: Record<string, unknown> | null = null;
						if (fs.existsSync(GODOT_EXPORT_DIR)) {
							const pck: string | undefined = fs
								.readdirSync(GODOT_EXPORT_DIR)
								.find((f) => f.toLowerCase().endsWith(".pck"));
							if (pck !== undefined) {
								base = pck.slice(0, -".pck".length);
								const htmlPath: string = path.join(GODOT_EXPORT_DIR, `${base}.html`);
								if (fs.existsSync(htmlPath)) {
									const html: string = fs.readFileSync(htmlPath, "utf-8");
									// Match: const GODOT_CONFIG = {...};   (single-line, JSON-shaped)
									const match: RegExpExecArray | null = /const\s+GODOT_CONFIG\s*=\s*(\{[^;]*?\})\s*;/m.exec(
										html,
									);
									if (match !== null) {
										try {
											godotConfig = JSON.parse(match[1]) as Record<string, unknown>;
										} catch (err: unknown) {
											console.warn("[vite] Failed to parse GODOT_CONFIG:", err);
										}
									}
								}
							}
						}
						res.end(JSON.stringify({ base, godotConfig }));
						return;
					}

					const filePath: string = path.join(GODOT_EXPORT_DIR, safe);
					if (!fs.existsSync(filePath) || !fs.statSync(filePath).isFile()) {
						// Honest 404 — falling through to Vite's SPA fallback would
						// return index.html, which a <script> tag loads as 200 OK
						// then explodes on the first '<' as a SyntaxError.
						res.statusCode = 404;
						res.setHeader("Content-Type", "text/plain; charset=utf-8");
						res.end(
							`Godot export not found at web/godot-export${safe}.\n` +
								`Run a Godot Web export into web/godot-export/ and refresh.\n`,
						);
						return;
					}
					const ext: string = path.extname(filePath).toLowerCase();
					res.setHeader(
						"Content-Type",
						CONTENT_TYPES[ext] ?? "application/octet-stream",
					);
					for (const [k, v] of Object.entries(COOP_COEP_HEADERS)) {
						res.setHeader(k, v);
					}
					fs.createReadStream(filePath).pipe(res);
				});
			},
		},
	],
	server: {
		headers: COOP_COEP_HEADERS,
		port: 5173,
		strictPort: false,
	},
	resolve: {
		alias: {
			"@": path.resolve(__dirname, "src"),
		},
	},
	build: {
		outDir: "dist",
		sourcemap: true,
	},
});
