import assert from "node:assert/strict";
import test from "node:test";

import { cfg } from "../src/config.ts";
import { get_match_state, reset_match, tick_match_state } from "../src/state/match.ts";
import { make_player, players, spawn_for_team } from "../src/state/players.ts";
import { reset_all_vehicles } from "../src/state/vehicles.ts";
import type { Team, Vec3 } from "../../shared/protocol.ts";

function fake_ws(): ReturnType<typeof make_player>["ws"] {
	return {
		readyState: 0,
		bufferedAmount: 0,
		send: () => undefined,
		close: () => undefined,
	} as ReturnType<typeof make_player>["ws"];
}

function distance_xz(a: Vec3, b: Vec3): number {
	const dx = a[0] - b[0];
	const dz = a[2] - b[2];
	return Math.sqrt(dx * dx + dz * dz);
}

function add_player(peer_id: number, team: Team): void {
	const p = make_player(peer_id, fake_ws(), team);
	players.set(peer_id, p);
}

test("match can leave waiting with one player on each team", () => {
	players.clear();
	reset_all_vehicles(true);
	reset_match();

	add_player(1, "red");
	assert.equal(get_match_state(), "waiting");
	tick_match_state(Date.now());
	assert.equal(get_match_state(), "waiting");

	add_player(2, "blue");
	tick_match_state(Date.now() + 100);
	assert.equal(get_match_state(), "warmup");
});

test("base spawns use five separated slots per team", () => {
	for (const team of ["red", "blue"] as const) {
		const slots = team === "red" ? cfg.match.red_spawn_slots : cfg.match.blue_spawn_slots;
		assert.ok(slots !== undefined && slots.length === 5, `${team} has five spawn slots`);
		const spawned = slots.map((_slot, index) => spawn_for_team(team, index));
		for (let i = 0; i < spawned.length; i++) {
			assert.ok(distance_xz(spawned[i], slots[i]) < 0.4, `${team} slot ${i} spawns near authored slot`);
			assert.equal(spawned[i][1], slots[i][1], `${team} slot ${i} keeps authored ground height`);
		}
		for (let i = 1; i < spawned.length; i++) {
			assert.ok(distance_xz(spawned[0], spawned[i]) > 2.0, `${team} slot ${i} is not stacked on slot 0`);
		}
	}
});
