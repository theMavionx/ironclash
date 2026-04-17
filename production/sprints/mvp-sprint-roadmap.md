# MVP Sprint Roadmap — Ironclash

**Created**: 2026-04-17
**MVP Target Ship Date**: 2026-05-01
**Total Window**: 15 days (2026-04-17 → 2026-05-01)
**Team**: 2 people + AI assistance
**Daily Availability**: 2-4 hr/person (avg ~3 hr)
**Total Capacity**: ~90 person-hours

---

## Milestone Goal

Ship a **browser-playable 5v5 third-person shooter** on 2026-05-01:
one map, three capture points, Assault class with AK only, no vehicles,
character animations from purchased asset packs.

Post-MVP patch 1 (targeted 4-8 weeks after ship): tanks, helicopter,
Heavy/RPG class, scoreboard, settings UI.

---

## Capacity Reality Check

A networked multiplayer shooter from zero is typically 6-18 months of
full-time work for a small team. 90 hours is ~1 full-time dev-week.
**Aggressive scope cuts are mandatory, not optional.** Concept doc
acknowledges this as team-accepted risk (lines 265-273 in
`design/gdd/game-concept.md`).

---

## Sprint Breakdown (4 × mini-sprints)

| # | Name | Dates | Days | Capacity | Theme |
|---|------|-------|------|----------|-------|
| 1 | Foundation | 2026-04-17 → 2026-04-20 | 4 | ~24 h | Unblock hosting + prove networking works |
| 2 | Core | 2026-04-21 → 2026-04-24 | 4 | ~24 h | Player, shooting, hit registration |
| 3 | Features | 2026-04-25 → 2026-04-28 | 4 | ~24 h | Capture points, match flow, map |
| 4 | Ship | 2026-04-29 → 2026-05-01 | 3 | ~18 h | UI, deploy, bugfix, release |

---

## MVP In-Scope (26 items, reduced from 28)

Kept from `design/gdd/systems-index.md`:

1. Networking layer (prototype then production)
2. Input system
3. Audio system framework (minimal — SFX bus only)
4. VFX system framework (minimal — muzzle flash + hit spark only)
5. Web export & asset loading
6. Player controller (infantry only)
7. Camera system (over-shoulder TPS only)
8. Health / damage system
9. Hit registration (no lag comp — documented limitation)
10. Team assignment (2 teams, auto-balance)
11. Match state machine (warmup → active → end)
12. Weapon system (AK hitscan only)
13. Capture point system (3 points, timed capture)
14. Respawn system (base spawn + held-point spawn)
15. Match scoring (income + kills at time expiry)
16. Animations (use purchased character pack; weapon = simple swap)
17. Quick-play matchmaking (hardcoded server join, not real matchmaker)
18. Server hosting / dedicated process (minimum viable: 1 hosted server)
19. HUD (health, ammo, capture progress — nothing else)
20. Main menu (single "Play" button, name input)

Plus cross-cutting:
21. ADR-0002 Server Hosting (document first, implement in Sprint 1)
22. Map blockout (1 map, 3 capture points, boxy greybox only)
23. Texture application (use existing `textures/` terrain PBR)
24. Character model + anim rigging (from purchased packs)
25. Weapon model (AK from purchased pack)
26. Basic audio (gunshot, footstep, capture, death — 4 SFX minimum)

---

## MVP Cut List (deferred to Post-MVP, NOT removed from systems-index)

The following systems remain in `design/gdd/systems-index.md` and keep
their GDD docs. They are **deferred from the 2026-05-01 ship**, not
deleted. Schedule for post-MVP patch 1.

| System | GDD Status | Reason for Cut |
|--------|-----------|----------------|
| Tank controller | Not started | 6DOF vehicle + net sync too heavy for 90h budget |
| Helicopter controller | Not started | Highest technical risk; systems-index High-Risk #2 |
| Vehicle base system | Not started | No vehicles means no shared base needed |
| Class loadout system | Not started | Only 1 class in MVP; single-class = no picker |
| Heavy class (RPG weapon) | N/A (inside weapon/class) | No second class in MVP |
| Scoreboard UI | Not started | End-of-match screen is "Team A: X / Team B: Y" text only |
| Settings UI | Not started | Defaults only; no rebind, no volume sliders |
| Post-match summary UI | Not started | Covered by simple text end-screen |
| Hit feedback polish | Not started | Minimal hit marker + damage number only |
| Full VFX polish | N/A | Muzzle flash + impact spark only; no smoke, no shells |
| Reload animations | N/A | Flash/swap visual, no animated reload |

All of the above remain in `systems-index.md` tagged as their original
priority. We do not modify the index. This list is the source of truth
for "what will not be in the 2026-05-01 build."

---

## Global Risks (tracked across all sprints)

| # | Risk | Probability | Impact | Mitigation |
|---|------|------------|--------|-----------|
| R1 | Networking does not work in browser at 10 players | High | Fatal (no ship) | Sprint 1 prototype validates; if fails, cut to 2v2 or ship single-map-practice-mode |
| R2 | 90h capacity insufficient even for reduced scope | High | Late or unshipped | Weekly checkpoint; further cuts if Sprint 1/2 run over |
| R3 | Purchased animation pack incompatible with character rig | Medium | Rework art pipeline | Verify rig compatibility on Day 1 before writing controller code |
| R4 | ADR-0002 hosting cost blocker | Medium | Project stall | Investigate free tiers (Hathora free, Railway free) in ADR-0002 |
| R5 | Health issues / life disruption to 2-person team over 15 days | Medium | Fatal to timeline | Accept — no mitigation; push ship date if occurs |

---

## Gate Criteria Between Sprints

**End of Sprint 1**: Networking prototype confirmed working (≥4 concurrent
players with state sync in browser). If FAIL → re-plan immediately, likely
cut to single-player-with-bots or ship slip.

**End of Sprint 2**: One player can move, aim, shoot, and hit another
player (or dummy) with AK. If FAIL → cut to reduced map + slower target.

**End of Sprint 3**: Capture point mechanic works and match can end.
If FAIL → ship as deathmatch-only, no capture.

**End of Sprint 4**: Web export runs from the hosted server URL with
2+ humans connected. If FAIL → ship slip.

---

## Files This Roadmap Generates

- `production/sprints/sprint-01-foundation.md` — detailed plan (written now)
- `production/sprints/sprint-02-core.md` — write at start of Sprint 2
- `production/sprints/sprint-03-features.md` — write at start of Sprint 3
- `production/sprints/sprint-04-ship.md` — write at start of Sprint 4

Each sprint plan is written at sprint start so scope is informed by
previous-sprint actuals, not optimistic pre-sprint estimates.
