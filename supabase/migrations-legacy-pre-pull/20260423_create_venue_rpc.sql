-- 20260423_create_venue_rpc.sql
--
-- Restore the missing public.create_venue(...) RPC that the client's
-- New-Venue modal (www/index.html openAddVenue) has always called.
-- Without it PostgREST returns "Could not find the function
-- public.create_venue(...) in the schema cache" and the New-Venue save
-- path fails for every user/venue.
--
-- The function is SECURITY DEFINER so the INSERT + RETURNING can cleanly
-- produce the new venue's id regardless of whether the caller's RLS
-- SELECT policy on public.venues would admit the row in the same
-- transaction (the AFTER INSERT trigger venues_auto_grant_owner is what
-- adds the caller's venue_members row — creating the SELECT visibility
-- that RLS needs — and that trigger only fires once the INSERT has
-- committed its row).
--
-- The existing AFTER INSERT trigger grant_venue_creator_owner handles
-- creator ownership via auth.uid(); SECURITY DEFINER preserves the
-- caller's JWT context, so auth.uid() still resolves to the human who
-- initiated the RPC — no ownership drift.
--
-- ── Rollback ──────────────────────────────────────────────────────
-- DROP FUNCTION IF EXISTS public.create_venue(text, text, text, text);
-- ──────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.create_venue(
  p_name     text,
  p_address  text,
  p_phone    text,
  p_currency text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_new_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'create_venue: not authenticated';
  END IF;

  IF p_name IS NULL OR length(btrim(p_name)) = 0 THEN
    RAISE EXCEPTION 'create_venue: name is required';
  END IF;

  INSERT INTO public.venues (name, address, phone, currency)
  VALUES (
    btrim(p_name),
    NULLIF(btrim(COALESCE(p_address, '')), ''),
    NULLIF(btrim(COALESCE(p_phone,   '')), ''),
    COALESCE(NULLIF(btrim(COALESCE(p_currency, '')), ''), 'CAD')
  )
  RETURNING id INTO v_new_id;

  RETURN v_new_id;
END;
$$;

REVOKE ALL ON FUNCTION public.create_venue(text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_venue(text, text, text, text) TO authenticated;
