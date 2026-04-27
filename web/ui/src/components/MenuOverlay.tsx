import { useEffect, useState } from "react";
import { godotBridge } from "@/bridge/godotBridge";
import { GameEvent, UiEvent } from "@/bridge/eventTypes";

/**
 * Pre-match menu — sits over the Godot 3D menu scene that idles the player
 * model. Clicking PLAY emits `ui_play` to Godot which swaps the scene to
 * the gameplay map and connects the network.
 *
 * Auto-hides as soon as the user clicks PLAY. Returns the same overlay if
 * the user disconnects (we listen for the `network_disconnected` event so
 * the menu reappears after a server drop).
 */
export default function MenuOverlay() {
	const [visible, setVisible] = useState<boolean>(true);
	const [busy, setBusy] = useState<boolean>(false);

	useEffect(() => {
		// React's MenuOverlay shows again if the server drops the client —
		// the user is back at the title screen and may want to retry PLAY.
		const off = godotBridge.subscribe(GameEvent.NetworkDisconnected, () => {
			setVisible(true);
			setBusy(false);
		});
		return off;
	}, []);

	function handlePlay(): void {
		if (busy) return;
		setBusy(true);
		// Focus the canvas so Godot's later `Input.mouse_mode = MOUSE_MODE_CAPTURED`
		// (fired from PlayerController._ready in the gameplay scene) inherits
		// the click's transient activation. We don't request pointer-lock from
		// here because Chrome flagged that path with WrongDocumentError when
		// the canvas's owner document didn't match React's render document.
		const canvas: HTMLCanvasElement | null = document.getElementById("godot-canvas") as HTMLCanvasElement | null;
		if (canvas !== null) {
			canvas.focus();
		}
		godotBridge.emit(UiEvent.Play, {});
		setTimeout(() => setVisible(false), 180);
	}

	if (!visible) return null;

	return (
		<div className="pointer-events-none absolute inset-0 flex flex-col">
			{/* ── Title (top-left) ───────────────────────────────────────────── */}
			<div className="pointer-events-none absolute left-10 top-10 select-none">
				<div className="font-sans text-display tracking-tight text-text leading-none">
					IRONCLASH
				</div>
				<div className="mt-2 font-sans text-caption uppercase tracking-label text-accent">
					5 v 5 · Browser Combined Arms
				</div>
			</div>

			{/* ── Subtle vignette so the character reads against any background  */}
			<div
				className="pointer-events-none absolute inset-0"
				style={{
					background:
						"radial-gradient(ellipse at center, rgba(0,0,0,0) 45%, rgba(0,0,0,0.35) 75%, rgba(0,0,0,0.55) 100%)",
				}}
			/>

			{/* ── PLAY button (bottom-right) ─────────────────────────────────── */}
			<div className="pointer-events-auto absolute bottom-12 right-12">
				<button
					type="button"
					onClick={handlePlay}
					disabled={busy}
					className={
						"group relative flex items-center justify-center " +
						"px-20 py-5 font-sans text-display uppercase tracking-label " +
						"border-2 border-accent bg-accent text-bg " +
						"transition-all duration-150 " +
						"hover:bg-bg hover:text-accent active:scale-[0.97] " +
						"disabled:opacity-40 disabled:cursor-wait"
					}
				>
					<span className="relative z-10">PLAY</span>
					<span
						aria-hidden
						className="absolute -bottom-2 left-3 right-3 h-[3px] bg-accent opacity-50 group-hover:opacity-100 transition-opacity"
					/>
				</button>
				<div className="mt-3 text-right font-sans text-caption uppercase tracking-label text-text-muted">
					{busy ? "Loading match…" : "Click PLAY to start"}
				</div>
			</div>

			{/* ── Tiny build tag (bottom-left) ───────────────────────────────── */}
			<div className="pointer-events-none absolute bottom-6 left-10 font-mono text-caption text-text-muted">
				v0.1 · proto 0.1.0
			</div>
		</div>
	);
}
