# Quick-Play Matchmaking

> **Status**: Skeleton (0/8 sections filled)
> **Author**: TBD
> **Last Updated**: 2026-04-17
> **Implements Pillar**: Pillar 3 — *Matches Start Fast* (click Play → in match)
> **MVP Scope**: Hardcoded server URL. Click "Play" → connect to active server → join first non-full match OR queue for next. No skill-based matching, no region selection.

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
| Idle | Menu open | Click "Play" | Show Play button |
| Connecting | Play clicked | Connection success/fail | Show spinner |
| Queued | Connected, match full | Slot opens | Wait for next match |
| In Match | Slot available | Match ends OR disconnect | Gameplay |

### Interactions with Other Systems

<!-- TODO -->

## Formulas

<!-- TODO: team auto-balance rule (smaller team gets joiner) -->

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Server unreachable | <!-- TODO --> | |
| Match ends while connecting | <!-- TODO --> | |
| Player name collision | <!-- TODO --> | |

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
| Do we pre-queue players or start match with <10? | <!-- TODO --> | <!-- TODO --> | |
