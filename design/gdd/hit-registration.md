# Hit Registration

> **Status**: Designed
> **Author**: Claude Code Game Studios session
> **Last Updated**: 2026-04-14
> **Implements Pillar**: Skill Is The Ceiling (precise hit detection rewards aim) + Every Tool Has A Counter (server-authoritative shots prevent cheating)

## Overview

Hit Registration is the system that determines, on the server, whether a fired
weapon hit a target — and what zone of the target was hit. It runs entirely
on the server (per ADR-0001 server-authoritative model). Clients send fire
events; the server raycasts (for hitscan weapons) or simulates projectile
flight (for explosive weapons) and produces hit results that are passed to
the Health & Damage System for damage application. **No lag compensation is
implemented at MVP** — shots are evaluated against the server's current
world state at the moment they arrive, not the world state the client saw
when shooting. This means high-latency players will experience apparent
shot misses when the target has moved between client frame and server tick.
This is a documented, accepted trade-off.

## Player Fantasy

When a shot lands, it lands clearly: hit marker, damage number (post-MVP),
satisfying audio. When it misses, it misses for a reason the player can
read — they didn't lead the target, they aimed at a limb instead of torso,
they didn't account for falloff. The exception is the high-ping player who
will sometimes feel cheated by the no-lag-comp design — this is the price
paid for an aggressive 15-day server-authoritative MVP.

## Detailed Design

### Core Rules

1. Hit Registration runs **only on the server** (per ADR-0001).
2. Clients send a `fire_weapon` RPC containing: timestamp, fire origin (camera position), fire direction (camera forward), weapon ID. Clients **do not** send hit claims — the server determines hits.
3. Server validates the fire event (rate limit, alive state, weapon owned, weapon ammo > 0). If valid, server processes the shot.
4. **Hitscan weapons** (AK, helicopter minigun): server performs a single raycast on the **server's current world state** at the moment the RPC is received. No lag compensation.
5. **Projectile weapons** (RPG, tank cannon): server spawns a server-side projectile entity at the fire origin moving in the fire direction at the weapon's projectile speed. The projectile is simulated each server tick (30 Hz). On collision, hit is registered.
6. **Hitbox model** is a 4-zone detailed compound collider per player: head, torso, stomach, limbs (arms + legs share the limb category).
7. The first valid hit per shot is what counts — for hitscan, the closest raycast intersection; for projectile, the first colliding entity.
8. Friendly fire is decided in **Health & Damage System**, not here. This system reports the hit; Health applies (or doesn't apply) the damage.

### Hitbox Zone Definitions (player)

| Zone | Collider | Approximate dimensions |
|---|---|---|
| **Head** | Sphere | Radius 0.13 m, centered at head bone |
| **Torso** | Capsule (vertical) | Height 0.45 m, radius 0.20 m, from neck to mid-spine |
| **Stomach** | Capsule (vertical) | Height 0.25 m, radius 0.18 m, from mid-spine to pelvis |
| **Limbs** | 4 capsules | Arms: ~0.55 m × 0.08 m; Legs: ~0.85 m × 0.10 m. All tagged "limb". |

Each collider has a metadata tag `hit_zone` that the raycast result reads to feed into Health & Damage.

Zones move with the character's animated skeleton (bone-attached). Crouch and ADS animations move the zones accordingly. Server uses the **server-side animated** pose for hitbox positions, not interpolated client poses.

### Vehicle Hitboxes (MVP)

- Tank: single uniform capsule wrapping the model. No zone differentiation. Damage anywhere = same damage.
- Helicopter: single uniform capsule. Same uniformity.
- Post-MVP: helicopter tail rotor weak point as a small "weak" tagged collider.

### Hit Detection — Hitscan Pipeline

```
on_server_receive(fire_weapon RPC from client):
    if not validate_fire_event(client, weapon, timestamp): return

    weapon_data = get_weapon_data(weapon_id)
    if weapon_data.type != HITSCAN: return

    ray_origin = fire_origin     // from client RPC (camera position)
    ray_direction = fire_direction.normalized()
    ray_end = ray_origin + ray_direction * weapon_data.max_range

    // Sanity check: is fire_origin within ~1m of the server-known player camera position?
    server_player_camera = get_server_camera_position(client.player_id)
    if distance(ray_origin, server_player_camera) > origin_tolerance:
        log_suspicious(client, "fire_origin too far from server camera")
        return  // reject shot

    // Sanity check: angular tolerance — direction should be within ~5° of last known aim
    server_aim = get_server_aim_direction(client.player_id)
    if angle_between(ray_direction, server_aim) > direction_tolerance_degrees:
        log_suspicious(client, "fire_direction too far from server aim")
        return

    // Execute raycast on server's current world state
    hit = physics_raycast(ray_origin, ray_end, hit_mask, exclude=[client.player_collider])

    if hit:
        target_entity = get_entity_from_collider(hit.collider)
        hit_zone = hit.collider.get_meta("hit_zone")  // "head" / "torso" / "stomach" / "limb" / "vehicle" / null
        distance_to_hit = ray_origin.distance_to(hit.position)

        // Pass to Health & Damage
        health_damage_system.apply_damage(
            source = client.player_id,
            target = target_entity,
            weapon = weapon_data,
            hit_zone = hit_zone,
            distance = distance_to_hit
        )

        // Broadcast hit event to clients (for VFX, audio, hit marker)
        broadcast_hit_event(target_entity.id, hit.position, hit.normal, hit_zone)
```

### Hit Detection — Projectile Pipeline

```
on_server_receive(fire_weapon RPC for projectile):
    if not validate_fire_event(client, weapon, timestamp): return

    weapon_data = get_weapon_data(weapon_id)
    if weapon_data.type != PROJECTILE: return

    // Same fire-origin + fire-direction sanity checks as hitscan

    // Spawn server-side projectile entity
    projectile = spawn_projectile(
        origin = fire_origin,
        direction = fire_direction,
        speed = weapon_data.projectile_speed,    // m/s
        gravity_factor = weapon_data.projectile_gravity,
        max_lifetime = weapon_data.projectile_lifetime,
        owner = client.player_id,
        weapon = weapon_data
    )

    // Projectile is replicated to clients via MultiplayerSpawner for visual
    // Server simulates collision each tick

each server tick (30 Hz):
    for projectile in active_projectiles:
        new_position = projectile.position + projectile.velocity * delta_time
        projectile.velocity.y -= projectile.gravity_factor * delta_time

        // Collision detection: swept ray from old position to new
        hit = physics_raycast(projectile.position, new_position, hit_mask, exclude=[projectile.owner_collider])

        if hit:
            // Hit registered
            handle_projectile_impact(projectile, hit)
            despawn(projectile)
        elif projectile.lifetime_elapsed > projectile.max_lifetime:
            despawn(projectile)
        else:
            projectile.position = new_position
```

### Validation Checks (Anti-Cheat at MVP)

The server runs these sanity checks on every fire event. Failed checks cause the shot to be **silently dropped** (no error to client to avoid leaking detection logic):

| Check | Purpose | Tolerance |
|---|---|---|
| **Player alive** | Cannot fire while dead | hard fail |
| **Weapon owned** | Cannot fire weapons not in loadout | hard fail |
| **Ammo > 0** | Cannot fire empty weapon | hard fail |
| **Not in vehicle (or in correct vehicle seat)** | Cannot fire infantry weapon while in vehicle | hard fail |
| **Fire rate limit** | Cannot fire faster than weapon's fire rate (with small tolerance) | within 80% of expected interval |
| **Fire origin proximity** | Client-claimed fire origin must be within 1.0 m of server's known camera position | 1.0 m |
| **Fire direction angle** | Client-claimed direction must be within 5° of server's last known aim | 5.0° |
| **Match state** | Cannot fire during pre-match or post-match | hard fail |

Repeated failures (>10 in 10 seconds) trigger a `log_suspicious` event for post-game review; player is **not** kicked at MVP (anti-cheat is post-MVP).

### Interactions with Other Systems

- **Networking** (peer): client → server via `fire_weapon` RPC; server → all clients via `broadcast_hit_event` RPC
- **Player Controller** (upstream): server reads alive/in-vehicle state for validation
- **Camera System** (upstream): server reads `last_known_aim` populated by client camera state replication
- **Weapon System** (upstream): provides weapon data (type, fire rate, range, projectile speed, etc.)
- **Health & Damage** (downstream): receives hit events with target/zone/distance for damage application
- **Hit Feedback / HUD** (downstream): receives `broadcast_hit_event` for hit markers and audio
- **VFX System** (downstream): renders impact effect at hit position
- **Audio System** (downstream): plays hit sound (varies by zone — head/body/limb)

## Formulas

### Origin tolerance check

```
origin_distance = fire_origin_client.distance_to(server_camera_position)
valid = origin_distance <= origin_tolerance   // 1.0 m
```

### Direction angle check

```
dot = fire_direction_client.normalized().dot(server_aim_direction.normalized())
angle_radians = acos(clamp(dot, -1.0, 1.0))
angle_degrees = angle_radians * 180.0 / π
valid = angle_degrees <= direction_tolerance_degrees   // 5.0
```

### Fire rate limit

```
expected_interval = 60.0 / weapon.rounds_per_minute   // seconds between shots
time_since_last_shot = now - player.last_shot_time
valid = time_since_last_shot >= expected_interval * 0.8   // allow 20% jitter
```

### Projectile travel (per server tick)

```
delta = 1.0 / 30.0   // 33.3 ms per server tick
projectile.velocity.y -= projectile.gravity_factor * delta
new_pos = projectile.position + projectile.velocity * delta
```

For RPG: `gravity_factor = 0` (straight-line flight at MVP — simpler), `speed = 60 m/s`
For tank cannon: `gravity_factor = 9.8 * 0.3`, `speed = 80 m/s` (slight arc)

(Projectile speeds tunable per Weapon System.)

## Edge Cases

- **Client sends fire_weapon while server thinks player is dead** → rejected (alive check)
- **Two fire events in same tick from same player** → second is rejected by fire-rate check
- **Hit on player who died this tick** → applied to dead player; Health & Damage handles "ignore damage to dead" gracefully (returns 0)
- **Projectile spawned, target moves out of the way mid-flight** → projectile continues, hits whatever it next collides with (wall, ground, another player)
- **Projectile lifetime exceeded with no hit** → despawn silently; no event
- **Client claims fire origin in invalid location** (e.g., far above their character) → rejected by origin tolerance check
- **Client rapidly aims wildly to bypass direction check** → server's `last_known_aim` updates each tick from camera replication; cheating with off-screen aim still detected
- **Player switches weapons mid-fire-event-flight** → server uses the weapon ID claimed in the RPC; if invalid (not owned), reject
- **Hitscan ray hits two zones in a stack** (e.g., crouching player behind cover, ray glances head and torso) → first collision wins (closest)
- **Projectile hits a friendly** → still registers as a hit, but Health & Damage filters friendly damage to 0
- **Hitscan ray with 0 length** (origin = end somehow) → rejected as invalid input
- **Projectile spawns inside another collider** (very close to wall) → spawn slightly offset along fire direction (~0.5 m) to prevent immediate self-collision
- **Two hitscan shots from different players hit same player same tick** → both apply damage independently in order received
- **Network packet loss drops fire_weapon RPC** → shot is lost; client showed muzzle flash but no hit. By design (RPC is `unreliable_ordered` for hitscan to avoid TCP head-of-line; reliable for projectile spawn).
- **Player rapidly turns 180° between fire and server tick** → direction tolerance check measured against most recent server-known aim; a sharp turn within one tick may produce a tolerance fail. Adjust tolerance up if false positives occur in playtest.

## Dependencies

**Upstream (hard):**
- **Networking** — RPC dispatch
- **Weapon System** — weapon data table
- **Player Controller** — alive state, vehicle state
- **Camera System** — replicated aim direction for direction validation

**Downstream (hard):**
- **Health & Damage** — receives all hit events
- **HUD / Hit Feedback** — receives broadcast_hit_event for hit markers

**Downstream (soft):**
- **VFX System**, **Audio System** — react to hit events

## Tuning Knobs

| Knob | Range | Default | Effect |
|---|---|---|---|
| `origin_tolerance` | 0.5 – 2.0 m | 1.0 | Allowed distance between client-claimed and server-known fire origin |
| `direction_tolerance_degrees` | 2.0 – 15.0° | 5.0 | Allowed angle deviation between client-claimed and server-known aim |
| `fire_rate_tolerance_factor` | 0.7 – 0.95 | 0.8 | How much faster than spec a player can fire (rate-limit jitter) |
| `hitbox_head_radius` | 0.10 – 0.16 m | 0.13 | Head sphere size — smaller = harder headshots |
| `hitbox_torso_height` | 0.40 – 0.55 m | 0.45 | Torso capsule size |
| `hitbox_torso_radius` | 0.18 – 0.24 m | 0.20 | Torso capsule width |
| `hitbox_stomach_height` | 0.20 – 0.30 m | 0.25 | Stomach capsule size |
| `hitbox_stomach_radius` | 0.15 – 0.20 m | 0.18 | Stomach capsule width |
| `hitbox_limb_radius` | 0.06 – 0.10 m | 0.08 | Limb capsule width |
| `projectile_spawn_offset` | 0.3 – 1.0 m | 0.5 | Forward offset to prevent self-collision on spawn |
| `suspicious_log_threshold` | 5 – 25 in 10 s | 10 | Failed validations before flagging player |

## Visual/Audio Requirements

- **Hit markers** at screen center on confirmed hit, different shape/color for headshot:
  - Body hit: cross/plus shape, white
  - Headshot: same shape but red and slightly larger
  - Hit marker is fired by the **broadcast_hit_event** received from server, not by client prediction
- **Impact VFX** spawned at hit position, varies by surface (concrete / metal / flesh / vehicle)
- **Hit audio** routed to Hit Feedback bus, varies by zone (head = sharp, torso = thud, limb = soft thud)
- **Projectile visual** for RPG and tank cannon: visible flying projectile (rocket trail / shell trail) replicated to all clients

## UI Requirements

- **Hit marker** in HUD (per Visual/Audio above)
- **Damage indicator** (directional arc on HUD edge showing where damage came from) — owned by Health & Damage System, but uses hit position from this system
- **Crosshair feedback**: minor "kick" animation on fire (cosmetic only)
- **No public ping/latency display** at MVP (post-MVP option to show in scoreboard)

## Acceptance Criteria

- [ ] Hitscan ray hits exact zone the camera reticle covers (with no movement)
- [ ] Headshot zone is small enough to require precise aim (radius 0.13 m)
- [ ] Projectile (RPG) travels at ~60 m/s and registers hit on first colliding entity
- [ ] Hit events arrive at all clients within one server tick of detection
- [ ] Server rejects shots with invalid origin (>1 m from camera) — tested with manipulated client
- [ ] Server rejects shots with invalid direction (>5° off aim) — tested with manipulated client
- [ ] Server rate-limits shots to weapon's fire rate (±20% tolerance)
- [ ] Damage is correctly applied per zone (head=2.5x, torso=1.0x, stomach=1.1x, limb=0.7x)
- [ ] No client can damage a target without server agreeing (verified by disabling server validation and observing rejections)
- [ ] Friendly fire correctly filtered to 0 by Health & Damage (this system passes the hit; Health filters)
- [ ] Server tick budget for hit registration: <2 ms total at peak combat (10 simultaneous fire events per second across match)
- [ ] No projectile leak — all projectiles despawn within `max_lifetime` even if no hit
- [ ] Debug visualization toggle works in dev builds; absent from release builds

## Open Questions

- **Lag compensation**: explicitly OUT for MVP. Adding it is the single highest-impact post-MVP polish item if "shots feel bad" tops playtest feedback.
- **Backstab / point-blank bonus**: not at MVP. Damage is uniform regardless of attack angle relative to target facing.
- **Ricochet / penetration**: not at MVP. Bullets stop on first hit. Walls fully block.
- **Vehicle weak points**: helicopter tail rotor as 2× zone — post-MVP.
- **Client-side hit prediction**: not at MVP. Client has zero hit prediction; hit feedback only after server confirms. Adds latency to hit feel.
- **Anti-cheat hardening**: post-MVP. MVP includes only the sanity checks above. Expect cheating; budget for anti-cheat work in post-launch.
- **Headshot sound to nearby players** (so a teammate hears your headshot): cosmetic feature, post-MVP.
