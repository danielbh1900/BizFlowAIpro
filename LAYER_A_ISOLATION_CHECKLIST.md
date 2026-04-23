# Layer A — Workspace Isolation Checklist (QA Runbook)

> **Purpose.** Practical, device-level verification that the Layer A
> workspace-isolation pass (subcommits A1–A5) is working as designed on
> the seven narrowed admin/setup surfaces. Use this before accepting
> Layer A as shipped, and re-run on every venue-boundary regression.
>
> **Repo HEAD at document write:** Layer A Subcommit A6.
> **Latest code safe point:** `safe_point_ctx_skeleton`.
> **Date:** 2026-04-23.

---

## 1. What Layer A delivered

Context-boundary plumbing for the seven affected admin/setup surfaces. Five
code subcommits, one doc subcommit, each independently revertible.

| Subcommit | Tag | Delivered |
|---|---|---|
| A1 | `safe_point_ctx_foundation` | `VENUE_CTX` module: generation counter, AbortController, reset registry, `bump()` hook in `switchVenue()`. No behavior change on its own. |
| A2 | `safe_point_ctx_stale_guard` | Generation-based stale-response guards on every post-await write point in the seven loaders. Backup/Restore destructive paths protected end-to-end. |
| A3 | `safe_point_ctx_reset_registry` | Three per-surface reset callbacks (`ctx:setup`, `ctx:business-settings`, `ctx:suppliers`) registered at `init()` and fired on every `bump()`. Wipes DOM + module state. |
| A4 | `safe_point_ctx_keyed_remount` | `data-ctx-gen` attribute on page roots; pre-loader remount in `navigateTo()` when a stale affected page is revisited. |
| A5 | `safe_point_ctx_skeleton` | Loading skeleton replaces the brief blank flash during switch. Explicit clear for `#setup-bars-night` dropdown (D3 fully resolved). |
| A6 | *(this doc)* | `HOW_TO_RESTORE.md` entries + this runbook. No code. |

---

## 2. Scope — the seven affected surfaces

Three page roots, covering the seven user-listed surfaces:

| Page root | Registered reset id | User-listed surfaces |
|---|---|---|
| `#pg-setup` | `ctx:setup` | Setup → Bars, Setup → Staff, Setup → Stations (implicit), Setup → Items |
| `#pg-business` | `ctx:business-settings` | Business Settings, Data Management, Backup / Restore |
| `#pg-suppliers` | `ctx:suppliers` | Suppliers |

Every other page in BARINV is **out of scope** for Layer A and is not
guaranteed workspace-safe yet.

---

## 3. Acceptance criteria

All nine must verify before Layer A is accepted. Each is observable
either in the browser/WKWebView console or by a manual protocol below.

### C1 — Generation monotonicity

- `VENUE_CTX.currentGen()` strictly increases on every `switchVenue()`.
- **Verify:** Console logs `[CTX] gen=N (registry size=3)` after each switch,
  with N incrementing (0 → 1 → 2 → 3 …).

### C2 — Stale responses dropped, never rendered

- During a mid-load switch, any in-flight Supabase response belonging to a
  previous generation is refused at the post-await write point.
- **Verify:**
  1. Throttle network (Charles / Simulator Network Link Conditioner).
  2. Navigate to Setup → Items in a large venue (500+ items).
  3. Immediately switch to a small venue.
  4. Observe `[CTX] loadSetup dropped stale gen=N` in console.
  5. The rendered Items list is the small venue's content only. No row
     from the large venue appears.

### C3 — Reset registry fires fully on every bump()

- Every registered reset executes on every switch, in insertion order,
  before the new venue's `preload()` completes.
- **Verify:** Console logs, in this exact order, after every switch:
  - `[CTX] reset: ctx:setup (with skeleton + dropdown clear)`
  - `[CTX] reset: ctx:business-settings (with skeleton on backups list)`
  - `[CTX] reset: ctx:suppliers (with skeleton)`

### C4 — No cross-venue data flash

- On switch, affected pages show **skeleton** or correct-venue data.
  Never previous-venue data after the generation counter has advanced.
- **Verify:**
  1. Navigate to Setup on Venue A. Wait for full render (bar list visible).
  2. Switch to Venue B.
  3. Navigate back to Setup.
  4. The first paint shows skeleton rows, then Venue B's bars. **No Venue
     A bar names appear at any point after `[CTX] gen=...` log.**

### C5 — Destructive Backup / Restore refuses mid-switch operations

- If the user triggers an Import/Restore then switches workspace mid-flow,
  the operation aborts with a visible message and no destructive DB write
  reaches the wrong venue.
- **Verify:**
  1. On Venue A, Settings → Data Management → Choose Backup File → pick a
     valid backup JSON → reach the "⚠ Final Confirmation" modal.
  2. Switch to Venue B **before** clicking RESTORE.
  3. Click RESTORE.
  4. Expected toast: `⚠ Workspace changed — restore aborted for safety`.
  5. No new rows exist in Venue B's tables (verify via Supabase SQL Editor
     or the venue's Setup counts).

### C6 — Keyed-remount fires on revisit after switch

- Navigating to an affected surface after a switch triggers the registered
  reset **before** the loader runs.
- **Verify:**
  1. Navigate to Setup, let it render.
  2. Switch venue (without navigating away from Setup — just use the venue
     dropdown). The reset fires as part of `bump()`.
  3. After `navigateHome()` takes you elsewhere, navigate back to Setup.
  4. Console shows `[CTX] remount: setup stale, running reset before loader`.
  5. The Setup page re-renders cleanly for the new venue.

### C7 — #setup-bars-night dropdown is clean on every switch

- Dropdown options are wiped to `<option>— Select Night —</option>` on
  every `bump()`, regardless of whether `renderBars()` subsequently runs.
- **Verify:**
  1. Navigate to Setup → Bars on Venue A. Expand the dropdown. Observe
     Venue A's night names.
  2. Switch to Venue B.
  3. Without navigating anywhere, open the dropdown if Setup is still the
     active page for a moment. It should show only the placeholder
     `— Select Night —`.
  4. When Setup repaints for Venue B, the dropdown repopulates with
     Venue B's nights.

### C8 — No unrelated regressions

- Dispatch, Variance, Accountability, Nights, PAR Levels, VIP Tables,
  Reports, Block Mode, POS pages, Opening tables, BLE Debug — all behave
  identically to `safe_point_handoff_doc`.
- **Verify:** Smoke test each page once after the Layer A pass. No
  visible change in behavior or render speed beyond the expected
  improvements on the seven affected surfaces.

### C9 — Observable isolation trace

- Console produces a sufficient audit trail to reconstruct exactly what
  happened during each venue switch.
- **Verify:** After one end-to-end session (login → switch venue →
  navigate 3 affected pages → switch again → logout), a single console
  filter for `[CTX]` returns a clean, chronological log of generations,
  resets fired, and any stale drops detected.

---

## 4. Manual QA protocol — device-level pass

Run all of the following **after** rebuilding in Xcode (Cmd+R) and
force-quitting + reopening the iPad app on SW cache v312.

### 4.1 Two-venue baseline

Preconditions: an admin user who is a member of at least two venues
(henceforth "Venue A" and "Venue B") in the same organization. Both
venues should have at least a few bars, staff, items, and suppliers so
stale data would be noticeable.

### 4.2 Pass 1 — generation + reset trace

1. Launch the app. Log in.
2. Open the devtools console (Safari Web Inspector attached to the WKWebView).
3. Navigate to Setup → Bars, wait for render.
4. Switch to Venue B via the top-right venue selector.
5. **Expect in console, in this order:**
   - `[CTX] reset: ctx:setup (with skeleton + dropdown clear)`
   - `[CTX] reset: ctx:business-settings (with skeleton on backups list)`
   - `[CTX] reset: ctx:suppliers (with skeleton)`
   - `[CTX] gen=1 (registry size=3)`
6. UI: Setup bar list briefly shows pulsing skeleton rows, then Venue B's bars.
7. Switch back to Venue A. Same trace, `gen=2`.

### 4.3 Pass 2 — Setup surfaces

1. On Venue A, navigate to Setup. Verify bars/staff/stations/items all render correctly.
2. Switch to Venue B. Navigate to Setup.
3. Verify each of the four sub-surfaces shows Venue B's data, not Venue A's.
4. Verify search inputs are empty (not carrying Venue A filters).
5. Verify select-all checkboxes are unchecked.
6. Verify selected-count labels read `0 selected`.

### 4.4 Pass 3 — Business Settings

1. On Venue A, open Settings → Business Settings.
2. Note the business name and terminology values.
3. Switch to Venue B. Open Business Settings.
4. Verify:
   - Name, currency, address, timezone all show Venue B's values.
   - Terminology fields (`term-staff`, `term-helper`, etc.) show Venue B.
   - Data Management backup list shows Venue B's backups, not Venue A's.
   - Giveaway reasons editor is Venue B's list.

### 4.5 Pass 4 — Suppliers

1. On Venue A, open Suppliers.
2. Switch to Venue B.
3. Open Suppliers. List reflects Venue B only.

### 4.6 Pass 5 — Backup / Restore safety

**Destructive test. Only run on a disposable venue pair.**

1. On a disposable Venue A, export a backup.
2. On disposable Venue B, start an Import flow. Reach the "⚠ Final
   Confirmation" modal.
3. **Do not type the confirmation yet.** Leave the modal open.
4. Use the venue dropdown to switch back to Venue A.
5. Return to the still-open modal. Type the Venue B name and click RESTORE.
6. Expected toast: `⚠ Workspace changed — restore aborted for safety`.
7. Verify no changes were made to either venue's data.

### 4.7 Pass 6 — Export during switch

1. On a large Venue A, trigger an "Export Backup" for scope=current.
2. While the export loop is running (visible in console as multiple
   table-query lines), switch to Venue B.
3. Expected: the export aborts with a toast `Export cancelled — workspace changed`. No file is downloaded. No mixed-venue JSON leaks out.

### 4.8 Pass 7 — Negative control

1. Navigate to Dispatch on Venue A. Wait for render.
2. Switch to Venue B.
3. **Dispatch is out of Layer A scope.** Expect the prior v307 behavior
   — the new venue's `night_bars` are read via `getActiveBarsForNight`
   and render correctly. No Layer A skeleton appears (it's not a Layer A
   surface).
4. This confirms Layer A did not spread beyond its scope.

---

## 5. Known open issues — carried forward

### D2 — Open modals with stale data after a workspace switch *(NOT closed)*

A user who has any page-level edit modal open (Edit Supplier, Edit Bar,
Edit Item, Edit Staff, Add New Supplier, Add New Night, Add New
Giveaway Reason, etc.) and then switches venue sees the modal remain
open with inputs holding the previous venue's values.

**Current mitigation (A2 guards):** RLS at the database would reject a
stale `.update(...)` call if it tried to modify a record no longer
belonging to the active venue. No data corruption is possible.

**Why this is still not acceptable:** per the reviewer's explicit note:
*"A user should not be able to meaningfully interact with a Venue A
modal while already in Venue B."* Data safety is not the only bar;
workspace-isolation UX is the bar.

**Agreed fix shape for the future commit:**

- **Broad fix:** add a fourth reset id `ctx:modal` (or equivalent
  pre-registry hook in `bump()`) that calls `closeModal()` if any modal
  overlay is visible. Unconditional closure on every workspace switch.
  Approximately 10 lines of code.
- **Targeted reinforcement for high-stakes modals:** capture
  `myGen = VENUE_CTX.currentGen()` when the modal opens. In the modal's
  confirm callback, refuse the action if `VENUE_CTX.isStale(myGen)`. Same
  pattern A2 used for `dmImportBackupStep2`. Apply to Edit Supplier,
  Edit Bar, Edit Staff, Edit Item, Giveaway Reasons save, and
  Business Settings save.

**Expected scope for the fix:** one small commit (~30–50 lines),
independently safe-pointed. Not bundled with any other work.

### D3 — `#setup-bars-night` stale options *(CLOSED in A5)*

Previously flagged in A4 as "effectively mitigated, not fully resolved."
A5's explicit dropdown clear inside the `ctx:setup` reset closes it
at the data-persistence level. No exception path can leave stale night
names visible across a workspace boundary.

### Pre-Layer-A items also worth remembering *(UNRELATED — not Layer A's problem)*

- **BLE scale** still unresolved. Aggressive-connect path is the only
  one that has ever succeeded; native Swift `CoreBluetooth` bridge is
  the likely next step when you're ready.
- **POS accuracy** (Square catalog → BARINV item mapping, pour-size
  detection) still has open edge cases. Separate track.
- **Staff / stations per-night** still use `localStorage` (device-
  local). Same class of bug that `night_bars` fixed for bars. Queued
  as P1 follow-ups after Layer A.
- **v307 runtime acceptance** on device is still pending. Layer A was
  deliberately started before v307 acceptance because its absence
  could contaminate v307's validation. Both now need device-level
  verification.

---

## 6. Out of scope for Layer A

Explicitly NOT delivered by A1–A6 and NOT covered by this checklist:

- **Layer B** — workspace-scoped `localStorage` wrapper (pinned tiles,
  last-night, dispatch view keys that currently leak across venues).
- **Layer C** — capabilities-driven UI composition (business-type-
  aware page visibility; replacing the current hide-list).
- **Layer D** — terminology dictionary, paired with localization.
- **Layer E** — client-side query scoping wrapper (`SB.venueQuery`).
- **Layer F** — automated isolation test harness.
- Any page or subsystem outside the three affected page roots
  (`#pg-setup`, `#pg-business`, `#pg-suppliers`).
- Variance engine, Opening workflow UI, BLE, POS.
- Schema changes, RLS changes, RPC changes.

---

## 7. Rollback commands

Use at any point Layer A needs to be reversed.

```bash
cd "/Volumes/MiniSSD/IOS BARINV BACKUP/BARINV-PRO IOS"

# Roll back A6 (this doc) only — leaves all A1–A5 code in place.
git reset --hard safe_point_ctx_skeleton
npx cap copy ios

# Roll back A5 only — leaves A1–A4 in place.
git reset --hard safe_point_ctx_keyed_remount
npx cap copy ios

# Roll back A4 + A5 — leaves A1–A3 in place.
git reset --hard safe_point_ctx_reset_registry
npx cap copy ios

# Roll back A3 + A4 + A5 — leaves A1–A2 in place.
git reset --hard safe_point_ctx_stale_guard
npx cap copy ios

# Roll back A2 + A3 + A4 + A5 — leaves A1 in place.
git reset --hard safe_point_ctx_foundation
npx cap copy ios

# Full Layer A rollback.
git reset --hard safe_point_handoff_doc
npx cap copy ios
```

Each intermediate rollback is independently tested and leaves the app
in a known-consistent state. No subcommit depends on a later one.

---

## 8. Sign-off

Sign this doc (here, in a file, or in a message) once every acceptance
criterion C1–C9 has been verified on device and the seven surfaces
have passed Passes 1–7 above.

Until signed, Layer A is considered **code-complete, acceptance-
pending** and should not be built on top of.

D2 remains **open** and must be addressed before Layer B begins.
