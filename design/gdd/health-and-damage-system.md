# Health & Damage System

> **Status**: Designed
> **Author**: Claude Code Game Studios session
> **Last Updated**: 2026-04-14
> **Implements Pillar**: Skill Is The Ceiling (TTK favors aim/positioning) + Every Tool Has A Counter (RPG hard-counters vehicles)

## Overview

The Health & Damage System owns every entity's hit points, damage application
pipeline, hitbox multipliers, distance falloff, regeneration rules, and death
events. It is the central authority that determines whether a shot kills,
hurts, or does nothing — and propagates the resulting state changes to the
respawn system, scoring system, HUD, and audio. The system is fully
**server-authoritative** (per ADR-0001).

## Player Fantasy

Damage feels **earned and clear**. A well-placed headshot rewards aim
visibly. A spray that lands center-mass kills in a few rounds, not 20.
Vehicles are scary but **fragile** — three RPGs and a tank is gone, two
RPGs and the helicopter falls from the sky. This makes the RPG class feel
*decisive* and creates the dramatic "tank rolling in → 3 RPGs from
defenders → boom" moments core to the combined-arms fantasy.

Health regen up to a partial threshold (50/100) means: after a fight you
recover enough to keep playing, but the longer you survive without
respawning, the more vulnerable you stay. Punished risk, rewarded careful
positioning.

## Detailed Design

### Core Rules

1. The Health & Damage System is **fully server-authoritative**. Clients display HP from server snapshots; clients never compute damage authoritatively.
2. Every damageable entity has: `current_hp`, `max_hp`, `is_alive`, `last_damage_time`, `last_attacker_id`.
3. A damage event has: `source_entity`, `target_entity`, `weapon_type`, `hit_zone`, `distance`, `base_damage`.
4. Damage is applied in pipeline order: **base_damage → falloff → hitbox multiplier → friendly-fire filter → final damage → HP deduction → death check → events fired**.
5. **Friendly fire is OFF** at MVP. Damage to teammates is filtered to 0 before HP deduction.
6. Regeneration applies only to player entities, only to a **threshold of 50 HP**, only after a 5-second damage-free window.
7. Vehicles do not regenerate.
8. On death: HP set to 0, `is_alive = false`, death events fired (kill feed, scoring, respawn timer start, drop player from any vehicle they occupied).

### Player HP

| Class | Max HP | Notes |
|---|---|---|
| Assault (AK) | 100 | Standard |
| Heavy (RPG) | 100 | Same — no class HP advantage |

Equal HP across classes simplifies balance — class differentiation comes from weapons, not durability.

### Vehicle HP

| Vehicle | Max HP | Dies in (RPG hits) | Notes |
|---|---|---|---|
| Tank | 750 | 3 | Slow, heavily armored against small arms, vulnerable to RPG |
| Helicopter | 500 | 2 | Fragile — 2 RPGs is dead. Mobility is the survival mechanism. |

### Damage Sources & Base Values

| Weapon | Base Damage (vs player) | Damage (vs vehicle) | Notes |
|---|---|---|---|
| AK (Assault rifle) | 22 | 3 per round | Hitscan, falloff applies |
| RPG | 250 (direct) / 80 (splash within 4 m) | 250 | Projectile, no falloff (single-shot weapon) |
| Tank cannon | 200 (direct) / 100 (splash within 6 m) | 200 | Projectile, vehicle weapon |
| Helicopter minigun | 18 per round | 5 per round | Hitscan, faster fire rate than AK |
| Helicopter rockets (post-MVP) | 150 / 60 splash | 150 | Projectile |

**TTK calculations (player target, no falloff):**
- AK center-mass: 100 ÷ 22 = ~5 rounds = ~0.5 s at 600 RPM
- AK headshot: 100 ÷ (22 × 2.5) = ~2 rounds
- RPG direct: 1 hit (instakill)
- Tank cannon direct: 1 hit (instakill)

This sits in the **medium TTK** range, matching PUBG-style pacing.

### Hitbox Multipliers (player only)

| Hit Zone | Multiplier | Result vs AK |
|---|---|---|
| Head | ×2.5 | 55 dmg |
| Stomach | ×1.1 | 24.2 dmg |
| Torso (default) | ×1.0 | 22 dmg |
| Limbs (arms/legs) | ×0.7 | 15.4 dmg |

Vehicles have **no hitbox zones** at MVP — uniform damage anywhere on the model. (Post-MVP could add weak-points like helicopter tail rotor.)

### Damage Falloff (hitscan weapons only)

| Distance | Multiplier |
|---|---|
| 0 – 30 m | 1.00 |
| 30 – 80 m | linear interpolate to 0.50 |
| 80 m+ | 0.50 (floor) |

Projectile weapons (RPG, tank cannon) have **no falloff** — full damage anywhere they hit.

### Regeneration Rules

- **Trigger:** 5.0 seconds since `last_damage_time`
- **Rate:** 25 HP per second
- **Cap:** regen stops at 50 HP (cannot regen above this)
- If `current_hp >= 50` already (from being undamaged), regen does nothing
- If a player takes damage during regen, the timer resets and regen halts immediately
- Vehicles do not regen at all

### Death Pipeline

When `current_hp` reaches 0:
1. Server sets `is_alive = false`, `current_hp = 0`
2. Server broadcasts `on_player_killed(victim_id, killer_id, weapon, hit_zone)` RPC to all clients
3. If victim is in a vehicle, vehicle ejects them (vehicle remains alive)
4. Respawn System receives the death event and starts the respawn timer
5. Camera System switches victim's view to spectator orbit on killer
6. Match Scoring receives the kill event for K/D and team score
7. HUD updates kill feed for all clients

For vehicles:
1. Server sets vehicle `is_alive = false`
2. Server broadcasts `on_vehicle_destroyed(vehicle_id, killer_id, weapon)` RPC
3. Vehicle ejects all occupants (each takes 50 dmg from explosion as damage event)
4. Vehicle entity persists for 2 s as a smoking wreck (visual), then is freed
5. Vehicle does NOT respawn automatically at MVP — vehicles spawn once per match (decision deferred to Vehicle System; this system supports either model)

### Interactions with Other Systems

- **Hit Registration** (upstream): provides hit events with source, target, weapon, hit zone, distance — feeds into damage pipeline
- **Weapon System** (upstream): defines `base_damage`, weapon class, falloff curve per weapon
- **Networking** (peer): replicates HP via `MultiplayerSynchronizer` server→client; death events via RPCs
- **Player Controller** (downstream): reads `is_alive` to enable/disable controller
- **Camera System** (downstream): reads `is_alive` to switch to spectator camera; receives damage event for screen shake
- **Respawn System** (downstream): receives death event to start respawn timer
- **Match Scoring** (downstream): receives kill events for K/D and team score
- **HUD** (downstream): displays HP bar, damage indicators (directional), low-HP overlay
- **Audio System** (downstream): hit sounds, death sounds, regen ambient cue
- **VFX System** (downstream): blood splash on hit, vehicle wreck explosion

## Formulas

### Damage application pipeline

```
function apply_damage(source, target, weapon, hit_zone, distance):
    if not target.is_alive:
        return 0

    if friendly_fire == false and source.team == target.team:
        return 0

    damage = weapon.base_damage_vs_player if target.is_player else weapon.base_damage_vs_vehicle

    if weapon.uses_falloff and distance > 0:
        if distance <= falloff_near:                    # 30 m
            falloff_mult = 1.0
        elif distance >= falloff_far:                   # 80 m
            falloff_mult = falloff_min                  # 0.5
        else:
            t = (distance - falloff_near) / (falloff_far - falloff_near)
            falloff_mult = lerp(1.0, falloff_min, t)
        damage *= falloff_mult

    if target.is_player and hit_zone in hitbox_multipliers:
        damage *= hitbox_multipliers[hit_zone]

    damage = max(round(damage), 0)
    target.current_hp -= damage
    target.last_damage_time = now
    target.last_attacker_id = source.id

    if target.current_hp <= 0:
        target.current_hp = 0
        target.is_alive = false
        fire_death_event(target, source, weapon, hit_zone)

    return damage
```

### Splash damage (RPG, tank cannon, vehicle explosion)

```
function apply_splash(source, weapon, impact_position):
    for entity in entities_within_radius(impact_position, weapon.splash_radius):
        distance_to_impact = entity.position.distance_to(impact_position)
        falloff = 1.0 - (distance_to_impact / weapon.splash_radius)   # linear falloff inside radius
        splash_dmg = weapon.splash_base_damage * falloff
        apply_damage(source, entity, weapon, hit_zone="torso", distance=0)  # use base, splash already calculated
```

For RPG:
- `splash_radius = 4 m`
- `splash_base_damage = 80`

For tank cannon:
- `splash_radius = 6 m`
- `splash_base_damage = 100`

For vehicle wreck explosion (on destroy):
- `splash_radius = 5 m`
- `splash_base_damage = 50`

### Regeneration tick (server-side, per second)

```
for player in alive_players:
    time_since_damage = now - player.last_damage_time
    if time_since_damage >= 5.0 and player.current_hp < 50:
        regen_amount = 25 * delta_time
        player.current_hp = min(player.current_hp + regen_amount, 50)
```

## Edge Cases

- **Damage to dead entity** → ignored, returns 0
- **Self-damage** (RPG fired at close range) → applies normally (no self-damage immunity); rewards careful RPG use
- **Friendly fire from vehicle splash** → blocked by friendly-fire filter (teammate splash = 0 damage)
- **Headshot through helmet** (no helmet item at MVP) → headshot multiplier applies fully; no helmet system
- **Damage exactly equal to current_hp** → kill is registered (HP = 0, death event fires)
- **Multiple damage events same tick** (player hit by 2 simultaneous bullets) → applied sequentially in order received; if first kills, second still queues but does no work (entity already dead)
- **Vehicle destroyed with players inside** → all occupants ejected and take 50 splash damage (may also kill them, chained deaths fire correctly)
- **RPG hits a wall 1m from player** → splash damage applies to player at falloff
- **Long-range AK at 100m hits headshot** → 22 × 0.5 (falloff) × 2.5 (head) = 27.5 dmg. Headshot reward partially offset by falloff. By design.
- **Regen during a fight** → first hit resets timer; player cannot regen mid-combat
- **Player HP at 51 takes 1 damage** → drops to 50; regen could immediately start it back up after 5s wait
- **Player below 50 HP takes damage** → drops further; regen will pull back up to 50 cap (only)
- **Helicopter hit by AK from 80 m** → 18 × 0.5 = 9 dmg per round (falloff applies); 500 HP / 9 = 55 rounds to kill heli with AK only at long range. Practically, RPG is the answer.
- **Tank rams a player** (collision damage) → not implemented at MVP; collision deals no damage. Documented as known limitation.
- **Damage from outside the map** (out-of-bounds zone) → handled by Map System, not this system. This system applies the damage value passed to it.

## Dependencies

**Upstream (hard):**
- **Hit Registration** — provides hit events that trigger damage pipeline
- **Weapon System** — defines weapon damage values, falloff curves, splash properties

**Upstream (soft):**
- **Vehicle System** — provides vehicle entity HP definitions
- **Match State Machine** — clears all damage timers on match start

**Downstream (hard):**
- **Player Controller** (reads is_alive)
- **Camera System** (reads is_alive)
- **Respawn System** (consumes death events)
- **Match Scoring** (consumes kill events)
- **HUD** (displays HP, damage indicators, kill feed)
- **Networking** (replicates HP via Synchronizer)

**Downstream (soft):**
- **Audio System** (hit sounds, death sounds)
- **VFX System** (blood, explosions)

## Tuning Knobs

| Knob | Range | Default | Effect |
|---|---|---|---|
| `player_max_hp` | 80 – 150 | 100 | Per-player HP pool |
| `regen_threshold` | 30 – 80 | 50 | Max HP regen can reach |
| `regen_delay_seconds` | 3 – 10 | 5 | Damage-free time before regen starts |
| `regen_rate_hp_per_sec` | 10 – 50 | 25 | Regen speed |
| `friendly_fire_enabled` | bool | false | Toggle FF (post-MVP) |
| `falloff_near_distance` | 20 – 50 m | 30 | Start of falloff curve |
| `falloff_far_distance` | 60 – 120 m | 80 | End of falloff curve |
| `falloff_min_multiplier` | 0.3 – 0.7 | 0.5 | Floor multiplier at long range |
| `headshot_multiplier` | 1.5 – 3.5 | 2.5 | Head damage |
| `stomach_multiplier` | 1.0 – 1.3 | 1.1 | Stomach damage |
| `torso_multiplier` | 1.0 – 1.0 | 1.0 | Torso baseline (locked) |
| `limb_multiplier` | 0.5 – 0.9 | 0.7 | Arm/leg damage |
| `tank_max_hp` | 500 – 1500 | 750 | Tank HP (3 RPG to kill at default RPG damage) |
| `helicopter_max_hp` | 300 – 1000 | 500 | Heli HP (2 RPG to kill) |
| `ak_damage_vs_vehicle` | 0 – 10 | 3 | Per-round AK damage to vehicles (allows infantry chip damage) |
| `rpg_direct_damage` | 150 – 400 | 250 | RPG direct hit damage (also vs vehicles) |
| `rpg_splash_damage` | 50 – 150 | 80 | RPG splash damage at impact center |
| `rpg_splash_radius` | 2 – 8 m | 4 | RPG splash radius |
| `tank_cannon_direct_damage` | 100 – 300 | 200 | Tank shell direct hit |
| `tank_cannon_splash_radius` | 3 – 10 m | 6 | Tank shell splash radius |
| `wreck_splash_damage` | 30 – 100 | 50 | Damage from vehicle destruction explosion |
| `wreck_splash_radius` | 3 – 8 m | 5 | Vehicle wreck splash radius |

## Visual/Audio Requirements

- **Hit feedback (audio):** different cue per hit zone — head (sharper "ding"), torso (thud), limb (softer thud); audio routed to Hit Feedback bus
- **Damage taken audio:** grunt/pain cue, scaled by damage amount; clipped to once per ~0.5s to avoid spam
- **Low HP audio:** subtle heartbeat + breath when HP < 30 (loops while below threshold)
- **Death audio:** death cue per side (one for victim, different for killer's "kill confirm" sound)
- **Regen audio:** soft healing cue when regen activates; subtle continuous tone while regening
- **Vehicle wreck:** large explosion VFX + smoke column persisting 5 s after wreck despawns

## UI Requirements

- **HP bar** in HUD: bottom-left, color-coded (green > 60, yellow 30-60, red < 30)
- **HP number** displayed alongside bar
- **Regen indicator**: small upward arrow on HP bar when regen active
- **Damage indicator**: directional arc on HUD showing where damage came from (fades over 2 s)
- **Hit marker**: small reticle flash on screen when player lands a hit (different shape for headshot)
- **Kill confirm**: brief "ELIMINATED [name]" text on kill (top-center, 1.5 s)
- **Low-HP screen overlay**: red vignette intensifies as HP drops below 30 (post-MVP polish, optional at MVP)

## Acceptance Criteria

- [ ] AK center-mass kill in 5 rounds at point blank (100 ÷ 22 = ~5 — verified with bot)
- [ ] AK headshot 2-shot kill at point blank (verified)
- [ ] AK damage falls to 50% at 80m (verified with measurement)
- [ ] RPG direct hit instakills a player (verified)
- [ ] RPG splash damages but does not always kill at 4m radius
- [ ] Tank dies in exactly 3 RPG direct hits (750 / 250 = 3)
- [ ] Helicopter dies in exactly 2 RPG direct hits (500 / 250 = 2)
- [ ] AK can finish a damaged tank but takes a full mag for ~12% (3 × 30 = 90 dmg)
- [ ] Friendly fire is fully blocked — teammate damage = 0
- [ ] Regen kicks in 5s after last damage and stops at exactly 50 HP
- [ ] Regen halts immediately on new damage
- [ ] Death event fires exactly once per kill (no double-fire under heavy load)
- [ ] HP is server-authoritative — clients cannot fake HP value
- [ ] All damage events fit within server tick budget (<1 ms total per tick at peak combat)
- [ ] Vehicle ejection on destroy correctly damages occupants for 50 splash

## Open Questions

- **Helmet/armor system**: post-MVP. Could add a chest plate that absorbs first ~50 damage. Not at MVP.
- **Med kits / consumables**: not at MVP. Regen-to-50 covers in-fight survival; full health requires respawn.
- **Healing classes (medic)**: not at MVP. Solo-skill focus.
- **Vehicle weak points**: post-MVP. Helicopter tail rotor as 2× damage zone could create skill expression.
- **Damage numbers floating** (visible "27" pop above target on hit): not at MVP — minimalist HUD philosophy. Add post-MVP if playtest demands.
- **Falloff curve shape**: linear from 30→80m. Should it be non-linear (e.g., quadratic)? Linear is simpler and tunable; revisit if balance feedback requires.
- **Vehicle collision damage**: not implemented at MVP. Tanks running over players → no damage. Documented limitation.
- **Drone damage values** (post-MVP): TBD when drone system is designed.
