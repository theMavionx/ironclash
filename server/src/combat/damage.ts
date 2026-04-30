// HP application + death/destruction broadcasts. Every gameplay path that
// deals damage (player gun, vehicle weapon, kamikaze claim) ends here.

import type { Player } from "../state/players.ts";
import { players } from "../state/players.ts";
import { request_vehicle_respawn, type Vehicle } from "../state/vehicles.ts";
import { broadcast } from "../net/socket.ts";
import { award_kill, request_respawn } from "../state/match.ts";
import { make_logger } from "../util/log.ts";

const log_match = make_logger("match");
const log_veh = make_logger("veh");

/** Apply damage to a player. Broadcasts `damage` always, `death` once when
 *  HP first hits 0. Awards a kill to the attacker's team if the round is
 *  in_progress and the kill is cross-team. */
export function apply_player_damage(
	victim: Player,
	attacker_peer_id: number,
	attacker_team: string,
	amount: number,
	weapon_id: string,
	headshot: boolean = false,
): void {
	if (!victim.alive || amount <= 0) return;
	const attacker: Player | undefined = players.get(attacker_peer_id);
	const attacker_name: string = attacker?.display_name ?? `Player${attacker_peer_id}`;
	const attacker_team_wire: "red" | "blue" = attacker_team === "blue" ? "blue" : "red";
	victim.hp = Math.max(0, victim.hp - amount);
	broadcast({
		t: "damage",
		victim: victim.peer_id,
		victim_name: victim.display_name,
		victim_team: victim.team,
		attacker: attacker_peer_id,
		attacker_name,
		attacker_team: attacker_team_wire,
		amount,
		new_hp: victim.hp,
		weapon: weapon_id,
		headshot,
	});
	if (victim.hp > 0) return;
	victim.alive = false;
	request_respawn(victim.peer_id);
	award_kill(attacker_team_wire, victim.team);
	broadcast({
		t: "death",
		victim: victim.peer_id,
		victim_name: victim.display_name,
		victim_team: victim.team,
		killer: attacker_peer_id,
		killer_name: attacker_name,
		killer_team: attacker_team_wire,
		weapon: weapon_id,
	});
	log_match.info(`kill ${attacker_name}(${attacker_peer_id}) → ${victim.display_name}(${victim.peer_id}) (${weapon_id})`);
}

/** Apply damage to a vehicle. On destruction broadcasts the explosion +
 *  smoke-fire VFX so every client renders the wreck. Driver is vacated so
 *  another peer can re-claim a fresh respawn (when match resets HP). */
export function apply_vehicle_damage(
	target: Vehicle,
	attacker_peer_id: number,
	amount: number,
	weapon_id: string,
): void {
	if (!target.alive || amount <= 0) return;
	target.hp = Math.max(0, target.hp - amount);
	log_veh.info(`${target.id} dmg=${amount} hp=${target.hp}/${target.max_hp} by peer=${attacker_peer_id} (${weapon_id})`);
	if (target.hp > 0) return;
	target.alive = false;
	target.driver_peer_id = -1;
	request_vehicle_respawn(target);
	const smoke_duration_s: number = Math.max(0, (target.respawn_at_ms - Date.now()) / 1000);
	broadcast({ t: "vfx_event", kind: "explosion", entity_id: target.id, pos: target.pos, weapon: weapon_id });
	broadcast({ t: "vfx_event", kind: "smoke_fire_start", entity_id: target.id, pos: target.pos, weapon: weapon_id, duration: smoke_duration_s });
	log_veh.info(`destroyed ${target.id} by peer=${attacker_peer_id} (${weapon_id})`);
}
