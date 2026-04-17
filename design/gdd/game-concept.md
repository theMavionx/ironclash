# Game Concept: Ironclash (working title)

*Created: 2026-04-14*
*Status: Draft*

---

## Elevator Pitch

> Ironclash is a browser-based 5v5 third-person team objective shooter where
> you capture and hold three control points with combined-arms combat —
> infantry, tanks, helicopters, and (post-MVP) kamikaze drones. Inspired by
> the visual feel of PUBG and the arcade tempo of Fortnite, built around the
> fantasy of the badass clutch outplay seen from over your character's
> shoulder.

---

## Core Identity

| Aspect | Detail |
| ---- | ---- |
| **Genre** | Team-based objective TPS (third-person shooter, capture-point / domination) |
| **Platform** | Browser (HTML5 via Godot 4.3 web export) |
| **Target Audience** | See Player Profile — PUBG / Fortnite / TPS players wanting quick browser sessions |
| **Player Count** | 5v5 (6v6 tested during beta) |
| **Session Length** | 8-15 minutes per match |
| **Monetization** | Deferred — cosmetic skins (direct sales recommended over loot boxes; see Risks) |
| **Estimated Scope** | Aggressive — 15-day MVP (team-accepted risk), 3-6 months for post-MVP polish |
| **Comparable Titles** | PUBG (TPS feel + military realism), Fortnite (TPS arcade tempo, no building), Splitgate (browser-scale TPS) |

---

## Core Fantasy

**Be the badass who earned it — and look badass doing it.**

Third-person view is core to the fantasy. The player sees their character
on screen — geared up, military, cool — and watches that character pull off
clutch moments. Every kill is a skill check, not a dice roll. The player
experience centers on *earning* moments of dominance:

- Outplaying an opponent with a cross-map AK headshot
- Clutching a 1v3 defense on the last capture point with one mag left
- Flying a helicopter at rooftop height while raining fire on infantry
- Killing an enemy tank with a single well-placed RPG round
- (Post-MVP) Piloting a drone undetected into a tight formation

The third-person camera also makes skin investment matter — players see
their character constantly, so the cosmetic skin economy (post-MVP) has a
much stronger pull than in first-person games.

The player should finish every match able to point to **one moment they pulled
off** — not one the game handed them.

---

## Unique Hook

**A browser-native combined-arms third-person objective shooter.**

Browser shooters are almost universally first-person (Krunker, Shell Shockers,
Block Ops). TPS games of this scope require native clients (PUBG, The Division,
Gears). Ironclash occupies the empty gap: third-person + tanks + helicopters
in a zero-install browser experience, sized for 5v5 matches that fit into a
coffee break.

The "and also" test: *"It's like PUBG TPS in a browser, AND ALSO you can jump
into a helicopter mid-match and rain hell from above — no install, just a URL."*

---

## Player Experience Analysis (MDA Framework)

### Target Aesthetics

| Aesthetic | Priority | How We Deliver It |
| ---- | ---- | ---- |
| **Challenge** (mastery) | **1** | Headshot bonuses, recoil patterns, vehicle counterplay, skill-based matchmaking (post-MVP) |
| **Fantasy** (power trip) | **2** | Vehicle rampages, RPG one-shots, clutch moments |
| **Fellowship** (social) | N/A | No friend queue, no lobbies, no voice chat — online matches are with random players only |
| **Sensation** (feedback) | **4** | Hit markers, screen shake, weapon audio punch |
| **Expression** | **5** | Skins (post-MVP) |
| **Narrative** | N/A | No story layer |
| **Discovery** | N/A | Not an exploration game |
| **Submission** | N/A | Explicitly competitive |

### Key Dynamics

- Players will **learn map chokepoints** and develop personal angles, using third-person camera to scout corners
- Players will **manage stamina** — sprinting across open ground exhausted is a death sentence
- Veteran players will **hunt helicopters** with RPGs for the prestige kill
- Players will **rotate respawns** strategically — dying near a captured point means fast re-entry; losing the point pushes respawn back to base
- Tank vs RPG trade-offs will emerge — when a tank is active, RPG-class players become priority targets and priority spawns

### Core Mechanics

1. **Third-person hitscan + projectile gunplay** with per-weapon recoil, headshot multipliers, and over-shoulder free-aim reticle
2. **Capture-point control** — timed neutralization + capture, point income while held
3. **Vehicle combat** — tank (ground) and helicopter (air), each with armor and counters
4. **Two-class loadout system** — Assault (AK) / Heavy (RPG). No pistol class, no sidearms.
5. **Match scoring** — win by capture-point income + kills over match duration

---

## Player Motivation Profile

### Primary Psychological Needs Served

| Need | How This Game Satisfies It | Strength |
| ---- | ---- | ---- |
| **Autonomy** | Class choice, vehicle access, engagement decisions (push/hold/flank) | Supporting |
| **Competence** | Skill-expressive aim, earned vehicle kills, clutch moments | **Core** |
| **Relatedness** | Shared team objective only — no friend queue, no voice, no ping system | Minimal |

### Player Type Appeal (Bartle)

- [x] **Killers/Competitors** — Primary. Aim duels, K/D, clutch kills are the core fantasy
- [x] **Achievers** — Secondary. Round wins, future progression, skin collection
- [x] **Self-expressers** — Strong third-person view makes character cosmetics highly visible (post-MVP skin economy)
- [ ] **Explorers** — Not served; fixed maps, no emergent systems
- [ ] **Socializers** — Minimally served; no voice, no guilds

### Flow State Design

- **Onboarding curve**: First-match bot warm-up (post-MVP); MVP relies on genre literacy (Standoff/CS players know the drill)
- **Difficulty scaling**: Skill-based matchmaking (post-MVP); MVP is free-for-all lobbies
- **Feedback clarity**: Hit markers, damage numbers, kill feed, capture progress bar
- **Recovery from failure**: Fast respawn (5-8 sec), match length short enough that one bad round doesn't ruin a session

---

## Core Loop

### Moment-to-Moment (30 seconds)
Scan with the over-shoulder camera → engage → aim down sights (camera tightens
to over-shoulder closer) → shoot → kill/die. Reload, reposition, repeat. If a
vehicle is in play, decide: counter with RPG, or avoid. If in a vehicle:
strafe, fire, dodge incoming.

### Short-Term (2-5 minutes)
Contest a capture point. Clear defenders, stand on point, hold while teammates
cover angles. Lose the point → fall back to a secondary objective.

### Session-Level (8-15 minutes per match; 30-60 min per sitting)
Complete a match. Team with more capture-point income + kills at time expiry
wins. Natural stopping point between matches; "one more match" psychology
drives re-queue.

### Long-Term Progression
**MVP**: None (matches only).
**Post-MVP**: Skin unlocks, stats tracking, seasonal ranked ladder.

### Retention Hooks
- **Curiosity**: New maps added post-launch
- **Investment**: Skin collection, rank progression (post-MVP)
- **Social**: Friend duo queue, shareable clip moments
- **Mastery**: Aim improvement, map knowledge, vehicle proficiency

---

## Game Pillars

### Pillar 1: Skill Is The Ceiling

Every outcome should trace to a player decision or execution. Luck, randomness,
and unearned power are minimized.

*Design test*: If we're debating between "add a random critical hit chance" vs
"add a consistent headshot multiplier," this pillar chooses **headshot
multiplier**. Skill over RNG.

### Pillar 2: Every Tool Has A Counter

No weapon, vehicle, or tactic is un-counterable. Helicopter → RPG. Sniper →
movement/flanking. Tank → RPG flanking. Drone → audio + hitscan.

*Design test*: If we're debating whether to add a new weapon/vehicle without a
clear counter, this pillar says **design the counter first, or don't ship it**.

### Pillar 3: Matches Start Fast

Players click "Play," wait briefly, and are dropped into a live match against
random opponents. No lobbies, no friend invites, no setup friction. The game
minimizes time between "I want to play" and "I am shooting."

*Design test*: If we're debating a feature that adds pre-match steps (map
vote, team balance screen, loadout confirmation), this pillar says **skip it
or move it post-match**.

### Anti-Pillars (What This Game Is NOT)

- **NOT a hero shooter** — no ultimate abilities, no character-locked powers. Skill > kit.
- **NOT a battle royale** — fixed teams, fixed map, fixed match length. Objective-driven, not survival-driven.
- **NOT a building game** — no Fortnite-style construction. Only the camera/aim feel is borrowed; building is explicitly out.
- **NOT a first-person shooter** — third-person infantry view is core to the fantasy and the cosmetic economy. No FPS toggle.
- **NOT pay-to-win** — all gameplay-affecting items are earned or unlocked via play. Cash shop is cosmetic only.
- **NOT a social platform** — no voice chat, no friend invites, no lobbies. Pure quick-play matchmaking.
- **NOT a looter shooter** — no in-match loot pickups (weapons are loadout-based).
- **NOT playable offline** — online-vs-real-players only. No bots, no single-player mode, no practice against AI.

---

## Inspiration and References

| Reference | What We Take From It | What We Do Differently | Why It Matters |
| ---- | ---- | ---- | ---- |
| **PUBG** | Third-person military feel, weapon-handling weight, over-shoulder camera | Objective-based 5v5 instead of battle royale; browser scale | Validates TPS military feel |
| **Fortnite** | TPS arcade tempo, free-aim reticle, fast respawn satisfaction | No building system; no battle royale; military aesthetic instead of cartoon | Validates TPS arcade pacing |
| **The Division** | Cover-aware TPS, third-person military aesthetic | No cover-snap system (free movement); 5v5 not co-op PvE | Visual feel reference |
| **Battlefield (classic)** | Combined-arms infantry + vehicle chaos | 5v5 not 32v32; browser-scale; third-person | Vehicle fantasy reference |
| **Splitgate** | Browser-scale shooter proves the audience exists | TPS instead of FPS; objective instead of arena | Browser shooter audience validation |

**Non-game inspirations**: Military action films (mobility + chaos pacing); third-person action camera staging.

---

## Target Player Profile

| Attribute | Detail |
| ---- | ---- |
| **Age range** | 14-25 |
| **Gaming experience** | Casual to mid-core FPS players |
| **Time availability** | 10-30 minute sessions, often between other activities |
| **Platform preference** | Browser (school/work computer, no install friction) or low-end PC |
| **Current games they play** | PUBG, Fortnite, Warzone, Splitgate, mobile TPS games |
| **What they're looking for** | Quick skill-expressive TPS with vehicles, no install friction, character cosmetics they actually see |
| **What would turn them away** | Pay-to-win, forced voice chat, bloated downloads, matchmaking waits >60 sec, first-person view |

---

## Technical Considerations

| Consideration | Assessment |
| ---- | ---- |
| **Recommended Engine** | **Godot 4.3** (already pinned). HTML5 export, acceptable for 5v5 scope |
| **Key Technical Challenges** | Netcode (highest risk), vehicle physics sync, browser performance budget, hit registration without lag compensation |
| **Art Style** | Stylized low-poly 3D (reduces asset load time for browser; faster production for small team) |
| **Art Pipeline Complexity** | Medium — leverage Synty / asset store packs for characters/weapons; custom map geometry only |
| **Audio Needs** | Moderate — weapon audio and vehicle audio are critical to feel; drone audio (post-MVP) is gameplay-relevant |
| **Networking** | Client-Server via Godot MultiplayerAPI + WebSockets. Authoritative server, no rollback/lag-comp at MVP |
| **Content Volume** | MVP: 1 map, 3 classes, 2 vehicles, ~4 weapons. Post-MVP: +maps, +skins, +drone |
| **Procedural Systems** | None |

---

## Risks and Open Questions

### Design Risks
- **Vehicle balance may dominate infantry play** — if helicopter is too strong, infantry combat becomes secondary and the gunplay pillar collapses
- **Browser players may have FPS/latency variance** that makes competitive play feel unfair
- **5v5 with 2 vehicles may leave too few infantry** — 3 infantry vs 1 tank + 1 heli per side could feel empty

### Technical Risks (CRITICAL — see Scope Risks)
- **Netcode from zero experience in 15 days is the single highest-risk item in this plan.** Without lag compensation, hit registration will feel bad for any player above ~80ms ping
- **Vehicle physics sync** (especially helicopter 6DOF) is substantially harder than infantry sync; both vehicles compound the risk
- **HTML5 export performance** in Godot 4.3 has limits (no threading on web, WASM overhead) — 5v5 + vehicles + effects may strain budget
- **No anti-cheat at MVP** — browser clients are trivially modifiable; expect wallhacks/aimbots within days of public release

### Market Risks
- **Browser FPS audience is skin-deep** — players bounce fast; retention requires strong core loop on day 1
- **Loot boxes/cases are legally regulated** in Belgium, Netherlands, parts of Germany, scrutinized in UK/EU. **Strong recommendation: direct skin sales instead of cases** when monetization is added

### Scope Risks (HIGH — team-accepted)
- **15-day timeline for all listed MVP features (5v5 netcode, 2 vehicles, classes, weapons, map, animations, reload) is not realistic for a 2-person AI-assisted team with no prior multiplayer shipping experience.** This is documented here as a paper trail. The team has chosen to proceed with this target; expectation-setting and a fallback plan follow below.
- **No fallback plan.** Team has explicitly cut bots and single-player modes (online-vs-real-players only). If multiplayer breaks close to day 15, there is no shippable product. This is documented as accepted risk.
- **Cut-order if time runs out (first to be cut, last):**
  1. Drone (already deferred)
  2. Second vehicle (helicopter is harder — cut helicopter first, ship with tank only)
  3. Reload animations (use flash/swap instead of full anim)
  4. Third weapon
  5. Map polish / visual quality

### Open Questions
- What's the actual match-making flow in-browser? (Lobby browser? Quick-play button? Room codes?) — needs `/architecture-decision`
- Server hosting: dedicated server, peer-host, or relay? Cost model? — needs technical spike
- How do we handle a player leaving mid-match in 5v5? (Bot fill? Forfeit?) — defer to post-MVP

---

## MVP Definition

**Core hypothesis**: *Browser-native combined-arms objective shooting is fun
enough to retain players across multiple sessions in a 15-day development
window.*

**Required for MVP** (Day 15 target, risk accepted):
1. 5v5 networked match via Godot MultiplayerAPI + WebSockets
2. One map with three capture points
3. Two classes: Assault (AK) and Heavy (RPG). No pistol, no sidearms.
4. Two vehicles: tank and helicopter, with HP, weapons, and counter-play
5. Basic reload + movement + shoot animations (quality bar: functional, not polished)
6. Match flow: click Play → quick-match into live match → score → results → re-queue
7. Win condition: capture-point income + kills at time expiry
8. Respawn rule: respawn at team base, OR at any capture point currently held by your team

**Explicitly NOT in MVP** (defer):
- Drones
- Skins, cases, monetization
- Progression, XP, unlocks
- Skill-based matchmaking (MVP uses simple quick-match queue)
- Anti-cheat
- Friend invites, lobbies, room codes, voice chat, ping system
- Bots, single-player, practice mode
- Audio polish, VFX polish
- Multiple maps
- Lag compensation, client prediction beyond Godot defaults

### Scope Tiers

| Tier | Content | Features | Timeline |
| ---- | ---- | ---- | ---- |
| **Target MVP** | 5v5 online, 1 map | All listed MVP features | Day 15 target (no fallback) |
| **Public Beta** | 5v5 online, 1 map, basic matchmaking | MVP + lobby browser + stats | +2 months |
| **Polish Release** | +1 map, drone, skin shop | Full audio/VFX polish, anti-cheat pass, direct skin sales | +4-6 months |

---

## Next Steps

- [ ] Get concept approval from `creative-director`
- [x] Engine pinned — Godot 4.3 (already configured)
- [ ] Decompose concept into systems (`/map-systems`)
- [ ] Create first architecture decision: **Networking approach** (`/architecture-decision`)
- [ ] Prototype core loop — infantry gunplay first (`/prototype gunplay`)
- [ ] Plan Day-0 to Day-15 sprint (`/sprint-plan new`)
- [ ] Second architecture decision: **Vehicle physics/sync** before day 5
