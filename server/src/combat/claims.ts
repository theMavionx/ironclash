// Vehicle weapon damage authority via "hit claim" pattern.
//
// Per ADR-0005 the server can't run real projectile physics (no map geometry),
// so the driver client reports impacts as `vehicle_hit_claim` packets and the
// server validates with cheap checks:
//
//   - claimer must be the registered driver of the firing vehicle
//   - target (player or vehicle) must be alive
//   - distance shooter→target ≤ projectile_max_range
//   - cooldown since last claim ≥ projectile_min_interval
//
// Validated → apply_player_damage / apply_vehicle_damage exactly the same as
// player-gun hits. Hit-through-walls is the known compromise (ADR-0005).

import type { Vec3 } from "../../../shared/protocol.ts";
import type { Player } from "../state/players.ts";
import { players } from "../state/players.ts";
import { vehicles } from "../state/vehicles.ts";
import { vec_dist } from "../util/vec.ts";
import { apply_player_damage, apply_vehicle_damage } from "./damage.ts";
import { make_logger } from "../util/log.ts";

const log = make_logger("claim");

export interface ProjectileSpec {
	display_name: string;
	damage_player: number;
	damage_vehicle: number;
	range_meters: number;
	min_interval_ms: number;     // anti-spam: server drops claims faster than this
}

/** All vehicle / kamikaze projectiles that come through `vehicle_hit_claim`.
 *  Add a new ammo type by appending one entry — handlers and clients pick it
 *  up via the wire id. */
export const PROJECTILE_REGISTRY: Record<string, ProjectileSpec> = {
	player_rpg:     { display_name: "Player RPG",     damage_player: 120, damage_vehicle: 200, range_meters: 200, min_interval_ms: 2400 },
	tank_shell:     { display_name: "Tank Shell",     damage_player: 100, damage_vehicle: 220, range_meters: 200, min_interval_ms: 350 },
	heli_missile:   { display_name: "Heli Missile",   damage_player: 60,  damage_vehicle: 80,  range_meters: 250, min_interval_ms: 200 },
	drone_kamikaze: { display_name: "Drone Kamikaze", damage_player: 999, damage_vehicle: 999, range_meters: 5,   min_interval_ms: 5000 },
};

/** Per-(peer × projectile) last-claim timestamp. Plain Map keyed by composite
 *  string — the volume is small (10 peers × 3 projectiles). */
const _last_claim_ms: Map<string, number> = new Map();

function claim_key(peer_id: number, projectile: string): string {
	return `${peer_id}|${projectile}`;
}

export interface ClaimRequest {
	shooter: Player;
	projectile: string;            // PROJECTILE_REGISTRY key
	vehicle_id?: string;           // "tank" / "helicopter" — validates driver match
	target_peer_id?: number;       // player victim
	target_vehicle_id?: string;    // vehicle victim
	hit_pos?: Vec3;                // optional: client-reported impact location
}

export type ClaimResult =
	| { ok: true; what: "player" | "vehicle"; victim_id: string }
	| { ok: false; reason: string };

/** Validate a hit claim and apply damage. */
export function process_hit_claim(req: ClaimRequest): ClaimResult {
	const spec: ProjectileSpec | undefined = PROJECTILE_REGISTRY[req.projectile];
	if (spec === undefined) return { ok: false, reason: "unknown_projectile" };

	// Driver-only firing for vehicle weapons. Drones identify themselves the
	// same way (vehicle_id="drone").
	if (req.vehicle_id !== undefined) {
		const v = vehicles.get(req.vehicle_id);
		if (v === undefined) return { ok: false, reason: "unknown_vehicle" };
		if (v.driver_peer_id !== req.shooter.peer_id) return { ok: false, reason: "not_driver" };
	}

	// Anti-spam: minimum interval between claims of the same projectile from
	// this peer. Slack of 5 ms keeps legit at-cap shooters honest.
	const now: number = Date.now();
	const key: string = claim_key(req.shooter.peer_id, req.projectile);
	const last: number = _last_claim_ms.get(key) ?? 0;
	if (now - last < spec.min_interval_ms - 5) {
		return { ok: false, reason: "cooldown" };
	}
	_last_claim_ms.set(key, now);

	// Apply damage to whichever target was claimed (priority: explicit player
	// claim, then vehicle). Range gated on shooter→target distance.
	if (req.target_peer_id !== undefined) {
		const victim: Player | undefined = players.get(req.target_peer_id);
		if (victim === undefined) return { ok: false, reason: "unknown_player_target" };
		if (!victim.alive) return { ok: false, reason: "victim_dead" };
		const dist: number = vec_dist(req.shooter.pos, victim.pos);
		if (dist > spec.range_meters) {
			log.warn(`reject peer=${req.shooter.peer_id} ${req.projectile} → P${victim.peer_id} dist=${dist.toFixed(1)} > ${spec.range_meters}`);
			return { ok: false, reason: "out_of_range" };
		}
		apply_player_damage(victim, req.shooter.peer_id, req.shooter.team, spec.damage_player, req.projectile);
		return { ok: true, what: "player", victim_id: String(victim.peer_id) };
	}

	if (req.target_vehicle_id !== undefined) {
		const v = vehicles.get(req.target_vehicle_id);
		if (v === undefined) return { ok: false, reason: "unknown_vehicle_target" };
		if (!v.alive) return { ok: false, reason: "vehicle_already_dead" };
		const dist: number = vec_dist(req.shooter.pos, v.pos);
		if (dist > spec.range_meters) {
			log.warn(`reject peer=${req.shooter.peer_id} ${req.projectile} → ${v.id} dist=${dist.toFixed(1)} > ${spec.range_meters}`);
			return { ok: false, reason: "out_of_range" };
		}
		apply_vehicle_damage(v, req.shooter.peer_id, spec.damage_vehicle, req.projectile);
		return { ok: true, what: "vehicle", victim_id: v.id };
	}

	return { ok: false, reason: "no_target" };
}
