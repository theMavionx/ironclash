# Weapon System

> **Status**: Draft (8/8 sections filled)
> **Author**: AI-assisted draft
> **Last Updated**: 2026-04-18
> **Implements Pillar**: Pillar 1 — *Skill Is The Ceiling* (aim-driven gunplay); Pillar 2 — *Every Tool Has A Counter* (AK counters RPG at close, RPG counters vehicles)
> **MVP Scope**: 2 weapons — AK (Assault, hitscan) and RPG (Heavy, projectile).
> **Note**: RPG was initially cut per capacity; reinstated by user decision 2026-04-18. MVP implementation risk is elevated as a result.

## Overview

The weapon system defines how players deal damage in Ironclash. Two weapons
exist, bound one-per-class: the **AK** (Assault class, hitscan automatic rifle)
and the **RPG** (Heavy class, projectile launcher with infinite ammo gated by
a cooldown). Weapons are assigned via class loadout — chosen before the match
and on each respawn — and cannot be dropped, picked up, or swapped mid-life.
The system targets an **arcade tempo**: fast time-to-kill, light and learnable
recoil, tight spread, immediate feedback. Role separation is deliberate — the
AK dominates infantry duels, the RPG dominates vehicle demolition, and neither
crosses into the other's specialty without significant disadvantage.

## Player Fantasy

### Assault (AK) — The Quick Duelist

The AK player thrives on instant close-range duels. When you round a corner
and see an enemy, the outcome is a trinity: **skill** (your crosshair is on
target), **reflex** (your trigger pulls first), and **positioning** (you chose
the angle they didn't expect). Every kill collapses these three into a single
satisfying half-second — you earned it because you saw, reacted, and were
already where you needed to be. The fantasy is the **clutch 1v1**: step around
the corner, land the burst, step back out before the second enemy rounds the
same corner. AK players finish matches remembering specific duels, not
specific maps.

### Heavy (RPG) — The Match-Changer

The Heavy player moves slower, reacts slower, and loses most infantry 1v1s —
but when their shot lands, the match tilts. A tank that was farming kills
stops farming. A helicopter that was raining suppressive fire crashes. A
cluster of defenders on a capture point scatters. Even on a miss, the RPG's
cooldown is **opportunity, not punishment**: you reposition, find a new angle,
and wait for the next shot to matter. The fantasy is **the decisive moment**:
the crossfire you interrupted, the push you stopped, the vehicle you killed.
Heavy players finish matches remembering specific events, not specific duels.

## Detailed Design

### Core Rules

**Both weapons**:

1. Weapon is bound 1:1 with the player's class loadout choice (AK ↔ Assault, RPG ↔ Heavy). Chosen pre-match and on each respawn, cannot be swapped mid-life.
2. Weapons cannot be dropped, picked up, traded, or stolen mid-match.
3. All damage is resolved server-side per ADR-0001. Clients receive hit confirmation via the `on_damage_dealt` RPC and display feedback only after server confirmation.
4. Fire input throttled server-side — server rejects fire RPCs arriving faster than the weapon's `fire_rate_rpm / 60` per second.
5. Firing is disabled while: reloading (AK only), entering/exiting a vehicle, dead, in the respawn countdown, or when match state is not `ACTIVE`.

**AK (Assault)**:

6. Full-auto fire: holding LMB fires at `fire_rate_rpm` while ammo > 0.
7. No ADS at MVP — hipfire-only, large crosshair, no zoom. (ADS deferred; see Open Questions.)
8. Spread cone applied per shot: base hipfire cone plus a movement penalty when the player is sprinting.
9. Deterministic recoil pattern applied to aim rotation per shot. Pattern resets after `recoil_recovery_time` seconds of no fire.
10. Magazine ammo depletes on fire. When magazine = 0, no fire occurs; firing again does nothing until reload.
11. Reload triggered by `R` key: 2.5 second timer, during which firing is blocked. At end of reload, magazine refills from reserve up to `magazine_capacity`.
12. Reload cancelled if the player fires (firing re-enables if mag > 0), dies, or enters a vehicle.
13. Pressing `R` with a full magazine is a no-op. Pressing `R` with 0 reserve shows a "no ammo" toast.
14. Ammo reserve refills to maximum when the player stands on their own team's capture point or team base for `ammo_refill_duration` seconds.

**RPG (Heavy)**:

15. Single-shot fire: tap LMB fires one projectile. Holding LMB does nothing after the first shot.
16. Infinite ammo — no magazine, no reload. Fire gated by `rpg_cooldown` seconds between shots.
17. No ADS. The Heavy aims with hipfire reticle.
18. Projectile physics: rocket travels at `rpg_projectile_speed`, on a straight line (no gravity drop at MVP). Collides with world geometry, players, and vehicles. Explodes on any collision.
19. Damage on direct hit to an infantry target: `rpg_direct_infantry_damage`.
20. Damage on direct hit to a vehicle: `rpg_direct_vehicle_damage`.
21. Splash damage on explosion: applied to all soft targets within `rpg_splash_radius_infantry` meters (infantry) and `rpg_splash_radius_vehicle` meters (vehicle). Splash damage falls off linearly from center to edge.
22. Splash does not damage the shooter's teammates (no friendly fire at MVP).
23. Splash DOES damage the shooter if the explosion occurs within `rpg_self_damage_radius` of the shooter's position (rocket jump is not a feature — self-damage is punishment for close-range spam).
24. While `rpg_cooldown` is active, the firing state is visually communicated: HUD cooldown bar + dimmed crosshair.

### States and Transitions

**AK states**:

| State | Entry Condition | Exit Condition | Behavior |
|-------|----------------|----------------|----------|
| Ready | Default (spawn, reload complete) | LMB pressed with ammo > 0, or R pressed | Accept fire/reload input |
| Firing | LMB held, ammo > 0 | LMB released OR ammo = 0 | Fire at `fire_rate_rpm`, apply recoil + spread |
| Empty | Ammo = 0, LMB still held | Reload triggered | Dry-fire click on LMB press |
| Reloading | R pressed, ammo < mag AND reserve > 0 | 2.5s elapsed OR fire / death / vehicle enter | Reload in progress, fire blocked |
| Disabled | In vehicle OR dead OR match not ACTIVE | Condition cleared | Weapon hidden, no input accepted |

**RPG states**:

| State | Entry Condition | Exit Condition | Behavior |
|-------|----------------|----------------|----------|
| Ready | Cooldown 0 AND spawned | LMB pressed | Accept fire input |
| Firing | LMB tapped | Rocket spawned | Server validates, spawns projectile, starts cooldown |
| On Cooldown | Rocket fired | Cooldown timer expires | Fire blocked; UI shows cooldown bar |
| Disabled | In vehicle OR dead OR match not ACTIVE | Condition cleared | Weapon hidden, no input accepted |

### Interactions with Other Systems

| System | Interaction | Direction |
|--------|-------------|-----------|
| **Input system** | Provides `fire`, `reload`, `aim` action events | Input → Weapon |
| **Player controller** | Provides muzzle transform (world position + forward vector) and movement speed for spread calculation | Player controller → Weapon |
| **Camera system** | Weapon may request camera kickback on fire (small recoil push to camera pitch) | Weapon → Camera |
| **Networking (ADR-0001)** | All fire, reload, and hit RPCs routed via MultiplayerAPI; server authoritative | Weapon ↔ Networking |
| **Hit registration** | Weapon provides ray origin + direction + damage profile. Hit reg resolves what was hit. | Weapon → Hit registration |
| **Health/damage** | Damage values flow into damage pipeline for HP reduction | Weapon → Health |
| **Class loadout system** | Loadout pre-selects which weapon instance this player uses | Class loadout → Weapon |
| **Animation system** | Fire event triggers fire anim; reload event triggers reload anim (AK) or cooldown anim (RPG) | Weapon → Animations |
| **Audio system** | Fire event plays gunshot SFX; reload plays mag-out/mag-in SFX; RPG fire plays launcher thunk + rocket whoosh | Weapon → Audio |
| **VFX system** | Fire event spawns muzzle flash; RPG projectile spawns smoke trail; explosion spawns blast VFX | Weapon → VFX |
| **Capture point system** | Capture points refill reserve ammo (AK only — RPG is infinite) | Capture point → Weapon |
| **HUD** | Shows AK ammo counter, RPG cooldown bar, reload progress, low-ammo toast | Weapon → HUD |
| **Vehicle base system** | Vehicle has separate mounted weapons. Infantry weapons disabled while in vehicle. | Vehicle base → Weapon |

## Formulas

### AK Damage

```
final_damage = base_damage * hit_location_multiplier
```

| Variable | Type | Range | Source | Description |
|----------|------|-------|--------|-------------|
| base_damage | float | 20-50 | data file | Flat per-hit damage, no distance fall-off |
| hit_location_multiplier | float | 1.0-2.86 | hitbox tag | 1.0 body, 2.86 head, 0.75 limbs (deferred to post-MVP; MVP is 1.0 body / 2.86 head only) |

**MVP values**: `base_damage = 35`. TTK body = 3 shots (35+35+35 = 105 ≥ 100 HP). Headshot = 1-shot kill (35 × 2.86 = 100.1).

### AK Fire Rate

```
seconds_between_shots = 60 / fire_rate_rpm
```

**MVP value**: `fire_rate_rpm = 600`. Time per shot = 0.1 s. TTK at 3 body shots = 0.2 s.

### AK Recoil (deterministic pattern)

Pattern is a fixed sequence of `(pitch_offset_deg, yaw_offset_deg)` pairs
applied per shot, in order. When `recoil_recovery_time` seconds pass with no
fire, the pattern index resets to 0.

```
MVP first-10-shot pattern (then repeats):
[(1.0, 0.0), (1.1, -0.2), (1.2, 0.3), (1.3, -0.4), (1.4, 0.5),
 (1.3, 0.6), (1.2, -0.7), (1.1, 0.6), (0.9, -0.5), (0.8, 0.4)]
```

`recoil_recovery_time = 0.5s`.

### AK Spread

```
hipfire_cone_deg = base_hipfire + movement_penalty
movement_penalty = (current_speed / sprint_max_speed) * max_movement_spread
```

**MVP values**: `base_hipfire = 2.5°`, `max_movement_spread = 2.0°`. Standing hipfire = 2.5°, sprinting hipfire = 4.5°.

### AK Reload

```
reload_duration = 2.5s
rounds_transferred = min(reserve_ammo, magazine_capacity - current_magazine)
reserve_ammo_after = reserve_ammo - rounds_transferred
magazine_after = current_magazine + rounds_transferred
```

At MVP, `magazine_capacity = 30`, starting `reserve_ammo = 90`. Ammo refill at capture point restores reserve to 90 over `ammo_refill_duration = 1.0s`.

### RPG Damage

```
if is_vehicle(target):
    damage = rpg_direct_vehicle_damage
elif is_direct_hit(target):
    damage = rpg_direct_infantry_damage
else:  # splash
    distance = world_position(target) - explosion_center
    falloff = 1.0 - (distance / splash_radius)
    damage = rpg_splash_peak * max(0, falloff)
```

**MVP values**:
- `rpg_direct_infantry_damage = 80` (not 1-shot at 100 HP; forces follow-up)
- `rpg_direct_vehicle_damage = 250` (tank at 500 HP dies in 2 direct hits)
- `rpg_splash_peak = 40` (at center of splash, infantry)
- `rpg_splash_radius_infantry = 2.0m`
- `rpg_splash_radius_vehicle = 3.0m` (wider radius against vehicles to account for size)
- `rpg_self_damage_radius = 3.0m` (firing closer than 3m = self-damage)

**Expected outputs**:
- Direct hit infantry at 100 HP → 80 damage → follow-up needed (AK shot or second RPG)
- Splash hit infantry at 1.0m from center → 40 × (1 - 1.0/2.0) = 20 damage
- Splash hit infantry at 2.0m → 0 damage (outside radius)
- Direct hit tank at 500 HP → 250 → 2 shots to kill
- Direct hit helicopter at 300 HP → 250 → 1 shot leaves heli critically damaged

### RPG Cooldown

```
next_fire_time = last_fire_time + rpg_cooldown
```

**MVP value**: `rpg_cooldown = 4.0s`. This is the primary balance lever for infinite-ammo RPG. A Heavy can fire ~15 rockets per minute.

### RPG Projectile Travel

```
projectile_position(t) = muzzle_position + (muzzle_forward * rpg_projectile_speed * t)
```

**MVP values**: `rpg_projectile_speed = 50 m/s`. At this speed, a rocket crosses a 100 m lane in 2.0 s — slow enough that moving targets can dodge, fast enough that stationary targets cannot.

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Fire RPC arrives faster than `fire_rate_rpm` | Server rejects the surplus RPCs, logs as suspicious with client ID | Basic anti-cheat; may indicate modded client |
| Player fires AK while reloading | Reload cancelled, shot fires immediately (if mag > 0) | Player intent prioritized; mirrors real-game feel |
| Player presses R with full magazine | No-op — no timer, no anim | Prevents accidental lock |
| Player presses R with 0 reserve | No-op + "no ammo" toast on HUD for 2 s | Feedback instead of silent fail |
| Player dies mid-reload | State resets on respawn: magazine full, reserve full (AK); RPG cooldown cleared | Death = full re-gear |
| Two AK shots from two players hit same target same tick | Server processes in arrival order; first subtracts HP, second checks remaining | Server decides order; no client-side arbitration |
| RPG fired while target passes behind wall | Projectile collides with wall, no damage to target | Projectile physics — no magic tracking |
| RPG self-damage from close-range shot | Shooter takes splash damage within `rpg_self_damage_radius` | Prevents close-range spam |
| RPG hits teammate | Direct damage blocked; splash to teammate blocked | No friendly fire at MVP |
| AK fire against a vehicle | Full damage applied to vehicle HP pool (vehicle HP is the limiter, not damage type) | Simplicity; AK damage vs tank HP makes AK ineffective by math, not by rule |
| Player at exact `rpg_self_damage_radius` boundary | Takes 0 damage (inclusive outside, exclusive inside) | Deterministic edge resolution |
| LMB held through AK empty→reload→refill | Does NOT auto-resume fire after reload completes | Requires explicit re-pull — prevents accidental spray |
| Helicopter firing its mounted gun + infantry on foot firing AK simultaneously at same target | Both damage instances apply in server tick order | Both are valid damage sources |
| Client predicts hit, server says miss | No damage applied. Hit-feedback system explicitly does not show hit marker unless server confirms. | Server authoritative; documented MVP limitation (no lag comp) |

## Dependencies

| System | Direction | Nature of Dependency |
|--------|-----------|---------------------|
| Input system | Weapon depends on Input | Action events (fire, reload) |
| Player controller | Weapon depends on Player controller | Muzzle transform, movement speed, player HP |
| Networking (ADR-0001) | Weapon depends on Networking | Fire/reload/hit RPCs, server-authoritative resolution |
| Hit registration | Hit registration depends on Weapon | Weapon provides damage profile, ray/projectile origin |
| Health/damage | Health depends on Weapon | Damage values enter damage pipeline |
| Class loadout | Weapon depends on Class loadout | Loadout binds class to weapon instance |
| Camera | Camera depends on Weapon | Camera kickback on fire |
| Animations | Animations depend on Weapon | Fire, reload, cooldown anim triggers |
| Audio | Audio depends on Weapon | Gunshot, reload, explosion SFX |
| VFX | VFX depends on Weapon | Muzzle flash, smoke trail, explosion |
| HUD | HUD depends on Weapon | Ammo counter, cooldown bar, toasts |
| Capture point system | Weapon depends on Capture point | Ammo refill at captured points |
| Vehicle base | Weapon depends on Vehicle base | Weapon disabled in vehicle |

## Tuning Knobs

### AK

| Parameter | Current Value | Safe Range | Effect of Increase | Effect of Decrease |
|-----------|--------------|------------|-------------------|-------------------|
| `base_damage` | 35 | 20-50 | Faster TTK, less skill margin | Slower TTK, more skill margin |
| `headshot_multiplier` | 2.86 | 1.5-3.0 | Rewards aim more | Body shots more viable |
| `fire_rate_rpm` | 600 | 400-900 | Frantic, burns ammo | Slow, AK feels weak |
| `magazine_capacity` | 30 | 20-45 | Less reload pressure | More reload downtime |
| `reserve_ammo` | 90 | 60-180 | Reload spam OK | Ammo economy matters |
| `reload_duration` | 2.5s | 1.8-3.5 | Punishing downtime | Reload spam viable |
| `base_hipfire` | 2.5° | 1.5-5.0 | Close-range dominant | Long-range viable |
| `max_movement_spread` | 2.0° | 1.0-4.0 | Discourages running & gunning | Mobile gunplay viable |
| `recoil_pattern_magnitude` | 1.0× | 0.5-1.5× | Harder spray control | Spray-friendly |
| `recoil_recovery_time` | 0.5s | 0.3-1.0 | Must tap-fire | Continuous fire OK |
| `ammo_refill_duration` | 1.0s | 0.5-3.0 | Must stand on point longer | Instant top-up |

### RPG

| Parameter | Current Value | Safe Range | Effect of Increase | Effect of Decrease |
|-----------|--------------|------------|-------------------|-------------------|
| `rpg_direct_infantry_damage` | 80 | 60-120 | 1-shot at high values | Requires more follow-up |
| `rpg_direct_vehicle_damage` | 250 | 150-400 | Tanks melt fast | Tanks feel tanky |
| `rpg_splash_peak` | 40 | 20-75 | AoE strong | Splash trivial |
| `rpg_splash_radius_infantry` | 2.0m | 1.0-4.0 | Camping strong | Must aim precisely |
| `rpg_splash_radius_vehicle` | 3.0m | 2.0-5.0 | Forgiving vehicle hits | Must direct-hit vehicles |
| `rpg_self_damage_radius` | 3.0m | 1.0-5.0 | Close-range RPG punished | Close-range RPG viable |
| `rpg_cooldown` | 4.0s | 2.0-10.0 | Spam RPGs | Wait matters |
| `rpg_projectile_speed` | 50 m/s | 30-120 | Hit moving targets | Targets can dodge |

## Visual/Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|----------------|---------------|----------|
| AK fire | Muzzle flash VFX, shell eject, small camera kickback | Gunshot SFX (distinct AK "crack"), echo tail outdoors | Must |
| AK reload start | "Reloading" UI text, animation plays (from pack) | Mag-out click SFX | Must |
| AK reload complete | Ammo counter refresh | Mag-in click + bolt-forward SFX | Must |
| AK empty click | None | Dry trigger SFX | Must |
| AK low ammo (< 6 rounds) | Ammo counter turns red | Low-ammo chime (once, on crossing threshold) | Should |
| RPG fire | Launcher smoke VFX from back of tube, projectile spawn | Launcher "thunk" SFX + rocket whoosh (trailing audio on projectile) | Must |
| RPG rocket travel | Rocket exhaust trail VFX (smoke + flame) | Whoosh SFX, 3D-attenuated | Must |
| RPG explosion | Blast VFX (sphere + debris), ground scorch decal | Explosion SFX with low-end punch | Must |
| RPG cooldown active | Dimmed crosshair, cooldown bar on HUD | — | Must |
| RPG cooldown ready | Crosshair re-saturates, subtle chime | "Ready" chime SFX | Should |
| Hit on enemy (handled by hit-feedback.md) | Hit marker on crosshair | Hit tick SFX | Must |
| Headshot | Red hit marker | Higher-pitch tick | Should |
| Kill confirm | Thicker hit marker, 300 ms | Distinct kill SFX | Should |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| AK current mag / reserve | HUD bottom-right (large font) | On fire/reload | Assault class, alive |
| AK reload progress | Center-bottom horizontal bar | 30 Hz during reload | Assault class, reloading |
| AK low-ammo warning | Ammo counter color change (white → red) | On threshold cross | < 6 rounds in mag |
| RPG cooldown bar | HUD bottom-right (large ring around weapon icon) | 30 Hz while cooling | Heavy class, cooldown active |
| RPG "ready" indicator | Crosshair saturates + icon glow | On cooldown expire | Heavy class, ready to fire |
| No-ammo toast | Center screen, fades after 2s | On failed R with 0 reserve | Assault class, reload failed |
| Weapon icon | HUD bottom-right corner | Static | Always alive |

## Acceptance Criteria

**AK**:
- [ ] LMB held fires AK at exactly 600 RPM (± 5%)
- [ ] Body hit deals 35 damage, headshot deals 100 (1-shot at 100 HP), server-verified
- [ ] Recoil pattern is bit-for-bit identical across 10 successive fires (deterministic test)
- [ ] Hipfire spread is 2.5° standing and 4.5° at full sprint, measured via 100-shot grouping test
- [ ] R triggers 2.5 s reload; firing during reload cancels and fires (if mag > 0)
- [ ] Server rejects fire RPCs arriving faster than 10/sec per client
- [ ] Capture point ammo refill fills reserve to 90 over 1 s

**RPG**:
- [ ] LMB fires one rocket per tap; holding LMB does not repeat
- [ ] Direct infantry hit deals 80 damage; splash at 1.0 m from center deals 20 damage
- [ ] Direct vehicle hit deals 250 damage
- [ ] Self-damage applies when explosion is within 3 m of shooter
- [ ] Cooldown enforced at 4.0 s between shots, server-authoritative
- [ ] Rocket travels at 50 m/s straight line, collides with geometry/players/vehicles
- [ ] No friendly fire (direct or splash) applied to same-team targets

**Both**:
- [ ] Weapon state resets to full gear on respawn
- [ ] Weapon disabled while in vehicle, while dead, while match not ACTIVE
- [ ] Server-confirmed hits display via hit-feedback.md pipeline within one tick of server confirmation
- [ ] Performance: fire resolution server-side completes within 2 ms
- [ ] No hardcoded values — all tuning knobs loaded from `assets/data/weapons.tres` or similar Godot resource

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| Is AK ADS added post-MVP? (currently hipfire-only) | Designer | Post-MVP patch 1 | TBD |
| Does RPG support arc/gravity for long-range indirect fire? | Designer | Post-MVP patch 1 | TBD — MVP is straight line |
| Damage fall-off with distance for AK? | Designer | Day 10 playtest | TBD — MVP is flat |
| Cap on Heavy class per team (max 1-2 RPG per side)? | Designer (class-loadout-system.md) | Sprint 3 | TBD |
| Can AK hit a helicopter effectively? (300 HP, 35 dmg/shot = 9 shots = viable with full mag) | Designer | Day 10 playtest | Tentatively yes — helicopter is AoE threat, AK is anti-aircraft-of-last-resort |
| Final AK recoil pattern tuning | Dev | Day 10 playtest | TBD |
| Rocket jump intentionally disallowed? (self-damage at 3m radius) | Designer | Post-MVP | Yes at MVP; may revisit as a mechanic post-MVP |
