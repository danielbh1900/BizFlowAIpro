-- 20260423_business_profile_capabilities.sql
--
-- Phase 0 of the capability/profile architecture.
--
-- Adds a structural `capabilities` column to public.business_profile.
-- This column is the future single source of truth for "does this
-- workspace expose module X, concept Y, workflow Z." It is ADDED here
-- and BACKFILLED but NOT YET READ by any code path. Phase 0 ships no
-- UI gating, no navigation changes, no terminology rewiring. The only
-- post-migration behavior is that a client-side CAPS module can
-- populate itself from this column; it has no consumers yet.
--
-- Default for new rows is an empty object so newly created workspaces
-- fall through to the client-side CAPABILITY_PRESETS (keyed by
-- business_type) at load time. Existing rows are backfilled with the
-- full Bar/Club capability set so current Bar/Club workspaces
-- (Harbour, Theatre, TradeX, and any other existing row) remain
-- indistinguishable from today once gating eventually ships. The
-- backfill intentionally ignores each row's business_type — the user
-- constraint is "zero behavior change for existing workspaces", so
-- the most permissive current-UX preset wins for all existing rows;
-- admins can later re-derive per-row.
--
-- ── Rollback ──────────────────────────────────────────────────────
-- ALTER TABLE public.business_profile DROP COLUMN IF EXISTS capabilities;
-- ──────────────────────────────────────────────────────────────────

ALTER TABLE public.business_profile
  ADD COLUMN IF NOT EXISTS capabilities jsonb NOT NULL DEFAULT '{}'::jsonb;

UPDATE public.business_profile
SET capabilities = jsonb_build_object(
  'supportsShifts',         false,
  'supportsNights',         true,
  'supportsBars',           true,
  'supportsStations',       true,
  'supportsDepartments',    false,
  'supportsTables',         true,
  'supportsMenuItems',      true,
  'supportsIngredients',    true,
  'supportsRecipes',        true,
  'supportsSKUs',           true,
  'supportsSuppliers',      true,
  'supportsPurchaseOrders', true,
  'supportsReceiving',      true,
  'supportsTransfers',      false,
  'supportsCycleCounts',    false,
  'supportsWasteTracking',  true,
  'supportsPAR',            true,
  'supportsParPerLocation', true,
  'supportsParPerSKU',      false,
  'supportsPourCost',       true,
  'supportsDispatch',       true,
  'supportsAccountability', true,
  'supportsVariance',       true,
  'supportsGiveaways',      true,
  'supportsVIP',            true,
  'supportsRoomService',    false,
  'supportsMinibar',        false,
  'supportsBLEWeigh',       true
)
WHERE capabilities = '{}'::jsonb;
