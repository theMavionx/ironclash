# Helicopter Controller

> **Status**: Skeleton (0/8 sections filled)
> **Author**: TBD
> **Last Updated**: 2026-04-18
> **Implements Pillar**: Pillar 2 — *Every Tool Has A Counter* (air dominance offset by RPG vulnerability)
> **MVP Implementation**: Deferred to Post-MVP patch 1. GDD written now for design completeness.
> **Risk**: HIGHEST technical risk per systems-index. 6DOF + network sync is the hardest vehicle problem.
> **Extends**: vehicle-base-system.md

## Overview

<!-- TODO -->

## Player Fantasy

<!-- TODO -->

## Detailed Design

### Core Rules

<!-- TODO -->

### States and Transitions

| State | Entry Condition | Exit Condition | Behavior |
|-------|----------------|----------------|----------|
| Landed | Touched ground | Throttle up | Rotor idle, stationary |
| Hovering | Throttle balanced | Movement input | Altitude hold |
| Flying | Pitch/roll input | Pitch/roll neutral | 6DOF movement |
| Damaged | HP < 30% | Repair OR destroyed | Smoke VFX, reduced thrust |
| Destroyed | HP = 0 | Respawn | Crash, explosion, ejects occupants |

### Interactions with Other Systems

<!-- TODO -->

## Formulas

<!-- TODO: thrust, drag, pitch/roll rates, altitude cap, rocket pod damage -->

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Pilot disconnects mid-flight | <!-- TODO --> | |
| Helicopter above map ceiling | <!-- TODO --> | |
| Network desync on rotation | <!-- TODO --> | High risk given 30 Hz tick |

## Dependencies

| System | Direction | Nature of Dependency |
|--------|-----------|---------------------|
| Vehicle base | Heli depends on Vehicle base | Inherits HP, enter/exit |
| Networking | Heli depends on Networking | Critical — 30 Hz sync may be insufficient |
| Weapon system | Heli uses Weapon-like weapons | Rocket pods, machine gun |

## Tuning Knobs

| Parameter | Current Value | Safe Range | Effect of Increase | Effect of Decrease |
|-----------|--------------|------------|-------------------|-------------------|
| <!-- TODO --> | | | | |

## Visual/Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|----------------|---------------|----------|
| Rotor spinup | Blade blur | Spool-up SFX | Must |
| In flight | Rotor wash on ground | Continuous rotor noise (3D attenuated) | Must |
| Damaged | Smoke trail | Rotor stutter SFX | Must |
| Crash | Explosion VFX | Crash boom SFX | Must |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| Altitude | HUD bottom-left | 30 Hz | While piloting |
| Speed | HUD bottom-left | 30 Hz | While piloting |
| Heli HP | HUD top | On change | While piloting |

## Acceptance Criteria

- [ ] <!-- TODO -->

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| Can helicopter network-sync at 30 Hz without jitter? | Network prog | Post-MVP prototype | Unresolved |
| Realistic flight model vs arcade? | Designer | Post-MVP | <!-- TODO --> |
