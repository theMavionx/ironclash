---
status: reverse-documented
source: src/gameplay/combat/
date: 2026-04-21
---

# Combat Framework

> **Status**: Draft (8/8 sections filled, reverse-documented)
> **Author**: AI-assisted reverse-engineering of existing implementation
> **Last Updated**: 2026-04-21
> **Implements Pillar**: Supports all three pillars as shared combat infrastructure
> **MVP Scope**: Shared damage-attribution enum and extensibility pattern for all weapon → health paths.

> **Note**: This document describes the shared combat "glue" — the enum and
> hooks that let weapons (tank, heli, drone, RPG, AK) feed into a single
> HealthComponent damage pipeline. It reverse-documents
> `src/gameplay/combat/damage_types.gd` and its role as the attribution
> layer. The closely-related `src/gameplay/combat/destruction_vfx.gd` is
> documented separately in `destruction-effects.md`.

## Overview

The combat framework is the shared layer between weapons (projectile,
hitscan, kamikaze) and the health system. It provides two elements:

1. **`DamageTypes.Source` enum** — a single authoritative list of damage
   attribution tags. Every hit that touches a `HealthComponent` carries
   exactly one source identifier, enabling downstream systems (kill feed,
   scoring, VFX branching, death-cam framing) to react appropriately
   without each weapon needing to implement its own tagging scheme.
2. **A uniform call contract** — `HealthComponent.take_damage(amount: int,
   source: DamageTypes.Source)` — called by tank shells, drone kamikaze
   impacts, helicopter missiles, and (when implemented) RPG rockets and
   AK hitscan.

The framework is deliberately thin. It is not a damage calculator, a
buff/debuff system, or a status-effect manager. Those responsibilities
belong to weapon-system.md (damage numbers), health-and-damage-system.md
(HP math), and a future status effects system (post-MVP).

## Player Fantasy

There is **no direct player-facing fantasy** for the combat framework —
it is infrastructure. Its value to the player is indirect: because every
weapon reports damage through the same contract, the **kill feed is
consistent** ("Killed by tank shell", "Killed by drone"), the **MVP card
at post-match** can correctly attribute damage, and future features
(damage-over-time effects, status inflictions) can be added without
rewriting every weapon.

## Detailed Design

### Core Rules

1. `DamageTypes` is a `RefCounted` script exposing a single enum `Source`. It is NOT a singleton / autoload — it is used only for its enum type.
2. The `Source` enum currently contains three values:
   - `TANK_SHELL` (0)
   - `HELI_MISSILE` (1)
   - `DRONE_KAMIKAZE` (2)
3. The enum is **open for extension**. As AK, RPG, and future weapons are implemented, new values will be appended (never inserted or reordered — the enum's integer values are stable for save-compat and network serialization).
4. Every weapon that deals damage to a `HealthComponent` MUST pass its corresponding `DamageTypes.Source` value to `take_damage()`. Weapons must not call damage-pipeline functions without a source.
5. `HealthComponent.take_damage(amount, source)` is the uniform entry point. Its implementation:
   - Applies damage math (e.g., vehicle-vs-infantry multipliers, see health-and-damage-system.md)
   - Emits signals with the `source` included for observers (kill feed, scoreboard, VFX manager)
   - On HP reaching 0, emits `destroyed(source)` — the source of the killing blow
6. Downstream consumers of `destroyed` signal (tank, heli, drone controllers) branch on `source` to decide visual behavior:
   - `DRONE_KAMIKAZE` → large explosion + charred wreck
   - `TANK_SHELL` / `HELI_MISSILE` → medium explosion + charred wreck
   - (future) `AK` → blood spurt, no wreck (infantry)
   - (future) `RPG` → large splash VFX + ragdoll infantry
7. The kill feed (see hud.md § kill feed) reads `source` to print the weapon name used in kills.
8. Match scoring (see match-scoring.md) does NOT branch on `source` for point awards — points depend on the **victim type**, not the weapon.

### Damage Source Expansion Roadmap

| Source | Integer Value | Status | Added When |
|--------|--------------|--------|-----------|
| TANK_SHELL | 0 | Implemented | 2026-04-18 (tank controller) |
| HELI_MISSILE | 1 | Implemented | 2026-04-19 (helicopter controller) |
| DRONE_KAMIKAZE | 2 | Implemented | 2026-04-20 (drone controller) |
| AK | 3 (proposed) | Pending | When weapon-system.md § AK is implemented |
| RPG_DIRECT | 4 (proposed) | Pending | When weapon-system.md § RPG is implemented |
| RPG_SPLASH | 5 (proposed) | Pending | When weapon-system.md § RPG splash is implemented |
| FALL_DAMAGE | 6 (proposed) | Pending | If fall damage added (currently not at MVP) |
| OUT_OF_BOUNDS | 7 (proposed) | Pending | If world-boundary kill added |
| UNKNOWN | 99 (proposed) | Reserved | Fallback for edge cases |

### States and Transitions

The combat framework itself is stateless — it is an enum and a call
contract. State lives in the sources (weapons) and the sink
(HealthComponent). No transitions to document here.

### Interactions with Other Systems

| System | Interaction | Direction |
|--------|-------------|-----------|
| **All weapons** (projectile, drone, AK, RPG) | Weapons pass `DamageTypes.Source` to `HealthComponent.take_damage()` | Weapons → Combat → Health |
| **Health/damage system** | Consumes source, branches damage math, emits signals with source | Combat ← Health |
| **HUD — kill feed** | Reads source to print weapon name in feed entries | Combat → HUD |
| **Match scoring** | Source informs (future) weapon-specific kill bonuses (e.g., "DRONE_KAMIKAZE worth 15 pts instead of 10") | Combat → Match scoring |
| **Destruction effects** | Source informs which destruction VFX pattern to play | Combat → Destruction effects |
| **Camera system** (death cam) | Source informs kill-cam framing (projectile trajectory playback — post-MVP) | Combat → Camera |
| **Post-match summary UI** | Source informs "top killer weapon" stat (post-MVP) | Combat → Post-match |

## Formulas

No formulas — the framework is a tagging/routing layer.

Related formulas live in:
- `weapon-system.md` — per-weapon damage values
- `health-and-damage-system.md` — damage reduction, armor math
- `match-scoring.md` — kill point values per victim type

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Weapon calls `take_damage(amount)` without a source | Fails at compile time (type required); at runtime the fallback is `UNKNOWN` once added | Enforce tagging contract |
| Two weapons hit the same target in the same tick | Each `take_damage()` call is a separate event with its own source; last killing blow wins the kill credit | Per ADR-0001 tick ordering |
| Damage source enum value persisted over network as integer (e.g., 0 = TANK_SHELL) | Stable integers; never reorder, only append | Save / network compat |
| A mod or plugin wants to add a custom damage source | MUST edit `DamageTypes` directly and extend the enum; no runtime extension supported at MVP | Simplicity, no dynamic source registration |
| Legacy `take_damage` calls from old code without source | Flagged by lint rule / code review; must be updated | Contract strictness |
| `DRONE_KAMIKAZE` source applied to drone's own self-destruct | Drone's HealthComponent receives self-damage with source = DRONE_KAMIKAZE; destroyed signal fires with that source | Self-attribution accepted |

## Dependencies

| System | Direction | Nature |
|--------|-----------|--------|
| Weapon system | Weapon depends on Combat framework | Uses DamageTypes.Source |
| Health/damage system | Health depends on Combat framework | `take_damage(amount, source)` signature |
| Tank controller | Tank depends on Combat framework | TANK_SHELL source |
| Helicopter controller | Helicopter depends on Combat framework | HELI_MISSILE source |
| Drone controller | Drone depends on Combat framework | DRONE_KAMIKAZE source |
| HUD (kill feed) | HUD depends on Combat framework | Reads source for display |
| Match scoring | Match scoring depends on Combat framework | Future source-specific scoring |
| Destruction effects | Destruction effects depends on Combat framework | Source informs VFX choice |

## Tuning Knobs

The framework itself has no tuning — it is a routing layer. Relevant tuning:

| Concern | Where Tuned |
|---------|-------------|
| How much damage each weapon deals | `weapon-system.md` |
| How much damage reduction armor provides | `health-and-damage-system.md` |
| How many kill points per damage source | `match-scoring.md` (currently victim-based, can become source-based post-MVP) |

## Visual/Audio Requirements

The framework has no direct visuals or audio. Its consumers (HUD, VFX, Audio) use the `source` tag to choose:

| Event | Framework Role | Example |
|-------|---------------|---------|
| Kill feed line | Provides weapon name from source | "Dex killed Alex with TANK_SHELL" |
| Death cam framing | Future source-specific camera (post-MVP) | DRONE_KAMIKAZE cam zooms on impact |
| Impact VFX selection | Source informs VFX dispatch table | DRONE_KAMIKAZE → fragmentation, TANK_SHELL → scorch |
| Hit SFX selection | Source informs audio cue | HELI_MISSILE → whoosh-boom, AK → crack-thud |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| Kill feed entries with weapon name (from source) | Top-right HUD | On kill | Per standard kill feed |
| "Killed by X" text on death screen | Center-top | Static | On own death |
| Post-match "top weapon" stat (post-MVP) | Post-match summary | Static | End of match |

## Acceptance Criteria

- [ ] `DamageTypes.Source` enum exists at `src/gameplay/combat/damage_types.gd`
- [ ] Current values: TANK_SHELL=0, HELI_MISSILE=1, DRONE_KAMIKAZE=2
- [ ] All existing damage calls (tank, heli, drone) pass a valid `Source` value
- [ ] New damage sources are added by APPENDING to the enum (never inserting)
- [ ] `HealthComponent.take_damage(amount, source)` accepts the enum correctly
- [ ] `HealthComponent.destroyed(source)` signal carries the killing-blow source
- [ ] Kill feed reads the source and displays the corresponding weapon name
- [ ] Adding a new source (e.g., AK = 3) does not break any existing code paths
- [ ] Code review catches any `take_damage` call missing a source parameter

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| Should AK splash/ricochet be a different source than AK direct hit? | Designer | When AK implemented | Tentative: no, one AK source is enough |
| Should fall damage and out-of-bounds be implemented at MVP? | Designer | Sprint 3 | MVP: no fall damage; out-of-bounds handled by map geometry |
| Should there be a per-source damage multiplier in HealthComponent (e.g., vehicles take 1.5× from RPG)? | Designer (health-and-damage-system.md) | Sprint 3 | Possible — see health GDD |
| Should weapon-specific kill points per source replace current victim-based kill points? | Designer (match-scoring.md) | Post-MVP | Tentative: no, victim-based is cleaner |
| Status effects (burn, stun, bleed) — extend Combat framework or separate system? | Designer | Post-MVP | Separate system; Combat framework remains thin |
| Should source be an Object rather than enum (to carry richer metadata like shooter ID)? | Lead programmer | Post-MVP | Probably not — current integer enum plus separate RPC args (shooter_id) is cleaner |

## Technical Debt (per .claude/rules/gameplay-code.md)

- The `DamageTypes.Source` enum is hardcoded in GDScript. For a more
  data-driven approach, it could be migrated to a `Resource` file listing
  allowed sources. **Deferred — enum is fine for MVP**; the rule's intent
  is about gameplay _values_ (damage, cooldowns), not enum identifiers.
- No lint rule exists to catch `take_damage()` calls missing a source
  parameter — recommend adding to `.claude/rules/` or code-review
  checklist.
