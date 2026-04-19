# Respawn System

> **Status**: Draft (8/8 sections filled)
> **Author**: AI-assisted draft
> **Last Updated**: 2026-04-18
> **Implements Pillar**: Pillar 3 — *Matches Start Fast* (fast respawn keeps tempo); Pillar 1 — *Skill Is The Ceiling* (short death penalty — one bad duel does not end a session)
> **MVP Scope**: 5-second respawn timer. Spawn at team base OR any team-held capture point. Class reselection on respawn.

## Overview

When a player's HP reaches 0, they enter the **dead** state. A 5-second
respawn timer counts down, during which the player watches a death-cam
perspective (spectator view of their killer or a fixed overhead fallback)
and selects their respawn location and class for the next life. When the
timer expires, the player is re-spawned at the selected location with
full HP, full ammo reserves, and their chosen class's weapon. A brief
2-second spawn protection period grants invulnerability and disabled
firing. The respawn system is authoritative on the server per ADR-0001;
the server validates that selected spawn points are valid (team-owned or
home base) at the moment of respawn.

## Player Fantasy

Death is a short beat, not a setback. The 5-second timer is long enough
to register "I got out-played" but short enough that you never lose the
thread of the match. Choosing your respawn point is a tactical decision
— do you push to the contested B point and rejoin the fight fast, or
fall back to base and rotate with the group? Every respawn is a chance
to reset strategy, swap class if the match demands it, and launch back
into the match. The fantasy is never "I'm benched waiting" — it is
"I'm already thinking about my next play."

## Detailed Design

### Core Rules

1. A player enters the **Dead** state when HP reaches 0 from any damage source (weapon, splash, fall, vehicle).
2. On death, the server sends `on_player_killed` RPC to all clients, which triggers kill-feed, death-cam, and respawn-UI state.
3. `respawn_timer` starts at `respawn_duration` seconds and decrements on the server at 10 Hz. Clients display a smooth 30 Hz countdown.
4. During the timer, the player sees the **respawn UI** with two interactive panels: (a) class selection (Assault / Heavy), (b) spawn location selection (Team Base + list of team-held capture points).
5. If the player does not choose a class, the previous class is retained. If the player does not choose a spawn, the default is **Team Base**.
6. At timer expiry, the server spawns the player at the chosen location and sets HP to `player_max_hp` (100), full mag, full reserve (Assault), cooldown reset (Heavy), cleared debuffs, and class loadout applied.
7. The spawned player is in **Spawn Protection** state for `spawn_protection_duration` seconds. During this state: invulnerable to all damage, cannot fire their weapon, appears translucent to both teammates and enemies.
8. Spawn protection ends early if the player fires their weapon (the player may opt out of invulnerability to shoot).
9. Spawn protection ends early if the player moves more than `spawn_protection_break_distance` metres from the spawn point.
10. The player may not change class mid-life after Spawn Protection ends.
11. Dead players are excluded from capture-point presence counts (per capture-point-system.md rule 11).
12. If all of a team's capture points are lost during a player's respawn timer, options reduce to Team Base only. UI updates in real-time.
13. If the team loses control of the player's selected spawn point during the timer, selection reverts to Team Base.
14. The player cannot cancel their respawn timer to respawn earlier.
15. Team Base has **4 fixed spawn pads**. On spawn at Base, the system picks the pad with the greatest distance to the nearest enemy (anti-spawn-camp).
16. Capture point spawn: the player spawns at the edge of the capture volume on the side **facing outward from the map center** (less likely to spawn directly into a defender standing on the point).
17. If the selected capture point is contested at respawn moment, spawn is delayed 1 additional second and then forced to Team Base (to avoid spawning into combat).
18. Respawn does not occur during match state `WARMUP` or `END` — players remain dead until next match or return-to-menu.
19. Disconnecting during death removes the player from the match entirely; no re-queue to the same match.

### States and Transitions

| State | Entry Condition | Exit Condition | Behavior |
|-------|----------------|----------------|----------|
| Alive | Respawn | HP reaches 0 | Normal gameplay |
| Dead (countdown) | HP = 0 | Timer expires | Respawn UI + death-cam; timer runs |
| Respawning | Timer expires | Spawn Protection begins | Server teleports player to spawn point, restores HP/ammo, re-binds class loadout |
| Spawn Protection | Spawn complete | Duration elapses OR fires weapon OR moves out of protection radius | Invulnerable, cannot fire, translucent |
| Alive (normal) | Spawn protection ends | HP reaches 0 | Normal gameplay |
| Match Suspended | Match state != ACTIVE | Match state = ACTIVE OR returns to menu | No respawn occurs |

### Interactions with Other Systems

| System | Interaction | Direction |
|--------|-------------|-----------|
| **Health/damage** | Provides the death signal (HP = 0) | Health → Respawn |
| **Class loadout** | Provides class selection UI and applies chosen class on spawn | Class loadout ↔ Respawn |
| **Weapon system** | Resets ammo / cooldowns on spawn | Weapon ↔ Respawn |
| **Capture point system** | Provides list of currently-owned capture points as spawn options | Capture → Respawn |
| **Team assignment** | Filters capture-points to same-team owned | Team → Respawn |
| **Match state machine** | Respawn disabled outside ACTIVE state | Match state → Respawn |
| **Networking (ADR-0001)** | Death + respawn RPCs routed server-authoritative | Respawn ↔ Networking |
| **Player controller** | Respawn teleports player via controller's warp API | Respawn → Player controller |
| **Camera** | Death triggers death-cam mode; respawn returns to over-shoulder | Respawn → Camera |
| **HUD** | Respawn UI, timer, spawn selection panels | Respawn → HUD |
| **VFX system** | Spawn emergence VFX (materialize shimmer) | Respawn → VFX |
| **Audio system** | Spawn-in SFX, death-sting on-death | Respawn → Audio |

## Formulas

### Respawn Timer

```
respawn_progress(t) = max(0, respawn_duration - (t - time_of_death))
```

**MVP value**: `respawn_duration = 5.0s`.

### Spawn Selection Priority

When the player does not explicitly select a spawn:

```
default_spawn = TEAM_BASE
```

If the player selected a capture point but it is no longer valid at respawn moment:

```
fallback_spawn = TEAM_BASE
```

### Base Spawn Pad Selection

```
spawn_pad = argmax(
    min(distance(pad, enemy) for enemy in alive_enemies)
    for pad in base_pads
)
```

Select the pad that is farthest from the nearest enemy.

### Capture-Point Spawn Position

```
spawn_position = capture_point.center + capture_point.outward_vector * capture_radius * 0.9
```

`outward_vector` is the pre-authored direction pointing away from map center. Spawn is placed 0.9 × radius outward so the player is just inside the capture volume.

### Spawn Protection Break — Distance

```
distance_moved = (current_position - spawn_origin).length
if distance_moved > spawn_protection_break_distance:
    end_spawn_protection()
```

**MVP value**: `spawn_protection_break_distance = 5.0m`.

### Tuning Variables

| Variable | Type | MVP Value |
|----------|------|-----------|
| `respawn_duration` | float (s) | 5.0 |
| `spawn_protection_duration` | float (s) | 2.0 |
| `spawn_protection_break_distance` | float (m) | 5.0 |
| `contested_capture_spawn_delay` | float (s) | 1.0 |
| `base_spawn_pad_count` | int | 4 |
| `player_max_hp` | int | 100 |

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Player dies to splash damage from RPG, multiple teammates also in radius | Each player's death processed independently | Per-player respawn timer |
| Player dies during the respawn-timer of another teammate | Independent state — no interaction | Each player has own respawn lifecycle |
| Team loses the only capture point the player had selected mid-timer | Selection reverts to Team Base; UI updates | Rule 13 |
| Team captures a new point mid-timer | New option appears in spawn UI | Real-time UI update |
| Player respawns while the server is processing a match-end | Respawn cancelled; player enters spectator-like state until match END RPC | Match state transition takes priority |
| Player tries to fire during Spawn Protection | Fire input accepted, ends Spawn Protection immediately, then fires | Opt-out of invulnerability is intentional |
| Enemy approaches Spawn Protection player and tries to damage | Damage rejected server-side; no HP change, no hit marker for enemy | Invulnerability is absolute |
| Player moves > 5m away during Spawn Protection | Protection ends | Cannot abuse protection for positioning |
| Base is surrounded by enemies (spawn-camp) | Spawn picks pad farthest from nearest enemy (per algorithm) | Algorithmic anti-camp; no manual override |
| All 4 base spawn pads are within 5m of enemies | Spawn still occurs at the farthest pad; spawn-camp is a design risk accepted at MVP | Per concept risk-acceptance |
| Player dies at exact match-end tick | Death processed, but no respawn occurs — match END supersedes | Match state check |
| Player disconnects during respawn timer | Player removed from match on disconnect; no phantom respawn | Disconnect = leave |
| Capture-point spawn position would place player inside geometry | Designer must author map so this cannot occur; if it does, server falls back to Team Base and logs an error | Authoring contract |
| Player's selected class no longer exists (e.g., class-cap reached mid-timer) | Fallback to previous class; UI flashes "class unavailable" | Per class-loadout-system.md |

## Dependencies

| System | Direction | Nature |
|--------|-----------|--------|
| Health/damage | Respawn depends on Health | Death signal |
| Class loadout | Respawn depends on Class loadout | Class selection UI, class applied |
| Weapon system | Respawn depends on Weapon | Reset state on respawn |
| Capture point system | Respawn depends on Capture | Spawn anchor list |
| Team assignment | Respawn depends on Team | Same-team capture filter |
| Match state machine | Respawn depends on Match state | Only runs during ACTIVE |
| Player controller | Respawn depends on Player controller | Teleport API |
| Camera | Respawn depends on Camera | Death-cam transition |
| Networking | Respawn depends on Networking | Server authority |
| HUD | HUD depends on Respawn | Respawn UI, timer |
| VFX | VFX depends on Respawn | Materialize effect |
| Audio | Audio depends on Respawn | Spawn SFX |

## Tuning Knobs

| Parameter | Current | Safe Range | Increase | Decrease |
|-----------|---------|-----------|----------|----------|
| `respawn_duration` | 5.0s | 3.0-15.0 | Matches punish death more; slower rotation | Almost no penalty; chaotic |
| `spawn_protection_duration` | 2.0s | 0.5-5.0 | Longer safety from camp | Spawn-camp risk |
| `spawn_protection_break_distance` | 5.0m | 2.0-20.0 | Player can get full Out-of-spawn before ending | Protection ends fast |
| `base_spawn_pad_count` | 4 | 2-8 | More options, less camp | Predictable spawns |
| `contested_capture_spawn_delay` | 1.0s | 0-3.0 | More delay for risky spawns | Fast-rotate into fight |
| `player_max_hp` | 100 | 75-150 | Tankier, longer TTK | Glass cannon |

## Visual/Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|----------------|---------------|----------|
| Death | Screen red flash → fade to grey; death-cam transition | Death sting (low, descending) | Must |
| Death-cam (following killer) | Camera smoothly transitions to killer perspective; killer name/class displayed | Muffled ambient | Should |
| Respawn UI appears | Panel slides up from bottom; timer prominent | Subtle UI click | Must |
| Timer ticking | Timer text counts down; last 1s pulses red | Tick SFX at 1s intervals in final 3s | Should |
| Spawn location selected | Selected panel glows team colour | Select click SFX | Should |
| Spawn occurs | Materialize VFX (particle swirl + teleport flash) | Spawn-in whoosh SFX | Must |
| Spawn Protection active | Player model translucent with team-coloured outline; small "SHIELD" icon above head | Gentle hum loop | Must |
| Spawn Protection ends | Opacity returns to full; icon disappears | Soft chime | Should |
| Team loses capture point mid-timer (selected one) | Respawn UI flashes red on that option, reverts selection to Base | Alert beep | Should |
| Fall-damage / suicide (post-MVP: currently no fall damage) | — | — | N/A at MVP |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| Respawn timer (big number) | Center of screen | 30 Hz | While dead |
| Class selection panel | Left side of respawn UI | On team class counts change | While dead |
| Spawn location panel | Right side of respawn UI | On capture-point ownership change | While dead |
| Team base icon (always available) | Top of spawn location panel | Static | While dead |
| Each capture point icon (A/B/C) with availability state | Spawn location panel | Real-time | While dead |
| Selected spawn location indicator | Highlighted icon + team-coloured outline | On selection | While dead |
| Killer name + class | Top-center | Static | While dead (after `on_player_killed` RPC) |
| Death reason ("Killed by X with AK") | Kill feed (standard, not respawn UI) | On kill | Kill feed standard |
| Spawn Protection remaining | Small radial timer above player model | 30 Hz | During Spawn Protection |

## Acceptance Criteria

- [ ] On HP = 0, player enters Dead state and respawn UI appears within 200 ms
- [ ] Respawn timer expires at exactly 5.0 s from time of death (server-authoritative)
- [ ] Player can select class and spawn location during timer; changes persist until respawn
- [ ] Default spawn = Team Base if no explicit selection
- [ ] Default class = previous class if no explicit selection
- [ ] Respawning at a capture point positions player at outer edge of capture volume
- [ ] Base spawn picks farthest pad from nearest alive enemy (verified with 4-pad test, 3 enemy positions)
- [ ] Selected capture point that becomes enemy-owned mid-timer reverts selection to Base
- [ ] Spawn Protection lasts 2.0 s or until player fires OR moves > 5.0 m from spawn origin
- [ ] Damage to Spawn-Protected player is rejected server-side (no HP change)
- [ ] Dead player is excluded from capture-point presence counts
- [ ] No respawn occurs during match WARMUP or END state
- [ ] Performance: respawn server-side logic completes in < 5 ms per respawn event
- [ ] Contested-capture spawn applies 1s additional delay and forces Base

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| Should there be a "respawn wave" mechanic (multiple teammates respawn together)? | Designer | Day 10 playtest | MVP: no. Individual respawn. |
| Should killcam replay the last 2s of death (à la CS:GO)? | Designer | Post-MVP | Deferred — plain spectator cam at MVP |
| Should Base spawn include a spawn-room no-enter zone for enemies? | Designer | Day 10 playtest | MVP: no — rely on the pad-distance algorithm |
| Can the player queue a spawn *during* Spawn Protection (e.g., pre-select next spawn)? | Designer | Post-MVP | MVP: no. Single active selection only. |
| Should dying to self-damage (RPG close-range) reduce respawn timer as a mercy mechanic? | Designer | Post-MVP | No — accept player error |
| Fall damage / out-of-bounds death handling? | Designer | Sprint 3 | TBD — MVP map should prevent via geometry |
