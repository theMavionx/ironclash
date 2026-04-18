# Main Menu

> **Status**: Skeleton (0/8 sections filled)
> **Author**: TBD
> **Last Updated**: 2026-04-17
> **Implements Pillar**: Pillar 3 — *Matches Start Fast* (minimize clicks to play)
> **MVP Scope**: Name input field + big "Play" button. No settings, no loadout, no lobby. Post-match returns here.

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
| Landing | Page load | Name entered + Play clicked | Show name input + Play button |
| Connecting | Play clicked | Server response | Show spinner |
| In-match | Server confirms | Match ends / disconnect | Menu hidden |
| Post-match | Match ended RPC | User clicks "Play again" | Show score + Play again button |

### Interactions with Other Systems

<!-- TODO -->

## Formulas

N/A

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Empty name | <!-- TODO --> | |
| Name collision on server | <!-- TODO --> | |
| Server down | <!-- TODO --> | |

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
| Game logo | Top-center | Static | Always |
| Name input | Center | On keystroke | Pre-match |
| Play button | Center below name | Static | Pre-match |
| Server status | Bottom | 5s poll | Always |

## Acceptance Criteria

- [ ] <!-- TODO -->

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| Store name in localStorage for return visits? | <!-- TODO --> | <!-- TODO --> | |
