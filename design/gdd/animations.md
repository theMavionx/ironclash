# Animations

> **Status**: Skeleton (0/8 sections filled)
> **Author**: TBD
> **Last Updated**: 2026-04-17
> **Implements Pillar**: Pillar 2 — *Every Tool Has A Counter* (readable animations communicate player state)
> **MVP Scope**: Character anims from purchased pack (idle, run, sprint, aim, fire, reload, death). Weapon = no full reload anim, flash/swap only.

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
| Idle | No input | Move/aim/fire | Loop idle |
| Run | WASD held | WASD released OR sprint | Loop run cycle |
| Aim | RMB held | RMB released | Upper body aim pose |
| Fire | LMB pressed | Anim complete | Fire anim, recoil pose |
| Death | HP <= 0 | Respawn | Ragdoll or death anim |

### Interactions with Other Systems

<!-- TODO -->

## Formulas

<!-- TODO: blend weights, anim speed scaling to movement speed -->

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| <!-- TODO --> | | |

## Dependencies

| System | Direction | Nature of Dependency |
|--------|-----------|---------------------|
| <!-- TODO --> | | |

## Tuning Knobs

| Parameter | Current Value | Safe Range | Effect of Increase | Effect of Decrease |
|-----------|--------------|------------|-------------------|-------------------|
| <!-- TODO --> | | | | |

## Visual/Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|----------------|---------------|----------|
| <!-- TODO --> | | | |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| N/A | | | |

## Acceptance Criteria

- [ ] <!-- TODO -->

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| Is the purchased rig compatible? | Dev 2 | 2026-04-17 (S1-002) | <!-- TODO --> |
