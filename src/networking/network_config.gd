class_name NetworkConfig
extends Resource

## Data-driven config for the networking layer (ADR-0001).
## Edit the .tres resource — never hardcode values in scripts.
##
## Implements: docs/architecture/adr-0001-networking-architecture.md
## Related:    design/gdd/team-assignment.md (team_max_players, team_min_to_start)

## Address the dedicated server binds on. "*" = all interfaces.
@export var server_host: String = "*"

## Port the WebSocket server listens on / clients dial by default.
@export_range(1024, 65535) var server_port: int = 9080

## URL clients dial when none is supplied at runtime. Override via
## `start_client(url_override)` for non-default deployments.
@export var client_url: String = "ws://127.0.0.1:9080"

## Cap per team. Mirrors design/gdd/team-assignment.md → team_max_players.
@export_range(1, 8) var team_max_players: int = 5

## Min per team before the match leaves WaitingForPlayers.
## Mirrors design/gdd/team-assignment.md → team_min_players_to_start.
@export_range(1, 5) var team_min_players_to_start: int = 3

## Authoritative simulation tick rate. ADR-0001 fixes 30 Hz.
@export_range(10, 60) var server_tick_hz: int = 30

## Reject incoming peers once the server already holds (max_players * 2)
## connections. Set false during load testing.
@export var reject_when_full: bool = true
