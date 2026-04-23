-- =============================================================================
-- X2 — Historical per-night bar integrity
-- Date: 2026-04-22
-- Safe-point tag (pre-apply): safe_point_pre_x2_night_bars
-- =============================================================================
--
-- Problem being fixed:
--   getActiveBarsForNight(nightId) used to return the venue's current global
--   active-bars list, ignoring the nightId. That meant switching to a past
--   night showed the latest setup, not the setup that belonged to that night.
--   The bug propagated to Dispatch, Variance, Accountability, End-of-Night,
--   Staff Performance, Shift Reports, and Waste — every page that asked
--   "which bars for this night?".
--
-- What this migration does:
--   • Creates night_bars (id, night_id, bar_id, bar_name_at, created_at).
--     bar_name_at is a snapshot of bars.name at the time of snapshot so
--     later renames don't rewrite history.
--   • RLS: viewer+ SELECT, admin+ INSERT/DELETE. No UPDATE policy —
--     snapshot rows are additive/removable only.
--   • Trigger: AFTER INSERT ON nights auto-populates night_bars from the
--     venue's currently-active bars. Every path that creates a night gets
--     the snapshot automatically.
--   • RPC backfill_night_bars(v_venue_id): admin-only, reconstructs
--     missing rows for historical nights from verifiable transactional
--     evidence (events + bar_close_summaries). Does not touch nights that
--     already have snapshots.
--   • One-shot inline backfill at migration-apply time using the same
--     evidence sources, so existing nights have correct snapshots
--     immediately after this migration runs.
--
-- What this migration deliberately does NOT do:
--   • It does NOT guess history from current state. Nights with zero
--     transactional evidence stay empty; the client fallback path (global
--     active bars with a _fallback flag) handles those explicitly.
--   • It does NOT touch bar or night rows.
--   • It does NOT touch events, or any snapshot table, or the variance
--     engine.
--   • It does NOT change RLS on any existing table.
--
-- Rollback:
--     BEGIN;
--       DROP TRIGGER IF EXISTS nights_snapshot_bars_ai ON nights;
--       DROP FUNCTION IF EXISTS snapshot_night_bars_on_insert();
--       DROP FUNCTION IF EXISTS backfill_night_bars(UUID);
--       DROP TABLE IF EXISTS night_bars CASCADE;
--     COMMIT;
-- =============================================================================


CREATE TABLE IF NOT EXISTS night_bars (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  night_id    UUID NOT NULL REFERENCES nights(id) ON DELETE CASCADE,
  bar_id      UUID NOT NULL REFERENCES bars(id) ON DELETE RESTRICT,
  bar_name_at TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (night_id, bar_id)
);
CREATE INDEX IF NOT EXISTS night_bars_night_idx ON night_bars (night_id);
CREATE INDEX IF NOT EXISTS night_bars_bar_idx  ON night_bars (bar_id);

ALTER TABLE night_bars ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS night_bars_select_v ON night_bars;
CREATE POLICY night_bars_select_v ON night_bars
  FOR SELECT USING (EXISTS (
    SELECT 1 FROM nights n
     WHERE n.id = night_bars.night_id
       AND has_venue_access(n.venue_id, 'viewer')
  ));
DROP POLICY IF EXISTS night_bars_insert_v ON night_bars;
CREATE POLICY night_bars_insert_v ON night_bars
  FOR INSERT WITH CHECK (EXISTS (
    SELECT 1 FROM nights n
     WHERE n.id = night_bars.night_id
       AND has_venue_access(n.venue_id, 'admin')
  ));
DROP POLICY IF EXISTS night_bars_delete_v ON night_bars;
CREATE POLICY night_bars_delete_v ON night_bars
  FOR DELETE USING (EXISTS (
    SELECT 1 FROM nights n
     WHERE n.id = night_bars.night_id
       AND has_venue_access(n.venue_id, 'admin')
  ));


CREATE OR REPLACE FUNCTION snapshot_night_bars_on_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  INSERT INTO night_bars (night_id, bar_id, bar_name_at)
  SELECT NEW.id, b.id, b.name
    FROM bars b
   WHERE b.venue_id = NEW.venue_id AND b.active = true
  ON CONFLICT (night_id, bar_id) DO NOTHING;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS nights_snapshot_bars_ai ON nights;
CREATE TRIGGER nights_snapshot_bars_ai
  AFTER INSERT ON nights
  FOR EACH ROW EXECUTE FUNCTION snapshot_night_bars_on_insert();


CREATE OR REPLACE FUNCTION backfill_night_bars(v_venue_id UUID)
RETURNS TABLE (
  night_id UUID,
  night_name TEXT,
  bars_inserted INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  r RECORD;
  inserted_count INTEGER;
BEGIN
  IF NOT has_venue_access(v_venue_id, 'admin') THEN
    RAISE EXCEPTION 'admin role required on venue' USING ERRCODE = '42501';
  END IF;

  FOR r IN
    SELECT n.id AS nid, n.name AS nname
      FROM nights n
     WHERE n.venue_id = v_venue_id
     ORDER BY n.date NULLS LAST, n.name
  LOOP
    WITH evidence AS (
      SELECT DISTINCT bar_id FROM events
        WHERE night_id = r.nid AND bar_id IS NOT NULL
      UNION
      SELECT DISTINCT bar_id FROM bar_close_summaries
        WHERE night_id = r.nid AND bar_id IS NOT NULL
    )
    INSERT INTO night_bars (night_id, bar_id, bar_name_at)
    SELECT r.nid, e.bar_id,
           COALESCE(b.name, 'Unknown bar ' || SUBSTRING(e.bar_id::text, 1, 8))
      FROM evidence e
      LEFT JOIN bars b ON b.id = e.bar_id
    ON CONFLICT (night_id, bar_id) DO NOTHING;

    GET DIAGNOSTICS inserted_count = ROW_COUNT;
    night_id := r.nid;
    night_name := r.nname;
    bars_inserted := inserted_count;
    RETURN NEXT;
  END LOOP;
  RETURN;
END;
$$;


-- One-shot inline backfill across every venue at migration-apply time.
INSERT INTO night_bars (night_id, bar_id, bar_name_at)
SELECT DISTINCT e.night_id, e.bar_id,
       COALESCE(b.name, 'Unknown bar ' || SUBSTRING(e.bar_id::text, 1, 8))
  FROM events e
  LEFT JOIN bars b ON b.id = e.bar_id
 WHERE e.night_id IS NOT NULL AND e.bar_id IS NOT NULL
ON CONFLICT (night_id, bar_id) DO NOTHING;

INSERT INTO night_bars (night_id, bar_id, bar_name_at)
SELECT DISTINCT bcs.night_id, bcs.bar_id,
       COALESCE(b.name, 'Unknown bar ' || SUBSTRING(bcs.bar_id::text, 1, 8))
  FROM bar_close_summaries bcs
  LEFT JOIN bars b ON b.id = bcs.bar_id
 WHERE bcs.night_id IS NOT NULL AND bcs.bar_id IS NOT NULL
ON CONFLICT (night_id, bar_id) DO NOTHING;
