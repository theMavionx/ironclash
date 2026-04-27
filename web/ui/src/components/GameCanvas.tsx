import { useEffect, useRef, useState } from "react";
import { godotBridge } from "@/bridge/godotBridge";

// Folder mounted by vite.config.ts where Godot's web export lives. The actual
// file basename (Godot uses config/name → "Ironclash4.3.*") is discovered at
// runtime via the synthetic /godot/_manifest.json endpoint, so we don't have
// to keep this file in lockstep with the project's name.
const GODOT_DIR: string = "/godot";

// Godot 4 web export exposes a global `Engine` constructor on window. The
// shape below covers the surface we actually call — extend as needed.
type GodotEngineCtor = new (config: GodotEngineConfig) => GodotEngine;

interface GodotEngineConfig {
	canvas?: HTMLCanvasElement;
	executable?: string;
	mainPack?: string;
	args?: string[];
	persistentDrops?: boolean;
	/** 0 = none, 1 = resize to canvas CSS size, 2 = resize to window. */
	canvasResizePolicy?: 0 | 1 | 2;
	/** Side-loaded GDExtension WASM files preloaded before the game starts. */
	gdextensionLibs?: string[];
	/** Override Module.locateFile — controls where the engine fetches every
	 *  side-loaded file (.wasm, .pck, GDExtension libs) from. */
	locateFile?: (path: string, prefix?: string) => string;
	ensureCrossOriginIsolationHeaders?: boolean;
	focusCanvas?: boolean;
	experimentalVK?: boolean;
	fileSizes?: Record<string, number>;
	serviceWorker?: string;
	onProgress?: (current: number, total: number) => void;
	onPrint?: (...args: unknown[]) => void;
	onPrintError?: (...args: unknown[]) => void;
	onExit?: (code: number) => void;
}

interface GodotManifest {
	base: string | null;
	godotConfig: GodotEngineConfig | null;
}

interface GodotEngine {
	startGame: (overrides?: Partial<GodotEngineConfig>) => Promise<void>;
	requestQuit?: () => void;
}

declare global {
	interface Window {
		Engine?: GodotEngineCtor;
	}
}

export default function GameCanvas() {
	const canvasRef = useRef<HTMLCanvasElement | null>(null);
	const engineRef = useRef<GodotEngine | null>(null);
	// Hard guard: Godot's web engine cannot be torn down + re-instantiated in
	// the same page lifetime. If React (HMR, future StrictMode, etc.) re-runs
	// our effect we MUST refuse to boot a second time or the page enters a
	// "RID allocations leaked at exit" loop.
	const bootedRef = useRef<boolean>(false);
	const [progress, setProgress] = useState<{ current: number; total: number }>({
		current: 0,
		total: 0,
	});
	const [error, setError] = useState<string | null>(null);

	useEffect(() => {
		if (bootedRef.current) return;
		bootedRef.current = true;
		const canvas = canvasRef.current;
		if (!canvas) return;

		let cancelled: boolean = false;
		let scriptEl: HTMLScriptElement | null = null;

		const boot = async (): Promise<void> => {
			try {
				await clearGodotWebExportCaches();
				if (cancelled) return;
				const manifest: GodotManifest = await fetchManifest();
				if (cancelled) return;
				if (manifest.base === null || manifest.base.length === 0) {
					throw new Error(
						"No .pck file found in web/godot-export/. Run a Godot Web export and refresh.",
					);
				}
				const base: string = `${GODOT_DIR}/${manifest.base}`;
				await loadScriptOnce(`${base}.js`).then((el) => {
					scriptEl = el;
				});
				if (cancelled) return;
				if (window.Engine === undefined) {
					throw new Error(
						`Godot Engine global missing after loading ${base}.js. Was the file actually a Godot 4 web export?`,
					);
				}
				// Inherit everything Godot's auto-generated HTML put in GODOT_CONFIG
				// (gdextensionLibs is the critical one — without it the engine will
				// fail to dlopen addons like terrain_3d). Then override paths with
				// our /godot/ URL prefix and switch resize-policy to canvas-CSS.
				//
				// IMPORTANT: gdextensionLibs entries MUST stay as basenames (no path
				// prefix). Reason: Emscripten registers each loaded .wasm in its
				// LDSO table keyed by the exact string passed; Godot's web platform
				// then calls dlopen(basename(extension_path)). If we prefix with
				// "/godot/", the registration key won't match what dlopen requests
				// → "file not found". The engine resolves these basenames against
				// `executable`'s directory automatically when fetching.
				const fromGodot: GodotEngineConfig = manifest.godotConfig ?? {};
				const gdextensionLibs: string[] = fromGodot.gdextensionLibs ?? [];
				const engine = new window.Engine({
					...fromGodot,
					canvas,
					executable: base,
					mainPack: `${base}.pck`,
					gdextensionLibs,
					// canvasResizePolicy values per Godot 4.3 source:
					//   0 = no resize (use canvas.width/height as-is)
					//   1 = use project's viewport_width/height (1280x720 default → letterboxed!)
					//   2 = fill window (sets canvas.style position=absolute, top/left=0,
					//       width/height = window.inner*). This is the default and the only
					//       value that actually fills the browser window.
					// React's HUD overlay sits in a sibling div with pointer-events-none and
					// z-order above the canvas, so making the canvas absolute doesn't break it.
					canvasResizePolicy: 2,
					// React already serves the page with COOP/COEP headers via Vite —
					// disable the engine's own service-worker fallback that tries to
					// inject them and reloads the tab.
					ensureCrossOriginIsolationHeaders: false,
					serviceWorker: undefined,
					onProgress: (current, total) => {
						if (!cancelled) setProgress({ current, total });
					},
					onPrintError: (...args) => console.error("[Godot]", ...args),
				});
				// The engine's hardcoded Config.prototype.getModuleConfig builds an
				// internal `locateFile` that returns relative basenames as-is, so
				// the browser resolves them against the React page URL ('/') and
				// 404s on every GDExtension WASM. Wrap getModuleConfig to rewrite
				// any relative path under /godot/ before Emscripten fetches it.
				patchEngineLocateFile(engine);
				engineRef.current = engine;
				await engine.startGame();
				// Wait for the GDScript autoload to install the bridge so the
				// menu overlay can dispatch ui_play once the user clicks PLAY.
				// Bounded so a silent autoload failure surfaces an error.
				const ready: Promise<void> = godotBridge.waitForReady();
				const timeout: Promise<never> = new Promise((_, reject) =>
					setTimeout(() => reject(new Error("Godot autoload didn't signal ready in 15s")), 15000),
				);
				await Promise.race([ready, timeout]);
				if (cancelled) return;
				// `ui_play` is emitted by MenuOverlay's PLAY button now —
				// Godot's main_menu.tscn waits on it before swapping to the
				// gameplay scene.
			} catch (err: unknown) {
				if (cancelled) return;
				console.error("[GameCanvas] boot failed:", err);
				setError(err instanceof Error ? err.message : String(err));
			}
		};

		void boot();

		return () => {
			cancelled = true;
			engineRef.current?.requestQuit?.();
			engineRef.current = null;
			// Leave the script tag in place — Godot's engine module is not designed
			// to be re-instantiated cleanly within the same page lifetime, so on
			// unmount we just stop the running instance and let HMR reload the page.
			if (scriptEl !== null) {
				// Intentional no-op; held only for the closure capture above.
			}
		};
	}, []);

	const pct: number =
		progress.total > 0 ? Math.round((progress.current / progress.total) * 100) : 0;

	return (
		<div className="absolute inset-0">
			<canvas
				ref={canvasRef}
				// Godot's engine.js internally calls document.querySelector('#'+canvas.id)
				// for some bookkeeping — without an id the selector becomes '#' and
				// throws SyntaxError before the game even boots.
				id="godot-canvas"
				tabIndex={0}
				className="block h-full w-full"
				// Godot writes its own width/height every frame; defaults keep the
				// initial paint sane before the engine takes over.
				width={1280}
				height={720}
			/>
			{progress.total > 0 && progress.current < progress.total && (
				<div className="pointer-events-none absolute inset-0 flex items-center justify-center bg-bg font-sans text-label uppercase tracking-label text-text-muted">
					Loading {pct}%
				</div>
			)}
			{error !== null && (
				<div className="pointer-events-auto absolute inset-0 flex items-center justify-center bg-red-950/80 p-8 text-center font-mono text-sm text-white">
					<div>
						<div className="mb-2 text-base font-bold">Failed to load game</div>
						<div className="opacity-80">{error}</div>
						<div className="mt-4 text-xs opacity-60">
							Run a Godot Web export into <code>web/godot-export/</code>, then refresh.
						</div>
					</div>
				</div>
			)}
		</div>
	);
}

/** Wrap the engine's internal getModuleConfig() to override the locateFile it
 *  hands to Emscripten. The stock impl returns gdextension basenames as-is,
 *  which the browser then resolves against the React page URL — wrong base.
 *  We force every relative path under GODOT_DIR. */
interface PatchableEngine {
	config?: {
		getModuleConfig?: (loadPath: string, response: unknown) => {
			locateFile?: (path: string) => string;
		} & Record<string, unknown>;
	};
}

function patchEngineLocateFile(engine: GodotEngine): void {
	const e = engine as unknown as PatchableEngine;
	const cfg = e.config;
	if (cfg === undefined || typeof cfg.getModuleConfig !== "function") {
		console.warn("[GameCanvas] engine.config.getModuleConfig missing — locateFile patch skipped");
		return;
	}
	const original = cfg.getModuleConfig.bind(cfg);
	cfg.getModuleConfig = function patched(loadPath: string, response: unknown) {
		const moduleCfg = original(loadPath, response);
		const stockLocate = moduleCfg.locateFile;
		moduleCfg.locateFile = (path: string): string => {
			const resolved: string =
				typeof stockLocate === "function" ? stockLocate(path) : path;
			if (resolved.startsWith("/") || /^https?:/i.test(resolved)) {
				return resolved;
			}
			return `${GODOT_DIR}/${resolved}`;
		};
		return moduleCfg;
	};
}

/** Hit the synthetic manifest endpoint that vite.config.ts serves to discover
 *  the actual base name of the Godot export (Godot uses config/name → e.g.
 *  "Ironclash4.3.pck", not "index.pck") plus the full GODOT_CONFIG block
 *  parsed out of the auto-generated <Project>.html — critical because that's
 *  where `gdextensionLibs` lives and the engine refuses to load addons
 *  like terrain_3d without it. */
async function fetchManifest(): Promise<GodotManifest> {
	const res = await fetch(`${GODOT_DIR}/_manifest.json`, { cache: "no-store" });
	if (!res.ok) {
		throw new Error(`Manifest fetch failed (${res.status})`);
	}
	return (await res.json()) as GodotManifest;
}

async function clearGodotWebExportCaches(): Promise<void> {
	if ("serviceWorker" in navigator) {
		const registrations = await navigator.serviceWorker.getRegistrations();
		await Promise.all(
			registrations
				.filter((registration) => {
					const scriptURL =
						registration.active?.scriptURL ??
						registration.waiting?.scriptURL ??
						registration.installing?.scriptURL ??
						"";
					return /Ironclash|\/godot\//i.test(scriptURL);
				})
				.map((registration) => registration.unregister()),
		);
	}

	if ("caches" in window) {
		const keys = await caches.keys();
		await Promise.all(
			keys
				.filter((key) => /Ironclash|godot/i.test(key))
				.map((key) => caches.delete(key)),
		);
	}
}

const _scriptCache: Map<string, Promise<HTMLScriptElement>> = new Map();

/** Inject a <script> tag once; subsequent calls return the same Promise. */
function loadScriptOnce(src: string): Promise<HTMLScriptElement> {
	const cached = _scriptCache.get(src);
	if (cached !== undefined) return cached;
	const promise = new Promise<HTMLScriptElement>((resolve, reject) => {
		const el = document.createElement("script");
		el.src = src;
		el.async = true;
		el.onload = () => resolve(el);
		el.onerror = () => reject(new Error(`Failed to load script: ${src}`));
		document.body.appendChild(el);
	});
	_scriptCache.set(src, promise);
	return promise;
}
