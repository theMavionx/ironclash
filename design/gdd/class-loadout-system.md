# Weapons & Loadout (Single-Class)

> **Status**: Filled (8/8 sections)
> **Author**: Dex Dexter
> **Last Updated**: 2026-04-21
> **Implements Pillar**: Pillar 2 — *Every Tool Has A Counter* (infantry threat via AK, anti-vehicle via RPG — both always on hand)
> **MVP Implementation**: In-progress (Sprint 1). Replaces the originally-planned Assault/Heavy class split.
> **Scope**: One universal soldier with a fixed 2-weapon loadout — AK (infantry) and RPG (anti-vehicle). Player switches between them at will. No class selection screen, no per-team caps, no sidearms.

---

## Overview

Every player spawns as the same soldier carrying both an AK and an RPG. Pressing `1` equips the AK, `2` equips the RPG. There is no class selection flow — no pre-match picker, no respawn picker, no team-composition balancing. The design collapses the original Assault / Heavy class split into a single universal loadout to reduce UI surface area, match-start friction, and balance burden for the 15-day MVP.

The AK is the default anti-infantry tool (auto-fire, 30-round magazine, manual reload). The RPG is the default anti-vehicle tool (single-shot, 1 round per mag, auto-reloads after each shot). Both weapons are always carried; switching costs only the `Select` animation duration (no ammo pickup, no weapon drop).

## Player Fantasy

*"I am a well-equipped soldier. The rifle handles most fights; the rocket launcher is my answer when a tank rounds the corner. I never have to choose between them — I just have to pick the right one for the moment."*

The player should feel **flexible and self-reliant**: every engagement — infantry firefight, vehicle ambush, contested capture — is winnable with the loadout they already have. The cost of flexibility is that neither weapon is specialist-grade: the AK is a generic rifle (no scope, no burst mode), the RPG reloads slowly and carries only one round. Mastery = weapon-switch muscle memory, not class-identity commitment.

## Detailed Rules

### Core Rules

1. **Fixed loadout.** Every player, every spawn, has: AK + RPG. No pickups, no drops, no scavenging.
2. **Weapon selection.** Keys `1` / `2` request a switch. Request is ignored if the controller is `busy` (mid-reload, mid-fire for RPG, mid-select).
3. **Weapon switch cost.** `AR_Select` / `RPG_Select` animation plays; input is locked for its duration. After the animation finishes, the newly-selected weapon is fireable.
4. **AK rules.**
   - Magazine: 30 rounds. Reserves: infinite.
   - Fire mode: full-auto while LMB is held.
   - Fire rate: gated by `ar_fire_interval_sec` (default 0.1 s ≈ 600 RPM).
   - Reload: **manual only** via `R` key. Reload while magazine is full is rejected.
   - Empty magazine: trigger yields nothing (dry-click). No auto-reload on empty (post-MVP).
5. **RPG rules.**
   - Magazine: 1 round. Reserves: infinite (single-round auto-reload after every shot).
   - Fire mode: single-shot per LMB press (press edge only; holding does not retrigger).
   - Reload: **automatic** — after firing, `RPG_Reload` plays immediately, during which fire/switch are locked. No manual `R` reload for the RPG.
6. **Input gating.** All weapon input is ignored when `Input.mouse_mode != CAPTURED` (i.e., the pause/menu state).
7. **Serialization.** A `busy` lock in `WeaponController` enforces: one `Select`, one `Reload`, or one RPG `Fire→Reload` chain at a time. AK fire does NOT set `busy` (auto-fire must keep flowing; per-shot cadence is gated by `ar_fire_interval_sec`, not by the animation).

### States and Transitions

The `WeaponController` exposes one combined state:

| State | Entry Condition | Exit Condition | Allowed Input |
|-------|----------------|----------------|---------------|
| **Idle** | Last action finished; no input pending | LMB press/hold, `R`, or `1`/`2` | Fire, reload, switch |
| **Firing (AK)** | LMB held AND mag > 0 AND cooldown elapsed | LMB released OR mag empty | Switch (`1`/`2`) interrupts → transitions to Switching. `R` transitions to Reloading. |
| **Firing (RPG)** | LMB press edge AND mag > 0 | `RPG_Burst` animation finishes → auto-chain to Reloading | None (locked) |
| **Reloading** | `R` pressed (AK) OR RPG auto-chain (post-fire) | Reload animation finishes → refill mag → Idle | None (locked) |
| **Switching** | `1` or `2` pressed while Idle/Firing | `AR_Select` / `RPG_Select` animation finishes → Idle | None (locked) |

Transition table:

| From | Trigger | To |
|------|---------|-----|
| Idle | LMB (AR held) | Firing (AK) |
| Idle | LMB (RPG press) | Firing (RPG) |
| Idle | `R` (AR equipped, mag < 30) | Reloading |
| Idle | `1` or `2` (different weapon) | Switching |
| Firing (AK) | LMB released | Idle |
| Firing (AK) | Mag empty | Idle (player must press `R`) |
| Firing (AK) | `R` | Reloading |
| Firing (AK) | `1`/`2` | Switching |
| Firing (RPG) | `RPG_Burst` finished | Reloading (auto-chain) |
| Reloading | Anim finished | Idle |
| Switching | Anim finished | Idle |

### Interactions with Other Systems

| System | Relationship |
|--------|-------------|
| `PlayerAnimController` | Weapon controller drives `play_fire()`, `play_reload()`, `play_select()`. Anim controller owns the `AnimationPlayer` and emits `action_finished(action)` back to weapon controller. |
| `WeaponAnimVisibility` | Observes the current animation name (via `AnimationPlayer.current_animation`) and toggles bone-attached weapon parts (AK parts vs RPG parts vs reload frame swaps). Not coupled to weapon controller directly. |
| HUD (`AmmoDisplay`) | Listens to `WeaponController.ammo_changed(weapon, current, maximum)` and `weapon_switched(weapon)`. No write path from HUD → gameplay. |
| `PlayerController` | Reads movement input independently. The two controllers do not communicate — movement is unaffected by weapon state (no move-slowdown while reloading in MVP). |
| Projectile system (future) | Will consume a `fired(weapon, muzzle_transform)` signal from `WeaponController` to spawn actual projectiles. Currently animation-only. |

## Formulas

### AK fire cadence

```
shots_per_second = 1 / ar_fire_interval_sec
```

| Variable | Unit | Default | Range |
|----------|------|---------|-------|
| `ar_fire_interval_sec` | seconds | 0.1 | [0.05, 0.3] |

Example: at 0.1 s interval, LMB held for 3 seconds fires `min(30, floor(3 / 0.1)) = 30` rounds before the mag is empty and input yields nothing until `R` is pressed.

### RPG fire-to-reload turnaround

```
total_turnaround = rpg_burst_duration + rpg_reload_duration
```

Where `rpg_burst_duration` and `rpg_reload_duration` are the authored animation lengths from the GLB (frame counts at 30 FPS — see `weapon_anim_visibility.gd` § FPS). `total_turnaround` is the effective cooldown between consecutive RPG shots. QA must verify this stays under 5 s; longer ruins the fantasy of "I have an RPG for this moment".

### Mag refill (both weapons)

```
on reload animation finished:
    if weapon == AR:  ar_ammo = ar_mag_size      # 30
    if weapon == RPG: rpg_ammo = rpg_mag_size    # 1
```

No partial reload — topping up a half-empty AK magazine still refills to 30. Intentional simplification for MVP.

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Player presses `1` while already holding AK | No-op (input ignored; no select anim) | `_current_weapon == w` short-circuit in `_switch_weapon()`. |
| Player presses `1` during AR_Reload | Ignored (busy lock active) | Reload completes first; player must press `1` again if they still want to switch. |
| Player holds LMB + presses `2` mid-burst | Firing stops; select anim plays; player now holds RPG with the still-held LMB — RPG does NOT fire on LMB held, only on press edge, so holding LMB post-switch is harmless. On LMB release + re-press, RPG fires. | Prevents accidental rocket-spam when switching. |
| Player presses `R` on full AK magazine | Ignored (`_ar_ammo >= ar_mag_size` early-return) | Avoids wasted animation and ammo counter flash. |
| Player presses `R` while holding RPG | Ignored (weapon != AR early-return) | RPG auto-reloads; manual R is meaningless. |
| Mouse becomes un-captured (ESC pause) mid-fire | All input dropped next frame (`mouse_mode != CAPTURED` gate). In-progress reload/select animations continue; AK auto-fire stops. | Prevents firing into UI when the cursor is visible. |
| Player fires RPG with 0 ammo | Ignored (`_rpg_ammo <= 0` early-return). This only occurs if the auto-reload chain is interrupted somehow. | Defense against desynced state. |
| Player dies mid-action | `PlayerController.set_active(false)` disables processing; weapon controller's state is frozen. On respawn, weapons are force-reset to full mags (not yet implemented — see Acceptance Criteria). | Post-MVP: explicit `respawn_reset()` method on `WeaponController`. |
| Animation finishes but weapon was switched mid-play | `_on_anim_finished` checks the name matches the expected animation for the current weapon/action; stale signals are dropped. | Prevents double-reload or skipped busy-unlock. |

## Dependencies

| System | Direction | Nature of Dependency |
|--------|-----------|---------------------|
| `PlayerAnimController` | WeaponController → AnimController | Calls `set_weapon/play_fire/play_reload/play_select`; listens for `action_finished`. |
| `WeaponAnimVisibility` | WeaponAnimVisibility → AnimationPlayer | Reads current animation name & frame position (no coupling to WeaponController). |
| `AmmoDisplay` (HUD) | UI → WeaponController | Listens to `ammo_changed` and `weapon_switched`. No write path. |
| `PlayerController` | None (movement is independent) | No coupling — weapon state does not affect movement speed in MVP. |
| Respawn system | Respawn → WeaponController | **(TODO)** must call a reset method to restore mags and weapon to AK on death. |
| Projectile system (future) | Projectile ← WeaponController | **(TODO)** emit `fired(weapon, muzzle_transform)` to spawn projectiles server-side. |

### Bidirectional references to update in dependency docs

- `design/gdd/player-controller.md` — note that movement is **independent** of weapon state (no reload-slowdown).
- `design/gdd/hud.md` — must document `AmmoDisplay` widget and its signals.
- `design/gdd/weapon-system.md` — should reference this doc as the authoritative input/state-machine spec for AK and RPG.
- `design/gdd/projectile-system.md` — consumes `WeaponController.fired` signal (future).

## Tuning Knobs

Exposed on `WeaponController` as `@export` properties. See `src/gameplay/player/weapon_controller.gd`.

| Parameter | Current Value | Safe Range | Effect of Increase | Effect of Decrease |
|-----------|---------------|------------|---------------------|---------------------|
| `ar_mag_size` | 30 | [10, 60] | More sustained AK fire before reload → fewer reload windows for opponents | More forced reloads → higher reload-punish incentive |
| `ar_fire_interval_sec` | 0.1 | [0.05, 0.3] | Slower RPM → AK less dominant vs skilled aimers | Faster RPM → AK overshadows RPG's niche |
| `rpg_mag_size` | 1 | [1, 3] | Multi-shot RPG trivializes vehicles → Pillar 2 broken | N/A (already at floor) |

### Tuning knobs on `PlayerAnimController` (animation side)

| Parameter | Current Value | Safe Range | Effect |
|-----------|---------------|------------|--------|
| `blend_time` | 0.2 s | [0.0, 0.4] | Longer = smoother transitions but laggier response to state change |
| `sprint_animation_speed` | 2.5 | [1.5, 3.5] | Higher = more frantic sprint anim (already clamped) |

## Visual / Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|-----------------|----------------|----------|
| AK single round fired | `AR_Burst` anim plays (muzzle flash — post-MVP via VFX system) | AK gunshot SFX | Must |
| AK reload (R pressed) | `AR_Reload` anim; magazine swap frames 12-48 (see `weapon_anim_visibility.gd`) | Magazine click/insert SFX | Must |
| AK mag empty (dry-click) | None in MVP | Dry-click SFX — post-MVP | Should |
| RPG fired | `RPG_Burst` anim; rocket exits barrel; rocketbullet hidden from frame 62 | Rocket launch whoosh | Must |
| RPG auto-reload | `RPG_Reload` anim; rocketbullet-in-hand frames 17-61 | Strap-unclip + rocket-load SFX | Must |
| Weapon switch (1 or 2) | `AR_Select` / `RPG_Select` anim; `WeaponAnimVisibility` toggles weapon parts on anim name change | Holster click + draw SFX | Must |
| Ammo counter update | `AmmoDisplay` label re-renders (bottom-right HUD) | None | Must |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|------------------|------------------|-----------|
| Current ammo (e.g. `AR 27 / 30`) | Bottom-right HUD (`AmmoDisplay`) | On every fire/reload/switch | Always (only current weapon shown) |
| Current weapon label | Same widget as ammo counter | On switch | Always |
| Reload in progress indicator | **(Post-MVP)** subtle bar/spinner during reload | Continuous while reloading | Should |
| Dry-click feedback | **(Post-MVP)** ammo counter flash red | On dry-click | Nice-to-have |

No class-selection UI. No pre-match picker. No respawn picker.

## Acceptance Criteria

- [ ] Spawning a player scene shows `AR 30 / 30` in the bottom-right HUD.
- [ ] Pressing `1` while holding AK → no-op (no animation, no log spam).
- [ ] Pressing `2` while holding AK → `AR_Select` NOT played, `RPG_Select` plays; HUD flips to `RPG 1 / 1`; input is locked until anim finishes.
- [ ] Pressing `1` back → `AR_Select` plays; HUD flips to `AR N / 30` (N = ammo before switch; state persists across switches).
- [ ] Holding LMB with AK equipped → AK_Burst replays every `ar_fire_interval_sec`; ammo decrements 1 per shot; stops at 0.
- [ ] Pressing `R` with AK at < 30 rounds → `AR_Reload` plays; ammo fills to 30 on anim finished; input locked during reload.
- [ ] Pressing `R` with AK at exactly 30 → no animation, no state change.
- [ ] Pressing LMB once with RPG equipped → `RPG_Burst` plays, ammo → 0, then `RPG_Reload` auto-chains and ammo → 1 on finish.
- [ ] Holding LMB with RPG equipped → only one shot per LMB press edge; releasing and re-pressing fires a second shot.
- [ ] During any reload/select, `1`/`2`/`R` are all ignored until `action_finished` fires.
- [ ] With mouse un-captured (ESC), neither LMB nor `R` nor `1`/`2` affect weapon state.
- [ ] HUD `ammo_changed` signal fires at every state-altering event; no stale values.

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| Should movement slow during reload? | Designer | Sprint 2 | **Open** — MVP: no slowdown. Decision after first internal playtest. |
| Auto-reload AK when mag hits 0? | Designer | Sprint 2 | **Open** — MVP: no. Forces intentional reload timing. |
| Should switching weapon interrupt a reload? | Designer | Sprint 2 | **Open** — MVP: no (busy lock blocks switch during reload). Revisit if playtesters find it frustrating. |
| Should the RPG share an ammo reserve with pickups in later sprints? | Designer | Post-MVP | **Deferred** — current scope has no pickups. |
| Muzzle-flash VFX source-of-truth (per-anim event or code-driven)? | Tech Artist | Sprint 2 | **Open** — leaning toward anim-event-driven (aligned with `WeaponAnimVisibility` pattern). |
