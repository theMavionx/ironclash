# VFX System (Framework)

> **Status**: Designed (thin spec — infrastructure layer)
> **Author**: Claude Code Game Studios session
> **Last Updated**: 2026-04-14
> **Implements Pillar**: Skill Is The Ceiling (visual feedback — muzzle flashes, impacts, tracers — communicates shot placement and skill information)

## Overview

The VFX System manages pooled particle effects and visual feedback for weapons,
vehicles, damage, and explosions. It defines pool sizes, GPU vs CPU particle
choice, LOD behavior, and the performance budget for visual effects in the
browser environment. This GDD covers the framework; individual effect
authoring is owned by the technical-artist agent.

## Player Fantasy

Visual feedback makes every shot feel earned. Tracers show the path of bullets.
Impact decals prove where you landed. Explosions feel weighty. The VFX system
succeeds when players *see* their skill reflected on screen without questioning
what happened.

## Detailed Design

### Core Rules

- All recurring effects use **pooled `GPUParticles3D` instances** — instantiate once at scene load, emit on demand
- One-shot explosions use **non-pooled one-shot instances** with `one_shot = true` and auto-free on completion
- VFX is **client-side only** — never part of server simulation, never affects gameplay state
- Effects are **triggered by RPC/signal** from server-authoritative systems (weapon fire, vehicle explode) but rendered locally on each client

### Standard Effect Catalog (MVP)

| Effect | Type | Pool Size | Notes |
|---|---|---|---|
| Muzzle flash (AR) | GPU pooled | 4 | Short-lived, frequent |
| Muzzle flash (RPG) | GPU pooled | 2 | Larger, rarer |
| Muzzle flash (pistol) | GPU pooled | 4 | Small |
| Bullet tracer | GPU pooled | 16 | One per round fired |
| Impact (concrete) | GPU pooled | 8 | Puff + decal spawn |
| Impact (metal) | GPU pooled | 8 | Sparks + decal spawn |
| Impact (flesh) | GPU pooled | 4 | Blood splash (stylized) |
| Explosion (RPG/tank) | One-shot | N/A | Large, heavy |
| Explosion (vehicle death) | One-shot | N/A | Largest, rarest |
| Bullet hole decal | Decal pool | 32 | Auto-expire after 30s |
| Blood decal | Decal pool | 16 | Auto-expire after 10s |
| Vehicle exhaust | GPU continuous | 2 | One per active vehicle |
| Helicopter dust | GPU continuous | 1 | When low altitude over ground |

### Pool Management

- Pools pre-allocated on scene load — no runtime `instantiate()` in the hot path
- When a pool is exhausted, the new request **steals the oldest active instance**
- Pool sizes are tunable (see Tuning Knobs)

### LOD Rules (post-MVP but framework supports from day 1)

- Effects >50 m from camera render with reduced particle count (50%)
- Effects >100 m from camera do not render at all
- MVP: no LOD — rely on pool caps to prevent explosion

### Interactions with Other Systems

- **Weapon System** (event source): muzzle flash, tracer, impact on hit
- **Health/Damage** (event source): blood splash on flesh hit, damage-number float
- **Vehicle Controllers** (event source): exhaust, dust, explosion on destroy
- **Hit Registration** (event source): impact effects spawn at hit location
- **Match State** (event source): match-start / capture flash effects

## Formulas

**Particle count per effect (MVP budget):**
- Muzzle flash: 8-16 particles, 0.1s lifetime
- Tracer: 1 beam particle, 0.2s lifetime
- Impact: 12-24 particles, 0.5s lifetime
- Explosion: 60-120 particles, 1.5s lifetime
- Exhaust (continuous): 8 particles/sec, 2s lifetime each

**Total active particle budget** (worst-case full combat moment):
16 tracers × 1 + 4 muzzles × 16 + 8 impacts × 24 + 1 explosion × 120 + 2 exhaust × 16 = ~450 active particles. Well within `GPUParticles3D` capability on mid-range hardware.

## Edge Cases

- **Many kills simultaneous** (grenade in crowd) → blood effect pool fills, older instances stolen; no crash
- **Explosion during low framerate** → one-shot instance still plays; may appear choppy but doesn't break
- **Player deep underground / outside map** → effects spawn where triggered, may not be visible, that's OK
- **Scene change mid-effect** → active effects are freed with their parent scene; no leak
- **Browser GPU driver mismatch** → fall back to CPU particles if `GPUParticles3D` fails to compile (Godot does this automatically)

## Dependencies

**Upstream:** Godot 4.3 `GPUParticles3D`, `Decal` node, rendering pipeline

**Downstream (depended on by):**
- Weapon System (hard — muzzle flash, tracer, impact)
- Vehicle Controllers (hard — exhaust, explosion)
- Health/Damage (hard — blood, damage numbers)
- Capture Point System (soft — capture flash is nice-to-have)

## Tuning Knobs

| Knob | Range | Default | Effect |
|---|---|---|---|
| `particle_quality` | low / medium / high | medium | Scales particle counts per effect |
| `max_concurrent_particle_systems` | 8-32 | 16 | Cap to prevent GPU overload |
| `decal_lifetime_bullet_seconds` | 5-60 | 30 | How long bullet holes stay |
| `decal_lifetime_blood_seconds` | 3-30 | 10 | How long blood decals stay |
| `lod_near_distance_m` | 30-100 | 50 | Distance where particles reduce (post-MVP) |
| `lod_far_distance_m` | 75-200 | 100 | Distance where particles cull (post-MVP) |

## Acceptance Criteria

- [ ] All MVP effects play through pools without runtime `instantiate()`
- [ ] Frame time stays <16.6 ms during worst-case combat (measured: 4 weapons firing, 1 explosion, 2 vehicles active)
- [ ] No visible pool-exhaustion artifacts (effects cutting out abruptly) under normal 5v5 play
- [ ] Decals expire correctly and do not accumulate across match
- [ ] Effects are triggered by events, never by per-frame polling
- [ ] Client-only — no VFX state appears in network replication

## Open Questions

- Post-process stack: motion blur, bloom? Likely off at MVP for perf. Defer to technical-artist.
- Hit markers for headshots (visual flourish): separate VFX effect or UI element? Leaning UI.
- Stylized vs realistic blood: tied to art direction (stylized low-poly → stylized blood)
