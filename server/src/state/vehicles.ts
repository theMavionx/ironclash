// Vehicle roster + registry. The registry is the single source of truth —
// adding a new vehicle (say, a jeep) is one entry here, no other file needs
// editing on the server side.

import type { Vec3 } from "../../../shared/protocol.ts";

export interface Vehicle {
	id: string;
	pos: Vec3;
	rot: Vec3;
	aim_yaw: number;
	aim_pitch: number;
	driver_peer_id: number;   // -1 = no driver
	hp: number;
	max_hp: number;
	alive: boolean;
	respawn_at_ms: number;
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
	spawn_rot: Vec3;
	respawn_delay_seconds: number;
}

/** ADD A NEW VEHICLE HERE — no other server file needs changing. */
export const VEHICLE_REGISTRY: VehicleSpec[] = [
	{ id: "tank",        max_hp: 600, hit_radius_m: 2.52, spawn_pos: [7.00124, 10, 23.6674],        spawn_rot: [0, -2.789559, 0], respawn_delay_seconds: 20 },
	{ id: "tank2",       max_hp: 600, hit_radius_m: 2.52, spawn_pos: [9.40532, 10, 30.2121],        spawn_rot: [0, -2.789559, 0], respawn_delay_seconds: 20 },
	{ id: "tank3",       max_hp: 600, hit_radius_m: 2.52, spawn_pos: [-14.2364, 10, -80.3324],      spawn_rot: [0, 0.399662, 0], respawn_delay_seconds: 20 },
	{ id: "tank4",       max_hp: 600, hit_radius_m: 2.52, spawn_pos: [-16.7427, 10, -86.2658],      spawn_rot: [0, 0.399662, 0], respawn_delay_seconds: 20 },
	{ id: "helicopter",  max_hp: 400, hit_radius_m: 2.56, spawn_pos: [26.5641, 13.7194, 45.9781],  spawn_rot: [0, -2.760955, 0], respawn_delay_seconds: 45 },
	{ id: "helicopter2", max_hp: 400, hit_radius_m: 2.56, spawn_pos: [-33.2199, 13.642, -100.473], spawn_rot: [0, 0.317371, 0], respawn_delay_seconds: 45 },
	{ id: "drone",       max_hp: 50,  hit_radius_m: 1.2, spawn_pos: [-15.1088, 23.3642, 0.392877], spawn_rot: [0, 0, 0], respawn_delay_seconds: 10 },
];

export const vehicles: Map<string, Vehicle> = new Map();
const _spec_by_id: Map<string, VehicleSpec> = new Map();
const _scene_spawn_synced_ids: Set<string> = new Set();

for (const spec of VEHICLE_REGISTRY) {
	_spec_by_id.set(spec.id, spec);
	vehicles.set(spec.id, {
		id: spec.id,
		pos: [...spec.spawn_pos],
		rot: [...spec.spawn_rot],
		aim_yaw: spec.spawn_rot[1],
		aim_pitch: 0,
		driver_peer_id: -1,
		hp: spec.max_hp,
		max_hp: spec.max_hp,
		alive: true,
		respawn_at_ms: 0,
		last_update_ms: 0,
	});
}

export function get_vehicle_spec(id: string): VehicleSpec | undefined {
	return _spec_by_id.get(id);
}

export function sync_vehicle_spawn_from_scene(
	id: string,
	pos: Vec3,
	rot: Vec3,
	aim_yaw: number,
	aim_pitch: number,
): boolean {
	if (_scene_spawn_synced_ids.has(id)) return false;
	const spec: VehicleSpec | undefined = _spec_by_id.get(id);
	const v: Vehicle | undefined = vehicles.get(id);
	if (spec === undefined || v === undefined) return false;
	spec.spawn_pos = [...pos];
	spec.spawn_rot = [...rot];
	v.pos = [...pos];
	v.rot = [...rot];
	v.aim_yaw = aim_yaw;
	v.aim_pitch = aim_pitch;
	v.last_update_ms = 0;
	_scene_spawn_synced_ids.add(id);
	return true;
}

export function request_vehicle_respawn(vehicle: Vehicle, now_ms: number = Date.now()): void {
	const spec: VehicleSpec | undefined = _spec_by_id.get(vehicle.id);
	if (spec === undefined) return;
	vehicle.respawn_at_ms = now_ms + spec.respawn_delay_seconds * 1000;
}

export function check_vehicle_respawns(now_ms: number): Vehicle[] {
	const respawned: Vehicle[] = [];
	for (const v of vehicles.values()) {
		if (v.alive || v.respawn_at_ms === 0 || now_ms < v.respawn_at_ms) continue;
		const spec: VehicleSpec | undefined = _spec_by_id.get(v.id);
		if (spec === undefined) continue;
		v.hp = v.max_hp;
		v.alive = true;
		v.driver_peer_id = -1;
		v.pos = [...spec.spawn_pos];
		v.rot = [...spec.spawn_rot];
		v.aim_yaw = spec.spawn_rot[1];
		v.aim_pitch = 0;
		v.respawn_at_ms = 0;
		v.last_update_ms = 0;
		respawned.push(v);
	}
	return respawned;
}

/** Free any vehicles that this peer was driving. Idempotent — safe to call on
 *  disconnect even if the peer wasn't driving anything. */
export function vacate_driver(peer_id: number): void {
	for (const v of vehicles.values()) {
		if (v.driver_peer_id === peer_id) v.driver_peer_id = -1;
	}
}

/** Reset all vehicles to full HP / alive. Called when a new match starts. */
export function reset_all_vehicles(allow_scene_resync: boolean = false): void {
	if (allow_scene_resync) {
		_scene_spawn_synced_ids.clear();
	}
	for (const v of vehicles.values()) {
		const spec: VehicleSpec | undefined = _spec_by_id.get(v.id);
		v.hp = v.max_hp;
		v.alive = true;
		v.driver_peer_id = -1;
		v.respawn_at_ms = 0;
		v.last_update_ms = 0;
		// Park at the canonical spawn so wreckage from last round doesn't ghost.
		if (spec !== undefined) {
			v.pos = [...spec.spawn_pos];
			v.rot = [...spec.spawn_rot];
			v.aim_yaw = spec.spawn_rot[1];
			v.aim_pitch = 0;
		}
	}
}
