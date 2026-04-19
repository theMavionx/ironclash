# Quick-Play Matchmaking

> **Status**: Draft (8/8 sections filled)
> **Author**: AI-assisted draft
> **Last Updated**: 2026-04-18
> **Implements Pillar**: Pillar 3 — *Matches Start Fast* (click Play → in match; zero friction)
> **MVP Scope**: Hardcoded single-server URL. Click "Play" → connect → auto-join first non-full match OR wait for next. No skill-based matching, no region selection, no friend queue, no lobbies.

## Overview

Quick-Play Matchmaking is the glue between the Main Menu and the live match.
It runs entirely on the client's side of the connection at MVP — a hardcoded
WebSocket URL points to the single dedicated game server. When the player
clicks "Play" on the main menu with a valid name, the client opens a
WebSocket connection, performs a handshake with the server, and is assigned
either (a) a slot in a currently-running match (joining in progress) or
(b) a waiting slot in the next-starting match. Team is assigned by the
server using auto-balance (smaller team gets the joiner). The player's
class selection is deferred to the respawn UI on death — no class is
chosen before spawn. Match start occurs when the player count crosses the
`min_players_to_start` threshold, or after a `warmup_max_duration` timeout.
All session lifecycle messages (connection lost, match ended, kicked) are
authoritative on the server.

## Player Fantasy

The fantasy is that there is **no matchmaking experience** — the player
sees a button, clicks it, sees a brief spinner, and is playing. No
lobby browser, no room codes, no "add friend" step, no loadout screen, no
class picker. The friction between "I want to play" and "I am shooting"
is measured in seconds, not screens. If the player needs to join a
half-finished match, they do so silently; if they need to wait for
others, a subtle "waiting for players" indicator is the only interruption.
Quick-Play feels like stepping into an arcade cabinet — coin in, play.

## Detailed Design

### Core Rules

1. The client knows one server URL, set at build time in a config resource (`assets/data/server_config.tres`). No server list, no region selector at MVP.
2. The client initiates a WebSocket Secure (WSS) connection to the server on "Play" click. Per ADR-0001, all connections go through Godot's `MultiplayerAPI` with `WebSocketMultiplayerPeer` transport.
3. The server assigns each connected client a **peer ID** and broadcasts a join event.
4. Handshake payload from client on connect contains: `display_name` (sanitized player name string, 3-16 chars), `client_version`, `preferred_class_hint` (optional, for future use).
5. The server assigns the joining client to a **match slot**. Match slot assignment logic:
   - If an ACTIVE match exists with spare capacity (< `max_players_per_match` == 10): join this match as an in-progress joiner. Assigned team is the side with fewer players (auto-balance). Ties broken by coin flip.
   - Else if a WARMUP match exists (not yet started) with spare capacity: join the WARMUP pool. Same team auto-balance.
   - Else: server creates a new match in WARMUP state, client is the first joiner.
6. **Maximum 1 active match per server at MVP.** If the active match is full and another player connects, they enter a WAITING slot (queue) and will join the next WARMUP or in-progress match.
7. WAITING queue is FIFO. When a slot opens (disconnect, match end), the head of the queue is routed in.
8. Match begins when either of these conditions triggers:
   - Player count reaches `min_players_to_start` (default 4 — 2v2 minimum)
   - OR `warmup_max_duration` (default 60s) elapses since the first player joined, and player count ≥ 2
9. While in WARMUP, players may move and test mechanics but scoring does not accumulate (see match-scoring.md rule 1).
10. On match transition WARMUP → ACTIVE: all players spawn at their team base with full HP/ammo; match timer begins counting down from `match_duration_seconds`.
11. On match transition to END: all players shown the end screen for `end_screen_duration` (default 15s), then automatically re-queued for a new match (unless they click "Return to Menu").
12. Auto-requeue behaviour: after END, the client re-enters the matchmaking flow as if the player had just clicked "Play" — new match slot, new WARMUP.
13. Player name conflict handling: if two clients connect with the same `display_name`, the server appends `#<peer_id_tail>` (e.g., `Dex` + `Dex#42`). Client reads its authoritative name back from the server.
14. Connection loss (WebSocket closed, timeout): player is removed from the match; no reconnection at MVP per ADR-0001. Client displays "Disconnected" screen with "Back to Menu" button.
15. Client version mismatch on handshake: server rejects with specific error code, client displays "Update required" message.
16. Minimum client version is embedded in the server's config and checked at handshake time.
17. If the match ends while a client is still in WARMUP of that match (unusual edge case), the client is moved to the next WARMUP match.

### Team Auto-Balance Algorithm

When a client needs team assignment:

```
count_a = count_alive_players(TEAM_A) + count_warmup_players(TEAM_A)
count_b = count_alive_players(TEAM_B) + count_warmup_players(TEAM_B)

if count_a < count_b:
    assign TEAM_A
elif count_b < count_a:
    assign TEAM_B
else:
    assign random choice of TEAM_A / TEAM_B
```

Team assignment is **one-way** at MVP — a player cannot switch teams mid-match or on respawn.

### States and Transitions (Client View)

| State | Entry | Exit | Behavior |
|-------|-------|------|----------|
| MenuIdle | Main menu load | "Play" clicked with valid name | Main menu visible, matchmaking inactive |
| Connecting | "Play" clicked | Connection success OR failure | Spinner + "Connecting..." |
| Handshaking | WebSocket open | Server assigns slot OR rejects | Brief; normally < 500 ms |
| Waiting (queued) | Active match full | Slot opens for this client | "Waiting for match..." + queue position |
| InWarmup | Server assigns to WARMUP match | Match enters ACTIVE | Player in-world but scoring inactive |
| InMatch | WARMUP → ACTIVE transition | ACTIVE → END transition | Normal gameplay |
| PostMatch | Match END state | "Play Again" OR timeout auto-requeue OR "Return to Menu" | End screen + buttons |
| Disconnected | Connection dropped | User clicks "Back to Menu" | Error screen |

### Interactions with Other Systems

| System | Interaction | Direction |
|--------|-------------|-----------|
| **Main menu** | Provides display name, triggers matchmaking | Main menu → Matchmaking |
| **Networking (ADR-0001)** | Opens/closes WebSocket connection, routes all RPCs | Matchmaking ↔ Networking |
| **Match state machine** | Receives WARMUP/ACTIVE/END state signals | Match state ↔ Matchmaking |
| **Team assignment** | Receives auto-balance result from matchmaking | Matchmaking → Team |
| **Respawn system** | Player first-spawn occurs at WARMUP entry or ACTIVE match join | Matchmaking → Respawn |
| **HUD** | Displays matchmaking-state messages (Waiting, Disconnected) | Matchmaking → HUD |
| **Post-match summary UI** | Shown at END; has "Play Again" button that triggers re-queue | Post-match ↔ Matchmaking |
| **Audio system** | Plays connection jingle, disconnect sting | Matchmaking → Audio |
| **Web export & asset loading** | Loads main menu and in-game scenes; pre-loads game scene during matchmaking spinner | Web export ↔ Matchmaking |

## Formulas

### Warmup Start Trigger

```
on_warmup_tick():
    if players_in_warmup >= min_players_to_start:
        transition_to_active()
    elif warmup_elapsed >= warmup_max_duration and players_in_warmup >= 2:
        transition_to_active()
```

**MVP values**: `min_players_to_start = 4`, `warmup_max_duration = 60s`, minimum for auto-start after timeout = 2.

### Queue Position Display

```
queue_position = waiting_queue.index_of(client) + 1
estimated_wait_seconds = queue_position × average_slot_open_rate
```

`average_slot_open_rate` is a rolling average maintained by the server based on disconnects per minute. MVP implementation may simply display queue position without a time estimate.

### Tuning Variables

| Variable | Type | MVP Value |
|----------|------|-----------|
| `max_players_per_match` | int | 10 (5v5) |
| `min_players_to_start` | int | 4 (2v2 minimum) |
| `warmup_max_duration` | float (s) | 60.0 |
| `end_screen_duration` | float (s) | 15.0 |
| `handshake_timeout_seconds` | float (s) | 10.0 |
| `display_name_min_length` | int | 3 |
| `display_name_max_length` | int | 16 |

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Server unreachable at "Play" click | Client shows "Server unreachable — try again later" after 10 s timeout | Graceful failure with retry option |
| Server reachable but full (active match + full queue) | Queue has no hard cap at MVP; client joins end of queue. UI shows position. | Accept unbounded queue at MVP scale |
| Player enters empty name and clicks Play | Button disabled until name meets minimum length | Input validation on client + re-validated on server |
| Player enters name > 16 chars | Input field hard-caps to 16 characters | Client-side truncation |
| Player name contains control characters or whitespace extremes | Server sanitizes by stripping non-printable and trimming whitespace; rejects handshake if result < 3 chars | Anti-abuse |
| Duplicate name on same server | Server appends `#XX` tag (last 2 digits of peer ID) | Keeps display readable |
| Profanity in name | No filter at MVP. Accept risk. | Deferred to moderation tooling post-MVP |
| Match starts with only 2 players (minimum after 60s timeout) | Match runs; auto-balance places 1 per team | Playable over empty |
| Match active, all 10 players connected, then 1 disconnects | Match continues. Respawn queue may generate imbalance but is not corrected mid-match at MVP. | Per ADR-0001, no backfill or rebalance at MVP |
| Match active, 4 players on Team A, 5 on Team B. New joiner arrives. | Routed to Team A for balance | Auto-balance logic |
| Client clicks "Play Again" at end of match | Same client reconnects to a new WARMUP match; this is a full new handshake | No "session persistence" at MVP |
| Client clicks "Return to Menu" at end | Full disconnect from server; returns to main menu | Clean teardown |
| Client crashes mid-match | Same as disconnect — server removes after timeout | Treated as abrupt disconnect |
| Server process restarts while clients connected | All clients drop to "Disconnected" screen | No reconnect at MVP |
| Player at top of queue connects, but match ends simultaneously | Player is routed to the new WARMUP match that forms immediately | Race condition handled by server scheduling |
| Two players in the WAITING queue; active match ends; new WARMUP created | Both waiting players are routed into the new WARMUP in FIFO order | Standard queue drain |
| Client version < server minimum | Handshake rejected with UPDATE_REQUIRED code; client displays update message | Version control |
| Client version > server (beta client vs prod server) | Accepted (forward compatibility, server is tolerant) | Allow canary clients |

## Dependencies

| System | Direction | Nature |
|--------|-----------|--------|
| Main menu | Matchmaking depends on Main menu | Name input, Play trigger |
| Networking (ADR-0001) | Matchmaking depends on Networking | Connection, handshake, state replication |
| Match state machine | Matchmaking ↔ Match state | State transitions |
| Team assignment | Matchmaking → Team | Sets team on join |
| Respawn system | Matchmaking → Respawn | Initial spawn trigger |
| HUD | HUD depends on Matchmaking | Waiting / Disconnected messages |
| Post-match summary UI | Post-match depends on Matchmaking | Play Again re-queue |
| Web export & asset loading | Matchmaking depends on Web export | Scene pre-load during spinner |
| Audio system | Audio depends on Matchmaking | Connection jingles |

## Tuning Knobs

| Parameter | Current | Safe Range | Increase | Decrease |
|-----------|---------|-----------|----------|----------|
| `max_players_per_match` | 10 (5v5) | 6-12 | Bigger matches, harder netcode | Smaller, faster netcode |
| `min_players_to_start` | 4 (2v2) | 2-10 | Wait for fuller matches | Start with very few |
| `warmup_max_duration` | 60s | 15-300 | Patient, wait for full matches | Aggressive auto-start |
| `end_screen_duration` | 15s | 5-60 | More time to read stats | Fast re-queue |
| `handshake_timeout_seconds` | 10s | 3-30 | Tolerant of slow connections | Fast failure for unreachable |
| `auto_requeue_default` | true | bool | Player stays in the loop | Requires explicit "Play Again" |

## Visual/Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|----------------|---------------|----------|
| "Play" clicked | Button depresses; spinner appears; main menu fades | Click SFX | Must |
| Connecting | Centered spinner + "Connecting..." text | Soft loop (subtle ambient) | Must |
| Connection established, assigned to WARMUP | Scene transition to game map; "Warmup — waiting for players (n/10)" HUD element | Connect-in whoosh SFX | Must |
| Connection established, assigned to in-progress match | Scene transition; brief "Joining in progress" banner | Same connect SFX | Must |
| Waiting in queue | Main menu stays but modal overlay: "Waiting — position 3" | Soft looping queue hum | Should |
| Match starting (WARMUP → ACTIVE transition) | Banner "Match Starting!" animates across screen | 3-second countdown SFX + match-start sting | Must |
| Disconnected | Full-screen overlay: "Disconnected — connection lost. Return to menu." | Disconnect sting (descending) | Must |
| Connection failed at start | Menu remains but toast: "Server unreachable — try again?" | Error SFX | Must |
| Version mismatch | Full-screen overlay: "Update required — reload browser" | Error SFX | Must |
| Name conflict tag applied | Small toast: "Your name is now 'Dex#42'" | Subtle tick | Nice-to-have |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| Connecting spinner | Center screen | Static | While Connecting / Handshaking |
| "Waiting — position N" | Modal overlay | On queue position change | While queued |
| "Warmup — players (n/10)" | Top-center HUD | On player join/leave | While WARMUP |
| Warmup countdown timer | Top-center HUD | 1 Hz | While WARMUP + after min_players met |
| "Match Starting!" banner | Full-screen center | Once, animated | At WARMUP → ACTIVE transition |
| Disconnected screen | Full-screen overlay | Static | After connection loss |
| Error messages (unreachable, version, etc.) | Full-screen overlay or toast | Static | On error |

## Acceptance Criteria

- [ ] Clicking "Play" with valid name initiates WebSocket connection to hardcoded URL
- [ ] Client shows "Connecting..." spinner during connection
- [ ] Connection succeeds to an active server and assigns player a slot within < 2s on reasonable network
- [ ] Auto-balance places joiner on smaller team; ties broken random
- [ ] WARMUP matches start when player count reaches 4 OR after 60s with ≥ 2 players
- [ ] Match state correctly transitions WARMUP → ACTIVE with correct spawn-in behaviour
- [ ] Queue forms correctly when server full; FIFO ordering verified
- [ ] Player name duplicate handling appends #XX tag
- [ ] Player name < 3 or > 16 chars is rejected or truncated appropriately
- [ ] Version mismatch displays update-required message, does not leave player in broken state
- [ ] Connection loss returns player to disconnected screen; no reconnect attempt at MVP
- [ ] END → auto-requeue re-enters matchmaking cleanly; "Return to Menu" fully disconnects
- [ ] Performance: handshake + slot assignment completes in < 500 ms server-side on idle server
- [ ] Performance: matchmaking server logic adds < 1 ms per tick overhead at 10-player count
- [ ] No hardcoded server URL in source code — must be in `assets/data/server_config.tres`

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| Should clients see each other's pings in the waiting queue? | Designer | Post-MVP | MVP: no. Defer to scoreboard. |
| Should "Play Again" carry over selected class? | Designer | Sprint 4 | MVP: no — class is a per-respawn choice |
| How should the server handle a mass-disconnect (e.g., ISP outage)? | Network prog | Post-MVP | MVP: match aborts if < 2 players remain; players see "Match Aborted" |
| Should there be a soft skill-matching heuristic (e.g., last-game-k/d based)? | Designer | Post-MVP (beta) | Deferred. MVP is pure FIFO auto-balance. |
| Should servers support multiple simultaneous matches (e.g., match 1 active, match 2 forming)? | Network prog | Post-MVP | MVP: 1 match per server process. Scale via multi-server fleet later. |
| Should the main menu display "server online / N players" status pre-click? | Designer | Sprint 4 | Nice-to-have for MVP; see main-menu.md |
| Region selection (EU / NA / ASIA) pre-click? | Designer | Post-MVP | Deferred per ADR-0002. MVP is single server. |
| Friend queue / party system? | Designer | Post-MVP (beta) | Explicitly deferred — concept says "no friend queue, no lobbies" |
