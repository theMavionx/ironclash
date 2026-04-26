// Player roster + team helpers. Add per-player fields here, not on the
// snapshot type — the snapshot pulls only what clients need to render.
//
// Players are server-authoritative for hp / team / alive. Position is
// trusted from the client (with speed-clamp; see net dispatch).

import type { WebSocket } from "ws";
import type { Team, Vec3 } from "../../../shared/protocol.ts";
import { cfg } from "../config.ts";

export interface Player {
	peer_id: number;
	ws: WebSocket;
	team: Team;
	alive: boolean;
	hp: number;
	max_hp: number;
	pos: Vec3;
	rot_y: number;
	aim_pitch: number;
	last_seen_ms: number;
	last_transform_ms: number;
	hello_received: boolean;
	last_fire_ms: Map<string, number>;
	respawn_at_ms: number;
	clamp_warnings: number;
	weapon: string;       // wire id, MUST match weapons.json key ("ak" / "rpg")
	move_state: string;   // "idle" | "walk" | "sprint" | "crouch" | "ads" | "airborne"
}

export const players: Map<number, Player> = new Map();
let _next_peer_id: number = 1;

export function next_peer_id(): number { return _next_peer_id++; }

export function team_count(team: Team): number {
	let n: number = 0;
	for (const p of players.values()) if (p.team === team) n++;
	return n;
}

/** design/gdd/team-assignment.md: assign to smaller team, tie-break to red. */
export function pick_team_for_new_peer(): Team {
	return team_count("red") <= team_count("blue") ? "red" : "blue";
}

export function spawn_for_team(team: Team): Vec3 {
	const s: Vec3 = team === "red" ? cfg.match.red_spawn : cfg.match.blue_spawn;
	const jitter: number = 1.5;
	return [
		s[0] + (Math.random() - 0.5) * jitter,
		s[1],
		s[2] + (Math.random() - 0.5) * jitter,
	];
}

export function make_player(peer_id: number, ws: WebSocket, team: Team): Player {
	return {
		peer_id, ws, team,
		alive: true,
		hp: cfg.match.starting_hp,
		max_hp: cfg.match.starting_hp,
		pos: spawn_for_team(team),
		rot_y: team === "red" ? 0 : Math.PI,
		aim_pitch: 0,
		last_seen_ms: Date.now(),
		last_transform_ms: 0,
		hello_received: false,
		last_fire_ms: new Map(),
		respawn_at_ms: 0,
		clamp_warnings: 0,
		weapon: "ak",
		move_state: "idle",
	};
}
