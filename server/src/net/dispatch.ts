// Message dispatch table. Each C2S type registers exactly one handler.
//
// To add a new client-to-server message:
//   1. Add the C2S* interface in shared/protocol.ts.
//   2. `register_handler("my_msg", (player, msg) => { ... })` in handlers.ts.
//   No central switch to edit.

import type { C2S } from "../../../shared/protocol.ts";

type C2STypeName = C2S["t"];
import type { Player } from "../state/players.ts";
import { make_logger } from "../util/log.ts";

const log = make_logger("net");

// Conditional pick: extract the variant of C2S whose `t` is K.
export type C2SVariant<K extends string> = Extract<C2S, { t: K }>;

export type C2SHandler<K extends string = string> = (
	player: Player,
	msg: C2SVariant<K>,
) => void;

const _handlers: Map<string, C2SHandler> = new Map();

export function register_handler<K extends C2STypeName>(t: K, handler: C2SHandler<K>): void {
	if (_handlers.has(t)) {
		log.warn(`overwriting handler for "${t}"`);
	}
	_handlers.set(t, handler as C2SHandler);
}

export function dispatch(player: Player, msg: C2S): void {
	const h: C2SHandler | undefined = _handlers.get(msg.t);
	if (h === undefined) {
		log.warn(`no handler for "${msg.t}" from peer=${player.peer_id}`);
		return;
	}
	h(player, msg);
}

export function registered_types(): string[] {
	return [..._handlers.keys()].sort();
}
