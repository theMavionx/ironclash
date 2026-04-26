---
status: reverse-documented
source: src/gameplay/drone/drone_controller.gd
scenes: scenes/drone/drone.tscn
date: 2026-04-25
---

# Drone System (Kamikaze FPV)

> **Status**: Draft (8/8 sections filled, reverse-documented)
> **Author**: AI-assisted reverse-engineering of existing implementation
> **Last Updated**: 2026-04-25 — flight model rewritten from full Mode 2 ACRO to **arcade helicopter-style** (body yaw-only, mouse Y = camera pitch only, lighter damping than helicopter for "less stable" feel). Controls now mirror `helicopter_controller.gd` for consistency.
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

Compared to the helicopter, the drone feels **lighter and twitchier**:
gravity always pulls (no auto-hover — pilot must hold lift), drift is
real (lighter horizontal damping than the helicopter), and yaw lags
slightly behind mouse input. It is approachable for any player who has
flown the helicopter, but rewards practice with tighter approach lines.

For defenders, the fantasy is the inverse: the **distant buzz** that warns
a drone is inbound, the quick pivot to AK fire, the satisfying pop as the
drone fragments midair. Drones are intentionally audible (buzz SFX) so
defenders always have a fair chance to react.

## Detailed Design

### Core Rules

1. One drone exists on the map at any time, parked at a fixed **drone pad** (authored by the map designer). Drone respawns at this pad after destruction.
2. Any infantry player can interact with the pad (stand on it + press the interact key) to **enter** the drone. Entry replaces the player's third-person camera with the drone's first-person mount camera. The player's body remains at the pad and is dealt with when they exit or die.
3. A drone may have **at most one pilot** at any time. If occupied, the interact prompt on the pad shows "occupied" and cannot be entered.
4. Flight controls (arcade helicopter-style — **mirrors `helicopter_controller.gd`**):
   - **Space** — lift up (collective; held-input acceleration along world-up)
   - **Ctrl** or **C** — descend (additive downward acceleration; for fast dives onto kamikaze targets)
   - **W / A / S / D** — strafe in the body's yaw-aligned local XZ frame
   - **Mouse X** — yaw the body (smoothed; lags slightly behind input — see formula)
   - **Mouse Y** — **camera pitch only**. The body NEVER pitches or rolls — only the FPV camera mount rotates. This keeps the rigid-mounted FPV view level for accurate kamikaze approaches.
5. **Body never pitches or rolls.** Only `rotation.y` (yaw) is touched on the `CharacterBody3D` root. This guarantees the FPV camera (child of body via `FPVMount`) stays level regardless of strafe input.
6. **Visual strafe-tilt** is applied to the child `Model` node (sibling of `FPVMount`). The model leans into strafe direction (max ±18° pitch / ±15° roll) for visual feedback only — the camera mount is unaffected.
7. **No auto-hover.** Gravity (9.8 m/s²) pulls continuously. Pilot must hold Space to maintain altitude. This is the primary "less stable than helicopter" lever — the helicopter auto-decays vertical velocity to zero on neutral input; the drone does not.
8. Camera is rigid-mounted to the drone body. With body always level, no static uptilt is needed — pilot uses Mouse Y to look up/down freely (range −75° to +60°, wider than infantry/heli for kamikaze diving).
9. Maximum altitude is clamped to `max_altitude = 50 m` (matches helicopter ceiling from helicopter-controller.md).
10. Kamikaze detection — two rules:
    - **Target rule (no threshold)**: any physics-slide collision with a body that has a `HealthComponent` triggers kamikaze regardless of impact speed. Even a gentle touch on a tank, helicopter, drone, or infantry detonates the drone and kills the target. This is the kamikaze fantasy: contact = death.
    - **Terrain rule (threshold)**: collisions with bodies that have NO `HealthComponent` (terrain, walls, pads, props) only detonate the drone if `pre_slide_velocity.length >= kamikaze_speed_threshold` (default 6.0 m/s). Below the threshold the drone bounces / slides without damage — pilots can land softly on pads or graze geometry.
11. Kamikaze effect:
    - Target's `HealthComponent` takes `kamikaze_damage = 999` with source `DamageTypes.Source.DRONE_KAMIKAZE` → one-shot kill any target at MVP values.
    - The drone also damages itself with 999 (self-destruct) — triggers its own destroyed state.
    - HealthComponent lookup is recursive: tries `collider.HealthComponent` first, then `find_child("HealthComponent", true)` so colliders that nest the component (e.g. Player puts it under `Body`) are still detected.
12. (See rule 10 — non-kamikaze terrain collisions below threshold bounce/slide without damage.)
13. On destruction:
    - Drone enters "wreck mode" (no input, gravity-only fall, no propeller animation)
    - `DestructionVFX.apply_charred()` and `DestructionVFX.spawn_smoke_fire()` applied to wreck
    - A `respawn_delay = 1.5 s` timer is started
    - At timeout, drone teleports back to spawn transform, clears destruction VFX, resets health, emits `respawned` signal
14. The `respawned` signal is listened to by the FPV HUD, which clears the "DRONE OFFLINE" overlay.
15. Linear damping is **lighter than the helicopter on purpose** — horizontal 1.0/s (heli: 2.0/s) means the drone drifts farther after releasing strafe input. Vertical damping 0.5/s gently bleeds vertical spikes but does NOT counter gravity, so released Space still sinks.
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

### Vertical (Lift + Gravity, no auto-hover)

```
velocity.y -= gravity * delta                          # gravity = 9.8, always
if Space held:  velocity.y += lift_acceleration * delta   # lift = 14.0
if Ctrl/C held: velocity.y -= lift_down_acceleration * delta  # down = 8.0
velocity.y = lerp(velocity.y, velocity.y * exp(-vertical_damping * delta), 1.0)  # vd = 0.5
```

Net vertical acceleration when holding Space at hover: **+4.2 m/s²** (climb).
Released: gravity dominates → drone drifts down. There is no auto-hover —
this is the "less stable" lever vs. the helicopter (which auto-decays
vertical velocity to zero on neutral input).

### Horizontal (Strafe in Yaw-Aligned Local Frame)

```
strafe_input = Vector2(D-A, S-W).clamp_length(1.0)
yaw_basis = Basis(Vector3.UP, _yaw_current)
world_strafe = yaw_basis * Vector3(strafe_input.x, 0, strafe_input.y)
target_vx = world_strafe.x * strafe_speed     # strafe_speed = 10.0
target_vz = world_strafe.z * strafe_speed
horizontal_blend = 1.0 - exp(-horizontal_damping * delta)   # damping = 1.0
velocity.x = lerp(velocity.x, target_vx, horizontal_blend)
velocity.z = lerp(velocity.z, target_vz, horizontal_blend)
```

Same shape as the helicopter, but with **half the damping** (1.0 vs 2.0)
— drone never quite snaps to target velocity, leaving residual drift.

### Yaw (smoothed mouse target)

```
on mouse motion: _yaw_target -= relative.x * mouse_sensitivity   # 0.0025 rad/px
yaw_blend = 1.0 - exp(-yaw_smooth_speed * delta)                 # smooth = 8.0
_yaw_current = lerp_angle(_yaw_current, _yaw_target, yaw_blend)
rotation.y = _yaw_current
```

`yaw_smooth_speed = 8` (heli: 10) — slightly laggier; the floaty feel.

### Camera Pitch (mouse Y → camera mount only)

```
on mouse motion:
  pitch_sign = -1 if invert_camera_pitch else 1
  _camera_pitch = clamp(
    _camera_pitch - relative.y * camera_pitch_sensitivity * pitch_sign,
    deg_to_rad(camera_min_pitch_deg),    # -75°
    deg_to_rad(camera_max_pitch_deg),    # +60°
  )
FPVMount.rotation.x = _camera_pitch       # body untouched
```

Wider than the helicopter's ±45° so the pilot can dive-look at kamikaze
targets directly below.

### Visual Strafe Tilt (Model node only — camera unaffected)

```
target_pitch = (S - W) * deg_to_rad(max_pitch_tilt_deg)   # max = 18°
target_roll  = (A - D) * deg_to_rad(max_roll_tilt_deg)    # max = 15°
tilt_blend = 1.0 - exp(-tilt_smooth_speed * delta)        # smooth = 4.0
_pitch_tilt_current = lerp(_pitch_tilt_current, target_pitch, tilt_blend)
_roll_tilt_current  = lerp(_roll_tilt_current,  target_roll,  tilt_blend)
Model.rotation.x = _pitch_tilt_current
Model.rotation.z = _roll_tilt_current
```

`tilt_smooth_speed = 4` (heli: 6) — drone leans into turns more lazily.

### Kamikaze Threshold

```
if pre_slide_velocity.length_squared >= kamikaze_speed_threshold^2:
    apply_damage(target_health, kamikaze_damage, DamageTypes.Source.DRONE_KAMIKAZE)
    self_damage(kamikaze_damage)
```

`kamikaze_speed_threshold = 6.0 m/s` — slower than `strafe_speed = 10 m/s`,
so a full forward strafe will detonate on contact. Allows careful pilots
to land softly (e.g. drift onto pad at < 6 m/s) without detonating.

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Pilot enters drone then drone is destroyed by enemy AK fire (non-kamikaze) | Drone enters wreck state; pilot enters respawn flow (dies with drone) | Drone destruction is lethal to pilot |
| Pilot exits drone cleanly via vehicle switcher | Drone set_active(false) — stops physics; pilot's body resumes at pad | Clean exit = no death |
| Drone kamikazes into own teammate | No friendly fire per weapon-system.md rule 22; teammate unharmed; drone still self-destructs | No friendly fire |
| Drone grounded at throttle 0 | Rotors coast to stop; drone sits on ground | `is_on_floor() && not is_armed` check |
| Drone exceeds max_altitude (> 50m) and still has upward velocity | Upward velocity clamped to 0; drone hovers at ceiling | Rule 9 |
| Mouse input at high polling rate (e.g., 1000 Hz) | `_yaw_target` and `_camera_pitch` integrate every motion event; smoothing applied per physics tick — no teleport-spin | Rule 4 |
| Pilot disconnects while piloting drone | Drone enters idle state (no input); lingers for server timeout; then returned to pad as unoccupied | TBD — see Open Questions |
| Pilot releases all keys mid-flight | Body holds yaw, gravity pulls drone down, horizontal velocity bleeds toward zero. No auto-hover. | Rule 7 (less stable than helicopter by design) |
| Pilot re-enters drone after exiting | `set_active(true)` syncs `_yaw_target` to current body yaw — no snap-turn on entry | `set_active()` body |
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
| `lift_acceleration` (m/s²) | 14.0 | 10-30 | Snappier climb | Cannot out-thrust gravity |
| `lift_down_acceleration` (m/s²) | 8.0 | 0-30 | Faster dives | No assisted descent |
| `gravity` (m/s²) | 9.8 | 5-15 | Drone falls fast when neutral | Floatier (closer to helicopter feel) |
| `strafe_speed` (m/s) | 10.0 | 4-25 | Fast traversal | Sluggish |
| `horizontal_damping` (1/s) | 1.0 | 0.3-3.0 | Closer to helicopter (tight stops) | More drift, harder to control |
| `vertical_damping` (1/s) | 0.5 | 0.0-2.0 | Tighter altitude hold | Bouncier vertical |
| `mouse_sensitivity` (rad/px) | 0.0025 | 0.001-0.01 | Twitchy yaw | Sluggish yaw |
| `yaw_smooth_speed` (1/s) | 8.0 | 4-20 | Snappier yaw (toward heli's 10) | Floatier yaw |
| `camera_pitch_sensitivity` (rad/px) | 0.0025 | 0.001-0.01 | Twitchy look | Sluggish look |
| `camera_min_pitch_deg` | -75 | -89..-30 | Look further down (kamikaze diving) | Less downward visibility |
| `camera_max_pitch_deg` | 60 | 30..89 | Look further up | Less upward visibility |
| `max_pitch_tilt_deg` | 18 | 0-45 | More dramatic forward lean | Stiff visual |
| `max_roll_tilt_deg` | 15 | 0-45 | More dramatic side lean | Stiff visual |
| `tilt_smooth_speed` (1/s) | 4.0 | 1-15 | Snappier visual lean | Lazier lean |
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
- [ ] **Body never pitches or rolls** — only `rotation.y` is touched (verified by inspecting the body's `rotation.x` and `rotation.z` always == 0 during flight)
- [ ] **Mouse Y rotates `FPVMount` only** — body untouched, FPV camera looks up/down freely in [-75°, +60°]
- [ ] **Visual tilt appears on `Model` node only** — strafe lean is visible in third-person view but does NOT affect FPV camera
- [ ] Space held → drone climbs (vertical velocity becomes positive within 1 frame)
- [ ] Space released → drone sinks (vertical velocity trends negative — there is NO auto-hover)
- [ ] Ctrl/C held → drone descends faster than gravity alone
- [ ] WASD strafe is yaw-aligned (W always moves forward in camera direction, regardless of drone's spawn orientation)
- [ ] Yaw lags behind mouse target by ~125ms (`yaw_smooth_speed = 8` → time-constant ≈ 0.125s)
- [ ] Horizontal velocity bleeds toward zero on neutral input within 4-5 seconds (vs. helicopter's 2 seconds — drone drifts longer)
- [ ] Re-entering the drone (`set_active(true)`) does NOT cause it to snap-turn — `_yaw_target` resyncs to current body yaw
- [ ] Max altitude enforced at 50m; upward velocity clamped
- [ ] Any contact with a body that has a HealthComponent (tank, heli, drone, infantry) applies 999 damage and self-destructs the drone — regardless of impact speed
- [ ] Terrain / wall / pad collisions below `kamikaze_speed_threshold` (6 m/s) slide/bounce without damage
- [ ] Terrain / wall / pad collisions at or above 6 m/s self-destruct the drone (no target damage — terrain takes none)
- [ ] HealthComponent lookup also finds it when nested under a child (Player → Body → HealthComponent)
- [ ] Drone destruction triggers wreck-fall state, charred VFX, smoke/fire, and 1.5s respawn timer
- [ ] Drone respawn teleports to original spawn transform with full HP and resets `_camera_pitch`, `_pitch_tilt_current`, `_roll_tilt_current` to zero
- [ ] Pilot dying with drone enters normal respawn flow (5s, respawn UI)
- [ ] All propellers (12 blades in 4 motors) animate proportional to synthetic throttle (Space=1, Ctrl=0, neutral=0.5); stop when parked + idle
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

- Lift / strafe: `lift_acceleration=14`, `lift_down_acceleration=8`, `gravity=9.8`, `strafe_speed=10`
- Damping: `horizontal_damping=1.0`, `vertical_damping=0.5`
- Yaw / camera: `mouse_sensitivity=0.0025`, `yaw_smooth_speed=8`, `camera_pitch_sensitivity=0.0025`, `camera_min/max_pitch_deg=-75/+60`
- Visual tilt: `max_pitch_tilt_deg=18`, `max_roll_tilt_deg=15`, `tilt_smooth_speed=4`
- Combat: `kamikaze_speed_threshold=6`, `kamikaze_damage=999`, `respawn_delay=1.5`
- Rotor: `max_rotor_speed_rad_per_sec=60`, `idle_rotor_speed_rad_per_sec=16`, etc.
- Hardcoded string `propeller_node_names` array (12 entries)

This allows Inspector override in scene but NOT `Resource`-file configuration per project rules.

**Proposed refactor** (Sprint 3 or post-MVP):
- `assets/data/drone.tres` as `DroneResource` with all tunables as typed fields
- `drone_controller.gd` accepts `DroneResource` via `@export var tuning: DroneResource`
- Propeller node naming moves to a typed `Dictionary[String, int]` resource or scene-based naming convention

Also: `_find_descendant_by_name` recursive O(n) per propeller (12 × N
nodes) on `_ready()` — acceptable at MVP (single drone), but if drones
scale to 2+ per team, consider caching NodePaths at author-time.
