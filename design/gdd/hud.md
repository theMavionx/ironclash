# HUD

> **Status**: Skeleton (0/8 sections filled)
> **Author**: TBD
> **Last Updated**: 2026-04-17
> **Implements Pillar**: Pillar 1 — *Skill Is The Ceiling* (clear info lets skill decide outcomes)
> **MVP Scope**: Health bar, ammo counter, capture-point progress, match timer, kill feed. No minimap, no damage numbers beyond hit feedback.

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
| Alive | Player HP > 0 | Player dies | Show full HUD |
| Dead | HP = 0 | Respawn | Show respawn timer + kill cam stub |
| Match End | Match state = end | Return to menu | Show final score |

### Interactions with Other Systems

<!-- TODO -->

## Formulas

<!-- TODO: layout anchors, scaling for resolution -->

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
| Health | Bottom-left | On change | Always while alive |
| Ammo | Bottom-right | On fire/reload | Always while alive |
| Capture progress | Top-center | 30 Hz | When near point OR contested |
| Match timer | Top-center | 1 Hz | Always |
| Kill feed | Top-right | On kill event | 5s display per entry |
| Crosshair | Center | 60 Hz | Always while alive |

## Acceptance Criteria

- [ ] <!-- TODO -->

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| <!-- TODO --> | | | |
