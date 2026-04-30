import assert from "node:assert/strict";
import test from "node:test";

import type { Team, Vec3, ZoneOwner } from "../../shared/protocol.ts";
import { cfg } from "../src/config.ts";
import {
	get_control_point_snapshot,
	reset_control_points,
	tick_control_points,
} from "../src/state/control_points.ts";
import type { Player } from "../src/state/players.ts";
import { players } from "../src/state/players.ts";
import { reset_all_vehicles, vehicles } from "../src/state/vehicles.ts";

const ALPHA = cfg.match.control_points.find((point) => point.id === "alpha");
assert.ok(ALPHA, "alpha control point must exist");

const FAR_AWAY: Vec3 = [999, 0, 999];

function reset_world(): void {
	players.clear();
	reset_all_vehicles();
	reset_control_points();
}

function add_player(peer_id: number, team: Team, pos: Vec3, alive: boolean = true): Player {
	const player: Player = {
		peer_id,
		ws: {} as Player["ws"],
		team,
		display_name: `Player${peer_id}`,
		alive,
		hp: alive ? 100 : 0,
		max_hp: 100,
		pos: [...pos],
		rot_y: 0,
		aim_pitch: 0,
		last_seen_ms: 0,
		last_transform_ms: 0,
		hello_received: true,
		last_fire_ms: new Map(),
		respawn_at_ms: 0,
		clamp_warnings: 0,
		weapon: "ak",
		move_state: "idle",
	};
	players.set(peer_id, player);
	return player;
}

function alpha_state(): {
	owner: ZoneOwner;
	capture_team: ZoneOwner;
	capture_progress: number;
} {
	const zone = get_control_point_snapshot().find((point) => point.id === "alpha");
	assert.ok(zone, "alpha control point snapshot must exist");
	return {
		owner: zone.owner,
		capture_team: zone.capture_team,
		capture_progress: zone.capture_progress,
	};
}

function assert_progress(actual: number, expected: number): void {
	assert.ok(
		Math.abs(actual - expected) < 0.0001,
		`expected progress ${expected}, got ${actual}`,
	);
}

test("a single attacker captures a neutral point after the full capture duration", () => {
	reset_world();
	add_player(1, "red", ALPHA.pos);

	tick_control_points(ALPHA.capture_seconds * 0.5);
	assert.deepEqual(alpha_state(), {
		owner: "neutral",
		capture_team: "red",
		capture_progress: 0.5,
	});

	tick_control_points(ALPHA.capture_seconds * 0.5);
	assert.deepEqual(alpha_state(), {
		owner: "red",
		capture_team: "neutral",
		capture_progress: 0,
	});
});

test("leaving a point pauses partial capture instead of continuing or resetting", () => {
	reset_world();
	add_player(1, "red", ALPHA.pos);

	tick_control_points(2);
	const paused_progress = alpha_state().capture_progress;

	players.clear();
	tick_control_points(30);
	const paused = alpha_state();
	assert.equal(paused.owner, "neutral");
	assert.equal(paused.capture_team, "red");
	assert_progress(paused.capture_progress, paused_progress);

	add_player(1, "red", ALPHA.pos);
	tick_control_points(ALPHA.capture_seconds * (1 - paused_progress));
	assert.equal(alpha_state().owner, "red");
});

test("opposing teams inside the same point freeze the current capture progress", () => {
	reset_world();
	add_player(1, "red", ALPHA.pos);

	tick_control_points(2);
	const paused_progress = alpha_state().capture_progress;

	add_player(2, "blue", ALPHA.pos);
	tick_control_points(30);
	const contested = alpha_state();
	assert.equal(contested.owner, "neutral");
	assert.equal(contested.capture_team, "red");
	assert_progress(contested.capture_progress, paused_progress);

	players.delete(2);
	tick_control_points(ALPHA.capture_seconds * (1 - paused_progress));
	assert.equal(alpha_state().owner, "red");
});

test("a different attacker team starts its own capture from zero", () => {
	reset_world();
	add_player(1, "red", ALPHA.pos);

	tick_control_points(2);
	players.clear();
	add_player(2, "blue", ALPHA.pos);

	tick_control_points(0.5);
	const state = alpha_state();
	assert.equal(state.owner, "neutral");
	assert.equal(state.capture_team, "blue");
	assert_progress(state.capture_progress, 0.5 / ALPHA.capture_seconds);
});

test("the owning team clears an enemy partial capture by entering alone", () => {
	reset_world();
	add_player(1, "red", ALPHA.pos);
	tick_control_points(ALPHA.capture_seconds);
	assert.equal(alpha_state().owner, "red");

	players.clear();
	add_player(2, "blue", ALPHA.pos);
	tick_control_points(2);
	assert.equal(alpha_state().capture_team, "blue");

	players.clear();
	add_player(1, "red", ALPHA.pos);
	tick_control_points(0.1);
	assert.deepEqual(alpha_state(), {
		owner: "red",
		capture_team: "neutral",
		capture_progress: 0,
	});
});

test("a driver captures from the driven vehicle position, not their parked body", () => {
	reset_world();
	const tank = vehicles.get("tank");
	assert.ok(tank, "tank vehicle must exist");

	add_player(1, "blue", FAR_AWAY);
	tank.driver_peer_id = 1;
	tank.pos = [...ALPHA.pos];
	tick_control_points(ALPHA.capture_seconds);
	assert.equal(alpha_state().owner, "blue");

	reset_world();
	const reset_tank = vehicles.get("tank");
	assert.ok(reset_tank, "tank vehicle must exist after reset");
	add_player(1, "blue", ALPHA.pos);
	reset_tank.driver_peer_id = 1;
	reset_tank.pos = [...FAR_AWAY];
	tick_control_points(ALPHA.capture_seconds);
	assert.equal(alpha_state().owner, "neutral");
});
