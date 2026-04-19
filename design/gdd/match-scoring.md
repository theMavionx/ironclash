# Match Scoring

> **Status**: Draft (8/8 sections filled)
> **Author**: AI-assisted draft
> **Last Updated**: 2026-04-18
> **Implements Pillar**: Pillar 1 — *Skill Is The Ceiling* (kills matter); Pillar 2 — *Every Tool Has A Counter* (objectives and kills are both valid paths to victory); Pillar 3 — *Matches Start Fast* (fixed short duration)
> **MVP Scope**: 10-minute matches. Team score = sum(capture income + kill points). Team with higher score at time expiry wins. Tie → 60s sudden-death overtime.

## Overview

Match scoring is the system that turns gameplay actions into the final
win/loss verdict. Each team accumulates a single numeric **team score** over
the course of the match, drawn from two sources: **capture-point income**
(passive, per-second while points are held) and **kill points** (discrete,
per-kill). The match runs for a fixed 10 minutes of ACTIVE state; at expiry,
the team with the higher score wins. Ties trigger a 60-second sudden-death
overtime where the first team to gain a 50-point lead wins; unresolved ties
after overtime end as a draw. Scoring is server-authoritative per ADR-0001
and replicated to all clients via MultiplayerSynchronizer.

## Player Fantasy

Match scoring frames the question the player answers every minute: **push
for territory or push for kills?** Both are valid, neither is supreme. A
team that slam-dunks infantry kills but ignores points can lose. A team
that camps captured points without defending them can also lose. The player
learns to read the score — "we're down 300 points, we need B now or we need
a multi-kill on the flank." The final ten seconds of a close match are a
shared, shared-stakes moment — everyone on both teams watches the timer and
the capture bars at the same time. The fantasy is the **decisive late-game
push**: the play that flips the scoreboard just before the timer expires.

## Detailed Design

### Core Rules

1. A match has three states driven by match-state-machine.md: **WARMUP** → **ACTIVE** → **END**. Scoring only accumulates during ACTIVE.
2. Each team has a single integer score, starting at 0 for both teams at the transition from WARMUP to ACTIVE.
3. Score is increased by two sources:
   - **Capture income**: every second of ACTIVE state, each team gains `income_rate_per_sec × count_owned_points(team)` points. (See capture-point-system.md § Formulas → Income Rate.)
   - **Kill points**: when a player kills an enemy, the killer's team gains `kill_points_per_target_type` points.
4. Kill point values vary by victim type:

| Victim Type | Kill Points |
|-------------|------------|
| Infantry (Assault or Heavy) | 10 |
| Driver of unoccupied vehicle (no vehicle loss) | 10 |
| Vehicle destruction (tank) | 50 |
| Vehicle destruction (helicopter) | 75 |

   At MVP, only infantry kills apply (vehicles post-MVP). Values are defined here for completeness.

5. Kill points are awarded to the team of the player who dealt the **final blow** (damage that brought HP below 0). Splash damage counts.
6. **Assist tracking is deferred to post-MVP.** At MVP there are no partial kill credits.
7. **Self-kills** (environmental fall, RPG self-splash): no kill points awarded to either team. No negative points.
8. **Friendly fire does not exist at MVP.** Any hypothetical team-kill does not reduce score.
9. Scores are clamped to non-negative: `team_score = max(0, team_score)`. (At MVP no negative-point sources exist, but the clamp is defensive.)
10. The match timer counts down from `match_duration_seconds` at 1 Hz. Reaches 0 → transition to **END** state (via match-state-machine.md).
11. At the moment of transition to END, the server captures final scores, identifies the winner, and broadcasts `on_match_ended` RPC.
12. **Tie handling**: if `team_a_score == team_b_score` at timer expiry, the match enters **OVERTIME** sub-state for `overtime_duration` seconds.
13. During OVERTIME, the first team to achieve a score lead of `overtime_win_lead` points wins immediately (triggers END transition).
14. If OVERTIME expires without either team reaching the lead threshold, the match ends as a DRAW. No team is declared winner.
15. Warmup state allows players to move and shoot but does not accumulate score or kill points. Warmup duration is set by match-state-machine.md.
16. Early-end conditions at MVP: **only** time expiry (or OT resolution). No score cap, no all-capture-points-held shortcut at MVP.

### Per-Player Statistics

For end-of-match display and future scoreboard support, the server tracks per-player stats during ACTIVE state:

| Stat | Description |
|------|-------------|
| Kills | Count of kills against enemy players (final blows) |
| Deaths | Count of times the player's HP reached 0 |
| Headshots | Subset of kills dealt by headshot-damage |
| Capture contributions | Seconds of ACTIVE presence in a capture volume while the point progressed or was owned by the player's team |
| Vehicle destructions | Count of vehicles destroyed by player's damage (post-MVP) |
| Total damage dealt | Sum of HP subtracted by the player's damage (excludes splash overkill) |

Per-player stats are NOT used in the team-score calculation. They are
display-only. MVP end-of-match text screen shows only team winner, team
scores, and a "top player" line (highest individual kills).

### States and Transitions

| State | Entry Condition | Exit Condition | Behavior |
|-------|----------------|----------------|----------|
| WARMUP | Match created, players joining | Warmup timer ends OR min-player threshold met | No scoring |
| ACTIVE | WARMUP exit | Match timer reaches 0 | Scoring accumulates from capture + kills |
| OVERTIME | ACTIVE ended with tie | Lead threshold reached OR overtime timer ends | Scoring continues; first-to-lead wins |
| END (victory) | ACTIVE ends with winner OR OVERTIME lead | Players return to menu OR new match starts | Final scores displayed, winner announced |
| END (draw) | OVERTIME ends without lead | Players return to menu | Draw announced |

### Interactions with Other Systems

| System | Interaction | Direction |
|--------|-------------|-----------|
| **Match state machine** | Drives WARMUP/ACTIVE/OVERTIME/END transitions | Match state → Scoring |
| **Capture point system** | Provides per-second income count | Capture → Scoring |
| **Health/damage system** | Provides death signals (who killed whom) | Health → Scoring |
| **Weapon system** | Feeds damage → kill causality chain | Weapon → Scoring (via Health) |
| **Team assignment** | Maps players to teams for score routing | Team → Scoring |
| **Networking (ADR-0001)** | Score replicated to all clients; transition RPCs | Scoring ↔ Networking |
| **HUD** | Displays team scores + match timer | Scoring → HUD |
| **Scoreboard** | Displays full per-player stats (post-MVP) | Scoring → Scoreboard |
| **Post-match summary UI** | Displays final results and winner (post-MVP full version) | Scoring → Post-match |
| **Respawn system** | Respawn stops during END state | Match state → Respawn |
| **Audio system** | Plays victory/defeat/draw stings on END | Scoring → Audio |

## Formulas

### Team Score per Tick

Capture tick runs at 1 Hz during ACTIVE and OVERTIME states:

```
on_capture_tick(team):
    team_score[team] += count_owned_points(team) × income_rate_per_sec
```

With `income_rate_per_sec = 1`, a team holding 2 points gains 2 per second = 120 over 60s.

### Team Score on Kill

```
on_player_killed(victim, killer, weapon):
    if killer is not null and killer.team != victim.team:
        team_score[killer.team] += kill_points_per_target_type[victim.class_or_vehicle]
```

### Victory Determination (end of ACTIVE)

```
on_match_active_timer_expired():
    if team_score[A] > team_score[B]:
        winner = A
        transition_to_end(winner)
    elif team_score[B] > team_score[A]:
        winner = B
        transition_to_end(winner)
    else:
        transition_to_overtime()
```

### Overtime Resolution

```
on_overtime_tick():
    lead = abs(team_score[A] - team_score[B])
    if lead >= overtime_win_lead:
        winner = A if team_score[A] > team_score[B] else B
        transition_to_end(winner)
    if overtime_timer_expired():
        transition_to_end(winner=null)  # DRAW
```

### Theoretical Score Range

Over a 10-minute (600 s) ACTIVE match:

- Team holding all 3 capture points continuously: 3 × 600 = **1800 capture points**
- Team holding 2 on average: 2 × 600 = **1200**
- Team holding 1 on average: 600
- 40 infantry kills × 10 pts: **400 kill points**

Realistic team score range: **600-1600**. Target scoring balance: capture income should be roughly 2× kill points for a competent, objective-focused team; pure kill-farming teams should consistently lose to pure objective teams.

### Tuning Variables

| Variable | Type | MVP Value |
|----------|------|-----------|
| `match_duration_seconds` | int | 600 (10 min) |
| `income_rate_per_sec` | int | 1 (referenced from capture-point-system.md) |
| `kill_points_infantry` | int | 10 |
| `kill_points_vehicle_tank` | int | 50 |
| `kill_points_vehicle_heli` | int | 75 |
| `overtime_duration` | int | 60 (1 min) |
| `overtime_win_lead` | int | 50 |

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Kill dealt by RPG splash that hits 2 enemies simultaneously | Both kills credited. Score increases by `2 × kill_points_infantry`. | Each victim is an independent kill event |
| Kill where damage from 2 teammates contributed but only one dealt the lethal shot | Only the final-blow-dealer's team credited. No split. | Assist tracking deferred |
| Player suicides (fall off map post-MVP, RPG self-splash) | No kill points awarded to either team | Rule 7 |
| Player disconnects mid-match | Their team keeps their accumulated team score; their per-player stats frozen | Team score is the only score that matters |
| Capture point ownership changes mid-second (tick boundary) | Ownership at the moment of the 1 Hz capture tick is used | Deterministic tick timing |
| Team holds 3 points → captures at 3/sec | Correct; no cap on simultaneous point holdings | Designed, not a bug |
| Score tied at exactly 0-0 at timer expiry | OVERTIME triggers same as any other tie | Rule 12 |
| Score tied at match expiry AND OT expiry with 0 points scored during OT | DRAW | Rule 14 |
| Kill awarded during the same tick as timer expiry | Kill counts — processed before the expiry transition | Tick ordering |
| Damage dealt before match start (pre-ACTIVE) | No kill points; no score impact | Scoring only during ACTIVE/OVERTIME |
| OVERTIME starts, team immediately scores 50 lead in first 100ms | Instant win — no minimum OVERTIME duration | Sudden death is sudden |
| Team had score lead but lost it to decay (not possible — scores only go up at MVP) | N/A — scores monotonically increase at MVP | Clamped to 0; no erosion sources |
| Server crashes mid-OVERTIME | All connected clients see "server ended match" screen, return to menu, no winner | Per ADR-0001 no reconnect at MVP |
| Both teams held 0 capture points all match, both had 0 kills, score 0-0 | DRAW after OVERTIME (no one scores) | Theoretically possible, should be vanishingly rare |

## Dependencies

| System | Direction | Nature |
|--------|-----------|--------|
| Match state machine | Scoring depends on Match state | WARMUP/ACTIVE/OVERTIME/END gating |
| Capture point system | Scoring depends on Capture | Income source |
| Health/damage | Scoring depends on Health | Kill events |
| Team assignment | Scoring depends on Team | Score routing |
| Networking | Scoring depends on Networking | Replicated state, RPCs |
| HUD | HUD depends on Scoring | Score + timer display |
| Scoreboard | Scoreboard depends on Scoring | Per-player stats |
| Post-match summary UI | Post-match depends on Scoring | Final winner + scores |
| Respawn system | Respawn depends on Scoring | Disabled during END |
| Audio system | Audio depends on Scoring | Victory/defeat stings |

## Tuning Knobs

| Parameter | Current | Safe Range | Increase | Decrease |
|-----------|---------|-----------|----------|----------|
| `match_duration_seconds` | 600 (10m) | 300-1800 | Longer matches; attrition matters | Shorter; frantic |
| `income_rate_per_sec` | 1 | 1-5 | Capture dominates scoring | Kills dominate |
| `kill_points_infantry` | 10 | 5-50 | Pure-kill teams viable | Objective-only viable |
| `kill_points_vehicle_tank` | 50 | 25-150 | Heavy-focused gameplay | Tanks less valuable as targets |
| `kill_points_vehicle_heli` | 75 | 50-200 | Heli-hunting fantasy strong | Heli not a priority target |
| `overtime_duration` | 60 | 30-180 | Long tense OT | Quick resolution |
| `overtime_win_lead` | 50 | 25-200 | OT lasts longer | Quick sudden-death |

## Visual/Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|----------------|---------------|----------|
| Score update (capture tick) | Team score HUD number ticks up with a soft flash | Subtle coin-click (shared with capture-point tick) | Nice-to-have |
| Score update (kill) | Team score HUD flashes briefly with +10/+50/+75 text that fades | Distinct "score gain" chime | Should |
| Match timer final 10s | Timer text turns red and pulses | Ticking clock SFX | Must |
| Match timer final 3s | Timer text larger, louder pulse | Louder tick, higher pitch | Must |
| ACTIVE → OVERTIME transition | Screen edges gain red pulse; "OVERTIME — FIRST TO +50" banner | Dramatic "tie" sting + overtime musical cue | Must |
| OVERTIME lead achieved | Winning team gets "VICTORY" banner; losing team gets "DEFEAT" | Victory / defeat musical sting | Must |
| ACTIVE ending (no tie) | Same victory/defeat banners | Victory / defeat sting | Must |
| DRAW (OT expired) | "DRAW" banner, no colour favouritism | Low neutral chord | Must |
| Top player announced | Small tile on post-match UI with name, class, kills (MVP: in text screen) | — | Should |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| Team A score | HUD top-center-left | On change | Always during ACTIVE / OVERTIME |
| Team B score | HUD top-center-right | On change | Always during ACTIVE / OVERTIME |
| Match timer (mm:ss) | HUD top-center | 1 Hz | Always during ACTIVE / OVERTIME |
| OVERTIME banner | Center-top | On entry to OVERTIME | While OVERTIME |
| OVERTIME "lead needed" indicator | Near score | On change | While OVERTIME |
| Final score + winner (END screen) | Center, full-screen | Static | During END |
| Top player of match | Bottom of END screen | Static | During END |

## Acceptance Criteria

- [ ] Scores begin at 0-0 at transition from WARMUP to ACTIVE
- [ ] Capture tick at 1 Hz correctly applies `count_owned_points × 1` to each team's score
- [ ] Infantry kill awards exactly 10 kill points to the killer's team, 0 to victim's team
- [ ] Self-kills award 0 points to either team
- [ ] Timer counts down from 600 to 0 at exactly 1 Hz real-time (server authoritative)
- [ ] Timer reaching 0 triggers victory determination within 200 ms
- [ ] Higher-score team wins at timer expiry; tie triggers OVERTIME
- [ ] OVERTIME ends early when lead ≥ 50 points
- [ ] OVERTIME expiry without lead resolution produces DRAW
- [ ] All clients receive identical final score state within one network tick
- [ ] Per-player stats tracked during ACTIVE for post-match display
- [ ] No scoring during WARMUP or END states
- [ ] Performance: score tick + kill processing completes in < 1 ms server-side
- [ ] No hardcoded values — tuning loaded from `assets/data/match_scoring.tres`

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| Should the scoring allow early win on hitting a score cap (e.g., first to 2000)? | Designer | Day 10 playtest | MVP: no cap. Only timer or OT lead wins. |
| Should OT reset the scores (both back to 0) instead of continuing accumulated scores? | Designer | Day 10 playtest | MVP: continue accumulated. Lead-of-50 mechanic makes reset unnecessary. |
| Should a team get bonus points for holding all 3 capture points? (comeback-snowball risk) | Designer | Day 10 playtest | MVP: no bonus; flat income. |
| What counts as "top player" when stats are tied? | Designer | Sprint 4 | Tiebreaker: kills → fewest deaths → highest capture contribution |
| Should capture contribution appear in end-of-match display, or only on post-MVP scoreboard? | Designer | Sprint 4 | MVP: only kills shown in text end-screen |
| Round-based structure (multi-round matches) post-MVP? | Designer | Post-MVP | Deferred — MVP is single-round |
