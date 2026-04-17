# Input System

> **Status**: Designed (thin spec — infrastructure layer)
> **Author**: Claude Code Game Studios session
> **Last Updated**: 2026-04-14
> **Implements Pillar**: Skill Is The Ceiling (precise, responsive input is a prerequisite for skill expression)

## Overview

The Input System captures player keyboard and mouse input, applies configured
sensitivity, and dispatches discrete events (fire, reload, jump, etc.) to the
Player Controller and other consumers. It is a thin abstraction layer between
Godot's `InputMap` and game systems. At MVP, only keyboard and mouse are
supported; gamepad and remapping are post-MVP.

## Player Fantasy

Invisible. The best input system is one the player never thinks about —
inputs feel instantaneous and correct, 100% of the time. This system succeeds
by being unnoticed.

## Detailed Design

### Core Rules

- Input is polled every client frame (60 Hz target)
- Movement input is converted to a 2D vector (WASD → `Vector2`) and sent to the server every 30 Hz
- Mouse delta drives aim rotation (accumulated client-side; sent at 30 Hz)
- Action inputs (fire, reload, jump, interact) are edge-triggered and sent immediately on press/release

### Default Bindings (MVP)

| Action | Binding |
|---|---|
| Move | W / A / S / D |
| Jump | Space |
| Crouch | Ctrl (hold) / C (toggle — post-MVP) |
| Sprint | Left Shift (hold) |
| Fire | Left Mouse |
| Aim Down Sights | Right Mouse |
| Reload | R |
| Interact / Enter vehicle | E |
| Weapon 1 / 2 | 1 / 2 |
| Scoreboard | Tab (hold) |
| Menu / Pause | Esc |

### States and Transitions

Input system is stateless. It has two modes:
- **Gameplay mode** — inputs dispatch to Player Controller
- **UI mode** — inputs dispatch to UI focus target, gameplay ignores

Transition: entering/exiting a menu calls `Input.set_mouse_mode()` and swaps dispatch target.

### Interactions with Other Systems

- **Player Controller** (consumer): receives movement vector, aim rotation, jump, crouch, sprint
- **Weapon System** (consumer): receives fire, reload, weapon-switch actions
- **Vehicle Controllers** (consumer): receives movement/rotation inputs when in vehicle
- **UI / Menus** (consumer): receives click/navigation inputs when in UI mode
- **Settings UI** (configurator): writes sensitivity values to this system's config

## Formulas

**Aim rotation per frame:**
`aim_delta = mouse_delta * sensitivity * (base_sensitivity_factor)`

- `mouse_delta`: pixels moved this frame
- `sensitivity`: user-configured (range 0.1 – 5.0, default 1.0)
- `base_sensitivity_factor`: 0.003 radians/pixel (tuning constant)

Scoping multiplier (ADS): `aim_delta *= ads_sensitivity_multiplier` (default 0.7 when ADS active, tunable)

## Edge Cases

- **Window loses focus** → all held keys released, mouse capture dropped
- **Alt-Tab during fire** → fire released, no stuck-key exploit
- **Simultaneous opposing inputs** (A + D) → cancel to zero on that axis
- **Browser pointer-lock denied** → fall back to free mouse, show warning
- **Extreme sensitivity values** → clamped to [0.1, 5.0] before apply
- **Input during server-pause / match end** → ignored

## Dependencies

**Upstream (depends on):**
- None at the game-system level — uses Godot's built-in `Input` singleton

**Downstream (depended on by):**
- Player Controller (hard — cannot move without input)
- Weapon System (hard — cannot fire without input)
- Vehicle Controllers (hard)
- Settings UI (hard — configures this system)
- Main Menu, Scoreboard, other UI (hard)

Interface: Input System exposes signals/methods; consumers connect and read. No direct coupling to Godot's `Input` outside this system.

## Tuning Knobs

| Knob | Range | Default | Effect |
|---|---|---|---|
| `mouse_sensitivity` | 0.1 – 5.0 | 1.0 | Overall aim speed |
| `ads_sensitivity_multiplier` | 0.1 – 1.0 | 0.7 | Sensitivity while aiming |
| `invert_y` | bool | false | Invert vertical mouse axis |
| `input_send_rate` | 10 – 60 Hz | 30 Hz | How often input state is sent to server |
| `base_sensitivity_factor` | constant | 0.003 rad/px | Internal tuning — do not expose to players |

## Acceptance Criteria

- [ ] All 11 MVP bindings respond within 1 frame of press
- [ ] Mouse sensitivity slider persists across sessions (LocalStorage in browser)
- [ ] No stuck keys after window focus loss or Alt-Tab
- [ ] Simultaneous opposing keys produce zero-net movement
- [ ] Inputs are suppressed during menus and during match end state
- [ ] Pointer-lock requested on gameplay start; fallback to free mouse if denied

## Open Questions

- Remap UI: post-MVP, but data layer should already support it (store bindings as a dictionary rather than hardcoded)
- Should browsers that deny pointer-lock be blocked from playing, or allowed with warning? (Current plan: allow with warning)
