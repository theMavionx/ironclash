// Server-side balance config: loaded once at boot from
// `assets/data/balance/{match,weapons}.json`. Env-var overrides apply on top.
//
// Adding a new tunable knob:
//   1. Add the field + default to MatchConfig / WeaponDef.
//   2. Add the JSON entry in assets/data/balance/.
//   3. Use `cfg.match.<knob>` from any module — no globals.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { make_logger } from "./util/log.ts";
import type { Vec3 } from "../../shared/protocol.ts";

const log = make_logger("cfg");

const BALANCE_DIR: string = resolve(import.meta.dirname, "../../assets/data/balance");

export interface WeaponDef {
	display_name: string;
	damage: number;
	headshot_multiplier: number;
	range_meters: number;
	fire_rate_hz: number;
	cone_deg: number;
	/** True (default) = instant cone-pick at fire. False = projectile travels
	 *  on the client; damage applied via `vehicle_hit_claim` on impact. */
	is_hitscan?: boolean;
}

export interface WeaponsRegistry {
	[id: string]: WeaponDef;
}

export interface MatchConfig {
	max_per_team: number;
	min_per_team_to_start: number;
	max_total: number;
	starting_hp: number;
	respawn_delay_seconds: number;
	tick_hz: number;
	red_spawn: Vec3;
	blue_spawn: Vec3;
	max_horizontal_speed_mps: number;
	position_jitter_tolerance_m: number;
	warmup_seconds: number;
	match_duration_seconds: number;
	post_match_seconds: number;
	kill_cap_per_team: number;
}

const DEFAULT_MATCH: MatchConfig = {
	max_per_team: 5,
	min_per_team_to_start: 3,
	max_total: 10,
	starting_hp: 100,
	respawn_delay_seconds: 5.0,
	tick_hz: 30,
	red_spawn: [-20, 1, 0],
	blue_spawn: [20, 1, 0],
	max_horizontal_speed_mps: 12.0,
	position_jitter_tolerance_m: 0.5,
	warmup_seconds: 5.0,
	match_duration_seconds: 120.0,
	post_match_seconds: 10.0,
	kill_cap_per_team: 30,
};

const DEFAULT_WEAPONS: WeaponsRegistry = {
	ak: { display_name: "AK", damage: 25, headshot_multiplier: 2, range_meters: 100, fire_rate_hz: 10, cone_deg: 3 },
};

function load_json<T>(filename: string, fallback: T): T {
	try {
		const path: string = resolve(BALANCE_DIR, filename);
		const raw: string = readFileSync(path, "utf-8");
		const parsed: unknown = JSON.parse(raw);
		log.info(`loaded ${filename}`);
		return parsed as T;
	} catch (e) {
		const err: Error = e instanceof Error ? e : new Error(String(e));
		log.warn(`${filename} load failed: ${err.message} — using defaults`);
		return fallback;
	}
}

const matchCfg: MatchConfig = load_json("match.json", DEFAULT_MATCH);
const weaponsCfg: WeaponsRegistry = load_json("weapons.json", DEFAULT_WEAPONS);

export const cfg = {
	match: matchCfg,
	weapons: weaponsCfg,
	port: Number(process.env.IRONCLASH_PORT ?? 9080),
	host: process.env.IRONCLASH_HOST ?? "0.0.0.0",
	tick_hz: Number(process.env.IRONCLASH_TICK_HZ ?? matchCfg.tick_hz),
	get tick_ms(): number { return 1000 / this.tick_hz; },
};

// Per-frame ceilings shared by validators across modules.
export const LIMITS = {
	max_frame_bytes: 4096,
	max_pos_axis: 10000,
	max_vel_axis: 200,
	cooldown_slack_ms: 5,
	move_state_max_chars: 16,
	dir_unit_tolerance: 1.5,
	rot_max_radians: 100,
} as const;
