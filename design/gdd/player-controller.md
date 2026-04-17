# Player Controller

> **Status**: Designed
> **Author**: Claude Code Game Studios session
> **Last Updated**: 2026-04-14
> **Implements Pillar**: Skill Is The Ceiling — movement is a primary skill-expression axis (positioning, peek timing, stamina management)

## Overview

The Player Controller owns every aspect of how a player-character moves
through the world on foot: walking, sprinting, crouching, jumping, and
aim-down-sights speed modulation. It reads player intent from the Input
System, consumes stamina, and produces a server-authoritative position and
aim direction that the Networking layer replicates to other clients. The
controller uses a **soft acceleration** movement model with arcade tempo
(PUBG visual feel + Fortnite pacing): reaching max speed takes ~0.4 s, and
direction changes have visible inertia. Stamina governs sprint duration.
**Lean has been cut** — third-person camera already provides corner-peek
through camera rotation, making lean redundant.

## Player Fantasy

Movement should feel **arcade-snappy but with weight** — the visual
seriousness of PUBG combined with the responsive tempo of Fortnite. The
player feels like a *military operator in gear*: fast bursts of sprint,
chunky deceleration that telegraphs movement to opponents, rewarded for
managing stamina, punished for running across open ground exhausted. The
third-person camera lets the player read their character's positioning at
all times — a key skill expression for cornering and cover use.

## Detailed Design

### Core Rules

1. The Player Controller is **server-authoritative** (per ADR-0001). Client
   sends input state at 30 Hz; server simulates movement and broadcasts
   resulting position.
2. Movement uses **acceleration-based** velocity (not instant snap). Target
   velocity is computed from input; actual velocity ramps toward target
   using an acceleration constant.
3. Horizontal movement and vertical movement are **decoupled**. Gravity
   always applies when not grounded. Jump adds instantaneous vertical
   velocity.
4. **Stamina** is a client-visible gameplay resource that limits sprint
   duration. Stamina is server-authoritative.
5. **ADS (aim down sights)** is a state, not a movement modifier — it tightens the camera (per Camera System) and slows the player. Weapon accuracy is improved while ADS active (per Weapon System).
6. While **in a vehicle**, Player Controller is disabled; Vehicle Controller takes over. Controller re-enables on exit.
7. Dead players have the controller disabled until respawn.
8. **Lean is not implemented** — third-person camera replaces the corner-peek role.

### Movement States

| State | Max Speed | Enter Condition | Exit Condition |
|---|---|---|---|
| **Idle** | 0 m/s | No input, grounded | Any movement input |
| **Walk** | 7 m/s | WASD pressed, no sprint key | Release WASD → Idle; Shift → Sprint |
| **Sprint** | 11 m/s | Walk + Shift held + forward input + stamina > 0 | Release Shift / stamina = 0 / direction not forward / crouch / ADS |
| **Crouch** | 3.5 m/s | Crouch active | Crouch released and headroom clear |
| **ADS (aim down sights)** | 5 m/s | RMB held | RMB released |
| **Airborne** | (current horizontal × 0.5 control) | Not grounded | Grounded |
| **Disabled** | 0 m/s | In vehicle OR dead | Exit vehicle / respawn |

### Transition Rules

- Sprint requires a forward-ish input vector (dot product with forward > 0.5). Strafe-sprinting is not allowed.
- Crouch is **configurable** (per Input System): hold-to-crouch OR toggle-to-crouch, per player preference.
- Crouch cannot uncrouch if there is a ceiling obstacle overhead (stay crouched).
- ADS slows to 5 m/s regardless of other states (ADS + crouch = 3.5 m/s, the lower cap wins).
- Jump requires `grounded == true` and stamina ≥ `jump_stamina_cost` (15).
- Jumping while crouched is **not allowed** at MVP (simplifies collider).

### Stamina Rules

- **Pool:** 100 units
- **Sprint drain:** 15 units/sec while sprinting
- **Jump cost:** 15 units instant
- **Regen delay:** 1.0 second after last drain event
- **Regen rate:** 25 units/sec after delay
- **Sprint lockout:** if stamina hits 0, player cannot sprint again until stamina regens to at least 30 (prevents sprint-stutter abuse)
- Stamina is **not displayed as a number** to the player — it's shown as a subtle HUD stamina bar that fades in while draining or below 50%.

### Interactions with Other Systems

- **Input System** (upstream): consumes movement vector, jump, sprint, crouch, ADS
- **Networking** (upstream): controller RPC submits input state at 30 Hz; receives position from server at 30 Hz (with 60 Hz render interpolation)
- **Camera System** (downstream): receives player root position, ADS state, movement velocity for over-shoulder camera follow
- **Hit Registration** (downstream): provides hitbox transform (body, head, legs) at authoritative position
- **Weapon System** (downstream): notified of ADS state (affects recoil and accuracy); notified of sprint state (disables fire while sprinting)
- **Vehicle System** (downstream): controller disabled on vehicle enter; re-enabled on exit
- **Animation System** (downstream): consumes movement speed, crouch state, ADS state to blend third-person character animations
- **HUD** (downstream): consumes stamina value for stamina bar
- **Respawn System** (upstream): invokes controller with initial position and facing on respawn

## Formulas

### Acceleration toward target velocity (Battlefield-style soft movement)

Each physics tick, compute horizontal velocity:
```
target_velocity = input_vector.normalized() * current_max_speed
velocity_delta = target_velocity - current_velocity
acceleration = velocity_delta * accel_rate * delta_time
current_velocity += clamp_magnitude(acceleration, max_accel_per_tick)
```

- `current_max_speed`: one of 0 / 7 / 11 / 3.5 / 5 depending on state
- `accel_rate`: 12.0 when grounded (snappier than Battlefield to fit Fortnite-arcade tempo), 2.0 when airborne
- `max_accel_per_tick`: caps at 2.5 m/s per tick to prevent spikes

**Effect:** reaching max sprint speed from standstill takes ~0.4 s; direction change shows ~0.18 s of inertia.

### Jump

```
vertical_velocity = jump_impulse  (set instantly on jump press)
```
- `jump_impulse`: 5.5 m/s (produces ~1.2 m jump apex with gravity = 12.5 m/s²)
- Gravity: `-12.5 m/s²` (stronger than Earth for snappier feel — game-standard)

### Stamina update (per tick)

```
if sprinting:
    stamina -= stamina_sprint_drain_rate * delta_time
    last_drain_time = now
elif (now - last_drain_time) > stamina_regen_delay and stamina < stamina_max:
    stamina += stamina_regen_rate * delta_time

stamina = clamp(stamina, 0, 100)
```

## Edge Cases

- **Sprinting with zero stamina + hold Shift** → no sprint, player walks at Walk speed; HUD stamina bar flashes briefly once per attempt to signal "locked out until regen to 30"
- **Jumping with zero stamina** → jump input ignored; audio "fail" cue plays (low-priority sound, no UI)
- **Crouch-jump** (hold crouch, press jump) → not allowed at MVP; jump is ignored while crouched
- **Player jumps onto a ledge and becomes grounded mid-air state** → landing is detected each physics tick; vertical velocity zeroed immediately
- **Ceiling during uncrouch** → stays crouched; on next tick, re-checks if ceiling is clear
- **Getting stuck in geometry** (rare, from teleport edge cases) → server resets player to last known valid position; documented as known recovery behavior
- **Vehicle enter while sprinting** → controller disabled mid-sprint; stamina drain stops; vehicle logic takes over
- **Dying while airborne** → controller disabled immediately; ragdoll handled by Animation system (post-MVP; MVP just freezes the character)
- **Network rubber-band** (server rejects client-extrapolated position) → server state wins; position snaps. Interpolation smooths the snap over ~150 ms.

## Dependencies

**Upstream (hard — controller cannot function without these):**
- **Input System** — provides move vector, sprint, jump, crouch, ADS input
  - Interface: Input System exposes signals/getters; controller reads per tick
- **Networking layer (ADR-0001)** — provides client→server input RPC and server→client position sync via `MultiplayerSynchronizer`
  - Interface: controller is a networked `CharacterBody3D` with authority on server

**Upstream (soft):**
- **Respawn System** — calls `controller.respawn_at(position, facing)` on player respawn

**Downstream (hard — these systems cannot function without Player Controller):**
- Camera System, Hit Registration, Weapon System, Vehicle System (on-enter transition), Animation System, HUD (stamina)

**Downstream (soft):**
- Audio System (footstep trigger events), VFX System (footstep dust post-MVP)

## Tuning Knobs

| Knob | Range | Default | Effect |
|---|---|---|---|
| `walk_speed` | 5 – 9 m/s | 7 | Base movement |
| `sprint_speed` | 8 – 14 m/s | 11 | Sprint cap |
| `crouch_speed` | 2.5 – 5 m/s | 3.5 | Crouch cap |
| `ads_speed` | 3 – 7 m/s | 5 | ADS cap |
| `jump_impulse` | 4 – 7 m/s | 5.5 | Jump height (apex ≈ 1.2 m) |
| `gravity` | 10 – 20 m/s² | 12.5 | Fall speed |
| `accel_rate_grounded` | 6 – 20 | 12 | Velocity ramp (higher = snappier) |
| `accel_rate_airborne` | 1 – 5 | 2 | Air control strength |
| `stamina_max` | 50 – 200 | 100 | Total pool |
| `stamina_sprint_drain_rate` | 10 – 25 /s | 15 | Sprint cost per second |
| `stamina_jump_cost` | 0 – 30 | 15 | Per-jump cost |
| `stamina_regen_delay` | 0.5 – 2.0 s | 1.0 | Idle time before regen starts |
| `stamina_regen_rate` | 15 – 40 /s | 25 | Regen per second after delay |
| `stamina_sprint_lockout_threshold` | 20 – 40 | 30 | Stamina required to re-sprint after 0 |

## Visual/Audio Requirements

- **Footstep audio** (routed to Audio System Footsteps bus): one sample per step, varies by surface (concrete / metal / wood / dirt). Frequency scales with movement speed (walk: ~0.5 s interval, sprint: ~0.3 s).
- **Jump audio**: single cue on jump input; land cue on grounded transition.
- **Stamina depleted audio**: subtle "out of breath" cue when stamina hits 0.
- **Sprint animation (3rd person)**: forward lean + faster cycle; weapon lowers.
- **ADS animation**: character raises weapon toward eye line; weapon model held in firing pose for camera to read clearly. Camera tightens to shoulder (per Camera System).
- **Crouch animation**: character lowers stance smoothly over ~0.2 s.
- All character animations are visible to the player at all times (third-person view) — quality bar is "readable from camera distance," not "AAA polish" for MVP.

## UI Requirements

- **Stamina bar**: small horizontal bar below crosshair OR at bottom-left HUD.
  - Fades in when stamina < 100 OR when stamina is actively draining
  - Fades out after 2 s of being full and idle
  - Red flash when sprint attempt fails due to lockout (<30 stamina after 0)
- **No numeric stamina display** — bar only, per Player Fantasy (feel over metrics)

## Acceptance Criteria

- [ ] Server-authoritative position for all movement (clients cannot cheat speed/fly)
- [ ] Max sprint speed (11 m/s) is reached in 0.3 – 0.5 s from standstill (measured)
- [ ] Direction change at sprint shows visible inertia (~0.18 s lag) — not instant snap
- [ ] Jump apex is 1.2 m ± 0.1 m (measured from ground level)
- [ ] Stamina drains fully in ~6.7 s of continuous sprint, regens fully in ~4 s after 1 s delay
- [ ] Sprint lockout engages at 0 stamina; unlocks at 30 stamina
- [ ] Crouch hold / toggle both work based on setting in Settings UI
- [ ] Uncrouch is blocked under low ceilings
- [ ] ADS caps speed at 5 m/s regardless of sprint input
- [ ] Controller is fully disabled in vehicle and on death, with no stray input bleeding through
- [ ] Respawn correctly places player at spawn position with full stamina
- [ ] Controller tick fits within server 30 Hz budget (<5 ms per-player server cost)
- [ ] Network interpolation smooths server snaps within 150 ms (no teleport-visible snap under normal conditions)

## Open Questions

- **Slide** is explicitly cut at MVP. Post-MVP consideration: crouch-while-sprinting could trigger a short slide.
- **Vault** is explicitly cut. Post-MVP.
- **Wall-run** is explicitly cut. Post-MVP, likely never.
- **Lean** is cut entirely — third-person camera replaces its role.
- **Footstep surface detection**: needs raycast downward each step, or parameterized by floor material tags? Defaults to "concrete" if no tag found.
- **Sprint while jumping**: does sprint continue on landing if key held and stamina available? Yes, by default; no interrupt on land.
- **Knockback / external forces** (explosion blast, vehicle collision): will be designed with Health/Damage system.
- **Character rotation independent from camera**: in TPS, should the character body always face camera-forward, or should it rotate to match movement direction? Decision: character rotates to camera-forward when ADS or shooting; otherwise rotates to movement direction with smooth blend. Refine during implementation.
