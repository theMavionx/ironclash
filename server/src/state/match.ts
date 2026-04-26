// Match state machine + scoring.
// State graph:
//   waiting → warmup (both teams have ≥1)
//   warmup → in_progress (after warmup_seconds, full HP reset)
//   in_progress → post_match (timer expires OR kill_cap hit)
//   post_match → warmup or waiting (after post_match_seconds, scores reset)
//
// Public surface: get_match_state, award_kill, tick_match_state,
// broadcast_match_state, request_respawn, check_respawns, reset_match.

import type { MatchState, Team, Vec3 } from "../../../shared/protocol.ts";
import { cfg } from "../config.ts";
import { players, spawn_for_team, team_count } from "./players.ts";
import { reset_all_vehicles } from "./vehicles.ts";
import { broadcast } from "../net/socket.ts";
import { make_logger } from "../util/log.ts";

const log = make_logger("match");

let _state: MatchState = "waiting";
let _state_changed_at_ms: number = Date.now();
let _red_score: number = 0;
let _blue_score: number = 0;
let _last_broadcast_ms: number = 0;

export function get_match_state(): MatchState { return _state; }
export function get_red_score(): number { return _red_score; }
export function get_blue_score(): number { return _blue_score; }

function set_state(next: MatchState): void {
	if (next === _state) return;
	_state = next;
	_state_changed_at_ms = Date.now();
	log.info(`→ ${next}`);
}

/** Seconds left in the current timed phase (0 outside warmup/match/post). */
export function time_remaining(now_ms: number): number {
	const elapsed_s: number = (now_ms - _state_changed_at_ms) / 1000;
	switch (_state) {
		case "warmup":      return Math.max(0, cfg.match.warmup_seconds - elapsed_s);
		case "in_progress": return Math.max(0, cfg.match.match_duration_seconds - elapsed_s);
		case "post_match":  return Math.max(0, cfg.match.post_match_seconds - elapsed_s);
		default:            return 0;
	}
}

/** Award a kill. No-op outside `in_progress` so warmup duels don't count. */
export function award_kill(attacker_team: Team, victim_team: Team): void {
	if (_state !== "in_progress") return;
	if (attacker_team === victim_team) return;     // friendly fire mistake
	if (attacker_team === "red") _red_score++;
	else _blue_score++;
}

/** Schedule a respawn for the given player. */
export function request_respawn(peer_id: number): void {
	const p = players.get(peer_id);
	if (p === undefined) return;
	p.respawn_at_ms = Date.now() + cfg.match.respawn_delay_seconds * 1000;
}

/** Reset HP / scores between rounds. Resurrects dead players too — those get
 *  their own `respawn` event so client avatars unhide. */
export function reset_match(): void {
	_red_score = 0;
	_blue_score = 0;
	for (const p of players.values()) {
		const was_dead: boolean = !p.alive;
		p.hp = cfg.match.starting_hp;
		p.alive = true;
		p.respawn_at_ms = 0;
		p.pos = spawn_for_team(p.team);
		if (was_dead) {
			broadcast({ t: "respawn", peer_id: p.peer_id, pos: p.pos, team: p.team });
		}
	}
	reset_all_vehicles();
	log.info("reset");
}

export function tick_match_state(now_ms: number): void {
	const red_count: number = team_count("red");
	const blue_count: number = team_count("blue");
	const tr: number = time_remaining(now_ms);
	switch (_state) {
		case "waiting":
			if (red_count >= 1 && blue_count >= 1) set_state("warmup");
			break;
		case "warmup":
			if (red_count === 0 || blue_count === 0) { set_state("waiting"); break; }
			if (tr <= 0) { reset_match(); set_state("in_progress"); }
			break;
		case "in_progress":
			if (red_count === 0 || blue_count === 0) { set_state("waiting"); break; }
			if (tr <= 0) { set_state("post_match"); break; }
			if (_red_score >= cfg.match.kill_cap_per_team || _blue_score >= cfg.match.kill_cap_per_team) {
				set_state("post_match");
			}
			break;
		case "post_match":
			if (tr <= 0) {
				reset_match();
				set_state(red_count >= 1 && blue_count >= 1 ? "warmup" : "waiting");
			}
			break;
	}
}

export function broadcast_match_state(now_ms: number): void {
	broadcast({
		t: "match_state",
		state: _state,
		time_remaining: time_remaining(now_ms),
		red_score: _red_score,
		blue_score: _blue_score,
		red_count: team_count("red"),
		blue_count: team_count("blue"),
	});
}

/** Throttled broadcast: pushes match_state at 2 Hz so timer is live without
 *  flooding. Called every tick from the snapshot loop. */
export function maybe_broadcast_match_state(now_ms: number): void {
	if (now_ms - _last_broadcast_ms < 500) return;
	_last_broadcast_ms = now_ms;
	broadcast_match_state(now_ms);
}

/** Walk all dead players, respawn anyone past their respawn deadline. */
export function check_respawns(now_ms: number): void {
	for (const p of players.values()) {
		if (p.alive) continue;
		if (p.respawn_at_ms === 0) continue;
		if (now_ms < p.respawn_at_ms) continue;
		p.alive = true;
		p.hp = cfg.match.starting_hp;
		p.pos = spawn_for_team(p.team);
		p.respawn_at_ms = 0;
		broadcast({ t: "respawn", peer_id: p.peer_id, pos: p.pos, team: p.team });
		log.info(`respawn peer=${p.peer_id} team=${p.team}`);
	}
}

export function pos_for_team_spawn(team: Team): Vec3 { return spawn_for_team(team); }
