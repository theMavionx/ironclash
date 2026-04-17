# Audio System (Framework)

> **Status**: Designed (thin spec — infrastructure layer)
> **Author**: Claude Code Game Studios session
> **Last Updated**: 2026-04-14
> **Implements Pillar**: Skill Is The Ceiling (audio cues — footsteps, reload, vehicle hum — are critical skill information)

## Overview

The Audio System is the framework that loads, pools, mixes, and plays sound
in Ironclash. It defines the bus hierarchy, volume controls, positional audio
rules, and pooling limits. This GDD covers the framework only — individual
SFX authoring and music cues are owned by the sound-designer and audio-director
agents and will be specified in separate content documents.

## Player Fantasy

Audio is a gameplay information channel, not background noise. A skilled
player hears a reload from behind a wall and pre-aims the corner. A drone's
whine (post-MVP) signals "look up now." Every critical gameplay event has an
audio cue players can learn and act on.

## Detailed Design

### Core Rules

- All audio routes through a central mixer with named buses
- Per-bus volume is exposed to the player via Settings UI
- Spatial audio is 3D for gameplay SFX (weapons, footsteps, vehicles, explosions)
- UI and music are stereo (non-spatial)
- Audio pool size is capped to prevent runaway concurrent sounds in chaotic moments

### Bus Hierarchy

```
Master (0 dB default)
├── Music (-6 dB default)
├── SFX (0 dB default)
│   ├── Weapons (0 dB)
│   ├── Vehicles (-3 dB)
│   ├── Impacts (0 dB)
│   ├── Footsteps (-6 dB)
│   └── Ambient (-12 dB)
├── UI (-3 dB default)
└── Voice (muted at MVP — no voice chat, no announcer)
```

### Pooling Rules

- **SFX pool:** 16 concurrent `AudioStreamPlayer3D` instances, round-robin reuse
- **UI pool:** 4 concurrent `AudioStreamPlayer` instances (stereo)
- **Music:** 1 dedicated `AudioStreamPlayer` (crossfade capable, but no adaptive layering at MVP)
- When pool is full, new sound **steals the oldest instance** (no dropped cues)

### Audio Format Standards

| Content Type | Format | Bitrate | Rationale |
|---|---|---|---|
| SFX | OGG Vorbis | 96 kbps | Small size, web-friendly |
| Music | OGG Vorbis | 128 kbps | Balance between size and quality |
| Voice (post-MVP) | OGG Vorbis | 80 kbps | Voice is narrowband |

Reject: WAV (too large), MP3 (licensing complications).

### Interactions with Other Systems

- **Weapon System** (event source): triggers fire, reload, weapon-switch sounds
- **Player Controller** (event source): triggers footsteps, jump, land
- **Vehicle Controllers** (event source): triggers engine loops, explosion on destroy
- **Health/Damage** (event source): triggers hit grunt, death sound
- **Capture Point System** (event source): triggers capture-progress ticks, captured/lost jingles
- **Match State** (event source): match-start and match-end stingers
- **Settings UI** (configurator): writes bus volumes to this system

## Formulas

**Attenuation (3D spatial):**
Godot default `AudioStreamPlayer3D` uses inverse-distance attenuation. Config per sound:
- `unit_size`: 1 m (reference distance)
- `max_distance`: varies per SFX (footsteps: 25 m, gunfire: 100 m, explosion: 150 m, vehicle: 75 m)
- `rolloff`: linear (post-MVP may switch to inverse-square for some categories)

**Volume dB → linear** (for slider UI):
`linear = 10^(db / 20)` — standard conversion

## Edge Cases

- **Many sounds triggered same frame** (explosion in crowd) → pool fills; new sounds steal oldest
- **Player in vehicle** → muffle external SFX by attaching a low-pass filter to SFX bus (post-MVP)
- **Player spawns near loud ambient** → ambient fades in over 0.5s, not instant
- **Audio context suspended** (browser autoplay policy) → resume on first user input
- **Browser tab loses focus** → pause/mute audio (not gameplay), resume on focus

## Dependencies

**Upstream:** Godot 4.3 AudioServer (built-in)

**Downstream (depended on by):**
- Weapon System, Vehicle Controllers, Player Controller, Health/Damage, Capture Points (hard — core gameplay audio)
- HUD, Hit feedback (hard — UI audio cues)
- Settings UI (hard — exposes bus volumes)

## Tuning Knobs

| Knob | Range | Default | Effect |
|---|---|---|---|
| `master_volume` | 0.0 – 1.0 | 1.0 | Overall mix level |
| `music_volume` | 0.0 – 1.0 | 0.5 | Music bus level |
| `sfx_volume` | 0.0 – 1.0 | 1.0 | SFX bus level |
| `ui_volume` | 0.0 – 1.0 | 0.7 | UI bus level |
| `sfx_pool_size` | 8-32 | 16 | Concurrent SFX cap |
| `footstep_max_distance_m` | 10-50 | 25 | Footstep audibility range |
| `gunfire_max_distance_m` | 50-200 | 100 | Gunfire audibility range |

## Acceptance Criteria

- [ ] All MVP SFX play through correct buses (verified via audio bus inspector)
- [ ] Volume sliders persist across sessions and apply immediately
- [ ] No audio glitches/pops when >16 sounds trigger simultaneously
- [ ] 3D positional audio is audibly correct (left/right/distance)
- [ ] Browser autoplay policy is handled — audio resumes on first click
- [ ] Tab defocus pauses audio; refocus resumes without glitch
- [ ] Total audio memory footprint <40 MB for MVP SFX + music

## Open Questions

- Music strategy: single looping track per match, or state-driven (tense/calm) music? Defer to audio-director
- Announcer/VO: MVP has none; post-MVP may add capture-point callouts
- Reverb/reverb zones: not at MVP; may add for indoor map areas post-MVP
