import { useEffect, useRef, useState } from "react";
import { godotBridge } from "@/bridge/godotBridge";

// Folder mounted by vite.config.ts where Godot's web export lives. The actual
// file basename (Godot uses config/name → "Ironclash4.3.*") is discovered at
// runtime via the synthetic /godot/_manifest.json endpoint, so we don't have
// to keep this file in lockstep with the project's name.
const GODOT_DIR: string = "/godot";
let lastRunDependencyNoticeAt: number = 0;

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
	files?: string[];
	godotConfig: GodotEngineConfig | null;
	version?: string | null;
}

interface GodotEngine {
	startGame: (overrides?: Partial<GodotEngineConfig>) => Promise<void>;
	requestQuit?: () => void;
}

declare global {
	interface Window {
		Engine?: GodotEngineCtor;
	}
	interface Navigator {
		deviceMemory?: number;
	}
}

interface GameCanvasProps {
	/** Called for every Godot engine boot progress tick (current / total bytes
	 *  of the .pck + side .wasm). Lifted to App so the loading overlay outside
	 *  this component can render the bar without needing to peek into our state. */
	onProgress?: (current: number, total: number) => void;
	/** Fires once Godot's WebBridge autoload signals `godot_ready`. */
	onReady?: () => void;
	/** Fires if the boot pipeline throws (manifest 404, missing .pck, etc.). */
	onError?: (message: string) => void;
}

export default function GameCanvas({ onProgress, onReady, onError }: GameCanvasProps) {
	const canvasRef = useRef<HTMLCanvasElement | null>(null);
	const engineRef = useRef<GodotEngine | null>(null);
	// Hard guard: Godot's web engine cannot be torn down + re-instantiated in
	// the same page lifetime. If React (HMR, future StrictMode, etc.) re-runs
	// our effect we MUST refuse to boot a second time or the page enters a
	// "RID allocations leaked at exit" loop.
	const bootedRef = useRef<boolean>(false);
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
				logBrowserRenderDiagnostics();
				const manifest: GodotManifest = await fetchManifest();
				if (cancelled) return;
				if (manifest.base === null || manifest.base.length === 0) {
					throw new Error(
						"No .pck file found in web/godot-export/. Run a Godot Web export and refresh.",
					);
				}
				const base: string = `${GODOT_DIR}/${manifest.base}`;
				const cacheVersion: string | null = manifest.version ?? null;
				preloadGodotResources(manifest, base, cacheVersion);
				await loadScriptOnce(cacheBustGodotUrl(`${base}.js`, cacheVersion)).then((el) => {
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
					mainPack: cacheBustGodotUrl(`${base}.pck`, cacheVersion),
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
						if (cancelled) return;
						onProgress?.(current, total);
					},
					onPrintError: logGodotStderr,
				});
				// The engine's hardcoded Config.prototype.getModuleConfig builds an
				// internal `locateFile` that returns relative basenames as-is, so
				// the browser resolves them against the React page URL ('/') and
				// 404s on every GDExtension WASM. Wrap getModuleConfig to rewrite
				// any relative path under /godot/ before Emscripten fetches it.
				patchEngineLocateFile(engine, cacheVersion);
				engineRef.current = engine;
				await engine.startGame();
				// Wait for the GDScript autoload to install the bridge so React
				// can show PLAY and dispatch ui_play once the user clicks it.
				// Bounded so a silent autoload failure surfaces an error.
				const ready: Promise<void> = godotBridge.waitForReady();
				const timeout: Promise<never> = new Promise((_, reject) =>
					setTimeout(() => reject(new Error("Godot autoload didn't signal ready in 15s")), 15000),
				);
				await Promise.race([ready, timeout]);
				if (cancelled) return;
				onReady?.();
				// Godot's main_scene is match_warmup.tscn, but it stays idle until
				// React sends ui_play. This component's job is only engine boot.
			} catch (err: unknown) {
				if (cancelled) return;
				console.error("[GameCanvas] boot failed:", err);
				const msg: string = err instanceof Error ? err.message : String(err);
				setError(msg);
				onError?.(msg);
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
			{/* Engine-load progress is rendered by the parent's LoadingOverlay
			    (it owns the unified loading UI across engine boot + warmup). We
			    intentionally don't paint a redundant "Loading X%" badge here. */}
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

function patchEngineLocateFile(engine: GodotEngine, cacheVersion: string | null): void {
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
			if (/^(https?:|data:|blob:)/i.test(resolved)) {
				return resolved;
			}
			const localUrl: string = resolved.startsWith("/") ? resolved : `${GODOT_DIR}/${resolved}`;
			return cacheBustGodotUrl(localUrl, cacheVersion);
		};
		return moduleCfg;
	};
}

function logGodotStderr(...args: unknown[]): void {
	const text: string = args.map(String).join(" ");
	if (isRunDependencyProgressLine(text)) {
		const now: number = Date.now();
		if (now - lastRunDependencyNoticeAt > 15000) {
			lastRunDependencyNoticeAt = now;
			console.info("[Godot] loading WebAssembly side modules...");
		}
		return;
	}
	console.error("[Godot]", ...args);
}

function logBrowserRenderDiagnostics(): void {
	const canvas: HTMLCanvasElement = document.createElement("canvas");
	const attrs: WebGLContextAttributes = {
		alpha: false,
		antialias: false,
		depth: true,
		failIfMajorPerformanceCaveat: false,
		powerPreference: "high-performance",
		stencil: false,
	};
	const gl2 = canvas.getContext("webgl2", attrs) as WebGL2RenderingContext | null;
	const gl1 =
		gl2 === null ? (canvas.getContext("webgl", attrs) as WebGLRenderingContext | null) : null;
	const gl: WebGL2RenderingContext | WebGLRenderingContext | null = gl2 ?? gl1;

	const baseInfo = {
		userAgent: navigator.userAgent,
		platform: navigator.platform,
		language: navigator.language,
		hardwareConcurrency: navigator.hardwareConcurrency,
		deviceMemory: navigator.deviceMemory,
		crossOriginIsolated: window.crossOriginIsolated,
		webgl2: gl2 !== null,
		webgl1: gl1 !== null,
	};
	console.info("[webgl-diagnostics] browser", baseInfo);

	if (gl === null) {
		console.error("[webgl-diagnostics] WebGL unavailable");
		return;
	}

	const dbg = gl.getExtension("WEBGL_debug_renderer_info");
	const rendererInfo =
		dbg !== null
			? {
					vendor: gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL) as string,
					renderer: gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) as string,
				}
			: {
					vendor: gl.getParameter(gl.VENDOR) as string,
					renderer: gl.getParameter(gl.RENDERER) as string,
				};
	console.info("[webgl-diagnostics] renderer", rendererInfo);

	const caps: Record<string, number | string | boolean | null> = {
		version: gl.getParameter(gl.VERSION) as string,
		shadingLanguageVersion: gl.getParameter(gl.SHADING_LANGUAGE_VERSION) as string,
		maxTextureSize: gl.getParameter(gl.MAX_TEXTURE_SIZE) as number,
		maxRenderbufferSize: gl.getParameter(gl.MAX_RENDERBUFFER_SIZE) as number,
		maxVertexAttribs: gl.getParameter(gl.MAX_VERTEX_ATTRIBS) as number,
		maxVertexUniformVectors: gl.getParameter(gl.MAX_VERTEX_UNIFORM_VECTORS) as number,
		maxFragmentUniformVectors: gl.getParameter(gl.MAX_FRAGMENT_UNIFORM_VECTORS) as number,
		maxVaryingVectors: gl.getParameter(gl.MAX_VARYING_VECTORS) as number,
		maxTextureImageUnits: gl.getParameter(gl.MAX_TEXTURE_IMAGE_UNITS) as number,
		maxVertexTextureImageUnits: gl.getParameter(gl.MAX_VERTEX_TEXTURE_IMAGE_UNITS) as number,
		maxCombinedTextureImageUnits: gl.getParameter(gl.MAX_COMBINED_TEXTURE_IMAGE_UNITS) as number,
	};
	if (gl2 !== null) {
		caps.maxArrayTextureLayers = gl2.getParameter(gl2.MAX_ARRAY_TEXTURE_LAYERS) as number;
		caps.max3DTextureSize = gl2.getParameter(gl2.MAX_3D_TEXTURE_SIZE) as number;
	}
	console.info("[webgl-diagnostics] caps", caps);

	const terrainRisk = gl2 === null || Number(caps.maxVaryingVectors ?? 0) < 16;
	if (terrainRisk) {
		console.warn("[webgl-diagnostics] terrain risk: WebGL2 missing or low varying-vector budget");
	}
}

function isRunDependencyProgressLine(text: string): boolean {
	return (
		text.includes("still waiting on run dependencies") ||
		text.includes("dependency: loadDylibs") ||
		text.includes("dependency: al /godot/") ||
		text === "(end of list)"
	);
}

/** Hit the synthetic manifest endpoint that vite.config.ts serves to discover
 *  the actual base name of the Godot export (Godot uses config/name → e.g.
 *  "Ironclash4.3.pck", not "index.pck") plus the full GODOT_CONFIG block
 *  parsed out of the auto-generated <Project>.html — critical because that's
 *  where `gdextensionLibs` lives and the engine refuses to load addons
 *  like terrain_3d without it. */
async function fetchManifest(): Promise<GodotManifest> {
	const res = await fetch(`${GODOT_DIR}/_manifest.json`, { cache: "no-cache" });
	if (!res.ok) {
		throw new Error(`Manifest fetch failed (${res.status})`);
	}
	return (await res.json()) as GodotManifest;
}

const _scriptCache: Map<string, Promise<HTMLScriptElement>> = new Map();
const _preloadedGodotUrls: Set<string> = new Set();

function cacheBustGodotUrl(url: string, version: string | null | undefined): string {
	const cleanVersion: string | undefined = version?.trim();
	if (cleanVersion === undefined || cleanVersion.length === 0) return url;
	if (/^(https?:|data:|blob:)/i.test(url)) return url;
	const separator: string = url.includes("?") ? "&" : "?";
	return `${url}${separator}v=${encodeURIComponent(cleanVersion)}`;
}

function preloadGodotResources(
	manifest: GodotManifest,
	base: string,
	cacheVersion: string | null,
): void {
	const files: Set<string> | null =
		manifest.files === undefined ? null : new Set(manifest.files);

	const add = (fileName: string, as: "script" | "fetch", type?: string): void => {
		if (files !== null && !files.has(fileName)) return;
		const href: string = cacheBustGodotUrl(`${GODOT_DIR}/${fileName}`, cacheVersion);
		if (_preloadedGodotUrls.has(href)) return;
		const link: HTMLLinkElement = document.createElement("link");
		link.rel = "preload";
		link.href = href;
		link.as = as;
		if (type !== undefined) link.type = type;
		if (as === "fetch") link.crossOrigin = "anonymous";
		document.head.appendChild(link);
		_preloadedGodotUrls.add(href);
	};

	const baseName: string = base.slice(GODOT_DIR.length + 1);
	add(`${baseName}.js`, "script");
	add(`${baseName}.wasm`, "fetch", "application/wasm");
	add(`${baseName}.side.wasm`, "fetch", "application/wasm");
	add(`${baseName}.pck`, "fetch", "application/octet-stream");
	add(`${baseName}.worker.js`, "script");
	add(`${baseName}.audio.worklet.js`, "script");

	for (const lib of manifest.godotConfig?.gdextensionLibs ?? []) {
		add(lib, "fetch", "application/wasm");
	}
}

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
