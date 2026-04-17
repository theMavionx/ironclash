# Cat Data & Spawning

> **Status**: In Design
> **Author**: game-designer + user
> **Last Updated**: 2026-03-26
> **Implements Pillar**: Pillar 2 — "Котики — личности, не ресурсы"

## Overview

Cat Data & Spawning — фундаментальная система, определяющая структуру данных каждого
кота в игре и механику появления новых уличных котов в приюте. Это "анатомия" кота:
имя, порода, расцветка, характер, предпочтения по глажке, история. Игрок не
взаимодействует с этой системой напрямую — она предоставляет данные, на которых
строятся Petting, Happiness, Personality и все остальные системы. Без неё нет котов,
а без котов нет игры.

## Player Fantasy

Каждый новый кот — это сюрприз и маленькое событие. Утром игрок видит нового
испуганного кота у входа в приют и чувствует одновременно любопытство ("кто это?",
"какой он?") и заботу ("бедняга, надо помочь"). Система должна создавать ощущение,
что каждый кот — живое существо со своей историей, а не случайная генерация.

## Detailed Design

### Core Rules

**Структура данных кота (CatData)**:

1. **Identity** (неизменяемое):
   - `cat_id`: уникальный идентификатор (string, UUID)
   - `name`: имя кота (string) — генерируется при создании
   - `breed`: порода (enum CatBreed) — определяет базовый спрайт и размер
   - `coat_color`: расцветка (enum CoatColor) — вариация внутри породы
   - `coat_pattern`: паттерн шерсти (enum CoatPattern) — полосатый, пятнистый и т.д.
   - `eye_color`: цвет глаз (enum EyeColor)
   - `size`: размер кота (enum: Small, Medium, Large)
   - `backstory_id`: ссылка на мини-историю (string)

2. **Personality** (неизменяемое, читается Cat Personality системой):
   - `temperament`: основной темперамент (enum: Friendly, Shy, Playful, Grumpy, Lazy)
   - `petting_zones`: массив предпочтительных зон глажки (PettingZone[])
   - `petting_dislike_zones`: массив нелюбимых зон (PettingZone[])
   - `trust_rate`: скорость роста доверия (float, 0.5-2.0, default 1.0)
   - `favorite_food`: любимая еда (enum FoodType)
   - `favorite_toy`: любимая игрушка (enum ToyType)

3. **Mutable State** (изменяется в рантайме):
   - `happiness`: текущее счастье (float, 0-100, default зависит от temperament)
   - `hunger`: голод (float, 0-100, 0 = сытый, 100 = очень голодный)
   - `trust_level`: уровень доверия к игроку (float, 0-100, default 0)
   - `days_in_shelter`: дней в приюте (int, default 0)
   - `times_petted_today`: количество поглаживаний за день (int, resets daily)
   - `is_adopted`: усыновлён ли (bool, default false)
   - `adoption_day`: день усыновления (int, nullable)

**Enums**:

- `CatBreed`: Tabby, Siamese, Persian, Maine Coon, British Shorthair, Russian Blue,
  Calico, Black, Orange, Tuxedo, Sphynx, Scottish Fold, Ragdoll, Bengal, Munchkin
- `CoatColor`: White, Black, Orange, Gray, Brown, Cream
- `CoatPattern`: Solid, Tabby, Bicolor, Tricolor, Pointed, Spotted
- `EyeColor`: Green, Yellow, Blue, Amber, Heterochromia
- `PettingZone`: Head, Ears, Chin, Cheeks, Back, Belly, Tail, Paws
- `Temperament`: Friendly, Shy, Playful, Grumpy, Lazy
- `FoodType`: DryFood, WetFood, Fish, Chicken, Milk
- `FoodType` и `ToyType` расширяются по мере добавления контента

**Генерация кота**:

1. Система выбирает breed из доступного пула (зависит от прогресса приюта)
2. coat_color, coat_pattern, eye_color — выбираются из валидных комбинаций для breed
3. temperament — взвешенный случайный выбор (Friendly 30%, Shy 25%, Playful 25%, Grumpy 10%, Lazy 10%)
4. petting_zones — 2-3 случайных зоны из PettingZone, с учётом temperament:
   - Friendly: больше шанс на Belly, Paws (зоны высокого доверия)
   - Shy: только безопасные зоны (Head, Back)
   - Grumpy: 1-2 зоны вместо 2-3
5. petting_dislike_zones — 1-2 зоны, не пересекающиеся с petting_zones
6. name — выбирается из пула имён, не повторяя имена текущих котов в приюте
7. backstory_id — случайный выбор из пула мини-историй, compatible с temperament
8. trust_rate — базовое значение по temperament, +/- 20% случайная вариация:
   - Friendly: 1.5, Shy: 0.6, Playful: 1.2, Grumpy: 0.7, Lazy: 1.0

### States and Transitions

Каждый кот в игре проходит через следующие состояния:

| State | Entry Condition | Exit Condition | Behavior |
|-------|----------------|----------------|----------|
| **Stray** | Кот создан, ждёт за дверью | Игрок принимает кота | Показывается в UI как "новый кот у двери". Нет взаимодействия. |
| **New Arrival** | Принят в приют | trust_level >= 10 | Пугливый, ограниченные зоны глажки. happiness decay ускорен x1.5. |
| **Settling In** | trust_level >= 10 | trust_level >= 40 | Начинает раскрываться. Доступны все petting_zones. Нормальный decay. |
| **Comfortable** | trust_level >= 40 | trust_level >= 75 | Полностью доступен. Может показывать уникальные анимации. |
| **Ready for Home** | trust_level >= 75 AND happiness >= 70 | Усыновлён ИЛИ happiness < 60 | Привлекает посетителей. Может быть усыновлён. |
| **Adopted** | Посетитель усыновил | Финальное состояние | Переносится в Collection (Photo Wall). Данные archived. |

Переходы назад: если happiness падает ниже порога, кот может вернуться из
"Ready for Home" в "Comfortable" (но не дальше назад). Trust level не падает.

### Interactions with Other Systems

| System | Direction | Interface |
|--------|-----------|-----------|
| **Cat Personality** | Читает CatData | Читает temperament, petting_zones, petting_dislike_zones, trust_rate. Определяет поведенческие реакции. |
| **Cat Needs** | Читает/пишет Mutable State | Читает hunger, happiness. Обновляет hunger по таймеру Day Cycle. |
| **Petting System** | Читает Identity + Personality | Читает petting_zones, petting_dislike_zones, trust_level для определения реакций. Пишет: times_petted_today, trust_level, happiness. |
| **Cat Happiness** | Читает/пишет Mutable State | Агрегирует все входы (petting, feeding, needs) в итоговый happiness. |
| **Visitor System** | Читает State | Проверяет state == ReadyForHome и happiness >= 70 для adoption eligibility. |
| **Care System** | Читает Personality | Читает favorite_food, favorite_toy для бонусов при уходе. |
| **Adoption System** | Пишет State | Меняет is_adopted, adoption_day. Триггерит переход в Adopted. |
| **Save/Load** | Читает/пишет всё | Сериализует полный CatData + Mutable State для каждого кота. |
| **Day Cycle** | Триггерит события | Утро: spawning нового кота. Конец дня: days_in_shelter++, times_petted_today = 0. |

## Formulas

### Spawn Rate (сколько котов приходит за день)

```
daily_spawn_count = base_spawn_rate + floor(shelter_capacity / spawn_capacity_divisor)
```

| Variable | Type | Range | Source | Description |
|----------|------|-------|--------|-------------|
| base_spawn_rate | int | 1 | config | Минимум котов в день |
| shelter_capacity | int | 3-30 | Shelter Upgrade | Текущая вместимость приюта |
| spawn_capacity_divisor | int | 5-10 | config | Делитель для масштабирования |
| daily_spawn_count | int | 1-4 | calculated | Итого котов за утро |

**Expected output range**: 1 (MVP, 3 места) to 4 (full shelter, 30 мест).

**Ограничение**: spawn не происходит, если текущее количество котов >= shelter_capacity.

### Initial Happiness (стартовое счастье нового кота)

```
initial_happiness = base_initial_happiness + temperament_bonus + random(-5, 5)
```

| Variable | Type | Range | Source | Description |
|----------|------|-------|--------|-------------|
| base_initial_happiness | float | 20 | config | Базовое счастье для уличного кота |
| temperament_bonus | float | -10 to 15 | temperament | Friendly: +15, Playful: +10, Lazy: +5, Shy: 0, Grumpy: -10 |
| random | float | -5 to 5 | system | Небольшая случайная вариация |

**Expected output range**: 5 (Grumpy, unlucky) to 40 (Friendly, lucky).

### Trust Growth (рост доверия за взаимодействие)

```
trust_gain = base_trust_gain * trust_rate * zone_bonus
```

| Variable | Type | Range | Source | Description |
|----------|------|-------|--------|-------------|
| base_trust_gain | float | 2.0 | config | Базовый прирост доверия за одно поглаживание |
| trust_rate | float | 0.5-2.0 | CatData | Индивидуальная скорость доверия |
| zone_bonus | float | 0.5-2.0 | Petting System | 2.0 для любимой зоны, 1.0 для нейтральной, 0.5 для нелюбимой |

**Expected output range**: 0.5 (grumpy cat, wrong zone) to 8.0 (friendly cat, favorite zone).
**trust_level cap**: 100. Gain clamped to не превышать cap.

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Приют полон, утро наступило | Spawn не происходит. UI показывает "Приют полон — расширьте, чтобы принять новых котов" | Pillar 3: без стресса. Коты не умирают на улице. |
| Все имена из пула использованы | Добавить суффикс-номер (Мурка 2) или расширить пул | Пул должен быть 100+ имён, маловероятный случай |
| Кот с Heterochromia + Sphynx | Валидная комбинация — все coat/eye комбинации проверены на уровне breed-таблиц | Избегаем визуальных глитчей |
| happiness = 0 | Кот грустит, но НЕ убегает и НЕ умирает. Просто перестаёт привлекать посетителей. | Pillar 3: уют без стресса |
| trust_level уже 100, продолжают гладить | trust_gain = 0, но happiness всё ещё растёт. Поглаживание не бесполезно. | Pillar 1: каждое прикосновение имеет значение |
| Два кота с одинаковыми breed+coat | Допустимо. Разные имена, personality, backstory делают их уникальными. | Pillar 2: личности, не клоны |
| Кот в состоянии ReadyForHome, happiness упал < 60 | Возврат в Comfortable. trust_level не падает. | Мягкая деградация, не наказание |
| Последний кот усыновлён, приют пуст | Немедленный spawn 1 кота (не ждать утра). | Пустой приют = скучная игра |

## Dependencies

| System | Direction | Nature |
|--------|-----------|--------|
| Cat Personality | Downstream (depends on this) | **Hard** — не может существовать без CatData |
| Cat Needs | Downstream | **Hard** — читает hunger, happiness из Mutable State |
| Petting System | Downstream | **Hard** — нуждается в petting_zones, trust_level |
| Cat Happiness | Downstream | **Hard** — агрегирует данные из Mutable State |
| Visitor System | Downstream | **Hard** — проверяет cat state для adoption eligibility |
| Care System | Downstream | **Soft** — использует favorite_food/toy для бонусов |
| Adoption System | Downstream | **Hard** — меняет state на Adopted |
| Save/Load | Downstream | **Hard** — сериализует все данные |
| Day Cycle | Upstream | **Soft** — триггерит spawn и daily reset, но CatData работает и без него |
| Shelter Upgrade | Upstream | **Soft** — shelter_capacity влияет на spawn rate |

## Tuning Knobs

| Parameter | Current Value | Safe Range | Effect of Increase | Effect of Decrease |
|-----------|--------------|------------|-------------------|-------------------|
| base_spawn_rate | 1 | 0-3 | Больше котов в день, быстрее заполнение | Медленнее заполнение, больше времени на каждого |
| spawn_capacity_divisor | 7 | 3-15 | Медленнее масштабирование spawn с ростом приюта | Быстрее масштабирование, risk of overwhelm |
| base_initial_happiness | 20 | 5-50 | Коты приходят менее грустными, быстрее готовы | Дольше путь до ReadyForHome, больше заботы |
| base_trust_gain | 2.0 | 0.5-5.0 | Быстрее рост доверия, быстрее прогрессия | Медленнее, больше времени с каждым котом |
| temperament weights | 30/25/25/10/10 | -- | Больше Friendly = проще. Больше Grumpy = интереснее. | Влияет на разнообразие опыта |
| name pool size | 100+ | 50-500 | Больше разнообразия | Быстрее повторы |
| max cats in shelter | shelter_capacity | 3-30 | Больше котов = больше контента одновременно | Меньше = фокус на каждом коте |

## Visual/Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|----------------|---------------|----------|
| Новый кот появился (Stray) | Кот сидит у двери, дрожит, уши прижаты | Тихое мяуканье за дверью | MVP |
| Кот принят (Stray -> New Arrival) | Кот осторожно входит, озирается | Звук открытия двери, робкое мяу | MVP |
| Кот раскрылся (New Arrival -> Settling In) | Анимация потягивания, уши поднимаются | Мягкое мурчание | Vertical Slice |
| Кот готов к усыновлению (-> ReadyForHome) | Сердечко/звёздочка над котом | Радостное мяу | Vertical Slice |
| Кот усыновлён | Cutscene: кот уходит с хозяином, оглядывается | Bitter-sweet мелодия | Alpha |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| Новый кот у двери | Notification popup + дверь приюта | Event-driven | State == Stray |
| Имя и порода кота | Tooltip при наведении | Constant | Всегда |
| Trust level | Прогресс-бар под котом | Per interaction | При наведении/взаимодействии |
| Cat state label | Иконка статуса рядом с котом | On state change | Всегда |
| Количество котов / вместимость | HUD corner | On change | Всегда |

## Acceptance Criteria

- [ ] Кот создаётся с полным набором Identity + Personality + Mutable State
- [ ] Никакие два кота в приюте не имеют одинаковый cat_id
- [ ] Никакие два кота в приюте не имеют одинаковое имя
- [ ] Breed-coat-eye комбинации всегда визуально валидны
- [ ] Spawn не происходит при полном приюте
- [ ] Экстренный spawn при пустом приюте работает немедленно
- [ ] State transitions проходят только в определённом порядке (нет пропуска состояний)
- [ ] trust_level никогда не падает ниже достигнутого максимума
- [ ] happiness может падать, но не вызывает game over
- [ ] daily_spawn_count корректно масштабируется с shelter_capacity
- [ ] Performance: генерация кота завершается < 1ms
- [ ] Все значения читаются из конфигов, нет hardcoded gameplay values

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| Нужны ли "редкие" породы с особыми условиями появления? | game-designer | Alpha | Может добавить retention, но усложняет spawn logic |
| Backstory: сколько уникальных историй нужно? Как связать с temperament? | narrative-director | Vertical Slice | Минимум 30 историй для разнообразия |
| Должны ли коты стареть визуально с days_in_shelter? | art-director | Alpha | Может усилить привязанность, но увеличивает арт-бюджет |
