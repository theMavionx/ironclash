# Match State Machine

> **Status**: Designed
> **Author**: Claude Code Game Studios session
> **Last Updated**: 2026-04-14
> **Implements Pillar**: Matches Start Fast (no warmup, fast transitions)

## Overview

The Match State Machine governs the lifecycle of a single match on a server.
It defines the discrete states a match passes through (waiting → warmup →
in progress → post-match) and the transitions between them. It is server-
authoritative and broadcasts the current state to all clients so HUDs,
camera, and gameplay systems can respond. Match needs minimum **3v3** to
start warmup (up to **5v5** maximum). A **60-second grace period** from the
first player connecting delays the warmup start to give time for more
players to arrive. After 3v3 is reached, the match enters **Warmup** — a
90-second practice phase where players can move and shoot but **no scoring,
no capture, instant respawn**. **Late-join IS enabled during Warmup** so
late arrivals can join up to the 5v5 cap. After Warmup ends (or 5v5
reached early), the real match (`InProgress`) begins with scores reset,
match clock starts, capture points activate, and **late-join is blocked**.

## Player Fantasy

The player should feel a clear arc per match: *I'm waiting (briefly) → the
match is on (high intensity) → it's over (results, then quickly into the
next match)*. There is no fiddly pre-match lobby, no warmup, no "waiting
for ready-up." The state machine is engineered to maximize the percentage
of the player's time in `InProgress` (active gameplay) and minimize idle
states.

## Detailed Design

### Core Rules

1. The Match State Machine runs **only on the server**. Current state is replicated to all clients via `MultiplayerSynchronizer`.
2. Four states exist: **WaitingForPlayers**, **Warmup**, **InProgress**, **PostMatch**.
3. State transitions are **server-only** decisions. Clients cannot trigger transitions.
4. Each state has explicit entry conditions and exit conditions; there is no implicit transition.
5. Match clock starts at `match_duration_seconds` on entering `InProgress`, ticks down at real time, and triggers `PostMatch` transition when it reaches 0.
6. Win condition is evaluated at `PostMatch` entry by Match Scoring System; this state machine simply triggers the evaluation.

### State Definitions

| State | Purpose | Gameplay | Scoring/Capture | Late-join | Duration |
|---|---|---|---|---|---|
| **WaitingForPlayers** | Server up; players connecting. Block all gameplay. | No | No | Yes (slot open) | Until 3v3 + grace (or 5v5 immediately) |
| **Warmup** | Practice phase. Players can move/shoot/die but no scores count. | **Yes** (move, shoot) | **No** (capture inactive, no kills counted) | **Yes** (up to 5v5) | `warmup_duration_seconds` (default 90 s) or 5v5 reached early |
| **InProgress** | Real match. All gameplay + scoring + capture. Late-join blocked. | **Yes** | **Yes** | **No** | Exactly `match_duration_seconds` (default 600 = 10 minutes) |
| **PostMatch** | Match over. Results screen. Input disabled. | No | No | No | `post_match_duration_seconds` (default 12 s) |

After `PostMatch` ends, the server **disconnects all clients** and either:
- **Recycles** for a new match (resets state to `WaitingForPlayers`, awaits new player connections), OR
- **Shuts down** (depends on hosting model — defer to ADR-0002)

### State Transitions

```
[Server starts]
     │
     ▼
┌────────────────────────────────────────────┐
│ WaitingForPlayers                          │
│ - First player connect → start grace timer │
│ - Grace timer counts down 60s              │
│ - Players continue to fill                 │
└────────────────────────────────────────────┘
     │
     │  Trigger A: both teams have ≥3 players AND grace timer reached 0
     │  Trigger B: both teams have reached 5v5 (skip warmup entirely, go straight to InProgress)
     │  Action: spawn all players, start warmup timer
     ▼
┌─────────────────────────────────────────────┐
│ Warmup                                      │
│ - Practice: move, shoot, die — no scoring   │
│ - Capture points inactive                   │
│ - Instant respawn                           │
│ - Late-join enabled (up to 5v5)             │
│ - Warmup timer counts down 90s              │
└─────────────────────────────────────────────┘
     │
     │  Trigger A: warmup timer reaches 0
     │  Trigger B: 5v5 reached during warmup (skip remaining warmup)
     │  Action: reset all scores/kills/captures, lock connections, start match clock
     ▼
┌─────────────────────────────────────────────┐
│ InProgress                                  │
│ - Match clock counts down from 600s         │
│ - Capture points active, scoring counts     │
│ - Late-join BLOCKED                         │
└─────────────────────────────────────────────┘
     │
     │  Trigger: match clock reaches 0
     │  Action: lock player input, evaluate win, broadcast results
     ▼
┌─────────────────────┐
│ PostMatch           │  ← results screen for 12s
└─────────────────────┘
     │
     │  Trigger: post-match timer reaches 0
     │  Action: disconnect all clients
     ▼
[Server recycles or shuts down]
```

**Note on Trigger B for WaitingForPlayers:** if 5v5 is reached during waiting, the match goes straight to `InProgress` skipping `Warmup` entirely (full lobby = no need to wait for more players, no need for warmup since no late-joiners possible).

### State Behaviors

**WaitingForPlayers:**
- Server accepts connections; Team Assignment auto-assigns players
- On first player connect, **grace timer** starts (default 60 s)
- Players see a "Waiting for players..." screen with current count (e.g., "5/10") and grace countdown ("Match starts in 42s")
- No gameplay systems run (no movement, no firing, no scoring)
- Camera shows menu/lobby camera
- Server polls each tick:
  - If both teams full (5v5) → transition straight to **InProgress** (skip Warmup)
  - Else if both teams have ≥3 players AND grace timer ≤ 0 → transition to **Warmup**
- If grace expires but one or both teams have <3 → grace timer **extends** by 30 s. After 3 extensions (total 150 s), if still under-populated, server times out and shuts down.

**Warmup:**
- All players are spawned at their team base
- Movement and weapons are **enabled** — players can shoot each other for aim practice
- Death has **instant respawn** (1 s timer instead of normal respawn)
- **Capture points are inactive** — cannot be captured during warmup
- **Scoring does not count** — kills and deaths are tracked locally for HUD feedback but reset to zero on InProgress entry
- **Late-join enabled** — new connections during Warmup are auto-assigned to smaller team and spawned at base with full HP
- Vehicles are present and usable (for aim practice)
- HUD shows "WARMUP" label and warmup countdown
- Server polls each tick:
  - If 5v5 reached → transition to InProgress immediately
  - Else if warmup timer ≤ 0 → transition to InProgress

**InProgress:**
- All gameplay systems active: movement, weapons, vehicles, capture points, scoring
- Match clock counts down (server authoritative; clients display via replicated value)
- Match clock visible on HUD top-center
- Capture points active and capturable
- Players respawn per Respawn System rules (normal respawn timing)
- **Late-join blocked**: new connections during InProgress are rejected with "Match in progress" message
- Disconnected players cannot rejoin
- All scores/kills are reset on entry from Warmup
- Server polls each tick: if match clock ≤ 0 → transition to PostMatch

**PostMatch:**
- All player input is **disabled** (controllers locked, weapons disabled, vehicles freeze)
- Camera switches to a fixed match-end view (top-down map view OR orbit around winning team's spawn — TBD)
- Results UI shows: winning team, final scores, individual K/D, captures
- Post-match timer counts down (12 s default)
- After timer expires: server broadcasts disconnect; clients return to main menu

### Interactions with Other Systems

- **Networking** (peer): server-authoritative state replicated via `MultiplayerSynchronizer`; transition events broadcast via `@rpc("authority")`
- **Team Assignment** (peer): assignment locks at `InProgress` entry
- **Player Controller** (downstream): reads `is_alive` AND match state; controller is disabled outside `InProgress`
- **Weapon System** (downstream): weapons disabled outside `InProgress`
- **Vehicle Controllers** (downstream): vehicles frozen outside `InProgress`
- **Capture Point System** (downstream): only active in `InProgress`
- **Respawn System** (downstream): respawns only happen in `InProgress`
- **Match Scoring** (downstream): only tracks score in `InProgress`; evaluates winner at `PostMatch` entry
- **Camera System** (downstream): switches to lobby/match-end camera per state
- **HUD** (downstream): shows match clock during `InProgress`, results screen during `PostMatch`

## Formulas

### Match clock tick

```
on_server_tick (30 Hz):
    if state == InProgress:
        match_clock -= delta_time
        if match_clock <= 0:
            match_clock = 0
            transition_to(PostMatch)

    elif state == PostMatch:
        post_match_clock -= delta_time
        if post_match_clock <= 0:
            recycle_or_shutdown_server()
```

### Transition guard (WaitingForPlayers → Warmup or InProgress)

```
if state == WaitingForPlayers:
    // Trigger: full lobby (5v5) — skip Warmup, go to InProgress
    if team_a.members.size() >= team_max_players and
       team_b.members.size() >= team_max_players:
        transition_to(InProgress)
        return

    // Trigger: min players present AND grace period elapsed → Warmup
    if team_a.members.size() >= team_min_players_to_start and
       team_b.members.size() >= team_min_players_to_start and
       grace_timer <= 0:
        transition_to(Warmup)
        return

    // Grace expired but under-populated → extend grace
    if grace_timer <= 0 and grace_extensions_used < 3:
        grace_timer = grace_extension_seconds   // 30s
        grace_extensions_used += 1
    elif grace_timer <= 0 and grace_extensions_used >= 3:
        shutdown_server("No match formed within timeout")
```

### Transition guard (Warmup → InProgress)

```
if state == Warmup:
    // Trigger A: full lobby reached during warmup — start immediately
    if team_a.members.size() >= team_max_players and
       team_b.members.size() >= team_max_players:
        reset_scores_and_kills()
        transition_to(InProgress)
        return

    // Trigger B: warmup timer expired
    if warmup_timer <= 0:
        reset_scores_and_kills()
        transition_to(InProgress)
        return
```

### Timer ticks

```
on_server_tick (30 Hz):
    if state == WaitingForPlayers:
        if total_players_connected >= 1 and grace_timer_started == false:
            grace_timer = grace_period_seconds   // 60s
            grace_timer_started = true
        if grace_timer_started:
            grace_timer -= delta_time

    elif state == Warmup:
        warmup_timer -= delta_time

    elif state == InProgress:
        match_clock -= delta_time
        if match_clock <= 0:
            transition_to(PostMatch)

    elif state == PostMatch:
        post_match_clock -= delta_time
        if post_match_clock <= 0:
            recycle_or_shutdown_server()
```

### Connection handling

```
on_player_connect(player):
    if state == WaitingForPlayers:
        if total_players_in_match < (team_max_players * 2):
            assign_to_smaller_team(player)
        else:
            reject_connection(player, "Match full")

    elif state == Warmup:
        if total_players_in_match < (team_max_players * 2):
            assign_to_smaller_team(player)
            spawn_at_team_base(player)   // full HP, instant
        else:
            reject_connection(player, "Match full")

    elif state == InProgress:
        reject_connection(player, "Match in progress")

    elif state == PostMatch:
        reject_connection(player, "Match ended")
```

### Score / kill reset on Warmup → InProgress

```
function reset_scores_and_kills():
    for player in all_players:
        player.kills = 0
        player.deaths = 0
        player.captures = 0
        player.damage_dealt = 0
        // HP is also reset to full and players respawn at team base
        respawn_at_team_base(player, full_hp=true)

    team_a.score = 0
    team_b.score = 0

    for capture_point in capture_points:
        capture_point.owning_team = null   // neutral
        capture_point.capture_progress = 0
        capture_point.contesting_teams = []
```

## Edge Cases

- **All players disconnect during `InProgress`** → match continues until clock expires; server recycles. No late-join repopulation.
- **All players disconnect during `Warmup`** → server resets to `WaitingForPlayers` (since no match was officially "started")
- **Player disconnects during `PostMatch`** → no impact
- **Player disconnects during Warmup** → slot stays open and can be filled by late-joiner (since Warmup allows late-join)
- **Player connects exactly at Warmup→InProgress transition** → if connection completes before transition, joins; if after, rejected with "Match in progress"
- **Match clock manipulation attempt** → ignored; server-authoritative
- **Server lag spike** → all timers use real time deltas, not tick counts
- **InProgress entered with fewer than min players** (server logic bug) → fail-safe: re-check at entry; if check fails, snap back to WaitingForPlayers
- **Match clock reaches 0 in tied score** → tie broken by Match Scoring System
- **All players on one team disconnect during InProgress** (5v0) → match continues; populated team runs up score
- **Grace timer expires with <3 on a team** → grace extends 30 s. Up to 3 extensions (total 150 s). Then server shuts down.
- **Warmup timer expires but match has only 3v3** → still transitions to InProgress with 3v3 (warmup served its purpose; remaining slots stay empty)
- **Player tries to capture a point during Warmup** → capture system rejects (capture inactive in Warmup)
- **Vehicle damage during Warmup** → vehicles take damage normally and can be destroyed; on InProgress entry, vehicles **respawn to full HP** at their original positions (since match scores reset, vehicles also reset)
- **Server forcibly killed mid-match** → no graceful handling; clients see connection-lost

## Dependencies

**Upstream:**
- **Networking** — RPC dispatch and state sync
- **Team Assignment** — provides team member counts for transition guard

**Downstream (hard):**
- **Player Controller** — reads state for enable/disable
- **Weapon System** — reads state for fire-disable outside InProgress
- **Vehicle Controllers** — reads state for freeze outside InProgress
- **Capture Point System** — reads state for activity gating
- **Respawn System** — reads state to gate respawns
- **Match Scoring** — reads state to gate scoring; receives PostMatch trigger to evaluate winner
- **HUD** — reads state for displayed UI (waiting screen / match clock / results screen)
- **Camera System** — reads state for camera mode

## Tuning Knobs

| Knob | Range | Default | Effect |
|---|---|---|---|
| `match_duration_seconds` | 300 – 1200 | 600 | 10-minute InProgress match length |
| `warmup_duration_seconds` | 30 – 180 | **90** | Warmup length (from 3v3 reached) |
| `warmup_respawn_delay_seconds` | 0 – 5 | **1** | Instant respawn during Warmup |
| `post_match_duration_seconds` | 5 – 30 | 12 | Results screen time |
| `team_min_players_to_start` | 1 – 5 | **3** | Min per team to enter Warmup |
| `team_max_players` | 3 – 8 | 5 | 5v5 cap |
| `grace_period_seconds` | 30 – 120 | **60** | Wait time after first player connects before Warmup starts |
| `grace_extension_seconds` | 15 – 60 | **30** | Additional wait if min not met when grace expires |
| `grace_max_extensions` | 1 – 5 | **3** | Max grace extensions before server gives up |
| `late_join_enabled_in_warmup` | bool | **true** | Late-join allowed during Warmup |
| `late_join_enabled_in_progress` | bool | **false** | Late-join blocked during InProgress (MVP) |
| `recycle_server_after_match` | bool | true | Server recycles or shuts down after PostMatch |
| `connection_timeout_in_waiting_seconds` | 60 – 600 | 300 | Max WaitingForPlayers time before server timeout |

## Visual/Audio Requirements

- **WaitingForPlayers screen**: full-screen overlay, "Waiting for players... 5/10" + grace timer "Warmup starts in 0:42", subtle background music
- **Warmup HUD label**: "WARMUP" text top-center with countdown "Match starts in 1:23"
- **Warmup-end audio cue**: subtle "match starting" cue 5 s before InProgress
- **Match-start audio sting**: horn/whistle sound at InProgress entry; "FIGHT!" text flashes briefly
- **Late-join during warmup**: subtle "join" sound for the joining player only (not broadcast to existing players)
- **Match clock visual**: top-center HUD, MM:SS format. Last 30 seconds: text turns yellow. Last 10 seconds: red + audio countdown ticks.
- **Match-end sting**: "MATCH OVER" text flash; victory or defeat fanfare based on local player's team result
- **Results screen audio**: subtle background music; no in-game ambient

## UI Requirements

- **WaitingForPlayers UI**: centered text "Waiting for players... 5/10", grace countdown "Warmup starts in 0:42", possibly tip-of-the-day rotating
- **Warmup UI**: standard HUD visible BUT scoreboard greyed out / hidden, top-center shows "WARMUP — Match starts in 1:23", capture point indicators show "Inactive during warmup"
- **Match clock**: HUD top-center, always visible during InProgress
- **PostMatch results screen** (full-screen overlay):
  - "VICTORY" or "DEFEAT" header (based on local team)
  - Winning team name + score
  - Loser team score
  - Per-player stat table (K/D, captures, damage)
  - "Returning to menu in [X]s..." countdown

## Acceptance Criteria

- [ ] State transitions only happen server-side; clients cannot force them
- [ ] WaitingForPlayers blocks all gameplay (movement, fire, capture)
- [ ] Grace timer starts on first player connect, ticks down 60 s
- [ ] If 5v5 reached during waiting → skip Warmup, go straight to InProgress
- [ ] Else after grace expires with ≥3v3 → enter Warmup
- [ ] Warmup enables movement and shooting but NOT capture or scoring
- [ ] Warmup respawn is instant (1 s)
- [ ] Late-join works during Warmup; player spawns at base full HP
- [ ] Warmup ends after 90 s OR when 5v5 reached
- [ ] On Warmup → InProgress: scores, kills, captures all reset to zero
- [ ] On Warmup → InProgress: vehicles respawn to full HP at original positions
- [ ] On Warmup → InProgress: all players respawn at team base full HP
- [ ] InProgress: connections rejected with "Match in progress"
- [ ] InProgress: capture and scoring work
- [ ] PostMatch disables all player input, holds clients 12 s, then disconnects
- [ ] Match clock counts down accurately (verified against wall clock — drift < 0.5 s over 10 min)
- [ ] All clients see the same state at the same time (within one network tick)
- [ ] After PostMatch, all clients are disconnected within 1 s
- [ ] Server recycles to WaitingForPlayers if `recycle_server_after_match` is true
- [ ] No gameplay system runs outside InProgress (audited per system)
- [ ] Connection timeout in WaitingForPlayers triggers if no players join within 5 min (server self-shuts)

## Open Questions

- **Tiebreaker on equal score**: decision deferred to Match Scoring GDD (probably: most kills wins; if also tied, Team A wins by default)
- **Early surrender / vote to forfeit**: not at MVP. 5v0 plays out the full 10 minutes.
- **Match length tuning**: 10 min is a guess. May tighten to 8 min or extend to 12 min after playtest. Tunable.
- **Reconnection during match**: not supported at MVP. Disconnected = out for the match. Reconnection attempts during InProgress are rejected like any other connection attempt.
- **Late-join post-MVP**: if "no late-join" hurts player retention, this can be added post-MVP. Adds netcode complexity (sync world state to late client) but is a known feature path.
- **Pause / time-out**: no pause mechanic. Match clock runs continuously.
- **Server hosting model** (recycle vs shutdown): tied to ADR-0002. Default is "recycle"; ADR-0002 will finalize.
- **Spectator mode** (watching matches without playing): post-MVP.
