-- =============================================================================
-- 039  Inventory reconciliation: ignore dropship items and kits / bundles
-- -----------------------------------------------------------------------------
-- Ben (5 Nov 2026): ignore anything dropshipped and any kits or bundles.
--
--  * Dropship = the Shopify product is tagged "dropshipping" or "dropship"
--    (Compex, Toe Spacer, Timebirds ...). sync-shopify-stock reads those SKUs with
--    a second bulk query each pull -> shopify_dropship_skus (same run_at).
--  * Kits / bundles: Shopify doesn't flag them (Cin7/SkuVault build them) and the
--    WMS has no SkuVault/Cin7 key, so they are found by name/SKU pattern
--    (wms__recon_auto_kit): Bundle, Mystery Box, Pack (not backpack), Package,
--    " + ", 2+ PACK / 3PK / 10PK / 3PAK in the SKU or variant, SKU ending -PAIR.
--  * Anything else can be ignored (or un-ignored) by hand from the report:
--    recon_ignore (sku, mode ignore|include, reason, who, when). A manual choice
--    always wins over the automatic rules.
-- =============================================================================

create table if not exists shopify_dropship_skus (
  sku     text primary key,
  run_at  timestamptz not null
);
alter table shopify_dropship_skus enable row level security;

create table if not exists recon_ignore (
  sku         text primary key,
  mode        text not null check (mode in ('ignore','include','auto')),   -- auto = follow the rules again
  reason      text not null default 'kit' check (reason in ('kit','dropship','other')),
  note        text,
  set_by      uuid references staff(id),
  set_at      timestamptz not null default now()
);
alter table recon_ignore enable row level security;

-- ---------------------------------------------------------------------------
create or replace function wms_import_shopify_dropship(p_run_at timestamptz, p_skus text[])
returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into shopify_dropship_skus as d (sku, run_at)
  select distinct trim(s), p_run_at from unnest(coalesce(p_skus, '{}')) s where trim(coalesce(s, '')) <> ''
  on conflict (sku) do update set run_at = excluded.run_at;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function wms_import_shopify_dropship(timestamptz, text[]) from public, anon, authenticated;
grant execute on function wms_import_shopify_dropship(timestamptz, text[]) to service_role;

-- Kit / bundle by name, variant or SKU. The report only applies it to SKUs that
-- have never had stock in a bin location (real products such as "4 Pack Mini
-- Resistance Bands" or "Bundles App Component" socks sit in bins themselves).
create or replace function wms__recon_auto_kit(p_sku text, p_name text, p_variant text)
returns boolean language sql immutable as $$
  select coalesce(p_name, '') !~* 'component'
     and (coalesce(p_name, '') ~* '(bundle|mystery box|\mpack\M|\mpackages?\M| \+ )'
       or coalesce(p_variant, '') ~* '\m([2-9]|[1-9][0-9]+) ?-?(pack|pk|pak)\M'
       or coalesce(p_sku, '') ~* '([2-9]|[1-9][0-9])(pk|pak|pack)|-pair$|bundle')
$$;

-- ---------------------------------------------------------------------------
-- Ignore / stop ignoring a SKU (admin + supervisor)
--   p_mode ignore | include (check it even if a rule says ignore) | auto (back to the rules)
--   Rows are never removed: auto just records that the rules apply again.
-- ---------------------------------------------------------------------------
create or replace function wms_recon_set_ignore(p_sku text, p_mode text, p_reason text default 'kit', p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_sku text := trim(coalesce(p_sku, '')); v_mode text := lower(coalesce(p_mode, ''));
        v_reason text := lower(coalesce(nullif(p_reason, ''), 'kit'));
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then return jsonb_build_object('ok',false,'error','FORBIDDEN'); end if;
  if v_sku = '' then return jsonb_build_object('ok',false,'error','NO_SKU'); end if;
  if v_mode not in ('ignore','include','auto') then return jsonb_build_object('ok',false,'error','BAD_MODE'); end if;
  if v_reason not in ('kit','dropship','other') then v_reason := 'other'; end if;
  insert into recon_ignore(sku, mode, reason, note, set_by)
  values (v_sku, v_mode, v_reason, nullif(trim(coalesce(p_note, '')), ''), auth.uid())
  on conflict (sku) do update set mode = excluded.mode, reason = excluded.reason, note = excluded.note,
                                  set_by = excluded.set_by, set_at = now();
  return jsonb_build_object('ok',true,'sku',v_sku,'mode',v_mode,'reason',v_reason);
end $$;
revoke execute on function wms_recon_set_ignore(text, text, text, text) from public, anon;
grant execute on function wms_recon_set_ignore(text, text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- The report, now skipping dropship + kits/bundles.
--   p_show diff (default) | red | amber | green | all | ignored
-- ---------------------------------------------------------------------------
create or replace function wms_inventory_recon(p_show text default 'diff', p_search text default null, p_limit int default 3000)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_wh uuid := wms__main_warehouse(); v_state sync_state; v_cur jsonb; v_run timestamptz;
        q text := nullif(trim(coalesce(p_search, '')), ''); v_show text := lower(coalesce(nullif(p_show, ''), 'diff'));
        v_out jsonb;
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select * into v_state from sync_state where system = 'shopify_stock';
  v_cur := coalesce(nullif(v_state.cursor, '')::jsonb, '{}');
  v_run := (v_cur->>'run_at')::timestamptz;

  if v_run is null then
    return jsonb_build_object('generated_at', now(), 'pulled_at', null, 'pull', v_cur, 'last_error', v_state.last_error,
      'rows', '[]'::jsonb, 'shown', 0, 'total_rows', 0,
      'tiles', jsonb_build_object('green',0,'amber',0,'red',0,'over_units',0,'under_units',0,'checked',0,
                                  'ignored_dropship',0,'ignored_kit',0,'ignored_other',0));
  end if;

  with sh as (
    select s.sku, sum(s.on_hand)::int as on_hand, sum(s.committed)::int as committed, count(*)::int as items
      from shopify_stock s
     where s.run_at = v_run and s.tracked and s.sku <> ''
     group by s.sku
  ), bins_ as (
    select bi.product_id, sum(bi.qty_on_hand)::int as in_bins,
           jsonb_agg(jsonb_build_object('code', b.code, 'qty', bi.qty_on_hand, 'type', b.location_type)
                     order by bi.qty_on_hand desc, b.row_seq nulls last, b.code) as locs,
           (array_agg(b.code order by bi.qty_on_hand desc, b.row_seq nulls last, b.code))[1] as first_code
      from bin_inventory bi join bins b on b.id = bi.bin_id
     where b.warehouse_id = v_wh and bi.qty_on_hand > 0
     group by bi.product_id
  ), open_ as (
    select coalesce(ol.product_id, p.id) as product_id,
           sum(greatest(ol.qty_ordered - ol.qty_picked, 0))::int as to_pick,
           sum(ol.qty_picked)::int as picked,
           count(distinct o.id) filter (where ol.qty_ordered > ol.qty_picked)::int as orders
      from order_lines ol join orders o on o.id = ol.order_id
      left join products p on ol.product_id is null and p.sku = ol.sku
     where o.status not in ('shipped','cancelled') and coalesce(ol.product_id, p.id) is not null
     group by 1
  ), wms as (
    select coalesce(b.product_id, o.product_id) as product_id, coalesce(b.in_bins, 0) as in_bins, b.locs, b.first_code,
           coalesce(o.to_pick, 0) as to_pick, coalesce(o.picked, 0) as picked, coalesce(o.orders, 0) as orders
      from bins_ b full join open_ o on o.product_id = b.product_id
  ), joined as (
    select coalesce(p.sku, sh.sku) as sku, p.id as product_id, p.name, p.variant_title,
           sh.sku is not null as in_shopify, p.id is not null as in_wms,
           coalesce(sh.on_hand, 0) as sh_on_hand, coalesce(sh.committed, 0) as sh_committed,
           coalesce(sh.on_hand, 0) - coalesce(sh.committed, 0) as sh_free, coalesce(sh.items, 0) as sh_items,
           coalesce(w.in_bins, 0) as in_bins, coalesce(w.to_pick, 0) as to_pick, coalesce(w.picked, 0) as picked,
           coalesce(w.orders, 0) as orders, coalesce(w.in_bins, 0) - coalesce(w.to_pick, 0) as wms_free,
           coalesce(w.locs, '[]'::jsonb) as locs, w.first_code
      from sh
      full join (select w.*, p.sku from wms w join products p on p.id = w.product_id) w on w.sku = sh.sku
      left join products p on p.sku = coalesce(w.sku, sh.sku)
  ), rows_ as (
    select j.*, j.wms_free - j.sh_free as diff,
           case when not j.in_shopify and (j.in_bins <> 0 or j.to_pick <> 0) then 'red'
                when not j.in_wms and j.sh_free <> 0 then 'red'
                when j.wms_free = j.sh_free then 'green'
                when abs(j.wms_free - j.sh_free) <= 2 then 'amber'
                else 'red' end as level,
           case when not j.in_shopify then 'Not in Shopify (or not tracked at the TWL location)'
                when not j.in_wms then 'SKU not in the WMS'
                when j.in_bins = 0 and j.sh_free > 0 then 'No stock in any location'
                when j.sh_items > 1 then 'Shopify has this SKU on ' || j.sh_items || ' items'
                else null end as note,
           -- why it is skipped: a manual choice wins, then dropship tag, then the kit rule
           case when ri.mode = 'ignore' then ri.reason
                when ri.mode = 'include' then null
                when ds.sku is not null then 'dropship'
                when wms__recon_auto_kit(j.sku, j.name, j.variant_title)
                     and not exists (select 1 from bin_inventory x where x.product_id = j.product_id) then 'kit'
                else null end as ignored,
           case when ri.mode in ('ignore','include') then 'manual' else 'auto' end as ignore_how,
           coalesce(ri.mode = 'include', false) as forced_in,
           case when ri.mode in ('ignore','include') then ri.note end as ignore_note,
           case when ri.mode in ('ignore','include') then (select display_name from staff where id = ri.set_by) end as ignore_by
      from joined j
      left join recon_ignore ri on ri.sku = j.sku
      left join shopify_dropship_skus ds on ds.sku = j.sku and ds.run_at = v_run
     where j.sh_on_hand <> 0 or j.sh_committed <> 0 or j.in_bins <> 0 or j.to_pick <> 0 or j.picked <> 0
  ), tiles as (
    select count(*) filter (where ignored is null and level = 'green') as green,
           count(*) filter (where ignored is null and level = 'amber') as amber,
           count(*) filter (where ignored is null and level = 'red') as red,
           coalesce(sum(diff) filter (where ignored is null and diff > 0), 0) as over_units,
           coalesce(sum(-diff) filter (where ignored is null and diff < 0), 0) as under_units,
           count(*) filter (where ignored is null) as checked,
           count(*) filter (where ignored = 'dropship') as ignored_dropship,
           count(*) filter (where ignored = 'kit') as ignored_kit,
           count(*) filter (where ignored = 'other') as ignored_other,
           coalesce(sum(sh_on_hand) filter (where ignored is null), 0) as sh_on_hand,
           coalesce(sum(sh_committed) filter (where ignored is null), 0) as sh_committed,
           coalesce(sum(in_bins) filter (where ignored is null), 0) as in_bins,
           coalesce(sum(to_pick) filter (where ignored is null), 0) as to_pick,
           coalesce(sum(picked) filter (where ignored is null), 0) as picked
      from rows_
  ), shown as (
    select * from rows_
     where (case when v_show = 'ignored' then ignored is not null
                 else ignored is null and (v_show = 'all' or (v_show = 'diff' and level <> 'green') or level = v_show) end)
       and (q is null or sku ilike '%' || q || '%' or name ilike '%' || q || '%'
            or exists (select 1 from jsonb_array_elements(locs) l where l->>'code' ilike q || '%'))
  )
  select jsonb_build_object(
    'generated_at', now(), 'pulled_at', v_run, 'pull', v_cur, 'last_error', v_state.last_error,
    'tiles', (select to_jsonb(t) from tiles t),
    'total_rows', (select count(*) from shown),
    'rows', coalesce((select jsonb_agg(jsonb_build_object(
        'level', level, 'sku', sku, 'product', name, 'variant', variant_title, 'note', note,
        'sh_on_hand', sh_on_hand, 'sh_committed', sh_committed, 'sh_free', sh_free,
        'in_bins', in_bins, 'to_pick', to_pick, 'orders', orders, 'picked', picked, 'wms_free', wms_free,
        'diff', diff, 'locs', locs, 'first_loc', first_code,
        'ignored', ignored, 'ignore_how', ignore_how, 'forced_in', forced_in, 'ignore_note', ignore_note, 'ignore_by', ignore_by))
      from (select * from shown order by case level when 'red' then 0 when 'amber' then 1 else 2 end, abs(diff) desc, sku
             limit greatest(coalesce(p_limit, 3000), 1)) x), '[]'::jsonb))
  into v_out;
  v_out := v_out || jsonb_build_object('shown', jsonb_array_length(v_out->'rows'));
  return v_out;
end $$;
revoke execute on function wms_inventory_recon(text, text, int) from public, anon;
grant execute on function wms_inventory_recon(text, text, int) to authenticated;
