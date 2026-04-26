// Vehicle roster + registry. The registry is the single source of truth —
// adding a new vehicle (say, a jeep) is one entry here, no other file needs
// editing on the server side.

import type { Vec3 } from "../../../shared/protocol.ts";

export interface Vehicle {
	id: string;
	pos: Vec3;
	rot: Vec3;
	driver_peer_id: number;   // -1 = no driver
	hp: number;
	max_hp: number;
	alive: boolean;
	last_update_ms: number;
}

export interface VehicleTarget {
	vehicle: Vehicle;
	distance: number;
}

/** Per-vehicle authoritative metadata. `hit_radius_m` is the cylinder radius
 *  the cone-pick uses; `spawn_pos` is where the server thinks the vehicle
 *  starts the match (matches Main.tscn's transform so fresh-connect snapshots
 *  don't teleport client meshes). */
export interface VehicleSpec {
	id: string;
	max_hp: number;
	hit_radius_m: number;
	spawn_pos: Vec3;
}

/** ADD A NEW VEHICLE HERE — no other server file needs changing. */
export const VEHICLE_REGISTRY: VehicleSpec[] = [
	{ id: "tank",       max_hp: 600, hit_radius_m: 3.6, spawn_pos: [-20.0656, 10.3083, -0.120736] },
	{ id: "helicopter", max_hp: 400, hit_radius_m: 3.2, spawn_pos: [-2.93867, 12.3792, -26.1676] },
	{ id: "drone",      max_hp: 50,  hit_radius_m: 1.2, spawn_pos: [-15.1088, 23.3642, 0.392877] },
];

export const vehicles: Map<string, Vehicle> = new Map();
const _spec_by_id: Map<string, VehicleSpec> = new Map();

for (const spec of VEHICLE_REGISTRY) {
	_spec_by_id.set(spec.id, spec);
	vehicles.set(spec.id, {
		id: spec.id,
		pos: [...spec.spawn_pos],
		rot: [0, 0, 0],
		driver_peer_id: -1,
		hp: spec.max_hp,
		max_hp: spec.max_hp,
		alive: true,
		last_update_ms: 0,
	});
}

export function get_vehicle_spec(id: string): VehicleSpec | undefined {
	return _spec_by_id.get(id);
}

/** Free any vehicles that this peer was driving. Idempotent — safe to call on
 *  disconnect even if the peer wasn't driving anything. */
export function vacate_driver(peer_id: number): void {
	for (const v of vehicles.values()) {
		if (v.driver_peer_id === peer_id) v.driver_peer_id = -1;
	}
}

/** Reset all vehicles to full HP / alive. Called when a new match starts. */
export function reset_all_vehicles(): void {
	for (const v of vehicles.values()) {
		const spec: VehicleSpec | undefined = _spec_by_id.get(v.id);
		v.hp = v.max_hp;
		v.alive = true;
		// Park at the canonical spawn so wreckage from last round doesn't ghost.
		if (spec !== undefined) {
			v.pos = [...spec.spawn_pos];
			v.rot = [0, 0, 0];
		}
	}
}
