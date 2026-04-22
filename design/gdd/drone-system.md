---
status: reverse-documented
source: src/gameplay/drone/drone_controller.gd
scenes: scenes/drone/drone.tscn
date: 2026-04-21
---

# Drone System (Kamikaze FPV)

> **Status**: Draft (8/8 sections filled, reverse-documented)
> **Author**: AI-assisted reverse-engineering of existing implementation
> **Last Updated**: 2026-04-21
> **Implements Pillar**: Pillar 2 — *Every Tool Has A Counter* (drone counters entrenched infantry; infantry counters drone with AK/timing); Pillar 1 — *Skill Is The Ceiling* (flight + aim skill decides outcomes)
> **MVP Scope**: **Promoted from Post-MVP to MVP** per implementation on 2026-04-21. Kamikaze FPV drone as a shared map pickup vehicle. One-pilot-at-a-time. Sacrifices pilot's current life for a high-damage strike.

> **Note**: Drone was originally deferred to Post-MVP patch 1 per
> design/gdd/systems-index.md § Priority Tiers. Implementation in
> src/gameplay/drone/ (committed 2026-04-20 per git log "fpv drone added")
> promotes it to MVP. This GDD reverse-documents the implemented behavior
> and establishes design intent for how it fits into the match loop.

## Overview

The Drone System adds a **kamikaze FPV vehicle** as a shared battlefield
asset: a small, fast, fragile flying bomb piloted in first-person view from
a designated pad on the map. Any infantry player can enter the drone's pad
and assume control; only one pilot may operate the drone at a time. The
drone flies via Mode-2 acro controls (WASD + mouse for full 6-DOF freedom),
and its primary purpose is a **controlled-collision kill**: a high-speed
impact on any target deals 999 damage (one-shot kill) and destroys the
drone. Destroyed drones respawn at the pad after a 1.5-second delay,
leaving a burning wreck at the impact site. The drone's pilot returns to
their body at the pad when they exit the drone cleanly (via vehicle switch)
or is killed if the drone is destroyed before they exit.

## Player Fantasy

The drone is the **asymmetric threat**. A single skilled drone pilot can
flip the course of a match by landing a kamikaze strike on a helicopter,
a tank's flank, or a clustered infantry squad. The fantasy is **the
suicide run** — piloting first-person at dangerous speeds through tight
corridors, seeing the enemy through your own drone's camera, and committing
to an impact that you cannot back out of. You are not a duelist; you are a
missile with a human brain. Every mission has a one-chance feel: if you
miss, you have given up your position and must recover.

For defenders, the fantasy is the inverse: the **distant buzz** that warns
a drone is inbound, the quick pivot to AK fire, the satisfying pop as the
drone fragments midair. Drones are intentionally audible (buzz SFX) so
defenders always have a fair chance to react.

## Detailed Design

### Core Rules

1. One drone exists on the map at any time, parked at a fixed **drone pad** (authored by the map designer). Drone respawns at this pad after destruction.
2. Any infantry player can interact with the pad (stand on it + press the interact key) to **enter** the drone. Entry replaces the player's third-person camera with the drone's first-person mount camera. The player's body remains at the pad and is dealt with when they exit or die.
3. A drone may have **at most one pilot** at any time. If occupied, the interact prompt on the pad shows "occupied" and cannot be entered.
4. Flight controls (Mode 2 acro):
   - **W / S** — throttle up / down (accumulator 0..1, NOT a held-input — throttle persists between frames)
   - **A / D** — yaw left / right (continuous rate × delta)
   - **Mouse X** — roll (body rotation around local forward axis)
   - **Mouse Y** — pitch (body rotation around local right axis; forward mouse = nose down)
5. Thrust is applied along the drone's local UP axis (body orientation determines thrust direction). Tilt = translation.
6. Gravity applies continuously. At `hover_throttle = 0.5`, thrust equals gravity and the drone hovers. Above = climb, below = descend.
7. No auto-leveling. When the mouse stops moving, the drone holds its current angle. This is intentional pure-acro feel per Open Source racing drone convention.
8. Camera is rigid-mounted to the drone body with a static 30° upward tilt — the pilot sees forward while flying nose-down at speed (matching real racing-drone practice).
9. Maximum altitude is clamped to `max_altitude = 50 m` (matches helicopter ceiling from helicopter-controller.md).
10. Kamikaze detection: on any physics-slide collision, if `pre_slide_velocity.length >= kamikaze_speed_threshold` (default 6.0 m/s), the collision qualifies as kamikaze.
11. Kamikaze effect:
    - If collider has a `HealthComponent`, apply `kamikaze_damage = 999` damage with source `DamageTypes.Source.DRONE_KAMIKAZE` → one-shot kill any target including tanks and helicopters at MVP values.
    - The drone also damages itself with 999 (self-destruct) — triggers its own destroyed state.
12. Non-kamikaze collisions (below threshold) bounce/slide without damage — you can land softly on a pad or nudge geometry without detonating.
13. On destruction:
    - Drone enters "wreck mode" (no input, gravity-only fall, no propeller animation)
    - `DestructionVFX.apply_charred()` and `DestructionVFX.spawn_smoke_fire()` applied to wreck
    - A `respawn_delay = 1.5 s` timer is started
    - At timeout, drone teleports back to spawn transform, clears destruction VFX, resets health, emits `respawned` signal
14. The `respawned` signal is listened to by the FPV HUD, which clears the "DRONE OFFLINE" overlay.
15. Linear damping (horizontal 1.5/s, vertical 0.8/s) ensures the drone slows down when the pilot is not actively thrusting — prevents runaway slides.
16. 12 propeller blades in 4 motor groups are animated programmatically, rotating at a rate that scales from `idle_rotor_speed_rad_per_sec` (16) to `max_rotor_speed_rad_per_sec` (60) with throttle. When parked on the floor at near-zero throttle, rotors coast to a stop.
17. The drone is a `CharacterBody3D` (not a `RigidBody3D`) — motion uses `move_and_slide()` with explicit velocity manipulation. This gives deterministic behavior for multiplayer sync (vs. physics integration which is non-deterministic).
18. Input is captured only when `_active == true`. `set_active(true/false)` is the public API used by the vehicle switcher to toggle between infantry and drone views.

### Pilot / Drone / Body State Model

| State | Actor | Visible From | Notes |
|-------|-------|-------------|-------|
| Infantry | Player on foot | Third-person over-shoulder (see camera-system.md) | Normal gameplay |
| Entering Drone | Player interacting with pad | Transition (brief fade) | Brief lockout during swap |
| Piloting Drone (alive) | Drone + pilot coupled | Drone FPV camera | Input controls drone |
| Piloting Drone (self-destruct initiated) | Kamikaze collision detected | Drone FPV → spectator of wreck | 1.5s wreck-fall view |
| Pilot Returning (drone respawned OR exited) | Pilot body | Third-person over-shoulder | Pilot resumes infantry control |
| Pilot Dead (drone destroyed without safe exit) | Pilot body | Respawn UI (see respawn-system.md) | Drone destruction kills pilot too |

Note: the **pilot's life is forfeit when the drone kamikazes**. The player
is not teleported back to their body — they enter the normal respawn flow
(5s timer, choose class + spawn location). This is the intended trade:
pilot's own respawn-lifetime for a one-shot kill on a high-value target.

### Interactions with Other Systems

| System | Interaction | Direction |
|--------|-------------|-----------|
| **Vehicle switcher** (`vehicle_switcher.gd`) | Handles player ↔ drone swap on pad interaction | Vehicle switcher ↔ Drone |
| **Health/damage** | Drone has its own `HealthComponent`; takes damage from AK/RPG/environment | Health ↔ Drone |
| **Combat framework** | `DamageTypes.Source.DRONE_KAMIKAZE` tags kamikaze damage for kill feed | Drone → Combat |
| **Destruction effects** | On destroy: `apply_charred` + `spawn_smoke_fire`. On respawn: `clear_charred` + `clear_vfx`. | Drone ↔ Destruction effects |
| **Networking (ADR-0001)** | Drone position + rotation + throttle replicated via MultiplayerSynchronizer at 30 Hz; RPC for kamikaze event | Drone ↔ Networking |
| **Camera system** | FPV camera replaces orbit/chase camera while piloting | Drone ↔ Camera |
| **Input system** | WASD + mouse consumed by drone controller when `_active`; forwarded to infantry otherwise | Input → Drone |
| **HUD** | FPV HUD overlay shows throttle, altitude, "DRONE OFFLINE" state | Drone → HUD |
| **Match scoring** | Kamikaze kill awards kill points to pilot's team per match-scoring.md § kill_points_per_target_type | Drone → Match scoring |
| **Respawn system** | Pilot dying with drone enters normal respawn flow; drone respawns separately at pad | Respawn ↔ Drone |

## Formulas

### Throttle Accumulator

```
on W held: throttle += throttle_rate * delta
on S held: throttle -= throttle_rate * delta
throttle = clamp(throttle, 0.0, 1.0)
```

Default: `throttle_rate = 1.0`, so W for 1 second = full throttle up.
Throttle **persists between frames** — no input = no change.

### Thrust along Local Up

```
local_up = drone.global_basis.y  # body-local up vector in world space
velocity += local_up * (throttle * max_thrust * delta)
velocity.y -= gravity * delta
```

`max_thrust = 20.0`, `gravity = 9.8`. At `hover_throttle = 0.5`:
thrust = 0.5 × 20 = 10 m/s², exactly cancels 9.8 m/s² down with 0.2 m/s²
overhead = slight climb at hover throttle. Adjust `hover_throttle = 0.49`
for true hover, if desired.

### Linear Damping (frame-rate independent)

```
horizontal_decay = exp(-horizontal_damping * delta)  # horizontal_damping = 1.5/s
vertical_decay   = exp(-vertical_damping * delta)    # vertical_damping = 0.8/s
velocity.x *= horizontal_decay
velocity.z *= horizontal_decay
velocity.y *= vertical_decay
```

### Mouse Rotation (per frame, clamped)

```
sens_rad = deg_to_rad(mouse_sensitivity_deg_per_px)  # 0.3 deg/px
pitch_amount = clamp(-mouse_delta.y * sens_rad, -max_pitch_per_frame, +max_pitch_per_frame)
roll_amount  = clamp(mouse_delta.x * sens_rad, -max_roll_per_frame, +max_roll_per_frame)
rotate_object_local(Vector3.RIGHT, pitch_amount)
rotate_object_local(Vector3.FORWARD, roll_amount)
```

`max_pitch_rate_deg = 360`, `max_roll_rate_deg = 360` — full inversion per second.

### Kamikaze Threshold

```
if pre_slide_velocity.length_squared >= kamikaze_speed_threshold^2:
    apply_damage(target_health, kamikaze_damage, DamageTypes.Source.DRONE_KAMIKAZE)
    self_damage(kamikaze_damage)
```

`kamikaze_speed_threshold = 6.0 m/s` — slower than full-throttle forward at
hover tilt (~10 m/s). Allows careful pilots to land safely without
detonating.

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Pilot enters drone then drone is destroyed by enemy AK fire (non-kamikaze) | Drone enters wreck state; pilot enters respawn flow (dies with drone) | Drone destruction is lethal to pilot |
| Pilot exits drone cleanly via vehicle switcher | Drone set_active(false) — stops physics; pilot's body resumes at pad | Clean exit = no death |
| Drone kamikazes into own teammate | No friendly fire per weapon-system.md rule 22; teammate unharmed; drone still self-destructs | No friendly fire |
| Drone grounded at throttle 0 | Rotors coast to stop; drone sits on ground | `is_on_floor() && not is_armed` check |
| Drone exceeds max_altitude (> 50m) and still has upward velocity | Upward velocity clamped to 0; drone hovers at ceiling | Rule 9 |
| Mouse input at high polling rate (e.g., 1000 Hz) | Accumulated delta summed across events before physics tick; per-frame clamp prevents teleport-spin | Rule 4 |
| Pilot disconnects while piloting drone | Drone enters idle state (no input); lingers for server timeout; then returned to pad as unoccupied | TBD — see Open Questions |
| Drone body orientation inverted (e.g., after complex mouse flicks) | `get_aim_pitch()` returns 0 to chase camera to prevent lurch on exit | `return 0.0` in current code |
| Drone collides with terrain at < 6 m/s | Slide/bounce without damage; drone remains intact | Non-kamikaze |
| Drone's charred overlay applied after respawn before VFX cleared | `clear_charred` runs on respawn before other logic | Rule 13 |
| Drone respawned but pilot already respawned into infantry | Drone remains unoccupied at pad; any player can re-enter | Expected flow |
| Two players race to interact with pad simultaneously | Server picks first-to-interact (FIFO); loser sees "occupied" | Server-authoritative decision |

## Dependencies

| System | Direction | Nature |
|--------|-----------|--------|
| Health/damage | Drone depends on Health | Own HealthComponent; damages target HealthComponents |
| Combat framework | Drone depends on Combat | Uses DamageTypes.Source enum |
| Destruction effects | Drone depends on Destruction effects | charred + smoke VFX on destroy |
| Networking (ADR-0001) | Drone depends on Networking | State replication, authoritative collision |
| Vehicle switcher | Drone depends on Vehicle switcher | Entry/exit handshake |
| Input system | Drone depends on Input | Consumes WASD + mouse while `_active` |
| Camera system | Drone depends on Camera | FPV camera activation |
| HUD | HUD depends on Drone | Displays throttle, altitude, offline state |
| Match scoring | Match scoring depends on Drone | Kill credits for kamikaze |
| Respawn system | Pilot's respawn depends on Drone destruction | Pilot dies with drone |
| VFX system | Drone depends on VFX | Propeller visuals, impact flashes (indirect via kamikaze) |

## Tuning Knobs

| Parameter | Current | Safe Range | Increase | Decrease |
|-----------|---------|-----------|----------|----------|
| `max_thrust` (m/s²) | 20.0 | 10-50 | Snappier climb, faster flight | Sluggish |
| `hover_throttle` | 0.5 | 0.3-0.8 | Less climbing power at 50% | Always climbing at neutral |
| `throttle_rate` (1/s) | 1.0 | 0.3-3.0 | Snap to full throttle | Gradual throttle |
| `gravity` (m/s²) | 9.8 | 5-15 | Harder to fly up | Floaty |
| `max_pitch_rate_deg` | 360/s | 180-720 | Crazy acrobatics | Sluggish |
| `max_roll_rate_deg` | 360/s | 180-720 | Crazy acrobatics | Sluggish |
| `max_yaw_rate_deg` | 180/s | 90-360 | Fast turns | Slow spinning |
| `mouse_sensitivity_deg_per_px` | 0.3 | 0.1-1.0 | Twitchy mouse | Sluggish mouse |
| `horizontal_damping` (1/s) | 1.5 | 0.5-4.0 | Brake hard | Slippery |
| `vertical_damping` (1/s) | 0.8 | 0.3-2.0 | Tight altitude hold | Drifty Y |
| `max_altitude` (m) | 50 | 20-150 | Higher ceiling | Ground-level only |
| `kamikaze_speed_threshold` (m/s) | 6.0 | 3-15 | Harder to accidentally detonate | Detonates on light touch |
| `kamikaze_damage` | 999 | 100-9999 | Instakill everything | Requires follow-up |
| `respawn_delay` (s) | 1.5 | 0.5-10 | Longer offline period | Near-instant respawn |
| `max_rotor_speed_rad_per_sec` | 60 | 20-200 | Visible blur | Slow spin |
| `idle_rotor_speed_rad_per_sec` | 16 | 0-50 | Always spinning | Stops completely |

## Visual/Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|----------------|---------------|----------|
| Drone on pad, unoccupied | Drone visible on pad, slow idle rotor spin | Soft electrical idle hum | Must |
| Drone on pad, occupied | Drone visible with small "PILOTED" beacon marker (post-MVP) | Same idle hum (piloted) | Should |
| Pilot entering drone | FPV camera fade-in transition; rotor spool up SFX | Rotor spool-up whine | Must |
| Full throttle flight | Rotor blur visible, body tilted into direction of travel | High-pitched rotor buzz (distance-attenuated for defenders) | Must |
| Kamikaze impact (target hit) | Impact VFX at collision point (debris + smoke); drone fragments scatter | Explosion SFX + brief metal twisting | Must |
| Drone destroyed (wreck mode) | Wreck falls via gravity; charred shader overlay; smoke/fire VFX spawned | Fire crackle + smoke hiss loop | Must |
| Drone respawned at pad | Teleport shimmer at spawn position; destruction VFX cleared | Teleport shimmer SFX + idle hum resumes | Must |
| Drone offline (during respawn_delay) | FPV HUD shows "DRONE OFFLINE" overlay; camera cuts to black | Static hiss or silence | Must |
| FPV flight audio perspective | Rotor buzz + wind noise from first-person | Directional audio of surroundings muffled by rotor | Should |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| FPV camera view | Full screen replaces third-person | Real-time | While piloting |
| Throttle indicator (bar/value) | FPV HUD bottom-left | 30 Hz | While piloting |
| Altitude (m) | FPV HUD bottom-left | 30 Hz | While piloting |
| Drone HP bar | FPV HUD top | On change | While piloting |
| "DRONE OFFLINE" overlay | Full-screen mask | Static | During respawn_delay |
| "DRONE READY" toast | FPV HUD bottom | 2s | On respawned signal |
| "ENTER DRONE [E]" prompt | World-space near pad | When player within interact range | Infantry near unoccupied pad |
| "DRONE OCCUPIED" prompt | World-space near pad | Real-time | Infantry near occupied pad |
| Exit drone prompt | FPV HUD | Static | While piloting |

## Acceptance Criteria

- [ ] Exactly one drone exists per map at a designer-authored pad location
- [ ] Only one pilot may occupy the drone at a time; others see "occupied" on the pad
- [ ] WASD + mouse controls produce the documented flight behavior (Mode 2 acro)
- [ ] Thrust exactly counters gravity at `hover_throttle = 0.5` within a tolerance of 2 m/s drift over 10 seconds
- [ ] Mouse stops → drone holds angle (no auto-leveling)
- [ ] Max altitude enforced at 50m; upward velocity clamped
- [ ] Kamikaze impact at 6+ m/s applies 999 damage to target HealthComponent and self-destructs drone
- [ ] Non-kamikaze collisions below 6 m/s slide/bounce without damage
- [ ] Drone destruction triggers wreck-fall state, charred VFX, smoke/fire, and 1.5s respawn timer
- [ ] Drone respawn teleports to original spawn transform with full HP
- [ ] Pilot dying with drone enters normal respawn flow (5s, respawn UI)
- [ ] All propellers (12 blades in 4 motors) animate proportional to throttle; stop when parked + idle
- [ ] Drone state syncs to all clients at 30 Hz per ADR-0001
- [ ] No friendly fire on teammate kamikaze collision
- [ ] Performance: drone physics tick completes in < 2 ms
- [ ] No hardcoded values — see Technical Debt for tuning-resource migration plan

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| Who can enter the drone? Any infantry, or Heavy-only, or a new "Drone Pilot" class? | Designer | Sprint 3 | Tentative: any infantry (current impl). Revisit if balance suffers. |
| Should the drone pad be on-map near a capture point (encouraging contest), or in safe base area? | Level designer | Sprint 3 | TBD — affects map layout |
| Should there be a cooldown after kamikaze before a new pilot can re-enter? | Designer | Day 10 playtest | MVP: 1.5s respawn = de-facto cooldown. Revisit if spam |
| Pilot disconnect while piloting — drone goes idle, returned to pad how? | Network prog | Sprint 4 | TBD — probably after server timeout (30s no-input) |
| Should multiple drones exist on the map (e.g., one per team)? | Designer | Post-MVP | MVP: one shared drone. Post-MVP: one per team. |
| Is the 30° FPV uptilt adjustable per pilot (preference)? | Designer | Post-MVP | Not at MVP |
| Is there a "boost" key for extra-fast flight? | Designer | Post-MVP | Not at MVP |
| Audio defender warning — should the buzz travel farther than the drone's effective engagement range so defenders always hear incoming? | Audio director | Sprint 4 | Tentative: 2× engagement range for buzz audibility |

## Technical Debt (per .claude/rules/gameplay-code.md)

`drone_controller.gd` exposes nearly all tuning via `@export` fields with
hardcoded defaults:

- Flight tunables: `max_thrust=20`, `hover_throttle=0.5`, `throttle_rate=1`, `gravity=9.8`, etc.
- Combat tunables: `kamikaze_speed_threshold=6`, `kamikaze_damage=999`, `respawn_delay=1.5`
- Rotor tunables: `max_rotor_speed_rad_per_sec=60`, `idle_rotor_speed_rad_per_sec=16`, etc.
- Hardcoded string `propeller_node_names` array (12 entries)

This allows Inspector override in scene but NOT `Resource`-file configuration per project rules.

**Proposed refactor** (Sprint 3 or post-MVP):
- `assets/data/drone.tres` as `DroneResource` with all tunables as typed fields
- `drone_controller.gd` accepts `DroneResource` via `@export var tuning: DroneResource`
- Propeller node naming moves to a typed `Dictionary[String, int]` resource or scene-based naming convention

Also: `_find_descendant_by_name` recursive O(n) per propeller (12 × N
nodes) on `_ready()` — acceptable at MVP (single drone), but if drones
scale to 2+ per team, consider caching NodePaths at author-time.
