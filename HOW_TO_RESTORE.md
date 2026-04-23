# How to Restore BARINV Pro to a Safe Point

This project uses git tags as named safe points. Each tag points to a specific commit where the app was in a known-working state. Use this guide when you need to roll the working tree back to one of those states.

All commands below assume your terminal is in the project root:

```bash
cd "/Volumes/MiniSSD/IOS BARINV BACKUP/BARINV-PRO IOS"
```

---

## Safe points (most recent first)

| Tag | What it captures |
|---|---|
| `safe_point_ctx_skeleton` | **Layer A · A5** — loading-skeleton replaces the blank flash on the seven affected surfaces during a workspace switch. `#setup-bars-night` dropdown is now explicitly cleared as part of the ctx:setup reset (D3 fully resolved at the data-persistence level). SW cache v312. |
| `safe_point_ctx_keyed_remount` | **Layer A · A4** — keyed remount via `data-ctx-gen` on `#pg-setup` / `#pg-business` / `#pg-suppliers`. `navigateTo()` fires the registered reset before the loader when a page root is stale. D3 effectively mitigated (fully resolved by A5). D2 explicitly carried forward. SW cache v311. |
| `safe_point_ctx_reset_registry` | **Layer A · A3** — three surface-reset callbacks registered at `init()` via `registerSurfaceResets()`. Covers Setup / Business-Settings+DataMgmt+Backup-Restore / Suppliers. DOM and page-local state cleared on every `VENUE_CTX.bump()`. SW cache v310. |
| `safe_point_ctx_stale_guard` | **Layer A · A2** — generation-based stale-response guards on the seven approved setup/admin loaders. Every post-await write refuses to touch DOM or module state if the workspace generation advanced during the await. Destructive Backup/Restore paths protected end-to-end. SW cache v309. |
| `safe_point_ctx_foundation` | **Layer A · A1** — `VENUE_CTX` foundation module (generation counter, AbortController lifecycle, reset registry). `bump()` wired as the first action in `switchVenue()`. No observable behavior change on its own. SW cache v308. |
| `safe_point_handoff_doc` | Master handoff doc (`BARINV_MASTER_HANDOFF_FULL.md`) committed. No code changes between this and Layer A. v307 runtime acceptance still pending on device. BLE scale calibration still pending (scale only connects via the orange 🎯 Aggressive Connect button — the regular Connect path is demonstrably broken for this device). Use this tag as a full-Layer-A rollback target. |
| `safe_point_setup_bars_unified` | Regression fix — Setup → Bars now writes `night_bars` (the same source Dispatch / Variance / Accountability / Nights 🍸 Bars read). Pre-X2 it wrote the global `bars.active`, which had no effect on per-night Dispatch after X2. One source of truth restored. SW cache v307. |
| `safe_point_pre_bar_setup_regression_fix` | Clean state right before the Setup→Bars source-of-truth regression fix. |
| `safe_point_x2_fallback_visible` | X2 fallback is no longer silent — when `getActiveBarsForNight` drops to the global-active list because a night has no snapshot (empty) or the lookup errored, a deduped `t-warn` toast + console.warn now surfaces the drift. Otherwise X2 unchanged. SW cache v306. |
| `safe_point_pre_x2_fallback_visible` | Clean state right before the fallback-visibility patch. |
| `safe_point_night_bars_integrity` | **X2** — historical per-night bar integrity. New `night_bars` table (snapshot with `bar_name_at`), auto-trigger on night INSERT, `backfill_night_bars(venue_id)` RPC, inline migration-time backfill from events + bar_close_summaries, async `getActiveBarsForNight` with `_fallback` marker, Nights-page per-night bar editor. SW cache v305. |
| `safe_point_pre_x2_night_bars` | Clean state right before X2. |
| `safe_point_par_selection_driven` | PAR Levels — selection-driven editing. 0 bars = empty prompt, 1 bar = direct auto-save, 2+ = bulk with current/new + confirm. No explicit mode toggle. SW cache v304. |
| `safe_point_pre_par_bulk_ux_correction` | Clean state right before removing the One/Multiple toggle from X1. |
| `safe_point_par_bulk_edit` | PAR Levels — multi-bar bulk edit (X1 v1). Mode toggle [One\|Multiple] + bar checklist + mixed-state current-value chip + blank-means-skip new input + confirmation modal + batch upsert. Per-bar storage unchanged. SW cache v303. |
| `safe_point_pre_par_bulk_and_history_audit` | Clean state right before X1 and the planned X2 (per-night bar integrity). Use this to roll both future commits back together. |
| `safe_point_pre_phase_validation_and_i18n` | Clean state before PAR validation phase and localization architecture planning. No code changes between this and `_pre_par_bulk_and_history_audit`. |
| `safe_point_par_per_bar_editor` | Opening Phase 1 — per-bar PAR editor on the PAR Levels page, reading/writing `opening_par_items` under the venue's default profile. Degrades gracefully if the SQL migration hasn't been applied. SW cache v302. |
| `safe_point_opening_phase1_sql` | SQL migration file `supabase/migrations/20260421_opening_phase1.sql` committed (tables + RLS + default-profile seed). **Not yet applied to Supabase.** Apply via SQL Editor. Rollback block included in the file header. |
| `safe_point_pre_opening_workflow` | Clean state right before any Opening workflow code was written. Use this to roll the whole Opening feature back. |
| `safe_point_dispatch_upper_compact` | Compact upper Dispatch (identity row + inline setup toolbar + collapsed Destinations + slim mode+legend + one-line summary). Also flips default-destinations to empty so operators pick deliberately. SW cache v301. |
| `safe_point_pre_dispatch_upper_rework` | Clean state right before the upper Dispatch compacting work. Use this to roll the upper page back without losing Quick Mode. |
| `safe_point_dispatch_quick_mode` | Dispatch page gains a Quick Mode: sticky action bar (Take/Comp/Shot × qty) + compact tap-to-apply cards with ⋯ expand for secondary controls. Detail Mode preserved as opt-out. SW cache v300. |
| `safe_point_real_back_and_readability` | Real history-aware Back + deliberate Section Home as separate buttons on every Block Mode destination page. Plus `--muted` contrast bump (WCAG AA) and moderate `.main` max-width expansion for better space use. SW cache v299. |
| `safe_point_block_mode_v3_backbar` | Block Mode v3 — big orange "← BACK TO &lt;section&gt;" bar on every destination page. One tap returns to the section's L2 (e.g. POS), cutting the Home→category→item round-trip. SW cache v298. |
| `safe_point_block_mode_v2_polish` | Block Mode v2 — launcher now has a universal search box and per-tile ☆ pin toggle with a "★ Pinned" row on the home. SW cache v296. |
| `safe_point_block_mode_v1` | Block Mode v1 — second navigation shell alongside Classic. Shared core, mode chooser, 2-level block launcher, topbar switcher. SW cache v295. |
| `safe_point_pre_block_mode` | Clean state immediately before any Block Mode code was written. Use this to roll back if Block Mode needs to be removed entirely. |
| `safe_point_bulk_cost_import` | Bulk `cost_price` CSV import on Suppliers page (manager-gated). Closes Phase-2 B2 — once ≥90% item coverage is hit, Giveaways cost columns auto-unlock. SW cache v294. |
| `safe_point_pdf_share_and_night_leaderboard` | Dashboard leaderboard **Night** filter + Print PDF routed through the iOS share sheet on iPad/Mac app, and through the browser Save-as-PDF dialog on web. SW cache v293. |
| `pre_native_ble_attempt` | Everything up to v285 aggressive BLE connect. Last point before any native Swift BLE bridge work. |
| `pre_ble_debug_safe_point` | Pre-BLE-debug clean Phase-1 state (commit `beca90d`). No BLE debug infrastructure. |
| `v2.4.0` | Dispatch single source of truth + Square mapping + qty math. |
| `v2.3.1` | Full SaaS architecture: RLS + multi-venue + role-aware UI. |
| `v2.2.8`, `v2.2.7` | Older Data Management / bar filtering milestones. |

List all tags at any time with:
```bash
git tag -l
```

See what a tag points to and its commit message:
```bash
git show <tag-name>
```

---

## Option 1 — Peek at an older state (non-destructive)

Use this when you want to *look* at the old code without changing `main`:

```bash
git checkout <tag-name>     # e.g. safe_point_pdf_share_and_night_leaderboard
```

You're now in "detached HEAD" — free to read files or run the app, but any commits you make here will not belong to `main`.

Get back to where you were:
```bash
git switch main
```

---

## Option 2 — Branch off a tag to try changes (non-destructive)

Use this when you want to experiment from an old state without touching `main`:

```bash
git switch -c try-from-<short-name> <tag-name>
# ...make edits, commits, etc...
git switch main             # back to main when done
```

---

## Option 3 — Restore ONE file from a tag (surgical)

Use this when only a specific file went wrong and you want to pull its older version:

```bash
git checkout <tag-name> -- www/index.html
# or just the service worker:
git checkout <tag-name> -- www/sw.js
```

This leaves everything else on `main` untouched. The restored file shows up as a staged change — review it with `git diff --staged`, then commit if you want to keep it.

---

## Option 4 — Hard-reset main back to a tag (**destructive**)

Use this only when you're sure you want the entire working tree back at the tag. **This discards every commit after the tag.**

```bash
git status                  # confirm nothing you care about is uncommitted
git reset --hard <tag-name>
```

**Warnings:**
- Any uncommitted changes in tracked files will be lost. Run `git stash` first if in doubt.
- If the tag is earlier than what you've already pushed to `origin/main`, you'll need a force-push to update the remote (`git push --force-with-lease origin main`). Don't force-push unless you know nobody else is working off `origin/main`.

---

## Always do this after restoring iOS-relevant files

If you restored anything under `www/` (e.g. `index.html`, `sw.js`, `variance-engine.js`), the iOS build still serves the *previous* bundle from `ios/App/App/public/`. Sync it:

```bash
npx cap copy ios
```

Then in Xcode: Cmd+R to rebuild.

On an already-installed device, force-quit the app and reopen so the WKWebView picks up the new assets. The service worker also caches HTML — if you see stale content, bump the `CACHE` constant in `www/sw.js` or clear site data from the iOS app (Settings → BARINV Pro → Clear storage, if exposed, or reinstall).

---

## How to create a new safe point

Whenever the app is in a working state you want to be able to return to:

```bash
# 1. Commit your changes first if you have any
git status
git add <files>
git commit -m "your message"

# 2. Tag the commit. Use a descriptive name.
git tag -a <tag-name> -m "What this captures"

# Example:
git tag -a safe_point_2026-05-01_before_refactor -m "Pre-refactor: everything working as of May 1."
```

Tags are local until pushed. To share:
```bash
git push origin <tag-name>
```

To delete a tag (local only):
```bash
git tag -d <tag-name>
```

---

## Supabase data (not covered by git)

Git only restores *code*. Database state (events, nights, VIP tables, etc.) is in Supabase and has its own backup system:

- **Automatic:** nightly `_backup_all_venues_daily` cron RPC writes per-venue snapshots into the `backup_snapshots` table.
- **Manual:** Admin → Data Management page → **Export Backup** (JSON download).
- **Restore:** Admin → Data Management → **Import Backup**, or call the `restore_venue_backup(backup_id)` RPC from the Supabase SQL editor.

See `README.md` §5.4 and §14 for the full RPC list.
