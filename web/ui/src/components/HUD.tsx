import { useEffect, useRef, useState } from "react";
import { useGodotEvent } from "@/hooks/useGodotEvent";
import {
	GameEvent,
	type AmmoChangedPayload,
	type HealthChangedPayload,
	type KillFeedPayload,
	type LocalDiedPayload,
	type MatchStatePayload,
	type NetworkConnectedPayload,
	type VehicleDriveStartPayload,
	type VehicleHpPayload,
} from "@/bridge/eventTypes";

/**
 * Match HUD over the Godot canvas. All payloads come from network_manager.gd
 * via WebBridge — no React-side game state.
 */
export default function HUD() {
	const [hp, setHp] = useState<HealthChangedPayload>({ hp: 100, max: 100 });
	const [ammo, setAmmo] = useState<AmmoChangedPayload>({ current: 30, reserve: 30, weapon: "AR" });
	const [match, setMatch] = useState<MatchStatePayload | null>(null);
	const [kills, setKills] = useState<KillFeedRow[]>([]);
	const [localPeer, setLocalPeer] = useState<NetworkConnectedPayload | null>(null);
	const [deathInfo, setDeathInfo] = useState<LocalDiedPayload | null>(null);
	const [respawnRemaining, setRespawnRemaining] = useState<number>(0);
	const [connState, setConnState] = useState<"connecting" | "open" | "closed" | "failed">(
		"connecting",
	);
	const [vehicle, setVehicle] = useState<VehicleHpPayload | null>(null);
	// Server-side respawn delay; HUD reads it from balance JSON in the future,
	// hardcoded here to match assets/data/balance/match.json.
	const RESPAWN_DELAY_S: number = 5;
	const tickRef = useRef<ReturnType<typeof setInterval> | null>(null);

	useGodotEvent<HealthChangedPayload>(GameEvent.HealthChanged, (p) => setHp(p));
	useGodotEvent<AmmoChangedPayload>(GameEvent.AmmoChanged, (p) => setAmmo(p));
	useGodotEvent<NetworkConnectedPayload>(GameEvent.NetworkConnected, (p) => {
		setLocalPeer(p);
		setHp({ hp: 100, max: 100 });
		setKills([]);
		setDeathInfo(null);
		setConnState("open");
	});
	useGodotEvent<{ reason: string }>(GameEvent.NetworkDisconnected, () => setConnState("closed"));
	useGodotEvent<{ reason: string }>(GameEvent.NetworkConnectionFailed, () => setConnState("failed"));
	useGodotEvent<VehicleDriveStartPayload>(GameEvent.VehicleDriveStart, (p) => {
		setVehicle({ vehicle_id: p.vehicle_id, hp: 0, max_hp: 0, alive: true });
	});
	useGodotEvent<Record<string, never>>(GameEvent.VehicleDriveEnd, () => setVehicle(null));
	useGodotEvent<VehicleHpPayload>(GameEvent.VehicleHp, (p) => setVehicle(p));
	useGodotEvent<MatchStatePayload>(GameEvent.MatchState, (p) => setMatch(p));
	useGodotEvent<KillFeedPayload>(GameEvent.KillFeed, (p) => {
		setKills((rows) => {
			const next: KillFeedRow[] = [
				{ id: Date.now() + Math.random(), killer: p.killer, victim: p.victim, weapon: p.weapon, headshot: p.headshot },
				...rows,
			];
			return next.slice(0, 6);
		});
	});
	useGodotEvent<LocalDiedPayload>(GameEvent.LocalDied, (p) => {
		setDeathInfo(p);
		setRespawnRemaining(RESPAWN_DELAY_S);
		if (tickRef.current !== null) clearInterval(tickRef.current);
		tickRef.current = setInterval(() => {
			setRespawnRemaining((r) => Math.max(0, r - 0.1));
		}, 100);
	});
	useGodotEvent<Record<string, never>>(GameEvent.LocalRespawned, () => {
		setDeathInfo(null);
		setRespawnRemaining(0);
		setHp({ hp: 100, max: 100 });
		if (tickRef.current !== null) {
			clearInterval(tickRef.current);
			tickRef.current = null;
		}
	});

	useEffect(() => () => {
		if (tickRef.current !== null) clearInterval(tickRef.current);
	}, []);

	const hpPct: number = Math.max(0, Math.min(100, (hp.hp / Math.max(hp.max, 1)) * 100));
	const isLow: boolean = hpPct <= 25;

	return (
		<>
			{/* ── Top-center: team scoreboard + match state ─────────────────── */}
			<div className="absolute left-1/2 top-4 -translate-x-1/2 flex items-center gap-4">
				<TeamBadge color="red" count={match?.red_count ?? 0} score={match?.red_score ?? 0} />
				<div className="flex flex-col items-center min-w-[140px]">
					<div className="ui-label text-text-muted">{matchStateLabel(match?.state)}</div>
					<div className="font-mono text-metric leading-none text-text">
						{matchClockText(match)}
					</div>
				</div>
				<TeamBadge color="blue" count={match?.blue_count ?? 0} score={match?.blue_score ?? 0} />
			</div>

			{/* ── Warmup countdown overlay ─────────────────────────────────── */}
			{match?.state === "warmup" && (
				<div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center">
					<div className="font-sans text-display tracking-tight text-accent">
						MATCH STARTS IN
					</div>
					<div className="mt-2 font-mono text-[80px] leading-none text-text">
						{match.time_remaining.toFixed(1)}
					</div>
				</div>
			)}

			{/* ── Post-match overlay ──────────────────────────────────────── */}
			{match?.state === "post_match" && (
				<div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center bg-black/60">
					<div className="font-sans text-display tracking-tight text-text">
						{postMatchHeadline(match)}
					</div>
					<div className="mt-4 flex items-center gap-8">
						<div className="text-center">
							<div className="ui-label text-red-400">RED</div>
							<div className="font-mono text-[64px] leading-none text-red-400">{match.red_score}</div>
						</div>
						<div className="font-mono text-text-muted">—</div>
						<div className="text-center">
							<div className="ui-label text-blue-400">BLUE</div>
							<div className="font-mono text-[64px] leading-none text-blue-400">{match.blue_score}</div>
						</div>
					</div>
					<div className="mt-6 ui-label text-text-muted">
						Next match in {match.time_remaining.toFixed(0)}s
					</div>
				</div>
			)}

			{/* ── Top-right: kill feed ──────────────────────────────────────── */}
			<div className="absolute right-6 top-6 flex w-72 flex-col gap-1 text-right">
				{kills.map((row) => (
					<KillFeedRowEl key={row.id} row={row} localPeer={localPeer?.peer_id} />
				))}
			</div>

			{/* ── Top-left: peer / team identity + connection state ─────────── */}
			<div className="absolute left-6 top-6 flex items-center gap-3">
				<ConnDot state={connState} />
				{localPeer !== null ? (
					<div>
						<div className="ui-label text-text-muted">You</div>
						<div className="font-mono text-value text-text">
							P{localPeer.peer_id}{" "}
							<span className={localPeer.team === "red" ? "text-red-400" : "text-blue-400"}>
								{(localPeer.team ?? "").toUpperCase()}
							</span>
						</div>
					</div>
				) : (
					<div className="font-mono text-caption text-text-muted">
						{connStateLabel(connState)}
					</div>
				)}
			</div>

			{/* ── Bottom-left: HP (infantry + vehicle if driving) ───────────── */}
			<div className="absolute bottom-6 left-6 w-72">
				{vehicle !== null && (
					<VehicleHpBlock vehicle={vehicle} />
				)}
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

			{/* ── Bottom-right: ammo ───────────────────────────────────────── */}
			<div className="absolute bottom-6 right-6 text-right">
				<div className="ui-label mb-1">{ammo.weapon}</div>
				<div className="font-mono text-text">
					<span className="text-metric leading-none">{ammo.current}</span>
					<span className="ml-2 text-value text-text-muted">/ {ammo.reserve}</span>
				</div>
			</div>

			{/* ── Center crosshair (hidden when dead) ──────────────────────── */}
			{deathInfo === null && (
				<div className="pointer-events-none absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2">
					<div className="relative h-4 w-4">
						<div className="absolute left-1/2 top-0 h-1.5 w-px -translate-x-1/2 bg-text" />
						<div className="absolute bottom-0 left-1/2 h-1.5 w-px -translate-x-1/2 bg-text" />
						<div className="absolute left-0 top-1/2 h-px w-1.5 -translate-y-1/2 bg-text" />
						<div className="absolute right-0 top-1/2 h-px w-1.5 -translate-y-1/2 bg-text" />
					</div>
				</div>
			)}

			{/* ── Death overlay ─────────────────────────────────────────────── */}
			{deathInfo !== null && (
				<div className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center bg-red-950/40">
					<div className="mb-2 font-sans text-display tracking-tight text-danger">YOU DIED</div>
					<div className="ui-label text-text">
						Killed by P{deathInfo.killer} ({deathInfo.weapon.toUpperCase()})
					</div>
					<div className="mt-6 font-mono text-metric text-text">
						Respawn in {respawnRemaining.toFixed(1)}s
					</div>
				</div>
			)}
		</>
	);
}

function matchStateLabel(s: MatchStatePayload["state"] | undefined): string {
	switch (s) {
		case "waiting": return "WAITING FOR PLAYERS";
		case "warmup": return "WARMUP";
		case "in_progress": return "MATCH";
		case "post_match": return "POST MATCH";
		default: return "—";
	}
}

/** Top-center clock: roster count when waiting, MM:SS during a timed phase. */
function matchClockText(m: MatchStatePayload | null): string {
	if (m === null) return "— v —";
	if (m.state === "waiting") return `${m.red_count} v ${m.blue_count}`;
	const total: number = Math.max(0, Math.floor(m.time_remaining));
	const mm: number = Math.floor(total / 60);
	const ss: number = total % 60;
	return `${mm.toString().padStart(2, "0")}:${ss.toString().padStart(2, "0")}`;
}

function postMatchHeadline(m: MatchStatePayload): string {
	if (m.red_score > m.blue_score) return "RED WINS";
	if (m.blue_score > m.red_score) return "BLUE WINS";
	return "DRAW";
}

type ConnState = "connecting" | "open" | "closed" | "failed";

function connStateLabel(s: ConnState): string {
	switch (s) {
		case "connecting": return "CONNECTING…";
		case "open": return "ONLINE";
		case "closed": return "OFFLINE";
		case "failed": return "CONNECTION FAILED";
	}
}

interface VehicleHpBlockProps {
	vehicle: VehicleHpPayload;
}

function VehicleHpBlock({ vehicle }: VehicleHpBlockProps) {
	const pct: number = Math.max(0, Math.min(100, (vehicle.hp / Math.max(vehicle.max_hp, 1)) * 100));
	const isLow: boolean = pct <= 25;
	const label: string = vehicle.vehicle_id.toUpperCase();
	return (
		<div className="mb-3 border-l-2 border-accent pl-3">
			<div className="mb-1 flex items-baseline justify-between">
				<span className="ui-label text-accent">{label}</span>
				<span className={"font-mono text-value " + (isLow ? "text-danger" : "text-text")}>
					{vehicle.hp}
					<span className="ml-1 text-text-muted">/ {vehicle.max_hp}</span>
				</span>
			</div>
			<div className="h-[3px] w-full bg-border">
				<div
					className={"h-full transition-[width] duration-200 " + (isLow ? "bg-danger" : "bg-accent")}
					style={{ width: `${pct}%` }}
				/>
			</div>
		</div>
	);
}

function ConnDot({ state }: { state: ConnState }) {
	const cls: string =
		state === "open" ? "bg-green-400" :
		state === "connecting" ? "bg-yellow-400 animate-pulse" :
		"bg-red-500";
	return (
		<div
			className={"h-2.5 w-2.5 rounded-full " + cls}
			title={connStateLabel(state)}
		/>
	);
}

interface KillFeedRow {
	id: number;
	killer: number;
	victim: number;
	weapon: string;
	headshot: boolean;
}

interface TeamBadgeProps {
	color: "red" | "blue";
	count: number;
	score: number;
}

function TeamBadge({ color, count, score }: TeamBadgeProps) {
	const colorClass: string = color === "red" ? "text-red-400 border-red-500/60" : "text-blue-400 border-blue-500/60";
	return (
		<div className={"flex flex-col items-center border px-4 py-1 min-w-[88px] " + colorClass}>
			<div className="ui-label">{color.toUpperCase()}</div>
			<div className="font-mono text-metric leading-none">{score}</div>
			<div className="font-mono text-caption text-text-muted">{count} players</div>
		</div>
	);
}

interface KillFeedRowElProps {
	row: KillFeedRow;
	localPeer?: number;
}

function KillFeedRowEl({ row, localPeer }: KillFeedRowElProps) {
	const youKilled: boolean = row.killer === localPeer;
	const youDied: boolean = row.victim === localPeer;
	const killerCls: string = youKilled ? "text-friendly" : "text-text";
	const victimCls: string = youDied ? "text-danger" : "text-enemy";
	return (
		<div className="flex items-center justify-end gap-2 bg-hud-bg px-2 py-1 text-label">
			<span className={killerCls}>P{row.killer}</span>
			<span className="text-text-muted">[{row.weapon.toUpperCase()}{row.headshot ? " HS" : ""}]</span>
			<span className={victimCls}>P{row.victim}</span>
		</div>
	);
}
