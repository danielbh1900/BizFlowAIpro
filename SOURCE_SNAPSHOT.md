# Source Snapshot — aiProINV Agent

aiProINV Agent is a next-generation product track. This file records the
code-level provenance of the repo's first commit so the historical
connection to BARINV Pro is traceable without re-introducing BARINV's
git history into this repository.

## Lineage at snapshot time

- **Source project**: BARINV Pro
- **Source repo location**: `/Volumes/MiniSSD/IOS BARINV BACKUP/BARINV-PRO IOS`
- **Source branch**: `main`
- **Source commit**: `36719f9d9ee4594ffe6c91655b8a3799cf58c9a5`
- **Source safe-point tag**: `safe_point_caps_foundation`
- **Source commit title**: "Phase 0: capability/profile foundation (no UI gating)"
- **Fork date**: 2026-04-23

The files in the initial commit of this repository were produced by:

1. `rsync -a --exclude='.DS_Store'` copy of BARINV Pro at the source
   commit listed above into `/Volumes/MiniSSD/IOS BARINV BACKUP/BARINV-BLUEPRINT IOS`.
2. Rename of the folder to `/Volumes/MiniSSD/aiProINVagent IOS` and then
   move to `/Volumes/MiniSSD/aiProINVagent IOS` as the final location.
3. Identity-rename edits applied on a pre-fork branch (`aiproinv-agent-main`,
   last BARINV-ancestry commit `a11e3a639b25c7353e20c1731a98c844bb855598`):
   - `com.barinv.pro` → `com.aiproinv.agent` (Xcode bundle id, Capacitor appId)
   - `BARINV Pro` → `aiProINV Agent` (display name, usage strings)
   - URL scheme `barinv` → `aiproinv-agent`
   - `package.json` name and description updated
4. Git history prior to this initial commit was intentionally discarded when
   establishing aiProINV Agent as an independent product repo. The original
   BARINV history remains in the frozen source project above.

## BARINV Pro remains independent

- BARINV Pro continues to live at `/Volumes/MiniSSD/IOS BARINV BACKUP/BARINV-PRO IOS`.
- BARINV Pro retains its own git history, its own safe-point tags, its own
  bundle id `com.barinv.pro`, and its own Supabase backend
  (`uzommuafouvaerdvirzf`).
- BARINV Pro is not modified by any work in this repository.
- If a fix is authored here that also applies to BARINV Pro, carry it across
  by hand — do not attempt to reconnect the git histories.

## Backend

- aiProINV Agent's Supabase backend is a separate project: `aiproinv-agent-dev`
  (ref `knynckfdpodlcydcmdym`, region `us-west-1`). Distinct URL and keys;
  not shared with BARINV Pro.

## Rollback ancestry reference

If the initial commit of this repo ever needs to be reconciled against
BARINV Pro's history for audit or cherry-pick purposes, start from the
tag `safe_point_caps_foundation` in the frozen BARINV Pro repo.
