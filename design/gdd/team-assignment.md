# Team Assignment

> **Status**: Designed
> **Author**: Claude Code Game Studios session
> **Last Updated**: 2026-04-14
> **Implements Pillar**: Matches Start Fast (auto-assign, no team-select screen)

## Overview

Team Assignment is the small but critical system that places connecting
players into one of two teams (Team A "Red" / Team B "Blue") and locks that
assignment for the duration of the match. It runs only on the server. There
is no team-select screen, no manual swap, no friend-side-with-friend logic
(per Pillar 3 *Matches Start Fast* and the no-lobbies decision in concept).
Players are auto-balanced into the smaller team on join.

## Player Fantasy

The player should never think about team assignment. They click Play, get
matched, and are simply *on a team*. The visual identity (red vs blue
nameplates, character team uniform, HUD color cues) makes team affiliation
unmistakable from the first second of the match.

## Detailed Design

### Core Rules

1. Team Assignment runs **only on the server**.
2. Two teams exist per match: **Team A (Red)** and **Team B (Blue)**.
3. Each team's max size is `team_max_players` (default 5; tunable for 6v6 testing).
4. Players are auto-assigned on connection: the team with fewer players gets the new player. Tie-broken by Team A preference.
5. Once assigned, team affiliation **locks for the entire match**. No swapping.
6. On player disconnect, the slot stays empty for the rest of the match (no late-join replacement once `InProgress` begins). **Late-join is allowed during `Warmup`** but blocked during `InProgress`.
7. Team affiliation is **server-authoritative** and replicated to all clients via `MultiplayerSynchronizer`.
8. Match minimum to start is `team_min_players_to_start` per team (default **3**) — match can begin as 3v3 minimum, up to 5v5 maximum.

### Team Data Structure

| Field | Type | Description |
|---|---|---|
| `team_id` | enum {TEAM_A, TEAM_B} | Authoritative team identifier |
| `team_name` | string | "Red" / "Blue" (display) |
| `team_color` | Color | Red (#D14545) / Blue (#3B7DD8) |
| `team_spawn_zone` | Vector3 + radius | Base spawn area (per Map / Capture Point system) |
| `members` | Array[player_id] | Currently assigned players |
| `team_score` | int | Match scoring contribution (owned by Match Scoring) |

### Assignment Algorithm

```
on_player_connect(player):
    if team_a.members.size() < team_b.members.size():
        assign(player, TEAM_A)
    elif team_b.members.size() < team_a.members.size():
        assign(player, TEAM_B)
    else:  // equal
        assign(player, TEAM_A)  // tie-break to A
    broadcast_team_assignment(player, player.team)
```

### Visual Team Identity

- **Character uniform color** matches team color (red vs blue tint on character model)
- **Nameplate** above teammates shows team color; enemy nameplates are absent at MVP (no enemy nameplate rendering — see Open Questions)
- **HUD elements** color-coded:
  - Team score: Red on left, Blue on right (or vice-versa per team)
  - Kill feed: kills by your team in your color, by enemy in their color
  - Capture progress: shows which team is capturing in their color
- **Minimap** (post-MVP) uses team colors for friendly markers

### Interactions with Other Systems

- **Networking** (peer): server assigns and replicates team affiliation
- **Match State Machine** (peer): assignment runs during `WaitingForPlayers` state; locks on `InProgress`
- **Health & Damage** (downstream): consults team for friendly-fire filter (team match → no damage)
- **Capture Point System** (downstream): consults player team to determine capture progress
- **Respawn System** (downstream): uses team's spawn zone to place respawned players
- **Match Scoring** (downstream): tracks team score
- **HUD** (downstream): displays team affiliation, scores, kill feed coloring

## Formulas

No formulas — purely categorical assignment.

## Edge Cases

- **All 10 slots full, 11th player connects** → connection rejected with "Match full" message
- **Player disconnects during `WaitingForPlayers` or `Warmup`** → slot freed, can be filled by next connecting player
- **Player disconnects during `InProgress`** → slot stays empty for the rest of the match (no late-join replacement once match is live)
- **Both teams empty when match-creation fires** → `WaitingForPlayers` state holds; match doesn't start until min players AND grace period
- **Player connects during `Warmup`** → assigned to smaller team, spawned at team base with full HP, joins the warmup
- **Player connects during `InProgress`** → connection rejected with "Match in progress" message; redirected to a new server / next match
- **Player connects during `PostMatch`** → connection rejected
- **Two players connect in same tick** → assigned in order received; tie-break logic applies
- **Server assigns but client never acknowledges** → after timeout (5 s), server treats player as disconnected and frees slot

## Dependencies

**Upstream (hard):**
- **Networking** — connect events
- **Match State Machine** — only assigns during `WaitingForPlayers`

**Downstream (hard):**
- **Health & Damage** — friendly-fire check
- **Capture Point System** — team ownership of points
- **Respawn System** — team spawn zone lookup
- **Match Scoring** — team score tracking
- **HUD** — color-coded display

## Tuning Knobs

| Knob | Range | Default | Effect |
|---|---|---|---|
| `team_max_players` | 3 – 8 | 5 | Cap per team |
| `team_min_players_to_start` | 1 – 5 | **3** | Min per team before `InProgress` starts (after grace period) |
| `team_a_color_hex` | string | #D14545 | Red |
| `team_b_color_hex` | string | #3B7DD8 | Blue |
| `team_a_display_name` | string | "Red" | Display label |
| `team_b_display_name` | string | "Blue" | Display label |
| `assignment_ack_timeout_seconds` | 2 – 10 | 5 | Time to wait for client ack before freeing slot |

## Visual/Audio Requirements

- **Character uniforms** colored per team (model material variant)
- **Team color** propagated to nameplates, HUD elements, capture progress indicators
- **Match-start sting**: brief "Team Red" / "Team Blue" text fade-in for player ("You are on Team Red") at match start
- **No team-select audio** — no team selection screen exists

## UI Requirements

- **No team-select screen** — player goes directly from "Play" to in-game
- **"You are on Team [X]" notification** at match start (1.5 s, fades)
- **Team scores in HUD** (top-center): "RED 145 — 132 BLUE" with team colors
- **Color-coded kill feed**, scoreboard, capture indicators

## Acceptance Criteria

- [ ] On connection, player is auto-assigned to smaller team
- [ ] When teams are equal, new player goes to Team A
- [ ] Team affiliation is identical on all clients (server-authoritative replication verified)
- [ ] No swap mechanism exists — UI offers no team-change option
- [ ] Match does not enter Warmup until both teams have ≥3 players AND grace period has elapsed (or 5v5 reached early — skip Warmup)
- [ ] During Warmup, late-joiners are auto-assigned to smaller team and spawn at base with full HP
- [ ] During InProgress, on disconnect the slot stays empty — no late-join replacement
- [ ] 11th connection is rejected with appropriate message
- [ ] Connections during InProgress are rejected with "Match in progress" message
- [ ] Friendly fire is correctly blocked between same-team players (cross-system: works with Health & Damage)
- [ ] HUD displays team scores with correct colors

## Open Questions

- **Enemy nameplates**: at MVP, no enemy nameplates render (forces players to read uniform color and posture). Some games (PUBG) hide enemies entirely; others (Battlefield) show distance + class icon. MVP = hidden. Revisit post-playtest.
- **Auto-balance mid-match** (if a player leaves making it 4v5): not at MVP. Defer to post-MVP "lobby health" feature.
- **Premade-friendly groups** (later — post-MVP — when friend invites exist): handle by keeping invited players together in assignment. Not a concern at MVP.
- **Team voice chat**: no voice at MVP per concept doc.
- **Custom team names / clan tags**: post-MVP.
