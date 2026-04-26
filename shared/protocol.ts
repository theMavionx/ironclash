// Wire protocol shared between Node server, Godot client (mirrored as
// dictionaries), and React UI (for HUD-level events). Every message is a
// JSON object with a discriminator field `t`. Vectors are tuples of numbers
// instead of objects to keep JSON small and parsing trivial in GDScript.
//
// Implements: docs/architecture/adr-0005-node-authoritative-server.md
//
// IMPORTANT: every change here is a breaking wire change. Bump
// `PROTOCOL_VERSION` and update both server/ and src/networking/network_manager.gd.

export const PROTOCOL_VERSION: string = "0.1.0";

export type Team = "red" | "blue";

export type MatchState = "waiting" | "warmup" | "in_progress" | "post_match";

export type Vec3 = [number, number, number];
export type Vec2 = [number, number];

// =====================================================================
// Client → Server
// =====================================================================

export interface C2SHello {
	t: "hello";
	client_version: string;
	protocol_version: string;
}

export interface C2STransform {
	t: "transform";
	pos: Vec3;
	rot_y: number;       // body yaw (radians)
	aim_pitch: number;   // camera pitch (radians)
	vel: Vec3;
	client_t: number;    // client time in ms (Time.get_ticks_msec on Godot)
	/** "idle" | "walk" | "sprint" | "crouch" | "ads" | "airborne". Optional;
	 *  servers default to "idle" when missing for older clients. */
	move_state?: string;
}

export interface C2SInput {
	t: "input";
	seq: number;
	move: Vec2;          // [strafe, forward], each in [-1, 1]
	fire: boolean;
	reload: boolean;
	sprint: boolean;
	jump: boolean;
	crouch: boolean;
	ads: boolean;
}

export interface C2SFire {
	t: "fire";
	seq: number;
	weapon: string;
	origin: Vec3;
	dir: Vec3;
	client_t: number;
}

export interface C2SAnimState {
	t: "anim_state";
	state: string;       // idle | run | sprint | aim | fire | reload | death | jump
	weapon?: string;
}

export interface C2SVehicleEnter {
	t: "vehicle_enter";
	vehicle_id: string;
}

export interface C2SVehicleExit {
	t: "vehicle_exit";
}

export interface C2SVehicleTransform {
	t: "vehicle_transform";
	vehicle_id: string;
	pos: Vec3;
	rot: Vec3;          // euler (x, y, z) radians
	vel: Vec3;
	client_t: number;
}

export interface C2SVehicleFire {
	t: "vehicle_fire";
	vehicle_id: string;
	projectile: "tank_shell" | "heli_missile";
	origin: Vec3;
	dir: Vec3;
	client_t: number;
}

/** Driver-initiated self-destruct (e.g. drone kamikaze impact). Server treats
 *  it as the vehicle taking lethal damage so the existing explosion + smoke
 *  broadcasts fire, no special VFX path needed on clients. */
export interface C2SVehicleSelfDestruct {
	t: "vehicle_self_destruct";
	vehicle_id: string;
}

/** Vehicle-weapon hit claim — driver client reports a local impact, server
 *  validates (driver, distance, cooldown) and applies authoritative damage.
 *  Used for tank shells, heli missiles, drone kamikaze. Closes the loop on
 *  vehicle→player and vehicle→vehicle damage authority. */
export interface C2SVehicleHitClaim {
	t: "vehicle_hit_claim";
	/** Projectile id from server-side PROJECTILE_REGISTRY. */
	projectile: "tank_shell" | "heli_missile" | "drone_kamikaze";
	/** Source vehicle (must be driven by claimer). Omit for non-vehicle drones
	 *  that ride directly on the player record (none yet). */
	vehicle_id?: string;
	/** Exactly one of these two should be set per claim. */
	target_peer_id?: number;
	target_vehicle_id?: string;
	hit_pos?: Vec3;
	client_t: number;
}

export interface C2SPing {
	t: "ping";
	client_t: number;
}

export type C2S =
	| C2SHello
	| C2STransform
	| C2SInput
	| C2SFire
	| C2SAnimState
	| C2SVehicleEnter
	| C2SVehicleExit
	| C2SVehicleTransform
	| C2SVehicleFire
	| C2SVehicleSelfDestruct
	| C2SVehicleHitClaim
	| C2SPing;

// =====================================================================
// Server → Client
// =====================================================================

export interface S2CWelcome {
	t: "welcome";
	peer_id: number;
	team: Team;
	max_per_team: number;
	tick_hz: number;
	protocol_version: string;
}

export interface S2CMatchState {
	t: "match_state";
	state: MatchState;
	time_remaining: number;   // seconds
	red_score: number;
	blue_score: number;
	red_count: number;
	blue_count: number;
}

export interface SnapshotPlayer {
	id: number;
	team: Team;
	pos: Vec3;
	rot_y: number;
	aim_pitch: number;
	hp: number;
	max_hp: number;
	alive: boolean;
	weapon: string;
	move_state: string;  // "idle"/"walk"/"sprint"/"crouch"/"ads"/"airborne"
}

export interface SnapshotVehicle {
	id: string;
	pos: Vec3;
	rot: Vec3;          // euler (x, y, z) radians
	driver_peer_id: number;  // -1 = no driver
	hp: number;
	max_hp: number;
	alive: boolean;
}

export interface S2CSnapshot {
	t: "snapshot";
	tick: number;
	server_t: number;
	players: SnapshotPlayer[];
	vehicles: SnapshotVehicle[];
}

export interface S2CPlayerJoined {
	t: "player_joined";
	peer_id: number;
	team: Team;
}

export interface S2CPlayerLeft {
	t: "player_left";
	peer_id: number;
}

export interface S2CDamage {
	t: "damage";
	victim: number;
	attacker: number;
	amount: number;
	new_hp: number;
	weapon: string;
	headshot: boolean;
}

export interface S2CDeath {
	t: "death";
	victim: number;
	killer: number;
	weapon: string;
}

export interface S2CRespawn {
	t: "respawn";
	peer_id: number;
	pos: Vec3;
	team: Team;
}

export type VfxKind =
	| "muzzle_flash"
	| "bullet_impact"
	| "explosion"
	| "smoke_fire_start"
	| "smoke_fire_stop"
	| "vehicle_fire";

export interface S2CVfxEvent {
	t: "vfx_event";
	kind: VfxKind;
	peer_id?: number;
	pos?: Vec3;
	dir?: Vec3;
	weapon?: string;
	entity_id?: number | string;
	/** For kind="vehicle_fire": which projectile scene to spawn. */
	projectile?: "tank_shell" | "heli_missile";
	/** For kind="vehicle_fire": vehicle the projectile came from. */
	vehicle_id?: string;
}

export interface S2CAnimEvent {
	t: "anim_event";
	peer_id: number;
	state: string;
	weapon?: string;
}

export interface S2CKicked {
	t: "kicked";
	reason: string;
}

export interface S2CPong {
	t: "pong";
	client_t: number;
	server_t: number;
}

export type S2C =
	| S2CWelcome
	| S2CMatchState
	| S2CSnapshot
	| S2CPlayerJoined
	| S2CPlayerLeft
	| S2CDamage
	| S2CDeath
	| S2CRespawn
	| S2CVfxEvent
	| S2CAnimEvent
	| S2CKicked
	| S2CPong;
