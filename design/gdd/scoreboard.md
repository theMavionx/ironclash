# Scoreboard

> **Status**: Skeleton (0/8 sections filled)
> **Author**: TBD
> **Last Updated**: 2026-04-18
> **Implements Pillar**: Pillar 1 — *Skill Is The Ceiling* (stats visible — who did what)
> **MVP Implementation**: Deferred to Post-MVP patch 1. MVP ships with text-only end-of-match score. Full scoreboard (per-player K/D/assist/capture) is post-MVP.
> **Scope**: TAB-to-open mid-match, always-visible post-match. Per-player stats, team totals.

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
| Hidden | Default | TAB pressed OR match end | No scoreboard |
| Overlay | TAB pressed | TAB released | Semi-transparent over gameplay |
| Full-screen | Match ended | Return-to-menu clicked | Full scoreboard + winner |

### Interactions with Other Systems

<!-- TODO -->

## Formulas

<!-- TODO: K/D ratio, MVP scoring -->

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Player disconnected | <!-- TODO — show with tag? hide? --> | |
| Tie in stats | <!-- TODO --> | |

## Dependencies

| System | Direction | Nature of Dependency |
|--------|-----------|---------------------|
| Match scoring | Scoreboard depends on Match scoring | Reads authoritative team + player scores |
| Team assignment | Scoreboard depends on Team | Groups players by team |
| Input system | Scoreboard depends on Input | TAB binding |

## Tuning Knobs

| Parameter | Current Value | Safe Range | Effect of Increase | Effect of Decrease |
|-----------|--------------|------------|-------------------|-------------------|
| <!-- TODO --> | | | | |

## Visual/Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|----------------|---------------|----------|
| TAB opens scoreboard | Fade-in overlay | Subtle tick | Should |
| Match ends | Scoreboard slams to center | Musical sting | Must |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| Team A players + stats | Left panel | On stat change | Scoreboard open |
| Team B players + stats | Right panel | On stat change | Scoreboard open |
| Team scores | Top of each panel | On capture/kill | Scoreboard open |
| Match timer | Top center | 1 Hz | Scoreboard open |

## Acceptance Criteria

- [ ] <!-- TODO -->

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| What columns? (Name, Class, Kills, Deaths, Captures, Score) | Designer | Post-MVP | <!-- TODO --> |
| Show ping per player? | Designer | Post-MVP | <!-- TODO --> |
