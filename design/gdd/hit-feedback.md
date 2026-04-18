# Hit Feedback

> **Status**: Skeleton (0/8 sections filled)
> **Author**: TBD
> **Last Updated**: 2026-04-17
> **Implements Pillar**: Pillar 1 — *Skill Is The Ceiling* (player must KNOW their shot hit)
> **MVP Scope**: Hit marker on crosshair when damage confirmed by server. Damage number float. No hit sound pitch variation, no elite hit polish.

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
| No hit | Default | Hit confirm RPC | None |
| Hit confirmed | Server confirms damage | 150 ms elapsed | Show hit marker X |
| Kill confirmed | Server confirms lethal | 300 ms elapsed | Stronger marker + sound |

### Interactions with Other Systems

<!-- TODO -->

## Formulas

<!-- TODO: hit marker fade, damage number position jitter -->

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Rapid-fire hits | <!-- TODO --> | |
| Simultaneous hits on multiple targets | <!-- TODO --> | |
| Shot felt on-target but server says miss | <!-- TODO --> | No lag comp — document as known MVP issue |

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
| Hit confirmed (non-lethal) | White X on crosshair, 150 ms | Short tick SFX | **Must** |
| Headshot | Red X on crosshair, 200 ms | Higher-pitch tick | **Must** |
| Kill | Thick X, 300 ms | Distinct kill sound | **Must** |
| Damage number | Floating number at hit point | — | Should |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| Hit marker | Crosshair | On hit confirm | When server RPC received |
| Damage number | At enemy position | On hit confirm | When server RPC received |

## Acceptance Criteria

- [ ] <!-- TODO -->

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| <!-- TODO --> | | | |
