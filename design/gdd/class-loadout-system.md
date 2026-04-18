# Class Loadout System

> **Status**: Skeleton (0/8 sections filled)
> **Author**: TBD
> **Last Updated**: 2026-04-18
> **Implements Pillar**: Pillar 2 — *Every Tool Has A Counter* (class choice is strategic — AK for infantry, RPG for anti-vehicle)
> **MVP Implementation**: Deferred to Post-MVP patch 1. GDD written now for design completeness.
> **Scope**: 2 classes — Assault (AK), Heavy (RPG). No pistol, no sidearms. Class chosen pre-match and on respawn.

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
| Selecting | Pre-match OR respawn screen | Class confirmed | Show 2 class cards |
| Locked | Class confirmed | Death / respawn | Cannot change mid-life |
| Changing | Death triggers reselect | New class confirmed | Brief pre-spawn UI |

### Interactions with Other Systems

<!-- TODO -->

## Formulas

<!-- TODO: maybe class cooldown rules, RPG count balancing -->

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Everyone picks Heavy (5 RPGs) | <!-- TODO — cap? free-for-all? --> | |
| Player AFKs on class select | <!-- TODO --> | |

## Dependencies

| System | Direction | Nature of Dependency |
|--------|-----------|---------------------|
| Weapon system | Loadout depends on Weapon | Binds class to weapon instance |
| Player controller | Loadout → Player controller | Class sets stats/movement profile |
| HUD | HUD depends on Loadout | Shows class-specific UI (RPG reload timer different) |
| Main menu / respawn UI | UI depends on Loadout | Selection UI |

## Tuning Knobs

| Parameter | Current Value | Safe Range | Effect of Increase | Effect of Decrease |
|-----------|--------------|------------|-------------------|-------------------|
| <!-- TODO --> | | | | |

## Visual/Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|----------------|---------------|----------|
| Class selected | Class card highlight | Confirm SFX | Must |
| Spawn with class | Weapon model change | Class-specific ambient (e.g., RPG strap) | Should |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| Class cards (2) | Center | On death | Respawn screen |
| Class counts (per team) | Class cards | Real-time | If team cap enabled |

## Acceptance Criteria

- [ ] <!-- TODO -->

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| Cap on Heavy per team (e.g., max 2 RPGs)? | Designer | Post-MVP | <!-- TODO --> |
| Can class be changed mid-life at a resupply point? | Designer | Post-MVP | <!-- TODO --> |
