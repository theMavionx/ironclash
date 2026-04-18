# Post-Match Summary UI

> **Status**: Skeleton (0/8 sections filled)
> **Author**: TBD
> **Last Updated**: 2026-04-18
> **Implements Pillar**: Pillar 3 — *Matches Start Fast* ("Play Again" one click away)
> **MVP Implementation**: Deferred to Post-MVP patch 1. MVP ships with text-only end screen. Full post-match UI (MVP moments, accolades, stat breakdown) is post-MVP.
> **Scope**: Shown after match-ended RPC. MVP highlight / top player / team result / "Play Again" button.

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
| Hidden | Default | Match ended RPC | Not shown |
| Animating in | Match ended RPC | Anim complete | Slide/fade in |
| Displayed | Anim complete | Play Again OR Return to Menu | Full summary visible |
| Leaving | Button clicked | New state entered | Fade out |

### Interactions with Other Systems

<!-- TODO -->

## Formulas

<!-- TODO: MVP selection formula (highest score? capture-weighted? custom?) -->

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Player disconnected before summary | <!-- TODO --> | |
| Tie match | <!-- TODO --> | |
| Player had 0 stats (AFK) | <!-- TODO --> | |

## Dependencies

| System | Direction | Nature of Dependency |
|--------|-----------|---------------------|
| Match scoring | Post-match depends on Match scoring | Final scores |
| Match state machine | Post-match depends on Match state | Match-ended transition |
| Scoreboard | Post-match links to Scoreboard | Reuses per-player stat widget |
| Quick-play matchmaking | Post-match links to Quick-play | "Play Again" re-queues |

## Tuning Knobs

| Parameter | Current Value | Safe Range | Effect of Increase | Effect of Decrease |
|-----------|--------------|------------|-------------------|-------------------|
| <!-- TODO — display duration before auto-requeue --> | | | | |

## Visual/Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|----------------|---------------|----------|
| Match end | Screen darkens, summary slides in | Victory/defeat musical sting | Must |
| MVP announced | MVP card highlighted | Trumpet-style sting | Should |
| "Play Again" hover | Button glow | Subtle hover SFX | Nice-to-have |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| Team result (Victory / Defeat) | Top banner | Static | Displayed |
| Final score | Top | Static | Displayed |
| MVP card (photo, stats) | Center | Static | Displayed |
| Per-player stat rows | Below MVP | Static | Displayed |
| "Play Again" button | Bottom-center | Static | Displayed |
| "Return to Menu" button | Bottom-right | Static | Displayed |

## Acceptance Criteria

- [ ] <!-- TODO -->

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| What accolades? ("Headshot King", "Capture Hero", etc.) | Designer | Post-MVP | <!-- TODO --> |
| Auto-requeue after N seconds? | Designer | Post-MVP | <!-- TODO --> |
