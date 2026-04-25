import { useState } from "react";
import { useGodotEvent } from "@/hooks/useGodotEvent";
import {
	GameEvent,
	type AmmoChangedPayload,
	type HealthChangedPayload,
} from "@/bridge/eventTypes";

/**
 * HUD overlay per design/gdd/art-bible-ui.md.
 * Tactical-minimal: thin lines, no rounding, monospace numerals, accent only
 * for HP fill. Sample widgets — extend per design/gdd/hud.md as features land.
 */
export default function HUD() {
	const [hp, setHp] = useState<HealthChangedPayload>({ hp: 100, max: 100 });
	const [ammo, setAmmo] = useState<AmmoChangedPayload>({
		current: 30,
		reserve: 90,
		weapon: "AK-74",
	});

	useGodotEvent<HealthChangedPayload>(GameEvent.HealthChanged, (payload) => setHp(payload));
	useGodotEvent<AmmoChangedPayload>(GameEvent.AmmoChanged, (payload) => setAmmo(payload));

	const hpPct: number = Math.max(0, Math.min(100, (hp.hp / Math.max(hp.max, 1)) * 100));
	const isLow: boolean = hpPct <= 25;

	return (
		<>
			{/* ── Bottom-left: HP ──────────────────────────────────────────────── */}
			<div className="absolute bottom-6 left-6 w-72">
				<div className="mb-2 flex items-baseline justify-between">
					<span className="ui-label">Health</span>
					<span className={"font-mono text-value " + (isLow ? "text-danger" : "text-text")}>
						{hp.hp}
						<span className="ml-1 text-text-muted">/ {hp.max}</span>
					</span>
				</div>
				<div className="h-[3px] w-full bg-border">
					<div
						className={"h-full transition-[width] duration-200 " + (isLow ? "bg-danger" : "bg-accent")}
						style={{ width: `${hpPct}%` }}
					/>
				</div>
			</div>

			{/* ── Bottom-right: ammo ───────────────────────────────────────────── */}
			<div className="absolute bottom-6 right-6 text-right">
				<div className="ui-label mb-1">{ammo.weapon}</div>
				<div className="font-mono text-text">
					<span className="text-metric leading-none">{ammo.current}</span>
					<span className="ml-2 text-value text-text-muted">/ {ammo.reserve}</span>
				</div>
			</div>

			{/* ── Top-center: match timer placeholder ──────────────────────────── */}
			<div className="absolute left-1/2 top-6 -translate-x-1/2 text-center">
				<div className="ui-label mb-1">Round</div>
				<div className="font-mono text-metric leading-none text-text">02:45</div>
			</div>

			{/* ── Top-right: kill feed placeholder ─────────────────────────────── */}
			<div className="absolute right-6 top-6 flex w-72 flex-col gap-1 text-right">
				<KillFeedRow killer="player_1" weapon="AK" victim="enemy_3" />
				<KillFeedRow killer="player_2" weapon="RPG" victim="enemy_1" />
			</div>

			{/* ── Center crosshair ─────────────────────────────────────────────── */}
			<div className="pointer-events-none absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2">
				<div className="relative h-4 w-4">
					<div className="absolute left-1/2 top-0 h-1.5 w-px -translate-x-1/2 bg-text" />
					<div className="absolute bottom-0 left-1/2 h-1.5 w-px -translate-x-1/2 bg-text" />
					<div className="absolute left-0 top-1/2 h-px w-1.5 -translate-y-1/2 bg-text" />
					<div className="absolute right-0 top-1/2 h-px w-1.5 -translate-y-1/2 bg-text" />
				</div>
			</div>
		</>
	);
}

interface KillFeedRowProps {
	killer: string;
	weapon: string;
	victim: string;
}

function KillFeedRow({ killer, weapon, victim }: KillFeedRowProps) {
	return (
		<div className="flex items-center justify-end gap-2 bg-hud-bg px-2 py-1 text-label">
			<span className="text-friendly">{killer}</span>
			<span className="text-text-muted">[{weapon}]</span>
			<span className="text-enemy">{victim}</span>
		</div>
	);
}
