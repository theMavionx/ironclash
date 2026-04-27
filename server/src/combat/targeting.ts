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

const PLAYER_CAPSULE_RADIUS_M = 0.45;
const PLAYER_CAPSULE_HEIGHT_M = 1.8;
const EPSILON = 1e-6;

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
	const cone_tan: number = Math.tan((weapon.cone_deg * Math.PI) / 180);
	let best: Player | null = null;
	let best_dist: number = Number.POSITIVE_INFINITY;
	for (const q of players.values()) {
		if (ctx.shooter_player_id !== undefined && q.peer_id === ctx.shooter_player_id) continue;
		if (ctx.shooter_team !== undefined && q.team === ctx.shooter_team) continue;
		if (!q.alive) continue;

		const capsule_base: Vec3 = q.pos;
		const capsule_top: Vec3 = [q.pos[0], q.pos[1] + PLAYER_CAPSULE_HEIGHT_M, q.pos[2]];
		const hit = ray_capsule_proximity(
			ctx.shooter_pos,
			aim,
			weapon.range_meters,
			capsule_base,
			capsule_top,
		);
		const allowed_radius: number = PLAYER_CAPSULE_RADIUS_M + cone_tan * Math.max(hit.along, 0);
		if (hit.distance > allowed_radius) continue;
		if (hit.along < best_dist) {
			best_dist = hit.along;
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

function ray_capsule_proximity(origin: Vec3, aim: Vec3, range: number, capsule_base: Vec3, capsule_top: Vec3): { along: number; distance: number } {
	const ray_segment: Vec3 = vec_scale(aim, range);
	const capsule_axis: Vec3 = vec_sub(capsule_top, capsule_base);
	const origin_to_base: Vec3 = vec_sub(origin, capsule_base);
	const a: number = vec_dot(ray_segment, ray_segment);
	const e: number = vec_dot(capsule_axis, capsule_axis);
	const f: number = vec_dot(capsule_axis, origin_to_base);
	let ray_t = 0.0;
	let capsule_t = 0.0;

	if (a <= EPSILON && e <= EPSILON) {
		ray_t = 0.0;
		capsule_t = 0.0;
	} else if (a <= EPSILON) {
		ray_t = 0.0;
		capsule_t = clamp01(f / e);
	} else {
		const c: number = vec_dot(ray_segment, origin_to_base);
		if (e <= EPSILON) {
			capsule_t = 0.0;
			ray_t = clamp01(-c / a);
		} else {
			const b: number = vec_dot(ray_segment, capsule_axis);
			const denom: number = a * e - b * b;
			if (Math.abs(denom) > EPSILON) {
				ray_t = clamp01((b * f - c * e) / denom);
			} else {
				ray_t = 0.0;
			}
			capsule_t = (b * ray_t + f) / e;
			if (capsule_t < 0.0) {
				capsule_t = 0.0;
				ray_t = clamp01(-c / a);
			} else if (capsule_t > 1.0) {
				capsule_t = 1.0;
				ray_t = clamp01((b - c) / a);
			}
		}
	}

	const closest_ray: Vec3 = [
		origin[0] + ray_segment[0] * ray_t,
		origin[1] + ray_segment[1] * ray_t,
		origin[2] + ray_segment[2] * ray_t,
	];
	const closest_capsule: Vec3 = [
		capsule_base[0] + capsule_axis[0] * capsule_t,
		capsule_base[1] + capsule_axis[1] * capsule_t,
		capsule_base[2] + capsule_axis[2] * capsule_t,
	];
	return {
		along: ray_t * range,
		distance: vec_len(vec_sub(closest_ray, closest_capsule)),
	};
}

function clamp01(value: number): number {
	if (value < 0.0) return 0.0;
	if (value > 1.0) return 1.0;
	return value;
}
