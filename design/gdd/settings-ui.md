# Settings UI

> **Status**: Skeleton (0/8 sections filled)
> **Author**: TBD
> **Last Updated**: 2026-04-18
> **Implements Pillar**: Pillar 3 — *Matches Start Fast* (minimal settings at MVP; deep settings post-MVP)
> **MVP Implementation**: Deferred to Post-MVP patch 1. MVP ships with defaults only — no user-configurable settings.
> **Scope**: Audio volumes, mouse sensitivity, key rebinds, graphics quality, language.

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
| Closed | Default | Settings clicked | Hidden |
| Open | Settings clicked | Close / apply | Modal overlay |
| Editing | Tab active | Tab switch / save | Tab-specific controls |
| Rebinding | Key press in rebind field | Key captured OR escape | Wait for key |

### Interactions with Other Systems

<!-- TODO -->

## Formulas

<!-- TODO: sensitivity scaling formula -->

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Invalid key rebind (system key) | <!-- TODO --> | |
| Browser localStorage disabled | <!-- TODO — settings don't persist --> | |
| Reset to defaults | <!-- TODO --> | |

## Dependencies

| System | Direction | Nature of Dependency |
|--------|-----------|---------------------|
| Input system | Settings writes to Input | Key rebinds modify Input bindings |
| Audio system | Settings writes to Audio | Bus volume changes |
| Web export | Settings depends on Web export | Uses browser localStorage |

## Tuning Knobs

| Parameter | Current Value | Safe Range | Effect of Increase | Effect of Decrease |
|-----------|--------------|------------|-------------------|-------------------|
| <!-- TODO — default sensitivity, default volumes --> | | | | |

## Visual/Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|----------------|---------------|----------|
| Settings opens | Panel slides in | Subtle click | Should |
| Setting changed | Value flashes | — | Should |
| Apply | Green checkmark | Confirm SFX | Must |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| Tab bar (Audio / Controls / Graphics / Language) | Left sidebar | Static | Settings open |
| Current values | Right panel | On edit | Settings open |
| Apply / Cancel / Reset | Bottom | Static | Settings open |

## Acceptance Criteria

- [ ] <!-- TODO -->

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| What graphics quality tiers? (Low / Med / High) | Tech | Post-MVP | <!-- TODO --> |
| Invert Y axis for aim? | Designer | Post-MVP | <!-- TODO --> |
