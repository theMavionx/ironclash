import { useEffect, useState } from "react";
import { godotBridge } from "@/bridge/godotBridge";
import { GameEvent } from "@/bridge/eventTypes";

interface Props {
	onPlay: (displayName: string) => void;
}

export default function MenuOverlay({ onPlay }: Props) {
	const [busy, setBusy] = useState<boolean>(false);
	const [displayName, setDisplayName] = useState<string>(() => {
		const saved: string | null = window.localStorage.getItem("ironclash.displayName");
		return sanitizeDisplayName(saved ?? "");
	});

	useEffect(() => {
		const off = godotBridge.subscribe(GameEvent.NetworkDisconnected, () => {
			setBusy(false);
		});
		return off;
	}, []);

	function handlePlay(): void {
		if (busy) return;
		const cleanName: string = sanitizeDisplayName(displayName);
		setDisplayName(cleanName);
		window.localStorage.setItem("ironclash.displayName", cleanName);
		setBusy(true);
		const canvas: HTMLCanvasElement | null = document.getElementById(
			"godot-canvas",
		) as HTMLCanvasElement | null;
		if (canvas !== null) canvas.focus();
		onPlay(cleanName);
	}

	function handleNameChange(value: string): void {
		setDisplayName(cleanDisplayName(value));
	}

	return (
		<div className="pointer-events-none absolute inset-0 flex flex-col bg-bg">
			<div className="pointer-events-none absolute left-10 top-10 select-none">
				<div className="font-sans text-display leading-none tracking-tight text-text">
					IRONCLASH
				</div>
				<div className="mt-2 font-sans text-caption uppercase tracking-label text-accent">
					5 v 5 - Browser Combined Arms
				</div>
			</div>

			<div className="pointer-events-auto absolute inset-0 flex flex-col items-center justify-center gap-4">
				<input
					type="text"
					value={displayName}
					onChange={(event) => handleNameChange(event.target.value)}
					onKeyDown={(event) => {
						if (event.key === "Enter") handlePlay();
					}}
					disabled={busy}
					maxLength={16}
					spellCheck={false}
					placeholder="CALLSIGN"
					className={
						"w-[360px] border-2 border-border-strong bg-black/65 px-5 py-3 " +
						"text-center font-mono text-value uppercase text-text outline-none " +
						"transition-colors duration-150 placeholder:text-text-muted " +
						"focus:border-accent disabled:cursor-wait disabled:opacity-40"
					}
				/>
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
						"disabled:cursor-wait disabled:opacity-40 disabled:hover:bg-accent disabled:hover:text-bg"
					}
				>
					<span className="relative z-10">{busy ? "STARTING..." : "PLAY"}</span>
					<span
						aria-hidden
						className="absolute -bottom-2 left-3 right-3 h-[3px] bg-accent opacity-50 transition-opacity group-hover:opacity-100"
					/>
				</button>
			</div>

			<div className="pointer-events-none absolute bottom-1/3 left-0 right-0 mt-6 text-center font-sans text-caption uppercase tracking-label text-text-muted">
				{busy ? "Starting warmup..." : "Game loaded. Pick callsign and deploy"}
			</div>

			<div className="pointer-events-none absolute bottom-6 left-10 font-mono text-caption text-text-muted">
				v0.1 - proto 0.1.3
			</div>
		</div>
	);
}

function sanitizeDisplayName(raw: string): string {
	const clean: string = cleanDisplayName(raw);
	return clean.length > 0 ? clean : "Player";
}

function cleanDisplayName(raw: string): string {
	return raw
		.normalize("NFKC")
		.replace(/[^\p{L}\p{N}_ -]/gu, "")
		.replace(/\s+/g, " ")
		.trim()
		.slice(0, 16);
}
