# Web Export & Asset Loading

> **Status**: Designed (thin spec — infrastructure layer)
> **Author**: Claude Code Game Studios session
> **Last Updated**: 2026-04-14
> **Implements Pillar**: Matches Start Fast (fast initial load = fast time-to-first-match)

## Overview

This system covers how Ironclash is packaged for browsers (Godot 4.3 HTML5
export), how assets are delivered progressively, and how the client transitions
from "page loaded" to "in a match." Goal: first meaningful paint of the main
menu within 10 seconds on a 25 Mbps connection; full asset load within 60
seconds.

## Player Fantasy

The player opens the URL, sees "Ironclash" and the Play button quickly, clicks
Play, and is in a match. Every second of load time is a second the player
might leave. This system succeeds by being short.

## Detailed Design

### Core Rules

- Ironclash ships as a single-page application: `index.html` + `game.wasm` + `game.pck` + assets
- Assets are split into **load tiers**:
  1. **Tier 1 — Immediate**: Engine WASM, UI font, main menu textures. Must load before menu shows. Target: <15 MB gzipped.
  2. **Tier 2 — Pre-match**: Map geometry, player/vehicle meshes, weapon meshes. Loads in background while player is in main menu. Target: <60 MB gzipped.
  3. **Tier 3 — Streamed**: Hi-res textures, VFX particles, additional audio. Loads on-demand during match.
- Server is contacted (WebSocket handshake) only after Tier 2 is complete
- If Tier 2 fails to load → show retry button; do not match the player into a game

### States and Transitions

| State | Description |
|---|---|
| `loading_tier_1` | Engine + menu assets downloading. Show load bar. |
| `menu_ready` | Main menu interactive. Tier 2 loading in background. |
| `ready_to_queue` | Tier 2 complete. "Play" button enabled. |
| `in_match` | Tier 3 streaming on demand. |

Transitions flow top-to-bottom only. No rollback — a failed load is an error state with retry.

### Interactions with Other Systems

- **Main Menu** (consumer): blocks "Play" button until `ready_to_queue`
- **Networking** (consumer): initiates server handshake only in `ready_to_queue`
- **All assets** (upstream): this system is the loader; every other system reads its assets through this

## Formulas

**Estimated load time (tier 1):**
`load_time_seconds = tier_size_mb * 8 / connection_mbps`

Example: 15 MB tier on 25 Mbps = 4.8 seconds (before gzip decompress overhead).

**Compression ratio target:**
Gzip typical: 3-5× for WASM, 2-3× for textures. Source sizes should be ~2× the target compressed tier sizes.

## Edge Cases

- **Browser cache hit** → near-instant load; skip to `menu_ready` immediately
- **Partial load failure** (network drop mid-tier) → show error, "Retry" button
- **Tier 2 takes >60s** → continue showing "loading" but allow menu interaction (settings, quit)
- **WebAssembly disabled in browser** → show "Your browser does not support WebAssembly" error page
- **Local storage full** → fall back to session storage; warn user that settings won't persist

## Dependencies

**Upstream (depends on):**
- Godot 4.3 HTML5 export pipeline
- Web host / CDN serving `.wasm`, `.pck`, asset files

**Downstream (depended on by):**
- Main Menu (hard — cannot show until Tier 1 loaded)
- Networking (hard — only connects after Tier 2)
- All gameplay systems (hard — they load assets through this pipeline)

## Tuning Knobs

| Knob | Range | Default | Effect |
|---|---|---|---|
| `tier_1_size_budget_mb` | 10-30 MB | 15 MB | Cap on immediate-load bundle |
| `tier_2_size_budget_mb` | 30-100 MB | 60 MB | Cap on pre-match load |
| `tier_3_size_budget_mb` | 50-200 MB | 125 MB | Cap on streamed assets |
| `load_timeout_seconds` | 30-180 | 120 | When to show error on stuck load |
| `retry_attempts` | 1-5 | 3 | Auto-retry count before hard error |

## Acceptance Criteria

- [ ] Tier 1 loads in <10 seconds on 25 Mbps connection (measured p50)
- [ ] Main menu is interactive before Tier 2 finishes
- [ ] Total bundle gzipped is under 200 MB
- [ ] Load bar shows percentage accurately (not stuck at 0% or 100%)
- [ ] Failed loads show a clear retry UI, not a silent hang
- [ ] Browser cache reuse works on repeat visits (verify via DevTools Network tab)

## Open Questions

- CDN choice: Cloudflare Pages, itch.io hosting, self-hosted? (Ties into ADR-0002)
- Asset versioning / cache busting strategy — simple build hash append?
- Mobile browser support: explicitly unsupported at MVP; what error to show?
