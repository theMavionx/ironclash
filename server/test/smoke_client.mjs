// Smoke test: connect 3 fake clients, run a transcript, validate.
//
// Pass conditions:
//   - All 3 receive `welcome` with peer_id, team in {red, blue}.
//   - Team distribution honors auto-balance (no team gets 3 of 3).
//   - All 3 receive snapshots with their peers visible.
//   - `fire` from client 1 produces `vfx_event` on clients 2 and 3.
//   - AK hitscan damage uses the fire origin, matching the Godot camera ray.
//   - `anim_state` from client 1 produces `anim_event` on clients 2 and 3 (not on 1 itself).
//   - `match_state` flips to `in_progress` once both teams have ≥1.
//   - `kicked: match_full` arrives if we connect 11.

import { WebSocket } from "ws";

const URL = process.env.URL ?? "ws://127.0.0.1:9080";
const NUM_CLIENTS = 3;

class TestClient {
	constructor(label) {
		this.label = label;
		this.ws = new WebSocket(URL);
		this.welcome = null;
		this.peers_seen = new Set();
		this.last_peer_pos = new Map();
		this.snapshots = 0;
		this.match_states = [];
		this.vfx_events = [];
		this.anim_events = [];
		this.kicked = null;
		this.damages = [];
		this.deaths = [];
		this.respawns = [];
		this.opened = new Promise((res, rej) => {
			this.ws.once("open", () => {
				this.ws.send(JSON.stringify({
					t: "hello",
					client_version: "smoke-0.1.0",
					protocol_version: "0.1.0",
				}));
				res();
			});
			this.ws.once("error", rej);
		});
		this.ws.on("message", (data) => {
			let msg;
			try { msg = JSON.parse(data.toString()); } catch { return; }
			if (msg.t === "welcome") this.welcome = msg;
			else if (msg.t === "snapshot") {
				this.snapshots++;
				for (const p of msg.players) {
					this.peers_seen.add(p.id);
					this.last_peer_pos.set(p.id, p.pos);
				}
			}
			else if (msg.t === "match_state") this.match_states.push(msg);
			else if (msg.t === "vfx_event") this.vfx_events.push(msg);
			else if (msg.t === "anim_event") this.anim_events.push(msg);
			else if (msg.t === "damage") this.damages.push(msg);
			else if (msg.t === "death") this.deaths.push(msg);
			else if (msg.t === "respawn") this.respawns.push(msg);
			else if (msg.t === "kicked") this.kicked = msg;
		});
	}
	send(msg) { this.ws.send(JSON.stringify(msg)); }
	close() { this.ws.close(); }
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

const FAILS = [];
function assert(cond, label) {
	if (cond) console.log(`  PASS  ${label}`);
	else { console.log(`  FAIL  ${label}`); FAILS.push(label); }
}

async function main() {
	console.log(`# Connecting ${NUM_CLIENTS} clients to ${URL}`);
	const clients = [];
	for (let i = 0; i < NUM_CLIENTS; i++) {
		clients.push(new TestClient(`c${i+1}`));
	}
	await Promise.all(clients.map(c => c.opened));
	await sleep(400); // welcome + initial match_state should arrive

	console.log("# Welcome packets");
	for (const c of clients) {
		assert(c.welcome != null, `${c.label} got welcome`);
		assert(c.welcome?.team === "red" || c.welcome?.team === "blue", `${c.label} got valid team (${c.welcome?.team})`);
		assert(typeof c.welcome?.peer_id === "number", `${c.label} got numeric peer_id`);
	}

	const teams = clients.map(c => c.welcome?.team);
	const reds = teams.filter(t => t === "red").length;
	const blues = teams.filter(t => t === "blue").length;
	console.log(`# Team distribution: red=${reds} blue=${blues}`);
	assert(Math.abs(reds - blues) <= 1, "auto-balance kept |red-blue| <= 1");

	console.log("# Snapshot reception (1 second)");
	const before = clients.map(c => c.snapshots);
	await sleep(1000);
	for (let i = 0; i < clients.length; i++) {
		const delta = clients[i].snapshots - before[i];
		assert(delta >= 25, `${clients[i].label} snapshots/sec ~= ${delta} (>=25)`);
	}

	console.log("# Cross-client visibility");
	for (const c of clients) {
		assert(c.peers_seen.size === NUM_CLIENTS, `${c.label} sees ${c.peers_seen.size} peers (expect ${NUM_CLIENTS})`);
	}

	console.log("# Match state transitions");
	const last = clients[0].match_states.at(-1);
	if (reds >= 1 && blues >= 1) {
		// First 1v1 trips warmup; warmup → in_progress after warmup_seconds.
		const ok = last?.state === "warmup" || last?.state === "in_progress";
		assert(ok, `match_state warmup or in_progress (got ${last?.state})`);
	} else {
		assert(last?.state === "waiting", `match_state=waiting`);
	}

	console.log("# Fire → vfx_event broadcast");
	const fireBefore = clients.map(c => c.vfx_events.length);
	clients[0].send({ t: "fire", seq: 1, weapon: "ak", origin: [0,1,0], dir: [1,0,0], client_t: Date.now() });
	await sleep(200);
	for (let i = 0; i < clients.length; i++) {
		const delta = clients[i].vfx_events.length - fireBefore[i];
		assert(delta >= 1, `${clients[i].label} got vfx_event after fire (${delta})`);
	}

	console.log("# AK fire origin -> server hitscan damage");
	const shooter = clients.find(c => c.welcome?.team === "red") ?? clients[0];
	const target = clients.find(c => c.welcome?.team !== shooter.welcome?.team);
	assert(target != null, "found an enemy target for AK damage test");
	if (target != null) {
		const damageBefore = target.damages.length;
		shooter.send({
			t: "transform",
			pos: [0, 0, 0],
			rot_y: 0,
			aim_pitch: 0,
			vel: [0, 0, 0],
			client_t: Date.now(),
		});
		target.send({
			t: "transform",
			pos: [0, 1, 20],
			rot_y: Math.PI,
			aim_pitch: 0,
			vel: [0, 0, 0],
			client_t: Date.now(),
		});
		await sleep(50);
		shooter.send({ t: "fire", seq: 2, weapon: "ak", origin: [0, 2.25, 0], dir: [0, 0, 1], client_t: Date.now() });
		await sleep(200);
		const damage = target.damages.at(-1);
		assert(target.damages.length > damageBefore, `${target.label} took AK damage`);
		assert(damage?.attacker === shooter.welcome?.peer_id, `damage attacker is ${shooter.label}`);
		assert(damage?.weapon === "ak", "damage weapon is ak");
	}

	console.log("# anim_state → anim_event broadcast (excluding shooter)");
	const animBefore = clients.map(c => c.anim_events.length);
	clients[0].send({ t: "anim_state", state: "reload", weapon: "ak" });
	await sleep(200);
	const c1Delta = clients[0].anim_events.length - animBefore[0];
	const othersDelta = clients.slice(1).map((c, i) => c.anim_events.length - animBefore[i+1]);
	assert(c1Delta === 0, `c1 did NOT receive its own anim_event (got ${c1Delta})`);
	for (let i = 0; i < othersDelta.length; i++) {
		assert(othersDelta[i] >= 1, `c${i+2} got anim_event from c1 (${othersDelta[i]})`);
	}

	console.log("# Cleanup");
	clients.forEach(c => c.close());
	await sleep(300);

	// ----- Defensive checks (each opens its own connection) -----

	console.log("# Reject: protocol mismatch");
	{
		const c = new TestClient("proto_mismatch");
		await c.opened.catch(() => {});
		// Override hello with wrong protocol_version. We sent the real hello in
		// the constructor — server might already be processing. Send the bad
		// one explicitly so the server kicks on the second hello.
		await sleep(50);
		c.ws.send(JSON.stringify({ t: "hello", client_version: "smoke", protocol_version: "9.9.9" }));
		await sleep(200);
		assert(c.kicked != null, `client kicked on bad protocol (kicked=${c.kicked?.reason})`);
	}

	console.log("# Reject: oversized frame");
	{
		const c = new TestClient("big_frame");
		await c.opened.catch(() => {});
		await sleep(50);
		const huge = "x".repeat(8000);
		c.ws.send(JSON.stringify({ t: "anim_state", state: huge }));
		await sleep(200);
		assert(c.kicked?.reason === "frame_too_large", `kicked on oversized frame (reason=${c.kicked?.reason})`);
	}

	console.log("# Reject: malformed transform pos");
	{
		const c = new TestClient("bad_pos");
		await c.opened.catch(() => {});
		await sleep(50);
		c.ws.send(JSON.stringify({
			t: "transform", pos: ["nope", null, "x"], rot_y: 0, aim_pitch: 0,
			vel: [0,0,0], client_t: Date.now(),
		}));
		await sleep(200);
		assert(c.kicked?.reason === "bad_transform_pos", `kicked on bad pos (reason=${c.kicked?.reason})`);
	}

	// ----- Damage / death / respawn flow -----

	console.log("# Damage: red c1 fires +X cone-hits blue c2");
	{
		// 2 fresh peers — first becomes red, second becomes blue.
		const red = new TestClient("dmg_red");
		const blue = new TestClient("dmg_blue");
		await Promise.all([red.opened, blue.opened]);
		await sleep(300);
		// Pin them onto the X axis at known spots so the +X aim cone hits.
		red.send({ t: "transform", pos: [-10, 1, 0], rot_y: 0, aim_pitch: 0, vel: [0,0,0], client_t: Date.now() });
		blue.send({ t: "transform", pos: [10, 1, 0], rot_y: Math.PI, aim_pitch: 0, vel: [0,0,0], client_t: Date.now() });
		await sleep(150);
		red.send({ t: "fire", seq: 1, weapon: "ak", origin: [-10,1,0], dir: [1,0,0], client_t: Date.now() });
		await sleep(200);
		assert(blue.damages.length >= 1, `blue received damage (${blue.damages.length})`);
		assert(blue.damages[0]?.new_hp === 75, `damage dropped HP 100→75 (got ${blue.damages[0]?.new_hp})`);
		assert(red.damages.length >= 1, "red also receives damage broadcast (omniscient view)");

		console.log("# Death: red kills blue with 4 AK shots, sees death event");
		// Need to wait between shots — fire rate cap 10 Hz = 100ms.
		for (let i = 0; i < 3; i++) {
			await sleep(120);
			red.send({ t: "fire", seq: i+2, weapon: "ak", origin: [-10,1,0], dir: [1,0,0], client_t: Date.now() });
		}
		await sleep(300);
		assert(blue.deaths.length === 1, `blue got death event (${blue.deaths.length})`);
		assert(blue.deaths[0]?.killer === red.welcome?.peer_id, `death.killer == red peer_id`);

		console.log("# Respawn: dead blue auto-respawns after delay");
		// match.json says 5s respawn, so wait 5.3s.
		await sleep(5300);
		assert(blue.respawns.length === 1, `blue got respawn event (${blue.respawns.length})`);
		assert(Array.isArray(blue.respawns[0]?.pos) && blue.respawns[0].pos.length === 3, "respawn carries vec3 pos");

		console.log("# Friendly fire: red shooting another red is filtered out");
		const red2 = new TestClient("dmg_red2");
		await red2.opened;
		await sleep(300);
		// Force red2 onto +X near blue's old spot so cone-pick would otherwise grab them.
		red2.send({ t: "transform", pos: [10, 1, 0], rot_y: 0, aim_pitch: 0, vel: [0,0,0], client_t: Date.now() });
		await sleep(120);
		// Another red shot — should now skip red2 (same team) and only hit blue (newly respawned somewhere).
		const red2DmgBefore = red2.damages.length;
		await sleep(120);
		red.send({ t: "fire", seq: 999, weapon: "ak", origin: [-10,1,0], dir: [1,0,0], client_t: Date.now() });
		await sleep(200);
		const red2Damage = red2.damages.slice(red2DmgBefore).find(d => d.victim === red2.welcome?.peer_id);
		assert(red2Damage === undefined, `red2 (same team) NOT damaged by red`);

		red.close(); blue.close(); red2.close();
		await sleep(200);
	}

	console.log("# Cooldown: rapid-fire over rate cap is dropped");
	{
		const coolRed = new TestClient("cool_red");
		const coolBlue = new TestClient("cool_blue");
		await Promise.all([coolRed.opened, coolBlue.opened]);
		await sleep(300);
		assert(coolRed.welcome?.team !== coolBlue.welcome?.team, "cooldown peers are on opposite teams");
		coolRed.send({ t: "transform", pos: [-10, 1, 0], rot_y: 0, aim_pitch: 0, vel: [0,0,0], client_t: Date.now() });
		coolBlue.send({ t: "transform", pos: [10, 1, 0], rot_y: Math.PI, aim_pitch: 0, vel: [0,0,0], client_t: Date.now() });
		await sleep(150);
		const dmgBefore = coolBlue.damages.length;
		for (let i = 0; i < 5; i++) {
			coolRed.send({ t: "fire", seq: 1000 + i, weapon: "ak", origin: [-10,1,0], dir: [1,0,0], client_t: Date.now() });
		}
		await sleep(300);
		const newDmgs = coolBlue.damages.length - dmgBefore;
		assert(newDmgs === 1, `cooldown dropped extras (got ${newDmgs} damages, expect 1)`);
		coolRed.close(); coolBlue.close();
		await sleep(200);
	}

	console.log("# Vehicle hit claim: tank shell drains player HP server-side");
	{
		// Two peers: red drives tank, blue stands in front of red within 200m.
		const red = new TestClient("claim_red");
		const blue = new TestClient("claim_blue");
		await Promise.all([red.opened, blue.opened]);
		await sleep(300);
		red.send({ t: "transform", pos: [0, 1, 0], rot_y: 0, aim_pitch: 0, vel: [0,0,0], client_t: Date.now() });
		blue.send({ t: "transform", pos: [10, 1, 0], rot_y: Math.PI, aim_pitch: 0, vel: [0,0,0], client_t: Date.now() });
		await sleep(150);
		// Red claims the tank.
		red.send({ t: "vehicle_enter", vehicle_id: "tank" });
		await sleep(200);
		// Now claim a tank-shell hit on blue.
		const blueDmgBefore = blue.damages.length;
		red.send({
			t: "vehicle_hit_claim",
			projectile: "tank_shell",
			vehicle_id: "tank",
			target_peer_id: blue.welcome?.peer_id,
			client_t: Date.now(),
		});
		await sleep(250);
		const got = blue.damages.length - blueDmgBefore;
		assert(got === 1, `blue took 1 damage from tank_shell claim (got ${got})`);
		assert(blue.damages.at(-1)?.weapon === "tank_shell", `damage tagged with tank_shell weapon`);
		assert(blue.damages.at(-1)?.amount === 100, `damage amount=100 (got ${blue.damages.at(-1)?.amount})`);

		console.log("# Vehicle hit claim: cooldown drops fast-repeat claims");
		const before2 = blue.damages.length;
		// 4 claims in quick succession; only the first should pass min_interval=350ms.
		for (let i = 0; i < 4; i++) {
			red.send({
				t: "vehicle_hit_claim",
				projectile: "tank_shell",
				vehicle_id: "tank",
				target_peer_id: blue.welcome?.peer_id,
				client_t: Date.now(),
			});
		}
		await sleep(250);
		const post2 = blue.damages.length - before2;
		assert(post2 === 0, `cooldown drops back-to-back claims within 350ms (got ${post2})`);

		console.log("# Vehicle hit claim: non-driver claim rejected");
		const before3 = blue.damages.length;
		// Blue tries to claim from the tank — but red is the driver, so server drops.
		blue.send({
			t: "vehicle_hit_claim",
			projectile: "tank_shell",
			vehicle_id: "tank",
			target_peer_id: red.welcome?.peer_id,
			client_t: Date.now(),
		});
		await sleep(200);
		const post3 = blue.damages.length - before3;
		assert(post3 === 0, `non-driver claim gives no damage (got ${post3})`);

		red.close(); blue.close();
		await sleep(200);
	}

	console.log("# Speed-clamp: teleport request gets capped, not accepted");
	{
		const c = new TestClient("speed_test");
		await c.opened;
		await sleep(200);
		// First transform — establishes baseline.
		c.send({ t: "transform", pos: [0, 1, 0], rot_y: 0, aim_pitch: 0, vel: [0,0,0], client_t: Date.now() });
		await sleep(120);
		// Now request a 200m teleport on +X. With dt~0.12s and cap 12 m/s,
		// max_step = 12*0.12 + 0.5 = ~1.94m. Server should clamp to ~1.94m.
		c.send({ t: "transform", pos: [200, 1, 0], rot_y: 0, aim_pitch: 0, vel: [0,0,0], client_t: Date.now() });
		await sleep(150);
		// Inspect a snapshot — clamped X should be < 5 (well under 200).
		// Use a 2nd peer to read snapshots that include the speed_test player.
		const observer = new TestClient("observer");
		await observer.opened;
		await sleep(400);
		const observed_pos = observer.last_peer_pos.get(c.welcome?.peer_id);
		assert(c.kicked === null, `client survived teleport attempt`);
		assert(observed_pos !== undefined, `observer saw the speed_test peer`);
		// Server should have clamped X to a few meters max (capped near 1.94m).
		// Allow generous bound 8m to absorb a few accumulated transform packets.
		assert(observed_pos !== undefined && observed_pos[0] < 8, `clamped X stays near origin (got ${observed_pos?.[0]?.toFixed(2)}, expect <8 not 200)`);
		c.close(); observer.close();
		await sleep(200);
	}

	console.log("# Reject: 11th connection (match full)");
	{
		const fillers = [];
		for (let i = 0; i < 10; i++) fillers.push(new TestClient(`fill${i}`));
		await Promise.all(fillers.map(c => c.opened.catch(() => {})));
		await sleep(300);
		const eleventh = new TestClient("eleventh");
		await eleventh.opened.catch(() => {});
		await sleep(300);
		assert(eleventh.kicked?.reason === "match_full", `11th rejected (reason=${eleventh.kicked?.reason})`);
		fillers.forEach(c => c.close());
		eleventh.close();
		await sleep(200);
	}

	console.log(FAILS.length === 0 ? "\nALL PASS" : `\nFAILED: ${FAILS.length}\n${FAILS.map(f => '  - ' + f).join('\n')}`);
	process.exit(FAILS.length === 0 ? 0 : 1);
}

main().catch((e) => { console.error(e); process.exit(2); });
