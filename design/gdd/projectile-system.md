---
status: reverse-documented
source: src/gameplay/projectile/
scenes: scenes/projectile/
date: 2026-04-21
---

# Projectile System

> **Status**: Draft (8/8 sections filled, reverse-documented)
> **Author**: AI-assisted reverse-engineering of existing implementation
> **Last Updated**: 2026-04-21
> **Implements Pillar**: Pillar 2 — *Every Tool Has A Counter* (projectile speed lets targets dodge); Pillar 1 — *Skill Is The Ceiling* (leading shots rewards skill)
> **MVP Scope**: Shared raycast-projectile framework used by Tank cannon, Helicopter missile, and RPG rocket.

> **Note**: This document was reverse-engineered from the existing implementation
> in `src/gameplay/projectile/`. It captures current behavior and clarified design
> intent. Numeric values mentioned here are those found in code at the time of writing;
> the canonical values live in weapon-system.md § Tuning Knobs.

## Overview

The projectile system is a shared framework for all physical-travel weapon
projectiles in Ironclash. Unlike AK bullets (hitscan — see weapon-system.md),
projectiles launched by tanks, helicopters, and RPGs take finite travel time
and can be visually tracked, dodged, and intercepted. Implementation uses a
**raycast-based projectile** (not a physical RigidBody3D) that sweeps a
RayCast3D one frame of travel ahead each physics tick, guaranteeing no
tunneling at any projectile speed. On collision, the projectile applies
damage to any `HealthComponent` on the hit target, spawns an impact VFX
(flash + volumetric smoke), and self-frees. All projectile behavior is
server-authoritative per ADR-0001; client-side projectiles are visual-only
replicas spawned from server RPC events.

## Player Fantasy

Projectiles make combat **visible**. You see the tank shell arcing toward
the flanking infantry, you see the helicopter's missile trailing smoke, you
see the RPG rocket leaving the Heavy's launcher. Every projectile is a
second chance — a chance for the target to dodge, a chance for a teammate
to counter-fire, a chance for the shooter to pre-aim. The fantasy is
**slow, heavy, committed violence** — the projectile hits when the shooter
earned it through lead, not through reflex. Watching your own RPG rocket
travel the final 30 meters to detonate on a tank is a unique satisfaction
that hitscan weapons cannot replicate.

## Detailed Design

### Core Rules

1. A projectile is spawned server-authoritatively when a weapon fire RPC is validated by the server (see weapon-system.md core rule 3).
2. Each projectile carries: `damage: int`, `damage_source: DamageTypes.Source`, `shooter: CollisionObject3D` (the firing vehicle/player, used to prevent self-hit).
3. On spawn, the projectile's RayCast3D is configured with `target_position` equal to one physics-frame's worth of travel at max speed (`speed / 30` units forward). This sweep length guarantees the projectile cannot tunnel through geometry faster than the tick rate allows.
4. The shooter is added as a `RayCast3D` exception so the projectile never registers a self-hit on the firing frame.
5. Each physics tick: check ray collision **before** translating the projectile. If collision: apply damage, spawn impact VFX, `queue_free()`. Otherwise translate `speed * delta` forward.
6. A projectile has a hard lifetime (default 3.0s). If no collision occurs before lifetime expires, the projectile self-frees silently (no VFX).
7. Collision mask determines what physics layers the projectile tests against. Default layers: world/terrain (1) + vehicles (2). Infantry layer (not yet assigned at MVP; tracked as Open Question).
8. On collision, if the collider has a child `HealthComponent` (name-matched node), call `health.take_damage(damage, damage_source)`.
9. Impact VFX (`scenes/projectile/shell_impact.tscn`) is spawned in world space parented to the current scene (NOT to the projectile, which is about to free itself).
10. Impact orientation: the VFX's local +Y is aligned with the surface normal of the hit using `Basis(Quaternion(Vector3.UP, hit_normal.normalized()))`, which handles degenerate cases (parallel vectors) correctly.
11. Muzzle flash (`scenes/projectile/muzzle_flash.tscn`) is spawned at the weapon muzzle transform on fire (not on hit). It is a 3-frame billboard sprite animation, self-freeing when the last frame has displayed.
12. Smoke volume (`scenes/projectile/smoke_volume.tscn`) persists longer than flash — 1s spawn-in + 10s sustain + 5s fade = 16s total — creating a brief lingering cloud marking the impact location. Uses Godot's FogVolume with a custom 3D-noise shader.

### Projectile Variants (speed / damage / lifetime per weapon)

| Weapon | Projectile Speed | Damage | Lifetime | Splash | Visual |
|--------|-----------------|--------|----------|--------|--------|
| Tank Cannon | 60 m/s | 100 (scene default) | 3.0 s | None (direct hit only at MVP) | Large muzzle flash + large impact smoke |
| Helicopter Missile | 80 m/s (proposed; not yet set in scene) | 150 | 3.0 s | 2.0m radius (post-MVP) | Smoke trail during travel + medium impact |
| RPG Rocket | 50 m/s (per weapon-system.md) | 80 infantry / 250 vehicle | 3.0 s | 2.0m infantry / 3.0m vehicle | Smoke trail during travel + large blast impact |

Note: The `tank_shell.gd` script currently has `@export var speed = 60.0`
as the hardcoded scene default. For RPG and Helicopter missile variants,
the scene instance must override this value. This is flagged as tech debt
(see § Technical Debt).

### States and Transitions

| State | Entry Condition | Exit Condition | Behavior |
|-------|----------------|----------------|----------|
| In Flight | Server confirms fire RPC, projectile spawned | Collision OR lifetime expiry | Translate `speed * delta` forward; raycast ahead |
| Colliding | RayCast3D detects collision | Immediately transitions to Free | Apply damage, spawn impact VFX |
| Expired | Lifetime < 0 | Immediately transitions to Free | Silent free (no VFX) |
| Free | End of either Colliding or Expired | N/A (node removed) | Node destroyed via `queue_free()` |

### Interactions with Other Systems

| System | Interaction | Direction |
|--------|-------------|-----------|
| **Weapon system** | Weapon provides projectile parameters via `setup(source, damage, shooter)` before adding to scene | Weapon → Projectile |
| **Health/damage** | Projectile calls `HealthComponent.take_damage()` on hit | Projectile → Health |
| **Combat framework** | Uses `DamageTypes.Source` enum to tag damage attribution | Combat framework ← Projectile |
| **Networking (ADR-0001)** | Projectile spawn is server-authoritative; clients receive spawn RPC | Projectile ↔ Networking |
| **Tank controller** | Tank cannon spawns TankShell instances | Tank → Projectile |
| **Helicopter controller** | Helicopter weapons spawn projectile instances | Helicopter → Projectile |
| **Vehicle base system** | `shooter` reference is the firing CollisionObject3D (typically the vehicle root) | Vehicle base → Projectile |
| **VFX system** | Muzzle flash, impact flash, and smoke volume draw on VFX framework primitives | Projectile → VFX |
| **Audio system** | Fire (launcher thunk), travel (whoosh loop on moving projectile), impact (explosion boom) | Projectile → Audio |

## Formulas

### Anti-Tunneling Ray Length

```
ray_target_position = Vector3(0, 0, -(speed / ray_tick_rate))
```

`ray_tick_rate = 30.0` in current code — conservative frame floor. At
`speed = 60 m/s`, ray length = 2.0 m per tick, which is longer than any
individual physics tick would travel (actual travel per tick ≈ `60 * 0.0167 ≈ 1.0 m`
at 60 Hz or `60 * 0.0333 ≈ 2.0 m` at 30 Hz). Extra headroom prevents
tunneling when physics hiccups.

### Translation per Tick

```
position += Vector3(0, 0, -speed * delta)  # local forward
```

### Lifetime Countdown

```
remaining_life -= delta
if remaining_life <= 0:
    queue_free()
```

### Impact Orientation

```
if hit_normal.length_squared() > 0.001:
    impact.global_transform.basis = Basis(Quaternion(Vector3.UP, hit_normal.normalized()))
```

Using `Quaternion(from, to)` explicitly — the naive cross-product-from-UP
approach produces a degenerate Basis when `hit_normal == Vector3.UP` or
`hit_normal == Vector3.DOWN`.

### Smoke Volume Lifetime

```
tween: density 0 → smoke_density (over spawn_time=1.0s)
       → hold (sustain_time=10.0s)
       → density → 0 (over fade_time=5.0s, EASE_IN)
       → queue_free()

total_lifetime = 1 + 10 + 5 = 16s
```

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Projectile fired from inside the muzzle intersects a wall immediately | Shooter exception prevents self-hit on spawn frame; if wall is not-self, impact fires on tick 1 | Expected — shoots into wall at point blank = explosion at wall |
| Two projectiles cross paths at same point | Both resolve independently; each raycast is local to its projectile | No projectile-vs-projectile collision at MVP |
| Projectile hits a target whose HealthComponent has HP = 0 (already dead) | Damage applied; HealthComponent ignores damage if dead (see health-and-damage-system.md) | Damage call is safe |
| Projectile's lifetime expires mid-air over nothing | Silent free; no VFX | Prevents visual spam at skybox |
| `impact_scene` is null or fails to instantiate | `push_error` logged; projectile still frees itself | Graceful failure; does not crash |
| Shooter dies mid-flight of own projectile | Projectile continues on course; damage still applied to targets | Projectile is self-contained after spawn |
| Target passes behind wall between fire and impact | Ray collides with wall; target takes no damage | Expected — line-of-sight required |
| Projectile travels faster than physics tick allows | Ray is pre-swept, so any target along travel path is caught | No tunneling by design |
| Server desyncs projectile from client visual | Client projectile is visual-only — server damage wins | Per ADR-0001, server authoritative |
| Projectile fired during match state != ACTIVE | Server rejects fire RPC; projectile never spawns | Per weapon-system.md core rule 5 |

## Dependencies

| System | Direction | Nature |
|--------|-----------|--------|
| Weapon system | Projectile depends on Weapon | `setup()` call provides damage + source |
| Health/damage | Health depends on Projectile | Receives `take_damage()` calls |
| Combat framework (damage_types) | Projectile depends on Combat framework | `DamageTypes.Source` enum |
| Networking (ADR-0001) | Projectile depends on Networking | Server-authoritative spawn, RPC mirroring |
| Tank controller | Projectile ← Tank | Tank spawns projectiles |
| Helicopter controller | Projectile ← Helicopter | Helicopter spawns projectiles |
| VFX system framework | Projectile depends on VFX framework | Pooling, GPUParticles3D primitives |
| Audio system | Audio depends on Projectile | Lifecycle events |

## Tuning Knobs

Per-projectile tuning lives in each weapon's scene or the firer's `setup()` call. Shared framework tunables:

| Parameter | Current | Safe Range | Increase | Decrease |
|-----------|---------|-----------|----------|----------|
| `speed` (per-projectile) | 50-80 m/s | 20-200 | Easier to hit moving targets | Targets dodge easily |
| `lifetime` | 3.0 s | 1.0-10.0 | Longer-range indirect fire | Short-range only |
| `collision_mask` | 0b11 (world + vehicles) | — | Include infantry layer (pending) | Restrict to specific classes |
| `ray_tick_rate` (anti-tunnel) | 30 Hz | 30-120 | Tighter tunnel safety | Risk tunneling at high speeds |
| Muzzle flash `frame_duration` | 0.04 s (3 frames × 0.04 = 0.12s total) | 0.02-0.10 | Longer visible flash | Snappier flash |
| Impact `total_lifetime` | 4.0 s | 2.0-10.0 | Longer VFX dwell | Faster cleanup |
| Smoke volume `sustain_time` | 10.0 s | 5.0-30.0 | Lingering battlefield smoke | Cleaner sightlines after fight |

## Visual/Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|----------------|---------------|----------|
| Fire | Muzzle flash sprite (3-frame, 0.12s) at weapon muzzle | Fire SFX (per weapon: tank boom, heli whoosh, RPG thunk) | Must |
| In flight | Smoke trail behind projectile (Heli/RPG — not yet implemented for Tank shell) | 3D-attenuated whoosh loop that tracks the projectile | Should |
| Impact (terrain) | `ShellImpact` spawn: flash particles + FogVolume smoke; scorch decal on geometry (post-MVP) | Impact boom with terrain-specific tail (dirt, stone, metal) | Must |
| Impact (vehicle) | Same impact VFX + hit spark particles from the vehicle's HealthComponent | Vehicle-specific impact SFX (metal clang, explosive boom) | Must |
| Impact (infantry, direct hit) | Blood burst VFX (minimal at MVP) + body-specific impact sound | Gore SFX (toned down) | Must |
| Projectile expired in air | No VFX, no SFX | Silent | Must (prevents skybox spam) |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| Crosshair lead-indicator (post-MVP helper) | Center of screen | 60 Hz | Aiming at moving target with projectile weapon |
| None at MVP for projectile-specific UI | — | — | — |

## Acceptance Criteria

- [ ] A tank shell spawned with `speed=60, damage=100` travels forward at 60 m/s and applies 100 damage on any HealthComponent target
- [ ] An RPG rocket spawned with `speed=50, damage=80, shooter=heavy_player` travels at 50 m/s, deals 80 damage on direct infantry hit, and 250 on direct vehicle hit (damage differentiation handled by HealthComponent / weapon-system.md)
- [ ] A projectile's RayCast3D never detects the firing vehicle on any frame (shooter exception)
- [ ] A projectile lifetime of 3.0 s silently frees the projectile if no collision occurs
- [ ] Impact VFX is reparented to the scene root (not the projectile) on hit, so it persists after projectile free
- [ ] Smoke volume plays its 1s spawn → 10s sustain → 5s fade tween and then frees itself
- [ ] Muzzle flash billboards correctly and cycles 3 frames at 0.04s/frame (0.12s total)
- [ ] No visible tunneling observed at any projectile speed up to 200 m/s
- [ ] Server-authoritative spawn: clients cannot trigger projectile spawn client-side
- [ ] Performance: 20 simultaneous active projectiles adds < 2 ms per physics tick server-side

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| Infantry collision layer assignment (projectile collision_mask) | Gameplay prog | Sprint 3 | TBD — must include infantry layer for RPG to hit players directly |
| Smoke trail during projectile flight — implement per weapon? | Technical artist | Post-MVP | Nice-to-have; skip for MVP |
| Splash damage for Helicopter missile (currently 0 at MVP) | Designer | Post-MVP | MVP: direct-hit only. Post-MVP: 2m splash. |
| Scorch decal on terrain impact | Technical artist | Post-MVP | Deferred |
| Projectile-vs-projectile collision (e.g., shoot down a rocket mid-air)? | Designer | Post-MVP | Deferred; would require layer change |
| Server-side lag compensation for fast projectiles | Network prog | Post-MVP | Not feasible at MVP per ADR-0001 |

## Technical Debt (per .claude/rules/gameplay-code.md)

The current implementation exposes tuning values as `@export` fields on the
`TankShell` node, which allows Scene-level overrides but NOT data-driven
configuration via `Resource` files as required by the project coding rule
"ALL gameplay values MUST come from external config/data files". Specifically:

- `speed`, `lifetime`, `damage`, `collision_mask`, `damage_source` are scene defaults
- `impact_scene` is a hardcoded `preload` path

**Proposed refactor** (Sprint 3 or post-MVP):
- Create `assets/data/projectiles.tres` as a `Resource` defining TankShell, HeliMissile, RPGRocket variants
- `TankShell.setup()` accepts a `ProjectileResource` instead of individual args
- Weapon scenes reference the resource by path, not by `@export` override
