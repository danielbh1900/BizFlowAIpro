# BARINV Master Handoff

> **Document purpose.** Engineering-grade handoff for BARINV Pro. Written for a future engineer, a product-minded reviewer, or a technical operator who needs to pick up the project safely.
>
> **Honesty covenant.** Unresolved issues are called out. Partially validated work is flagged as such. Legacy paths and traps are disclosed. This is not marketing.
>
> **Repo HEAD at time of writing:** `9d21cd8` on `main`, 34 commits ahead of origin.
> **Date:** 2026-04-22
> **Latest safe point:** `safe_point_setup_bars_unified`
> **Latest SW cache version:** `barinv-v307`

---

## 1. Executive Overview

BARINV Pro is a multi-tenant inventory-management SaaS for bars, nightclubs, event venues, and similar hospitality operations. It tracks liquor from stockroom to bar to pour, reconciles against POS sales (Square), and flags unexplained loss.

### Shape of the codebase

- **Single-file app.** `www/index.html` is **19,898 lines** as of this handoff. All UI and business logic live here except `www/variance-engine.js` (854 lines of pure-function math, Node-testable) and `www/sw.js` (80-line service worker).
- **Capacitor 8 wrapping iOS WKWebView** for the native app. Same HTML runs as a browser PWA. iOS project at `ios/App/App.xcodeproj`. Build flow: `npm run build` → `npx cap copy ios` → Xcode Cmd+R.
- **Supabase backend** (project ref `uzommuafouvaerdvirzf`, region `us-east-1`, Postgres 17.6). RLS enforces per-venue access. Edge Functions handle Square integration and per-assignment staff sessions.
- **42 base tables + 4 new Opening tables + 1 new night_bars table** in `public` schema as of this handoff.

### What works well right now

- Core dispatch → events → variance pipeline (variance engine is 88/88 passing as of Phase-1 Giveaways).
- Block Mode navigation, added in the last few weeks and iterated four times: tile launcher with search, pinned favorites, per-section back bar, real history-aware back.
- Per-bar Opening PAR foundation — Phase-1 schema + selection-driven editor shipped and live-validated at the data layer.
- Historical per-night bar integrity (`night_bars`) — schema applied, data backfilled from transactional evidence, auto-trigger keeps new nights snapshotted automatically.
- Dispatch Quick Mode — task-driven tap-to-apply cards with a sticky action bar.
- Readability (WCAG-AA compliant `--muted`) and max-width expansion for bigger displays.

### What is only partially working or only code-level verified

- **The Setup → Bars regression fix (v307).** Code-correct, DB source-of-truth unified, but **runtime acceptance on device is pending the user's tap-through**. Until that clears, v307 is not "accepted."
- **Opening workflow UI** does not exist yet. The data foundation (tables, trigger, backfill RPC, PAR editor) is ready; the admin generate / issue / receive UI and barback-side flow are still to be built.
- **Fallback visibility** on `night_bars` is now a deduped toast + console.warn, but the surface hasn't been battle-tested against many real nights.

### What is unstable or unresolved

- **BLE scale connection.** Discovered but not reliably connecting on Arboleaf / QN-KS via `@capacitor-community/bluetooth-le`. Native Swift `CoreBluetooth` bridge is the queued next step.
- **POS accuracy / completeness.** Pour-size detection, Square catalog→item mapping, variance-engine edge cases all have known open issues.
- **Staff and stations per-night** still use `localStorage` per device — the exact class of bug that `night_bars` just fixed for bars. Not drift-fixed yet; deliberately out of X2 scope.

### Maturity

Core operational flows (dispatch, variance, reports) are production-stable. Architecture decisions and data integrity are strong. UX is in active iteration and still rough in places. Two significant features (BLE, POS) are non-trivial unsolved problems that should not be conflated with the rest of the system's stability.

---

## 2. Current Health Assessment

### Stable

| Area | Why stable |
|---|---|
| Supabase backend + RLS | Venue-scoped policies; `has_venue_access(v, min_role)` helper used consistently. 47 migrations applied cleanly over time. |
| Variance engine | Pure functions, no side effects, 88/88 Node tests passing as of Phase-1 Giveaways ship. |
| `events` transaction log | Unchanged in recent work. All reports read from it. |
| Block Mode nav shell | Additive — never overwrote Classic. Rolled back freely between v1/v2/v3 without regression. |
| Per-bar PAR foundation (`opening_par_profiles`, `opening_par_items`) | Smoke-tested live via SQL (upsert independence across bars confirmed). |
| `night_bars` schema + trigger + backfill | Inline backfill verified on real data: SHOWTEK=9 bars, Rock Show=2 bars, matching distinct `(night_id, bar_id)` pairs in `events`. |

### Fragile

| Area | Why fragile |
|---|---|
| `getActiveBarsForNight(nightId)` | Sync → async conversion. 8 call sites plus 3 sync-to-async wrappers changed together. Any caller that was missed silently returns a Promise into a `.filter(...)` chain. No runtime test has landed yet. |
| Setup → Bars post-v307 | Freshly rewritten to write `night_bars` instead of global `bars.active`. Runtime not yet validated by user on device. |
| PAR Levels selection-driven | Three render branches (0/1/2+ bars) inside one function. Adding a 4th state (e.g., locked for non-admin) would touch many branches. |
| Dispatch Quick Mode | `dspQuickApply` bypasses the confirmation modal for Take/Return for speed. If a bug causes misattribution of actions, there's no confirm-step backstop. |

### Risky

| Area | Why risky |
|---|---|
| BLE scale code paths | Connection is unresolved. Code is defensive (isolated behind feature flags and a dedicated BLE Debug page) but there has been a lot of trial-and-error. Any change here should be expected to reveal new failures. |
| POS (Square) catalog mapping | Real-world venues have inconsistent product names and pour-size conventions. Known edge cases are not fully characterized. |
| Scoped-staff JWT flow | Works, but there's no session-extension / rotation. Shift turnover requires admin to re-issue codes. |
| `items.par_level` vs `opening_par_items` parallel existence | Intentional — two different dimensions (low-stock vs Opening PAR). But two places to edit PAR-sounding numbers is a documentation / UX gap, and there's no cross-link. |

### Misleading

| Area | Why misleading |
|---|---|
| README region field | README says `ca-central-1`; actual Supabase project is in `us-east-1`. Minor doc drift. |
| "Active bars are saved per night" subtitle in Setup → Bars | Pre-v307 this was **false** — Setup wrote to global `bars.active`. Post-v307 it is **true**. The text didn't change; the plumbing did. |
| "Set Active for Night" / "Set Inactive for Night" buttons | Post-v307 they are genuinely per-night. Pre-v307 they were not. Still named the same way. |
| `items.par_level` single field | Users may assume this is "opening par." It is not — it is the global low-stock indicator. Opening PAR lives in `opening_par_items`. |

### Do not assume done

- Opening workflow UI (only the foundation ships).
- Variance engine integration for `action='OPENING'` (no such events exist yet, so not blocking, but must be added when Opening workflow UI starts emitting them).
- Staff/stations per-night parity with bars.
- Localization (not started).
- BLE (unsolved).
- POS accuracy (ongoing).

### Overall status

**Conditionally healthy.** Core pipeline solid; recent work has measurably improved UX and data integrity; but the most recent integrity fix (v307) is code-only, not runtime-validated. Hold new feature work until that validation lands.

---

## 3. Priority Stack

### P0

1. **Runtime acceptance of v307** on device. Until the user confirms Setup → Bars → Dispatch sync works for SHOWTEK and Rock Show independently, nothing else should ship.
2. **BLE scale connection.** Business-critical hardware integration is non-functional. Native Swift `CoreBluetooth` bridge is the known next step.
3. **POS accuracy / completeness.** Ongoing; affects variance reliability.

### P1

1. **Staff per-night** migration to a DB-backed model (same pattern as `night_bars`).
2. **Stations per-night** migration to a DB-backed model.
3. **Opening workflow UI** (admin Generate → Issue → Receive, barback view, exception resolution, cancellation).
4. **Variance engine `OPENING`** integration (2-line change plus tests, bundled with Opening workflow UI rollout).

### P2

1. **Localization framework** (English-only scaffold first, then per-surface migration, then translations).
2. **Dispatch polish:** Undo toast after silent Quick-Mode applies; floating Save CTA; keyboard shortcuts.
3. **Block Mode polish:** recently-visited row, drag-to-reorder pins, cross-device pinned favorites (Supabase-backed).
4. **Reports polish:** PAR compliance report, Opening summary report, exception log.
5. **Setup / Nights editor consolidation decision** — do we keep two entry points for the same data (Setup → Bars + Nights → 🍸 Bars)?

---

## 4. Product Truth and System Philosophy

### Historical truth vs current venue state

BARINV is an operations + audit product. Those two missions pull in different directions:

- Operations needs **current state** — who's behind which bar tonight, what's currently in stock, what's happening at 11:47 PM.
- Audit needs **historical state** — what was true on Friday three weeks ago, when a variance report was generated, when a bottle was signed over.

The product must preserve both, not one. That is why `night_bars` exists separately from `bars.active`, and why `opening_run_items.par_qty` is snapshotted at generation time rather than read live from the template.

### Per-night truth vs global venue state

Specific design commitments:

- **`bars`** holds the venue's roster. `bars.active` is the global "is this bar still part of our operation?" flag. It's not per-night.
- **`night_bars`** holds per-night membership. One row per `(night_id, bar_id)`. Added automatically on new-night insert via trigger, editable by admin, historical by design.
- **`bar_name_at`** on `night_bars` captures the bar's name as it was when the row was added. If a bar is later renamed, history still reads the old name **from that column**. But day-to-day display shows the live name when available (see Decision Log §17 for the full rationale).
- **Events (`events.bar_id`)** are the authoritative transaction record. They can reconstruct "which bars had activity on night X" independently of `night_bars` — which is exactly what the `night_bars` inline backfill used.

### Operational usability vs audit truth — the live-name rule

When showing bar names in UI, BARINV currently uses the **live name when the bar exists**, and falls back to `bar_name_at` only when the bar has been removed. This is a deliberate choice (Option B in the decision log). Operators recognize bars by the name on the physical sign in front of them; renames almost always improve clarity. Audit integrity is preserved by keeping `bar_name_at` immutable in the database — a future audit screen can show it if needed.

### Why BARINV must preserve night-specific state

Three real failure modes justify the architecture:

1. **Variance drift.** A variance report from three weeks ago should reproduce exactly if re-run today. If the underlying bar list can change under it, reports become unreproducible.
2. **Accountability integrity.** "Your bar dispatched X bottles" requires that "your bar" means the same thing today as it did that night.
3. **Dispute resolution.** A manager arguing with a vendor, a bartender, or an owner needs the system to say what was true, not what is true.

### Why two editors for per-night bars

The user explicitly asked for both:

- **Setup → Bars → Configure for Night** — admins' natural-home for bar configuration. Bulk toggles per night.
- **Nights → 🍸 Bars editor** — admins operating from the Nights page can quickly edit one night's bar set without leaving that context.

Both paths now write to the same `night_bars` table. No divergence is possible at the data layer. Whether they should eventually collapse into one UI is an open question (§18).

---

## 5. Architecture Overview

### Frontend

- **`www/index.html`** is the whole app UI. ~19,900 lines. Every page, every modal, every renderer lives here. Editing is straightforward; discipline comes from code review, not from module boundaries.
- **`www/variance-engine.js`** — pure functions for POS↔inventory math. Node-testable via `node www/variance-engine-tests.js`. Source of truth for variance reporting. 88/88 tests pass.
- **`www/sw.js`** — service worker. Network-first for HTML (so new versions land on next navigation). Cache-first for assets. Network-only for `*.supabase.co`. Cache key is a single constant `CACHE = 'barinv-vNNN'` that **must be bumped on every ship** or PWA clients will see stale HTML.
- **`www/capacitor.js`** — copied from `@capacitor/core` at build time.

### Runtime model

- Native iOS: Capacitor 8 wraps WKWebView at `ios/App/App/public/`. The iOS build does **not** serve `www/` directly — it serves `ios/App/App/public/`, which is a copy produced by `npx cap copy ios`. Forgetting this step is the most common "why isn't my change showing up?" cause.
- PWA / browser: any static host serving `www/`. Same code, different shell.

### Supabase role

- **Postgres 17** with row-level security across every venue-scoped table.
- **PostgREST** handles CRUD; the client uses `supabase-js` for it.
- **GoTrue** handles auth (email/password for admins; custom-claims JWTs for scoped-staff sessions).
- **Storage** for venue floor-map images (`floor-maps/{venueId}.jpg`).
- **Realtime** enabled on `events` for live dashboard updates.
- **Edge Functions** handle Square integration and per-assignment staff code issuance.

### Storage model

| Where | What |
|---|---|
| Postgres (`public.*`) | All business data: venues, members, bars, staff, items, nights, events, backups, POS credentials, giveaway reasons, Opening tables, `night_bars`. |
| Supabase Storage | Floor-map images. |
| `localStorage` | Per-device preferences: `barinv_mode` (Classic/Block), `barinv_block_pinned`, `barinv_dispatch_view` (quick/detail), `barinv_dsp_dest_open`, `barinv_locale` (planned), DSP draft data, staff map per night, and per-night staff/stations overrides (legacy, still in use). |
| IndexedDB | Offline write queue scaffolding via `openIDB()` (very lightly used; proper offline mode is not built). |
| Memory-only | Session caches keyed by `SESSION.venueId` (e.g., `OPENING_PROFILE_CACHE`, `SETUP_BARS_NIGHT_SET`, `NAV_HISTORY`, `PAR_SELECTED_BARS`, `DSP_SELECTED_BARS`). |

### How key screens read and write data

- **Dispatch** reads items + currently-active destination bars via `getActiveBarsForNight(nightId)` (now async, from `night_bars`). Writes events via `dispatchSave()` — one event per `(bar, item, action)` tuple.
- **PAR Levels** reads/writes `opening_par_items` for the selected bar (1 bar) or selected bars (2+ for bulk edit). Default profile per venue lives in `opening_par_profiles`.
- **Setup → Bars** (post-v307) reads `night_bars` for the selected night via a session cache (`SETUP_BARS_NIGHT_SET`). Writes `night_bars` via bulk upsert/delete.
- **Nights** reads `nights` + `night_bars` summary via `loadNights()`. `🍸 Bars` editor opens a modal that reads `night_bars` rows for that night, lets admin toggle, saves via diffed insert/delete.
- **Variance, Accountability, Events, Staff Perf, Waste, Par Wizard** — all read per-night bars through the same `getActiveBarsForNight()` helper.

### Where legacy behavior still exists

- **Staff per-night** (`SESSION.cache.staff + localStorage['barinv_night_staff_...']`) — old model, not migrated. Works for single-device single-admin use; breaks silently across devices.
- **Stations per-night** — same localStorage model.
- **`items.par_level`** — pre-Opening single-number PAR. Still used by low-stock indicator, Variance, Pour Cost, Accountability, CSV export. Deliberately not removed.
- **`.dsp-legend` CSS class** — unused after Quick-Mode rework; dead but harmless.

### What has been replaced

- `getActiveBarsForNight` went from sync (always global) to async (reads `night_bars`) during X2.
- `Setup → Bars` bulk buttons went from writing `bars.active` to writing `night_bars` during the v307 fix.
- PAR Levels went from a global single-per-item editor to per-bar editor (Opening Phase 1, v302), then to selection-driven (v304).
- Dispatch page got the Quick Mode card layout on top of the older Detail Mode (preserved).

### What is transitional

- The Setup → Bars vs Nights → 🍸 Bars duplication. Both paths now write the same table, but the two editors exist side-by-side. Consolidation decision pending.
- Quick Mode vs Detail Mode Dispatch. Both coexist; Quick is default. No plan to remove Detail, but the lower interaction paradigm for Quick is still under review.
- The fallback path in `getActiveBarsForNight`. Acceptable when no snapshot exists, but should be eliminated as every edge-case night gets a snapshot via backfill or admin editor.

---

## 6. Source of Truth Map

| Operational area | Source of truth | Readers | Writers | Old / broken path |
|---|---|---|---|---|
| **Per-night bar membership** | `night_bars` table | Dispatch, Variance, Accountability, Events log, Par Wizard, Staff Performance, Waste, End-of-Night, `dspTransfer`, Setup → Bars editor (post-v307), Nights → 🍸 Bars editor | Setup → Bars (post-v307), Nights → 🍸 Bars editor, `nights_snapshot_bars_ai` trigger (AFTER INSERT on `nights`), `backfill_night_bars(v_venue_id)` RPC | Pre-X2: `bars.active` (global, ignored nightId). Between X2 and v307: split truth — Dispatch read `night_bars`, Setup → Bars still wrote `bars.active`. v307 unified both on `night_bars`. |
| **Venue-level bar roster** | `bars.active` column | New-night trigger (seeds snapshot from active bars), PAR Levels when no night is selected, various dropdowns, Edit Bar modal | Edit Bar modal (global toggle) | No change. This flag is still valid — just not per-night anymore. |
| **Opening PAR target qty (per bar, per item)** | `opening_par_items (profile_id, bar_id, item_id, qty)` | PAR Levels editor (both single and bulk modes) | PAR Levels editor via upsert with `ON CONFLICT (profile_id, bar_id, item_id) DO UPDATE` | Pre-Opening: `items.par_level` (single field per item, not per-bar). That column is retained for a different purpose (below). |
| **Low-stock alert threshold** | `items.par_level` column (global per item) | Cost Center low-stock indicator, Variance report, Pour Cost, Accountability, Waste report, CSV export | Items CSV import (bulk), Cost Center edit flow | Never changed. Parallel to, not replaced by, `opening_par_items`. |
| **Transactional events (dispatch, return, comp, etc.)** | `events` table | Variance engine, all reports, Dashboard realtime, Block Mode leaderboard | Dispatch save, Submit Event form, Clicker, Barback Submit, various RPCs | Unchanged; has been authoritative since v1. |
| **Bar close summaries** | `bar_close_summaries` | End-of-Night, Variance cross-checks, X2 backfill | End-of-Night save | Used by X2 backfill to reconstruct `(night, bar)` evidence. |
| **Staff per-night membership** | `localStorage['barinv_night_staff_<venue>_<night>']` **(legacy, fragile)** | Setup → Staff per-night checkboxes, `getActiveStaffForNight()` | Setup → Staff per-night bulk buttons | Never migrated. Same class of drift bug that `night_bars` just fixed for bars. Per-device only. Not synced across devices. |
| **Stations per-night membership** | `localStorage['barinv_night_stations_...']` **(legacy, fragile)** | Setup → Stations per-night, `getActiveStationsForNight()` | Setup → Stations per-night bulk buttons | Same as staff. Same migration pattern needed. |
| **Block Mode pinned favorites** | `localStorage['barinv_block_pinned']` | Block Mode launcher L1 | Pin/unpin toggle on each tile | Intentionally local; cross-device is Phase-2. |
| **Block Mode active pick (Classic/Block)** | `localStorage['barinv_mode']` | App startup routing (`navigateHome()`) | Mode chooser, topbar 🔀 switcher | Stable. |
| **Dispatch view (Quick/Detail)** | `localStorage['barinv_dispatch_view']` | `dspRenderCards` branch | View toggle in Quick action bar | Stable. |
| **Selected destinations for Dispatch (per venue+night)** | `localStorage['barinv_dsp_bars_<venue>_<night>']` | Dispatch render | Toggle bar chip / Clear All | Stable. Starts empty per safety fix in v301. |
| **Nav history (Block Mode Back button)** | In-memory `NAV_HISTORY` (capped at 20) | Block Back button pop | `navigateTo()` push; `switchAppMode()` clear | Session-scoped by design. |
| **Opening run workflow** | `opening_runs` + `opening_run_items` (Phase-1 foundation) | No client reads yet (UI not built) | No client writes yet | Foundation shipped, UI pending. |
| **PAR profile currently edited** | Memoized per `SESSION.venueId` in `OPENING_PROFILE_CACHE` | PAR Levels editor | Populated once per venue switch | Cache is invalidated on venue change by key match. |
| **Floor map** | Supabase Storage `floor-maps/{venueId}.jpg` | VIP Tables floor-plan view | `uploadFloorMap()` | Stable. |

---

## 7. Database and Schema Map

Table listings below cover the tables that matter most for operational correctness and recent changes. Complete schema reference lives in `README.md` §5 and the Supabase dashboard.

### `nights`

| Aspect | Value |
|---|---|
| Purpose | Per-venue night / shift container. |
| Key columns | `id UUID PK`, `venue_id UUID NOT NULL REFERENCES venues(id)`, `name TEXT`, `date DATE`, `code TEXT NOT NULL`, `active BOOLEAN`. |
| Constraints | Cascade from venue. |
| Behavior note | **AFTER INSERT trigger `nights_snapshot_bars_ai`** auto-populates `night_bars` from currently-active venue bars. |
| Status | Current. |

### `bars`

| Aspect | Value |
|---|---|
| Purpose | Per-venue bar roster. |
| Key columns | `id UUID PK`, `venue_id`, `name TEXT`, `active BOOLEAN`. |
| Constraints | Cascade from venue. **ON DELETE RESTRICT** from `night_bars` (cannot hard-delete a bar referenced by historical nights). |
| Behavior note | `active` is the venue-level roster flag, not per-night. Used as the seed for new-night snapshots. |
| Status | Current. |

### `events` (transaction log)

| Aspect | Value |
|---|---|
| Purpose | Central transaction log. Every inventory movement, comp, shot, promo, waste, breakage. |
| Key columns | `id`, `venue_id`, `night_id`, `bar_id`, `station_id`, `item_id`, `submitted_by TEXT` *(legacy)*, `qty`, `action TEXT NOT NULL`, `status`, `notes`, `reason_code` *(Phase-1)*, `qty_basis` *(Phase-1, CHECK IN ('shot','item_unit', NULL))*, `created_at`. |
| Valid `action` values | `REQUEST`, `DELIVERED`, `RETURNED`, `SOLD`, `ADJUSTMENT`, `COMP`, `SHOT`, `PROMO`, `WASTE`, `BREAKAGE`. No CHECK constraint on `action`. |
| Indexes | `idx_events_giveaway` on (venue_id, night_id, action) WHERE action IN giveaways. |
| RLS | Split paths for admin (`events_insert_v`: staff+ for non-giveaway, manager+ for COMP/SHOT/PROMO/WASTE/BREAKAGE) and scoped-staff (`events_staff_insert`: bar-restricted, blocks giveaway actions). |
| Status | Current. Also the authoritative source for `night_bars` historical backfill. |

### `night_bars` *(X2)*

| Aspect | Value |
|---|---|
| Purpose | Per-night bar-membership snapshot. Source of truth for which bars belonged to each night. |
| Key columns | `id UUID PK`, `night_id UUID NOT NULL REFERENCES nights(id) ON DELETE CASCADE`, `bar_id UUID NOT NULL REFERENCES bars(id) ON DELETE RESTRICT`, `bar_name_at TEXT NOT NULL` (snapshot name), `created_at TIMESTAMPTZ DEFAULT now()`. |
| Constraints | `UNIQUE (night_id, bar_id)`. |
| Indexes | on `night_id`, on `bar_id`. |
| FK behavior | Cascade from night (delete the night, delete its snapshot rows). Restrict from bar (cannot hard-delete a bar referenced by any historical night). |
| RLS | Viewer+ SELECT, admin+ INSERT, admin+ DELETE. **No UPDATE policy** — snapshots are add/remove only, so history cannot be silently rewritten. |
| Status | Current. Backfilled from `events` + `bar_close_summaries` at migration apply time. Auto-filled for new nights via trigger. |

### `opening_par_profiles` *(Opening Phase 1)*

| Aspect | Value |
|---|---|
| Purpose | PAR template per venue. One default "Standard" profile per venue today; schema supports multi-template later (e.g., "Large Event", "VIP Night"). |
| Key columns | `id`, `venue_id`, `name`, `is_default BOOLEAN`, `active BOOLEAN`, `created_by`, `created_at`. |
| Constraints | `UNIQUE (venue_id, name)`. |
| Indexes | Partial unique index `opening_par_profiles_one_active_default_per_venue` — at most one default per venue where `is_default=true AND active=true`. |
| RLS | Viewer+ SELECT, manager+ INSERT/UPDATE, admin+ DELETE. |
| Status | Current. Seeded one "Standard" row per existing venue at migration apply time. |

### `opening_par_items` *(Opening Phase 1)*

| Aspect | Value |
|---|---|
| Purpose | Per-bar per-item PAR target quantity inside a profile. |
| Key columns | `id`, `profile_id`, `bar_id`, `item_id`, `qty NUMERIC CHECK (qty >= 0)`, `created_at`, `updated_at`. |
| Constraints | `UNIQUE (profile_id, bar_id, item_id)`. |
| Indexes | on `(profile_id, bar_id)`. |
| Trigger | `opening_par_items_set_updated_at` BEFORE UPDATE, sets `updated_at = now()`. |
| FK behavior | Cascade from profile, bar, or item. |
| RLS | Viewer+ SELECT, manager+ INSERT/UPDATE/DELETE (all via the parent profile's venue scope). |
| Status | Current. Written by the PAR Levels editor in single and bulk modes. |

### `opening_runs` *(Opening Phase 1 foundation)*

| Aspect | Value |
|---|---|
| Purpose | Nightly workflow container — one row per (night, bar, profile). |
| Key columns | `id`, `venue_id`, `night_id`, `bar_id`, `profile_id NOT NULL`, `status` CHECK IN (`DRAFT`, `ISSUED`, `RECEIVED`, `CANCELLED`), `has_exception BOOLEAN`, `notes`, `cancel_reason`, actor columns (`created_by`, `prepared_by`, `issued_by`, `received_by`, `cancelled_by`), matching timestamps. |
| Constraints | `UNIQUE (night_id, bar_id, profile_id)`. **`profile_id` is NOT NULL** to keep the uniqueness constraint clean (SQL treats multiple NULLs as distinct). |
| Indexes | `(venue_id, night_id, status)`, `(night_id, bar_id)`. |
| FK behavior | Cascade from venue, night. Restrict from bar, profile. |
| RLS | Viewer+ SELECT, admin+ INSERT/UPDATE. No DELETE policy — cancellation is a status change. |
| Status | Foundation shipped. No UI yet. No rows in the database. |

### `opening_run_items` *(Opening Phase 1 foundation)*

| Aspect | Value |
|---|---|
| Purpose | Per-line quantities inside an opening_runs row. |
| Key columns | `id`, `run_id`, `item_id`, `par_qty` (snapshot at generation), `issued_qty` nullable, `received_qty` nullable, `exception_note`. |
| Constraints | `UNIQUE (run_id, item_id)`. |
| Indexes | on `run_id`. |
| FK behavior | Cascade from run. Restrict from item. |
| RLS | Viewer+ SELECT, admin+ INSERT/UPDATE (via run's venue scope). |
| Status | Foundation shipped. No UI yet. No rows. |
| Design note | `issued_qty` and `received_qty` are nullable **on purpose** — NULL means "not yet actioned," 0 means "explicitly zero." Different semantics. |

### `bar_close_summaries`

| Aspect | Value |
|---|---|
| Purpose | Per-bar end-of-night snapshots. Written at End-of-Night close. |
| Key columns | Include `night_id`, `bar_id`. |
| Behavior note | Used as secondary evidence by the `backfill_night_bars` RPC. Currently zero rows in the live DB. |
| Status | Current. |

### Other relevant tables *(see README.md §5.1 for full list)*

- `bar_item_dispatch_snapshots`, `bar_item_shot_snapshots`, `pos_bar_snapshots`, `pos_bar_product_snapshots` — **time-bucketed, not night-scoped**. They carry `bar_id` but no `night_id`, so they cannot contribute to the `night_bars` backfill. Useful for other analytics.
- `pos_connections`, `pos_credentials`, `pos_bar_mappings`, `pos_product_item_mappings`, `pos_source_map`, `pos_sync_runs`, `pos_transactions` — POS integration (Square).
- `backup_snapshots` — per-venue JSON payload snapshots; daily cron + pre-clean + pre-restore + manual triggers.
- `venue_members` — `(user_id, venue_id, role)` with role CHECK in `{owner, admin, manager, staff, viewer}`.
- `business_profile` — per-venue settings (`giveaway_reasons` JSONB, terminology presets, Square-connected flag).

---

## 8. Triggers, RPCs, and RLS

### Triggers

| Trigger | On | When | Purpose | Security |
|---|---|---|---|---|
| `nights_snapshot_bars_ai` | `nights` | AFTER INSERT | Auto-populates `night_bars` from `bars WHERE active=true AND venue_id = NEW.venue_id`. | SECURITY DEFINER. Bypasses RLS so every night-creation path (regardless of caller role) gets a snapshot. `search_path = public` set. |
| `opening_par_items_set_updated_at` | `opening_par_items` | BEFORE UPDATE | Sets `updated_at = now()`. | Normal. |

### RPCs (Phase-1 + X2 additions)

| RPC | Auth | Purpose | Notes |
|---|---|---|---|
| `backfill_night_bars(v_venue_id UUID)` | Admin+ on venue, enforced inline. | Reconstructs missing `night_bars` rows for a venue's nights from `events` + `bar_close_summaries` evidence. Returns `(night_id, night_name, bars_inserted)` per night. | SECURITY DEFINER; idempotent (`ON CONFLICT DO NOTHING`); safe to re-run. |
| Existing RPCs from README §5.4 | Various | `create_venue_backup`, `_do_create_backup`, `_backup_all_venues_daily`, `prune_venue_backups`, `restore_venue_backup`, `delete_venue`, `backfill_giveaway_actions`, `has_venue_access`, `has_min_role`, `get_venue_role`, `grant_venue_creator_owner`, `auth_is_scoped_staff`, `auth_scoped_venue`, `auth_scoped_night`, `auth_scoped_bar_ids`, `gen_assignment_code`, `_venue_scoped_tables` | Unchanged by recent work. |

### RLS summary for the new tables

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `night_bars` | Viewer+ | Admin+ | **No policy** (snapshot add/remove only) | Admin+ |
| `opening_par_profiles` | Viewer+ | Manager+ | Manager+ | Admin+ |
| `opening_par_items` | Viewer+ (via profile) | Manager+ (via profile) | Manager+ (via profile) | Manager+ (via profile) |
| `opening_runs` | Viewer+ | Admin+ | Admin+ | **No policy** (cancellation = status change) |
| `opening_run_items` | Viewer+ (via run) | Admin+ (via run) | Admin+ (via run) | **No policy** |

### Where SECURITY DEFINER is used

- `snapshot_night_bars_on_insert()` — needs to write `night_bars` from inside the `nights` INSERT trigger regardless of who's creating the night.
- `backfill_night_bars(v_venue_id)` — runs as owner so it can do the write, but still gates on `has_venue_access(v_venue_id, 'admin')` inside the function body. Raises `42501` if the caller isn't an admin on the venue.
- Existing RPCs (backups, delete_venue, etc.) use the same pattern.

### What still needs review

- **Scoped-staff paths for Opening runs.** Phase-1 foundation locks `opening_runs.status` updates to admin+. When the Opening workflow UI ships, the barback's "Ready for Issue" step (which sets `prepared_by` / `prepared_at`) will need either a dedicated RPC or a relaxed UPDATE policy. Not done yet.
- **`events` RLS for `action='OPENING'`.** Current policy allows any staff+ to insert non-giveaway actions. That's fine for Opening, but we should revisit once the workflow is live and rate-limits / anti-spoof controls become clearer.
- **`has_venue_access()` default `min_role='viewer'`** — behaves as expected in every current call, but the default value is a footgun for any future RLS policy that omits the argument.

---

## 9. Recent Major Changes Log

Ordered newest-first by commit on `main`. Each entry includes the problem, the change, what improved, what risk moved, and acceptance status.

### v307 — Setup → Bars regression fix (`5343b43`)

- **Problem.** After X2 shipped, `Setup → Bars → Configure for Night` still wrote the global `bars.active` flag, while Dispatch now read `night_bars`. Setup changes had no effect on Dispatch for a specific night. Labels claimed "Active bars are saved per night" — the labels were true; the plumbing was not.
- **Change.** Rewired Setup → Bars to read/write `night_bars` directly. New `SETUP_BARS_NIGHT_SET` in-memory cache. `renderBars()` displays per-night membership when a night is selected. `barsBulkSetActive()` now upserts/deletes `night_bars` instead of updating `bars.active`. `loadSetup()` awaits the cache warm-up before rendering.
- **Improved.** Single source of truth is now end-to-end across Setup → Bars, Nights → 🍸 Bars, Dispatch, and all bar-reading reports.
- **Risk moved.** Removed: silent split truth. Added: async `loadSetup` path, a new in-memory cache that can go stale if edits happen outside Setup (mitigation: `renderBarsForNight` on every dropdown change and after every bulk apply).
- **Status.** **Code correct; runtime acceptance on device pending the user's tap-through test.** Do not consider v307 "accepted" until that test lands.

### v306 — X2 fallback visibility (`01b5de3`)

- **Problem.** When `getActiveBarsForNight` fell back to the venue's global active list (because a night had no snapshot, or the lookup errored), nothing in the UI indicated that it had. Silent drift that the user explicitly ruled out.
- **Change.** Inside `getActiveBarsForNight`, added `_nbWarnFallback(reason, nightId)` that emits one `console.warn` + one `t-warn` toast per `(reason, nightId)` per session.
- **Improved.** Drift is surfaced; admin knows which nights lack snapshots.
- **Risk moved.** Tiny: toast spam if an admin bounces between multiple bad nights. Dedupe is per-session; a relaunch re-surfaces unresolved conditions.
- **Status.** Code-level validated. Runtime-surfacing behavior not specifically tested.

### v305 — X2 historical per-night bar integrity (`b7c53c0`)

- **Problem.** `getActiveBarsForNight(nightId)` ignored `nightId`. Every report and every page that asked "which bars for this night?" got the venue's current global active list. History drifted.
- **Change.** New `night_bars` table; AFTER-INSERT trigger on `nights`; `backfill_night_bars(v_venue_id)` RPC; inline one-shot backfill at migration apply time using `events` + `bar_close_summaries`. Client `getActiveBarsForNight` promoted to async, 8 call sites updated. Three sync containers made async. Nights page gained a 🍸 Bars editor.
- **Improved.** Historical truth is now enforced at the DB. Variance / Accountability / Dispatch all show the correct bars per night.
- **Risk moved.** Removed: silent per-night drift. Added: a whole new async hot path (`getActiveBarsForNight`) that can break every caller if regressed. Initially introduced a split-truth regression with Setup → Bars (fixed in v307).
- **Status.** DB layer verified (SHOWTEK=9, Rock Show=2). Runtime acceptance tied to v307 acceptance.

### v304 — PAR Levels selection-driven (`592f2dd`)

- **Problem.** The One/Multiple mode toggle from v303 added an unnecessary decision before the user could edit.
- **Change.** Removed the mode toggle entirely. Behavior now flows from the number of bars selected in the checklist: 0 = empty prompt, 1 = direct auto-save, 2+ = bulk edit with current/new + confirm.
- **Improved.** Faster, more natural UX: select bars → edit → apply.
- **Risk moved.** Removed one bit of UI state; net simplification.
- **Status.** Accepted.

### v303 — PAR Levels multi-bar bulk edit (X1) (`3185e90`)

- **Problem.** Editing per-bar PAR one bar at a time was slow when many bars shared the same qty.
- **Change.** Added mode toggle + bar checklist + mixed-state "current" chip + blank-means-skip "new" input + confirmation modal + batch upsert.
- **Improved.** Saves multiple bars in one call.
- **Risk moved.** Mode toggle introduced an extra decision (corrected in v304).
- **Status.** Superseded by v304. Tag preserved for rollback.

### v302 — Per-bar PAR editor (`7af18d2`)

- **Problem.** `items.par_level` was a single global number per item. Different bars needed different Opening quantities; global PAR couldn't express that.
- **Change.** Replaced the PAR Levels single-bar editor with a per-bar editor backed by `opening_par_items`. Graceful fallback if the migration hasn't been applied yet.
- **Improved.** Per-bar PAR is now the foundation for a real Opening workflow.
- **Risk moved.** Added a new data model that parallels `items.par_level`; the two now coexist with different purposes.
- **Status.** Code + data verified. Supabase migration applied live.

### Opening Phase 1 data foundation (`65a6b74`)

- **Problem.** No schema for Opening (templates, runs, per-line items).
- **Change.** SQL migration file creating `opening_par_profiles`, `opening_par_items`, `opening_runs`, `opening_run_items` with RLS and seed of one "Standard" default profile per venue. `prepared_by` / `prepared_at` on runs for lightweight barback-prep tracking. `profile_id` NOT NULL on runs for clean uniqueness. No RPCs yet.
- **Improved.** Ready to build the Opening workflow UI on top.
- **Risk moved.** New schema introduces terminology ("Opening PAR") that overlaps with existing `items.par_level`.
- **Status.** Applied to production Supabase. Verified with live queries.

### v301 — Compact upper Dispatch + safer default destinations (`3f494fa`)

- **Problem.** The Dispatch page had ~650–900 px of chrome above the items grid. Also, every fresh session started with all bars pre-selected, which was a real workflow-safety issue.
- **Change.** Identity row + inline setup toolbar + collapsed Destinations + slim mode+legend + one-line summary. Default `DSP_SELECTED_BARS = []`.
- **Improved.** Reclaimed ~400 px of vertical space. Operators pick destinations deliberately.
- **Risk moved.** Removed a silent safety hazard.
- **Status.** Accepted.

### v300 — Dispatch Quick Mode (`0242780`)

- **Problem.** Detail Mode cards had 8–10 buttons each, requiring a confirmation modal per tap. 50 items × 3 taps per action = forever.
- **Change.** New Quick Mode with sticky action bar + compact tap-to-apply cards + ⋯ expand for rare controls. Detail Mode preserved byte-identical. Take/Return apply silently with flash; Comp/Shot keep the modal (recipient capture).
- **Improved.** Massive operational speedup.
- **Risk moved.** Silent Take/Return = no confirm-step backstop. Undo toast has not been added yet.
- **Status.** Accepted. User wants Undo toast as a follow-up polish.

### v299 — Real Back + Section Home + readability (`4deff7d`)

- **Problem.** The "BACK TO POS" bar from v298 was actually Section Home wearing a Back label. Also, `--muted` (`#555` dark / `#8e8e93` light) was WCAG-AA-failing.
- **Change.** NAV_HISTORY stack (capped 20, session-scoped). Two-button per-page row: `← BACK` (history-aware) + `⌂ SECTION HOME` (deliberate jump). `--muted` bumped to `#9a9a9a` dark / `#6e6e73` light. `.main` max-width caps bumped (1200→1400→1600→1920).
- **Improved.** Three distinct navigation actions (Back / Section Home / Global Home) with distinct visual weight. Dark-mode secondary text is now ≈7:1 contrast.
- **Risk moved.** None significant.
- **Status.** Accepted.

### v298 — Block Mode big BACK bar (`c90c73f`)

- **Problem.** Navigating from `POS → Bar Mapping` to `POS → Connection` required going all the way back to Block Home.
- **Change.** Orange "← BACK TO &lt;section&gt;" bar on every destination page in Block Mode.
- **Improved.** 2-tap section navigation.
- **Status.** Superseded conceptually by v299 (real Back). Tag preserved.

### v297 — Dashboard tile nested-button fix (`8a12802`)

- **Problem.** The Dashboard tile was splitting into three orphaned pieces because `<button>` nested inside `<button>` is invalid HTML.
- **Change.** Outer tile became `<div role="button" tabindex="0">`. Inner pin stayed a real `<button>`.
- **Status.** Accepted.

### v296 — Block Mode search + pinned (`2f0604c`)

- **Problem.** Block Mode launcher had no search; no way to pin frequent destinations.
- **Change.** Universal search at top of launcher (filters all destinations across levels). Per-tile ☆ pin with localStorage persistence. Pinned row above Categories.
- **Status.** Accepted.

### v295 — Block Mode v1 (`d88034f`)

- **Problem.** Users reported that Classic Mode's menu-hunting was slow and unfriendly to touch.
- **Change.** Second navigation shell: mode chooser on first run, 2-level block launcher, topbar mode switcher. Shared core (zero schema changes, zero business-logic changes). Classic Mode byte-identical.
- **Status.** Accepted.

### v294 — Bulk cost-price CSV import (Phase-2 B2, `6f7cd38`)

- **Problem.** `items.cost_price` coverage was 0/90, blocking cost/margin reports.
- **Change.** New "Upload Cost List" CSV importer on Suppliers page. Matches by SKU with name fallback. Only touches `cost_price`.
- **Status.** Accepted. No user runtime follow-up requested.

### v293 — Leaderboard Night filter + Print PDF iOS share (`6be5fb3`)

- **Problem.** Top Bartender leaderboard only showed Today/Week/Month/Year. Print PDF failed in Capacitor WKWebView.
- **Change.** Added a Night option with per-night dropdown. `printHtml()` detects native platform and routes to iOS share sheet (Files / AirDrop / Print) via existing Filesystem + Share plugins.
- **Status.** Accepted.

---

## 10. Safe Points / Restore Map

All tags below are local. Push with `git push origin <tag>` if sharing.

| Tag | Commit | Captures | When to use | Rollback command |
|---|---|---|---|---|
| `safe_point_setup_bars_unified` | `5343b43` | Setup → Bars write path unified on `night_bars` (v307) | Latest stable; use as the baseline for further work | `git reset --hard safe_point_setup_bars_unified && npx cap copy ios` |
| `safe_point_pre_bar_setup_regression_fix` | (pre-5343b43) | HEAD right before v307 | If v307 itself breaks something | `git reset --hard safe_point_pre_bar_setup_regression_fix && npx cap copy ios` |
| `safe_point_x2_fallback_visible` | `01b5de3` | X2 fallback is no longer silent (v306) | Keep X2 but without v307 unified write | same pattern |
| `safe_point_pre_x2_fallback_visible` | pre-`01b5de3` | Before fallback toast | | |
| `safe_point_night_bars_integrity` | `b7c53c0` | X2 full (v305) — `night_bars` schema + trigger + backfill + async client | If v306 or v307 regresses | |
| `safe_point_pre_x2_night_bars` | pre-`b7c53c0` | Before any X2 code | If X2 itself needs to be rolled back at the SQL + client level | |
| `safe_point_par_selection_driven` | `592f2dd` | PAR Levels selection-driven (v304) | Stable PAR editor state | |
| `safe_point_pre_par_bulk_ux_correction` | pre-`592f2dd` | Before mode toggle removal | | |
| `safe_point_par_bulk_edit` | `3185e90` | PAR Levels v1 of bulk edit (v303) with mode toggle | Historical reference | |
| `safe_point_pre_par_bulk_and_history_audit` | | Clean state before X1 + X2 audit | | |
| `safe_point_pre_phase_validation_and_i18n` | | Clean state before the validation + localization architecture phase | | |
| `safe_point_par_per_bar_editor` | `7af18d2` | Opening Phase-1 per-bar PAR editor (v302) | Stable foundation state | |
| `safe_point_opening_phase1_sql` | `65a6b74` | SQL migration file committed (not yet applied at tag time; now applied) | Reference only | |
| `safe_point_pre_opening_workflow` | | Before any Opening code | Full Opening rollback (client + SQL) | |
| `safe_point_dispatch_upper_compact` | `3f494fa` | Compact upper Dispatch + safer defaults (v301) | | |
| `safe_point_pre_dispatch_upper_rework` | | Before v301 | | |
| `safe_point_dispatch_quick_mode` | `0242780` | Quick Mode (v300) | | |
| `safe_point_real_back_and_readability` | `4deff7d` | Real Back + Section Home + readability (v299) | | |
| `safe_point_block_mode_v3_backbar` | `c90c73f` | Block Mode big BACK bar (v298) | | |
| `safe_point_block_mode_v2_polish` | `2f0604c` | Block Mode search + pinned (v296) | | |
| `safe_point_block_mode_v1` | `d88034f` | Block Mode shell (v295) | | |
| `safe_point_pre_block_mode` | | Clean state before Block Mode | Full Block Mode rollback | |
| `safe_point_bulk_cost_import` | `6f7cd38` | Bulk cost-price CSV import (v294) | | |
| `safe_point_pdf_share_and_night_leaderboard` | `6be5fb3` | Leaderboard Night + Print PDF iOS share (v293) | | |
| `pre_ble_debug_safe_point` | `beca90d` | Pre-BLE-debug clean Phase-1 state | Full rollback of BLE work | |
| `pre_native_ble_attempt` | `ee2c278` | Everything up to BLE aggressive-connect (v285) | | |

The `HOW_TO_RESTORE.md` file in the repo is the current source of truth for these — consult it first.

---

## 11. Critical Runtime Flows

### Setup → Bars (post-v307)

1. Admin navigates to `Setup`, expands the Bars accordion.
2. `loadSetup()` runs: `await renderBarsForNight()` resolves the effective nightId (dropdown value → `SESSION.cache.nights[0].id`), fetches `night_bars` rows into the in-memory `SETUP_BARS_NIGHT_SET`, and calls `renderBars()`.
3. `renderBars()` populates the `setup-bars-night` dropdown and renders each venue bar with a badge: **"in night"** (green) if the bar's ID is in the cache, **"off"** otherwise.
4. Admin selects bars via checkboxes, clicks `Set Active for Night` or `Set Inactive for Night`.
5. `barsBulkSetActive(active)` runs:
   - If `active=true`: upserts `night_bars` rows with `(night_id, bar_id, bar_name_at = bars.name)` using `ON CONFLICT (night_id, bar_id) DO NOTHING`.
   - If `active=false`: deletes `night_bars` rows where `night_id = selected_night AND bar_id IN (selected_ids)`.
6. `await renderBarsForNight()` re-paints with the fresh cache.
7. Toast reports `N bars added to <night>` or `N bars removed from <night>`.
8. **`bars.active` is NOT touched by this path.** Global deactivation goes through the Edit Bar modal.

### Nights → 🍸 Bars editor

1. Admin navigates to `Nights`, clicks `🍸 Bars` on any row.
2. Modal opens titled `Bars for <night.name>`.
3. `openNightBarsEditor(nightId)` fetches current `night_bars` rows for that night, builds a checklist of every venue bar (active and inactive), pre-checks the current members.
4. Admin toggles checkboxes.
5. On Save: diff → `toAdd` (insert) + `toRemove` (delete). `bar_name_at` on new inserts uses the bar's current `bars.name` at the moment of edit.
6. Toast reports `(X added, Y removed)`.
7. Same table as Setup → Bars — both paths are now consistent.

### Dispatch (Quick Mode)

1. Admin navigates to Dispatch (via Block Mode or Classic nav).
2. `loadDispatch()` runs: reads the night selection, calls `await getActiveBarsForNight(nightId)`, renders the destinations checklist.
3. `getActiveBarsForNight` queries `night_bars` for the night. If rows exist: maps each to the live `bars` row for its name (Option B, live-when-exists), or to a ghost `{name: '<bar_name_at> (removed)', _ghost: true}` if the bar no longer exists. If no rows exist: returns the global active list with `_fallback = 'empty'` and fires a deduped toast.
4. Admin selects destinations (the default is empty since v301).
5. The Quick action bar shows `ACTION: [TAKE] [COMP] [SHOT] — QTY: [− 1 +] — VIEW: [Quick|Detail]`.
6. Admin taps an item card. `dspQuickApply(id)` applies the current `(action, qty)`:
   - For Take/Return: silently updates `DSP_STATE[id]`, flashes the card, toast `✓ Take 1× <item>`.
   - For Comp/Shot: delegates to the existing `dspAdj()` modal (recipient capture path preserved).
7. Admin hits Save Session. `dispatchSave()` builds events rows and INSERTs them. On success, `DSP_STATE` clears.

### PAR Levels (selection-driven)

1. Admin navigates to PAR Levels.
2. `loadParLevels()` fetches the venue's default `opening_par_profiles` row (memoized). Renders the bar checklist.
3. Admin selects bars in the checklist.
4. Branching:
   - **0 bars** — `<empty prompt>` "Select one or more bars above to edit Opening PAR."
   - **1 bar** — each item rendered with a single qty input, onchange → `savePar(input)` → `opening_par_items` upsert → toast `Saved`.
   - **2+ bars** — each item rendered with a read-only "current" chip (single value if all selected bars agree, `~` + tooltip if mixed) + blank "new" input. Apply button becomes enabled. Tap Apply → confirmation modal → batch upsert → toast `N items × M bars updated`.
5. Small-venue convenience: if the venue has exactly one active bar and nothing is selected, auto-selects it.

### Historical night switching

Any page that calls `getActiveBarsForNight(nightId)` will re-read `night_bars` fresh on every night-dropdown change. No caching across nights. Each night shows its own snapshot. Pages affected: Dispatch, Variance, Accountability, Events log, Par Wizard, Staff Performance, Waste, End-of-Night, `dspTransfer`.

### Bar activation / deactivation behavior

Two different actions with different effects:

- **Edit Bar modal → Active/Inactive toggle.** Updates `bars.active` globally. Affects: new-night snapshot seed, PAR Levels bar list (when no night is selected), various dropdowns. **Does NOT affect existing `night_bars` rows** (history is preserved).
- **Setup → Bars → Set Active/Inactive for Night** (post-v307). Inserts/deletes `night_bars` rows. Affects: Dispatch, Variance, Accountability, all per-night reports, for that specific night. **Does NOT touch `bars.active`.**

### Fallback behavior

When `getActiveBarsForNight(nightId)` cannot find a snapshot:

1. Returns the venue's global active list as a fallback array.
2. Sets `_fallback = 'empty'` (no rows) or `_fallback = 'error'` (query failed) on the array.
3. Fires a `console.warn` + `t-warn` toast (orange) once per `(reason, nightId)` per session, through `_nbWarnFallback()`.
4. Repeated page renders for the same night don't re-fire the toast. A full app relaunch resets the dedupe.

### Bulk-edit behavior (PAR)

Protected via a confirmation modal before writing. Blank "new" = no change. Explicit `0` = zero out. Payload size `edits × bars` is batched into one Supabase upsert. Per-row errors are surfaced via the returned error object; the user sees `Bulk save failed: <message>` if the whole batch rejects.

### Single-bar vs multi-bar behavior (PAR)

- **1 bar selected** = direct auto-save on each input change. No confirmation.
- **2+ bars selected** = explicit Apply required. Confirmation modal mandatory.

---

## 12. Runtime Validation Checklist

Practical iPad-level checks. Run after `npx cap copy ios` + Xcode Cmd+R + force-quit-and-reopen.

### Setup → Bars → Dispatch sync *(critical — gates further work)*

- [ ] Open Setup → Bars → select SHOWTEK from the Configure-For dropdown.
- [ ] Toggle 2 bars off via `Set Inactive for Night`. Verify toast reports `2 bars removed from SHOWTEK`.
- [ ] Navigate to Dispatch → SHOWTEK. Verify those 2 bars are gone from the destinations list.
- [ ] Back in Setup → Bars → switch to Rock Show. Verify the badges show Rock Show's own membership (different from SHOWTEK).
- [ ] Dispatch → Rock Show. Verify that night's list hasn't changed.

### Historical switching: SHOWTEK vs Rock Show

- [ ] Dispatch on SHOWTEK: expect 9 bars (per last known snapshot).
- [ ] Dispatch on Rock Show: expect 2 bars.
- [ ] Switch back and forth 3 times. Each night's list must stay stable.
- [ ] Same test in Variance (if events exist).
- [ ] Same test in Accountability.

### Nights → 🍸 Bars synchronization

- [ ] Nights page → 🍸 Bars on SHOWTEK. Verify pre-checked set matches what Setup → Bars shows for SHOWTEK.
- [ ] Uncheck one bar, Save. Toast reports `(0 added, 1 removed)`.
- [ ] Go back to Setup → Bars → SHOWTEK. Verify that bar now shows `off`.
- [ ] Tap Dispatch → SHOWTEK. Verify that bar is missing.

### PAR Levels save/load

- [ ] Navigate to PAR Levels. Select one bar. Change a qty. Toast `Saved`.
- [ ] Refresh the page (↺). Verify the qty persisted.
- [ ] Select 2 bars. Observe "current" chip. If values differ: `~` + tooltip. If same: numeric value.
- [ ] Enter a value in one "new" input. Tap Apply. Confirm modal. Save. Toast reports `1 item × 2 bars updated`.
- [ ] Refresh. Both bars show the new value.
- [ ] Select 0 bars. Verify empty prompt appears and Apply is hidden.

### Mixed-state bulk apply

- [ ] Confirm the confirmation modal lists each item on a row with `current → new` in the right colors.
- [ ] Leave every "new" input blank, tap Apply → toast `Enter at least one new value` (no writes).
- [ ] Enter `0` in one "new" input, Apply → verify that bar+item is zeroed.

### Fallback warning behavior

- [ ] (Synthetic test) Open Supabase SQL Editor, run: `DELETE FROM night_bars WHERE night_id = '<some night id>';`
- [ ] In the app, navigate to Dispatch on that night.
- [ ] Expect: orange `t-warn` toast `⚠ No bar snapshot for this night — showing current venue bars.`
- [ ] Navigate to Dispatch on a different night (with snapshot). No warning.
- [ ] Return to the broken night within the same session. No warning (deduped).
- [ ] Force-quit and reopen. Navigate to the broken night. Warning fires once.

### Variance / Accountability correctness

- [ ] Variance Report → SHOWTEK → expect the 9-bar grouping.
- [ ] Variance Report → Rock Show → expect the 2-bar grouping.
- [ ] Accountability → SHOWTEK → same.

### Async regression checks

- [ ] Open Dispatch, Variance, Accountability, Par Wizard, Event Log, Staff Performance in quick succession. None should render `[object Promise]` or an empty bars list (those would indicate a missing `await`).
- [ ] Tap `dspTransfer` from a Dispatch card, verify the target-bar dropdown populates correctly.
- [ ] Tap `dspSelectGroup('bar')` in Dispatch, verify bar-category selection still works.
- [ ] Tap `dspToggleAllBars` (`✦ ALL` chip in Dispatch), verify toggle-all-bars works.

### Smoke tests

- [ ] Force-quit + reopen cleanly loads.
- [ ] Venue switch updates PAR Levels, Dispatch destinations, Nights list to the new venue.
- [ ] Logout + login returns to the correct default home per stored mode.
- [ ] Create a new night. Immediately open Dispatch on that night. Verify `night_bars` was auto-populated by the trigger (list matches the venue's current active bars).

### Smoke tests that are expected to FAIL today *(known limitations)*

- [ ] Staff per-night config on Device A → visible on Device B. **Does not work — localStorage only.**
- [ ] Stations per-night config on Device A → visible on Device B. **Does not work — same.**
- [ ] BLE scale connect on Arboleaf. **Does not work — unresolved.**
- [ ] Square catalog → BARINV item mapping for every SKU. **Not fully correct — ongoing.**

---

## 13. Known Unresolved Issues

### BLE scale unresolved

The Arboleaf / QN-KS family is discovered but does not reliably GATT-connect on iOS 18.x via `@capacitor-community/bluetooth-le` v8.1.3. Aggressive-connect work (v285) did not break through. Ad manufacturer data appears to contain weight info but decoding hasn't been confirmed in a clean room. Next step is likely a native Swift `CoreBluetooth` bridge (~200 lines + Xcode target edit).

**Risk if used today:** the BLE Debug page exposes extensive diagnostics, but no real weigh-on-dispatch path works on the hardware you have. Weighed-return and weighed-dispatch flows exist in `dspWeighDispatch` / `dspWeighReturn`, but require a working scale connection to run end-to-end.

### POS unresolved

Square catalog → BARINV item mapping is incomplete for every SKU. Pour-size detection from the "NoZ - NAME" Square title pattern has edge cases. Variance engine accepts POS orders as ground truth for `ml_expected`, so mapping errors propagate directly into variance reports.

**Risk if used today:** variance numbers for venues with incomplete mappings are unreliable. The variance engine itself (`www/variance-engine.js`) is correct; the inputs aren't.

### Staff / stations per-night not migrated

The same class of bug `night_bars` just fixed for bars still exists for:

- Staff per-night (`localStorage['barinv_night_staff_<venue>_<night>']`)
- Stations per-night (`localStorage['barinv_night_stations_<venue>_<night>']`)

Per-device only; cannot sync across devices; breaks multi-device setups silently.

**Recommended fix:** replicate the `night_bars` pattern exactly: new `night_staff` / `night_stations` tables, same RLS pattern, same trigger on `nights` INSERT for auto-seed, same backfill approach (if any transactional evidence exists for those dimensions), same async `getActiveStaffForNight` / `getActiveStationsForNight` rewrites.

**Effort estimate:** each is ~1 day of focused work. Independent commits. Can be done after user validates v307.

### Opening workflow UI not built

Phase-1 foundation (tables, RLS, trigger, backfill RPC, per-bar PAR editor) is complete. Still to build:

- Admin Generate (bulk-create runs for tonight's bars from default profile)
- Admin Issue (sign off on picked runs, emit events with `action='OPENING'`)
- Admin Receive (mark runs as received)
- Barback prepared-for-issue flow (`prepared_by` / `prepared_at`)
- Exception resolution (manager+ only)
- Cancellation with reason
- Reporting (per-night Opening summary, PAR compliance over time)

### Variance engine OPENING action not integrated

Once Opening workflow UI starts emitting `action='OPENING'` events, those will appear as **unexplained outflow** in variance reports (because `ml_giveaway` currently unions only `COMP|SHOT|PROMO`). Fix is 2 lines in `variance-engine.js` plus one new test case. Must be shipped **with** or **immediately after** the Opening workflow UI, not before (no events yet = no harm yet).

### Localization not started

All UI strings are hard-coded. Persian and French are planned App Store languages. Architecture proposal exists in the conversation history (inline `I18N_STRINGS` registry + `t(key, params)` helper, surface-by-surface migration), but zero code has landed.

### Remaining UX debt

- Dispatch Quick Mode: no Undo toast after silent apply. After the user's positive feedback, this is queued as a high-impact polish.
- Dispatch Quick Mode: no floating Save CTA. Currently the Save Session button lives in the page header which can scroll out of view.
- Block Mode: the "Categories" label was deliberately kept; the user wanted "BACK TO HOME" language consistency, which applied to destination pages, not to section dividers. No known issue.
- Setup → Bars vs Nights → 🍸 Bars redundancy. Two editors for the same data. Both consistent post-v307. Consolidation decision pending.
- `.par-mode-toggle` CSS class remains in the stylesheet but is unused after v304. Harmless; cleanable whenever.

### Confusing legacy overlap still present

- `items.par_level` (global per item) and `opening_par_items.qty` (per bar per item) are both real, both editable, both show in different screens. A user could reasonably wonder "why are there two PARs?" The answer — one is low-stock, one is Opening — is correct but currently undocumented in the UI.
- "Set Active for Night" / "Set Inactive for Night" button names describe the post-v307 behavior accurately but are softer than they need to be. "Include in Night" / "Remove from Night" would be clearer.

---

## 14. Dangerous Areas / Do Not Change Blindly

Every item below has a specific reason. Touching them without understanding the reason will create hard-to-find bugs.

### `getActiveBarsForNight(nightId)` at `www/index.html:~8342`

- **Danger:** `async`. 8 call sites use `await`. Three upstream callers were converted from sync to async (`dspSelectGroup`, `dspToggleAllBars`, `dspTransfer`).
- **Risk of regression:** adding a new call site without `await` returns a Promise into code that then `.filter()`s it. The result is silently wrong (no bars shown) rather than a loud error.
- **Risk of reverting to sync:** all 8 current call sites break simultaneously.

### `night_bars` table + trigger + backfill RPC

- **Danger:** three coordinated pieces. Removing any one breaks the X2 contract.
- **Trigger `nights_snapshot_bars_ai`** — if dropped, new nights won't get snapshots. Past nights are fine but the app silently starts falling back.
- **RLS:** admin-only INSERT/DELETE. No UPDATE. Changing UPDATE policy would let history be silently rewritten.
- **`bar_name_at` column** — the audit-integrity column. Removing it would erase the ghost-name functionality.

### `dispatchSave()` and event emission

- **Danger:** emits the events that every report reads. Changing the shape of records here cascades to Variance, Accountability, Giveaways, POS variance, End-of-Night.
- **Specifically fragile:** the `reason_code` and `qty_basis` columns on `events` have specific CHECK constraint expectations (`qty_basis IN ('shot','item_unit', NULL)`). New action types that don't respect them get rejected at the DB level.

### `preload()` — central data loader

- **Danger:** called on every page navigation. Populates `SESSION.cache` with bars, items, staff, stations, nights, memberships, business profile.
- **Risk:** adding a query here slows down every navigation. Failing silently here hides real problems.

### Service worker cache version

- **Danger:** forget to bump `CACHE = 'barinv-vNNN'` in `www/sw.js` after shipping, and PWA clients see stale HTML indefinitely.
- **Risk:** discovered-by-user bugs look like fixed-but-not-deployed bugs.

### `npx cap copy ios` discipline

- **Danger:** iOS serves `ios/App/App/public/`, not `www/`. Every `www/` edit must be followed by `npx cap copy ios` before Xcode rebuild.
- **Mitigation:** establish it as muscle memory; errored-out tests from "forgot to copy" are a 30-minute debugging waste.

### `items.par_level`

- **Danger:** reads in many reports (low-stock, variance, pour cost, accountability, CSV export, End-of-Night). Renaming or repurposing would cascade.
- **Rule:** leave it alone. `opening_par_items` is the Opening-specific dimension.

### Edit Bar modal's `active` toggle

- **Danger:** writes `bars.active` globally. Post-v307 this is the *only* way to globally deactivate a bar. Users may expect it to also remove the bar from past nights' snapshots — it does not, intentionally.
- **Communication:** if this becomes confusing, a small note in the modal explaining the separation would help. Not added yet.

### Scoped-staff JWT helpers (`auth_scoped_*`)

- **Danger:** RLS policies across `events`, `opening_runs` (future), and several other tables depend on these helpers reading JWT claims correctly.
- **Risk:** refactoring how staff sessions issue or refresh tokens affects a wide policy surface.

### Variance engine (`www/variance-engine.js`)

- **Danger:** pure-function math, 88/88 tests. A subtle change here can flip every variance report.
- **Mitigation:** run `node www/variance-engine-tests.js` before/after any change. If tests fail, stop.

### Async conversions generally

- **Danger:** any function that becomes async affects every caller up the chain that doesn't `await`. TypeScript would catch this; vanilla JS does not.
- **Rule:** after any sync→async change, grep every caller and verify `await` is in place.

---

## 15. File and Function Map

### `www/index.html` (~19,900 lines, the whole app)

Approximate line ranges for the most relevant sections as of this handoff. Use `Grep` to navigate — line numbers drift with every edit.

| Section | Approx. lines | Key symbols |
|---|---|---|
| CSS (theme tokens, layout, component styles) | 16–1650 | `:root`, `:root.light-mode`, `.main`, `.topbar`, `.par-bar-chk`, `.par-mode-toggle` (dead), `.dsp-quick-bar`, `.dsp-card-q`, `.block-*`, `.dsp-setup-strip`, `.dsp-dest-strip` |
| HTML — login / setup wizard | 1700–2100 | |
| HTML — navigation chrome + breadcrumb | 2100–2250 | `.topbar`, `#top-nav` |
| HTML — pages (Nights, Setup, PAR Levels, VIP Tables, etc.) | 2250–3900 | `#pg-nights`, `#pg-setup`, `#pg-par`, `#pg-viptables`, `#pg-dispatch`, `#pg-dashboard` |
| HTML — Dispatch page (upper compact + Quick action bar) | 3830–4000 | `#dsp-quick-bar`, `#dsp-dest-strip`, `#dsp-preview-toggle`, `#dsp-grid` |
| JS — SESSION, auth, venue switching | 3700–4700 | `SESSION`, `startApp`, `switchVenue`, `loadMe`, `loadVenues` |
| JS — Navigation (`navigateTo`, `navigateHome`, NAV_HISTORY, Block Mode helpers) | 4700–5300 | `navigateTo`, `navigateHome`, `goBackInBlock`, `renderBlockLauncher`, `renderBlockBackBar` |
| JS — `preload()` and cache | ~5400 | `preload`, `SESSION.cache` |
| JS — `getActiveBarsForNight` *(X2 critical helper)* | ~8342 | `getActiveBarsForNight`, `_nbWarnFallback`, `_NB_FALLBACK_WARNED` |
| JS — Setup → Bars editor *(post-v307)* | 8283–8550 | `renderBars`, `renderBarsForNight`, `loadSetupNightBars`, `barsBulkSetActive`, `SETUP_BARS_NIGHT_SET` |
| JS — Nights + 🍸 Bars editor | 9228–9380 | `loadNights`, `openNightBarsEditor`, `openAddNight` |
| JS — Variance report | 9600–10100 | `loadVarianceReport`, `exportVariancePDF`, `varianceInlineEdit` |
| JS — PAR Levels *(selection-driven, v304)* | 10435–10700 | `loadParLevels`, `getDefaultOpeningProfile`, `savePar`, `applyParBulkEdit`, `toggleParBar`, `PAR_SELECTED_BARS` |
| JS — Block Mode launcher helpers | 5100–5300 | `renderBlockLauncher`, `renderDestTile`, `toggleBlockPin`, `goToBlocksHome` |
| JS — Opening tables state (cache) | 10400–10500 | `OPENING_PROFILE_CACHE`, `getDefaultOpeningProfile` |
| JS — Dispatch (upper render + quick card + save) | 16870–18720 | `loadDispatch`, `dspRenderCards`, `renderDspQuickCard`, `dspQuickApply`, `dspAdj`, `dspSaveAll`, `dispatchSave`, `dspTransfer` |
| JS — Reports (Accountability, Waste, Staff Perf, etc.) | 11100–13500 | `loadAccountability`, `loadWaste`, `loadStaffPerf`, `loadEndNight` |
| JS — BLE Debug (unresolved work) | 12880–13800 | `bleConnect`, `bleScan`, `bleLog`, etc. |
| JS — Service worker / offline / init | 8760–8900 | `init`, service worker registration, `applyAppModeClass` |
| JS — CSV helpers + template downloads | 17400–17900 | `triggerDownload`, `csvDownload`, `downloadCsvTemplate`, `parseCsvFileFromInput` |

### `www/sw.js` (80 lines)

- `CACHE = 'barinv-v307'` — bump on every ship.
- Shell: `/`, `/index.html`, `/manifest.json` — prefetched on install.
- Fetch strategy:
  - Network-first for HTML (auto-updates).
  - Cache-first for fonts / images / JS / CSS.
  - Network-only for `*.supabase.co`.

### `www/variance-engine.js` (854 lines)

Pure math. No DOM, no SB, no side effects. Tested via `node www/variance-engine-tests.js`. Exports:

- `runVarianceAnalysis({posOrders, events, items, bars, itemMapping})`
- `runTimeWindowVariance(..., minutes)`
- `applyPercentageThresholds(result, low, med, high)`
- `classifyAlcohol(category)`

### Migration files

- `supabase/migrations/20260421_opening_phase1.sql` — Opening Phase-1 foundation. Committed (not auto-applied; applied manually via MCP at session time).
- `supabase/migrations/20260422_night_bars_x2.sql` — X2 per-night bar integrity. Committed and applied.

Each file has a header comment block with purpose, scope, rollback SQL, and explicit exclusions.

### `HOW_TO_RESTORE.md` (repo root)

Current source of truth for safe-point tags, what each captures, and rollback commands. Updated on every new tag. Keep it current.

### `README.md` (repo root)

Project spec. Most fields accurate. Known drift: region field says `ca-central-1`; actual Supabase project is in `us-east-1`.

### Other files

- `www/manifest.json` — PWA manifest.
- `www/img/` — icons, placeholders.
- `www/native/` — iOS-specific Capacitor hooks (tiny).
- `ios/App/App.xcodeproj` — Xcode project. Do not edit directly except for signing + icons.
- `ios/App/App/public/` — **mirror of `www/` produced by `npx cap copy ios`**. Do not edit directly.
- `capacitor.config.json` — iOS + plugin config.
- `package.json` — Capacitor + plugin deps.
- `backups/` (gitignored) — local DB dumps. Canonical backup storage is the `backup_snapshots` table.

---

## 16. Current UX State

### What feels good now

- **Block Mode launcher** — tile-based, search, pinned favorites. Destination in 1–2 taps. Back/Section Home/Global Home all distinct. Contrast is legible.
- **Quick Mode Dispatch** — sticky action bar + one-tap apply + flash feedback + compact cards. Fast operational flow for the most-used page in the app.
- **PAR Levels selection-driven** — pick bars → edit. No mode gate. One interaction model for both single and multi.
- **Compact upper Dispatch** — ~400 px of chrome reclaimed. Items visible on first viewport on iPad.
- **Readability** — `--muted` is now WCAG AA. Tables, badges, metadata are readable without brightness boost.
- **Safe-point discipline** — 26 safe-point tags + `HOW_TO_RESTORE.md` + SQL rollback blocks. Every recent change is reversible.

### What still feels awkward

- **Two editors for per-night bars** (Setup → Bars and Nights → 🍸 Bars) writing the same data. Post-v307 they are consistent, but the duplication is unusual.
- **Labels that don't fully reflect behavior:** "Set Active for Night" could be "Include in Night" for clarity.
- **Two PAR concepts** (global low-stock `items.par_level` vs per-bar Opening `opening_par_items`) without cross-reference hints.
- **Dispatch Quick Mode missing Undo.** Silent apply is fast but unforgiving. Undo toast is the queued polish.
- **Dispatch Save button** sits in the page header, out of view when scrolled. Floating Save CTA is queued.
- **No device-agnostic staff/stations per-night.** Staff on iPad A aren't visible on iPad B.

### What was recently improved

- PAR Levels became per-bar (v302), then bulk-editable (v303), then selection-driven (v304). Three iterations to find the right shape.
- Block Mode layered four polish passes (v295 → v298 → v299 → v300 in parallel). Search, pinned, section-aware back, real history back, readability.
- Dispatch gained Quick Mode (v300), compact upper (v301), safer default destinations (v301).
- History integrity (X2 + v307) removes a whole class of silent-drift bugs.

### What still causes confusion

- For new admins: the distinction between global `bars.active` (Edit modal) and per-night `night_bars` (Setup → Bars toggles) is not self-explanatory.
- For power admins: running a `backfill_night_bars` RPC manually requires SQL Editor access — there's no UI button.
- For barbacks (who don't use the admin surface): Opening is not yet a product for them.
- "Why can't I save Opening PAR for Bar X?" — because Bar X isn't in the venue's active list OR isn't in the current PAR profile — two different causes with the same symptom.

### What needs real-world validation before more feature work

- **v307 Setup → Bars sync** — runtime acceptance pending.
- **X2 fallback toast** — not yet observed firing in a real session.
- **PAR Levels with 2+ bars + mixed values** — works in code; not yet tested against a real operator's intended flow.
- **Venue switching mid-session** — all caches should invalidate correctly. Tested for Opening profile cache; not explicitly re-tested for `SETUP_BARS_NIGHT_SET` or PAR selection after v307.

---

## 17. Decision Log

### D1 — `night_bars` as the source of truth for per-night bar membership

- **Decision.** Create a new table `night_bars (night_id, bar_id, bar_name_at, created_at)` with auto-trigger, inline backfill, admin-only writes, viewer-level reads. Make `getActiveBarsForNight(nightId)` query it.
- **Why.** History must not drift. Past nights must show their own bars. Dispatch/Variance/Accountability must be reproducible.
- **Alternative rejected.** Reconstruct from `events` only — doesn't work for configured-but-unused bars. Store per-night as an array column on `nights` — fails on FK safety and makes querying awkward.
- **Tradeoff accepted.** New table + new async path + new fallback surface. Worth it.

### D2 — `bar_name_at` as an immutable snapshot; display live name when available (Option B)

- **Decision.** Store `bar_name_at` at snapshot time. Display live `bars.name` when the bar still exists; fall back to `<bar_name_at> (removed)` for ghosts.
- **Why.** Operators recognize bars by the name on the sign in front of them. Renames are almost always clarity improvements. Audit integrity is preserved in the database — any future audit screen can read `bar_name_at` directly.
- **Alternative rejected.** Option A: always display `bar_name_at`. Cons: pre-rename labels persist forever; screenshots and UI disagree.
- **Tradeoff accepted.** Display fidelity diverges from archival fidelity, by design. Both are preserved.

### D3 — Per-bar Opening PAR normalized; global `items.par_level` retained

- **Decision.** New `opening_par_items (profile_id, bar_id, item_id, qty)` normalized. Leave `items.par_level` untouched for low-stock / variance / pour-cost reports.
- **Why.** Per-bar PAR is necessary for Opening; global PAR serves low-stock alerts. Two different things; both valid.
- **Alternative rejected.** Migrate `items.par_level` into the new model and remove it. Downside: every downstream report that references it (many) would need updating.
- **Tradeoff accepted.** Two PAR-shaped concepts coexist; users may conflate them.

### D4 — PAR Levels selection-driven editing (no mode toggle)

- **Decision.** Remove the `[One | Multiple]` toggle. Behavior flows from `PAR_SELECTED_BARS.size`: 0 / 1 / 2+.
- **Why.** The user explicitly said the toggle adds an unnecessary decision. The checklist already carries the information.
- **Alternative rejected.** Keep the toggle as a power-user affordance.
- **Tradeoff accepted.** Less explicit UI; users must infer mode from their selection. Low cost in practice.

### D5 — Make fallback visible (not silent)

- **Decision.** When `getActiveBarsForNight` falls back to global active bars, fire one console.warn + one `t-warn` toast per `(reason, nightId)` per session.
- **Why.** Silent drift is how integrity bugs hide. A visible warning surfaces the condition without being noisy.
- **Alternative rejected.** Page-specific inline banners (too much UI surface to add). Error out and return empty (would break pages).
- **Tradeoff accepted.** Small risk of surprise toasts on rarely-visited nights. Outweighed by the drift-prevention signal.

### D6 — Single source of truth for Setup → Bars (v307)

- **Decision.** Rewire Setup → Bars to write `night_bars` instead of `bars.active`.
- **Why.** Pre-v307, Setup → Bars looked per-night but wasn't. Post-X2, that mismatch caused "my Setup changes don't show up in Dispatch" bugs.
- **Alternative rejected.** Remove the per-night aspect of Setup → Bars entirely (force admins to use Nights → 🍸 Bars). Downside: admins who work from Setup don't expect to jump to Nights.
- **Tradeoff accepted.** Two editors for the same data remain; consolidation is a separate decision.

### D7 — Default destinations empty in Dispatch (v301)

- **Decision.** `DSP_SELECTED_BARS = []` on fresh session. Require explicit selection.
- **Why.** Auto-selecting every active bar had caused accidental dispatches to unintended destinations.
- **Alternative rejected.** Auto-select the first bar only. Weak compromise.
- **Tradeoff accepted.** One extra tap per session. Worth it for safety.

### D8 — Capacitor single-file architecture preserved

- **Decision.** All application UI and business logic stay inside `www/index.html`. No new JS modules without explicit approval.
- **Why.** Matches existing project convention (README §3). Avoids build-step complexity. Makes reviews easier.
- **Alternative rejected.** Split into `/classic /block /shared` folders when Block Mode was introduced.
- **Tradeoff accepted.** Single giant file. Mitigated by clear section headers and disciplined grep navigation.

### D9 — Use `toast()` for everything informational including fallback warnings

- **Decision.** `t-warn` toast variant (orange) for cautions. `t-ok` for success. `t-err` for errors. `t-info` for neutral.
- **Why.** Consistent visual language. Already-established pattern in the codebase.
- **Alternative rejected.** Sticky banners per page. Too much surface.
- **Tradeoff accepted.** Ephemeral messages. Users who miss a toast have a console record.

### D10 — `profile_id NOT NULL` on `opening_runs`

- **Decision.** Make `opening_runs.profile_id` NOT NULL.
- **Why.** SQL treats multiple NULLs as distinct for UNIQUE purposes. A NULL-able profile_id would allow silent duplicates on `(night_id, bar_id, profile_id)`.
- **Alternative rejected.** Use `COALESCE(profile_id, sentinel_uuid)` in an expression unique index. Complex.
- **Tradeoff accepted.** Can't create ad-hoc runs without a profile in Phase 1. Phase 2 can relax if needed.

---

## 18. Open Questions

Questions with no definitive answer yet. Flag for product discussion:

1. **Historical bar naming — Option A vs Option B long-term.** Currently Option B (live name when exists; `bar_name_at` only for ghosts). Re-evaluate if any venue goes through meaningful renames and operators complain about the past/present divergence.
2. **When to migrate staff and stations per-night.** Queued as P1, but priority relative to Opening workflow UI is not set.
3. **Order of Opening workflow UI vs localization vs other work.** Opening is higher operational value; localization is infrastructure. My recommendation is Opening first, but the user may have external constraints (App Store, multilingual launch timing).
4. **Consolidate Setup → Bars and Nights → 🍸 Bars editors?** The user wanted both. Post-v307 they are consistent. Keep both for different workflows? Collapse into one? No decision.
5. **Fallback toast dedupe frequency.** Currently once per `(reason, nightId)` per session. Some admins might want a sticky visible banner instead. Not tested against operator preference.
6. **Rename "Set Active for Night" to "Include in Night"?** Clearer but a label change nobody has explicitly asked for.
7. **Cross-reference `items.par_level` ↔ `opening_par_items` in the UI?** A small "see also" link could reduce confusion. No design yet.
8. **Should `bars.active = false` bar still appear in the Nights → 🍸 Bars editor as selectable?** Currently yes (any bar can be added to any night). Could be gated. No decision.
9. **When to pursue the BLE native Swift bridge?** Requires physical hardware time and iOS native-tooling setup. No owner identified.
10. **Variance engine `OPENING` timing.** When to add the 2-line legit-outflow change? Answer: same commit as the Opening workflow UI start emitting those events. Confirmed, but not calendared.
11. **Decision on whether Dispatch Quick Mode's silent apply stays as-is or gets an Undo toast.** User wants Undo; I agree. Not yet built.

---

## 19. Next Recommended Implementation Order

### Immediate (P0)

1. **Wait for v307 runtime acceptance.** Until the user's Setup → Bars → Dispatch sync test passes, do not ship any other feature work. Fixes to v307 regressions are acceptable; new features are not.

### Next up (P1), in order

1. **Staff per-night migration** — replicate the `night_bars` pattern for staff. One new table (`night_staff`), one trigger, one backfill RPC, client `getActiveStaffForNight` rewrite, Setup → Staff and Nights-page editor alignment.
2. **Stations per-night migration** — exact same pattern for stations.
3. **Opening workflow UI — admin side** — Generate, Issue, Receive, Cancel. One new page (`#pg-opening`) in Block Mode. Two RPCs (`confirm_opening_run_issue`, `confirm_opening_run_receive`) that atomically transition status and emit events.
4. **Variance engine OPENING integration** — 2-line change in `variance-engine.js`; add `'OPENING'` to the legit-outflow union. One new test case.
5. **Opening workflow UI — barback side** — scoped-staff view of their queue; mark prepared-for-issue; receive-confirm.
6. **Opening summary report** — per-night dashboard of runs by status + exception list.
7. **Dispatch Quick Mode Undo toast** — snackbar with 3-second UNDO button after each silent apply.
8. **Floating Save CTA on Dispatch** — sticky-bottom `Save Dispatch · N items` button.

### Later (P2)

1. **Localization framework** — scaffold commit (add `t()` + empty `I18N_STRINGS.en`). No string migration yet.
2. **Localization pilot surface** — migrate the Mode Chooser (6 strings). Prove the pattern.
3. **Localization language selector** in Business Settings.
4. **Surface-by-surface migration** — auth / nav chrome / high-traffic ops / admin-only pages, in that order.
5. **Translations** — only after English coverage is complete.
6. **Block Mode polish** — recently-visited row; drag-to-reorder pins; keyboard shortcuts.
7. **Cross-device pinned favorites** — migrate localStorage to `business_profile.settings.block_pinned`.

### What to wait on

- **BLE scale native Swift bridge** — waits for a hardware-in-hand session. Separate track.
- **POS accuracy improvements** — ongoing, case-by-case.
- **Multi-template Opening profiles** (Standard / Large Event / VIP Night / Light) — don't build until operators ask.
- **"Smarter formula" Opening** (`PAR − carryover − unopened leftovers`) — requires per-bar closing stock tracking. Large feature. Don't start.
- **Audit-first bar naming view (Option A)** — only if audit workflow demands it.

### What not to mix

- **Opening workflow UI + localization** in the same commit. Either one alone.
- **Variance engine changes + new tables** in the same commit.
- **BLE work + anything UI** in the same commit.
- **Staff per-night + stations per-night** in the same commit, even though they're almost identical. Ship independently for clean rollbacks.

### What would be overengineering today

- A workflow state machine library (for 4 statuses, a CHECK constraint + RPC-guarded transitions is correct).
- A separate `opening_runs_history` audit table (the existing actor columns + timestamps + no UPDATE policy are sufficient).
- Offline-first dispatch mode (nobody has asked).
- Signature capture (drawn signatures). Showy; not operationally useful.

### What must be validated before more coding

- v307 in real use (see §12).
- Any time `getActiveBarsForNight` or its callers are touched, re-run the async-regression checks.
- Any time `opening_par_items` or `night_bars` RLS is touched, verify from a non-admin session.

---

## 20. Safe Next Action

**Wait for the user's runtime acceptance of v307 on device. Do not start any new feature work until that result is in.**

If v307 passes: proceed to **staff per-night migration** as the next commit, following the `night_bars` pattern exactly.

If v307 fails: diagnose the exact failure, rollback with `git reset --hard safe_point_pre_bar_setup_regression_fix && npx cap copy ios`, and retry after understanding the failure mode.

---

## 21. Danger List

1. **v307 is not accepted yet.** Don't build on top of it until the user confirms Setup → Bars → Dispatch sync works on device.
2. **`getActiveBarsForNight` is async.** Every new caller must `await`. Missed await = silently empty bar lists.
3. **Staff/stations per-night are still on localStorage.** Multi-device setups will silently diverge until migrated.
4. **BLE scale code is exploratory.** Touching it should be treated as research, not engineering. Expect new failures.
5. **POS mapping is incomplete.** Variance reports for incompletely-mapped venues are unreliable inputs, not unreliable math.
6. **`bars.active` vs `night_bars` is two different knobs.** Don't conflate them in code or UI changes.
7. **`items.par_level` is load-bearing** for several reports. Do not repurpose it.
8. **Service worker cache version must be bumped** on every ship. Forgetting this silently freezes PWA clients.
9. **Capacitor `npx cap copy ios` discipline** — every `www/` edit must be followed by it before Xcode rebuild. Otherwise iOS shows a stale bundle.
10. **No UPDATE policy on `night_bars`** is intentional — history cannot be silently rewritten. Do not add one without an explicit product discussion.

---

*End of handoff.*
