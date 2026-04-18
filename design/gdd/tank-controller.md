# Tank Controller

> **Status**: Skeleton (0/8 sections filled)
> **Author**: TBD
> **Last Updated**: 2026-04-18
> **Implements Pillar**: Pillar 2 — *Every Tool Has A Counter* (tank dominates open ground; RPG flank counters it)
> **MVP Implementation**: Deferred to Post-MVP patch 1. GDD written now for design completeness.
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
| <!-- TODO --> | | | |

### Interactions with Other Systems

<!-- TODO -->

## Formulas

<!-- TODO: movement speed, turret rotation, cannon damage, reload, HP -->

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| <!-- TODO --> | | |

## Dependencies

| System | Direction | Nature of Dependency |
|--------|-----------|---------------------|
| Vehicle base | Tank depends on Vehicle base | Inherits enter/exit, HP, net sync |
| Player controller | Tank depends on Player controller | Driver origin |
| Weapon system | Tank uses Weapon-like cannon | Fire, damage, reload |

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
| <!-- TODO --> | | | |

## Acceptance Criteria

- [ ] <!-- TODO -->

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| <!-- TODO --> | | | |
