# Project Stage Analysis Report

**Generated**: 2026-04-17
**Stage**: Pre-Production
**Analysis Scope**: Full project (general)

---

## Executive Summary

Ironclash is a browser-based 5v5 third-person team objective shooter in
**Pre-Production**. The engine is configured (Godot 4.3), the game concept and
systems index are drafted, and 11 of 28 MVP system GDDs have been written.
**No source code exists yet** and **no sprint plan has been created**, despite
the concept calling for an aggressive 15-day MVP that started 2026-04-14.
Today is 2026-04-17 — the project is ~day 3-4 of 15 with zero implementation.

The dominant risk is **schedule**: 17 MVP GDDs remain unwritten, ADR-0002
(Server Hosting) is a documented blocker for day 5 and hasn't been authored,
and networking/helicopter prototypes that the systems index explicitly said
should run in parallel with GDD writing have not started.

**Current Focus**: Systems-layer GDD authoring (11/28 complete).
**Blocking Issues**: No sprint plan; ADR-0002 missing; no prototypes started;
empty `prototypes/petting-system/` of unknown provenance.
**Estimated Time to Next Stage (Production)**: Gated on networking prototype
proving multiplayer state sync viable. Per concept/ADR-0001, ~2-3 days once
prototyping begins.

---

## Completeness Overview

### Design Documentation
- **Status**: ~40% complete
- **Files Found**: 12 documents in `design/`
  - GDD sections: 12 files in `design/gdd/`
    - `game-concept.md` (concept)
    - `systems-index.md` (index of 34 systems)
    - 10 system GDDs: input, web-export, audio-framework, vfx-framework,
      player-controller, camera, health-and-damage, hit-registration,
      team-assignment, match-state-machine
  - Narrative docs: 0 (N/A — no story layer per concept)
  - Level designs: 0 files in `design/levels/`
- **Key Gaps**:
  - [ ] 17 MVP GDDs unwritten: Weapon, Vehicle base, Class loadout, Tank,
        Helicopter, Capture point, Respawn, Match scoring, Animations,
        Quick-play matchmaking, Server hosting, HUD, Hit feedback,
        Scoreboard, Main menu, Post-match summary UI, Settings UI
  - [ ] No level/map design doc for the single MVP capture-point map
  - [ ] `game-pillars.md` — pillars referenced in systems-index
        (*Skill Is The Ceiling*, *Every Tool Has A Counter*, *Matches Start Fast*)
        but not extracted to a dedicated pillars doc

### Source Code
- **Status**: 0% complete
- **Files Found**: 0 source files in `src/`
- **Major Systems Identified**: None
- **Key Gaps**:
  - [ ] Networking prototype — highest risk per ADR-0001; systems-index
        explicitly flagged for day 1-3 parallel prototyping
  - [ ] Helicopter flight prototype — second-highest technical risk
  - [ ] Player controller — core layer, 6 systems depend on it
  - [ ] All 28 MVP systems are unimplemented

### Architecture Documentation
- **Status**: ~33% complete (1 of 3 expected pre-production ADRs)
- **ADRs Found**: 1 in `docs/architecture/`
  - `adr-0001-networking-architecture.md`
- **Coverage**:
  - Networking — documented (ADR-0001)
  - Server hosting / deployment — **undocumented, blocker before day 5**
  - Web export / asset delivery — covered by GDD but no ADR
- **Key Gaps**:
  - [ ] **ADR-0002: Server Hosting & Deployment** — named as blocker in
        systems-index High-Risk section; cost model undecided; no pipeline
  - [ ] Architecture overview / index linking ADRs to systems

### Production Management
- **Status**: ~5% complete
- **Found**:
  - Sprint plans: 0 in `production/sprints/`
  - Milestones: 0 in `production/milestones/`
  - Roadmap: Missing
  - Session scaffolding: `session-state/.gitkeep`,
    `session-logs/session-log.md` exist
- **Key Gaps**:
  - [ ] **15-day MVP day-by-day sprint plan** — systems-index said to run
        `/sprint-plan new` after 3-5 GDDs; 11 are written, well past trigger
  - [ ] MVP milestone definition (day 15 release target)
  - [ ] Risk register (named risks in systems-index but not tracked formally)

### Testing
- **Status**: 0% coverage
- **Test Files**: 0 in `tests/`
- **Coverage by System**: N/A — no code exists to test
- **Key Gaps**:
  - [ ] Test strategy decision: minimum coverage for MVP vs. defer to
        post-MVP. 15-day timeline makes aggressive TDD unrealistic, but
        network sync and hit registration are high-risk and warrant tests
        even at MVP scope.

### Prototypes
- **Active Prototypes**: 1 directory, 0 documented
  - `prototypes/petting-system/` — **empty directory, no README, no files**
- **Archived**: 0
- **Key Gaps**:
  - [ ] `prototypes/petting-system/` — unclear purpose. Name does not match
        any concept element (military TPS). Possibly a stale template
        placeholder from a previous project or accidental creation.
        Needs removal or documentation.
  - [ ] No networking prototype — highest risk item has no experimental
        validation
  - [ ] No helicopter flight prototype — second-highest risk

---

## Stage Classification Rationale

**Why Pre-Production?**

The project satisfies Pre-Production indicators: engine configured, concept
and systems index drafted, multiple GDDs in progress, at least one ADR
authored, and no production-level source code yet.

**Indicators for this stage**:
- Engine pinned (Godot 4.3 Forward+) in `.claude/docs/technical-preferences.md`
- `design/gdd/game-concept.md` exists and is substantive
- `design/gdd/systems-index.md` exists with dependency mapping
- 11 system GDDs drafted
- 1 ADR authored (networking)
- `src/` empty (< 10 source files threshold for Production)

**Next stage requirements (to reach Production)**:
- [ ] Complete remaining 17 MVP GDDs (or accept gaps with documented risk)
- [ ] Author ADR-0002 (Server Hosting)
- [ ] Prototype networking + validate 10-player state sync
- [ ] First production source files committed to `src/`
- [ ] Sprint plan for the 15-day MVP window

---

## Gaps Identified (with Clarifying Questions)

### Critical Gaps (block progress)

1. **No 15-day sprint plan despite being on day 3-4 of 15**
   - **Impact**: Without a day-by-day plan, the aggressive timeline will
     slip silently. Systems-index explicitly prescribed running sprint-plan
     after the first 3-5 GDDs; 11 are written.
   - **Question**: Is the 15-day MVP target still the accepted scope, or
     has the team/solo-dev situation shifted?
   - **Suggested Action**: `/sprint-plan new` immediately, scoped to the
     remaining 11-12 days.

2. **ADR-0002 (Server Hosting) — documented blocker, not written**
   - **Impact**: Systems-index lists this as must-resolve-before-day-5.
     Cost model undecided; no deployment pipeline; browser-hosted dedicated
     servers are non-trivial to stand up.
   - **Question**: Have you evaluated any hosting options yet (self-host
     VPS, managed game-server hosting like Hathora/Edgegap, serverless
     relay)?
   - **Suggested Action**: `/architecture-decision` to author ADR-0002.

3. **No networking prototype — highest project risk**
   - **Impact**: Systems-index explicitly said to prototype networking in
     parallel with GDD writing starting day 1-3. No prototype exists.
     ADR-0001 is a decision on paper; it has not been validated with code.
   - **Question**: Is there a reason prototyping has been deferred, or was
     this just pending `/prototype` invocation?
   - **Suggested Action**: `/prototype networking` as soon as ADR-0002 is
     enough to choose a hosting target.

### Important Gaps (affect quality/velocity)

4. **17 MVP GDDs unwritten**
   - **Impact**: Weapon, Vehicle base, Tank, Helicopter, Capture point,
     Scoring, Animations, all 6 UI docs are undesigned. Implementation
     cannot begin on these without at least skeleton-level design.
   - **Question**: Do you want to continue `/design-system` in the order
     recommended by systems-index, or cut scope further to reduce the
     design backlog?
   - **Suggested Action**: `/design-system [system-name]` in the index
     order, or `/scope-check` to identify cut candidates.

5. **Empty prototype: `prototypes/petting-system/`**
   - **Impact**: Low, but creates confusion. Name does not align with the
     military TPS concept. Claude's startup hook flags it as an
     undocumented prototype.
   - **Question**: Is this a leftover from a different project, or
     intentional? Delete, rename, or document?
   - **Suggested Action**: User decision — most likely `rm -rf` the empty
     directory.

### Nice-to-Have Gaps (polish/best practices)

6. **No test strategy**
   - **Impact**: Low in the short term, moderate risk for network sync and
     hit registration correctness.
   - **Question**: Accept zero tests during the 15-day MVP, or define a
     minimum test set for high-risk systems (network sync, hit reg)?
   - **Suggested Action**: Defer to post-MVP unless a specific high-risk
     system surfaces; revisit at day-10 checkpoint.

7. **No game-pillars.md** — pillars are named in systems-index but not
   extracted. Low priority but useful for design-review gates.

8. **No milestone definition for day-15 release** — implicit in the concept
   but not formalized. Makes `/gate-check` harder to run.

---

## Recommended Next Steps

### Immediate Priority (Do First — today)

1. **Decide fate of `prototypes/petting-system/`** — 30 seconds
   - Manual action (delete or add README)

2. **`/sprint-plan new`** — build 15-day day-by-day plan
   - Estimated effort: M
   - Unblocks: all downstream scheduling

3. **`/architecture-decision` for ADR-0002 (Server Hosting)**
   - Suggested skill: `/architecture-decision`
   - Estimated effort: M
   - Unblocks: networking prototype, deployment setup

### Short-Term (Next 3-5 days)

4. **`/prototype networking`** — validate 10-player state sync
   - Estimated effort: L
   - Highest technical risk; must prove viability early

5. **Continue `/design-system`** for remaining 17 MVP GDDs in systems-index
   order (next up: Weapon system, Vehicle base, Class loadout)
   - Estimated effort per system: S-M

6. **`/prototype helicopter-flight`** — second-highest risk, can run in
   parallel with GDD writing

### Medium-Term (Days 5-10 of MVP)

7. Begin `src/` implementation of Foundation + Core layer systems once
   networking prototype validates the approach
8. `/milestone-review` at day 10 checkpoint to assess cut-list against scope

---

## Role-Specific Recommendations

None requested — general analysis.

---

## Follow-Up Skills to Run

Based on gaps identified, consider running:

- `/sprint-plan new` — no production plan exists, timeline is live
- `/architecture-decision` — ADR-0002 (Server Hosting) is a blocker
- `/prototype networking` — highest technical risk, unvalidated
- `/design-system [name]` — 17 MVP GDDs remaining
- `/scope-check` — if the 15-day target is slipping, identify cuts
- `/gate-check` — before transitioning Pre-Production → Production

---

## Appendix: File Counts by Directory

```
design/
  gdd/           12 files
  narrative/     0 files
  levels/        0 files

src/             0 files (empty)

docs/
  architecture/  1 ADR
  engine-reference/ (configured)

production/
  sprints/       0 plans
  milestones/    0 definitions
  session-state/ scaffold only
  session-logs/  scaffold only

tests/           0 files (empty)
prototypes/      1 directory (petting-system/, empty, undocumented)
```

---

**End of Report**

*Generated by `/project-stage-detect` skill*
