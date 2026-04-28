import { useEffect, useState } from "react";
import { godotBridge } from "@/bridge/godotBridge";
import { GameEvent } from "@/bridge/eventTypes";

interface Props {
	/** Fires when the user clicks PLAY. Godot is already booted; this sends the
	 *  warmup/start signal through App.tsx. */
	onPlay: () => void;
}

/**
 * Pure-React 2D title screen shown after the Godot export has loaded.
 * PLAY does not boot the engine anymore; it starts match warmup.
 *
 * Re-shows on `network_disconnected` so the user can retry — but only if the
 * page never advanced past the menu (App.tsx owns the `started` state and is
 * the source of truth for visibility).
 */
export default function MenuOverlay({ onPlay }: Props) {
	const [busy, setBusy] = useState<boolean>(false);

	useEffect(() => {
		// Belt-and-braces — if the parent re-mounts us after a disconnect, reset
		// the busy flag so PLAY is clickable again.
		const off = godotBridge.subscribe(GameEvent.NetworkDisconnected, () => {
			setBusy(false);
		});
		return off;
	}, []);

	function handlePlay(): void {
		if (busy) return;
		setBusy(true);
		// Focus the canvas eagerly — when Godot eventually mounts, its
		// `Input.mouse_mode = MOUSE_MODE_CAPTURED` (fired from PlayerController)
		// will inherit the click's transient activation. We don't request
		// pointer-lock here — that path triggered WrongDocumentError when the
		// canvas ownerDocument changed.
		const canvas: HTMLCanvasElement | null = document.getElementById(
			"godot-canvas",
		) as HTMLCanvasElement | null;
		if (canvas !== null) canvas.focus();
		onPlay();
	}

	return (
		<div className="pointer-events-none absolute inset-0 flex flex-col bg-bg">
			{/* ── Title (top-left) ───────────────────────────────────────────── */}
			<div className="pointer-events-none absolute left-10 top-10 select-none">
				<div className="font-sans text-display tracking-tight text-text leading-none">
					IRONCLASH
				</div>
				<div className="mt-2 font-sans text-caption uppercase tracking-label text-accent">
					5 v 5 · Browser Combined Arms
				</div>
			</div>

			{/* ── Centered PLAY button ───────────────────────────────────────── */}
			<div className="pointer-events-auto absolute inset-0 flex items-center justify-center">
				<button
					type="button"
					onClick={handlePlay}
					disabled={busy}
					className={
						"group relative flex items-center justify-center " +
						"px-24 py-6 font-sans text-display uppercase tracking-label " +
						"border-2 border-accent bg-accent text-bg " +
						"transition-all duration-150 " +
						"hover:bg-bg hover:text-accent active:scale-[0.97] " +
						"disabled:opacity-40 disabled:cursor-wait disabled:hover:bg-accent disabled:hover:text-bg"
					}
				>
					<span className="relative z-10">{busy ? "STARTING…" : "PLAY"}</span>
					<span
						aria-hidden
						className="absolute -bottom-2 left-3 right-3 h-[3px] bg-accent opacity-50 group-hover:opacity-100 transition-opacity"
					/>
				</button>
			</div>

			{/* ── Hint just below the button ─────────────────────────────────── */}
			<div className="pointer-events-none absolute bottom-1/3 left-0 right-0 mt-6 text-center font-sans text-caption uppercase tracking-label text-text-muted">
				{busy ? "Starting warmup..." : "Game loaded. Click PLAY to deploy"}
			</div>

			{/* ── Tiny build tag (bottom-left) ───────────────────────────────── */}
			<div className="pointer-events-none absolute bottom-6 left-10 font-mono text-caption text-text-muted">
				v0.1 · proto 0.1.0
			</div>
		</div>
	);
}
