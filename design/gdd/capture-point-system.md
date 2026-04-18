# Capture Point System

> **Status**: Skeleton (0/8 sections filled)
> **Author**: TBD
> **Last Updated**: 2026-04-17
> **Implements Pillar**: Pillar 3 — *Matches Start Fast* (objectives drive clear goal)
> **MVP Scope**: 3 capture points on 1 map. Timed neutralize + capture, income while held.

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
| Neutral | Match start OR neutralized | Team stands on point alone | No income |
| Capturing | One team present, not owned by them | Timer complete OR contested | Timer fills |
| Owned | Capture timer complete | Enemy begins neutralizing | Income ticks |
| Contested | Both teams present | One team leaves | Timers pause |

### Interactions with Other Systems

<!-- TODO -->

## Formulas

<!-- TODO: capture time, income rate, contested behavior -->

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
