// Concrete dispatch table. Each `register_handler(...)` here adds one C2S
// type. Handlers are short — heavy lifting lives in combat/state modules.

import { LIMITS } from "../config.ts";
import { cfg } from "../config.ts";
import { is_finite_vec3, vec_dist } from "../util/vec.ts";
import type { Player } from "../state/players.ts";
import { normalize_display_name, players } from "../state/players.ts";
import { request_vehicle_respawn, sync_vehicle_spawn_from_scene, vehicles } from "../state/vehicles.ts";
import type { Vec3 } from "../../../shared/protocol.ts";
import { broadcast, kick, send } from "./socket.ts";
import { register_handler } from "./dispatch.ts";
import { PROTOCOL_VERSION } from "./protocol_version.ts";
import { broadcast_match_state } from "../state/match.ts";
import { pick_player_target, pick_vehicle_target } from "../combat/targeting.ts";
import { apply_player_damage, apply_vehicle_damage } from "../combat/damage.ts";
import { process_hit_claim } from "../combat/claims.ts";
import { make_logger } from "../util/log.ts";

const log_net = make_logger("net");
const log_veh = make_logger("veh");

// ---------------------------------------------------------------------------
// Speed clamp (anti-teleport). Lives here because it only fires inside the
// transform handler — extracting it to its own module would be over-design.
// ---------------------------------------------------------------------------

function clamp_transform_step(p: Player, requested: Vec3, now_ms: number): Vec3 {
	if (p.last_transform_ms === 0) return requested;
	const dt: number = Math.max(0.001, (now_ms - p.last_transform_ms) / 1000);
	const dx: number = requested[0] - p.pos[0];
	const dz: number = requested[2] - p.pos[2];
	const horiz_dist: number = Math.sqrt(dx * dx + dz * dz);
	const max_step: number = cfg.match.max_horizontal_speed_mps * dt + cfg.match.position_jitter_tolerance_m;
	if (horiz_dist <= max_step) return requested;
	const scale: number = max_step / horiz_dist;
	p.clamp_warnings++;
	if (p.clamp_warnings === 1 || p.clamp_warnings % 30 === 0) {
		log_net.warn(`anticheat: peer=${p.peer_id} step ${horiz_dist.toFixed(2)}m > cap ${max_step.toFixed(2)}m (n=${p.clamp_warnings})`);
	}
	return [p.pos[0] + dx * scale, requested[1], p.pos[2] + dz * scale];
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

export function register_all_handlers(): void {
	register_handler("hello", (p, msg) => {
		if (msg.protocol_version !== PROTOCOL_VERSION) {
			kick(p, `protocol_mismatch:client=${msg.protocol_version}_server=${PROTOCOL_VERSION}`);
			return;
		}
		const first_hello: boolean = !p.hello_received;
		p.hello_received = true;
		p.display_name = normalize_display_name(msg.display_name, p.peer_id);
		send(p.ws, {
			t: "welcome",
			peer_id: p.peer_id,
			team: p.team,
			display_name: p.display_name,
			max_per_team: cfg.match.max_per_team,
			tick_hz: cfg.tick_hz,
			protocol_version: PROTOCOL_VERSION,
		});
		if (first_hello) {
			broadcast({ t: "player_joined", peer_id: p.peer_id, team: p.team, display_name: p.display_name }, p.peer_id);
			broadcast_match_state(Date.now());
		}
		log_net.info(`hello peer=${p.peer_id} name="${p.display_name}" client=${msg.client_version} proto=${msg.protocol_version}`);
	});

	register_handler("transform", (p, msg) => {
		if (!p.alive) return;
		if (!is_finite_vec3(msg.pos, LIMITS.max_pos_axis)) { kick(p, "bad_transform_pos"); return; }
		if (!is_finite_vec3(msg.vel, LIMITS.max_vel_axis)) { kick(p, "bad_transform_vel"); return; }
		if (typeof msg.rot_y !== "number" || !Number.isFinite(msg.rot_y)) { kick(p, "bad_rot_y"); return; }
		if (typeof msg.aim_pitch !== "number" || !Number.isFinite(msg.aim_pitch)) { kick(p, "bad_aim_pitch"); return; }
		const now: number = Date.now();
		p.pos = clamp_transform_step(p, msg.pos, now);
		p.rot_y = msg.rot_y;
		p.aim_pitch = msg.aim_pitch;
		p.last_transform_ms = now;
		if (typeof msg.move_state === "string"
			&& msg.move_state.length > 0
			&& msg.move_state.length < LIMITS.move_state_max_chars) {
			p.move_state = msg.move_state;
		}
	});

	register_handler("input", (_p, _msg) => { /* reserved for server-auth movement */ });

	register_handler("fire", (p, msg) => {
		if (!p.alive) return;
		if (!is_finite_vec3(msg.origin, LIMITS.max_pos_axis)) { kick(p, "bad_fire_origin"); return; }
		if (!is_finite_vec3(msg.dir, LIMITS.dir_unit_tolerance)) { kick(p, "bad_fire_dir"); return; }
		const weapon = cfg.weapons[msg.weapon];
		if (weapon === undefined || msg.weapon.startsWith("_")) {
			log_net.warn(`unknown weapon "${msg.weapon}" from peer=${p.peer_id}`);
			return;
		}
		const now: number = Date.now();
		const last: number = p.last_fire_ms.get(msg.weapon) ?? 0;
		const cooldown_ms: number = 1000 / weapon.fire_rate_hz;
		if (now - last < cooldown_ms - LIMITS.cooldown_slack_ms) return;
		p.last_fire_ms.set(msg.weapon, now);
		p.weapon = msg.weapon;

		broadcast({ t: "vfx_event", kind: "muzzle_flash", peer_id: p.peer_id, pos: msg.origin, dir: msg.dir, weapon: msg.weapon });
		broadcast({ t: "anim_event", peer_id: p.peer_id, state: "fire", weapon: msg.weapon }, p.peer_id);

		// Hitscan weapons (AK) cone-pick instantly. Projectile weapons (RPG)
		// resolve damage via vehicle_hit_claim from the rocket's local impact.
		if (weapon.is_hitscan ?? true) {
			const shooter_pos: Vec3 = vec_dist(p.pos, msg.origin) <= LIMITS.fire_origin_max_offset_m ? msg.origin : p.pos;
			const ctx = { shooter_pos, shooter_team: p.team, shooter_player_id: p.peer_id };
			const player_target = pick_player_target(ctx, weapon, msg.dir);
			if (player_target !== null) {
				apply_player_damage(player_target, p.peer_id, p.team, weapon.damage, msg.weapon, false);
				return;
			}
			const veh_target = pick_vehicle_target(ctx, weapon, msg.dir);
			if (veh_target !== null) {
				apply_vehicle_damage(veh_target.vehicle, p.peer_id, weapon.damage, msg.weapon);
			}
		}
	});

	register_handler("anim_state", (p, msg) => {
		if (msg.state === "weapon_select" && typeof msg.weapon === "string" && msg.weapon.length > 0) {
			p.weapon = msg.weapon;
		}
		broadcast({ t: "anim_event", peer_id: p.peer_id, state: msg.state, weapon: msg.weapon }, p.peer_id);
	});

	register_handler("vehicle_enter", (p, msg) => {
		const v = vehicles.get(msg.vehicle_id);
		if (v === undefined) { log_veh.warn(`unknown "${msg.vehicle_id}" from peer=${p.peer_id}`); return; }
		if (!v.alive) return;
		if (v.driver_peer_id !== -1 && v.driver_peer_id !== p.peer_id) return;  // already driven
		v.driver_peer_id = p.peer_id;
		log_veh.info(`peer=${p.peer_id} enters ${v.id}`);
	});

	register_handler("vehicle_exit", (p, _msg) => {
		for (const v of vehicles.values()) {
			if (v.driver_peer_id === p.peer_id) {
				v.driver_peer_id = -1;
				log_veh.info(`peer=${p.peer_id} exits ${v.id}`);
			}
		}
	});

	register_handler("vehicle_spawn_sync", (p, msg) => {
		const v = vehicles.get(msg.vehicle_id);
		if (v === undefined || !v.alive) return;
		if (v.driver_peer_id !== -1) return;
		if (v.last_update_ms !== 0) return;
		if (!is_finite_vec3(msg.pos, LIMITS.max_pos_axis)) { kick(p, "bad_vehicle_spawn_pos"); return; }
		if (!is_finite_vec3(msg.rot, LIMITS.rot_max_radians)) { kick(p, "bad_vehicle_spawn_rot"); return; }
		if (msg.aim_yaw !== undefined
			&& (typeof msg.aim_yaw !== "number" || !Number.isFinite(msg.aim_yaw) || Math.abs(msg.aim_yaw) > LIMITS.rot_max_radians)) {
			kick(p, "bad_vehicle_spawn_aim_yaw");
			return;
		}
		if (msg.aim_pitch !== undefined
			&& (typeof msg.aim_pitch !== "number" || !Number.isFinite(msg.aim_pitch) || Math.abs(msg.aim_pitch) > LIMITS.rot_max_radians)) {
			kick(p, "bad_vehicle_spawn_aim_pitch");
			return;
		}
		const synced: boolean = sync_vehicle_spawn_from_scene(
			msg.vehicle_id,
			msg.pos,
			msg.rot,
			msg.aim_yaw ?? msg.rot[1],
			msg.aim_pitch ?? 0,
		);
		if (synced) {
			log_veh.info(`scene spawn sync ${msg.vehicle_id} from peer=${p.peer_id}`);
		}
	});

	register_handler("vehicle_transform", (p, msg) => {
		const v = vehicles.get(msg.vehicle_id);
		if (v === undefined || !v.alive) return;
		if (v.driver_peer_id !== p.peer_id) return;
		if (!is_finite_vec3(msg.pos, LIMITS.max_pos_axis)) { kick(p, "bad_vehicle_pos"); return; }
		if (!is_finite_vec3(msg.rot, LIMITS.rot_max_radians)) { kick(p, "bad_vehicle_rot"); return; }
		if (!is_finite_vec3(msg.vel, LIMITS.max_vel_axis)) { kick(p, "bad_vehicle_vel"); return; }
		if (msg.aim_yaw !== undefined
			&& (typeof msg.aim_yaw !== "number" || !Number.isFinite(msg.aim_yaw) || Math.abs(msg.aim_yaw) > LIMITS.rot_max_radians)) {
			kick(p, "bad_vehicle_aim_yaw");
			return;
		}
		if (msg.aim_pitch !== undefined
			&& (typeof msg.aim_pitch !== "number" || !Number.isFinite(msg.aim_pitch) || Math.abs(msg.aim_pitch) > LIMITS.rot_max_radians)) {
			kick(p, "bad_vehicle_aim_pitch");
			return;
		}
		v.pos = msg.pos;
		v.rot = msg.rot;
		v.aim_yaw = msg.aim_yaw ?? msg.rot[1];
		v.aim_pitch = msg.aim_pitch ?? 0;
		v.last_update_ms = Date.now();
	});

	register_handler("vehicle_self_destruct", (p, msg) => {
		const v = vehicles.get(msg.vehicle_id);
		if (v === undefined || !v.alive) return;
		if (v.driver_peer_id !== p.peer_id) return;
		v.hp = 0;
		v.alive = false;
		v.driver_peer_id = -1;
		request_vehicle_respawn(v);
		const smoke_duration_s: number = Math.max(0, (v.respawn_at_ms - Date.now()) / 1000);
		broadcast({ t: "vfx_event", kind: "explosion", entity_id: v.id, pos: v.pos, weapon: "kamikaze" });
		broadcast({ t: "vfx_event", kind: "smoke_fire_start", entity_id: v.id, pos: v.pos, weapon: "kamikaze", duration: smoke_duration_s });
		log_veh.info(`self-destruct ${v.id} by peer=${p.peer_id}`);
	});

	register_handler("vehicle_fire", (p, msg) => {
		const v = vehicles.get(msg.vehicle_id);
		if (v === undefined || !v.alive) return;
		if (v.driver_peer_id !== p.peer_id) return;
		if (!is_finite_vec3(msg.origin, LIMITS.max_pos_axis)) { kick(p, "bad_vfire_origin"); return; }
		if (!is_finite_vec3(msg.dir, LIMITS.dir_unit_tolerance)) { kick(p, "bad_vfire_dir"); return; }
		if (msg.projectile !== "tank_shell" && msg.projectile !== "heli_missile") return;
		broadcast({
			t: "vfx_event", kind: "vehicle_fire",
			peer_id: p.peer_id, pos: msg.origin, dir: msg.dir,
			vehicle_id: msg.vehicle_id, projectile: msg.projectile,
		}, p.peer_id);
	});

	register_handler("vehicle_hit_claim", (p, msg) => {
		// Validation happens entirely inside process_hit_claim.
		const result = process_hit_claim({
			shooter: p,
			projectile: msg.projectile,
			vehicle_id: msg.vehicle_id,
			target_peer_id: msg.target_peer_id,
			target_vehicle_id: msg.target_vehicle_id,
			hit_pos: msg.hit_pos,
		});
		if (!result.ok) {
			log_net.warn(`hit_claim rejected peer=${p.peer_id} ${msg.projectile}: ${result.reason}`);
		}
	});

	register_handler("ping", (p, msg) => {
		send(p.ws, { t: "pong", client_t: msg.client_t, server_t: Date.now() });
	});
}
