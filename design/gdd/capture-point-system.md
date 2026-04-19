# Capture Point System

> **Status**: Draft (8/8 sections filled)
> **Author**: AI-assisted draft
> **Last Updated**: 2026-04-18
> **Implements Pillar**: Pillar 2 — *Every Tool Has A Counter* (defended points counter aggressive pushes); Pillar 3 — *Matches Start Fast* (objectives drive an always-clear goal)
> **MVP Scope**: 3 capture points on 1 map. Timed neutralize + capture. Income ticks while held.

## Overview

Capture points are the match's objective layer. Three fixed points on the
single MVP map — labelled **A**, **B**, and **C** — produce score income for
the team that controls them. A point is captured by having the team's players
stand inside its capture volume unopposed for the capture duration. If the
other team is present, the capture is **contested** and both timers pause. A
point owned by the opposing team must first be **neutralized** (reverted to
ownerless) before the opposite team can capture it. Ownership state is
authoritative on the server and broadcast to all clients via
MultiplayerSynchronizer. Captured points serve three purposes: (1) they
generate score over time, (2) they act as forward spawn anchors (see
respawn-system.md), and (3) they refill Assault reserve ammo (see
weapon-system.md).

## Player Fantasy

Capture points turn the map into a **territorial argument**. You are never
unsure what to do; the point is where the fight is. The moment a point flips
to your team's colour and the capture jingle plays, you earned that
territory — you held it long enough. The moment an enemy begins contesting,
the fight is on your terms because you chose the ground. Holding a point in
a 1v3 defence as your capture timer ticks down is the quintessential clutch
moment the concept promises in Pillar 1. Losing a point mid-capture because
one teammate rotated too late is the quintessential "we got out-played"
teaching moment. The point is always readable — colour, symbol, timer, radius
marker on the ground — so every player always knows where they stand.

## Detailed Design

### Core Rules

1. Three capture points exist on the MVP map: **A** (Team A base-adjacent), **B** (centre of map), **C** (Team B base-adjacent).
2. At match start: A is owned by Team A, C is owned by Team B, B is neutral. Teams start with their home point captured.
3. Each capture point has a **capture volume** — a vertical cylinder with radius `capture_radius` and height `capture_height` centred on the point's ground marker. Players inside the volume are considered "present on the point".
4. Server evaluates capture state every `capture_tick_rate` seconds (10 Hz). Results are broadcast to all clients at 30 Hz via MultiplayerSynchronizer.
5. **Neutral state**: the point is unowned, no income, shows grey marker. Occurs at match start for B, or when a previously-owned point has been fully neutralized.
6. **Owned state**: a team has fully captured the point. The owning team receives income at `income_rate_per_sec` per second per owned point. Shows team colour (blue/red).
7. **Capturing state**: one team (and only one team) has members inside the capture volume while the point is neutral. A timer `capture_progress` fills from 0 to `capture_duration` seconds. When full, the point flips to Owned by that team.
8. **Neutralizing state**: one team (and only one team) has members inside the volume while the point is owned by the other team. The `capture_progress` counts backward from `capture_duration` to 0. At 0, the point becomes Neutral (not Owned by the neutralizing team) and the UI plays a neutralize sound.
9. To capture an enemy-owned point from scratch, the attacking team must neutralize it first (progress 100% → 0%) and then capture from neutral (progress 0% → 100%). Total time = `capture_duration × 2`.
10. **Contested state**: both teams have at least one member inside the volume. Capture progress **pauses** in whatever direction it was moving (does not reset, does not swap direction). Contested UI shows crossed-swords icon and coloured outline.
11. Dead players do not count as present on the point (their body/ragdoll does not occupy volume).
12. Players in vehicles do not count as present on the point. Exiting a vehicle to stand on the point is required.
13. Capture progress is clamped to `[0, capture_duration]`.
14. A point's state and `capture_progress` are visible on the HUD at all times (see hud.md).
15. Sound cues play on state transitions (see Visual/Audio).
16. Capture-point ownership directly feeds match scoring (see match-scoring.md): a team's income accumulates per-second as `sum(owned points) × income_rate_per_sec`.
17. Capture-point ownership feeds the respawn system: a player may spawn at their team base OR at any capture point owned by their team (see respawn-system.md).
18. Standing on a capture point owned by your team refills Assault reserve ammo (see weapon-system.md).

### Capture Speed Scaling (multi-player stacking)

Multiple teammates on the point capture faster, up to a cap:

| Presence (same team) | Speed Multiplier |
|----------------------|------------------|
| 1 player | 1.0× |
| 2 players | 1.5× |
| 3+ players | 2.0× (cap) |

This is applied to both capturing and neutralizing. Enables defensive
"zerg clear" but caps the benefit so solo plays remain viable.

### States and Transitions

| State | Entry Condition | Exit Condition | Behavior |
|-------|----------------|----------------|----------|
| Neutral | Match start (B) OR progress reaches 0 from a Neutralizing state | Single team enters the volume | No income. Marker grey. |
| Capturing | Single team enters volume while Neutral | Progress full (→ Owned), OR other team enters (→ Contested), OR capturing team leaves (→ Neutral with partial progress) | Progress 0 → `capture_duration`, scaled by stacking. Marker pulses team colour. |
| Owned | Progress completes from Capturing | Enemy team enters volume (→ Neutralizing) | Income ticks every second. Marker solid team colour. |
| Neutralizing | Enemy team enters a team-Owned point | Progress 0 (→ Neutral), OR defender team enters (→ Contested), OR neutralizing team leaves (→ Owned with partial progress) | Progress `capture_duration` → 0. Marker flashes with defender + attacker colours. |
| Contested | Both teams present in volume | One team leaves (→ resumes previous non-contested state) | Progress frozen. Crossed-swords icon overlay. |

State persistence when a team leaves:
- If Capturing and capturing team leaves with partial progress, state reverts to **Neutral**, but `capture_progress` retains its value (does not reset to 0). Progress decays at `decay_rate` per second toward 0 while neutral and empty.
- If Neutralizing and neutralizing team leaves with partial progress, state reverts to **Owned**, `capture_progress` retains, decays at `decay_rate` per second toward `capture_duration`.

This prevents "hit-and-run" capture flipping but also prevents permanent
locked-partial-capture states.

### Interactions with Other Systems

| System | Interaction | Direction |
|--------|-------------|-----------|
| **Match scoring** | Provides per-second income per owned point to scoring pipeline | Capture → Match scoring |
| **Respawn system** | Provides list of team-owned spawn anchors | Capture → Respawn |
| **Weapon system** | Ammo refill at own-team-owned points | Capture → Weapon |
| **Team assignment** | Capture system queries which team a player belongs to when counting presence | Team → Capture |
| **Networking (ADR-0001)** | Ownership state + progress replicated via MultiplayerSynchronizer; transitions fire RPC events | Capture ↔ Networking |
| **Player controller** | Capture system queries player position + alive/dead state to count presence | Player controller → Capture |
| **Vehicle base** | Excludes players in vehicles from presence counts | Vehicle base → Capture |
| **HUD** | Displays state, progress, presence indicators | Capture → HUD |
| **VFX system** | Capture point spawns particle effects per state (neutralize plume, capture flash) | Capture → VFX |
| **Audio system** | State transitions fire SFX (neutralize siren, capture jingle) | Capture → Audio |
| **Match state machine** | Capture points become active during ACTIVE match state, frozen during WARMUP and END | Match state → Capture |

## Formulas

### Capture Progress

Per server tick (10 Hz, so `dt = 0.1s`):

```
presence_own = count_alive_same_team_inside_volume(point)
presence_enemy = count_alive_enemy_team_inside_volume(point)

if presence_own > 0 and presence_enemy > 0:
    # Contested — no change
    pass
elif presence_own > 0 and state in (NEUTRAL, CAPTURING):
    speed = capture_speed_multiplier(presence_own)
    progress += speed * dt
elif presence_enemy > 0 and state in (OWNED, NEUTRALIZING):
    speed = capture_speed_multiplier(presence_enemy)
    progress -= speed * dt
elif presence_own == 0 and presence_enemy == 0:
    # Decay toward home state
    if state == CAPTURING and progress > 0:
        progress -= decay_rate * dt
    elif state == NEUTRALIZING and progress < capture_duration:
        progress += decay_rate * dt

progress = clamp(progress, 0, capture_duration)
resolve_state_transition()
```

### Capture Speed Multiplier

```
capture_speed_multiplier(presence) =
    1.0 if presence == 1
    1.5 if presence == 2
    2.0 if presence >= 3
```

### Income Rate

```
income_per_tick_per_team = count_owned_points(team) × income_rate_per_sec × dt
```

**MVP values**: `income_rate_per_sec = 1`, `dt = 1.0` (income ticks once per second, not per 10 Hz).

Example: Team A owns A and B, Team B owns C. Per second: Team A gains 2, Team B gains 1.

### Tuning Variables

| Variable | Type | MVP Value | Notes |
|----------|------|-----------|-------|
| `capture_radius` | float (m) | 6.0 | Capture cylinder radius |
| `capture_height` | float (m) | 3.5 | Vertical extent (covers upstairs) |
| `capture_duration` | float (s) | 10.0 | Time to fully capture from neutral by 1 player |
| `capture_tick_rate` | float (Hz) | 10.0 | Server eval rate; sync at 30 Hz |
| `income_rate_per_sec` | int | 1 | Score points per second per owned point |
| `decay_rate` | float (unit/s) | 1.0 | Progress decay when volume empty |

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| 5 teammates + 1 enemy on point | Contested (progress pauses) | One enemy is enough to contest regardless of numbers |
| Player captures point, then dies in volume | Presence count decreases immediately on death | Ragdoll/corpse does not count |
| Player enters vehicle while on point | Presence count decreases immediately | Vehicle occupancy excludes from point |
| Player with RPG splash-kills own teammate standing on point | No friendly fire at MVP — teammate lives, presence unchanged | Per weapon-system.md rule 22 |
| Match starts mid-capture (should not happen but defensive) | State initializes to declared starting ownership; any in-progress values cleared | Deterministic match start |
| Point ownership flips between two states within one tick | Only final resolved state fires the transition RPC | Prevent duplicate sound/VFX triggers |
| All 10 players crammed on one point | Capture speed caps at 2× regardless | Per multiplier cap |
| Point neutralized while enemy still on it (0 progress) | Enters Neutral state. Enemy players' presence now drives a fresh capture in their favour. | Must commit to full neutralize-then-capture cycle |
| Team captures B while both teams fighting at C | B capture proceeds normally, C contested — independent | Each point is independent state machine |
| Player stands on point while match state = WARMUP | No effect; capture logic frozen | Capture only runs during ACTIVE |
| Player disconnects while solo-capturing | Presence drops to 0, progress begins decaying per `decay_rate` | No sudden capture completion |
| Two teammates on point; one is revived after being dead (post-MVP feature) | Revived player counted once alive; no double-count | Alive check is per-tick |

## Dependencies

| System | Direction | Nature |
|--------|-----------|--------|
| Match state machine | Capture depends on Match state | Only tick during ACTIVE |
| Team assignment | Capture depends on Team | Classify presence |
| Player controller | Capture depends on Player controller | Position + alive state |
| Networking (ADR-0001) | Capture depends on Networking | State replication, transition RPCs |
| Vehicle base | Capture depends on Vehicle base | Exclude drivers/passengers from presence |
| Match scoring | Match scoring depends on Capture | Income is computed from owned-points |
| Respawn system | Respawn depends on Capture | Spawn anchors = owned points |
| Weapon system | Weapon depends on Capture | Reserve ammo refill |
| HUD | HUD depends on Capture | Progress bars, indicators |
| VFX system | VFX depends on Capture | Triggered particle effects |
| Audio system | Audio depends on Capture | State transition SFX |

## Tuning Knobs

| Parameter | Current | Safe Range | Increase | Decrease |
|-----------|---------|-----------|----------|----------|
| `capture_radius` | 6.0m | 3.0-12.0 | Easier to contest | Tight — favors defender |
| `capture_height` | 3.5m | 2.5-6.0 | Covers rooftop plays | Only ground-level |
| `capture_duration` | 10.0s | 5.0-30.0 | Slower tempo, defensive advantage | Fast flips, aggressive play |
| `income_rate_per_sec` | 1 | 1-5 | Points matter more | Kills matter more |
| `capture_speed_multiplier[2]` | 1.5× | 1.0-2.0 | Stack-rushing strong | Solo viable |
| `capture_speed_multiplier[3+]` | 2.0× | 1.0-3.0 | Team-capture overwhelming | Single capture dominates |
| `decay_rate` | 1.0 unit/s | 0-3.0 | Progress erodes fast on exit | Partial progress sticky |
| `match_start_ownership` | A-to-Team-A, C-to-Team-B, B-neutral | — | — | Could randomize in post-MVP |

## Visual/Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|----------------|---------------|----------|
| Player enters capture volume | Crosshair gains "capture radius" indicator; point icon highlights | Soft whoosh SFX | Should |
| Capture progress ticking | Progress bar fills on HUD; 3D marker pulses team colour | Heartbeat-style tick, pitch rises with progress | Must |
| Point neutralized | Marker turns grey; flag/obelisk lowers; central VFX plume (dust kick) | Distinct neutralize siren (descending 3-note) | Must |
| Point captured (fresh, from Neutral) | Marker flips to team colour; flag raises; coloured light flash | Capture jingle (rising 3-note + bass punch) | Must |
| Point captured (taken from enemy) | Same as above, louder | Combined neutralize + capture — 6-note sweep, louder | Must |
| Contested | Crossed-swords icon overlay on HUD marker; yellow pulse on ground ring | Rising tension drone (low-volume, loops while contested) | Must |
| Income tick | Score HUD number ticks up with subtle flash | Low-volume coin-click SFX, once per second while owned | Nice-to-have |
| Capture progress lost (team left without completing) | Progress bar shrinks on HUD; ground ring fades | Descending chime on state revert | Should |
| Point icon on HUD updates | Mini-icon changes colour / symbol | — | Must |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| Three point mini-icons (A, B, C) with ownership colour | HUD top-center | On state change | Always during match |
| Progress bar per point | Under each mini-icon | 30 Hz while capturing/neutralizing | When progress non-boundary |
| "Contested" indicator | Over current-point mini-icon | On enter contest | While contested |
| Local-player capture radius (when standing in volume) | 3D ring on ground under player | Real-time | While inside volume |
| Point label (A/B/C) floating world-space | Above each capture volume | Real-time | Always |
| Team score (derived from income) | HUD top-center | 1 Hz | Always during match |
| Capture/neutralize timer text | Center-top on current point | 10 Hz | While progressing |

## Acceptance Criteria

- [ ] Three capture points exist on the MVP map with correct starting ownership (A=A, C=B, B=Neutral)
- [ ] Capture volume is a 6m-radius × 3.5m-height cylinder
- [ ] A solo player captures a neutral point in exactly 10 seconds (server-verified)
- [ ] Two teammates capture in 10 / 1.5 = ~6.67 seconds; 3+ in 5 seconds
- [ ] An enemy-owned point requires 20 seconds total to capture (10 neutralize + 10 capture), solo
- [ ] Contested state freezes progress in both directions
- [ ] A team leaving the volume causes `decay_rate`-per-second drift toward the home state
- [ ] Income ticks score +1/sec per owned point at the match scoring layer
- [ ] State transitions fire the correct VFX/SFX on server-authoritative transition (not on client prediction)
- [ ] Dead players and vehicle-occupants are excluded from presence counts
- [ ] Ownership and progress are visible on HUD for all 3 points at all times during ACTIVE match state
- [ ] Performance: capture tick evaluation completes in < 1 ms server-side across all 3 points
- [ ] No hardcoded values — all tuning knobs loaded from `assets/data/capture_points.tres`

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| Should overtime trigger if a capture is in progress at time-expiry? | Designer | Sprint 3 | TBD — see match-scoring.md |
| Should the center point (B) grant bonus income (e.g., 2×) to encourage midfield fights? | Designer | Day 10 playtest | TBD — MVP is flat 1/sec |
| Capture point assignable as "no-spawn" flag for attacker-only points (future gamemode)? | Designer | Post-MVP | Deferred |
| Should progress decay rate differ per point (e.g., home points decay faster)? | Designer | Day 10 playtest | TBD — MVP uniform |
| Voice line / announcer on capture? | Audio director | Post-MVP | Deferred (no VO at MVP) |
