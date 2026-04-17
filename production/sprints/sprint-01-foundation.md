# Sprint 1 — Foundation

**Dates**: 2026-04-17 (Fri) → 2026-04-20 (Mon) — 4 days
**Status**: Active

---

## Sprint Goal

Unblock server hosting and prove the networking architecture works in a
browser before any feature code is written. By end of sprint, two browser
clients must successfully send and receive state updates via a hosted
Godot dedicated server.

## Milestone Context

- **Milestone**: MVP ship 2026-05-01
- **Sprints Remaining**: 3 (this one + 3 more)
- **Roadmap**: `production/sprints/mvp-sprint-roadmap.md`

## Capacity

| Resource | Available Days | Available Hours | Buffer (20%) | Task Budget |
|----------|---------------|-----------------|-------------|-------------|
| Dev 1 | 4 | 12 | 2.4 | 9.6 h |
| Dev 2 | 4 | 12 | 2.4 | 9.6 h |
| **Total** | **8 person-days** | **24 h** | **4.8 h** | **~19 h** |

Capacity assumes 3 hr/person/day average (range 2-4). Buffer covers
meetings, context-switches, integration friction.

## Tasks

### Must Have (Critical Path)

| ID | Task | Owner | Est. Hours | Dependencies | Acceptance Criteria | Status |
|----|------|-------|-----------|-------------|---------------------|--------|
| S1-001 | **ADR-0002: Server Hosting & Deployment** — write ADR selecting host (Hathora / Railway / self-VPS) with cost model and deployment path | Dev 1 | 3 | None | ADR file in `docs/architecture/` with decision, rationale, 3 alternatives compared, cost table | Not Started |
| S1-002 | **Verify asset pack compatibility** — import purchased character rig + animation pack into Godot 4.3; confirm anims play on rig in a test scene | Dev 2 | 2 | None | Test scene shows character running, idle, shooting anim on imported rig; screenshot committed to `docs/art-checks/` | Not Started |
| S1-003 | **Networking prototype — bare minimum** — Godot MultiplayerAPI over WebSocket; 2 clients connect to headless server; each client spawns a cube; position syncs across clients | Dev 1 | 8 | S1-001 (know where to deploy) | Prototype repo path `prototypes/networking/`; 2 browser tabs see each other's cubes moving; README with how-to-run | Not Started |
| S1-004 | **Input system implementation** — per `design/gdd/input-system.md`; map WASD + mouse look + LMB fire + R reload key to action events | Dev 2 | 3 | S1-002 | `src/input/` with InputManager singleton; debug print shows action dispatch on keypress | Not Started |
| S1-005 | **Deploy networking prototype to chosen host** — get `prototypes/networking/` accessible from a public URL in a browser | Dev 1 | 3 | S1-001, S1-003 | Dev 2 can open URL from their machine, see their own cube + Dev 1's cube moving | Not Started |

**Must-Have total**: 19 hours — fills budget.

### Should Have

| ID | Task | Owner | Est. Hours | Dependencies | Acceptance Criteria | Status |
|----|------|-------|-----------|-------------|---------------------|--------|
| S1-010 | **Player controller skeleton** — `src/gameplay/player/` with empty PlayerController node, KinematicBody3D + Camera child, WASD movement (local-only, no net) | Dev 2 | 3 | S1-004 | Test scene loads, character moves with WASD, camera follows | Not Started |
| S1-011 | **Update `active.md` status block** to track sprint | Dev 1 | 0.5 | None | Status block reflects "Sprint 1: Foundation" | Not Started |

### Nice to Have (Cut First)

| ID | Task | Owner | Est. Hours | Dependencies | Acceptance Criteria | Status |
|----|------|-------|-----------|-------------|---------------------|--------|
| S1-020 | **Write Weapon system GDD** — `/design-system weapon-system` for AK-only MVP weapon | Either | 2 | None | GDD file in `design/gdd/weapon-system.md` with 8 required sections | Not Started |

## Carryover from Previous Sprint

None (first sprint).

## Risks to This Sprint

| Risk | Probability | Impact | Mitigation | Owner |
|------|------------|--------|-----------|-------|
| Networking prototype does not work by Day 4 | Medium | Fatal to MVP | Hard cap: if Day 3 EOD no progress, escalate scope cut or timeline slip | Dev 1 |
| Asset pack rig is incompatible (wrong skeleton naming) | Medium | Forces art rework | Verify on Day 1 before writing controller (S1-002 blocks S1-010) | Dev 2 |
| Free hosting tier rate-limits on WebSocket traffic | Low | Forces paid tier | Document as ADR risk; budget $5-20/mo if it hits | Dev 1 |
| Godot 4.3 MultiplayerAPI has web export quirks | Medium | Rework | Test web export early (Day 1-2); fall back to raw WebSocket if MultiplayerAPI fails over WS | Dev 1 |

## External Dependencies

| Dependency | Status | Impact if Delayed | Contingency |
|-----------|--------|------------------|-------------|
| Chosen hosting provider account | Not created | Blocks S1-005 | Use localhost tunnel (ngrok) for Sprint 1, real host in Sprint 2 |
| Purchased character anim pack | Downloaded | Blocks S1-002 | Use default Godot cube character if pack fails |

## Definition of Done

- [ ] S1-001 through S1-005 all complete with passing acceptance criteria
- [ ] 2 browser tabs on different machines can see each other's cubes syncing over the internet
- [ ] ADR-0002 committed to `docs/architecture/`
- [ ] Character rig + anim pack confirmed working
- [ ] `production/session-state/active.md` updated
- [ ] No S1-S2 bugs in prototype blocking next-sprint work
- [ ] Sprint 2 plan can be written with known networking constraints

## Gate Check (End of Sprint 1)

**PASS**: Networking prototype demonstrates 2+ browser clients syncing
state via hosted server. Asset pipeline confirmed. ADR-0002 written.
→ Proceed to Sprint 2.

**CONCERNS**: Prototype works on localhost but not yet on hosted server,
OR asset pack needs 1-2 days of rework.
→ Proceed to Sprint 2 but carry over S1-005 and budget less for Sprint 2.

**FAIL**: Prototype fundamentally does not work after 4 days of attempts.
→ STOP. Escalate. Re-scope MVP (possibilities: local-LAN only, 2v2 instead
of 5v5, or push ship date). Do NOT start Sprint 2.

## Daily Status Tracking

| Day | Date | Tasks Completed | Tasks In Progress | Blockers | Notes |
|-----|------|----------------|------------------|----------|-------|
| Day 1 | 2026-04-17 (Fri) | | | | |
| Day 2 | 2026-04-18 (Sat) | | | | |
| Day 3 | 2026-04-19 (Sun) | | | | |
| Day 4 | 2026-04-20 (Mon) | | | | |

---

## Post-Sprint Retrospective (fill at end of sprint)

**What worked**:
- [TBD]

**What didn't**:
- [TBD]

**Actual hours vs estimate**:
- [TBD]

**Carry into Sprint 2**:
- [TBD]
