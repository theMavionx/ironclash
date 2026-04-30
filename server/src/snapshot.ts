// Drift-corrected snapshot loop. Every TICK_MS we tick the match state,
// run respawns, build per-player + per-vehicle snapshots, and broadcast.
//
// Windows' setInterval rounds to the system timer quantum (15.6 ms),
// collapsing 30 Hz to ~22 Hz. A self-rescheduling setTimeout that tracks
// the next deadline pins us to the real tick rate on every OS.

import type { SnapshotPlayer, SnapshotVehicle } from "../../shared/protocol.ts";
import { cfg } from "./config.ts";
import { players } from "./state/players.ts";
import { check_vehicle_respawns, vehicles } from "./state/vehicles.ts";
import { check_respawns, maybe_broadcast_match_state, tick_match_state } from "./state/match.ts";
import { broadcast } from "./net/socket.ts";

let _next_tick_at: number = Date.now();
let _server_tick: number = 0;

function build_player_snapshot(): SnapshotPlayer[] {
	const out: SnapshotPlayer[] = [];
	for (const p of players.values()) {
		out.push({
			id: p.peer_id, team: p.team,
			display_name: p.display_name,
			pos: p.pos, rot_y: p.rot_y, aim_pitch: p.aim_pitch,
			hp: p.hp, max_hp: p.max_hp, alive: p.alive,
			weapon: p.weapon, move_state: p.move_state,
		});
	}
	return out;
}

function build_vehicle_snapshot(): SnapshotVehicle[] {
	const out: SnapshotVehicle[] = [];
	for (const v of vehicles.values()) {
		out.push({
			id: v.id, pos: v.pos, rot: v.rot,
			aim_yaw: v.aim_yaw, aim_pitch: v.aim_pitch,
			driver_peer_id: v.driver_peer_id,
			hp: v.hp, max_hp: v.max_hp, alive: v.alive,
		});
	}
	return out;
}

export function start_snapshot_loop(): void {
	function tick(): void {
		const now: number = Date.now();
		_server_tick++;
		tick_match_state(now);
		maybe_broadcast_match_state(now);
		check_respawns(now);
		for (const v of check_vehicle_respawns(now)) {
			broadcast({ t: "vfx_event", kind: "smoke_fire_stop", entity_id: v.id, pos: v.pos });
		}
		if (players.size > 0) {
			broadcast({
				t: "snapshot",
				tick: _server_tick,
				server_t: now,
				players: build_player_snapshot(),
				vehicles: build_vehicle_snapshot(),
			});
		}
		_next_tick_at += cfg.tick_ms;
		if (now - _next_tick_at > cfg.tick_ms * 5) _next_tick_at = now + cfg.tick_ms;
		setTimeout(tick, Math.max(0, _next_tick_at - Date.now()));
	}
	setTimeout(tick, cfg.tick_ms);
}
