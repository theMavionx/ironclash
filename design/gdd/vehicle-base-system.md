# Vehicle Base System

> **Status**: Skeleton (0/8 sections filled)
> **Author**: TBD
> **Last Updated**: 2026-04-18
> **Implements Pillar**: Pillar 2 — *Every Tool Has A Counter* (vehicles are strong tools with strong counters)
> **MVP Implementation**: Deferred to Post-MVP patch 1. GDD written now for design completeness; code not shipped by 2026-05-01.
> **Purpose**: Shared logic across all vehicles (tank, helicopter): enter/exit, HP, damage routing, network sync, passenger handling.

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
| Unoccupied | Match start OR driver exit | Interact prompt triggered | Idle, takes damage |
| Driver only | Driver enters | Driver exits OR destroyed | Controllable |
| Driver + passengers | Passenger enters | Any occupant exits OR destroyed | Controllable + passengers visible |
| Destroyed | HP = 0 | Respawn timer expires | Wreck, occupants ejected + damaged |

### Interactions with Other Systems

<!-- TODO -->

## Formulas

<!-- TODO: HP scale, damage routing, respawn timer -->

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
| <!-- TODO --> | | | |

## Acceptance Criteria

- [ ] <!-- TODO -->

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| <!-- TODO --> | | | |
