# Prototype Report: Petting System

## Hypothesis

Players will find it satisfying to pet a 2D cat by clicking and dragging the
mouse cursor over different body zones, with visual and audio feedback creating
a tactile, cozy feeling that sustains engagement for 15+ minutes.

## Approach

Built 5 Unity C# scripts forming a minimal petting prototype:

- **PettingController** — tracks mouse position, calculates stroke speed/direction,
  detects petting zones via Physics2D.OverlapPoint, triggers cat reactions
- **PrototypeCat** — minimal cat data with happiness/trust state, receives pet
  events, applies gains/losses per zone reaction type
- **PettingZone** — collider-based zones on cat body (Head, Ears, Back, Belly, Tail)
  with Loved/Neutral/Disliked reactions
- **PettingFeedback** — particle hearts, purr audio with smooth fade, camera shake
  on disliked zones, pitch variation for organic feel
- **PrototypeHUD** — smoothly animated happiness/trust bars with color interpolation

Key design decisions tested:
- Stroke speed sweet spot (2-8 units/sec) — too slow = hovering, too fast = slapping
- Zone-based reactions instead of simple "click to pet"
- Continuous interaction (drag) not discrete (click)
- 0.3s cooldown between pet triggers to prevent spam
- 1.5s "turn away" lockout on disliked zones

## Result

**PENDING PLAYTEST** — prototype code is ready for Unity Editor testing.
Update this section after running the prototype.

Expected observations to record:
- Does drag-to-pet feel natural vs click-to-pet?
- Zone detection accuracy at different sprite scales
- Heart particle count/size for visual satisfaction
- Purr audio fade timing (too abrupt? too slow?)
- Happiness decay rate (0.1/sec) vs gain rate (2-5 per pet)

## Metrics

*Fill after playtest:*
- Frame time: [measure]
- Feel assessment: [specific observations]
- Average session length: [how long before tester stops voluntarily]
- Pet count per minute: [from OnGUI debug overlay]
- Loved/Neutral/Disliked ratio: [from OnGUI debug overlay]
- Time to reach max happiness: [measure]
- Time to reach max trust: [measure]

## Recommendation: PENDING

*Update after playtest. Expected outcomes:*

### If PROCEED
Architecture requirements for production:
- Replace OnGUI debug with proper UI Toolkit or UGUI
- ScriptableObject-based cat data instead of hardcoded values
- Input System package instead of legacy Input.GetMouseButton
- Object pooling for particles
- Proper animation state machine instead of color tint hack
- Separate petting "feel" tuning into a PettingProfile ScriptableObject
- Event-driven architecture (C# events/UnityEvents) instead of direct references

Performance targets:
- Petting detection: < 0.1ms per frame
- Particle systems: < 0.5ms combined
- Total system: < 1ms frame impact

Estimated production effort: 2-3 weeks for polished petting system

### If PIVOT
Possible pivots:
- Click-and-hold instead of drag (simpler, less tactile)
- Mini-game per pet (rhythm-based, timing-based)
- First-person 3D petting (higher feel ceiling, much higher art cost)

### If KILL
If petting fundamentally doesn't feel good with mouse input:
- Consider gamepad with rumble as primary input
- Consider touch-screen (mobile pivot)
- Consider the game concept needs a different core verb

## Lessons Learned

*Fill after playtest:*
- [What surprised us about the interaction feel]
- [What zone sizes/positions worked vs didn't]
- [Impact on other systems: animation requirements, audio needs]
