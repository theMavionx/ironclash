import { useEffect, useRef, useState } from "react";
import { godotBridge } from "@/bridge/godotBridge";
import { GameEvent, UiEvent } from "@/bridge/eventTypes";
import GameCanvas from "@/components/GameCanvas";
import HUD from "@/components/HUD";
import LoadingOverlay from "@/components/LoadingOverlay";
import MenuOverlay from "@/components/MenuOverlay";

/**
 * Top-level UI orchestrator. Owns the boot phase so children stay simple:
 *
 *   booting     — GameCanvas mounts immediately on site entry, so Godot WASM/PCK
 *                 download starts without waiting for PLAY.
 *   menu        — shown after WebBridge and the idle warmup scene are ready.
 *                 PLAY sends `ui_play`.
 *   warmup      — Godot match_warmup.tscn prewarms shaders and loads Main.tscn.
 *                 `match_loading_progress` drives the loading overlay.
 *
 * No Godot 3D menu scene exists anymore — Godot's main_scene is the warmup
 * staging scene, which waits for React's PLAY event before doing heavy work.
 */
export default function App() {
	const [playRequested, setPlayRequested] = useState<boolean>(false);
	const [engineProgress, setEngineProgress] = useState<{ current: number; total: number }>({
		current: 0,
		total: 0,
	});
	const [engineReady, setEngineReady] = useState<boolean>(false);
	const [warmupReadyForPlay, setWarmupReadyForPlay] = useState<boolean>(false);
	const [bootError, setBootError] = useState<string | null>(null);
	const playSentRef = useRef<boolean>(false);

	useEffect(() => {
		return godotBridge.subscribe(GameEvent.WarmupReadyForPlay, () => {
			setWarmupReadyForPlay(true);
		});
	}, []);

	useEffect(() => {
		if (!playRequested || !engineReady || !warmupReadyForPlay || playSentRef.current) return;
		playSentRef.current = true;
		const id = window.setTimeout(() => {
			godotBridge.emit(UiEvent.Play, {});
		}, 0);
		return () => window.clearTimeout(id);
	}, [engineReady, playRequested, warmupReadyForPlay]);

	return (
		<div className="relative h-full w-full bg-bg">
			<GameCanvas
				onProgress={(current, total) =>
					setEngineProgress({ current, total })
				}
				onReady={() => setEngineReady(true)}
				onError={(msg) => setBootError(msg)}
			/>
			{/* Overlay layer — pointer-events disabled so input falls through
			    to the canvas; individual UI elements re-enable as needed. */}
			<div className="pointer-events-none absolute inset-0">
				<HUD />
				{engineReady && warmupReadyForPlay && !playRequested && bootError === null && (
					<MenuOverlay onPlay={() => setPlayRequested(true)} />
				)}
				{(!engineReady || !warmupReadyForPlay || playRequested || bootError !== null) && (
					<LoadingOverlay
						key={playRequested ? "warmup" : "engine"}
						mode={playRequested ? "warmup" : "engine"}
						engineCurrent={engineProgress.current}
						engineTotal={engineProgress.total}
						engineReady={engineReady}
						error={bootError}
					/>
				)}
			</div>
		</div>
	);
}
