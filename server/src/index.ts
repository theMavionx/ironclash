// Authoritative Ironclash 5v5 server — entry point.
//
// All logic lives in modules; this file just wires them together:
//   1. config.ts        loads balance JSON
//   2. state/*          singleton maps for players / vehicles / match
//   3. combat/*         targeting + damage + hit-claim validation
//   4. net/*            socket I/O + dispatch table
//   5. snapshot.ts      30 Hz tick loop
//
// Adding a new gameplay feature usually means: extend a registry (vehicles,
// projectiles), add an entry in handlers.ts, and add fields to the snapshot
// builder in snapshot.ts. No changes here unless you add a new module.

import { WebSocketServer, WebSocket } from "ws";
import {
	PROTOCOL_VERSION,
	type C2S,
} from "../../shared/protocol.ts";
import { cfg, LIMITS } from "./config.ts";
import { make_logger } from "./util/log.ts";
import { players, make_player, next_peer_id, pick_team_for_new_peer, team_count } from "./state/players.ts";
import { vacate_driver } from "./state/vehicles.ts";
import { broadcast, kick, send } from "./net/socket.ts";
import { dispatch } from "./net/dispatch.ts";
import { register_all_handlers } from "./net/handlers.ts";
import { broadcast_match_state } from "./state/match.ts";
import { start_snapshot_loop } from "./snapshot.ts";

const log = make_logger("net");

// Wire every C2S type → handler exactly once.
register_all_handlers();

const wss: WebSocketServer = new WebSocketServer({ port: cfg.port, host: cfg.host });
log.info(`Ironclash server up — ws://${cfg.host}:${cfg.port} (tick ${cfg.tick_hz} Hz, cap ${cfg.match.max_total}, proto ${PROTOCOL_VERSION})`);
log.info(`weapons: ${Object.keys(cfg.weapons).filter(k => !k.startsWith("_")).join(", ")}`);

wss.on("connection", (ws: WebSocket, req): void => {
	const remote: string = req.socket.remoteAddress ?? "?";
	if (players.size >= cfg.match.max_total) {
		send(ws, { t: "kicked", reason: "match_full" });
		ws.close();
		log.info(`reject ${remote}: match_full (${players.size}/${cfg.match.max_total})`);
		return;
	}
	const peer_id: number = next_peer_id();
	const team = pick_team_for_new_peer();
	const player = make_player(peer_id, ws, team);
	players.set(peer_id, player);
	log.info(`join peer=${peer_id} team=${team} (${remote})  red=${team_count("red")} blue=${team_count("blue")}`);

	send(ws, {
		t: "welcome",
		peer_id, team,
		max_per_team: cfg.match.max_per_team,
		tick_hz: cfg.tick_hz,
		protocol_version: PROTOCOL_VERSION,
	});
	broadcast({ t: "player_joined", peer_id, team }, peer_id);
	broadcast_match_state(Date.now());

	ws.on("message", (data: Buffer | ArrayBuffer | Buffer[]): void => {
		const size: number = (data as Buffer).byteLength ?? (data as Buffer).length ?? 0;
		if (size > LIMITS.max_frame_bytes) { kick(player, "frame_too_large"); return; }
		let msg: C2S;
		try { msg = JSON.parse(data.toString()) as C2S; }
		catch {
			log.warn(`bad json from peer=${peer_id}: ${data.toString().slice(0, 80)}`);
			return;
		}
		player.last_seen_ms = Date.now();
		dispatch(player, msg);
	});

	ws.on("close", (): void => {
		players.delete(peer_id);
		vacate_driver(peer_id);
		broadcast({ t: "player_left", peer_id });
		log.info(`left peer=${peer_id}  red=${team_count("red")} blue=${team_count("blue")}`);
		broadcast_match_state(Date.now());
	});

	ws.on("error", (e: Error): void => {
		log.warn(`ws error peer=${peer_id}: ${e.message}`);
	});
});

start_snapshot_loop();

// ----------------------------------------------------------------------
// Lifecycle
// ----------------------------------------------------------------------

function shutdown(reason: string): void {
	log.info(`shutdown: ${reason}`);
	for (const p of players.values()) {
		send(p.ws, { t: "kicked", reason: "server_shutdown" });
		try { p.ws.close(); } catch { /* best-effort */ }
	}
	wss.close(() => process.exit(0));
}

process.on("SIGINT", () => shutdown("SIGINT"));
process.on("SIGTERM", () => shutdown("SIGTERM"));
