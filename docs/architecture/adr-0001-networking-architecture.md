# ADR-0001: Networking Architecture

## Status
Accepted

## Date
2026-04-14

---

## Context

### Problem Statement

Ironclash is a 5v5 browser-based competitive shooter with combined-arms combat
(infantry + tank + helicopter). Every gameplay system — movement, shooting,
vehicles, capture points, scoring — depends on some form of network
synchronization between clients and a central authority. This decision must be
made FIRST, before any other system is designed or implemented, because 13 of
the 28 MVP systems have a direct dependency on the networking layer.

The 15-day MVP timeline, the 2-person AI-assisted team with no prior
multiplayer experience, and the browser-only target platform severely
constrain the design space. We need a networking approach that:

1. Can be implemented and stabilized in under a week
2. Is server-authoritative enough to support future anti-cheat
3. Works within Godot 4.3's HTML5 export limits
4. Is simple enough for an inexperienced team to debug

### Constraints

**Technical:**
- Godot 4.3 HTML5 export has **no native ENet support** over web (no UDP)
- Browsers disallow threading for WebAssembly in most practical configurations
- Browsers limit concurrent WebSocket connections per origin (6 typical)
- WebAssembly overhead adds per-frame cost; server-side physics is not an option for clients
- No access to low-level socket tuning in browser sandbox

**Timeline:**
- 15-day MVP target (accepted risk per `design/gdd/game-concept.md`)
- Networking must be functional by day 5 to unblock systems 6-28
- No time for custom replication protocols

**Resource:**
- 2 developers, AI-assisted ("vibe coding" workflow)
- No prior multiplayer shipping experience on the team
- Limited server operations experience

**Compatibility:**
- Must support modern evergreen browsers (Chrome, Firefox, Edge, Safari)
- Must support mid-range laptops as the client baseline
- Server hosting decision is deferred to **ADR-0002** but must be compatible with this networking choice

### Requirements

- **Must support 10 concurrent players per match** (5v5)
- **Must tolerate variable latency** (80-200 ms typical)
- **Must be server-authoritative** for health, damage, capture-point state, and position validation (Pillar 1: *Skill Is The Ceiling* — clients cannot be trusted)
- **Must perform within a 128 kbps per-client bandwidth budget**
- **Must complete a full state-sync tick in <20 ms server-side** (to maintain 30 Hz)
- **Must integrate cleanly with Godot 4.3 node/scene architecture**
- **Must allow future addition of client prediction and lag compensation** without architectural rewrite

---

## Decision

Ironclash will use **Godot 4.3's built-in `MultiplayerAPI` with a `WebSocketMultiplayerPeer` transport** in a **dedicated-server topology** with **full server authority**. State synchronization will be handled primarily through **`MultiplayerSynchronizer`** nodes and **RPCs** for discrete events. The server will run at **30 Hz**; clients will render at 60 Hz with **interpolation** between received snapshots. **No client-side prediction and no lag compensation will be implemented at MVP.**

### Architecture Diagram

```
            ┌─────────────────────────────────────────┐
            │       Dedicated Server (headless Godot) │
            │                                         │
            │   ┌─────────────────────────────────┐   │
            │   │  MultiplayerAPI (server peer)   │   │
            │   │  - Authoritative world state    │   │
            │   │  - 30 Hz simulation tick        │   │
            │   │  - Hit resolution               │   │
            │   │  - Capture-point state machine  │   │
            │   │  - Damage pipeline              │   │
            │   └─────────────────────────────────┘   │
            │              ▲                          │
            │              │ WebSocket (WSS)          │
            └──────────────┼──────────────────────────┘
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
        ▼                  ▼                  ▼
   ┌─────────┐        ┌─────────┐        ┌─────────┐
   │ Client 1│        │ Client 2│  ...   │Client 10│
   │ (browser│        │ (browser│        │ (browser│
   │  WASM)  │        │  WASM)  │        │  WASM)  │
   │         │        │         │        │         │
   │ Render  │        │ Render  │        │ Render  │
   │ 60 Hz   │        │ 60 Hz   │        │ 60 Hz   │
   │ Interp  │        │ Interp  │        │ Interp  │
   └─────────┘        └─────────┘        └─────────┘
```

**Flow:**
1. Client sends **input state** (move vector, aim vector, fire/reload flags) at 30 Hz via RPC
2. Server applies inputs to authoritative simulation
3. Server broadcasts **synchronized state** (positions, HP, capture progress) at 30 Hz via `MultiplayerSynchronizer`
4. Client **interpolates** between the two most recent snapshots for smooth 60 Hz rendering
5. Discrete events (hit confirm, kill, capture captured) fire via `@rpc("authority")` annotated functions

### Key Interfaces

**Client → Server (RPCs, "any_peer" with server-side validation):**
```gdscript
@rpc("any_peer", "call_local", "unreliable_ordered")
func submit_input(input_state: PackedByteArray) -> void

@rpc("any_peer", "call_remote", "reliable")
func request_enter_vehicle(vehicle_id: int) -> void

@rpc("any_peer", "call_remote", "reliable")
func request_exit_vehicle() -> void
```

**Server → Client (RPCs, "authority"):**
```gdscript
@rpc("authority", "call_remote", "reliable")
func on_player_killed(victim_id: int, killer_id: int, weapon: String) -> void

@rpc("authority", "call_remote", "reliable")
func on_capture_point_captured(point_id: int, team: int) -> void

@rpc("authority", "call_remote", "reliable")
func on_match_ended(winning_team: int, scores: Dictionary) -> void
```

**Continuous state replication (MultiplayerSynchronizer, server authority):**
- Player: `position`, `aim_rotation`, `health`, `class_id`, `weapon_id`, `vehicle_id`
- Vehicle: `position`, `rotation`, `health`, `driver_id`, `passengers`
- Capture point: `owning_team`, `capture_progress`, `contesting_teams`
- Match: `state`, `time_remaining`, `team_a_score`, `team_b_score`

---

## Alternatives Considered

### Alternative 1: WebRTC Peer-Host (one player hosts)

- **Description**: Use `WebRTCMultiplayerPeer`; one client is promoted to "host" and acts as authority for the other 9 clients. STUN/TURN server required for NAT traversal; a signaling server is needed for initial handshake.
- **Pros**:
  - Zero server hosting cost per match
  - No dedicated server deployment pipeline needed
  - Lower initial infrastructure complexity
- **Cons**:
  - Host leaves = match ends (catastrophic UX for a competitive game)
  - Host has first-player advantage (zero latency to authority)
  - Trivially cheatable — host controls world state
  - Violates Pillar 1 ("Skill Is The Ceiling") — host ping = 0 means host wins aim duels unfairly
  - TURN relay costs when peer-to-peer fails can exceed dedicated server cost
  - Godot WebRTC implementation in HTML5 export is less battle-tested than WebSockets
- **Rejection Reason**: Incompatible with the competitive integrity required by Pillar 1. No shipped competitive shooter uses peer-host for good reason.

### Alternative 2: Custom WebSocket Protocol with Hand-Rolled Replication

- **Description**: Bypass `MultiplayerAPI` entirely. Write a custom binary protocol over `WebSocketPeer`, implement snapshot delta encoding, priority-based interest management, and manual RPC dispatch.
- **Pros**:
  - Maximum control over bandwidth and CPU
  - Optimal per-player bandwidth with delta encoding
  - Opportunity to implement things like Glenn Fiedler-style rollback from day one
- **Cons**:
  - Estimated 3-4 weeks of dev time minimum
  - 15-day MVP is incompatible with this timeline
  - Very high bug surface for an inexperienced team
  - Requires re-inventing what Godot MultiplayerAPI already provides adequately
- **Rejection Reason**: Timeline disqualifies this entirely.

### Alternative 3: ENet over WebAssembly (custom build)

- **Description**: Build a custom WASM port of ENet or use community builds to enable UDP-like semantics in the browser.
- **Pros**:
  - UDP-style unreliable delivery (better for real-time)
  - Existing Godot ENet code paths can be reused
- **Cons**:
  - No browser supports UDP directly; any "ENet over WebAssembly" is actually WebSockets or WebRTC under the hood with extra indirection
  - Experimental, not production-ready in Godot 4.3
  - Adds a custom build pipeline the team cannot maintain
- **Rejection Reason**: Not a real option — browsers don't expose UDP.

### Alternative 4: Godot MultiplayerAPI + WebRTC (dedicated server over WebRTC)

- **Description**: Same server-authoritative architecture but use WebRTC `DataChannel` for unreliable-ordered delivery instead of WebSocket's TCP-backed reliability.
- **Pros**:
  - Better real-time characteristics (packet loss doesn't head-of-line-block like TCP)
  - Same authority model as chosen option
- **Cons**:
  - Requires a signaling server plus the game server
  - Godot WebRTC in HTML5 export has more reported issues than WebSockets in 4.3
  - Team has no WebRTC experience
  - Adds a STUN/TURN fallback requirement
- **Rejection Reason**: Too many moving parts for the 15-day timeline. May revisit post-MVP if WebSocket head-of-line blocking becomes a measurable problem.

### Alternative 5: Client-Authoritative with Server Validation

- **Description**: Clients send their own position and shot outcomes to the server, which periodically validates "is this plausible?" with heuristics.
- **Pros**:
  - Feels extremely responsive (zero input latency)
  - Easier to implement
- **Cons**:
  - Wide-open cheat surface (speed hacks, teleport, instakill)
  - Heuristic validation is a losing arms race
  - Violates Pillar 1 immediately
- **Rejection Reason**: Cheating would destroy the competitive premise of the game. Non-starter.

---

## Consequences

### Positive

- **Fast implementation path** — Godot's `MultiplayerAPI` handles peer connection, RPC dispatch, and synchronized variable replication out of the box. Expected networking layer stand-up: 3-4 days.
- **Server-authoritative foundation** — anti-cheat, lag compensation, and client prediction can be added later without restructuring the architecture.
- **Clean integration with Godot** — every gameplay system author can use familiar Godot networking patterns (`@rpc` annotation, `MultiplayerSynchronizer` nodes).
- **Deterministic competitive outcomes** — server is the single source of truth; no host advantage, no client divergence.
- **Testable** — server can be run headless, allowing automated multi-client integration tests.
- **Free upgrade path** — if WebRTC becomes necessary for real-time feel post-MVP, most of the code (RPCs, Synchronizers) ports with transport swap only.

### Negative

- **Perceived latency on every action** — without client prediction, every input has a ~80-150 ms round-trip delay before visible feedback. Shots, movement, vehicle controls all feel slightly delayed. This will be the #1 complaint from playtesters.
- **Hit registration feels inconsistent** — without lag compensation, shots that felt "on target" on the client may miss on the server if the target has moved. Expect frustration from players with >80 ms ping.
- **TCP head-of-line blocking** — WebSocket is TCP-backed. A dropped packet delays every subsequent message until retransmission. On a lossy connection, gameplay can stutter.
- **Server cost scales linearly** — every concurrent match requires a server process. Hosting economics must be worked out in ADR-0002 before launch.
- **Regional fragmentation** — to keep latency acceptable we must run servers in multiple regions and only match players to same-region servers. Cross-region matching is disabled at MVP.
- **30 Hz may be insufficient for helicopter** — helicopters move faster and rotate more continuously than infantry; 30 Hz interpolation may look jittery. We accept this risk; benchmarked in the helicopter prototype.

### Risks

- **Risk:** WebSocket message throughput in HTML5 export hits browser-imposed limits with 10 clients.
  - **Mitigation:** Prototype day 1-2 with 10 simulated peers, measure actual throughput. Fall back to message batching if needed.

- **Risk:** 30 Hz tick + no prediction feels so bad playtesters reject the game.
  - **Mitigation:** Day 10 playtest checkpoint. If feel is unacceptable, spike a basic input prediction for the local player (position only, no rollback) as emergency polish. Budget: 2 days.

- **Risk:** Godot `MultiplayerSynchronizer` has known edge cases around late-joining peers and vehicle ownership transfer.
  - **Mitigation:** Defer late-join support to post-MVP; players who disconnect do not reconnect to the same match. Vehicle ownership uses explicit RPC request + server assignment rather than auto-transfer.

- **Risk:** Server crashes mid-match leave clients in undefined state.
  - **Mitigation:** No graceful reconnection at MVP. Clients receive a "server ended" message and return to main menu. Document as known issue.

- **Risk:** Cheating emerges within days of public release (no anti-cheat at MVP).
  - **Mitigation:** Accepted, documented. Server authority prevents the worst classes of cheat (teleport, infinite HP, instakill). Wallhacks and aimbots are expected until anti-cheat is added post-MVP.

---

## Performance Implications

- **CPU (server):** Target <15 ms per tick at 30 Hz (so server is <45% loaded). 10-player physics + hit resolution + capture-point updates should fit comfortably.
- **CPU (client):** Target <4 ms per frame for network input/output + interpolation math. Remaining 12 ms of 16.6 ms frame budget for rendering, input, game logic.
- **Memory (server):** <256 MB per match process. Allows many matches per server VM.
- **Memory (client):** Negligible overhead — `MultiplayerSynchronizer` instances are small.
- **Load Time:** No network-layer impact on initial load time; first connection handshake <500 ms on good connection.
- **Network:** Target bandwidth budget — **128 kbps per client**, **1.28 Mbps per match egress** on server.
  - Player state: ~60 bytes × 10 players × 30 Hz = 18 kbps inbound to each client for other players
  - Own input: ~20 bytes × 30 Hz = 5 kbps outbound per client
  - Vehicle state (up to 2 active): ~80 bytes × 2 × 30 Hz = 5 kbps
  - RPC events (kills, captures): bursty, ~5 kbps average
  - Comfortable headroom within the 128 kbps budget

---

## Migration Plan

This is a greenfield decision — no existing networking code to migrate. Implementation phases:

1. **Day 1:** Bootstrap headless Godot server process. Verify local WebSocket connection from a test client.
2. **Day 2:** Wire up `MultiplayerSpawner` for player scenes. Basic player join/leave events.
3. **Day 3:** Implement input-submission RPC and position-sync via `MultiplayerSynchronizer`. Two-client local test.
4. **Day 4:** 10-client load test on localhost. Measure bandwidth and CPU. Tune tick rate if needed.
5. **Day 5:** Remote deployment test (single region). Measure real-world latency.
6. **Day 5+:** All other gameplay systems can now be built on top of this foundation.

---

## Validation Criteria

This decision is considered **validated** when:

- [ ] 10 clients successfully connect to a dedicated server and maintain stable connection for 10+ minutes
- [ ] State updates are received at a measured 30 Hz (±2 Hz) by all clients
- [ ] Round-trip latency is **<150 ms p95** on same-region connections
- [ ] Per-client bandwidth is **<128 kbps** in a full 5v5 match with vehicles active
- [ ] Server CPU usage is **<50%** of one core at 30 Hz tick with 10 clients
- [ ] A player shooting another player results in consistent damage on both clients within one tick (no desync)
- [ ] Playtest feedback on "shooting feel" is **tolerable** (not "excellent" — that requires prediction/lag-comp added later)

Validation playtest scheduled: **Day 10** of 15.

---

## Related Decisions

- **ADR-0002: Server Hosting & Deployment** (pending) — This decision determines HOW the dedicated server is provisioned, hosted, scaled, and paid for. It is blocked on ADR-0001 being locked.
- **ADR-0003: Client Prediction Strategy** (future, post-MVP) — When we add client prediction, it will build on this architecture without replacing it.
- **ADR-0004: Anti-Cheat Approach** (future, post-MVP) — Server authority established here is the foundation for future anti-cheat work.

### Related Design Documents

- `design/gdd/game-concept.md` — Game concept, Pillar 1 establishes server-authoritative requirement
- `design/gdd/systems-index.md` — Systems Index, Networking layer listed as highest-risk bottleneck (13 dependents)
