// JS-side counterpart of `src/gameplay/web/web_bridge.gd`.
//
// The contract:
//   - Godot calls `window.GodotBridge.onGameEvent(name, payloadObj)` whenever
//     it wants to push state to the UI (already a parsed object, NOT JSON).
//   - Godot installs `window.GodotBridge.dispatch(name, payloadJson)` during
//     its own _ready(); React calls it via `bridge.emit(name, payload)` which
//     stringifies the payload first.
//   - Godot sets `engineReady = true` once the autoload has wired itself.

type Listener<T = unknown> = (payload: T) => void;

class GodotBridgeImpl {
	/** True once Godot's WebBridge autoload has installed `dispatch`. */
	public engineReady: boolean = false;

	/** Filled by Godot — until then it's a no-op stub that buffers nothing. */
	public dispatch: (name: string, payloadJson: string) => void = (name) => {
		console.warn(`[GodotBridge] dispatch("${name}") called before engine ready — dropping`);
	};

	private readonly _listeners: Map<string, Set<Listener>> = new Map();
	private readonly _readyWaiters: Array<() => void> = [];

	/** Called BY GODOT for each game-side event. Keep the signature stable. */
	public onGameEvent(name: string, payload: unknown): void {
		const subs = this._listeners.get(name);
		if (subs === undefined) return;
		for (const fn of subs) {
			try {
				fn(payload);
			} catch (err: unknown) {
				console.error(`[GodotBridge] listener for "${name}" threw:`, err);
			}
		}
	}

	/** Subscribe to a Godot event. Returns an unsubscribe function. */
	public subscribe<T = unknown>(name: string, listener: Listener<T>): () => void {
		let bucket = this._listeners.get(name);
		if (bucket === undefined) {
			bucket = new Set();
			this._listeners.set(name, bucket);
		}
		bucket.add(listener as Listener);
		return () => {
			bucket?.delete(listener as Listener);
		};
	}

	/** Send an event TO Godot. Drops silently with a warning if engine not ready. */
	public emit(name: string, payload: Record<string, unknown> = {}): void {
		if (!this.engineReady) {
			console.warn(`[GodotBridge] emit("${name}") before engine ready — dropping`);
			return;
		}
		this.dispatch(name, JSON.stringify(payload));
	}

	/** Resolves once the Godot side has marked the bridge ready. */
	public async waitForReady(): Promise<void> {
		if (this.engineReady) return;
		await new Promise<void>((resolve) => {
			this._readyWaiters.push(resolve);
		});
	}

	/** Internal — called from the godot_ready listener wired below.
	 *  ALWAYS drains pending `_readyWaiters` regardless of `engineReady`,
	 *  because Godot's WebBridge autoload sets `engineReady = true` directly
	 *  BEFORE dispatching the ready event. An early return here would skip
	 *  the resolver loop and waiters would hang forever. */
	public _markReady(): void {
		this.engineReady = true;
		while (this._readyWaiters.length > 0) {
			const fn = this._readyWaiters.shift();
			fn?.();
		}
	}
}

declare global {
	interface Window {
		GodotBridge: GodotBridgeImpl;
	}
}

// Install the global singleton — single source of truth for the page.
const bridge: GodotBridgeImpl = new GodotBridgeImpl();
if (typeof window !== "undefined") {
	// Preserve `engineReady` and `dispatch` if Godot raced ahead and already
	// installed them (unlikely with React mounting first, but cheap insurance).
	const existing = (window as Window).GodotBridge as GodotBridgeImpl | undefined;
	if (existing !== undefined) {
		bridge.engineReady = existing.engineReady;
		if (typeof existing.dispatch === "function") {
			bridge.dispatch = existing.dispatch;
		}
	}
	window.GodotBridge = bridge;
}

// The Godot autoload emits `godot_ready` once the bridge is fully installed —
// flip our local readiness flag so emit() stops warning.
bridge.subscribe("godot_ready", () => bridge._markReady());

export const godotBridge: GodotBridgeImpl = bridge;
export type { GodotBridgeImpl };
