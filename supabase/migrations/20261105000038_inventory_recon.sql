-- =============================================================================
-- 038  Inventory reconciliation: Shopify stock vs stock in WMS bin locations
-- -----------------------------------------------------------------------------
-- Ben (5 Nov 2026): a report showing stock differences between Shopify and the
-- bin locations. Shopify figure = on hand minus committed (sold, not sent yet).
--
-- Like for like:
--   Shopify free = Shopify on hand (TWL location) - Shopify committed
--   WMS free     = units in bin locations - units still to pick for open orders
--   Difference   = WMS free - Shopify free   (+ = more in bins than Shopify says)
-- Units already picked into totes / on the pack desk have left the bins and are
-- also inside Shopify's committed, so they cancel out on both sides.
--
-- Traffic lights: Green = match (0) | Amber = 1-2 units out | Red = 3+ units out,
-- or the item is only in one system.
--
-- Shopify figures come from the sync-shopify-stock edge function (one bulk read
-- of every inventory level at the TWL location) into shopify_stock. Each pull has
-- a run_at; the report only reads the latest finished pull (sync_state
-- 'shopify_stock'.cursor->>'run_at'), so a half-finished pull never shows.
-- Old pulls are simply overwritten per item (rows are never removed).
-- =============================================================================

create table if not exists shopify_stock (
  inventory_item_id bigint primary key,
  location_id       bigint not null,
  sku               text   not null default '',
  tracked           boolean not null default true,
  on_hand           int not null default 0,
  committed         int not null default 0,
  available         int not null default 0,
  reserved          int not null default 0,
  run_at            timestamptz not null,
  updated_at        timestamptz not null default now()
);
create index if not exists shopify_stock_run_sku_idx on shopify_stock(run_at, sku);
alter table shopify_stock enable row level security;   -- read only through the report function

-- ---------------------------------------------------------------------------
-- Import one chunk of a pull (service role only: called by the edge function)
-- p_rows: [{item, sku, tracked, on_hand, committed, available, reserved}]
-- ---------------------------------------------------------------------------
create or replace function wms_import_shopify_stock(p_run_at timestamptz, p_location bigint, p_rows jsonb)
returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into shopify_stock as s (inventory_item_id, location_id, sku, tracked, on_hand, committed, available, reserved, run_at, updated_at)
  select (r->>'item')::bigint, p_location, trim(coalesce(r->>'sku', '')), coalesce((r->>'tracked')::boolean, true),
         coalesce((r->>'on_hand')::int, 0), coalesce((r->>'committed')::int, 0),
         coalesce((r->>'available')::int, 0), coalesce((r->>'reserved')::int, 0), p_run_at, now()
    from jsonb_array_elements(coalesce(p_rows, '[]')) r
   where r->>'item' is not null
  on conflict (inventory_item_id) do update
     set location_id = excluded.location_id, sku = excluded.sku, tracked = excluded.tracked,
         on_hand = excluded.on_hand, committed = excluded.committed, available = excluded.available,
         reserved = excluded.reserved, run_at = excluded.run_at, updated_at = now();
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function wms_import_shopify_stock(timestamptz, bigint, jsonb) from public, anon, authenticated;
grant execute on function wms_import_shopify_stock(timestamptz, bigint, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- The report (admin + supervisor)
--   p_show   diff (amber + red, default) | red | amber | green | all
--   p_search SKU, product name or location code
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
      'tiles', jsonb_build_object('green',0,'amber',0,'red',0,'over_units',0,'under_units',0,'checked',0));
  end if;

  with sh as (            -- Shopify, latest pull, tracked items with a SKU (several items can share a SKU)
    select s.sku, sum(s.on_hand)::int as on_hand, sum(s.committed)::int as committed, count(*)::int as items
      from shopify_stock s
     where s.run_at = v_run and s.tracked and s.sku <> ''
     group by s.sku
  ), bins_ as (           -- every unit sitting in a location in the main warehouse
    select bi.product_id, sum(bi.qty_on_hand)::int as in_bins,
           jsonb_agg(jsonb_build_object('code', b.code, 'qty', bi.qty_on_hand, 'type', b.location_type)
                     order by bi.qty_on_hand desc, b.row_seq nulls last, b.code) as locs,
           (array_agg(b.code order by bi.qty_on_hand desc, b.row_seq nulls last, b.code))[1] as first_code
      from bin_inventory bi join bins b on b.id = bi.bin_id
     where b.warehouse_id = v_wh and bi.qty_on_hand > 0
     group by bi.product_id
  ), open_ as (           -- open WMS orders (from ShipStation): still to pick, and picked but not sent
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
                else null end as note
      from joined j
     where j.sh_on_hand <> 0 or j.sh_committed <> 0 or j.in_bins <> 0 or j.to_pick <> 0 or j.picked <> 0
  ), tiles as (
    select count(*) filter (where level = 'green') as green, count(*) filter (where level = 'amber') as amber,
           count(*) filter (where level = 'red') as red,
           coalesce(sum(diff) filter (where diff > 0), 0) as over_units, coalesce(sum(-diff) filter (where diff < 0), 0) as under_units,
           count(*) as checked,
           coalesce(sum(sh_on_hand), 0) as sh_on_hand, coalesce(sum(sh_committed), 0) as sh_committed,
           coalesce(sum(in_bins), 0) as in_bins, coalesce(sum(to_pick), 0) as to_pick, coalesce(sum(picked), 0) as picked
      from rows_
  ), shown as (
    select * from rows_
     where (v_show = 'all' or (v_show = 'diff' and level <> 'green') or level = v_show)
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
        'diff', diff, 'locs', locs, 'first_loc', first_code))
      from (select * from shown order by case level when 'red' then 0 when 'amber' then 1 else 2 end, abs(diff) desc, sku
             limit greatest(coalesce(p_limit, 3000), 1)) x), '[]'::jsonb))
  into v_out;
  v_out := v_out || jsonb_build_object('shown', jsonb_array_length(v_out->'rows'));
  return v_out;
end $$;
revoke execute on function wms_inventory_recon(text, text, int) from public, anon;
grant execute on function wms_inventory_recon(text, text, int) to authenticated;
