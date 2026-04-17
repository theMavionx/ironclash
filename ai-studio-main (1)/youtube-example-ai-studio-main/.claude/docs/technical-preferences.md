# Technical Preferences

<!-- Populated by /setup-engine. Updated as the user makes decisions throughout development. -->
<!-- All agents reference this file for project-specific standards and conventions. -->

## Engine & Language

- **Engine**: Unity 2022.3 LTS
- **Language**: C#
- **Rendering**: URP (Universal Render Pipeline)
- **Physics**: Unity Physics (PhysX)

## Naming Conventions

- **Classes**: PascalCase (e.g., `CatController`)
- **Public Fields/Properties**: PascalCase (e.g., `HappinessLevel`)
- **Private Fields**: _camelCase (e.g., `_happinessLevel`)
- **Methods**: PascalCase (e.g., `PetCat()`)
- **Events**: PascalCase with `On` prefix (e.g., `OnCatPetted`)
- **Files**: PascalCase matching class (e.g., `CatController.cs`)
- **Prefabs**: PascalCase (e.g., `CatPrefab`)
- **Constants**: PascalCase or UPPER_SNAKE_CASE (e.g., `MaxCats`)

## Performance Budgets

- **Target Framerate**: [TO BE CONFIGURED]
- **Frame Budget**: [TO BE CONFIGURED]
- **Draw Calls**: [TO BE CONFIGURED]
- **Memory Ceiling**: [TO BE CONFIGURED]

> Typical targets for a 2D cozy game: 60fps / 16.6ms frame budget.
> Want to set these now? Use `/architecture-decision` to formalize.

## Testing

- **Framework**: NUnit (Unity Test Framework)
- **Minimum Coverage**: [TO BE CONFIGURED]
- **Required Tests**: Balance formulas, gameplay systems, networking (if applicable)

## Forbidden Patterns

<!-- Add patterns that should never appear in this project's codebase -->
- [None configured yet — add as architectural decisions are made]

## Allowed Libraries / Addons

<!-- Add approved third-party dependencies here -->
- [None configured yet — add as dependencies are approved]

## Architecture Decisions Log

<!-- Quick reference linking to full ADRs in docs/architecture/ -->
- [No ADRs yet — use /architecture-decision to create one]