--
-- PostgreSQL database dump
--


-- Dumped from database version 17.6
-- Dumped by pg_dump version 18.3

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: adjustment_reason; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.adjustment_reason AS ENUM (
    'found',
    'lost',
    'damaged',
    'theft',
    'administrative',
    'opening_balance',
    'other'
);


--
-- Name: audit_source; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.audit_source AS ENUM (
    'ui',
    'sync',
    'system',
    'admin_override',
    'migration',
    'edge_function'
);


--
-- Name: conflict_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.conflict_status AS ENUM (
    'open',
    'resolved_local',
    'resolved_server',
    'deferred'
);


--
-- Name: count_session_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.count_session_status AS ENUM (
    'draft',
    'in_progress',
    'submitted',
    'approved',
    'voided'
);


--
-- Name: event_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.event_status AS ENUM (
    'pending',
    'approved',
    'rejected',
    'voided'
);


--
-- Name: event_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.event_type AS ENUM (
    'bottle_service',
    'spillage',
    'breakage',
    'comp',
    'void',
    'transfer',
    'other'
);


--
-- Name: invoice_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.invoice_status AS ENUM (
    'pending',
    'approved',
    'rejected',
    'paid',
    'void'
);


--
-- Name: item_category; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.item_category AS ENUM (
    'spirit',
    'beer',
    'wine',
    'mixer',
    'garnish',
    'consumable',
    'equipment',
    'other'
);


--
-- Name: movement_type; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.movement_type AS ENUM (
    'receipt',
    'transfer_out',
    'transfer_in',
    'adjustment',
    'waste',
    'event_consumption',
    'count_correction',
    'opening_balance',
    'migration'
);


--
-- Name: permission_action; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.permission_action AS ENUM (
    'read',
    'insert',
    'update',
    'delete'
);


--
-- Name: placement_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.placement_status AS ENUM (
    'open',
    'closed',
    'cancelled'
);


--
-- Name: po_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.po_status AS ENUM (
    'draft',
    'sent',
    'partially_received',
    'received',
    'cancelled'
);


--
-- Name: queue_status; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.queue_status AS ENUM (
    'pending',
    'synced',
    'failed',
    'conflict',
    'blocked'
);


--
-- Name: user_role; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.user_role AS ENUM (
    'owner',
    'admin',
    'co_admin',
    'manager',
    'finance',
    'bartender',
    'barback',
    'door',
    'promoter'
);


--
-- Name: waste_reason; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.waste_reason AS ENUM (
    'spillage',
    'breakage',
    'expired',
    'contamination',
    'other'
);


--
-- Name: _backup_all_venues_daily(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._backup_all_venues_daily() RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE v uuid;
BEGIN
  FOR v IN SELECT id FROM public.venues LOOP
    BEGIN
      PERFORM public._do_create_backup(v, 'cron', '{}'::jsonb, NULL);
      PERFORM public.prune_venue_backups(v);
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING '[BARINV-cron] backup failed for venue %: %', v, SQLERRM;
    END;
  END LOOP;
END;
$$;


--
-- Name: _do_create_backup(uuid, text, jsonb, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._do_create_backup(v_venue_id uuid, v_trigger text, v_context jsonb DEFAULT '{}'::jsonb, v_caller uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $_$
DECLARE
  payload      jsonb := '{}'::jsonb;
  tbl_payload  jsonb;
  tbl_count    integer;
  total_rows   integer := 0;
  total_tables integer := 0;
  t            text;
  bk_id        uuid;
BEGIN
  FOR t IN SELECT table_name FROM public._venue_scoped_tables() LOOP
    EXECUTE format(
      'SELECT COALESCE(jsonb_agg(to_jsonb(r)), ''[]''::jsonb), count(*)::int
         FROM public.%I r WHERE venue_id = $1', t
    ) INTO tbl_payload, tbl_count USING v_venue_id;
    payload := payload || jsonb_build_object(t, tbl_payload);
    total_rows := total_rows + tbl_count;
    total_tables := total_tables + 1;
  END LOOP;

  INSERT INTO public.backup_snapshots
    (venue_id, trigger_source, trigger_context, payload, row_count, table_count, created_by)
  VALUES
    (v_venue_id, v_trigger, COALESCE(v_context, '{}'::jsonb), payload, total_rows, total_tables, v_caller)
  RETURNING id INTO bk_id;

  RAISE NOTICE '[BARINV-backup] venue=% trigger=% rows=% tables=% id=%',
    v_venue_id, v_trigger, total_rows, total_tables, bk_id;
  RETURN bk_id;
END;
$_$;


--
-- Name: _nsa_before_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._nsa_before_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF NEW.access_code IS NULL OR NEW.access_code = '' THEN
    NEW.access_code := public.gen_assignment_code();
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: _nsa_touch_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._nsa_touch_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN NEW.updated_at := now(); RETURN NEW; END;
$$;


--
-- Name: _role_rank(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._role_rank(r text) RETURNS integer
    LANGUAGE sql IMMUTABLE
    SET search_path TO 'pg_catalog'
    AS $$
  SELECT CASE r
    WHEN 'viewer'  THEN 1
    WHEN 'staff'   THEN 2
    WHEN 'manager' THEN 3
    WHEN 'admin'   THEN 4
    WHEN 'owner'   THEN 5
    ELSE 0
  END
$$;


--
-- Name: _venue_scoped_tables(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public._venue_scoped_tables() RETURNS TABLE(table_name text)
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
  SELECT c.table_name::text
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.column_name = 'venue_id'
    -- Exclude the backup table itself + ephemeral logs to avoid recursive growth.
    AND c.table_name NOT IN ('backup_snapshots')
  ORDER BY c.table_name;
$$;


--
-- Name: auth_is_scoped_staff(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auth_is_scoped_staff() RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(
    (auth.jwt() -> 'app_metadata' ->> 'scope') = 'staff_session',
    false
  )
$$;


--
-- Name: auth_scoped_assignment_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auth_scoped_assignment_id() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  SELECT NULLIF(auth.jwt() -> 'app_metadata' ->> 'assignment_id', '')::uuid
$$;


--
-- Name: auth_scoped_bar_ids(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auth_scoped_bar_ids() RETURNS uuid[]
    LANGUAGE sql STABLE
    AS $$
  SELECT COALESCE(
    ARRAY(
      SELECT (jsonb_array_elements_text(
        auth.jwt() -> 'app_metadata' -> 'allowed_bar_ids'
      ))::uuid
    ),
    ARRAY[]::uuid[]
  )
$$;


--
-- Name: auth_scoped_night(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auth_scoped_night() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  SELECT NULLIF(auth.jwt() -> 'app_metadata' ->> 'night_id', '')::uuid
$$;


--
-- Name: auth_scoped_role(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auth_scoped_role() RETURNS text
    LANGUAGE sql STABLE
    AS $$
  SELECT auth.jwt() -> 'app_metadata' ->> 'role'
$$;


--
-- Name: auth_scoped_staff_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auth_scoped_staff_id() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  SELECT NULLIF(auth.jwt() -> 'app_metadata' ->> 'staff_id', '')::uuid
$$;


--
-- Name: auth_scoped_venue(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.auth_scoped_venue() RETURNS uuid
    LANGUAGE sql STABLE
    AS $$
  SELECT NULLIF(auth.jwt() -> 'app_metadata' ->> 'venue_id', '')::uuid
$$;


--
-- Name: backfill_giveaway_actions(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.backfill_giveaway_actions(v_venue_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  comp_count int := 0;
  shot_count int := 0;
  caller uuid := auth.uid();
BEGIN
  IF caller IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;
  IF NOT public.has_venue_access(v_venue_id, 'admin') THEN
    RAISE EXCEPTION 'Forbidden: admin role required on this venue';
  END IF;

  WITH upd AS (
    UPDATE public.events
       SET action = 'COMP',
           reason_code = COALESCE(reason_code, 'other'),
           qty_basis   = COALESCE(qty_basis,   'shot')
     WHERE venue_id = v_venue_id
       AND action = 'ADJUSTMENT'
       AND notes LIKE 'COMP from %'
    RETURNING 1
  )
  SELECT count(*) INTO comp_count FROM upd;

  WITH upd AS (
    UPDATE public.events
       SET action = 'SHOT',
           reason_code = COALESCE(reason_code, 'staff_shot'),
           qty_basis   = COALESCE(qty_basis,   'shot')
     WHERE venue_id = v_venue_id
       AND action = 'ADJUSTMENT'
       AND notes LIKE 'SHOT from %'
    RETURNING 1
  )
  SELECT count(*) INTO shot_count FROM upd;

  RETURN jsonb_build_object(
    'venue_id', v_venue_id,
    'comp_updated', comp_count,
    'shot_updated', shot_count
  );
END;
$$;


--
-- Name: backfill_night_bars(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.backfill_night_bars(v_venue_id uuid) RETURNS TABLE(night_id uuid, night_name text, bars_inserted integer)
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
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
    SELECT r.nid, e.bar_id, COALESCE(b.name, 'Unknown bar ' || SUBSTRING(e.bar_id::text, 1, 8))
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


--
-- Name: create_venue(text, text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_venue(p_name text, p_address text, p_phone text, p_currency text) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
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


--
-- Name: create_venue_backup(uuid, text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_venue_backup(v_venue_id uuid, v_trigger text DEFAULT 'manual'::text, v_context jsonb DEFAULT '{}'::jsonb) RETURNS uuid
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE bk_id uuid;
BEGIN
  IF NOT public.has_venue_access(v_venue_id, 'admin') THEN
    RAISE EXCEPTION 'Forbidden: admin role required on this venue';
  END IF;
  IF v_trigger NOT IN ('cron','pre_clean','pre_restore','manual') THEN
    RAISE EXCEPTION 'Invalid trigger: %', v_trigger;
  END IF;
  bk_id := public._do_create_backup(v_venue_id, v_trigger, v_context, auth.uid());
  PERFORM public.prune_venue_backups(v_venue_id);
  RETURN bk_id;
END;
$$;


--
-- Name: delete_venue(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_venue(v_venue_id uuid) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE
  caller uuid := auth.uid();
BEGIN
  IF caller IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.venue_members
    WHERE user_id = caller
      AND venue_id = v_venue_id
      AND role IN ('owner','admin')
  ) THEN
    RAISE EXCEPTION 'Only venue owners or admins can delete this venue';
  END IF;

  DELETE FROM public.events WHERE venue_id = v_venue_id;
  DELETE FROM public.loyalty_points WHERE venue_id = v_venue_id;
  DELETE FROM public.menu_items WHERE venue_id = v_venue_id;
  DELETE FROM public.placements WHERE venue_id = v_venue_id;
  DELETE FROM public.po_items WHERE venue_id = v_venue_id;
  DELETE FROM public.recipe_ingredients WHERE venue_id = v_venue_id;
  DELETE FROM public.invoices WHERE venue_id = v_venue_id;
  DELETE FROM public.receipt_items WHERE venue_id = v_venue_id;
  DELETE FROM public.guest_bookings WHERE venue_id = v_venue_id;
  DELETE FROM public.guestlist WHERE venue_id = v_venue_id;
  DELETE FROM public.vip_tables WHERE venue_id = v_venue_id;
  DELETE FROM public.bar_close_summaries WHERE venue_id = v_venue_id;
  DELETE FROM public.bar_item_dispatch_snapshots WHERE venue_id = v_venue_id;
  DELETE FROM public.bar_item_shot_snapshots WHERE venue_id = v_venue_id;
  DELETE FROM public.pos_bar_product_snapshots WHERE venue_id = v_venue_id;
  DELETE FROM public.pos_bar_snapshots WHERE venue_id = v_venue_id;
  DELETE FROM public.pos_sync_runs WHERE venue_id = v_venue_id;
  DELETE FROM public.pos_transactions WHERE venue_id = v_venue_id;
  DELETE FROM public.pos_bar_mappings WHERE venue_id = v_venue_id;
  DELETE FROM public.pos_product_item_mappings WHERE venue_id = v_venue_id;
  DELETE FROM public.pos_source_map WHERE venue_id = v_venue_id;
  DELETE FROM public.warehouse_transfers WHERE venue_id = v_venue_id;
  DELETE FROM public.nights WHERE venue_id = v_venue_id;
  DELETE FROM public.purchase_orders WHERE venue_id = v_venue_id;
  DELETE FROM public.receipts WHERE venue_id = v_venue_id;
  DELETE FROM public.recipes WHERE venue_id = v_venue_id;
  DELETE FROM public.warehouse_items WHERE venue_id = v_venue_id;
  DELETE FROM public.pos_connections WHERE venue_id = v_venue_id;
  DELETE FROM public.stations WHERE venue_id = v_venue_id;
  DELETE FROM public.bars WHERE venue_id = v_venue_id;
  DELETE FROM public.items WHERE venue_id = v_venue_id;
  DELETE FROM public.staff WHERE venue_id = v_venue_id;
  DELETE FROM public.suppliers WHERE venue_id = v_venue_id;
  DELETE FROM public.guests WHERE venue_id = v_venue_id;
  DELETE FROM public.business_profile WHERE venue_id = v_venue_id;
  DELETE FROM public.menu_settings WHERE venue_id = v_venue_id;
  DELETE FROM public.loyalty_config WHERE venue_id = v_venue_id;

  DELETE FROM public.venues WHERE id = v_venue_id;
END;
$$;


--
-- Name: gen_assignment_code(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.gen_assignment_code() RETURNS text
    LANGUAGE sql
    AS $$
  -- 10-char Crockford-ish alphabet (no ambiguous 0/O/1/I): ~50 bits entropy.
  SELECT string_agg(
    substr('23456789ABCDEFGHJKLMNPQRSTUVWXYZ',
           1 + (get_byte(gen_random_bytes(1), 0) % 32)::int, 1),
    ''
  ) FROM generate_series(1, 10);
$$;


--
-- Name: get_user_org_id(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_user_org_id() RETURNS uuid
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select organization_id from public.profiles where id = auth.uid() limit 1;
$$;


--
-- Name: get_venue_role(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_venue_role(v_venue_id uuid) RETURNS public.user_role
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select role from public.venue_users
  where user_id = auth.uid() and venue_id = v_venue_id and active = true
  limit 1;
$$;


--
-- Name: grant_venue_creator_owner(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.grant_venue_creator_owner() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
BEGIN
  IF auth.uid() IS NOT NULL THEN
    INSERT INTO public.venue_members (user_id, venue_id, role, created_by)
    VALUES (auth.uid(), NEW.id, 'owner', auth.uid())
    ON CONFLICT (user_id, venue_id) DO UPDATE SET role = 'owner';
  END IF;
  RETURN NEW;
END;
$$;


--
-- Name: has_min_role(uuid, public.user_role); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_min_role(v_venue_id uuid, min_role public.user_role) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1 from public.venue_users
    where user_id = auth.uid()
      and venue_id = v_venue_id
      and active = true
      and case min_role
            when 'owner'     then role = 'owner'
            when 'admin'     then role in ('owner','admin')
            when 'co_admin'  then role in ('owner','admin','co_admin')
            when 'manager'   then role in ('owner','admin','co_admin','manager')
            when 'finance'   then role in ('owner','admin','co_admin','manager','finance')
            when 'bartender' then role in ('owner','admin','co_admin','manager','finance','bartender')
            when 'barback'   then role in ('owner','admin','co_admin','manager','finance','bartender','barback')
            when 'door'      then role in ('owner','admin','co_admin','manager','finance','bartender','barback','door')
            when 'promoter'  then true
          end
  );
$$;


--
-- Name: has_venue_access(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.has_venue_access(vid uuid, min_role text DEFAULT 'viewer'::text) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
  SELECT auth.uid() IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.venue_members vm
    WHERE vm.user_id = auth.uid()
      AND vm.venue_id = vid
      AND public._role_rank(vm.role) >= public._role_rank(min_role)
  )
$$;


--
-- Name: is_org_admin(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_org_admin() RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1 from public.venue_users vu
    join public.profiles p on p.id = auth.uid()
    where vu.user_id = auth.uid()
      and vu.organization_id = p.organization_id
      and vu.role in ('owner','admin')
      and vu.active = true
    limit 1
  );
$$;


--
-- Name: is_org_member(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_org_member(org_id uuid) RETURNS boolean
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and organization_id = org_id and active = true
  );
$$;


--
-- Name: opening_par_items_touch_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.opening_par_items_touch_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;


--
-- Name: prevent_last_owner_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_last_owner_delete() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public', 'pg_catalog'
    AS $$
BEGIN
  IF OLD.role = 'owner' THEN
    IF (SELECT count(*) FROM public.venue_members
        WHERE venue_id = OLD.venue_id AND role = 'owner') <= 1 THEN
      RAISE EXCEPTION 'Cannot remove the last owner of venue %', OLD.venue_id;
    END IF;
  END IF;
  RETURN OLD;
END;
$$;


--
-- Name: prune_venue_backups(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prune_venue_backups(v_venue_id uuid) RETURNS integer
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $$
DECLARE deleted_count integer;
BEGIN
  WITH ranked AS (
    SELECT id,
           ROW_NUMBER() OVER (PARTITION BY date_trunc('day', created_at) ORDER BY created_at DESC) AS day_rank,
           ROW_NUMBER() OVER (PARTITION BY date_trunc('month', created_at) ORDER BY created_at DESC) AS month_rank
    FROM public.backup_snapshots
    WHERE venue_id = v_venue_id
  ),
  keepers AS (
    -- Keep most-recent-per-day for the last 30 days  +  most-recent-per-month for the last 12 months
    SELECT id FROM public.backup_snapshots bs
    WHERE bs.venue_id = v_venue_id
      AND (
        bs.id IN (SELECT id FROM ranked WHERE day_rank = 1 AND created_at > now() - interval '30 days') OR
        bs.id IN (SELECT id FROM ranked WHERE month_rank = 1 AND created_at > now() - interval '12 months')
      )
  )
  DELETE FROM public.backup_snapshots
   WHERE venue_id = v_venue_id AND id NOT IN (SELECT id FROM keepers);
  GET DIAGNOSTICS deleted_count = ROW_COUNT;
  RETURN deleted_count;
END;
$$;


--
-- Name: restore_venue_backup(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.restore_venue_backup(v_backup_id uuid) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_catalog'
    AS $_$
DECLARE
  bk           public.backup_snapshots;
  t            text;
  rows_ins     integer;
  total_ins    integer := 0;
  tables_used  integer := 0;
BEGIN
  SELECT * INTO bk FROM public.backup_snapshots WHERE id = v_backup_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Backup not found';
  END IF;
  IF NOT public.has_venue_access(bk.venue_id, 'admin') THEN
    RAISE EXCEPTION 'Forbidden: admin role required on this venue';
  END IF;

  -- Defer FK checks for the duration of this transaction. All venue-
  -- scoped FKs were switched to DEFERRABLE in the deferrable_fks_for_restore
  -- migration. Non-deferrable FKs (if any get added later) will simply
  -- continue firing eagerly — the restore may then fail on order, which
  -- is preferable to silent corruption.
  SET CONSTRAINTS ALL DEFERRED;

  -- Wipe current venue data (all venue-scoped tables)
  FOR t IN SELECT table_name FROM public._venue_scoped_tables() LOOP
    EXECUTE format('DELETE FROM public.%I WHERE venue_id = $1', t) USING bk.venue_id;
  END LOOP;

  -- Reinsert from payload, populating full rows via jsonb_populate_recordset
  FOR t IN SELECT table_name FROM public._venue_scoped_tables() LOOP
    IF bk.payload ? t AND jsonb_typeof(bk.payload->t) = 'array'
       AND jsonb_array_length(bk.payload->t) > 0 THEN
      EXECUTE format(
        'INSERT INTO public.%I SELECT * FROM jsonb_populate_recordset(NULL::public.%I, $1)',
        t, t
      ) USING bk.payload->t;
      GET DIAGNOSTICS rows_ins = ROW_COUNT;
      total_ins := total_ins + rows_ins;
      tables_used := tables_used + 1;
    END IF;
  END LOOP;

  -- SET CONSTRAINTS IMMEDIATE forces all deferred checks NOW,
  -- before COMMIT, so any violation produces an error we can
  -- translate clearly instead of COMMIT-time surprises.
  SET CONSTRAINTS ALL IMMEDIATE;

  RAISE NOTICE '[BARINV-restore] backup=% venue=% rows_inserted=% tables=%',
    v_backup_id, bk.venue_id, total_ins, tables_used;

  RETURN jsonb_build_object(
    'backup_id',       bk.id,
    'venue_id',        bk.venue_id,
    'rows_inserted',   total_ins,
    'tables_restored', tables_used,
    'restored_at',     now()
  );
END;
$_$;


--
-- Name: set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'public'
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


--
-- Name: snapshot_night_bars_on_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.snapshot_night_bars_on_insert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
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


--
-- Name: touch_pos_credentials_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.touch_pos_credentials_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO 'pg_catalog'
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: backup_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.backup_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    venue_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    trigger_source text NOT NULL,
    trigger_context jsonb DEFAULT '{}'::jsonb NOT NULL,
    payload jsonb NOT NULL,
    row_count integer DEFAULT 0 NOT NULL,
    table_count integer DEFAULT 0 NOT NULL,
    byte_size bigint GENERATED ALWAYS AS (octet_length((payload)::text)) STORED,
    created_by uuid,
    CONSTRAINT backup_snapshots_trigger_source_check CHECK ((trigger_source = ANY (ARRAY['cron'::text, 'pre_clean'::text, 'pre_restore'::text, 'manual'::text, 'pre_migration_unit'::text])))
);


--
-- Name: bar_close_summaries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bar_close_summaries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    night_id uuid,
    bar_id uuid NOT NULL,
    connection_id uuid,
    closed_at timestamp with time zone DEFAULT now() NOT NULL,
    sales_gross numeric DEFAULT 0 NOT NULL,
    sales_net numeric DEFAULT 0 NOT NULL,
    tips_total numeric DEFAULT 0 NOT NULL,
    cash_total numeric DEFAULT 0 NOT NULL,
    card_total numeric DEFAULT 0 NOT NULL,
    transactions integer DEFAULT 0 NOT NULL,
    discounts_total numeric DEFAULT 0 NOT NULL,
    voids_total numeric DEFAULT 0 NOT NULL,
    refunds_total numeric DEFAULT 0 NOT NULL,
    currency text DEFAULT 'CAD'::text,
    notes text,
    source_ref jsonb DEFAULT '{}'::jsonb NOT NULL,
    venue_id uuid
);


--
-- Name: bar_item_dispatch_snapshots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bar_item_dispatch_snapshots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bar_item_dispatch_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bar_item_dispatch_snapshots (
    id bigint DEFAULT nextval('public.bar_item_dispatch_snapshots_id_seq'::regclass) NOT NULL,
    connection_id uuid,
    bar_id uuid NOT NULL,
    item_id uuid NOT NULL,
    snapshot_ts timestamp with time zone NOT NULL,
    bucket_minutes integer DEFAULT 60 NOT NULL,
    bottles_sent numeric DEFAULT 0 NOT NULL,
    shots_sent numeric DEFAULT 0 NOT NULL,
    ml_sent numeric DEFAULT 0 NOT NULL,
    units_sent numeric DEFAULT 0 NOT NULL,
    source text DEFAULT 'dispatch'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    venue_id uuid
);


--
-- Name: bar_item_shot_snapshots_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.bar_item_shot_snapshots_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: bar_item_shot_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bar_item_shot_snapshots (
    id bigint DEFAULT nextval('public.bar_item_shot_snapshots_id_seq'::regclass) NOT NULL,
    connection_id uuid,
    bar_id uuid NOT NULL,
    item_id uuid NOT NULL,
    snapshot_ts timestamp with time zone NOT NULL,
    bucket_minutes integer DEFAULT 60 NOT NULL,
    bottles_sent numeric DEFAULT 0 NOT NULL,
    full_shots_per_bottle numeric DEFAULT 0 NOT NULL,
    total_shots_sent numeric DEFAULT 0 NOT NULL,
    shots_sold numeric DEFAULT 0 NOT NULL,
    expected_shots_remaining numeric DEFAULT 0 NOT NULL,
    expected_bottles_remaining numeric DEFAULT 0 NOT NULL,
    expected_grams_remaining numeric DEFAULT 0 NOT NULL,
    restock_threshold_shots numeric DEFAULT 0 NOT NULL,
    restock_needed boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    venue_id uuid
);


--
-- Name: bars; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bars (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    venue_id uuid
);


--
-- Name: business_profile; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_profile (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    business_name text DEFAULT 'My Business'::text,
    business_type text DEFAULT 'bar'::text,
    currency text DEFAULT 'CAD'::text,
    timezone text DEFAULT 'America/Vancouver'::text,
    logo_url text,
    address text,
    settings jsonb DEFAULT '{}'::jsonb,
    updated_at timestamp with time zone DEFAULT now(),
    venue_id uuid,
    capabilities jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    night_id uuid,
    bar_id uuid,
    station_id uuid,
    item_id uuid,
    submitted_by text NOT NULL,
    qty numeric DEFAULT 1,
    action text NOT NULL,
    status text DEFAULT 'PENDING'::text,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    venue_id uuid,
    reason_code text,
    qty_basis text,
    CONSTRAINT events_qty_basis_check CHECK (((qty_basis IS NULL) OR (qty_basis = ANY (ARRAY['shot'::text, 'item_unit'::text]))))
);


--
-- Name: guest_bookings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.guest_bookings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    guest_id uuid,
    night_id uuid,
    vip_table_id uuid,
    party_size integer DEFAULT 1,
    status text DEFAULT 'confirmed'::text,
    arrival_time text,
    special_requests text,
    spend numeric DEFAULT 0,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    venue_id uuid
);


--
-- Name: guestlist; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.guestlist (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    night_id uuid,
    name text NOT NULL,
    phone text,
    ticket_type text DEFAULT 'General'::text,
    notes text,
    checked_in boolean DEFAULT false,
    checked_in_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    venue_id uuid,
    added_by text
);


--
-- Name: guests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.guests (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    phone text,
    email text,
    instagram text,
    notes text,
    tags text[] DEFAULT '{}'::text[],
    total_visits integer DEFAULT 0,
    total_spend numeric DEFAULT 0,
    avg_spend numeric DEFAULT 0,
    last_visit_at timestamp with time zone,
    vip_level text DEFAULT 'regular'::text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now(),
    venue_id uuid,
    added_by text
);


--
-- Name: invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    supplier_id uuid,
    po_id uuid,
    invoice_number text,
    amount numeric DEFAULT 0,
    status text DEFAULT 'PENDING'::text,
    invoice_date date,
    due_date date,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    venue_id uuid
);


--
-- Name: items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    sku text,
    category text,
    unit text DEFAULT 'bottle'::text,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    par_level integer DEFAULT 0,
    cost_price numeric DEFAULT 0,
    sale_price numeric DEFAULT 0,
    supplier_id uuid,
    category_type text DEFAULT 'beverage'::text,
    unit_size text DEFAULT '750ml'::text,
    units_per_case integer DEFAULT 1,
    reorder_point integer DEFAULT 0,
    bottle_size_ml integer,
    service_mode text DEFAULT 'regular_bar'::text,
    full_shots numeric,
    shot_weight_g numeric DEFAULT 31.5,
    measurement_mode text DEFAULT 'shot'::text,
    restock_threshold_shots numeric DEFAULT 0 NOT NULL,
    empty_bottle_weight_g numeric,
    full_bottle_weight_g numeric,
    image_url text,
    liquor_room_stock integer DEFAULT 0,
    venue_id uuid
);


--
-- Name: loyalty_config; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.loyalty_config (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    venue_id uuid,
    points_per_dollar numeric DEFAULT 1,
    tier_silver integer DEFAULT 500,
    tier_gold integer DEFAULT 2000,
    tier_platinum integer DEFAULT 5000,
    reward_rules jsonb DEFAULT '[]'::jsonb,
    active boolean DEFAULT true,
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: loyalty_points; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.loyalty_points (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    guest_id uuid,
    venue_id uuid,
    points integer NOT NULL,
    reason text NOT NULL,
    booking_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: menu_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.menu_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    item_id uuid,
    venue_id uuid,
    display_name text,
    description text,
    menu_category text,
    display_order integer DEFAULT 0,
    featured boolean DEFAULT false,
    visible boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: menu_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.menu_settings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    venue_id uuid,
    title text DEFAULT 'Our Menu'::text,
    subtitle text,
    logo_url text,
    theme text DEFAULT 'dark'::text,
    show_prices boolean DEFAULT true,
    show_categories boolean DEFAULT true,
    footer_text text,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);


--
-- Name: night_bars; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.night_bars (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    night_id uuid NOT NULL,
    bar_id uuid NOT NULL,
    bar_name_at text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: night_staff_assignments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.night_staff_assignments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    venue_id uuid NOT NULL,
    night_id uuid NOT NULL,
    staff_id uuid NOT NULL,
    role text NOT NULL,
    allowed_bar_ids uuid[] DEFAULT '{}'::uuid[] NOT NULL,
    access_code text NOT NULL,
    revoked boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT night_staff_assignments_role_check CHECK ((role = ANY (ARRAY['bartender'::text, 'barback'::text])))
);


--
-- Name: nights; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.nights (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    date date NOT NULL,
    code text NOT NULL,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    venue_id uuid
);


--
-- Name: opening_par_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.opening_par_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    profile_id uuid NOT NULL,
    bar_id uuid NOT NULL,
    item_id uuid NOT NULL,
    qty numeric NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT opening_par_items_qty_check CHECK ((qty >= (0)::numeric))
);


--
-- Name: opening_par_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.opening_par_profiles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    venue_id uuid NOT NULL,
    name text NOT NULL,
    is_default boolean DEFAULT false NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: opening_run_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.opening_run_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    run_id uuid NOT NULL,
    item_id uuid NOT NULL,
    par_qty numeric NOT NULL,
    issued_qty numeric,
    received_qty numeric,
    exception_note text
);


--
-- Name: opening_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.opening_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    venue_id uuid NOT NULL,
    night_id uuid NOT NULL,
    bar_id uuid NOT NULL,
    profile_id uuid NOT NULL,
    status text DEFAULT 'DRAFT'::text NOT NULL,
    has_exception boolean DEFAULT false NOT NULL,
    notes text,
    cancel_reason text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    prepared_by uuid,
    prepared_at timestamp with time zone,
    issued_by uuid,
    issued_at timestamp with time zone,
    received_by uuid,
    received_at timestamp with time zone,
    cancelled_by uuid,
    cancelled_at timestamp with time zone,
    CONSTRAINT opening_runs_status_check CHECK ((status = ANY (ARRAY['DRAFT'::text, 'ISSUED'::text, 'RECEIVED'::text, 'CANCELLED'::text])))
);


--
-- Name: placements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.placements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    station_id uuid NOT NULL,
    item_id uuid NOT NULL,
    qty numeric DEFAULT 1 NOT NULL,
    bartender_id uuid,
    barback_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    venue_id uuid
);


--
-- Name: po_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.po_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    po_id uuid,
    item_id uuid,
    quantity numeric NOT NULL,
    unit_cost numeric DEFAULT 0,
    total_cost numeric DEFAULT 0,
    received_qty numeric DEFAULT 0,
    notes text,
    venue_id uuid
);


--
-- Name: pos_bar_mappings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pos_bar_mappings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    connection_id uuid NOT NULL,
    pos_location_id text NOT NULL,
    pos_location_name text,
    bar_id uuid NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    venue_id uuid
);


--
-- Name: pos_bar_product_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pos_bar_product_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    connection_id uuid NOT NULL,
    bar_id uuid NOT NULL,
    snapshot_ts timestamp with time zone NOT NULL,
    bucket_minutes integer DEFAULT 1 NOT NULL,
    product_key text NOT NULL,
    product_name text NOT NULL,
    category text,
    qty numeric DEFAULT 0 NOT NULL,
    revenue_net numeric DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    venue_id uuid
);


--
-- Name: pos_bar_snapshots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pos_bar_snapshots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    connection_id uuid NOT NULL,
    bar_id uuid NOT NULL,
    snapshot_ts timestamp with time zone NOT NULL,
    bucket_minutes integer DEFAULT 1 NOT NULL,
    sales_gross numeric DEFAULT 0 NOT NULL,
    sales_net numeric DEFAULT 0 NOT NULL,
    tips_total numeric DEFAULT 0 NOT NULL,
    cash_total numeric DEFAULT 0 NOT NULL,
    card_total numeric DEFAULT 0 NOT NULL,
    transactions integer DEFAULT 0 NOT NULL,
    discounts_total numeric DEFAULT 0 NOT NULL,
    voids_total numeric DEFAULT 0 NOT NULL,
    refunds_total numeric DEFAULT 0 NOT NULL,
    currency text DEFAULT 'CAD'::text,
    source_ref jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    venue_id uuid
);


--
-- Name: pos_connections; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pos_connections (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    business_id uuid,
    provider text NOT NULL,
    name text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    config jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    venue_id uuid
);


--
-- Name: pos_credentials; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pos_credentials (
    venue_id uuid NOT NULL,
    provider text DEFAULT 'square'::text NOT NULL,
    access_token text NOT NULL,
    location_id text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE pos_credentials; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.pos_credentials IS 'Server-only POS credentials. Access via Edge Functions with service_role only. Never expose to client.';


--
-- Name: COLUMN pos_credentials.access_token; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON COLUMN public.pos_credentials.access_token IS 'Provider access token. NEVER return this to clients.';


--
-- Name: pos_product_item_mappings_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.pos_product_item_mappings_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: pos_product_item_mappings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pos_product_item_mappings (
    id bigint DEFAULT nextval('public.pos_product_item_mappings_id_seq'::regclass) NOT NULL,
    connection_id uuid NOT NULL,
    product_key text NOT NULL,
    product_name text NOT NULL,
    inventory_item_id uuid NOT NULL,
    usage_mode text DEFAULT 'shot'::text NOT NULL,
    shots_per_sale numeric DEFAULT 0 NOT NULL,
    ml_per_sale numeric DEFAULT 0 NOT NULL,
    units_per_sale numeric DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    venue_id uuid
);


--
-- Name: pos_source_map; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pos_source_map (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider text DEFAULT 'square'::text NOT NULL,
    location_id text NOT NULL,
    square_source_key text NOT NULL,
    square_source_label text,
    local_bar_code text NOT NULL,
    local_bar_name text,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    venue_id uuid
);


--
-- Name: pos_sync_runs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pos_sync_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    connection_id uuid NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    ended_at timestamp with time zone,
    status text DEFAULT 'running'::text NOT NULL,
    range_start timestamp with time zone,
    range_end timestamp with time zone,
    cursor text,
    metrics jsonb DEFAULT '{}'::jsonb NOT NULL,
    error_message text,
    venue_id uuid
);


--
-- Name: pos_transactions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pos_transactions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    provider text DEFAULT 'square'::text NOT NULL,
    square_payment_id text NOT NULL,
    square_order_id text,
    location_id text NOT NULL,
    source_key text,
    source_label text,
    local_bar_code text,
    amount_cents integer DEFAULT 0 NOT NULL,
    tip_cents integer DEFAULT 0 NOT NULL,
    cash_cents integer DEFAULT 0 NOT NULL,
    card_cents integer DEFAULT 0 NOT NULL,
    status text,
    paid_at timestamp with time zone,
    raw jsonb,
    created_at timestamp with time zone DEFAULT now(),
    venue_id uuid
);


--
-- Name: profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.profiles (
    id uuid NOT NULL,
    username text NOT NULL,
    role text DEFAULT 'admin'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: purchase_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.purchase_orders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    supplier_id uuid,
    status text DEFAULT 'DRAFT'::text,
    po_number text,
    notes text,
    total_cost numeric DEFAULT 0,
    ordered_at timestamp with time zone,
    received_at timestamp with time zone,
    created_by text,
    created_at timestamp with time zone DEFAULT now(),
    venue_id uuid
);


--
-- Name: receipt_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.receipt_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    receipt_id uuid,
    item_name text,
    quantity numeric DEFAULT 1,
    unit_price numeric DEFAULT 0,
    total_price numeric DEFAULT 0,
    notes text,
    venue_id uuid
);


--
-- Name: receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.receipts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    supplier_id uuid,
    vendor_name text,
    purchased_by text,
    receipt_date date,
    subtotal numeric DEFAULT 0,
    tax numeric DEFAULT 0,
    total numeric DEFAULT 0,
    image_data text,
    notes text,
    status text DEFAULT 'PENDING'::text,
    created_at timestamp with time zone DEFAULT now(),
    venue_id uuid
);


--
-- Name: recipe_ingredients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipe_ingredients (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    recipe_id uuid,
    item_id uuid,
    quantity numeric NOT NULL,
    unit text DEFAULT 'ml'::text,
    notes text,
    venue_id uuid
);


--
-- Name: recipes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    category text,
    description text,
    yield_qty numeric DEFAULT 1,
    yield_unit text DEFAULT 'serving'::text,
    sale_price numeric DEFAULT 0,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    venue_id uuid
);


--
-- Name: staff; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    role text NOT NULL,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    legal_name text,
    email text,
    phone text,
    emergency_contact text,
    notes text,
    venue_id uuid
);


--
-- Name: stations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    bar_id uuid NOT NULL,
    name text NOT NULL,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    venue_id uuid
);


--
-- Name: suppliers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.suppliers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    contact text,
    email text,
    phone text,
    address text,
    notes text,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    venue_id uuid
);


--
-- Name: venue_members; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.venue_members (
    user_id uuid NOT NULL,
    venue_id uuid NOT NULL,
    role text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    created_by uuid,
    CONSTRAINT venue_members_role_check CHECK ((role = ANY (ARRAY['owner'::text, 'admin'::text, 'manager'::text, 'staff'::text, 'viewer'::text])))
);


--
-- Name: TABLE venue_members; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.venue_members IS 'User → venue memberships with role. Read-gated per-row; writes require admin+.';


--
-- Name: venues; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.venues (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    address text,
    phone text,
    logo_url text,
    currency text DEFAULT 'CAD'::text,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: vip_tables; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vip_tables (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    night_id uuid,
    table_name text NOT NULL,
    guest_name text,
    server_name text,
    minimum_spend numeric DEFAULT 0 NOT NULL,
    deposit_paid numeric DEFAULT 0 NOT NULL,
    actual_spend numeric DEFAULT 0 NOT NULL,
    comps numeric DEFAULT 0 NOT NULL,
    discounts numeric DEFAULT 0 NOT NULL,
    notes text,
    is_closed boolean DEFAULT false NOT NULL,
    closed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    booked_by text DEFAULT ''::text,
    venue_id uuid,
    position_x numeric DEFAULT 0,
    position_y numeric DEFAULT 0,
    table_shape text DEFAULT 'round'::text,
    table_seats integer DEFAULT 4,
    table_status text DEFAULT 'available'::text,
    table_rotation integer DEFAULT 0
);


--
-- Name: warehouse_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.warehouse_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    category text DEFAULT 'Other'::text NOT NULL,
    brand text NOT NULL,
    size text,
    unit text DEFAULT 'ml'::text,
    stock numeric DEFAULT 0,
    min_stock integer DEFAULT 0,
    active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    venue_id uuid
);


--
-- Name: warehouse_transfers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.warehouse_transfers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    item_id uuid,
    quantity numeric NOT NULL,
    destination text,
    created_by text,
    created_at timestamp with time zone DEFAULT now(),
    venue_id uuid
);


--
-- Name: backup_snapshots backup_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.backup_snapshots
    ADD CONSTRAINT backup_snapshots_pkey PRIMARY KEY (id);


--
-- Name: bar_close_summaries bar_close_summaries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bar_close_summaries
    ADD CONSTRAINT bar_close_summaries_pkey PRIMARY KEY (id);


--
-- Name: bar_item_dispatch_snapshots bar_item_dispatch_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bar_item_dispatch_snapshots
    ADD CONSTRAINT bar_item_dispatch_snapshots_pkey PRIMARY KEY (id);


--
-- Name: bar_item_shot_snapshots bar_item_shot_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bar_item_shot_snapshots
    ADD CONSTRAINT bar_item_shot_snapshots_pkey PRIMARY KEY (id);


--
-- Name: bars bars_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bars
    ADD CONSTRAINT bars_pkey PRIMARY KEY (id);


--
-- Name: business_profile business_profile_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_profile
    ADD CONSTRAINT business_profile_pkey PRIMARY KEY (id);


--
-- Name: events events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_pkey PRIMARY KEY (id);


--
-- Name: guest_bookings guest_bookings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_bookings
    ADD CONSTRAINT guest_bookings_pkey PRIMARY KEY (id);


--
-- Name: guestlist guestlist_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guestlist
    ADD CONSTRAINT guestlist_pkey PRIMARY KEY (id);


--
-- Name: guests guests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guests
    ADD CONSTRAINT guests_pkey PRIMARY KEY (id);


--
-- Name: invoices invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_pkey PRIMARY KEY (id);


--
-- Name: items items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.items
    ADD CONSTRAINT items_pkey PRIMARY KEY (id);


--
-- Name: loyalty_config loyalty_config_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loyalty_config
    ADD CONSTRAINT loyalty_config_pkey PRIMARY KEY (id);


--
-- Name: loyalty_points loyalty_points_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loyalty_points
    ADD CONSTRAINT loyalty_points_pkey PRIMARY KEY (id);


--
-- Name: menu_items menu_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.menu_items
    ADD CONSTRAINT menu_items_pkey PRIMARY KEY (id);


--
-- Name: menu_settings menu_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.menu_settings
    ADD CONSTRAINT menu_settings_pkey PRIMARY KEY (id);


--
-- Name: night_bars night_bars_night_id_bar_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.night_bars
    ADD CONSTRAINT night_bars_night_id_bar_id_key UNIQUE (night_id, bar_id);


--
-- Name: night_bars night_bars_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.night_bars
    ADD CONSTRAINT night_bars_pkey PRIMARY KEY (id);


--
-- Name: night_staff_assignments night_staff_assignments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.night_staff_assignments
    ADD CONSTRAINT night_staff_assignments_pkey PRIMARY KEY (id);


--
-- Name: nights nights_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.nights
    ADD CONSTRAINT nights_pkey PRIMARY KEY (id);


--
-- Name: night_staff_assignments nsa_code_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.night_staff_assignments
    ADD CONSTRAINT nsa_code_unique UNIQUE (access_code);


--
-- Name: night_staff_assignments nsa_one_per_role; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.night_staff_assignments
    ADD CONSTRAINT nsa_one_per_role UNIQUE (night_id, staff_id, role);


--
-- Name: opening_par_items opening_par_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_par_items
    ADD CONSTRAINT opening_par_items_pkey PRIMARY KEY (id);


--
-- Name: opening_par_items opening_par_items_profile_id_bar_id_item_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_par_items
    ADD CONSTRAINT opening_par_items_profile_id_bar_id_item_id_key UNIQUE (profile_id, bar_id, item_id);


--
-- Name: opening_par_profiles opening_par_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_par_profiles
    ADD CONSTRAINT opening_par_profiles_pkey PRIMARY KEY (id);


--
-- Name: opening_par_profiles opening_par_profiles_venue_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_par_profiles
    ADD CONSTRAINT opening_par_profiles_venue_id_name_key UNIQUE (venue_id, name);


--
-- Name: opening_run_items opening_run_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_run_items
    ADD CONSTRAINT opening_run_items_pkey PRIMARY KEY (id);


--
-- Name: opening_run_items opening_run_items_run_id_item_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_run_items
    ADD CONSTRAINT opening_run_items_run_id_item_id_key UNIQUE (run_id, item_id);


--
-- Name: opening_runs opening_runs_night_id_bar_id_profile_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_runs
    ADD CONSTRAINT opening_runs_night_id_bar_id_profile_id_key UNIQUE (night_id, bar_id, profile_id);


--
-- Name: opening_runs opening_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_runs
    ADD CONSTRAINT opening_runs_pkey PRIMARY KEY (id);


--
-- Name: placements placements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.placements
    ADD CONSTRAINT placements_pkey PRIMARY KEY (id);


--
-- Name: po_items po_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.po_items
    ADD CONSTRAINT po_items_pkey PRIMARY KEY (id);


--
-- Name: pos_bar_mappings pos_bar_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_bar_mappings
    ADD CONSTRAINT pos_bar_mappings_pkey PRIMARY KEY (id);


--
-- Name: pos_bar_product_snapshots pos_bar_product_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_bar_product_snapshots
    ADD CONSTRAINT pos_bar_product_snapshots_pkey PRIMARY KEY (id);


--
-- Name: pos_bar_snapshots pos_bar_snapshots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_bar_snapshots
    ADD CONSTRAINT pos_bar_snapshots_pkey PRIMARY KEY (id);


--
-- Name: pos_connections pos_connections_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_connections
    ADD CONSTRAINT pos_connections_pkey PRIMARY KEY (id);


--
-- Name: pos_credentials pos_credentials_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_credentials
    ADD CONSTRAINT pos_credentials_pkey PRIMARY KEY (venue_id);


--
-- Name: pos_product_item_mappings pos_product_item_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_product_item_mappings
    ADD CONSTRAINT pos_product_item_mappings_pkey PRIMARY KEY (id);


--
-- Name: pos_source_map pos_source_map_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_source_map
    ADD CONSTRAINT pos_source_map_pkey PRIMARY KEY (id);


--
-- Name: pos_sync_runs pos_sync_runs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_sync_runs
    ADD CONSTRAINT pos_sync_runs_pkey PRIMARY KEY (id);


--
-- Name: pos_transactions pos_transactions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_transactions
    ADD CONSTRAINT pos_transactions_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: purchase_orders purchase_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_pkey PRIMARY KEY (id);


--
-- Name: receipt_items receipt_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipt_items
    ADD CONSTRAINT receipt_items_pkey PRIMARY KEY (id);


--
-- Name: receipts receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipts
    ADD CONSTRAINT receipts_pkey PRIMARY KEY (id);


--
-- Name: recipe_ingredients recipe_ingredients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_ingredients
    ADD CONSTRAINT recipe_ingredients_pkey PRIMARY KEY (id);


--
-- Name: recipes recipes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipes
    ADD CONSTRAINT recipes_pkey PRIMARY KEY (id);


--
-- Name: staff staff_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT staff_pkey PRIMARY KEY (id);


--
-- Name: stations stations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stations
    ADD CONSTRAINT stations_pkey PRIMARY KEY (id);


--
-- Name: suppliers suppliers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_pkey PRIMARY KEY (id);


--
-- Name: venue_members venue_members_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venue_members
    ADD CONSTRAINT venue_members_pkey PRIMARY KEY (user_id, venue_id);


--
-- Name: venues venues_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venues
    ADD CONSTRAINT venues_pkey PRIMARY KEY (id);


--
-- Name: vip_tables vip_tables_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vip_tables
    ADD CONSTRAINT vip_tables_pkey PRIMARY KEY (id);


--
-- Name: warehouse_items warehouse_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouse_items
    ADD CONSTRAINT warehouse_items_pkey PRIMARY KEY (id);


--
-- Name: warehouse_transfers warehouse_transfers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouse_transfers
    ADD CONSTRAINT warehouse_transfers_pkey PRIMARY KEY (id);


--
-- Name: bar_close_summaries_bar_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bar_close_summaries_bar_id_idx ON public.bar_close_summaries USING btree (bar_id);


--
-- Name: bar_close_summaries_connection_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bar_close_summaries_connection_id_idx ON public.bar_close_summaries USING btree (connection_id);


--
-- Name: bar_close_summaries_night_id_bar_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bar_close_summaries_night_id_bar_id_key ON public.bar_close_summaries USING btree (night_id, bar_id);


--
-- Name: bar_close_summaries_night_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bar_close_summaries_night_id_idx ON public.bar_close_summaries USING btree (night_id);


--
-- Name: bar_item_dispatch_snapshots_bar_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bar_item_dispatch_snapshots_bar_id_idx ON public.bar_item_dispatch_snapshots USING btree (bar_id);


--
-- Name: bar_item_dispatch_snapshots_connection_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bar_item_dispatch_snapshots_connection_id_idx ON public.bar_item_dispatch_snapshots USING btree (connection_id);


--
-- Name: bar_item_dispatch_snapshots_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bar_item_dispatch_snapshots_item_id_idx ON public.bar_item_dispatch_snapshots USING btree (item_id);


--
-- Name: bar_item_shot_snapshots_bar_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bar_item_shot_snapshots_bar_id_idx ON public.bar_item_shot_snapshots USING btree (bar_id);


--
-- Name: bar_item_shot_snapshots_connection_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bar_item_shot_snapshots_connection_id_idx ON public.bar_item_shot_snapshots USING btree (connection_id);


--
-- Name: bar_item_shot_snapshots_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX bar_item_shot_snapshots_item_id_idx ON public.bar_item_shot_snapshots USING btree (item_id);


--
-- Name: bars_name_venue_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX bars_name_venue_unique ON public.bars USING btree (name, venue_id);


--
-- Name: guest_bookings_night_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX guest_bookings_night_id_idx ON public.guest_bookings USING btree (night_id);


--
-- Name: guestlist_night_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX guestlist_night_id_idx ON public.guestlist USING btree (night_id);


--
-- Name: idx_bar_close_summaries_bar; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bar_close_summaries_bar ON public.bar_close_summaries USING btree (bar_id);


--
-- Name: idx_bar_close_summaries_night; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bar_close_summaries_night ON public.bar_close_summaries USING btree (night_id);


--
-- Name: idx_bars_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bars_venue ON public.bars USING btree (venue_id);


--
-- Name: idx_bks_trigger; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bks_trigger ON public.backup_snapshots USING btree (trigger_source);


--
-- Name: idx_bks_venue_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_bks_venue_time ON public.backup_snapshots USING btree (venue_id, created_at DESC);


--
-- Name: idx_events_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_created ON public.events USING btree (created_at DESC);


--
-- Name: idx_events_giveaway; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_giveaway ON public.events USING btree (venue_id, night_id, action) WHERE (action = ANY (ARRAY['COMP'::text, 'SHOT'::text, 'PROMO'::text, 'WASTE'::text, 'BREAKAGE'::text]));


--
-- Name: idx_events_night; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_night ON public.events USING btree (night_id);


--
-- Name: idx_events_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_status ON public.events USING btree (status);


--
-- Name: idx_events_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_events_venue ON public.events USING btree (venue_id);


--
-- Name: idx_guest_bookings_guest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_guest_bookings_guest ON public.guest_bookings USING btree (guest_id);


--
-- Name: idx_guest_bookings_night; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_guest_bookings_night ON public.guest_bookings USING btree (night_id);


--
-- Name: idx_guest_bookings_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_guest_bookings_venue ON public.guest_bookings USING btree (venue_id);


--
-- Name: idx_guestlist_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_guestlist_venue ON public.guestlist USING btree (venue_id);


--
-- Name: idx_guests_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_guests_name ON public.guests USING btree (name);


--
-- Name: idx_guests_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_guests_venue ON public.guests USING btree (venue_id);


--
-- Name: idx_invoices_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_invoices_venue ON public.invoices USING btree (venue_id);


--
-- Name: idx_items_bottle_size_ml; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_items_bottle_size_ml ON public.items USING btree (bottle_size_ml);


--
-- Name: idx_items_measurement_mode; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_items_measurement_mode ON public.items USING btree (measurement_mode);


--
-- Name: idx_items_service_mode; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_items_service_mode ON public.items USING btree (service_mode);


--
-- Name: idx_items_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_items_venue ON public.items USING btree (venue_id);


--
-- Name: idx_loyalty_points_guest; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_loyalty_points_guest ON public.loyalty_points USING btree (guest_id);


--
-- Name: idx_loyalty_points_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_loyalty_points_venue ON public.loyalty_points USING btree (venue_id);


--
-- Name: idx_menu_items_item; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_menu_items_item ON public.menu_items USING btree (item_id);


--
-- Name: idx_menu_items_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_menu_items_venue ON public.menu_items USING btree (venue_id);


--
-- Name: idx_nights_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_nights_venue ON public.nights USING btree (venue_id);


--
-- Name: idx_nsa_code_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_nsa_code_active ON public.night_staff_assignments USING btree (access_code) WHERE (NOT revoked);


--
-- Name: idx_nsa_night; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_nsa_night ON public.night_staff_assignments USING btree (night_id);


--
-- Name: idx_nsa_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_nsa_venue ON public.night_staff_assignments USING btree (venue_id);


--
-- Name: idx_placements_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_placements_venue ON public.placements USING btree (venue_id);


--
-- Name: idx_po_items_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_po_items_venue ON public.po_items USING btree (venue_id);


--
-- Name: idx_pos_bar_mappings_bar; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pos_bar_mappings_bar ON public.pos_bar_mappings USING btree (bar_id);


--
-- Name: idx_pos_bar_mappings_conn; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pos_bar_mappings_conn ON public.pos_bar_mappings USING btree (connection_id);


--
-- Name: idx_pos_bar_product_bar_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pos_bar_product_bar_time ON public.pos_bar_product_snapshots USING btree (bar_id, snapshot_ts);


--
-- Name: idx_pos_bar_product_prod; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pos_bar_product_prod ON public.pos_bar_product_snapshots USING btree (product_key);


--
-- Name: idx_pos_bar_product_snapshots_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pos_bar_product_snapshots_venue ON public.pos_bar_product_snapshots USING btree (venue_id);


--
-- Name: idx_pos_bar_snapshots_bar_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pos_bar_snapshots_bar_time ON public.pos_bar_snapshots USING btree (bar_id, snapshot_ts);


--
-- Name: idx_pos_bar_snapshots_conn_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pos_bar_snapshots_conn_time ON public.pos_bar_snapshots USING btree (connection_id, snapshot_ts);


--
-- Name: idx_pos_bar_snapshots_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pos_bar_snapshots_venue ON public.pos_bar_snapshots USING btree (venue_id);


--
-- Name: idx_pos_connections_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pos_connections_active ON public.pos_connections USING btree (is_active);


--
-- Name: idx_pos_sync_runs_conn; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pos_sync_runs_conn ON public.pos_sync_runs USING btree (connection_id);


--
-- Name: idx_pos_sync_runs_started; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pos_sync_runs_started ON public.pos_sync_runs USING btree (started_at);


--
-- Name: idx_purchase_orders_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_purchase_orders_venue ON public.purchase_orders USING btree (venue_id);


--
-- Name: idx_receipts_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_receipts_venue ON public.receipts USING btree (venue_id);


--
-- Name: idx_recipe_ingredients_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_recipe_ingredients_venue ON public.recipe_ingredients USING btree (venue_id);


--
-- Name: idx_staff_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_staff_venue ON public.staff USING btree (venue_id);


--
-- Name: idx_stations_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_stations_venue ON public.stations USING btree (venue_id);


--
-- Name: idx_suppliers_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_suppliers_venue ON public.suppliers USING btree (venue_id);


--
-- Name: idx_vip_tables_night_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vip_tables_night_id ON public.vip_tables USING btree (night_id);


--
-- Name: idx_vip_tables_table_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vip_tables_table_name ON public.vip_tables USING btree (table_name);


--
-- Name: idx_vip_tables_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_vip_tables_venue ON public.vip_tables USING btree (venue_id);


--
-- Name: idx_warehouse_transfers_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_warehouse_transfers_venue ON public.warehouse_transfers USING btree (venue_id);


--
-- Name: ix_bar_item_dispatch_snapshots_bar_ts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_bar_item_dispatch_snapshots_bar_ts ON public.bar_item_dispatch_snapshots USING btree (bar_id, snapshot_ts DESC);


--
-- Name: ix_bar_item_shot_snapshots_bar_ts; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_bar_item_shot_snapshots_bar_ts ON public.bar_item_shot_snapshots USING btree (bar_id, snapshot_ts DESC);


--
-- Name: night_bars_bar_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX night_bars_bar_idx ON public.night_bars USING btree (bar_id);


--
-- Name: night_bars_night_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX night_bars_night_idx ON public.night_bars USING btree (night_id);


--
-- Name: nights_code_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX nights_code_key ON public.nights USING btree (code);


--
-- Name: opening_par_items_profile_bar_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX opening_par_items_profile_bar_idx ON public.opening_par_items USING btree (profile_id, bar_id);


--
-- Name: opening_par_profiles_one_active_default_per_venue; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX opening_par_profiles_one_active_default_per_venue ON public.opening_par_profiles USING btree (venue_id) WHERE ((is_default = true) AND (active = true));


--
-- Name: opening_run_items_run_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX opening_run_items_run_idx ON public.opening_run_items USING btree (run_id);


--
-- Name: opening_runs_night_bar_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX opening_runs_night_bar_idx ON public.opening_runs USING btree (night_id, bar_id);


--
-- Name: opening_runs_venue_night_status_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX opening_runs_venue_night_status_idx ON public.opening_runs USING btree (venue_id, night_id, status);


--
-- Name: pos_bar_mappings_bar_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pos_bar_mappings_bar_id_idx ON public.pos_bar_mappings USING btree (bar_id);


--
-- Name: pos_bar_mappings_connection_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pos_bar_mappings_connection_id_idx ON public.pos_bar_mappings USING btree (connection_id);


--
-- Name: pos_bar_mappings_connection_id_pos_location_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pos_bar_mappings_connection_id_pos_location_id_key ON public.pos_bar_mappings USING btree (connection_id, pos_location_id);


--
-- Name: pos_bar_product_snapshots_bar_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pos_bar_product_snapshots_bar_id_idx ON public.pos_bar_product_snapshots USING btree (bar_id);


--
-- Name: pos_bar_product_snapshots_connection_id_bar_id_snapshot_ts__key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pos_bar_product_snapshots_connection_id_bar_id_snapshot_ts__key ON public.pos_bar_product_snapshots USING btree (connection_id, bar_id, snapshot_ts, bucket_minutes, product_key);


--
-- Name: pos_bar_product_snapshots_connection_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pos_bar_product_snapshots_connection_id_idx ON public.pos_bar_product_snapshots USING btree (connection_id);


--
-- Name: pos_bar_snapshots_bar_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pos_bar_snapshots_bar_id_idx ON public.pos_bar_snapshots USING btree (bar_id);


--
-- Name: pos_bar_snapshots_connection_id_bar_id_snapshot_ts_bucket_m_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pos_bar_snapshots_connection_id_bar_id_snapshot_ts_bucket_m_key ON public.pos_bar_snapshots USING btree (connection_id, bar_id, snapshot_ts, bucket_minutes);


--
-- Name: pos_bar_snapshots_connection_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pos_bar_snapshots_connection_id_idx ON public.pos_bar_snapshots USING btree (connection_id);


--
-- Name: pos_product_item_mappings_connection_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pos_product_item_mappings_connection_id_idx ON public.pos_product_item_mappings USING btree (connection_id);


--
-- Name: pos_sync_runs_connection_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX pos_sync_runs_connection_id_idx ON public.pos_sync_runs USING btree (connection_id);


--
-- Name: pos_transactions_square_payment_id_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX pos_transactions_square_payment_id_key ON public.pos_transactions USING btree (square_payment_id);


--
-- Name: profiles_username_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX profiles_username_key ON public.profiles USING btree (username);


--
-- Name: stations_bar_id_name_key; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX stations_bar_id_name_key ON public.stations USING btree (bar_id, name);


--
-- Name: ux_bar_item_shot_snapshots_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_bar_item_shot_snapshots_unique ON public.bar_item_shot_snapshots USING btree (connection_id, bar_id, item_id, snapshot_ts, bucket_minutes);


--
-- Name: ux_pos_product_item_mappings_unique; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_pos_product_item_mappings_unique ON public.pos_product_item_mappings USING btree (connection_id, product_key, inventory_item_id);


--
-- Name: venue_members_user_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX venue_members_user_idx ON public.venue_members USING btree (user_id);


--
-- Name: venue_members_venue_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX venue_members_venue_idx ON public.venue_members USING btree (venue_id);


--
-- Name: vip_tables_night_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vip_tables_night_id_idx ON public.vip_tables USING btree (night_id);


--
-- Name: warehouse_transfers_item_id_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX warehouse_transfers_item_id_idx ON public.warehouse_transfers USING btree (item_id);


--
-- Name: nights nights_snapshot_bars_ai; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER nights_snapshot_bars_ai AFTER INSERT ON public.nights FOR EACH ROW EXECUTE FUNCTION public.snapshot_night_bars_on_insert();


--
-- Name: night_staff_assignments nsa_set_code; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER nsa_set_code BEFORE INSERT ON public.night_staff_assignments FOR EACH ROW EXECUTE FUNCTION public._nsa_before_insert();


--
-- Name: night_staff_assignments nsa_touch_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER nsa_touch_updated BEFORE UPDATE ON public.night_staff_assignments FOR EACH ROW EXECUTE FUNCTION public._nsa_touch_updated_at();


--
-- Name: opening_par_items opening_par_items_set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER opening_par_items_set_updated_at BEFORE UPDATE ON public.opening_par_items FOR EACH ROW EXECUTE FUNCTION public.opening_par_items_touch_updated_at();


--
-- Name: pos_credentials pos_credentials_set_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER pos_credentials_set_updated_at BEFORE UPDATE ON public.pos_credentials FOR EACH ROW EXECUTE FUNCTION public.touch_pos_credentials_updated_at();


--
-- Name: venue_members venue_members_prevent_last_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER venue_members_prevent_last_owner BEFORE DELETE ON public.venue_members FOR EACH ROW EXECUTE FUNCTION public.prevent_last_owner_delete();


--
-- Name: venues venues_auto_grant_owner; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER venues_auto_grant_owner AFTER INSERT ON public.venues FOR EACH ROW EXECUTE FUNCTION public.grant_venue_creator_owner();


--
-- Name: backup_snapshots backup_snapshots_venue_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.backup_snapshots
    ADD CONSTRAINT backup_snapshots_venue_id_fkey FOREIGN KEY (venue_id) REFERENCES public.venues(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: bar_close_summaries bar_close_summaries_bar_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bar_close_summaries
    ADD CONSTRAINT bar_close_summaries_bar_id_fkey FOREIGN KEY (bar_id) REFERENCES public.bars(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: bar_close_summaries bar_close_summaries_connection_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bar_close_summaries
    ADD CONSTRAINT bar_close_summaries_connection_id_fkey FOREIGN KEY (connection_id) REFERENCES public.pos_connections(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: bar_close_summaries bar_close_summaries_night_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bar_close_summaries
    ADD CONSTRAINT bar_close_summaries_night_id_fkey FOREIGN KEY (night_id) REFERENCES public.nights(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: bar_item_dispatch_snapshots bar_item_dispatch_snapshots_bar_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bar_item_dispatch_snapshots
    ADD CONSTRAINT bar_item_dispatch_snapshots_bar_id_fkey FOREIGN KEY (bar_id) REFERENCES public.bars(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: bar_item_dispatch_snapshots bar_item_dispatch_snapshots_connection_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bar_item_dispatch_snapshots
    ADD CONSTRAINT bar_item_dispatch_snapshots_connection_id_fkey FOREIGN KEY (connection_id) REFERENCES public.pos_connections(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: bar_item_dispatch_snapshots bar_item_dispatch_snapshots_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bar_item_dispatch_snapshots
    ADD CONSTRAINT bar_item_dispatch_snapshots_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: bar_item_shot_snapshots bar_item_shot_snapshots_bar_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bar_item_shot_snapshots
    ADD CONSTRAINT bar_item_shot_snapshots_bar_id_fkey FOREIGN KEY (bar_id) REFERENCES public.bars(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: bar_item_shot_snapshots bar_item_shot_snapshots_connection_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bar_item_shot_snapshots
    ADD CONSTRAINT bar_item_shot_snapshots_connection_id_fkey FOREIGN KEY (connection_id) REFERENCES public.pos_connections(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: bar_item_shot_snapshots bar_item_shot_snapshots_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bar_item_shot_snapshots
    ADD CONSTRAINT bar_item_shot_snapshots_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: events events_bar_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_bar_id_fkey FOREIGN KEY (bar_id) REFERENCES public.bars(id) DEFERRABLE;


--
-- Name: events events_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(id) DEFERRABLE;


--
-- Name: events events_night_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_night_id_fkey FOREIGN KEY (night_id) REFERENCES public.nights(id) DEFERRABLE;


--
-- Name: events events_station_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.events
    ADD CONSTRAINT events_station_id_fkey FOREIGN KEY (station_id) REFERENCES public.stations(id) DEFERRABLE;


--
-- Name: guest_bookings guest_bookings_guest_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_bookings
    ADD CONSTRAINT guest_bookings_guest_id_fkey FOREIGN KEY (guest_id) REFERENCES public.guests(id) DEFERRABLE;


--
-- Name: guest_bookings guest_bookings_night_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_bookings
    ADD CONSTRAINT guest_bookings_night_id_fkey FOREIGN KEY (night_id) REFERENCES public.nights(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: guestlist guestlist_night_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guestlist
    ADD CONSTRAINT guestlist_night_id_fkey FOREIGN KEY (night_id) REFERENCES public.nights(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: invoices invoices_po_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_po_id_fkey FOREIGN KEY (po_id) REFERENCES public.purchase_orders(id) DEFERRABLE;


--
-- Name: invoices invoices_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) DEFERRABLE;


--
-- Name: loyalty_points loyalty_points_guest_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.loyalty_points
    ADD CONSTRAINT loyalty_points_guest_id_fkey FOREIGN KEY (guest_id) REFERENCES public.guests(id) DEFERRABLE;


--
-- Name: menu_items menu_items_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.menu_items
    ADD CONSTRAINT menu_items_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(id) DEFERRABLE;


--
-- Name: night_bars night_bars_bar_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.night_bars
    ADD CONSTRAINT night_bars_bar_id_fkey FOREIGN KEY (bar_id) REFERENCES public.bars(id) ON DELETE RESTRICT;


--
-- Name: night_bars night_bars_night_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.night_bars
    ADD CONSTRAINT night_bars_night_id_fkey FOREIGN KEY (night_id) REFERENCES public.nights(id) ON DELETE CASCADE;


--
-- Name: night_staff_assignments night_staff_assignments_night_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.night_staff_assignments
    ADD CONSTRAINT night_staff_assignments_night_id_fkey FOREIGN KEY (night_id) REFERENCES public.nights(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: night_staff_assignments night_staff_assignments_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.night_staff_assignments
    ADD CONSTRAINT night_staff_assignments_staff_id_fkey FOREIGN KEY (staff_id) REFERENCES public.staff(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: night_staff_assignments night_staff_assignments_venue_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.night_staff_assignments
    ADD CONSTRAINT night_staff_assignments_venue_id_fkey FOREIGN KEY (venue_id) REFERENCES public.venues(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: opening_par_items opening_par_items_bar_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_par_items
    ADD CONSTRAINT opening_par_items_bar_id_fkey FOREIGN KEY (bar_id) REFERENCES public.bars(id) ON DELETE CASCADE;


--
-- Name: opening_par_items opening_par_items_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_par_items
    ADD CONSTRAINT opening_par_items_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(id) ON DELETE CASCADE;


--
-- Name: opening_par_items opening_par_items_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_par_items
    ADD CONSTRAINT opening_par_items_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES public.opening_par_profiles(id) ON DELETE CASCADE;


--
-- Name: opening_par_profiles opening_par_profiles_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_par_profiles
    ADD CONSTRAINT opening_par_profiles_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: opening_par_profiles opening_par_profiles_venue_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_par_profiles
    ADD CONSTRAINT opening_par_profiles_venue_id_fkey FOREIGN KEY (venue_id) REFERENCES public.venues(id) ON DELETE CASCADE;


--
-- Name: opening_run_items opening_run_items_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_run_items
    ADD CONSTRAINT opening_run_items_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(id) ON DELETE RESTRICT;


--
-- Name: opening_run_items opening_run_items_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_run_items
    ADD CONSTRAINT opening_run_items_run_id_fkey FOREIGN KEY (run_id) REFERENCES public.opening_runs(id) ON DELETE CASCADE;


--
-- Name: opening_runs opening_runs_bar_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_runs
    ADD CONSTRAINT opening_runs_bar_id_fkey FOREIGN KEY (bar_id) REFERENCES public.bars(id) ON DELETE RESTRICT;


--
-- Name: opening_runs opening_runs_cancelled_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_runs
    ADD CONSTRAINT opening_runs_cancelled_by_fkey FOREIGN KEY (cancelled_by) REFERENCES auth.users(id);


--
-- Name: opening_runs opening_runs_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_runs
    ADD CONSTRAINT opening_runs_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id);


--
-- Name: opening_runs opening_runs_issued_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_runs
    ADD CONSTRAINT opening_runs_issued_by_fkey FOREIGN KEY (issued_by) REFERENCES auth.users(id);


--
-- Name: opening_runs opening_runs_night_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_runs
    ADD CONSTRAINT opening_runs_night_id_fkey FOREIGN KEY (night_id) REFERENCES public.nights(id) ON DELETE CASCADE;


--
-- Name: opening_runs opening_runs_prepared_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_runs
    ADD CONSTRAINT opening_runs_prepared_by_fkey FOREIGN KEY (prepared_by) REFERENCES auth.users(id);


--
-- Name: opening_runs opening_runs_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_runs
    ADD CONSTRAINT opening_runs_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES public.opening_par_profiles(id) ON DELETE RESTRICT;


--
-- Name: opening_runs opening_runs_received_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_runs
    ADD CONSTRAINT opening_runs_received_by_fkey FOREIGN KEY (received_by) REFERENCES auth.users(id);


--
-- Name: opening_runs opening_runs_venue_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_runs
    ADD CONSTRAINT opening_runs_venue_id_fkey FOREIGN KEY (venue_id) REFERENCES public.venues(id) ON DELETE CASCADE;


--
-- Name: placements placements_barback_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.placements
    ADD CONSTRAINT placements_barback_id_fkey FOREIGN KEY (barback_id) REFERENCES public.staff(id) DEFERRABLE;


--
-- Name: placements placements_bartender_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.placements
    ADD CONSTRAINT placements_bartender_id_fkey FOREIGN KEY (bartender_id) REFERENCES public.staff(id) DEFERRABLE;


--
-- Name: placements placements_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.placements
    ADD CONSTRAINT placements_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(id) DEFERRABLE;


--
-- Name: placements placements_station_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.placements
    ADD CONSTRAINT placements_station_id_fkey FOREIGN KEY (station_id) REFERENCES public.stations(id) DEFERRABLE;


--
-- Name: po_items po_items_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.po_items
    ADD CONSTRAINT po_items_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(id) DEFERRABLE;


--
-- Name: po_items po_items_po_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.po_items
    ADD CONSTRAINT po_items_po_id_fkey FOREIGN KEY (po_id) REFERENCES public.purchase_orders(id) DEFERRABLE;


--
-- Name: pos_bar_mappings pos_bar_mappings_bar_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_bar_mappings
    ADD CONSTRAINT pos_bar_mappings_bar_id_fkey FOREIGN KEY (bar_id) REFERENCES public.bars(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: pos_bar_mappings pos_bar_mappings_connection_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_bar_mappings
    ADD CONSTRAINT pos_bar_mappings_connection_id_fkey FOREIGN KEY (connection_id) REFERENCES public.pos_connections(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: pos_bar_product_snapshots pos_bar_product_snapshots_bar_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_bar_product_snapshots
    ADD CONSTRAINT pos_bar_product_snapshots_bar_id_fkey FOREIGN KEY (bar_id) REFERENCES public.bars(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: pos_bar_product_snapshots pos_bar_product_snapshots_connection_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_bar_product_snapshots
    ADD CONSTRAINT pos_bar_product_snapshots_connection_id_fkey FOREIGN KEY (connection_id) REFERENCES public.pos_connections(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: pos_bar_snapshots pos_bar_snapshots_bar_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_bar_snapshots
    ADD CONSTRAINT pos_bar_snapshots_bar_id_fkey FOREIGN KEY (bar_id) REFERENCES public.bars(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: pos_bar_snapshots pos_bar_snapshots_connection_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_bar_snapshots
    ADD CONSTRAINT pos_bar_snapshots_connection_id_fkey FOREIGN KEY (connection_id) REFERENCES public.pos_connections(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: pos_credentials pos_credentials_venue_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_credentials
    ADD CONSTRAINT pos_credentials_venue_id_fkey FOREIGN KEY (venue_id) REFERENCES public.venues(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: pos_product_item_mappings pos_product_item_mappings_connection_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_product_item_mappings
    ADD CONSTRAINT pos_product_item_mappings_connection_id_fkey FOREIGN KEY (connection_id) REFERENCES public.pos_connections(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: pos_sync_runs pos_sync_runs_connection_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pos_sync_runs
    ADD CONSTRAINT pos_sync_runs_connection_id_fkey FOREIGN KEY (connection_id) REFERENCES public.pos_connections(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: profiles profiles_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.profiles
    ADD CONSTRAINT profiles_id_fkey FOREIGN KEY (id) REFERENCES auth.users(id);


--
-- Name: purchase_orders purchase_orders_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) DEFERRABLE;


--
-- Name: receipt_items receipt_items_receipt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.receipt_items
    ADD CONSTRAINT receipt_items_receipt_id_fkey FOREIGN KEY (receipt_id) REFERENCES public.receipts(id) DEFERRABLE;


--
-- Name: recipe_ingredients recipe_ingredients_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_ingredients
    ADD CONSTRAINT recipe_ingredients_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.items(id) DEFERRABLE;


--
-- Name: recipe_ingredients recipe_ingredients_recipe_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipe_ingredients
    ADD CONSTRAINT recipe_ingredients_recipe_id_fkey FOREIGN KEY (recipe_id) REFERENCES public.recipes(id) DEFERRABLE;


--
-- Name: stations stations_bar_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stations
    ADD CONSTRAINT stations_bar_id_fkey FOREIGN KEY (bar_id) REFERENCES public.bars(id) DEFERRABLE;


--
-- Name: venue_members venue_members_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venue_members
    ADD CONSTRAINT venue_members_created_by_fkey FOREIGN KEY (created_by) REFERENCES auth.users(id) DEFERRABLE;


--
-- Name: venue_members venue_members_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venue_members
    ADD CONSTRAINT venue_members_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: venue_members venue_members_venue_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.venue_members
    ADD CONSTRAINT venue_members_venue_id_fkey FOREIGN KEY (venue_id) REFERENCES public.venues(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: vip_tables vip_tables_night_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vip_tables
    ADD CONSTRAINT vip_tables_night_id_fkey FOREIGN KEY (night_id) REFERENCES public.nights(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: warehouse_transfers warehouse_transfers_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouse_transfers
    ADD CONSTRAINT warehouse_transfers_item_id_fkey FOREIGN KEY (item_id) REFERENCES public.warehouse_items(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: backup_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.backup_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: bar_close_summaries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.bar_close_summaries ENABLE ROW LEVEL SECURITY;

--
-- Name: bar_close_summaries bar_close_summaries_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bar_close_summaries_delete_v ON public.bar_close_summaries FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: bar_close_summaries bar_close_summaries_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bar_close_summaries_insert_v ON public.bar_close_summaries FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: bar_close_summaries bar_close_summaries_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bar_close_summaries_select_v ON public.bar_close_summaries FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: bar_close_summaries bar_close_summaries_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bar_close_summaries_staff_select ON public.bar_close_summaries FOR SELECT TO authenticated USING ((public.auth_is_scoped_staff() AND (bar_id = ANY (public.auth_scoped_bar_ids()))));


--
-- Name: bar_close_summaries bar_close_summaries_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bar_close_summaries_update_v ON public.bar_close_summaries FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: bar_item_dispatch_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.bar_item_dispatch_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: bar_item_dispatch_snapshots bar_item_dispatch_snapshots_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bar_item_dispatch_snapshots_delete_v ON public.bar_item_dispatch_snapshots FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: bar_item_dispatch_snapshots bar_item_dispatch_snapshots_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bar_item_dispatch_snapshots_insert_v ON public.bar_item_dispatch_snapshots FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: bar_item_dispatch_snapshots bar_item_dispatch_snapshots_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bar_item_dispatch_snapshots_select_v ON public.bar_item_dispatch_snapshots FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: bar_item_dispatch_snapshots bar_item_dispatch_snapshots_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bar_item_dispatch_snapshots_update_v ON public.bar_item_dispatch_snapshots FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: bar_item_shot_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.bar_item_shot_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: bar_item_shot_snapshots bar_item_shot_snapshots_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bar_item_shot_snapshots_delete_v ON public.bar_item_shot_snapshots FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: bar_item_shot_snapshots bar_item_shot_snapshots_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bar_item_shot_snapshots_insert_v ON public.bar_item_shot_snapshots FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: bar_item_shot_snapshots bar_item_shot_snapshots_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bar_item_shot_snapshots_select_v ON public.bar_item_shot_snapshots FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: bar_item_shot_snapshots bar_item_shot_snapshots_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bar_item_shot_snapshots_update_v ON public.bar_item_shot_snapshots FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: bars; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.bars ENABLE ROW LEVEL SECURITY;

--
-- Name: bars bars_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bars_delete_v ON public.bars FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: bars bars_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bars_insert_v ON public.bars FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: bars bars_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bars_select_v ON public.bars FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: bars bars_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bars_staff_select ON public.bars FOR SELECT TO authenticated USING ((public.auth_is_scoped_staff() AND (venue_id = public.auth_scoped_venue()) AND (id = ANY (public.auth_scoped_bar_ids()))));


--
-- Name: bars bars_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bars_update_v ON public.bars FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text)) WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: bar_item_dispatch_snapshots bids_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bids_staff_select ON public.bar_item_dispatch_snapshots FOR SELECT TO authenticated USING ((public.auth_is_scoped_staff() AND (bar_id = ANY (public.auth_scoped_bar_ids()))));


--
-- Name: bar_item_shot_snapshots biss_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY biss_staff_select ON public.bar_item_shot_snapshots FOR SELECT TO authenticated USING ((public.auth_is_scoped_staff() AND (bar_id = ANY (public.auth_scoped_bar_ids()))));


--
-- Name: backup_snapshots bks_admin_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY bks_admin_all ON public.backup_snapshots TO authenticated USING (public.has_venue_access(venue_id, 'admin'::text)) WITH CHECK (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: business_profile; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.business_profile ENABLE ROW LEVEL SECURITY;

--
-- Name: business_profile business_profile_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY business_profile_delete_v ON public.business_profile FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: business_profile business_profile_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY business_profile_insert_v ON public.business_profile FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: business_profile business_profile_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY business_profile_select_v ON public.business_profile FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: business_profile business_profile_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY business_profile_update_v ON public.business_profile FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'admin'::text)) WITH CHECK (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: events; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;

--
-- Name: events events_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY events_delete_v ON public.events FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: events events_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY events_insert_v ON public.events FOR INSERT TO authenticated WITH CHECK ((public.has_venue_access(venue_id, 'staff'::text) AND ((action <> ALL (ARRAY['COMP'::text, 'SHOT'::text, 'PROMO'::text, 'WASTE'::text, 'BREAKAGE'::text])) OR public.has_venue_access(venue_id, 'manager'::text))));


--
-- Name: events events_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY events_select_v ON public.events FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: events events_staff_insert; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY events_staff_insert ON public.events FOR INSERT TO authenticated WITH CHECK ((public.auth_is_scoped_staff() AND (venue_id = public.auth_scoped_venue()) AND (night_id = public.auth_scoped_night()) AND (bar_id = ANY (public.auth_scoped_bar_ids())) AND (action <> ALL (ARRAY['COMP'::text, 'SHOT'::text, 'PROMO'::text, 'WASTE'::text, 'BREAKAGE'::text]))));


--
-- Name: events events_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY events_staff_select ON public.events FOR SELECT TO authenticated USING ((public.auth_is_scoped_staff() AND (venue_id = public.auth_scoped_venue()) AND (night_id = public.auth_scoped_night()) AND (bar_id = ANY (public.auth_scoped_bar_ids()))));


--
-- Name: events events_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY events_update_v ON public.events FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: guest_bookings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.guest_bookings ENABLE ROW LEVEL SECURITY;

--
-- Name: guest_bookings guest_bookings_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guest_bookings_delete_v ON public.guest_bookings FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: guest_bookings guest_bookings_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guest_bookings_insert_v ON public.guest_bookings FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: guest_bookings guest_bookings_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guest_bookings_select_v ON public.guest_bookings FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: guest_bookings guest_bookings_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guest_bookings_update_v ON public.guest_bookings FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: guestlist; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.guestlist ENABLE ROW LEVEL SECURITY;

--
-- Name: guestlist guestlist_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guestlist_delete_v ON public.guestlist FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: guestlist guestlist_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guestlist_insert_v ON public.guestlist FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: guestlist guestlist_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guestlist_select_v ON public.guestlist FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: guestlist guestlist_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guestlist_update_v ON public.guestlist FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: guests; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.guests ENABLE ROW LEVEL SECURITY;

--
-- Name: guests guests_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guests_delete_v ON public.guests FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: guests guests_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guests_insert_v ON public.guests FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: guests guests_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guests_select_v ON public.guests FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: guests guests_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY guests_update_v ON public.guests FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: invoices; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;

--
-- Name: invoices invoices_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY invoices_delete_v ON public.invoices FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: invoices invoices_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY invoices_insert_v ON public.invoices FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: invoices invoices_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY invoices_select_v ON public.invoices FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: invoices invoices_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY invoices_update_v ON public.invoices FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text)) WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.items ENABLE ROW LEVEL SECURITY;

--
-- Name: items items_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY items_delete_v ON public.items FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: items items_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY items_insert_v ON public.items FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: items items_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY items_select_v ON public.items FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: items items_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY items_staff_select ON public.items FOR SELECT TO authenticated USING ((public.auth_is_scoped_staff() AND (venue_id = public.auth_scoped_venue())));


--
-- Name: items items_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY items_update_v ON public.items FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text)) WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: loyalty_config; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.loyalty_config ENABLE ROW LEVEL SECURITY;

--
-- Name: loyalty_config loyalty_config_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY loyalty_config_delete_v ON public.loyalty_config FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: loyalty_config loyalty_config_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY loyalty_config_insert_v ON public.loyalty_config FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: loyalty_config loyalty_config_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY loyalty_config_select_v ON public.loyalty_config FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: loyalty_config loyalty_config_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY loyalty_config_update_v ON public.loyalty_config FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'admin'::text)) WITH CHECK (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: loyalty_points; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.loyalty_points ENABLE ROW LEVEL SECURITY;

--
-- Name: loyalty_points loyalty_points_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY loyalty_points_delete_v ON public.loyalty_points FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: loyalty_points loyalty_points_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY loyalty_points_insert_v ON public.loyalty_points FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: loyalty_points loyalty_points_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY loyalty_points_select_v ON public.loyalty_points FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: loyalty_points loyalty_points_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY loyalty_points_update_v ON public.loyalty_points FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: menu_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.menu_items ENABLE ROW LEVEL SECURITY;

--
-- Name: menu_items menu_items_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY menu_items_delete_v ON public.menu_items FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: menu_items menu_items_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY menu_items_insert_v ON public.menu_items FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: menu_items menu_items_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY menu_items_select_v ON public.menu_items FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: menu_items menu_items_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY menu_items_update_v ON public.menu_items FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text)) WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: menu_settings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.menu_settings ENABLE ROW LEVEL SECURITY;

--
-- Name: menu_settings menu_settings_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY menu_settings_delete_v ON public.menu_settings FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: menu_settings menu_settings_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY menu_settings_insert_v ON public.menu_settings FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: menu_settings menu_settings_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY menu_settings_select_v ON public.menu_settings FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: menu_settings menu_settings_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY menu_settings_update_v ON public.menu_settings FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text)) WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: night_bars; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.night_bars ENABLE ROW LEVEL SECURITY;

--
-- Name: night_bars night_bars_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY night_bars_delete_v ON public.night_bars FOR DELETE USING ((EXISTS ( SELECT 1
   FROM public.nights n
  WHERE ((n.id = night_bars.night_id) AND public.has_venue_access(n.venue_id, 'admin'::text)))));


--
-- Name: night_bars night_bars_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY night_bars_insert_v ON public.night_bars FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public.nights n
  WHERE ((n.id = night_bars.night_id) AND public.has_venue_access(n.venue_id, 'admin'::text)))));


--
-- Name: night_bars night_bars_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY night_bars_select_v ON public.night_bars FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.nights n
  WHERE ((n.id = night_bars.night_id) AND public.has_venue_access(n.venue_id, 'viewer'::text)))));


--
-- Name: night_staff_assignments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.night_staff_assignments ENABLE ROW LEVEL SECURITY;

--
-- Name: nights; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.nights ENABLE ROW LEVEL SECURITY;

--
-- Name: nights nights_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY nights_delete_v ON public.nights FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: nights nights_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY nights_insert_v ON public.nights FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: nights nights_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY nights_select_v ON public.nights FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: nights nights_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY nights_staff_select ON public.nights FOR SELECT TO authenticated USING ((public.auth_is_scoped_staff() AND (id = public.auth_scoped_night())));


--
-- Name: nights nights_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY nights_update_v ON public.nights FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: night_staff_assignments nsa_mgr_all; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY nsa_mgr_all ON public.night_staff_assignments TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text)) WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: night_staff_assignments nsa_staff_self; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY nsa_staff_self ON public.night_staff_assignments FOR SELECT TO authenticated USING ((public.auth_is_scoped_staff() AND (id = public.auth_scoped_assignment_id())));


--
-- Name: opening_par_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.opening_par_items ENABLE ROW LEVEL SECURITY;

--
-- Name: opening_par_items opening_par_items_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY opening_par_items_delete_v ON public.opening_par_items FOR DELETE USING ((EXISTS ( SELECT 1
   FROM public.opening_par_profiles p
  WHERE ((p.id = opening_par_items.profile_id) AND public.has_venue_access(p.venue_id, 'manager'::text)))));


--
-- Name: opening_par_items opening_par_items_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY opening_par_items_insert_v ON public.opening_par_items FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public.opening_par_profiles p
  WHERE ((p.id = opening_par_items.profile_id) AND public.has_venue_access(p.venue_id, 'manager'::text)))));


--
-- Name: opening_par_items opening_par_items_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY opening_par_items_select_v ON public.opening_par_items FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.opening_par_profiles p
  WHERE ((p.id = opening_par_items.profile_id) AND public.has_venue_access(p.venue_id, 'viewer'::text)))));


--
-- Name: opening_par_items opening_par_items_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY opening_par_items_update_v ON public.opening_par_items FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM public.opening_par_profiles p
  WHERE ((p.id = opening_par_items.profile_id) AND public.has_venue_access(p.venue_id, 'manager'::text)))));


--
-- Name: opening_par_profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.opening_par_profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: opening_par_profiles opening_par_profiles_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY opening_par_profiles_delete_v ON public.opening_par_profiles FOR DELETE USING (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: opening_par_profiles opening_par_profiles_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY opening_par_profiles_insert_v ON public.opening_par_profiles FOR INSERT WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: opening_par_profiles opening_par_profiles_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY opening_par_profiles_select_v ON public.opening_par_profiles FOR SELECT USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: opening_par_profiles opening_par_profiles_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY opening_par_profiles_update_v ON public.opening_par_profiles FOR UPDATE USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: opening_run_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.opening_run_items ENABLE ROW LEVEL SECURITY;

--
-- Name: opening_run_items opening_run_items_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY opening_run_items_insert_v ON public.opening_run_items FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM public.opening_runs r
  WHERE ((r.id = opening_run_items.run_id) AND public.has_venue_access(r.venue_id, 'admin'::text)))));


--
-- Name: opening_run_items opening_run_items_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY opening_run_items_select_v ON public.opening_run_items FOR SELECT USING ((EXISTS ( SELECT 1
   FROM public.opening_runs r
  WHERE ((r.id = opening_run_items.run_id) AND public.has_venue_access(r.venue_id, 'viewer'::text)))));


--
-- Name: opening_run_items opening_run_items_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY opening_run_items_update_v ON public.opening_run_items FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM public.opening_runs r
  WHERE ((r.id = opening_run_items.run_id) AND public.has_venue_access(r.venue_id, 'admin'::text)))));


--
-- Name: opening_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.opening_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: opening_runs opening_runs_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY opening_runs_insert_v ON public.opening_runs FOR INSERT WITH CHECK (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: opening_runs opening_runs_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY opening_runs_select_v ON public.opening_runs FOR SELECT USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: opening_runs opening_runs_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY opening_runs_update_v ON public.opening_runs FOR UPDATE USING (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: pos_bar_mappings pbm_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pbm_staff_select ON public.pos_bar_mappings FOR SELECT TO authenticated USING ((public.auth_is_scoped_staff() AND (bar_id = ANY (public.auth_scoped_bar_ids()))));


--
-- Name: pos_bar_product_snapshots pbps_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pbps_staff_select ON public.pos_bar_product_snapshots FOR SELECT TO authenticated USING ((public.auth_is_scoped_staff() AND (bar_id = ANY (public.auth_scoped_bar_ids()))));


--
-- Name: pos_bar_snapshots pbs_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pbs_staff_select ON public.pos_bar_snapshots FOR SELECT TO authenticated USING ((public.auth_is_scoped_staff() AND (bar_id = ANY (public.auth_scoped_bar_ids()))));


--
-- Name: placements; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.placements ENABLE ROW LEVEL SECURITY;

--
-- Name: placements placements_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY placements_delete_v ON public.placements FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: placements placements_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY placements_insert_v ON public.placements FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: placements placements_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY placements_select_v ON public.placements FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: placements placements_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY placements_staff_select ON public.placements FOR SELECT TO authenticated USING ((public.auth_is_scoped_staff() AND (venue_id = public.auth_scoped_venue()) AND (EXISTS ( SELECT 1
   FROM public.stations s
  WHERE ((s.id = placements.station_id) AND (s.bar_id = ANY (public.auth_scoped_bar_ids())))))));


--
-- Name: placements placements_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY placements_update_v ON public.placements FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: po_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.po_items ENABLE ROW LEVEL SECURITY;

--
-- Name: po_items po_items_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY po_items_delete_v ON public.po_items FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: po_items po_items_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY po_items_insert_v ON public.po_items FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: po_items po_items_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY po_items_select_v ON public.po_items FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: po_items po_items_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY po_items_update_v ON public.po_items FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text)) WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: pos_bar_mappings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pos_bar_mappings ENABLE ROW LEVEL SECURITY;

--
-- Name: pos_bar_mappings pos_bar_mappings_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_bar_mappings_delete_v ON public.pos_bar_mappings FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: pos_bar_mappings pos_bar_mappings_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_bar_mappings_insert_v ON public.pos_bar_mappings FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: pos_bar_mappings pos_bar_mappings_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_bar_mappings_select_v ON public.pos_bar_mappings FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: pos_bar_mappings pos_bar_mappings_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_bar_mappings_update_v ON public.pos_bar_mappings FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'admin'::text)) WITH CHECK (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: pos_bar_product_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pos_bar_product_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: pos_bar_product_snapshots pos_bar_product_snapshots_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_bar_product_snapshots_delete_v ON public.pos_bar_product_snapshots FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: pos_bar_product_snapshots pos_bar_product_snapshots_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_bar_product_snapshots_insert_v ON public.pos_bar_product_snapshots FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: pos_bar_product_snapshots pos_bar_product_snapshots_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_bar_product_snapshots_select_v ON public.pos_bar_product_snapshots FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: pos_bar_product_snapshots pos_bar_product_snapshots_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_bar_product_snapshots_update_v ON public.pos_bar_product_snapshots FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: pos_bar_snapshots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pos_bar_snapshots ENABLE ROW LEVEL SECURITY;

--
-- Name: pos_bar_snapshots pos_bar_snapshots_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_bar_snapshots_delete_v ON public.pos_bar_snapshots FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: pos_bar_snapshots pos_bar_snapshots_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_bar_snapshots_insert_v ON public.pos_bar_snapshots FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: pos_bar_snapshots pos_bar_snapshots_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_bar_snapshots_select_v ON public.pos_bar_snapshots FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: pos_bar_snapshots pos_bar_snapshots_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_bar_snapshots_update_v ON public.pos_bar_snapshots FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: pos_connections; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pos_connections ENABLE ROW LEVEL SECURITY;

--
-- Name: pos_connections pos_connections_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_connections_delete_v ON public.pos_connections FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: pos_connections pos_connections_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_connections_insert_v ON public.pos_connections FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: pos_connections pos_connections_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_connections_select_v ON public.pos_connections FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: pos_connections pos_connections_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_connections_update_v ON public.pos_connections FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'admin'::text)) WITH CHECK (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: pos_credentials; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pos_credentials ENABLE ROW LEVEL SECURITY;

--
-- Name: pos_credentials pos_credentials_deny_all_non_service; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_credentials_deny_all_non_service ON public.pos_credentials AS RESTRICTIVE TO authenticated, anon USING (false) WITH CHECK (false);


--
-- Name: pos_product_item_mappings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pos_product_item_mappings ENABLE ROW LEVEL SECURITY;

--
-- Name: pos_product_item_mappings pos_product_item_mappings_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_product_item_mappings_delete_v ON public.pos_product_item_mappings FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: pos_product_item_mappings pos_product_item_mappings_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_product_item_mappings_insert_v ON public.pos_product_item_mappings FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: pos_product_item_mappings pos_product_item_mappings_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_product_item_mappings_select_v ON public.pos_product_item_mappings FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: pos_product_item_mappings pos_product_item_mappings_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_product_item_mappings_update_v ON public.pos_product_item_mappings FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'admin'::text)) WITH CHECK (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: pos_source_map; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pos_source_map ENABLE ROW LEVEL SECURITY;

--
-- Name: pos_source_map pos_source_map_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_source_map_delete_v ON public.pos_source_map FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: pos_source_map pos_source_map_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_source_map_insert_v ON public.pos_source_map FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: pos_source_map pos_source_map_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_source_map_select_v ON public.pos_source_map FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: pos_source_map pos_source_map_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_source_map_update_v ON public.pos_source_map FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'admin'::text)) WITH CHECK (public.has_venue_access(venue_id, 'admin'::text));


--
-- Name: pos_sync_runs; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pos_sync_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: pos_sync_runs pos_sync_runs_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_sync_runs_delete_v ON public.pos_sync_runs FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: pos_sync_runs pos_sync_runs_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_sync_runs_insert_v ON public.pos_sync_runs FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: pos_sync_runs pos_sync_runs_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_sync_runs_select_v ON public.pos_sync_runs FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: pos_sync_runs pos_sync_runs_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_sync_runs_update_v ON public.pos_sync_runs FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: pos_transactions; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.pos_transactions ENABLE ROW LEVEL SECURITY;

--
-- Name: pos_transactions pos_transactions_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_transactions_delete_v ON public.pos_transactions FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: pos_transactions pos_transactions_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_transactions_insert_v ON public.pos_transactions FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: pos_transactions pos_transactions_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_transactions_select_v ON public.pos_transactions FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: pos_transactions pos_transactions_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY pos_transactions_update_v ON public.pos_transactions FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: profiles; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: profiles profiles_insert_self_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_insert_self_v ON public.profiles FOR INSERT TO authenticated WITH CHECK ((id = auth.uid()));


--
-- Name: profiles profiles_select_self_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_select_self_v ON public.profiles FOR SELECT TO authenticated USING ((id = auth.uid()));


--
-- Name: profiles profiles_update_self_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY profiles_update_self_v ON public.profiles FOR UPDATE TO authenticated USING ((id = auth.uid())) WITH CHECK ((id = auth.uid()));


--
-- Name: purchase_orders; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.purchase_orders ENABLE ROW LEVEL SECURITY;

--
-- Name: purchase_orders purchase_orders_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY purchase_orders_delete_v ON public.purchase_orders FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: purchase_orders purchase_orders_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY purchase_orders_insert_v ON public.purchase_orders FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: purchase_orders purchase_orders_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY purchase_orders_select_v ON public.purchase_orders FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: purchase_orders purchase_orders_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY purchase_orders_update_v ON public.purchase_orders FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text)) WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: receipt_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.receipt_items ENABLE ROW LEVEL SECURITY;

--
-- Name: receipt_items receipt_items_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY receipt_items_delete_v ON public.receipt_items FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: receipt_items receipt_items_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY receipt_items_insert_v ON public.receipt_items FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: receipt_items receipt_items_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY receipt_items_select_v ON public.receipt_items FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: receipt_items receipt_items_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY receipt_items_update_v ON public.receipt_items FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: receipts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.receipts ENABLE ROW LEVEL SECURITY;

--
-- Name: receipts receipts_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY receipts_delete_v ON public.receipts FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: receipts receipts_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY receipts_insert_v ON public.receipts FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: receipts receipts_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY receipts_select_v ON public.receipts FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: receipts receipts_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY receipts_update_v ON public.receipts FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: recipe_ingredients; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipe_ingredients ENABLE ROW LEVEL SECURITY;

--
-- Name: recipe_ingredients recipe_ingredients_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_ingredients_delete_v ON public.recipe_ingredients FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: recipe_ingredients recipe_ingredients_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_ingredients_insert_v ON public.recipe_ingredients FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: recipe_ingredients recipe_ingredients_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_ingredients_select_v ON public.recipe_ingredients FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: recipe_ingredients recipe_ingredients_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipe_ingredients_update_v ON public.recipe_ingredients FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text)) WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: recipes; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.recipes ENABLE ROW LEVEL SECURITY;

--
-- Name: recipes recipes_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipes_delete_v ON public.recipes FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: recipes recipes_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipes_insert_v ON public.recipes FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: recipes recipes_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipes_select_v ON public.recipes FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: recipes recipes_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY recipes_update_v ON public.recipes FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text)) WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: staff; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.staff ENABLE ROW LEVEL SECURITY;

--
-- Name: staff staff_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY staff_delete_v ON public.staff FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: staff staff_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY staff_insert_v ON public.staff FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: staff staff_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY staff_select_v ON public.staff FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: staff staff_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY staff_staff_select ON public.staff FOR SELECT TO authenticated USING ((public.auth_is_scoped_staff() AND (venue_id = public.auth_scoped_venue())));


--
-- Name: staff staff_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY staff_update_v ON public.staff FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text)) WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: stations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.stations ENABLE ROW LEVEL SECURITY;

--
-- Name: stations stations_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stations_delete_v ON public.stations FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: stations stations_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stations_insert_v ON public.stations FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: stations stations_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stations_select_v ON public.stations FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: stations stations_staff_select; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stations_staff_select ON public.stations FOR SELECT TO authenticated USING ((public.auth_is_scoped_staff() AND (venue_id = public.auth_scoped_venue()) AND (bar_id = ANY (public.auth_scoped_bar_ids()))));


--
-- Name: stations stations_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY stations_update_v ON public.stations FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text)) WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: suppliers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.suppliers ENABLE ROW LEVEL SECURITY;

--
-- Name: suppliers suppliers_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY suppliers_delete_v ON public.suppliers FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: suppliers suppliers_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY suppliers_insert_v ON public.suppliers FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: suppliers suppliers_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY suppliers_select_v ON public.suppliers FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: suppliers suppliers_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY suppliers_update_v ON public.suppliers FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text)) WITH CHECK (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: venue_members; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.venue_members ENABLE ROW LEVEL SECURITY;

--
-- Name: venues; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.venues ENABLE ROW LEVEL SECURITY;

--
-- Name: venues venues_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY venues_delete_v ON public.venues FOR DELETE TO authenticated USING (public.has_venue_access(id, 'owner'::text));


--
-- Name: venues venues_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY venues_insert_v ON public.venues FOR INSERT TO authenticated WITH CHECK ((auth.uid() IS NOT NULL));


--
-- Name: venues venues_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY venues_select_v ON public.venues FOR SELECT TO authenticated USING (public.has_venue_access(id, 'viewer'::text));


--
-- Name: venues venues_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY venues_update_v ON public.venues FOR UPDATE TO authenticated USING (public.has_venue_access(id, 'admin'::text)) WITH CHECK (public.has_venue_access(id, 'admin'::text));


--
-- Name: vip_tables; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.vip_tables ENABLE ROW LEVEL SECURITY;

--
-- Name: vip_tables vip_tables_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY vip_tables_delete_v ON public.vip_tables FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: vip_tables vip_tables_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY vip_tables_insert_v ON public.vip_tables FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: vip_tables vip_tables_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY vip_tables_select_v ON public.vip_tables FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: vip_tables vip_tables_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY vip_tables_update_v ON public.vip_tables FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: venue_members vm_delete_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY vm_delete_admin ON public.venue_members FOR DELETE TO authenticated USING ((public.has_venue_access(venue_id, 'admin'::text) AND ((role <> 'owner'::text) OR public.has_venue_access(venue_id, 'owner'::text))));


--
-- Name: venue_members vm_insert_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY vm_insert_admin ON public.venue_members FOR INSERT TO authenticated WITH CHECK ((public.has_venue_access(venue_id, 'admin'::text) AND ((role <> 'owner'::text) OR public.has_venue_access(venue_id, 'owner'::text))));


--
-- Name: venue_members vm_select_member; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY vm_select_member ON public.venue_members FOR SELECT TO authenticated USING (((user_id = auth.uid()) OR public.has_venue_access(venue_id, 'admin'::text)));


--
-- Name: venue_members vm_update_admin; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY vm_update_admin ON public.venue_members FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'admin'::text)) WITH CHECK ((public.has_venue_access(venue_id, 'admin'::text) AND ((role <> 'owner'::text) OR public.has_venue_access(venue_id, 'owner'::text))));


--
-- Name: warehouse_items; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.warehouse_items ENABLE ROW LEVEL SECURITY;

--
-- Name: warehouse_items warehouse_items_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY warehouse_items_delete_v ON public.warehouse_items FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: warehouse_items warehouse_items_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY warehouse_items_insert_v ON public.warehouse_items FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: warehouse_items warehouse_items_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY warehouse_items_select_v ON public.warehouse_items FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: warehouse_items warehouse_items_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY warehouse_items_update_v ON public.warehouse_items FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: warehouse_transfers; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.warehouse_transfers ENABLE ROW LEVEL SECURITY;

--
-- Name: warehouse_transfers warehouse_transfers_delete_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY warehouse_transfers_delete_v ON public.warehouse_transfers FOR DELETE TO authenticated USING (public.has_venue_access(venue_id, 'manager'::text));


--
-- Name: warehouse_transfers warehouse_transfers_insert_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY warehouse_transfers_insert_v ON public.warehouse_transfers FOR INSERT TO authenticated WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- Name: warehouse_transfers warehouse_transfers_select_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY warehouse_transfers_select_v ON public.warehouse_transfers FOR SELECT TO authenticated USING (public.has_venue_access(venue_id, 'viewer'::text));


--
-- Name: warehouse_transfers warehouse_transfers_update_v; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY warehouse_transfers_update_v ON public.warehouse_transfers FOR UPDATE TO authenticated USING (public.has_venue_access(venue_id, 'staff'::text)) WITH CHECK (public.has_venue_access(venue_id, 'staff'::text));


--
-- PostgreSQL database dump complete
--


