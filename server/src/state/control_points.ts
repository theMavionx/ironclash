// Server-authoritative control point ownership and scoring helpers.
//
// Players on foot count from their player transform. Players driving a vehicle
// count from the vehicle transform instead, so a parked body cannot capture a
// point while the same peer is actually flying/driving elsewhere.

import type { MatchZoneState, Team, Vec3, ZoneOwner } from "../../../shared/protocol.ts";
import { cfg, type ControlPointConfig } from "../config.ts";
import { players } from "./players.ts";
import { vehicles } from "./vehicles.ts";

interface ControlPointRuntime extends ControlPointConfig {
	owner: ZoneOwner;
	capture_team: ZoneOwner;
	capture_elapsed_s: number;
}

interface TeamPosition {
	team: Team;
	pos: Vec3;
}

export interface ControlPointScoreTick {
	red_points: number;
	blue_points: number;
}

export interface ControlPointOwnerCounts {
	red: number;
	blue: number;
	neutral: number;
}

const _points: ControlPointRuntime[] = cfg.match.control_points.map((point) => ({
	...point,
	owner: "neutral",
	capture_team: "neutral",
	capture_elapsed_s: 0,
}));

export function reset_control_points(): void {
	for (const point of _points) {
		point.owner = "neutral";
		point.capture_team = "neutral";
		point.capture_elapsed_s = 0;
	}
}

export function tick_control_points(dt_s: number): ControlPointScoreTick {
	const entities: TeamPosition[] = collect_team_positions();
	const score: ControlPointScoreTick = { red_points: 0, blue_points: 0 };

	for (const point of _points) {
		const present: Set<Team> = teams_inside_point(point, entities);
		if (present.size === 1) {
			const team: Team = Array.from(present)[0] as Team;
			tick_capture(point, team, dt_s);
		} else {
			point.capture_team = "neutral";
			point.capture_elapsed_s = 0;
		}

		if (point.owner === "red") score.red_points += point.points_per_second * dt_s;
		else if (point.owner === "blue") score.blue_points += point.points_per_second * dt_s;
	}

	return score;
}

export function get_control_point_snapshot(): MatchZoneState[] {
	return _points.map((point) => ({
		id: point.id,
		label: point.label,
		owner: point.owner,
		capture_team: point.capture_team,
		capture_progress: point.capture_seconds <= 0
			? 0
			: Math.max(0, Math.min(1, point.capture_elapsed_s / point.capture_seconds)),
	}));
}

export function control_point_owner_counts(): ControlPointOwnerCounts {
	const counts: ControlPointOwnerCounts = { red: 0, blue: 0, neutral: 0 };
	for (const point of _points) {
		if (point.owner === "red") counts.red++;
		else if (point.owner === "blue") counts.blue++;
		else counts.neutral++;
	}
	return counts;
}

function tick_capture(point: ControlPointRuntime, team: Team, dt_s: number): void {
	if (point.owner === team) {
		point.capture_team = "neutral";
		point.capture_elapsed_s = 0;
		return;
	}
	if (point.capture_team !== team) {
		point.capture_team = team;
		point.capture_elapsed_s = 0;
	}
	point.capture_elapsed_s += dt_s;
	if (point.capture_elapsed_s >= point.capture_seconds) {
		point.owner = team;
		point.capture_team = "neutral";
		point.capture_elapsed_s = 0;
	}
}

function collect_team_positions(): TeamPosition[] {
	const out: TeamPosition[] = [];
	const driving_peer_ids: Set<number> = new Set();

	for (const vehicle of vehicles.values()) {
		if (!vehicle.alive || vehicle.driver_peer_id < 0) continue;
		const driver = players.get(vehicle.driver_peer_id);
		if (driver === undefined || !driver.alive) continue;
		driving_peer_ids.add(driver.peer_id);
		out.push({ team: driver.team, pos: vehicle.pos });
	}

	for (const player of players.values()) {
		if (!player.alive || driving_peer_ids.has(player.peer_id)) continue;
		out.push({ team: player.team, pos: player.pos });
	}

	return out;
}

function teams_inside_point(point: ControlPointRuntime, entities: TeamPosition[]): Set<Team> {
	const present: Set<Team> = new Set();
	const half_height: number = point.height_m * 0.5;
	for (const entity of entities) {
		const dx: number = entity.pos[0] - point.pos[0];
		const dz: number = entity.pos[2] - point.pos[2];
		const dy: number = Math.abs(entity.pos[1] - point.pos[1]);
		if (dy > half_height) continue;
		if (Math.sqrt(dx * dx + dz * dz) > point.radius_m) continue;
		present.add(entity.team);
	}
	return present;
}
