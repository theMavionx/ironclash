// Hit-pick functions: given a shooter, weapon, and aim, return the closest
// valid victim (player or vehicle) inside the cone+range. Pure: no state
// mutation, no broadcasting.

import type { Vec3 } from "../../../shared/protocol.ts";
import type { WeaponDef } from "../config.ts";
import type { Player } from "../state/players.ts";
import type { Vehicle, VehicleTarget } from "../state/vehicles.ts";
import { players } from "../state/players.ts";
import { vehicles, get_vehicle_spec } from "../state/vehicles.ts";
import { vec_dot, vec_len, vec_normalize, vec_scale, vec_sub } from "../util/vec.ts";

export interface HitContext {
	shooter_pos: Vec3;
	shooter_team?: string;        // "red"/"blue"; undefined = no friendly-fire filter
	shooter_player_id?: number;   // exclude self from player picks
	exclude_vehicle_id?: string;  // exclude shooter's own vehicle from vehicle picks
}

/** Closest enemy player inside the weapon's cone + range. Filters self,
 *  team-mates, and dead players. */
export function pick_player_target(ctx: HitContext, weapon: WeaponDef, dir: Vec3): Player | null {
	const aim: Vec3 = vec_normalize(dir);
	if (aim[0] === 0 && aim[1] === 0 && aim[2] === 0) return null;
	const cone_threshold: number = Math.cos((weapon.cone_deg * Math.PI) / 180);
	let best: Player | null = null;
	let best_dist: number = Number.POSITIVE_INFINITY;
	for (const q of players.values()) {
		if (ctx.shooter_player_id !== undefined && q.peer_id === ctx.shooter_player_id) continue;
		if (ctx.shooter_team !== undefined && q.team === ctx.shooter_team) continue;
		if (!q.alive) continue;
		const delta: Vec3 = vec_sub(q.pos, ctx.shooter_pos);
		const dist: number = vec_len(delta);
		if (dist > weapon.range_meters || dist < 1e-3) continue;
		const dot: number = vec_dot([delta[0]/dist, delta[1]/dist, delta[2]/dist], aim);
		if (dot < cone_threshold) continue;
		if (dist < best_dist) {
			best_dist = dist;
			best = q;
		}
	}
	return best;
}

/** Closest vehicle whose hit-cylinder intersects the weapon cone. */
export function pick_vehicle_target(ctx: HitContext, weapon: WeaponDef, dir: Vec3): VehicleTarget | null {
	const aim: Vec3 = vec_normalize(dir);
	if (aim[0] === 0 && aim[1] === 0 && aim[2] === 0) return null;
	let best: VehicleTarget | null = null;
	let best_dist: number = Number.POSITIVE_INFINITY;
	const cone_tan: number = Math.tan((weapon.cone_deg * Math.PI) / 180);
	for (const v of vehicles.values()) {
		if (!v.alive) continue;
		if (ctx.exclude_vehicle_id !== undefined && v.id === ctx.exclude_vehicle_id) continue;
		const delta: Vec3 = vec_sub(v.pos, ctx.shooter_pos);
		const along: number = vec_dot(delta, aim);
		if (along < 0 || along > weapon.range_meters) continue;
		const closest: Vec3 = vec_scale(aim, along);
		const perpendicular: number = vec_len(vec_sub(delta, closest));
		const radius: number = get_vehicle_spec(v.id)?.hit_radius_m ?? 2.0;
		const cone_slack: number = cone_tan * Math.max(along, 0);
		if (perpendicular > radius + cone_slack) continue;
		if (along < best_dist) {
			best_dist = along;
			best = { vehicle: v, distance: along };
		}
	}
	return best;
}
