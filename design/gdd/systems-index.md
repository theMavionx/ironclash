# Systems Index: Ironclash

> **Status**: Draft
> **Created**: 2026-04-14
> **Last Updated**: 2026-04-14
> **Source Concept**: design/gdd/game-concept.md

---

## Overview

Ironclash is a browser-based 5v5 **third-person** team objective shooter with
combined-arms combat (infantry + tank + helicopter) on a single map with three
capture points. The infantry view is over-shoulder TPS (PUBG-style camera +
Fortnite-style arcade tempo). Two classes only: Assault (AK) and Heavy (RPG).
The systems scope is driven by three pillars: *Skill Is The Ceiling*, *Every
Tool Has A Counter*, and *Matches Start Fast*. The MVP targets a 15-day
development window with two AI-assisted developers — scope is aggressive and
risk is team-accepted. This index enumerates **28 MVP systems** across 5
dependency layers, plus **6 deferred systems** for post-MVP. Networking is the
dominant bottleneck: 13 of 28 systems depend on it, making it the highest-risk
item and the first system that must be designed and prototyped.

---

## Systems Enumeration

| # | System Name | Category | Priority | Status | Design Doc | Depends On |
|---|-------------|----------|----------|--------|------------|------------|
| 1 | Networking layer | Core | MVP | Approved (ADR-0001) | [ADR-0001](../../docs/architecture/adr-0001-networking-architecture.md) | (none) |
| 2 | Input system (inferred) | Core | MVP | Designed | [design/gdd/input-system.md](input-system.md) | (none) |
| 3 | Audio system (inferred) | Audio | MVP | Designed | [design/gdd/audio-system-framework.md](audio-system-framework.md) | (none) |
| 4 | VFX system (inferred) | Core | MVP | Designed | [design/gdd/vfx-system-framework.md](vfx-system-framework.md) | (none) |
| 5 | Web export & asset loading (inferred) | Core | MVP | Designed | [design/gdd/web-export-and-asset-loading.md](web-export-and-asset-loading.md) | (none) |
| 6 | Player controller (inferred) | Core | MVP | Designed | [design/gdd/player-controller.md](player-controller.md) | Input, Networking |
| 7 | Camera system (inferred) | Core | MVP | Designed | [design/gdd/camera-system.md](camera-system.md) | Player controller |
| 8 | Health/damage system (inferred) | Gameplay | MVP | Designed | [design/gdd/health-and-damage-system.md](health-and-damage-system.md) | Networking |
| 9 | Hit registration (inferred) | Gameplay | MVP | Designed | [design/gdd/hit-registration.md](hit-registration.md) | Networking, Player controller |
| 10 | Team assignment (inferred) | Core | MVP | Designed | [design/gdd/team-assignment.md](team-assignment.md) | Networking |
| 11 | Match state machine (inferred) | Core | MVP | Designed | [design/gdd/match-state-machine.md](match-state-machine.md) | Networking |
| 12 | Weapon system | Gameplay | MVP | Not Started | — | Networking, Hit registration, Player controller |
| 13 | Vehicle system (shared base) | Gameplay | MVP | Not Started | — | Networking, Player controller |
| 14 | Class loadout system | Gameplay | MVP | Not Started | — | Weapon system, Player controller |
| 15 | Tank controller | Gameplay | MVP | Not Started | — | Vehicle base, Weapon system |
| 16 | Helicopter controller | Gameplay | MVP | Not Started | — | Vehicle base, Weapon system |
| 17 | Capture point system | Gameplay | MVP | Not Started | — | Networking, Team assignment, Player controller |
| 18 | Respawn system (inferred) | Gameplay | MVP | Not Started | — | Capture points, Team assignment, Match state |
| 19 | Match scoring | Gameplay | MVP | Not Started | — | Capture points, Health/damage, Match state |
| 20 | Animations (inferred) | Core | MVP | Not Started | — | Player controller, Weapon system, Vehicle controllers |
| 21 | Quick-play matchmaking (inferred) | Core | MVP | Not Started | — | Networking, Match state |
| 22 | Server hosting / dedicated process (inferred) | Core | MVP | Not Started | — | Networking |
| 23 | HUD (inferred) | UI | MVP | Not Started | — | Health, Weapon, Capture, Match state |
| 24 | Hit feedback (inferred) | UI | MVP | Not Started | — | Hit registration, Health |
| 25 | Scoreboard (inferred) | UI | MVP | Not Started | — | Match scoring, Team |
| 26 | Main menu (inferred) | UI | MVP | Not Started | — | Input |
| 27 | Post-match summary UI (inferred) | UI | MVP | Not Started | — | Match scoring |
| 28 | Settings UI (inferred) | UI | MVP | Not Started | — | Input, Audio |
| 29 | Drone system | Gameplay | Full Vision | Not Started | — | Networking, Player controller, Camera, VFX |
| 30 | Skin/cosmetic system | Economy | Full Vision | Not Started | — | Account/auth, Player controller |
| 31 | Monetization/shop | Economy | Full Vision | Not Started | — | Account/auth, Skin system |
| 32 | Account/auth (inferred) | Persistence | Full Vision | Not Started | — | Networking |
| 33 | Progression/XP (inferred) | Progression | Full Vision | Not Started | — | Account/auth, Match scoring |
| 34 | Anti-cheat (inferred) | Meta | Full Vision | Not Started | — | Networking, Server hosting |

---

## Categories

| Category | Description | Systems in This Game |
|----------|-------------|----------------------|
| **Core** | Foundation systems everything depends on | Networking, Input, VFX, Web export, Player controller, Camera, Team, Match state, Animations, Matchmaking, Server hosting |
| **Gameplay** | The systems that make the game fun | Health/damage, Hit reg, Weapon, Vehicle base, Class loadout, Tank, Helicopter, Capture point, Respawn, Match scoring, Drone |
| **UI** | Player-facing information displays | HUD, Hit feedback, Scoreboard, Main menu, Post-match UI, Settings UI |
| **Audio** | Sound and music systems | Audio system framework |
| **Economy** | Resource creation and consumption (post-MVP) | Skin/cosmetic, Monetization/shop |
| **Persistence** | Save state and continuity (post-MVP) | Account/auth |
| **Progression** | How the player grows over time (post-MVP) | XP/leveling |
| **Meta** | Systems outside the core game loop (post-MVP) | Anti-cheat |

Narrative category does not apply (no story layer).

---

## Priority Tiers

| Tier | Definition | Target Milestone | Design Urgency |
|------|------------|------------------|----------------|
| **MVP** | Required for the 15-day playable MVP | Day 15 release | Design FIRST (all 28 systems) |
| **Full Vision** | Post-MVP polish and commercial features | +4-6 months after MVP | Design later |

Vertical Slice and Alpha tiers are not used — the 15-day MVP target skips these milestones.

---

## Dependency Map

### Foundation Layer (no dependencies)

1. **Networking layer** — The backbone. Every multiplayer system depends on this. Design and prototype FIRST.
2. **Input system** — KB+mouse binding and dispatch. Simple but needed by every interactive system.
3. **Audio system (framework)** — Bus/volume/pooling infrastructure. Actual SFX are authored later; system comes first.
4. **VFX system (framework)** — Pooling and spawn infrastructure for muzzle flashes, impacts, explosions.
5. **Web export & asset loading** — HTML5 export pipeline, progressive asset delivery, load screen.

### Core Layer (depends on Foundation)

1. **Player controller** — depends on: Input, Networking
2. **Camera system** — depends on: Player controller
3. **Health/damage system** — depends on: Networking
4. **Hit registration** — depends on: Networking, Player controller
5. **Team assignment** — depends on: Networking
6. **Match state machine** — depends on: Networking

### Feature Layer (depends on Core)

1. **Weapon system** — depends on: Networking, Hit registration, Player controller
2. **Vehicle system (shared base)** — depends on: Networking, Player controller
3. **Class loadout system** — depends on: Weapon, Player controller
4. **Tank controller** — depends on: Vehicle base, Weapon system
5. **Helicopter controller** — depends on: Vehicle base, Weapon system
6. **Capture point system** — depends on: Networking, Team, Player controller
7. **Respawn system** — depends on: Capture points, Team, Match state
8. **Match scoring** — depends on: Capture points, Health/damage, Match state
9. **Animations** — depends on: Player controller, Weapon, Vehicle controllers
10. **Quick-play matchmaking** — depends on: Networking, Match state
11. **Server hosting / dedicated process** — depends on: Networking

### Presentation Layer (depends on Features)

1. **HUD** — depends on: Health, Weapon, Capture points, Match state
2. **Hit feedback** — depends on: Hit registration, Health
3. **Scoreboard** — depends on: Match scoring, Team
4. **Main menu** — depends on: Input
5. **Post-match summary UI** — depends on: Match scoring
6. **Settings UI** — depends on: Input, Audio

### Polish / Deferred Layer (post-MVP)

1. **Drone system** — depends on: Networking, Player controller, Camera, VFX
2. **Account/auth** — depends on: Networking
3. **Skin/cosmetic system** — depends on: Account/auth, Player controller
4. **Monetization/shop** — depends on: Account/auth, Skin system
5. **Progression/XP** — depends on: Account/auth, Match scoring
6. **Anti-cheat** — depends on: Networking, Server hosting

---

## Recommended Design Order

Design these systems in this order. Systems in the same layer can be designed
in parallel if you have multiple design sessions running.

| Order | System | Priority | Layer | Agent(s) | Est. Effort |
|-------|--------|----------|-------|----------|-------------|
| 1 | Networking layer | MVP | Foundation | network-programmer, technical-director | L |
| 2 | Input system | MVP | Foundation | gameplay-programmer | S |
| 3 | Web export & asset loading | MVP | Foundation | technical-director | S |
| 4 | Audio system (framework) | MVP | Foundation | audio-director | S |
| 5 | VFX system (framework) | MVP | Foundation | technical-artist | S |
| 6 | Player controller | MVP | Core | gameplay-programmer | M |
| 7 | Camera system | MVP | Core | gameplay-programmer | S |
| 8 | Health/damage system | MVP | Core | systems-designer | S |
| 9 | Hit registration | MVP | Core | gameplay-programmer, network-programmer | M |
| 10 | Team assignment | MVP | Core | gameplay-programmer | S |
| 11 | Match state machine | MVP | Core | game-designer | S |
| 12 | Weapon system | MVP | Feature | systems-designer, gameplay-programmer | M |
| 13 | Vehicle system (shared base) | MVP | Feature | gameplay-programmer | M |
| 14 | Class loadout system | MVP | Feature | systems-designer | S |
| 15 | Capture point system | MVP | Feature | game-designer, systems-designer | M |
| 16 | Tank controller | MVP | Feature | gameplay-programmer | M |
| 17 | Helicopter controller | MVP | Feature | gameplay-programmer | L |
| 18 | Respawn system | MVP | Feature | game-designer | S |
| 19 | Match scoring | MVP | Feature | systems-designer | S |
| 20 | Quick-play matchmaking | MVP | Feature | network-programmer | M |
| 21 | Server hosting / dedicated process | MVP | Feature | devops-engineer, technical-director | M |
| 22 | Animations | MVP | Feature | technical-artist, gameplay-programmer | M |
| 23 | HUD | MVP | Presentation | ui-programmer, ux-designer | M |
| 24 | Hit feedback | MVP | Presentation | ui-programmer, sound-designer | S |
| 25 | Scoreboard | MVP | Presentation | ui-programmer | S |
| 26 | Main menu | MVP | Presentation | ui-programmer, ux-designer | S |
| 27 | Post-match summary UI | MVP | Presentation | ui-programmer | S |
| 28 | Settings UI | MVP | Presentation | ui-programmer | S |
| 29 | Account/auth | Full Vision | Polish | security-engineer | M |
| 30 | Drone system | Full Vision | Polish | gameplay-programmer | L |
| 31 | Anti-cheat | Full Vision | Polish | security-engineer | L |
| 32 | Skin/cosmetic system | Full Vision | Polish | gameplay-programmer | M |
| 33 | Progression/XP | Full Vision | Polish | systems-designer | M |
| 34 | Monetization/shop | Full Vision | Polish | economy-designer, ui-programmer | M |

Effort estimates: S = 1 session, M = 2-3 sessions, L = 4+ sessions.

---

## Circular Dependencies

None found.

---

## High-Risk Systems

These need early prototyping regardless of design order — they can kill the
project if they don't work.

| System | Risk Type | Risk Description | Mitigation |
|--------|-----------|------------------|------------|
| Networking layer | Technical | Zero multiplayer experience on team; 15-day timeline; browser constraints (WebSockets only, no threading, WASM overhead) | Prototype Day 1-3. Validate 10-player state sync before building anything else. Decision locked in ADR-0001. |
| Helicopter controller | Technical | 6DOF flight model + network sync is the hardest vehicle problem in games | Prototype separately from main build. First to cut if time runs out. |
| Tank controller | Technical | Physics + network sync; simpler than heli but still non-trivial | Build after helicopter sync is proven viable. |
| Hit registration | Technical | Without lag compensation, >80ms ping will feel bad. No lag comp at MVP. | Document as known issue. Target low-latency server regions only for MVP. |
| Server hosting | Scope | Cost model undecided; ongoing cost unclear; no deployment pipeline | Needs ADR-0002 (hosting/deployment). Resolve before day 5. |
| Web export perf | Technical | Browser CPU budget unknown with 10 players + 2 vehicles + VFX | Profile early. Budget aggressively. Be ready to cut visual fidelity. |
| 15-day timeline overall | Scope | Aggressive scope + inexperienced team = high completion risk. No bot fallback (team cut it). | Cut-order documented in concept doc. Accept risk. |

---

## Progress Tracker

| Metric | Count |
|--------|-------|
| Total systems identified | 34 |
| Design docs started | 11 |
| Design docs reviewed | 1 |
| Design docs approved | 1 (Networking via ADR-0001) |
| MVP systems designed | 11/28 |
| Full Vision systems designed | 0/6 |

---

## Next Steps

- [ ] Write **ADR-0001: Networking Architecture** (`/architecture-decision`)
- [ ] Write **ADR-0002: Server Hosting & Deployment** (`/architecture-decision`)
- [ ] Design MVP systems in the order listed above (use `/design-system [system-name]`)
- [ ] Start with **Networking layer** — this is the bottleneck and highest risk
- [ ] Prototype networking + helicopter flight **in parallel with GDD writing** — do not wait for all GDDs before coding the high-risk items (`/prototype networking`, `/prototype helicopter-flight`)
- [ ] Run `/design-review` on each completed GDD
- [ ] Run `/sprint-plan new` to build the 15-day day-by-day plan once first 3-5 GDDs are written
