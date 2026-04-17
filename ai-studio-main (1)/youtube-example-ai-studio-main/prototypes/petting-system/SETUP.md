# Petting System Prototype — Unity Setup

## Quick Start

1. Open your Unity 2022.3 LTS project
2. Copy the `Scripts/` folder into `Assets/Prototypes/PettingSystem/`
3. Create a new Scene called `PettingPrototype`
4. Follow the scene setup below

## Scene Setup

### Camera
- Main Camera: Orthographic, Size = 5, Position (0, 0, -10)
- Background color: warm cream (#FFF5E6)

### Cat GameObject
1. Create empty GameObject "Cat" at (0, 0, 0)
2. Add `SpriteRenderer` — use any cat sprite or Unity's default square (will be placeholder)
3. Add `PrototypeCat` component
4. Add `Animator` (optional — works without animations for basic test)

### Petting Zones (children of Cat)
Create 5 child GameObjects with `CircleCollider2D` + `PettingZone` component:

| Zone Name | Local Position | Radius | Zone Type | Reaction |
|-----------|---------------|--------|-----------|----------|
| Head | (0, 0.8) | 0.3 | Head | Loved |
| Ears | (0, 1.0) | 0.2 | Ears | Loved |
| Back | (0, 0) | 0.5 | Back | Neutral |
| Belly | (0, -0.3) | 0.4 | Belly | Disliked |
| Tail | (-0.8, -0.2) | 0.25 | Tail | Neutral |

Set all colliders to a "Petting" layer.

### PettingController
1. Create empty "PettingController" GameObject
2. Add `PettingController` component
3. Assign: mainCamera, currentCat, pettingLayerMask = "Petting" layer

### PettingFeedback
1. Add `PettingFeedback` component to PettingController
2. Create 3 child Particle Systems:
   - **Hearts**: shape = circle, emit = 0, startSize = 0.3, startColor = pink,
     gravity = -0.5 (float up), lifetime = 1s
   - **Sparkles**: shape = circle, emit = 0, startSize = 0.15, startColor = yellow
   - **Annoyed**: shape = circle, emit = 0, startSize = 0.2, startColor = gray,
     speed = 2, lifetime = 0.5s
3. Assign particle systems to PettingFeedback fields
4. Add AudioSource for purring (any looping purr sound, or leave empty for silent test)

### HUD (Canvas)
1. Create Canvas (Screen Space - Overlay)
2. Add two Image fills for happiness/trust bars
3. Add Text elements for cat name and values
4. Add `PrototypeHUD` component, wire up references

## Testing Checklist

- [ ] Mouse over cat — cursor changes (if cursor textures assigned)
- [ ] Click + drag over Head/Ears — hearts appear, happiness rises
- [ ] Click + drag over Back — small hearts, moderate happiness
- [ ] Click + drag over Belly — annoyed puff, cat "turns away", happiness drops
- [ ] After disliked zone — 1.5s cooldown where petting does nothing
- [ ] Stroke speed matters — too fast or too slow reduces effect
- [ ] Stop petting — happiness slowly decays
- [ ] Trust only goes up, never down
- [ ] OnGUI debug overlay shows metrics in top-left

## Key Questions to Answer During Playtest

1. Does the mouse-drag-over-cat feel like "petting"?
2. Is the zone size right? Can you reliably target Head vs Ears?
3. Is the feedback (hearts, purr) satisfying or too subtle?
4. Does the happiness decay rate feel right? Too punishing? Too slow?
5. After 15 minutes, are you still engaged or bored?
6. What's missing for the "feel" to work?
