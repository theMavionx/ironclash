# Systems Index: Paw Haven

> **Status**: Draft
> **Created**: 2026-03-26
> **Last Updated**: 2026-03-26
> **Source Concept**: design/gdd/game-concept.md

---

## Overview

Paw Haven — cozy sim с тактильным ядром (глажка котов) и лёгкой экономической
петлёй (донаты -> расширение приюта). Игра строится вокруг 5 явных систем из
концепта и 15 неявных, выведенных из core loop, MDA-анализа и технических
требований. Ключевой bottleneck — Petting System: если она не "чувствуется"
правильно, всё остальное не имеет значения.

---

## Systems Enumeration

| # | System Name | Category | Priority | Status | Design Doc | Depends On |
|---|-------------|----------|----------|--------|------------|------------|
| 1 | Cat Data & Spawning | Core | MVP | Designed | design/gdd/cat-data-spawning.md | -- |
| 2 | Cat Personality | Gameplay | MVP | Not Started | -- | Cat Data & Spawning |
| 3 | Cat Needs | Gameplay | MVP | Not Started | -- | Cat Data & Spawning, Day Cycle |
| 4 | Petting System | Gameplay | MVP | Designed | design/gdd/petting-system.md | Cat Personality, Cat Needs |
| 5 | Cat Happiness | Gameplay | MVP | Not Started | -- | Petting System, Cat Needs, Care System |
| 6 | Shelter Economy | Economy | MVP | Not Started | -- | -- |
| 7 | Visitor System | Gameplay | MVP | Not Started | -- | Cat Happiness, Shelter Economy, Day Cycle |
| 8 | Camera & Navigation | Core | MVP | Not Started | -- | -- |
| 9 | Game UI | UI | MVP | Not Started | -- | Cat Happiness, Shelter Economy, Cat Personality |
| 10 | Day Cycle | Core | Vertical Slice | Not Started | -- | -- |
| 11 | Care System | Gameplay | Vertical Slice | Not Started | -- | Cat Needs, Cat Data & Spawning |
| 12 | Shelter Upgrade | Progression | Vertical Slice | Not Started | -- | Shelter Economy |
| 13 | Cat Animation | Presentation | Vertical Slice | Not Started | -- | Cat Personality, Petting System, Cat Happiness |
| 14 | Juice & Feedback | Presentation | Vertical Slice | Not Started | -- | Petting System, Cat Happiness, Care System |
| 15 | Audio System | Audio | Vertical Slice | Not Started | -- | Petting System, Day Cycle, Cat Happiness |
| 16 | Adoption System | Gameplay | Alpha | Not Started | -- | Visitor System, Cat Personality |
| 17 | Shelter Decoration | Expression | Alpha | Not Started | -- | Shelter Upgrade |
| 18 | Save/Load | Persistence | Alpha | Not Started | -- | All gameplay systems |
| 19 | Collection (Photo Wall) | Progression | Full Vision | Not Started | -- | Adoption System |
| 20 | Tutorial | Meta | Full Vision | Not Started | -- | Petting System, Cat Needs, Game UI |

---

## Categories

| Category | Description |
|----------|-------------|
| **Core** | Foundation systems everything else depends on |
| **Gameplay** | The systems that make the game fun — petting, happiness, visitors |
| **Economy** | Resource creation and consumption — donations, spending |
| **Progression** | How the player grows — shelter upgrades, collection |
| **Expression** | Self-expression systems — decoration, customization |
| **Persistence** | Save state and continuity |
| **UI** | Player-facing information displays |
| **Audio** | Sound and music systems |
| **Presentation** | Visual feedback, animation, juice |
| **Meta** | Systems outside the core game loop — tutorial, onboarding |

---

## Priority Tiers

| Tier | Definition | Target Milestone | Systems |
|------|------------|------------------|---------|
| **MVP** | Core loop: гладить котов, видеть счастье, получать донаты | First playable | 9 systems |
| **Vertical Slice** | Полная сессия: один день с кормлением, анимациями, звуком | Demo | 6 systems |
| **Alpha** | Все фичи в черновом виде: усыновление, декор, сохранение | Alpha | 3 systems |
| **Full Vision** | Полировка: фотостена, туториал, полный контент | Release | 2 systems |

---

## Dependency Map

### Foundation Layer (no dependencies)

1. **Cat Data & Spawning** -- база всего: определяет что такое "кот", его данные и появление
2. **Camera & Navigation** -- базовое перемещение игрока между комнатами приюта
3. **Day Cycle** -- структурирует игровое время (Утро/День/Вечер)
4. **Shelter Economy** -- отслеживание валюты, независимо от источника

### Core Layer (depends on Foundation)

5. **Cat Personality** -- depends on: Cat Data & Spawning
6. **Cat Needs** -- depends on: Cat Data & Spawning, Day Cycle

### Feature Layer (depends on Core)

7. **Petting System** -- depends on: Cat Personality, Cat Needs
8. **Care System** -- depends on: Cat Needs, Cat Data & Spawning
9. **Cat Happiness** -- depends on: Petting System, Cat Needs, Care System
10. **Visitor System** -- depends on: Cat Happiness, Shelter Economy, Day Cycle
11. **Adoption System** -- depends on: Visitor System, Cat Personality
12. **Shelter Upgrade** -- depends on: Shelter Economy
13. **Shelter Decoration** -- depends on: Shelter Upgrade

### Presentation Layer (depends on Features)

14. **Cat Animation** -- depends on: Cat Personality, Petting System, Cat Happiness
15. **Juice & Feedback** -- depends on: Petting System, Cat Happiness, Care System
16. **Audio System** -- depends on: Petting System, Day Cycle, Cat Happiness
17. **Game UI** -- depends on: Cat Happiness, Shelter Economy, Cat Personality

### Polish Layer (depends on everything)

18. **Save/Load** -- depends on: all gameplay systems (serialization of their state)
19. **Collection (Photo Wall)** -- depends on: Adoption System
20. **Tutorial** -- depends on: Petting System, Cat Needs, Game UI

---

## Recommended Design Order

| Order | System | Priority | Layer | Est. Effort |
|-------|--------|----------|-------|-------------|
| 1 | Cat Data & Spawning | MVP | Foundation | S |
| 2 | Cat Personality | MVP | Core | M |
| 3 | Cat Needs | MVP | Core | S |
| 4 | Petting System | MVP | Feature | L |
| 5 | Cat Happiness | MVP | Feature | M |
| 6 | Shelter Economy | MVP | Foundation | S |
| 7 | Visitor System | MVP | Feature | M |
| 8 | Camera & Navigation | MVP | Foundation | S |
| 9 | Game UI | MVP | Presentation | M |
| 10 | Day Cycle | Vertical Slice | Foundation | S |
| 11 | Care System | Vertical Slice | Feature | S |
| 12 | Shelter Upgrade | Vertical Slice | Feature | M |
| 13 | Cat Animation | Vertical Slice | Presentation | M |
| 14 | Juice & Feedback | Vertical Slice | Presentation | M |
| 15 | Audio System | Vertical Slice | Presentation | M |
| 16 | Adoption System | Alpha | Feature | M |
| 17 | Shelter Decoration | Alpha | Feature | S |
| 18 | Save/Load | Alpha | Persistence | M |
| 19 | Collection (Photo Wall) | Full Vision | Progression | S |
| 20 | Tutorial | Full Vision | Meta | M |

Effort: S = 1 session, M = 2-3 sessions, L = 4+ sessions.

---

## Circular Dependencies

None found. The dependency graph is a clean DAG (directed acyclic graph).

---

## High-Risk Systems

| System | Risk Type | Risk Description | Mitigation |
|--------|-----------|-----------------|------------|
| Petting System | Technical + Design | Ядро игры. Должна быть тактильно приятной. Нет готовых решений в Unity для такого взаимодействия. | Прототипировать ПЕРВЫМ (`/prototype petting-system`) |
| Cat Animation | Technical | Плавное смешивание реакций на глажку — сложная анимационная задача для 2D | R&D вместе с Petting prototype, исследовать spine/skeletal animation |
| Cat Personality | Design | Как сделать 20 котов уникальными без огромного объёма контента? | Модульная система traits: комбинации из пула характеристик |

---

## Progress Tracker

| Metric | Count |
|--------|-------|
| Total systems identified | 20 |
| Design docs started | 2 |
| Design docs reviewed | 0 |
| Design docs approved | 0 |
| MVP systems designed | 2/9 |
| Vertical Slice systems designed | 0/6 |

---

## Next Steps

- [ ] Design MVP-tier systems first (use `/design-system [system-name]`)
- [ ] Start with Cat Data & Spawning (design order #1)
- [ ] Prototype Petting System early -- highest risk (`/prototype petting-system`)
- [ ] Run `/design-review` on each completed GDD
- [ ] Run `/gate-check pre-production` when MVP systems are designed
