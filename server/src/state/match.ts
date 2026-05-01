// Match state machine + scoring.
// State graph:
//   waiting → warmup (both teams have ≥1)
//   warmup → in_progress (after warmup_seconds, full HP reset)
//   in_progress → post_match (timer expires OR score cap hit)
//   post_match → warmup or waiting (after post_match_seconds, scores reset)
//
// Public surface: get_match_state, award_kill, tick_match_state,
// broadcast_match_state, request_respawn, check_respawns, reset_match.

import type { MatchState, Team, Vec3, WinReason } from "../../../shared/protocol.ts";
import { cfg } from "../config.ts";
import { players, spawn_for_player, spawn_for_team, team_count } from "./players.ts";
import { reset_all_vehicles } from "./vehicles.ts";
import {
	control_point_owner_counts,
	get_control_point_snapshot,
	reset_control_points,
	tick_control_points,
} from "./control_points.ts";
import { broadcast } from "../net/socket.ts";
import { make_logger } from "../util/log.ts";

const log = make_logger("match");
type MatchWinner = Team | "draw" | "";

let _state: MatchState = "waiting";
let _state_changed_at_ms: number = Date.now();
let _red_score: number = 0.0;
let _blue_score: number = 0.0;
let _last_broadcast_ms: number = 0;
let _last_tick_ms: number = Date.now();
let _winner: MatchWinner = "";
let _win_reason: WinReason = "";

export function get_match_state(): MatchState { return _state; }
export function get_red_score(): number { return Math.floor(_red_score); }
export function get_blue_score(): number { return Math.floor(_blue_score); }

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
	add_score(attacker_team, cfg.match.kill_score_points);
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
	_red_score = 0.0;
	_blue_score = 0.0;
	_winner = "";
	_win_reason = "";
	reset_control_points();
	for (const p of players.values()) {
		const was_dead: boolean = !p.alive;
		p.hp = cfg.match.starting_hp;
		p.alive = true;
		p.respawn_at_ms = 0;
		p.pos = spawn_for_player(p.peer_id, p.team);
		if (was_dead) {
			broadcast({ t: "respawn", peer_id: p.peer_id, pos: p.pos, team: p.team });
		}
	}
	reset_all_vehicles();
	log.info("reset");
}

export function tick_match_state(now_ms: number): void {
	const dt_s: number = Math.max(0, Math.min(0.2, (now_ms - _last_tick_ms) / 1000));
	_last_tick_ms = now_ms;
	const red_count: number = team_count("red");
	const blue_count: number = team_count("blue");
	const tr: number = time_remaining(now_ms);
	switch (_state) {
		case "waiting":
			if (red_count >= 1 && blue_count >= 1) {
				reset_match();
				set_state("warmup");
			}
			break;
		case "warmup":
			if (red_count === 0 || blue_count === 0) { set_state("waiting"); break; }
			if (tr <= 0) { reset_match(); set_state("in_progress"); }
			break;
		case "in_progress":
			if (red_count === 0 || blue_count === 0) { set_state("waiting"); break; }
			if (tr <= 0) { finish_match("time"); break; }
			tick_score(dt_s);
			if (get_red_score() >= cfg.match.score_cap_per_team || get_blue_score() >= cfg.match.score_cap_per_team) {
				finish_match("score_cap");
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

function tick_score(dt_s: number): void {
	if (dt_s <= 0) return;
	const point_score = tick_control_points(dt_s);
	add_score("red", point_score.red_points);
	add_score("blue", point_score.blue_points);
}

function add_score(team: Team, amount: number): void {
	if (amount <= 0) return;
	if (team === "red") _red_score += amount;
	else _blue_score += amount;
}

function finish_match(reason: WinReason): void {
	_winner = winner_from_score();
	_win_reason = reason;
	set_state("post_match");
	log.info(`finished reason=${reason} winner=${_winner || "none"} score=${get_red_score()}-${get_blue_score()}`);
}

function winner_from_score(): MatchWinner {
	const red: number = get_red_score();
	const blue: number = get_blue_score();
	if (red > blue) return "red";
	if (blue > red) return "blue";
	return "draw";
}

export function broadcast_match_state(now_ms: number): void {
	const zone_counts = control_point_owner_counts();
	broadcast({
		t: "match_state",
		state: _state,
		time_remaining: time_remaining(now_ms),
		red_score: get_red_score(),
		blue_score: get_blue_score(),
		red_count: team_count("red"),
		blue_count: team_count("blue"),
		score_cap: cfg.match.score_cap_per_team,
		winner: _winner,
		win_reason: _win_reason,
		red_zones: zone_counts.red,
		blue_zones: zone_counts.blue,
		neutral_zones: zone_counts.neutral,
		zones: get_control_point_snapshot(),
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
		p.pos = spawn_for_player(p.peer_id, p.team);
		p.respawn_at_ms = 0;
		broadcast({ t: "respawn", peer_id: p.peer_id, pos: p.pos, team: p.team });
		log.info(`respawn peer=${p.peer_id} team=${p.team}`);
	}
}

export function pos_for_team_spawn(team: Team): Vec3 { return spawn_for_team(team); }
