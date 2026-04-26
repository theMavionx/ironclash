# ADR-0005: Pivot to Node.js Authoritative Server

## Status

Accepted. **Supersedes ADR-0001** (Godot MultiplayerAPI + WebSocketMultiplayerPeer).

## Date

2026-04-26

---

## Context

ADR-0001 chose Godot 4.3's built-in `MultiplayerAPI` over a `WebSocketMultiplayerPeer`
in a dedicated headless Godot server topology. The reasoning was sound — server
authority comes "for free", `MultiplayerSynchronizer` handles state replication,
`@rpc` annotations dispatch events.

After bootstrapping the headless server we discovered:

1. **Iteration speed is the actual bottleneck**, not future anti-cheat. The
   project is in pre-MVP and the question we must answer is "is this game
   fun?", not "is this game cheat-resistant?". Anti-cheat is a post-MVP
   concern that we documented as accepted risk in `design/gdd/game-concept.md`.
2. **Single-language stack pays off** — the React UI is already TypeScript,
   the wire protocol is JSON, and 80 % of server work is match state, team
   assignment, lobby, scoring, and broadcasting — all pure data manipulation
   that JS does faster to iterate on than GDScript.
3. **Godot client remains** — the browser still runs Godot via WASM, so we
   keep all visual systems, terrain, vehicle physics, and animation work as
   originally planned. Only the *server* changes.
4. **Headless Godot deployment** is more complex than a Node container for a
   2-person team with no prior multiplayer ops experience.

The trade-off we are accepting:

- **Lost**: server-side raycast against real geometry. Hit validation becomes
  math-based (alive, cooldown, ammo, distance, angle, sane victim position)
  rather than a true physics raycast. A motivated cheater can fabricate hits
  through walls; HP / instakill / infinite ammo remain blocked.
- **Lost**: server-side vehicle physics. Vehicles are client-driven; the
  driver's client computes physics and sends position/rotation/velocity;
  other clients see interpolated copies. Server enforces speed clamps and
  authoritative HP/destruction, not collision response.

Both losses are acceptable for pre-MVP. Both are reversible — the wire
protocol is engine-agnostic JSON, so a future migration to a Godot
authoritative server only swaps the server implementation, not the client.

---

## Decision

The authoritative game server is a **Node.js + TypeScript process** using the
[`ws`](https://github.com/websockets/ws) library, communicating with Godot
clients over plain WebSocket frames carrying JSON messages.

### Architecture

```
┌──────────────────────────────────────────┐
│   Node.js Server (TypeScript)            │
│                                          │
│   - Match state machine                  │
│   - Team assignment (5v5, auto-balance)  │
│   - Player record (pos, rot, hp, alive)  │
│   - Snapshot broadcast @ 30 Hz           │
│   - Damage validation (math, no raycast) │
│   - Score / capture-point state          │
└──────────────────────────────────────────┘
                  │
                  │ WebSocket + JSON
                  │
┌─────────────────┼──────────────────┐
▼                 ▼                  ▼
Godot client     Godot client   ...  (up to 10)
(browser WASM)   (browser WASM)
- WebSocketPeer  (no MultiplayerAPI, no @rpc)
- Renders snapshot interpolation
- Sends transform + fire + anim_state
- Local prediction for own player only
```

### Code layout

```
shared/protocol.ts        Wire protocol (TypeScript types).
server/                   Node.js authoritative server.
  src/index.ts            Entry point.
  package.json            ws + tsx + typescript.
  tsconfig.json
src/networking/
  network_manager.gd      Godot client. Plain WebSocketPeer + JSON parser.
  network_config.gd       Resource for tunables (port, urls, team caps).
```

### Wire protocol (summary)

All messages carry a `t` discriminator. See `shared/protocol.ts` for the
canonical definition.

**Client → Server**: `hello`, `transform`, `input`, `fire`, `anim_state`,
`vehicle_enter`, `vehicle_exit`, `ping`.

**Server → Client**: `welcome`, `match_state`, `snapshot`, `player_joined`,
`player_left`, `damage`, `death`, `respawn`, `vfx_event`, `anim_event`,
`kicked`, `pong`.

### Authoritative responsibilities

The server owns:

- Player presence and team assignment.
- Health / damage / death / respawn.
- Match state machine (waiting → warmup → in_progress → post_match).
- Capture-point state and score (when implemented).
- VFX *events* (muzzle flash, bullet impact, explosion, smoke/fire start/stop) — broadcast as event packets, not particle sync.
- Animation *states* (idle / run / sprint / aim / fire / reload / death) — broadcast as state changes, not per-frame skeleton sync.

The client owns:

- Rendering, particle systems, animation playback, audio.
- Local prediction for the local player's movement (no rollback).
- Vehicle physics for the driver client; followers see interpolated transforms.

### What the server does *not* do

- Raycast hits against real map geometry — uses math validation (distance ≤ weapon range, angle ≤ tolerance, victim within sane error of last reported position).
- Vehicle physics simulation — accepts driver client's transforms, applies speed clamp.
- Pathfinding, AI — no NPCs at MVP.

---

## Consequences

### Positive

- Hot-reload server iteration loop (`tsx watch`) — change a damage formula, see effect immediately.
- Shared types between server and React UI prevent wire-protocol drift.
- Deploy is any Node host (Render, Fly, Railway, Hetzner with PM2, etc.).
- Server runs independently of Godot binary; CI doesn't need Godot installed to test server logic.
- Engine-agnostic protocol — future port to a different game client only needs the wire protocol.

### Negative

- Hit validation has a known cheat surface (wall-shots possible if client lies about origin). Documented as accepted risk for pre-MVP.
- Vehicle physics divergence is possible if driver client's WASM physics produces a different result than other clients' interpolation expects. Mitigation: server-side speed clamp, authoritative HP, periodic position correction.
- Two codebases (TS server, GDScript client) duplicate the player data model. Mitigation: `shared/protocol.ts` is the single source of truth for the wire format; in-memory representations on each side are free to differ.
- A future move to a Godot authoritative server (post-MVP if cheating becomes a problem) is a server-side rewrite. Not a refactor of clients.

### Risks

- **Risk:** Cheating breaks the competitive premise of the game.
  - **Mitigation:** This was already documented as accepted risk in ADR-0001 ("expect wallhacks/aimbots until anti-cheat is added post-MVP"). Math validation catches more than nothing — speed hacks, infinite HP, instakill, infinite ammo are blocked. Wall-shots and aimbots are not.

- **Risk:** Vehicle desync between driver and observers.
  - **Mitigation:** Driver-authoritative transforms with smoothing on observers. If desync is severe in playtest, escalate to per-vehicle authoritative position with server validation per tick.

- **Risk:** WebSocket frame overhead on JSON for 10 players × 30 Hz exceeds the 128 kbps budget from ADR-0001.
  - **Mitigation:** Measure first. If exceeded, switch to a binary protocol (msgpack or custom) without changing the topology — the wire format is the only thing that changes.

---

## Validation

This decision is considered validated when:

- [ ] 10 clients connect to the Node server and remain stable for 10+ minutes.
- [ ] Snapshot rate is 30 Hz ± 2 Hz at every client.
- [ ] Round-trip latency is < 150 ms p95 on same-region connections.
- [ ] A fire event from one client produces a muzzle_flash VFX on every other client within one tick.
- [ ] HP / death / respawn flow completes server-side and replicates correctly to all clients.
- [ ] Server CPU usage is < 30 % of one core at steady state (10 connected clients).

---

## Related

- **Supersedes:** ADR-0001 (Godot MultiplayerAPI + WebSocket dedicated server).
- **Related design docs:**
  - `design/gdd/team-assignment.md` — auto-balance, 5v5 cap, 3v3 minimum.
  - `design/gdd/match-state-machine.md` — state transitions implemented in server.
  - `design/gdd/health-and-damage-system.md` — damage formulas applied server-side.
- **Related future ADR:** ADR-0006 (post-MVP) will revisit the server authority model if anti-cheat work demands real raycast validation.
