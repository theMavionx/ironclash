import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "node:path";
import fs from "node:fs";
import crypto from "node:crypto";

// During dev we serve the Godot export sitting in ../godot-export/ at the
// virtual URL /godot/* — that way Godot writes once and React picks up
// without a copy step. SharedArrayBuffer needs the cross-origin isolation
// headers on every request (Godot's WASM threads will fail to start otherwise).
// `credentialless` keeps the page isolated like `require-corp`, but it allows
// no-cors third-party scripts such as the Vibe Jam widget to load without
// cookies instead of being blocked by COEP.
const GODOT_EXPORT_DIR: string = path.resolve(__dirname, "..", "godot-export");
const COOP_COEP_HEADERS: Record<string, string> = {
	"Cross-Origin-Embedder-Policy": "credentialless",
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

function getGodotExportFiles(): string[] {
	if (!fs.existsSync(GODOT_EXPORT_DIR)) return [];
	return fs
		.readdirSync(GODOT_EXPORT_DIR)
		.filter((fileName) => {
			const filePath: string = path.join(GODOT_EXPORT_DIR, fileName);
			return fs.statSync(filePath).isFile() && !/\.(br|gz)$/i.test(fileName);
		})
		.sort();
}

function getGodotExportVersion(files: string[]): string | null {
	if (files.length === 0) return null;
	const hash = crypto.createHash("sha256");
	for (const fileName of files) {
		const filePath: string = path.join(GODOT_EXPORT_DIR, fileName);
		const stat = fs.statSync(filePath);
		hash.update(`${fileName}:${stat.size}:${Math.floor(stat.mtimeMs)}\n`);
	}
	return hash.digest("hex").slice(0, 16);
}

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
						res.setHeader("Cache-Control", "public, max-age=0, must-revalidate");
						let base: string | null = null;
						let godotConfig: Record<string, unknown> | null = null;
						const files: string[] = getGodotExportFiles();
						const version: string | null = getGodotExportVersion(files);
						if (files.length > 0) {
							const pck: string | undefined = files.find((f) =>
								f.toLowerCase().endsWith(".pck"),
							);
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
						res.end(JSON.stringify({ base, files, godotConfig, version }));
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
					res.setHeader("Cache-Control", "public, max-age=31536000, immutable");
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
