-- =============================================================================
-- Opening Workflow — Phase 1 foundation
-- Date: 2026-04-21
-- Safe-point tag (pre-apply): safe_point_pre_opening_workflow
-- =============================================================================
--
-- Purpose:
--   Introduce the data model that supports the Opening workflow (per-bar PAR
--   templates + nightly run/checkpoint records) without touching any existing
--   table or any inventory math.
--
-- What this migration does:
--   • Creates 4 new tables:
--       opening_par_profiles      (one or more PAR templates per venue)
--       opening_par_items         (per-bar, per-item target qty inside a profile)
--       opening_runs              (nightly workflow entity, per-bar per-night)
--       opening_run_items         (per-line qty snapshot + issued/received qty)
--   • Enables RLS on all four with the same viewer/manager/admin patterns
--     already used by existing BARINV tables.
--   • Adds an updated_at trigger to opening_par_items.
--   • Seeds exactly one default "Standard" profile per existing venue (only if
--     that venue does not already have an active default profile).
--
-- What this migration deliberately does NOT do:
--   • It does NOT back-populate per-bar PAR from items.par_level.
--     (Copying a global qty into an arbitrary bar would be misleading data.)
--   • It does NOT touch the items table or items.par_level.
--   • It does NOT create any RPCs. Opening workflow actions (Generate / Issue /
--     Receive / Cancel) will arrive in a later phase with their own review.
--   • It does NOT insert any events rows and does NOT introduce a new
--     events.action value yet.
--
-- Important caveat — variance reporting:
--   Until the variance engine is taught to treat action='OPENING' as a
--   legitimate outflow (separate, later commit), any Opening dispatches we
--   eventually emit into events will be counted as unexplained variance for
--   the destination bar. This migration is safe to apply in isolation because
--   it does not emit any such events yet; the caveat is informational for the
--   next phase.
--
-- Rollback (run inside a transaction):
--     BEGIN;
--       DROP TRIGGER IF EXISTS opening_par_items_set_updated_at ON opening_par_items;
--       DROP FUNCTION IF EXISTS opening_par_items_touch_updated_at();
--       DROP TABLE IF EXISTS opening_run_items CASCADE;
--       DROP TABLE IF EXISTS opening_runs CASCADE;
--       DROP TABLE IF EXISTS opening_par_items CASCADE;
--       DROP TABLE IF EXISTS opening_par_profiles CASCADE;
--     COMMIT;
--
-- Apply via Supabase SQL Editor (Project → SQL → New query → paste this file →
-- Run). Idempotent: CREATE TABLE IF NOT EXISTS + seed NOT EXISTS guard make it
-- safe to re-run.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Tables
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS opening_par_profiles (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id    UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  name        TEXT NOT NULL,
  is_default  BOOLEAN NOT NULL DEFAULT false,
  active      BOOLEAN NOT NULL DEFAULT true,
  created_by  UUID REFERENCES auth.users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (venue_id, name)
);

-- At most one ACTIVE default profile per venue.
CREATE UNIQUE INDEX IF NOT EXISTS opening_par_profiles_one_active_default_per_venue
  ON opening_par_profiles (venue_id)
  WHERE is_default = true AND active = true;


CREATE TABLE IF NOT EXISTS opening_par_items (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id  UUID NOT NULL REFERENCES opening_par_profiles(id) ON DELETE CASCADE,
  bar_id      UUID NOT NULL REFERENCES bars(id) ON DELETE CASCADE,
  item_id     UUID NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  qty         NUMERIC NOT NULL CHECK (qty >= 0),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (profile_id, bar_id, item_id)
);
CREATE INDEX IF NOT EXISTS opening_par_items_profile_bar_idx
  ON opening_par_items (profile_id, bar_id);


CREATE TABLE IF NOT EXISTS opening_runs (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  venue_id       UUID NOT NULL REFERENCES venues(id) ON DELETE CASCADE,
  night_id       UUID NOT NULL REFERENCES nights(id) ON DELETE CASCADE,
  bar_id         UUID NOT NULL REFERENCES bars(id) ON DELETE RESTRICT,
  -- profile_id NOT NULL keeps the (night, bar, profile) uniqueness clean.
  -- SQL treats NULLs as distinct, so a NULLable profile_id could create
  -- duplicate rows silently. Phase 1 always uses the venue's default profile.
  profile_id     UUID NOT NULL REFERENCES opening_par_profiles(id) ON DELETE RESTRICT,
  status         TEXT NOT NULL DEFAULT 'DRAFT'
                 CHECK (status IN ('DRAFT','ISSUED','RECEIVED','CANCELLED')),
  has_exception  BOOLEAN NOT NULL DEFAULT false,
  notes          TEXT,
  cancel_reason  TEXT,

  -- Accountability chain. Every actor is a real auth.users UUID, not a free
  -- text username. Timestamps are server-set via DEFAULT now() at the RPC
  -- level (later phase); here they are just nullable until reached.
  created_by     UUID REFERENCES auth.users(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),

  -- Lightweight barback prep trail (per user feedback): records the moment a
  -- barback marks the run "ready for issue" without introducing a fourth
  -- status. Status stays DRAFT until the admin/stockroom signs off.
  prepared_by    UUID REFERENCES auth.users(id),
  prepared_at    TIMESTAMPTZ,

  issued_by      UUID REFERENCES auth.users(id),
  issued_at      TIMESTAMPTZ,

  received_by    UUID REFERENCES auth.users(id),
  received_at    TIMESTAMPTZ,

  cancelled_by   UUID REFERENCES auth.users(id),
  cancelled_at   TIMESTAMPTZ,

  UNIQUE (night_id, bar_id, profile_id)
);
CREATE INDEX IF NOT EXISTS opening_runs_venue_night_status_idx
  ON opening_runs (venue_id, night_id, status);
CREATE INDEX IF NOT EXISTS opening_runs_night_bar_idx
  ON opening_runs (night_id, bar_id);


CREATE TABLE IF NOT EXISTS opening_run_items (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id         UUID NOT NULL REFERENCES opening_runs(id) ON DELETE CASCADE,
  item_id        UUID NOT NULL REFERENCES items(id) ON DELETE RESTRICT,
  -- par_qty is a snapshot taken at generation time. If the PAR profile is
  -- edited later, tonight's runs keep their historical truth.
  par_qty        NUMERIC NOT NULL,
  -- NULL = not yet actioned. 0 = explicitly zero. This distinction matters
  -- for exception reporting.
  issued_qty     NUMERIC,
  received_qty   NUMERIC,
  exception_note TEXT,
  UNIQUE (run_id, item_id)
);
CREATE INDEX IF NOT EXISTS opening_run_items_run_idx
  ON opening_run_items (run_id);


-- -----------------------------------------------------------------------------
-- RLS — match existing BARINV venue-scoped patterns.
-- -----------------------------------------------------------------------------

ALTER TABLE opening_par_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE opening_par_items    ENABLE ROW LEVEL SECURITY;
ALTER TABLE opening_runs         ENABLE ROW LEVEL SECURITY;
ALTER TABLE opening_run_items    ENABLE ROW LEVEL SECURITY;


-- opening_par_profiles: viewer read, manager write, admin delete
DROP POLICY IF EXISTS opening_par_profiles_select_v ON opening_par_profiles;
CREATE POLICY opening_par_profiles_select_v ON opening_par_profiles
  FOR SELECT USING (has_venue_access(venue_id, 'viewer'));

DROP POLICY IF EXISTS opening_par_profiles_insert_v ON opening_par_profiles;
CREATE POLICY opening_par_profiles_insert_v ON opening_par_profiles
  FOR INSERT WITH CHECK (has_venue_access(venue_id, 'manager'));

DROP POLICY IF EXISTS opening_par_profiles_update_v ON opening_par_profiles;
CREATE POLICY opening_par_profiles_update_v ON opening_par_profiles
  FOR UPDATE USING (has_venue_access(venue_id, 'manager'));

DROP POLICY IF EXISTS opening_par_profiles_delete_v ON opening_par_profiles;
CREATE POLICY opening_par_profiles_delete_v ON opening_par_profiles
  FOR DELETE USING (has_venue_access(venue_id, 'admin'));


-- opening_par_items: inherits venue scope via the parent profile row.
DROP POLICY IF EXISTS opening_par_items_select_v ON opening_par_items;
CREATE POLICY opening_par_items_select_v ON opening_par_items
  FOR SELECT USING (EXISTS (
    SELECT 1 FROM opening_par_profiles p
     WHERE p.id = opening_par_items.profile_id
       AND has_venue_access(p.venue_id, 'viewer')
  ));

DROP POLICY IF EXISTS opening_par_items_insert_v ON opening_par_items;
CREATE POLICY opening_par_items_insert_v ON opening_par_items
  FOR INSERT WITH CHECK (EXISTS (
    SELECT 1 FROM opening_par_profiles p
     WHERE p.id = opening_par_items.profile_id
       AND has_venue_access(p.venue_id, 'manager')
  ));

DROP POLICY IF EXISTS opening_par_items_update_v ON opening_par_items;
CREATE POLICY opening_par_items_update_v ON opening_par_items
  FOR UPDATE USING (EXISTS (
    SELECT 1 FROM opening_par_profiles p
     WHERE p.id = opening_par_items.profile_id
       AND has_venue_access(p.venue_id, 'manager')
  ));

DROP POLICY IF EXISTS opening_par_items_delete_v ON opening_par_items;
CREATE POLICY opening_par_items_delete_v ON opening_par_items
  FOR DELETE USING (EXISTS (
    SELECT 1 FROM opening_par_profiles p
     WHERE p.id = opening_par_items.profile_id
       AND has_venue_access(p.venue_id, 'manager')
  ));


-- opening_runs: viewer read, admin write. No delete — cancellation is a
-- status change, handled by a future RPC.
DROP POLICY IF EXISTS opening_runs_select_v ON opening_runs;
CREATE POLICY opening_runs_select_v ON opening_runs
  FOR SELECT USING (has_venue_access(venue_id, 'viewer'));

DROP POLICY IF EXISTS opening_runs_insert_v ON opening_runs;
CREATE POLICY opening_runs_insert_v ON opening_runs
  FOR INSERT WITH CHECK (has_venue_access(venue_id, 'admin'));

DROP POLICY IF EXISTS opening_runs_update_v ON opening_runs;
CREATE POLICY opening_runs_update_v ON opening_runs
  FOR UPDATE USING (has_venue_access(venue_id, 'admin'));


-- opening_run_items: inherits venue scope via the parent run row.
DROP POLICY IF EXISTS opening_run_items_select_v ON opening_run_items;
CREATE POLICY opening_run_items_select_v ON opening_run_items
  FOR SELECT USING (EXISTS (
    SELECT 1 FROM opening_runs r
     WHERE r.id = opening_run_items.run_id
       AND has_venue_access(r.venue_id, 'viewer')
  ));

DROP POLICY IF EXISTS opening_run_items_insert_v ON opening_run_items;
CREATE POLICY opening_run_items_insert_v ON opening_run_items
  FOR INSERT WITH CHECK (EXISTS (
    SELECT 1 FROM opening_runs r
     WHERE r.id = opening_run_items.run_id
       AND has_venue_access(r.venue_id, 'admin')
  ));

DROP POLICY IF EXISTS opening_run_items_update_v ON opening_run_items;
CREATE POLICY opening_run_items_update_v ON opening_run_items
  FOR UPDATE USING (EXISTS (
    SELECT 1 FROM opening_runs r
     WHERE r.id = opening_run_items.run_id
       AND has_venue_access(r.venue_id, 'admin')
  ));


-- -----------------------------------------------------------------------------
-- Triggers
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION opening_par_items_touch_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS opening_par_items_set_updated_at ON opening_par_items;
CREATE TRIGGER opening_par_items_set_updated_at
  BEFORE UPDATE ON opening_par_items
  FOR EACH ROW EXECUTE FUNCTION opening_par_items_touch_updated_at();


-- -----------------------------------------------------------------------------
-- Seed: one default "Standard" profile per existing venue (if not already).
-- No per-bar rows are created here. Admins fill those in via the PAR editor.
-- -----------------------------------------------------------------------------

INSERT INTO opening_par_profiles (venue_id, name, is_default)
SELECT v.id, 'Standard', true
  FROM venues v
 WHERE NOT EXISTS (
         SELECT 1 FROM opening_par_profiles p
          WHERE p.venue_id = v.id
            AND p.is_default = true
            AND p.active = true
       );


-- Done. Verify with:
--   SELECT name, is_default, venue_id FROM opening_par_profiles;
--   SELECT COUNT(*) FROM opening_par_items;   -- expect 0
--   SELECT COUNT(*) FROM opening_runs;        -- expect 0
