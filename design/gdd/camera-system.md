# Camera System

> **Status**: Designed
> **Author**: Claude Code Game Studios session
> **Last Updated**: 2026-04-14
> **Implements Pillar**: Skill Is The Ceiling — clear, predictable third-person camera is prerequisite for skill expression (aim, spatial awareness, vehicle piloting)

## Overview

The Camera System owns every virtual camera in Ironclash: the third-person
over-shoulder infantry camera (primary view), the first-person tank cockpit
camera, the third-person helicopter chase camera, and the spectator camera
after death. It responds to Player Controller state (crouch, ADS, sprint)
and weapon system state, applies field-of-view changes, view bobbing, and
screen shake, and provides the final render view to the client. The camera
is entirely **client-side** — it is not replicated across the network.

## Player Fantasy

The third-person camera is core to Ironclash's identity. The player sees
their character on screen — geared up, military, cool — and watches that
character move, shoot, and clutch. The camera disappears when it works
right: bobbing is subtle enough to feel immersive without nausea; ADS pulls
the camera tighter to the shoulder so the player can read recoil and
placement; helicopter chase keeps the vehicle centered without losing
spatial awareness. Aiming is **free-aim** — a reticle on screen, the player
shoots where they look, no Gears-style cover snap.

## Detailed Design

### Core Rules

1. The Camera System runs **client-only**. Camera state is not replicated.
2. Each player has **one active camera** at a time. Camera mode switches with game state:
   - Alive + on foot → Third-Person Over-Shoulder Infantry
   - Alive + in tank → First-Person Tank Cockpit
   - Alive + piloting helicopter → Third-Person Helicopter Chase
   - Dead (spectating killer) → Third-Person Orbit
   - In main menu / post-match → Fixed Menu Camera
3. Aiming is always **free-aim** — a screen-center reticle. The weapon points where the camera looks. No cover-snap, no auto-aim.
4. FOV is a user-configurable preference persisted to local storage.
5. Camera reads Player Controller transform once per render frame at 60 Hz.
6. Screen shake is additive and decays over time; multiple shake sources stack but are capped.

### Camera Modes

| Mode | Type | Anchor | Input-driven rotation | Key behaviors |
|---|---|---|---|---|
| **Third-Person Infantry (default)** | TPS over-shoulder | Player root + shoulder offset | Mouse | Shoulder offset (right by default), ADS tightens shoulder + slight zoom, view bob, free-aim reticle |
| **First-Person Tank Cockpit** | FP | Tank cockpit interior | Mouse (turret aim) | Fixed FOV 85°, no bob, heavy shake on cannon fire |
| **Third-Person Helicopter Chase** | TPS chase | 8 m behind + 3 m above heli | Mouse (pitch/yaw around heli) | Configurable orbit distance; collision-aware (zooms in if obstacle) |
| **Third-Person Orbit (spectator)** | TPS orbit | Around killer (or last teammate alive) | Mouse orbit | No weapon overlay; HUD shows "Eliminated by [name]" |
| **Fixed Menu Camera** | TPS or FP | Scene-specific | None (cinematic) | Used in main menu and post-match screens |

### Third-Person Infantry — Camera Anchor & Offset

The camera sits **behind and slightly above** the character, offset to the **right shoulder** by default.

| Parameter | Default | ADS value |
|---|---|---|
| Distance behind player | 2.5 m | 1.5 m |
| Height above player root | 1.6 m | 1.7 m |
| Lateral shoulder offset (right) | +0.5 m | +0.35 m |
| FOV | user setting (default 90°) | base × 0.85 (e.g., 76.5°) |

**ADS transition** lerps all four parameters over 0.18 s. Mouse sensitivity is unchanged in ADS (gameplay snappy preserved).

**Camera collision:** raycast from player root to camera target position. If blocked, camera moves to hit point + 0.2 m offset. Prevents camera clipping into walls.

**Shoulder swap (post-MVP):** dedicated key swaps shoulder left/right for cornering. Cut from MVP — right shoulder only.

### FOV Behavior

- **Base FOV:** user-configurable, range 70° – 110°, default 90°
- **ADS FOV:** base_FOV × 0.85 (e.g., 90° → 76.5°). FOV change PLUS camera tightens to shoulder = readable aim feel.
- **Tank FOV:** fixed 85° (cockpit, not configurable)
- **Helicopter FOV:** base_FOV (uses user preference)
- **FOV transitions** (entering/exiting ADS, vehicle swaps): lerped over 0.18 s

### View Bobbing (subtle, third-person infantry only)

In third-person, the bob is applied to the **camera rig**, not the character — character animations handle character-level motion. Camera bob is a small additional offset for game-feel:

- Bob amplitude scales with movement speed: 0 at Idle, low at Walk, higher at Sprint
- Bob is **suppressed during ADS** (aim must remain stable)
- Bob is **suppressed in vehicles**
- Specific values in Formulas

### Free-Aim Reticle

- Reticle is **always at screen center**
- Weapon barrel orientation is computed each tick to point at the world position the camera looks at, raycast from camera through center to first hit (or 100 m point)
- This produces a small **visual offset** — the weapon points slightly differently from the camera direction at close range — by design (PUBG-style)
- **Hit detection** uses a raycast from camera (not from weapon muzzle) — what you see is what you hit. Server validates against this rule.

### Screen Shake

Three shake sources contribute additive offset and micro-rotation to the camera:

| Source | Intensity | Duration | Trigger |
|---|---|---|---|
| Weapon fire (own) | Small (1° peak) | 0.08 s | Every shot fired |
| Damage taken | Medium (2° peak) | 0.15 s | On HP loss event |
| Nearby explosion | Large (4° peak), scales with distance | 0.3 s | RPG/tank shell within 20 m |

Shake is clamped to prevent stacking beyond 5° total rotation offset. Shake is reduced to 50% strength while ADS active.

### Interactions with Other Systems

- **Player Controller** (upstream): provides root position, movement velocity, crouch state, ADS state
- **Vehicle Controllers** (upstream): provide cockpit anchor (tank) or orbit target (helicopter)
- **Input System** (upstream): provides mouse delta for rotation; forwards mouse sensitivity
- **Weapon System** (upstream): triggers weapon-fire screen shake; sets ADS state; reads camera ray for hit direction
- **Health/Damage System** (upstream): triggers damage screen shake
- **Match State Machine** (upstream): switches to spectator camera on death; switches to menu camera post-match
- **HUD** (downstream): reads FOV, camera transform for reticle and UI positioning
- **Hit Registration** (downstream): reads camera ray for shot direction; server uses this as authoritative aim source

## Formulas

### Camera anchor position (third-person infantry)

```
shoulder_local = Vector3(0.5, 1.6, -2.5)   // right, up, back  (default)
shoulder_local_ads = Vector3(0.35, 1.7, -1.5)  // ADS tighter

target_local = lerp(shoulder_local, shoulder_local_ads, ads_progress)
target_world = player_basis * target_local + player_position

// Collision check: raycast from player root + 1.6m to target_world
hit = raycast(player_root + Vector3(0, 1.6, 0), target_world)
if hit:
    camera_position = hit.position - hit.normal * 0.2  // small backstep
else:
    camera_position = target_world

camera.look_at(player_position + Vector3(0, 1.6, 0) + look_direction * 100)
```

`ads_progress` lerps 0→1 over 0.18 s on RMB press, 1→0 on release.

### View bob (third-person camera offset)

```
speed_factor = clamp(current_speed / sprint_speed, 0, 1)
bob_amplitude_y = 0.012 * speed_factor   // smaller than FPS — TPS bob is subtle
bob_amplitude_x = 0.006 * speed_factor
bob_frequency = 5.5 + 3.5 * speed_factor

offset_y = sin(time * bob_frequency * 2π) * bob_amplitude_y
offset_x = sin(time * bob_frequency * π)  * bob_amplitude_x

if ads_active or in_vehicle:
    offset_y = 0
    offset_x = 0
```

### FOV transition (lerp)

```
current_fov = lerp(current_fov, target_fov, fov_lerp_speed * delta_time)
```
- `fov_lerp_speed`: 11.0 → transition completes in ~0.18 s

### Aim raycast (free-aim)

```
ray_origin = camera.global_position
ray_direction = -camera.global_basis.z   // forward
ray_end = ray_origin + ray_direction * 100.0

hit = physics_raycast(ray_origin, ray_end, hit_mask)
target_world_point = hit.position if hit else ray_end

// Weapon barrel orients toward this point (cosmetic + gameplay)
weapon.look_at(target_world_point)
```

### Screen shake (additive, decaying)

Each active shake source contributes an offset computed with decaying noise:
```
elapsed = now - shake_start_time
progress = clamp(elapsed / shake_duration, 0, 1)
envelope = (1 - progress)^2

intensity = base_intensity * (0.5 if ads_active else 1.0)

pitch_offset += noise(time * 30) * intensity * envelope
yaw_offset   += noise(time * 30, 100) * intensity * envelope
```
Total offsets across sources are clamped to ±5°.

### Third-person chase camera (helicopter)

```
target_position = heli_position + heli_back_vector * orbit_distance + Vector3.UP * orbit_height
hit = raycast(heli_position, target_position)
adjusted_target = (hit.position + hit.normal * 0.3) if hit else target_position
actual_position = lerp(actual_position, adjusted_target, chase_smooth * delta_time)
camera.look_at(heli_position + Vector3.UP * 1.0)
```
- `orbit_distance`: 8 m default
- `orbit_height`: 3 m default
- `chase_smooth`: 6.0

## Edge Cases

- **Rapid ADS toggle** → ADS lerp continues from current value; no abusable snap-zoom peek
- **FOV change in Settings mid-match** → applies immediately with 0.18 s lerp
- **Camera inside geometry** (TPS chase clips into wall) → raycast adjusts camera to just in front of obstacle
- **Player rotates rapidly while camera collision is active** → camera slides along walls; never renders inside geometry
- **Player dies while in vehicle** → camera switches to spectator-orbit mode
- **Spectator target dies/disconnects** → switches to next living teammate; if all dead, free camera or match-end
- **FOV > 110 via config hack** → clamped client-side at read
- **Multiple explosions simultaneously** → shake intensity sums, clamped to 5° max offset
- **View bob during transition** (walk → sprint) → amplitude/frequency interpolate via `speed_factor`
- **Killcam target out of view** → camera teleports to target with 0.2 s black fade
- **Aim raycast hits friendly player** → still considered the aim point; weapon damage rules (friendly fire) handled by Weapon System, not camera
- **Player extremely close to wall, ADS pressed** → camera collision clamps tighter; aim raycast may originate from inside the player collider — solved by skipping player's own collider in raycast mask
- **Weapon clipping through wall in TPS** → since hit detection uses camera raycast (not weapon-muzzle raycast), the visual clipping doesn't break gameplay; cosmetic only

## Dependencies

**Upstream (hard):**
- **Player Controller** — provides root transform, movement state, ADS
- **Input System** — provides mouse delta and sensitivity
- **Match State** — triggers spectator / menu camera transitions

**Upstream (soft):**
- **Vehicle Controllers** (Tank, Helicopter) — provide anchor transforms when active
- **Weapon System** — fires screen shake events
- **Health/Damage** — fires damage screen shake

**Downstream:**
- **HUD** — reads current FOV and camera state for reticle positioning
- **Hit Registration** — reads camera ray as authoritative aim direction
- **Weapon System** — reads camera target world point to orient weapon barrel
- **VFX System** — reads camera frustum for culling decisions

## Tuning Knobs

| Knob | Range | Default | Effect |
|---|---|---|---|
| `base_fov_default` | 70 – 110° | 90° | Default FOV |
| `ads_fov_multiplier` | 0.5 – 1.0 | 0.85 | ADS zoom factor |
| `fov_lerp_speed` | 8 – 20 | 11 | FOV transition rate |
| `shoulder_offset_default_x` | 0.3 – 0.7 m | 0.5 | Right-shoulder lateral offset |
| `shoulder_offset_default_y` | 1.4 – 1.8 m | 1.6 | Camera height above root |
| `shoulder_offset_default_z` | -1.5 to -3.5 m | -2.5 | Distance behind player |
| `shoulder_offset_ads_x` | 0.2 – 0.5 m | 0.35 | ADS shoulder lateral |
| `shoulder_offset_ads_y` | 1.5 – 1.9 m | 1.7 | ADS height |
| `shoulder_offset_ads_z` | -1.0 to -2.5 m | -1.5 | ADS distance |
| `ads_lerp_speed` | 5 – 20 | 11 | ADS in/out transition |
| `bob_amp_y` | 0 – 0.025 m | 0.012 | TPS vertical bob max |
| `bob_amp_x` | 0 – 0.015 m | 0.006 | TPS horizontal bob max |
| `bob_freq_walk` | 4 – 8 Hz | 5.5 | Bob frequency at Walk |
| `bob_freq_sprint` | 8 – 12 Hz | 9 | Bob frequency at Sprint |
| `shake_intensity_fire` | 0 – 3° | 1° | Own-weapon fire shake |
| `shake_intensity_damage` | 0 – 5° | 2° | Taking damage shake |
| `shake_intensity_explosion` | 0 – 8° | 4° | Nearby explosion shake |
| `shake_max_clamp` | 3 – 8° | 5° | Total shake offset cap |
| `shake_ads_multiplier` | 0.3 – 1.0 | 0.5 | Shake reduction while ADS |
| `heli_orbit_distance` | 5 – 12 m | 8 | Helicopter chase distance |
| `heli_orbit_height` | 1 – 5 m | 3 | Helicopter chase height |
| `heli_chase_smooth` | 3 – 12 | 6 | Chase follow softness |
| `tank_cockpit_fov` | 75 – 100° | 85° | Tank fixed FOV |
| `aim_raycast_distance` | 50 – 200 m | 100 | Free-aim ray length |

## Visual/Audio Requirements

- **Minimal post-processing** for browser performance: only base tonemapping (Godot default). No motion blur, no AO, no bloom, no vignette at MVP.
- **Character model** is fully visible from third person — must look polished from the back (where the player sees it most). Coordinate with art-director.
- **Weapon held by character** is animated by Animation system; visible to camera. No first-person weapon model needed.
- **ADS sight alignment**: weapon raises to character's eye line (animation), camera tightens to shoulder, FOV reduces. Combined effect = readable aim.
- **No dedicated audio for Camera System** — Camera provides listener transform.

## UI Requirements

- **FOV slider in Settings UI**: range 70 – 110, default 90, persists to local storage
- **FOV preview**: setting changes apply live so player can preview in menu
- **Reticle** at screen center, rendered by HUD system. Cross/dot reticle, no scope overlay at MVP.
- **No camera mode indicator** — camera changes are self-evident

## Acceptance Criteria

- [ ] FOV setting saves and restores correctly across browser sessions
- [ ] ADS transition (camera tightens + FOV reduces) completes smoothly in ~0.18 s
- [ ] Third-person infantry camera does not clip into geometry (collision-aware)
- [ ] Free-aim reticle accurately predicts hit point — what reticle covers = what raycast hits
- [ ] Helicopter chase camera does not clip into geometry
- [ ] Tank cockpit camera is fixed inside tank with turret rotation input
- [ ] Spectator camera orbits killer; switches target if killer dies
- [ ] Screen shake does not exceed 5° total under worst-case stacking
- [ ] Camera tick fits in <1 ms client-side per frame at 60 Hz
- [ ] No camera state appears in network replication payload
- [ ] Menu camera is stable (no bob/shake/transitions) during main menu and post-match
- [ ] Character model never clips into camera frustum (player doesn't see inside their own head/back)

## Open Questions

- **Killcam content**: live follow only at MVP; replay deferred post-MVP
- **Cinematic camera for capture events**: post-MVP polish
- **Motion sickness options**: zero bob / zero shake toggle deferred to post-MVP unless playtest urgency
- **Helicopter first-person cockpit view**: post-MVP option
- **Tank third-person view toggle**: post-MVP; MVP is cockpit-only
- **Shoulder swap (left/right)**: cut from MVP. Right shoulder only. Add post-MVP if cornering feels asymmetric.
- **Aim assist**: not at MVP. May add subtle cone-snap on console builds (which don't exist yet) — irrelevant for browser MVP.
