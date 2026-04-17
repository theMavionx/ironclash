# Technical Preferences

<!-- Populated by /setup-engine. Updated as the user makes decisions throughout development. -->
<!-- All agents reference this file for project-specific standards and conventions. -->

## Engine & Language

- **Engine**: Godot 4.3
- **Language**: GDScript (primary), C++ via GDExtension (performance-critical)
- **Rendering**: Forward+
- **Physics**: Godot Physics (Jolt optional)
- **Key Addons**: `terrain_3d`, `godot_mcp`

## Naming Conventions (GDScript)

- **Classes** (`class_name`): PascalCase (e.g., `PlayerController`)
- **Variables / functions**: snake_case (e.g., `move_speed`, `take_damage()`)
- **Private members**: `_snake_case` prefix (e.g., `_velocity`)
- **Signals**: snake_case, past tense (e.g., `health_changed`)
- **Constants / enums**: UPPER_SNAKE_CASE (e.g., `MAX_HEALTH`)
- **Files (scripts)**: snake_case matching class (e.g., `player_controller.gd`)
- **Scenes**: PascalCase matching root node (e.g., `PlayerController.tscn`)
- **Node names in scene tree**: PascalCase
- **Autoloads**: PascalCase singleton name

## Performance Budgets

- **Target Framerate**: 60 fps
- **Frame Budget**: 16.6 ms
- **Draw Calls**: [TO BE CONFIGURED]
- **Memory Ceiling**: [TO BE CONFIGURED]

> Adjust via `/architecture-decision` when profiling data is available.

## Testing

- **Framework**: GUT (Godot Unit Test)
- **Minimum Coverage**: [TO BE CONFIGURED]
- **Required Tests**: Gameplay systems, AI behavior, navigation baking, balance formulas

## Forbidden Patterns

- Hardcoded gravity / movement constants — use `@export` or a central config resource
- String-based node path lookups across siblings (`../../...`) — use groups, signals, or `@onready`
- String-matching on `body.name` for collision logic — use groups or class checks (`is PlayerController`)
- Heavy work in `_ready()` (>1 frame) — offload to `WorkerThreadPool` or `call_deferred`
- Silent `load()` of optional plugins — always guard with `ResourceLoader.exists` and log failures

## Allowed Libraries / Addons

- `terrain_3d` (enabled) — procedural terrain system
- `godot_mcp` (enabled) — Claude MCP editor integration

## Architecture Decisions Log

- [No ADRs yet — use /architecture-decision to create one]
