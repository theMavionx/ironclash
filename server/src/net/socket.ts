// WebSocket I/O primitives. Every other module sends through these so we
// have one place to add metrics, rate limits, or transport swap (msgpack
// instead of JSON, etc.).

import { WebSocket } from "ws";
import type { S2C } from "../../../shared/protocol.ts";
import type { Player } from "../state/players.ts";
import { players } from "../state/players.ts";
import { make_logger } from "../util/log.ts";

const log = make_logger("net");
const SOFT_BACKPRESSURE_BYTES = 512 * 1024;
const HARD_BACKPRESSURE_BYTES = 2 * 1024 * 1024;

function send_data(ws: WebSocket, data: string, unreliable: boolean = false): boolean {
	if (ws.readyState !== WebSocket.OPEN) return false;
	if (ws.bufferedAmount > HARD_BACKPRESSURE_BYTES) {
		log.warn(`closing slow peer: buffered=${ws.bufferedAmount}`);
		try { ws.close(1013, "backpressure"); } catch { /* best-effort */ }
		return false;
	}
	if (unreliable && ws.bufferedAmount > SOFT_BACKPRESSURE_BYTES) return false;
	ws.send(data, (err?: Error | null) => {
		if (err != null) log.warn(`ws send failed: ${err.message}`);
	});
	return true;
}

export function send(ws: WebSocket, msg: S2C, unreliable: boolean = false): void {
	send_data(ws, JSON.stringify(msg), unreliable);
}

/** Broadcast to every connected peer. Pass `except_peer_id` to skip the
 *  shooter when forwarding fire VFX, anim cues, etc. */
export function broadcast(msg: S2C, except_peer_id?: number, unreliable: boolean = false): void {
	const data: string = JSON.stringify(msg);
	for (const p of players.values()) {
		if (except_peer_id !== undefined && p.peer_id === except_peer_id) continue;
		send_data(p.ws, data, unreliable);
	}
}

export function kick(p: Player, reason: string): void {
	send(p.ws, { t: "kicked", reason });
	log.warn(`kick peer=${p.peer_id}: ${reason}`);
	try { p.ws.close(); } catch { /* best-effort */ }
}
