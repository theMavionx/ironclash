# Petting System

> **Status**: In Design
> **Author**: game-designer + user
> **Last Updated**: 2026-03-26
> **Implements Pillar**: Pillar 1 — "Каждое прикосновение имеет значение"

## Overview

Petting System — ядро всей игры Paw Haven. Игрок зажимает кнопку мыши и водит
курсором по телу кота, выполняя поглаживание. Система определяет на какой зоне
тела находится курсор, рассчитывает качество штриха (скорость, направление),
и вызывает реакцию кота: мурчание и сердечки для любимых зон, отворачивание для
нелюбимых. Каждое поглаживание влияет на happiness и trust_level кота. Без этой
системы игра теряет свой core verb и не может существовать.

## Player Fantasy

Вы протягиваете руку к коту и чувствуете, как он откликается. Когда вы находите
правильное место — за ушком, под подбородком — кот расслабляется, начинает мурчать,
и вы чувствуете тёплое удовлетворение. Это не кнопка "погладить" — это ваша рука,
ваше движение, ваше терпение. Как в реальной жизни: нужно узнать кота, найти
подход, заслужить доверие.

> **Pillar 1**: "Глажка — ядро всей игры. Она должна быть тактильно приятной,
> отзывчивой и эмоционально наполненной. Никакого автоклика."

Ключевой reference: тактильное удовольствие из Unpacking — простое действие,
идеальный feel, эмоциональный отклик.

## Detailed Design

### Core Rules

**Input Model: Continuous Drag**

1. Игрок наводит курсор на кота — курсор меняется на "открытая рука"
2. Игрок зажимает ЛКМ — курсор меняется на "закрытая рука" (гладящая)
3. Пока ЛКМ зажата и курсор движется по коту, система отслеживает:
   - Позицию курсора (мировые координаты)
   - Текущую зону тела (PettingZone из Cat Data)
   - Скорость штриха (units/sec)
   - Направление штриха (Vector2 normalized)
4. Отпускание ЛКМ или уход курсора с кота — прекращение глажки

**Zone Detection**

Каждый кот имеет набор дочерних коллайдеров (CircleCollider2D), соответствующих
зонам тела. Система использует `Physics2D.OverlapPoint` каждый кадр для определения
текущей зоны.

Зоны (из Cat Data enum `PettingZone`):

| Zone | Typical Position | Collider Radius | Trust Required |
|------|-----------------|-----------------|----------------|
| Head | Верх головы | 0.3 | 0 (всегда доступна) |
| Ears | Уши (2 коллайдера) | 0.2 | 0 |
| Chin | Под подбородком | 0.25 | 10 |
| Cheeks | Щёки (2 коллайдера) | 0.2 | 10 |
| Back | Спина | 0.5 | 0 |
| Belly | Живот | 0.4 | 40 (зона высокого доверия) |
| Tail | Хвост | 0.25 | 20 |
| Paws | Лапы (4 коллайдера) | 0.15 | 30 |

**Trust Required**: минимальный `trust_level` кота, при котором зона доступна для
взаимодействия. Ниже порога — курсор не меняется, глажка этой зоны игнорируется.
Это создаёт ощущение постепенного "раскрытия" кота.

**Zone Reaction Types** (определяются Cat Data для каждого кота):

- **Loved**: любимая зона — максимальный happiness gain, мурчание, сердечки
- **Neutral**: нормальная зона — умеренный gain, лёгкое мурчание
- **Disliked**: нелюбимая зона — happiness loss, кот отворачивается на 1.5 сек

**Stroke Quality**

Не все поглаживания равны. Система рассчитывает `stroke_quality` (0.0-1.0):

- `stroke_speed`: скорость движения курсора (units/sec)
- Оптимальный диапазон: 2-8 units/sec (мягкое, плавное поглаживание)
- Ниже 0.5 = курсор стоит, не считается поглаживанием
- 0.5-2.0 = медленно, quality нарастает линейно от 0 до 1
- 2.0-8.0 = sweet spot, quality = 1.0
- 8.0-15.0 = слишком быстро, quality падает линейно от 1 до 0
- Выше 15.0 = слишком быстро, не считается поглаживанием

**Pet Trigger Cooldown**

Система триггерит событие "pet" не чаще чем раз в `pet_cooldown` (0.3 сек) на одну
зону. Это предотвращает спам и создаёт ритм взаимодействия. При смене зоны
кулдаун сбрасывается — поощряя "прогулку" по разным зонам.

**Turn Away Mechanic**

При попадании в Disliked зону кот "отворачивается":
- Все зоны становятся неактивными на `turn_away_duration` (1.5 сек)
- Визуально кот отворачивается (анимация)
- Звук недовольного мяу
- После окончания — кот возвращается в нормальное состояние
- Повторное попадание в Disliked сразу после recovery увеличивает duration x1.5

**Combo System (Sustained Petting)**

При непрерывном поглаживании любимой зоны в течение 3+ секунд активируется
"combo" — усиленный feedback:
- Больше сердечек
- Громче мурчание
- happiness gain x1.5
- Визуальный эффект: мягкое свечение вокруг зоны
- Combo прерывается при: уходе с зоны, отпускании ЛКМ, попадании в Disliked

### States and Transitions

Состояния взаимодействия (не кота — а самой системы глажки):

| State | Entry Condition | Behavior | Exit Condition |
|-------|----------------|----------|----------------|
| **Idle** | Курсор не на коте | Обычный курсор. Нет расчётов. | Курсор входит в коллайдер кота |
| **Hovering** | Курсор на коте, ЛКМ не зажата | Курсор "открытая рука". Tooltip с именем кота. | ЛКМ зажата -> Petting. Курсор ушёл -> Idle |
| **Petting** | ЛКМ зажата и курсор на коте | Курсор "закрытая рука". Stroke tracking. Pet triggers. | ЛКМ отпущена -> Hovering. Курсор ушёл -> Idle. Disliked zone -> TurnedAway |
| **Combo** | Petting на Loved зоне 3+ сек | Усиленный feedback. x1.5 happiness. | Зона сменилась -> Petting. ЛКМ отпущена -> Hovering |
| **TurnedAway** | Pet trigger на Disliked зоне | Все зоны неактивны. Ожидание recovery. | Timer 1.5s -> Hovering (если курсор на коте) или Idle |

### Interactions with Other Systems

| System | Direction | Interface |
|--------|-----------|-----------|
| **Cat Data & Spawning** | Reads | `petting_zones[]`, `petting_dislike_zones[]`, `trust_level`, `trust_rate`, `temperament`, cat state (для Trust Required зон) |
| **Cat Personality** (provisional) | Reads | Поведенческие модификаторы: Playful коты могут "ловить руку", Lazy — медленнее реагируют. Точный interface TBD после GDD. |
| **Cat Needs** (provisional) | Reads | `hunger` level — очень голодный кот хуже реагирует на petting (happiness gain x0.5 при hunger > 80). Interface TBD. |
| **Cat Happiness** | Writes | Отправляет `happiness_delta` после каждого pet trigger. Cat Happiness агрегирует все источники. |
| **Cat Data (trust)** | Writes | Обновляет `trust_level` через `trust_gain` формулу. Пишет `times_petted_today++`. |
| **Juice & Feedback** | Triggers | Отправляет событие `OnPetTriggered(position, reaction, stroke_quality, zone)` — Feedback система решает что показать. |
| **Cat Animation** | Triggers | Отправляет `OnPetStateChanged(state)` и `OnPetZoneActive(zone, reaction)` — Animation система управляет визуалом кота. |
| **Audio System** | Triggers | Отправляет `OnPurrIntensityChanged(0-1)` и `OnCatReaction(reaction)`. |
| **Game UI** | Provides data | Экспортирует: текущее состояние (Idle/Hovering/Petting/Combo), активная зона, stroke quality — для UI отображения. |

## Formulas

### Happiness Delta (за один pet trigger)

```
happiness_delta = base_happiness_gain * reaction_multiplier * stroke_quality * combo_multiplier * hunger_penalty
```

| Variable | Type | Range | Source | Description |
|----------|------|-------|--------|-------------|
| base_happiness_gain | float | 3.0 | config | Базовый прирост за одно поглаживание |
| reaction_multiplier | float | -1.0 to 2.0 | zone reaction | Loved: 2.0, Neutral: 1.0, Disliked: -1.0 |
| stroke_quality | float | 0.0-1.0 | calculated | Качество штриха по скорости |
| combo_multiplier | float | 1.0-1.5 | state | 1.0 нормально, 1.5 в Combo |
| hunger_penalty | float | 0.5-1.0 | Cat Needs | 1.0 при hunger < 80, 0.5 при hunger >= 80 |

**Expected output range**:
- Best case (Loved, perfect speed, Combo, not hungry): 3.0 * 2.0 * 1.0 * 1.5 * 1.0 = **9.0**
- Typical case (Neutral, good speed): 3.0 * 1.0 * 0.8 * 1.0 * 1.0 = **2.4**
- Worst case (Disliked): 3.0 * -1.0 * 1.0 * 1.0 * 1.0 = **-3.0**

### Trust Gain (за один pet trigger)

Используется формула из Cat Data GDD:

```
trust_gain = base_trust_gain * trust_rate * zone_bonus * stroke_quality
```

| Variable | Type | Range | Source | Description |
|----------|------|-------|--------|-------------|
| base_trust_gain | float | 2.0 | config (Cat Data) | Базовый прирост доверия |
| trust_rate | float | 0.5-2.0 | CatData | Индивидуальная скорость |
| zone_bonus | float | 0.5-2.0 | zone reaction | Loved: 2.0, Neutral: 1.0, Disliked: 0.5 |
| stroke_quality | float | 0.0-1.0 | calculated | Качество штриха |

**Note**: Trust НИКОГДА не уменьшается от petting (даже Disliked зона даёт 0.5 bonus).
Это решение из Cat Data GDD: `trust_level никогда не падает ниже достигнутого максимума`.

### Stroke Quality

```
if speed < min_speed: quality = 0.0
if speed >= optimal_min AND speed <= optimal_max: quality = 1.0
if speed > min_speed AND speed < optimal_min: quality = lerp(0, 1, (speed - min_speed) / (optimal_min - min_speed))
if speed > optimal_max AND speed < max_speed: quality = lerp(1, 0, (speed - optimal_max) / (max_speed - optimal_max))
if speed >= max_speed: quality = 0.0
```

| Variable | Type | Value | Description |
|----------|------|-------|-------------|
| min_speed | float | 0.5 | Ниже = не считается |
| optimal_min | float | 2.0 | Начало sweet spot |
| optimal_max | float | 8.0 | Конец sweet spot |
| max_speed | float | 15.0 | Выше = не считается |

### Combo Timer

```
combo_active = (continuous_pet_time >= combo_threshold) AND (current_zone.reaction == Loved)
```

| Variable | Type | Value | Description |
|----------|------|-------|-------------|
| continuous_pet_time | float | 0+ | Время непрерывного petting на одной Loved зоне |
| combo_threshold | float | 3.0 sec | Порог активации Combo |

## Edge Cases

| Scenario | Expected Behavior | Rationale |
|----------|------------------|-----------|
| Курсор движется между двумя перекрывающимися зонами | Приоритет по z-order: верхний коллайдер побеждает | Коллайдеры не должны перекрываться сильно, но если да — детерминированный результат |
| Игрок зажал ЛКМ но не двигает мышь | stroke_speed < 0.5 = не petting. Рука "лежит" на коте. Нет gain/loss. Визуально рука неподвижна. | Поглаживание = движение. Без движения нет взаимодействия. |
| Игрок двигает мышь очень быстро (>15 u/s) | quality = 0, pet trigger не срабатывает. Это "шлёпание", не поглаживание. | Pillar 1: тактильно приятное взаимодействие, не speedrun |
| Кот в состоянии New Arrival, игрок пытается потрогать Belly | Зона недоступна (trust < 40 required). Курсор не меняется. Нет реакции. | Постепенное раскрытие через доверие |
| Два кота рядом, зоны перекрываются | Один курсор = один кот. Приоритет по расстоянию до центра кота. | Избегаем confusing multi-target |
| Игрок спамит ЛКМ (click-click-click) вместо drag | pet_cooldown (0.3s) ограничивает спам. Каждый клик = максимум 1 pet trigger. Drag всегда эффективнее. | Поощряем плавное поглаживание |
| TurnedAway повторно (дважды попал в Disliked подряд) | Второй turn away длится 1.5 * 1.5 = 2.25 сек. Третий = 3.375 сек. Cap: 5 сек. | Мягкий deterrent от повторных ошибок |
| trust_level = 100, все зоны открыты, всё Loved | Максимальный feel-good moment. Combo активируется быстро. Это reward за терпение. | Payoff для long-term investment |
| Кот в Combo, игрок случайно задел Disliked зону | Combo прерывается, TurnedAway. Combo timer сбрасывается. | Чёткие последствия, но не наказание — можно начать снова |

## Dependencies

| System | Direction | Nature | Interface |
|--------|-----------|--------|-----------|
| Cat Data & Spawning | Upstream | **Hard** | Reads: petting_zones, petting_dislike_zones, trust_level, trust_rate, temperament, cat state |
| Cat Personality | Upstream | **Soft** (provisional) | Reads: поведенческие модификаторы (Playful/Lazy reactions). TBD. |
| Cat Needs | Upstream | **Soft** (provisional) | Reads: hunger для hunger_penalty. TBD. |
| Cat Happiness | Downstream | **Hard** | Writes: happiness_delta per pet trigger |
| Cat Animation | Downstream | **Hard** | Events: OnPetStateChanged, OnPetZoneActive |
| Juice & Feedback | Downstream | **Hard** | Events: OnPetTriggered(position, reaction, quality, zone) |
| Audio System | Downstream | **Soft** | Events: OnPurrIntensityChanged(float), OnCatReaction(reaction) |
| Game UI | Downstream | **Soft** | Exports: current state, active zone, stroke quality |
| Camera & Navigation | Upstream | **Soft** | Reads: camera reference для ScreenToWorldPoint |

**Bidirectional notes**:
- Cat Data GDD (section Interactions) уже определяет этот interface: "Petting System читает petting_zones, petting_dislike_zones, trust_level. Пишет: times_petted_today, trust_level, happiness." — **Consistent**.
- Cat Happiness, Cat Animation, Juice & Feedback ещё не спроектированы — interfaces здесь определены как контракт, который те системы должны реализовать.

## Tuning Knobs

| Parameter | Current Value | Safe Range | Effect of Increase | Effect of Decrease |
|-----------|--------------|------------|-------------------|-------------------|
| base_happiness_gain | 3.0 | 1.0-8.0 | Быстрее рост счастья, меньше petting нужно | Больше petting для результата, risk of tedium |
| pet_cooldown | 0.3s | 0.1-1.0 | Реже triggers, менее отзывчиво | Чаще triggers, может чувствоваться spammy |
| optimal_speed_min | 2.0 | 0.5-4.0 | Шире sweet spot снизу, проще | Нужно двигать быстрее для quality |
| optimal_speed_max | 8.0 | 5.0-15.0 | Шире sweet spot сверху | Уже sweet spot, труднее попасть |
| combo_threshold | 3.0s | 1.0-5.0 | Дольше ждать Combo, больше reward за терпение | Быстрее Combo, менее значим |
| combo_multiplier | 1.5 | 1.2-2.0 | Combo сильнее, больше мотивации удерживать | Combo менее заметен |
| turn_away_duration | 1.5s | 0.5-3.0 | Дольше ждать после ошибки | Быстрее recovery, менее наказующе |
| turn_away_escalation | 1.5x | 1.0-2.0 | Сильнее наказание за повторные ошибки | Нет эскалации (1.0 = flat duration) |
| turn_away_max_duration | 5.0s | 2.0-10.0 | Longer max punishment | Shorter cap |
| hunger_penalty_threshold | 80 | 50-100 | Раньше начинает влиять голод | Позже, hunger менее важен для petting |

**Interactions между knobs**: `pet_cooldown` и `base_happiness_gain` прямо связаны — уменьшение cooldown при высоком gain = слишком быстрый рост. Настраивать вместе.

**Cross-reference**: `base_trust_gain` и `trust_rate` определены в Cat Data GDD (Tuning Knobs). Не дублируем — ссылаемся на Cat Data.

## Visual/Audio Requirements

| Event | Visual Feedback | Audio Feedback | Priority |
|-------|----------------|---------------|----------|
| Cursor enters cat | Cursor -> "open hand" | -- | MVP |
| Petting starts (LMB down) | Cursor -> "closed hand" | -- | MVP |
| Pet trigger (Loved zone) | 3-6 hearts float up from position. Soft glow on zone. | Purr volume ramps up. Pitch slightly randomized (+/- 10%). | MVP |
| Pet trigger (Neutral zone) | 1-2 small hearts | Light purr | MVP |
| Pet trigger (Disliked zone) | Gray puff particles. No hearts. | Short annoyed meow. Purr stops. | MVP |
| Combo activated | Zone glows warmly. Hearts become larger, golden. Sparkle particles. | Purr deepens, volume max. Soft chime on activation. | Vertical Slice |
| Combo maintained | Continuous gentle sparkle trail following cursor | Sustained deep purr | Vertical Slice |
| Turn away | Cat sprite flips/rotates. Ears flatten. | Annoyed meow, then silence | MVP |
| Turn away recovery | Cat turns back. Ears raise. | Soft curious meow | Vertical Slice |
| Trust threshold reached (new zone unlocked) | Brief celebration: stars around new zone | Happy meow + small jingle | Vertical Slice |

## UI Requirements

| Information | Display Location | Update Frequency | Condition |
|-------------|-----------------|-----------------|-----------|
| Cat name | Floating label above cat | Constant | Hovering or Petting state |
| Happiness bar | Small bar below cat name | Per pet trigger (smoothed) | Hovering or Petting state |
| Trust progress | Secondary bar below happiness | Per pet trigger (smoothed) | Hovering or Petting state |
| Zone hint | Subtle highlight on cat body | On hover (no LMB) | trust >= zone requirement |
| Locked zone indicator | Lock icon on zone | On hover over locked zone | trust < zone requirement |
| Combo indicator | "Combo!" text + glow | While Combo active | Combo state |
| Stroke speed indicator | -- (NO explicit display) | -- | Intentionally hidden — feel, not numbers |

**Design decision**: Stroke quality is intentionally NOT shown as a number. Игрок должен
"чувствовать" правильную скорость через feedback (громкость мурчания, количество сердечек),
а не оптимизировать число. Это Pillar 1: feel, not metrics.

## Acceptance Criteria

- [ ] Cursor changes to "open hand" when hovering over cat
- [ ] Cursor changes to "closed hand" when LMB held over cat
- [ ] Cursor reverts to default when leaving cat
- [ ] Dragging over Loved zone produces hearts and happiness gain
- [ ] Dragging over Neutral zone produces fewer hearts and less gain
- [ ] Dragging over Disliked zone triggers TurnAway (no petting for 1.5s)
- [ ] Stroke speed below 0.5 u/s does NOT trigger pet events
- [ ] Stroke speed above 15 u/s does NOT trigger pet events
- [ ] Stroke speed 2-8 u/s produces maximum quality (1.0)
- [ ] Pet triggers respect cooldown (max ~3.3 triggers/sec at 0.3s cooldown)
- [ ] Combo activates after 3s continuous petting on Loved zone
- [ ] Combo breaks when leaving zone or releasing LMB
- [ ] Zones with trust requirement are inaccessible below threshold
- [ ] New zone unlock produces celebration feedback
- [ ] TurnAway escalation works: 1.5s -> 2.25s -> 3.375s, capped at 5s
- [ ] happiness_delta matches formula: base * reaction * quality * combo * hunger
- [ ] trust_gain matches Cat Data formula: base * rate * zone_bonus * quality
- [ ] Trust never decreases from petting interactions
- [ ] Performance: zone detection < 0.1ms per frame
- [ ] Performance: total petting system update < 0.5ms per frame
- [ ] All tuning values read from config (ScriptableObject), no hardcoded gameplay values
- [ ] Two overlapping cats: only nearest cat receives petting

## Open Questions

| Question | Owner | Deadline | Resolution |
|----------|-------|----------|-----------|
| Должны ли разные породы иметь разные размеры зон? | game-designer | Vertical Slice | Вероятно да — Maine Coon больше, Munchkin меньше. Affects collider setup. |
| Нужны ли "секретные" зоны, не видимые в UI? | game-designer | Alpha | Может усилить Discovery aesthetic, но risk of frustration |
| Поддержка gamepad (стик вместо мыши)? | ux-designer | Alpha | PC-first, но gamepad может расширить аудиторию. Другая модель input. |
| Должна ли глажка работать по-другому для Sphynx (без шерсти)? | game-designer | Alpha | Fun detail, но увеличивает scope |
| Тактильные звуки шерсти при поглаживании? | sound-designer | Vertical Slice | Может сильно усилить feel, нужен R&D с audio |
