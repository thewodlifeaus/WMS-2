-- =============================================================================
-- TWL WMS | Migration 033 | Settings (carts, totes, locations) + replenishment
--   Settings (admin only):
--   * Carts: add a cart, rename it, switch it on/off, and set its totes in order
--     (eg 25 totes BIN001-BIN025). Only when the cart is free (no open pick and
--     nothing waiting to be packed). Totes taken off a cart become loose totes.
--   * Locations: add one or many (a range), switch them off (only when empty),
--     switch back on, and set the type and zone.
--       Shelf (pick) | Backstock (backfill) | Receiving | Reserved | Staging |
--       Packing | Quarantine
--     Shelf, Backstock and Receiving can be picked from. Reserved and the rest
--     are never picked. Each location can override that (always / never).
--   Replenishment report (admin + supervisor):
--   * Shelf locations that are empty or low, the backstock locations holding
--     more of that item, open order demand and a suggested quantity to move.
--   * Items that are only in backstock (no shelf home yet).
--   No rows are removed by anything here.
-- =============================================================================

-- 1. pickable = active and (override, else the type's rule). Receiving is now pickable.
alter table bins add column if not exists pick_allowed boolean;   -- null = use the type's rule
alter table bins alter column is_pickable set expression as
  (is_active and coalesce(pick_allowed, location_type in ('pick','backfill','receiving')));

create or replace function wms__type_pickable(p_type text) returns boolean
language sql immutable as $$ select p_type in ('pick','backfill','receiving') $$;

create or replace function wms__main_warehouse() returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce((select warehouse_id from bins group by warehouse_id order by count(*) desc limit 1),
                  (select id from warehouses order by code limit 1))
$$;

-- ---------------------------------------------------------------------------
-- 2. Carts and totes
-- ---------------------------------------------------------------------------
create or replace function wms_admin_carts() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not wms_has_role(array['admin']::staff_role[]) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object(
    'carts', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id, 'code', c.code, 'active', c.is_active, 'free', wms__cart_free(c.id),
        'open_pick', (select ps.status from pick_sessions ps where ps.cart_id = c.id and ps.status in ('draft','assigned','in_progress')
                       order by ps.created_at desc limit 1),
        'picker', (select s.display_name from pick_sessions ps join staff s on s.id = ps.assigned_to
                    where ps.cart_id = c.id and ps.status in ('assigned','in_progress') order by ps.created_at desc limit 1),
        'totes', (select coalesce(jsonb_agg(cb.barcode order by cb.position nulls last, cb.barcode), '[]')
                    from cart_baskets cb where cb.cart_id = c.id and cb.is_active))
        order by c.is_active desc, (c.code ~ '^CART') desc, c.code), '[]') from carts c),
    'loose', (select coalesce(jsonb_agg(jsonb_build_object('barcode', cb.barcode, 'active', cb.is_active, 'busy', wms__tote_busy(cb.id))
                order by cb.barcode), '[]') from cart_baskets cb where cb.cart_id is null));
end $$;

create or replace function wms_admin_save_cart(p_cart_id uuid, p_code text, p_active boolean default true)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); v_code text := upper(trim(coalesce(p_code, ''))); c carts; v_id uuid;
begin
  if not wms_has_role(array['admin']::staff_role[]) then return jsonb_build_object('ok',false,'error','FORBIDDEN'); end if;
  if v_code !~ '^[A-Z0-9][A-Z0-9_-]{0,19}$' then return jsonb_build_object('ok',false,'error','BAD_CODE'); end if;
  if exists (select 1 from carts where (upper(code) = v_code or upper(barcode) = v_code) and id is distinct from p_cart_id) then
    return jsonb_build_object('ok',false,'error','CODE_TAKEN','code',v_code);
  end if;
  if p_cart_id is null then
    insert into carts(warehouse_id, code, barcode, basket_count, is_active)
    values (wms__main_warehouse(), v_code, v_code, 48, coalesce(p_active, true)) returning id into v_id;
    return jsonb_build_object('ok',true,'id',v_id,'code',v_code,'created',true);
  end if;
  select * into c from carts where id = p_cart_id for update;
  if c.id is null then return jsonb_build_object('ok',false,'error','NOT_FOUND'); end if;
  if c.is_active and not coalesce(p_active, true) and not wms__cart_free(c.id) then
    return jsonb_build_object('ok',false,'error','CART_BUSY','code',c.code);
  end if;
  update carts set code = v_code, barcode = v_code, is_active = coalesce(p_active, true) where id = c.id;
  return jsonb_build_object('ok',true,'id',c.id,'code',v_code,'created',false);
end $$;

-- the cart's totes, in order (position 1 = first tote). p_confirmed false = preview.
create or replace function wms_admin_set_cart_totes(p_cart_id uuid, p_barcodes text[], p_confirmed boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := wms__require_staff(); c carts; v_list text[]; v_bad jsonb; v_added text[]; v_loose text[]; i int; n int;
begin
  if not wms_has_role(array['admin']::staff_role[]) then return jsonb_build_object('ok',false,'error','FORBIDDEN'); end if;
  select * into c from carts where id = p_cart_id for update;
  if c.id is null then return jsonb_build_object('ok',false,'error','NOT_FOUND'); end if;

  select coalesce(array_agg(x order by o), '{}') into v_list
    from (select upper(trim(x)) x, o from unnest(coalesce(p_barcodes, '{}')) with ordinality u(x, o)) t where x <> '';
  n := coalesce(array_length(v_list, 1), 0);
  if n > 48 then return jsonb_build_object('ok',false,'error','TOO_MANY','max',48); end if;
  if n <> (select count(distinct x) from unnest(v_list) x) then
    return jsonb_build_object('ok',false,'error','DUPLICATE',
      'barcodes',(select jsonb_agg(x) from (select x from unnest(v_list) x group by x having count(*) > 1) d));
  end if;
  if exists (select 1 from unnest(v_list) x where x !~ '^[A-Z0-9][A-Z0-9_:-]{0,29}$') then
    return jsonb_build_object('ok',false,'error','BAD_BARCODE');
  end if;
  -- totes already on another cart, or in use
  select jsonb_agg(jsonb_build_object('barcode', cb.barcode, 'cart', oc.code)) into v_bad
    from cart_baskets cb join carts oc on oc.id = cb.cart_id
   where upper(cb.barcode) = any(v_list) and cb.cart_id <> c.id;
  if v_bad is not null then return jsonb_build_object('ok',false,'error','TOTE_ON_OTHER_CART','totes',v_bad); end if;
  select jsonb_agg(cb.barcode) into v_bad from cart_baskets cb
   where upper(cb.barcode) = any(v_list) and cb.cart_id is null and wms__tote_busy(cb.id);
  if v_bad is not null then return jsonb_build_object('ok',false,'error','TOTE_IN_USE','totes',v_bad); end if;
  if exists (select 1 from carts x where upper(x.barcode) = any(v_list) or upper(x.code) = any(v_list)) then
    return jsonb_build_object('ok',false,'error','BARCODE_IS_A_CART');
  end if;

  select coalesce(array_agg(x order by o), '{}') into v_added from unnest(v_list) with ordinality u(x, o)
   where not exists (select 1 from cart_baskets cb where cb.cart_id = c.id and upper(cb.barcode) = x and cb.is_active);
  select coalesce(array_agg(cb.barcode order by cb.position), '{}') into v_loose from cart_baskets cb
   where cb.cart_id = c.id and not (upper(cb.barcode) = any(v_list));

  if not coalesce(p_confirmed, false) then
    return jsonb_build_object('ok',true,'preview',true,'cart',c.code,'free',wms__cart_free(c.id),'totes',n,
      'first',v_list[1],'last',v_list[n],'added',to_jsonb(v_added),'made_loose',to_jsonb(v_loose));
  end if;
  if not wms__cart_free(c.id) then return jsonb_build_object('ok',false,'error','CART_BUSY','cart',c.code); end if;

  update cart_baskets set position = null where cart_id = c.id;
  update cart_baskets set cart_id = null where cart_id = c.id and not (upper(barcode) = any(v_list));
  for i in 1 .. n loop
    update cart_baskets set cart_id = c.id, position = i, kind = 'tote', is_active = true, warehouse_id = c.warehouse_id
     where upper(barcode) = v_list[i];
    if not found then
      insert into cart_baskets(cart_id, position, barcode, kind, warehouse_id, is_active)
      values (c.id, i, v_list[i], 'tote', c.warehouse_id, true);
    end if;
  end loop;
  if n > 0 then update carts set basket_count = n where id = c.id; end if;
  return jsonb_build_object('ok',true,'cart',c.code,'totes',n,'first',v_list[1],'last',v_list[n],
    'added',to_jsonb(v_added),'made_loose',to_jsonb(v_loose));
end $$;

-- ---------------------------------------------------------------------------
-- 3. Locations
-- ---------------------------------------------------------------------------
create or replace function wms_admin_locations(
  p_search text default null, p_type text default null, p_zone text default null,
  p_status text default 'active', p_limit int default 200, p_offset int default 0
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q text := upper(nullif(trim(coalesce(p_search, '')), '')); v jsonb; v_n int;
begin
  if not wms_has_role(array['admin']::staff_role[]) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  with t as (
    select b.*, z.code as zone,
           coalesce((select sum(qty_on_hand) from bin_inventory bi where bi.bin_id = b.id), 0) as units,
           coalesce((select sum(qty_allocated) from bin_inventory bi where bi.bin_id = b.id), 0) as reserved,
           (select count(*) from bin_inventory bi where bi.bin_id = b.id and bi.qty_on_hand > 0) as skus
      from bins b left join zones z on z.id = b.zone_id
     where (q is null or upper(b.code) like q || '%' or upper(b.code) like '%' || q || '%')
       and (p_type is null or p_type = '' or b.location_type::text = p_type)
       and (p_zone is null or p_zone = '' or z.code = p_zone)
       and (coalesce(p_status, 'active') = 'all' or (p_status = 'active') = b.is_active)
  ), pg as (
    select * from t order by (upper(code) = q) desc, row_seq nulls last, shelf_seq nulls last, bin_seq, code
     limit least(greatest(coalesce(p_limit, 200), 1), 2000) offset greatest(coalesce(p_offset, 0), 0)
  )
  select (select count(*) from t),
         coalesce((select jsonb_agg(jsonb_build_object('code', code, 'type', location_type, 'zone', zone, 'active', is_active,
                   'pickable', is_pickable, 'pick_allowed', pick_allowed, 'units', units, 'reserved', reserved, 'skus', skus)
                   order by (upper(code) = q) desc, row_seq nulls last, shelf_seq nulls last, bin_seq, code) from pg), '[]')
    into v_n, v;
  return jsonb_build_object('total', v_n, 'rows', v,
    'zones', (select coalesce(jsonb_agg(jsonb_build_object('code', z.code, 'name', z.name,
               'bins', (select count(*) from bins b where b.zone_id = z.id and b.is_active)) order by z.sequence, z.code), '[]') from zones z),
    'types', (select coalesce(jsonb_object_agg(t, n), '{}') from
               (select location_type::text t, count(*) n from bins where is_active group by 1) x));
end $$;

-- add locations. Codes: 'EA-01-01' (row-shelf-bin), 'SA-01' (row-shelf, when the row exists),
-- anything else is a floor area ('0-RECEIVE'). p_confirmed false = preview.
create or replace function wms_admin_add_locations(
  p_codes text[], p_type text default 'pick', p_zone text default null, p_confirmed boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := wms__require_staff(); v_wh uuid := wms__main_warehouse(); v_zone uuid; v_zone_code text := upper(nullif(trim(coalesce(p_zone, '')), ''));
  v_code text; parts text[]; b bins; v_row aisle_rows; v_shelf uuid; v_out jsonb := '[]'; v_kind text; v_status text;
  v_new int := 0; v_re int := 0; v_have int := 0; v_newrows text[] := '{}';
begin
  if not wms_has_role(array['admin']::staff_role[]) then return jsonb_build_object('ok',false,'error','FORBIDDEN'); end if;
  if coalesce(p_type, '') not in (select unnest(enum_range(null::location_type))::text) then
    return jsonb_build_object('ok',false,'error','BAD_TYPE');
  end if;
  if coalesce(array_length(p_codes, 1), 0) = 0 then return jsonb_build_object('ok',false,'error','NO_CODES'); end if;
  if array_length(p_codes, 1) > 500 then return jsonb_build_object('ok',false,'error','TOO_MANY','max',500); end if;
  if v_zone_code is not null and v_zone_code !~ '^[A-Z0-9][A-Z0-9_-]{0,19}$' then return jsonb_build_object('ok',false,'error','BAD_ZONE'); end if;
  select id into v_zone from zones where warehouse_id = v_wh and upper(code) = v_zone_code;

  if coalesce(p_confirmed, false) and v_zone_code is not null and v_zone is null then
    insert into zones(warehouse_id, code, name, sequence)
    values (v_wh, v_zone_code, v_zone_code, (select coalesce(max(sequence), 0) + 1 from zones where warehouse_id = v_wh))
    returning id into v_zone;
  end if;

  for v_code in select distinct upper(trim(x)) from unnest(p_codes) x where trim(coalesce(x, '')) <> '' loop
    if v_code !~ '^[A-Z0-9][A-Z0-9_-]{0,29}$' then
      v_out := v_out || jsonb_build_object('code', v_code, 'status', 'bad_code'); continue;
    end if;
    select * into b from bins where warehouse_id = v_wh and upper(code) = v_code;
    if b.id is not null then
      v_status := case when b.is_active then 'exists' else 'switch_on' end;
      if v_status = 'exists' then v_have := v_have + 1; else v_re := v_re + 1; end if;
      if coalesce(p_confirmed, false) and not b.is_active then update bins set is_active = true where id = b.id; end if;
      v_out := v_out || jsonb_build_object('code', v_code, 'status', v_status, 'type', b.location_type);
      continue;
    end if;

    parts := string_to_array(v_code, '-');
    select * into v_row from aisle_rows where warehouse_id = v_wh and upper(code) = parts[1];
    v_kind := case when array_length(parts, 1) = 3 then 'shelf'
                   when array_length(parts, 1) = 2 and v_row.id is not null then 'shelf'
                   else 'floor' end;
    v_new := v_new + 1;
    if v_kind = 'shelf' and v_row.id is null and not (parts[1] = any(v_newrows)) then v_newrows := v_newrows || parts[1]; end if;
    v_out := v_out || jsonb_build_object('code', v_code, 'status', 'new', 'kind', v_kind,
                                         'new_row', v_kind = 'shelf' and v_row.id is null);
    continue when not coalesce(p_confirmed, false);

    if v_kind = 'shelf' then
      if v_row.id is null then
        insert into aisle_rows(warehouse_id, zone_id, code, sequence)
        values (v_wh, v_zone, parts[1], (select coalesce(max(sequence), 0) + 1 from aisle_rows where warehouse_id = v_wh))
        returning * into v_row;
      end if;
      select id into v_shelf from shelves where row_id = v_row.id and upper(code) = parts[2];
      if v_shelf is null then
        insert into shelves(row_id, code, sequence)
        values (v_row.id, parts[2], coalesce(nullif(regexp_replace(parts[2], '\D', '', 'g'), '')::int, 0))
        returning id into v_shelf;
      end if;
      insert into bins(warehouse_id, shelf_id, zone_id, bin_code, code, barcode, location_type)
      values (v_wh, v_shelf, coalesce(v_zone, v_row.zone_id), coalesce(parts[3], ''), '', '', p_type::location_type);
    else
      insert into bins(warehouse_id, shelf_id, zone_id, bin_code, code, barcode, location_type)
      values (v_wh, null, v_zone, v_code, v_code, '', p_type::location_type);
    end if;
  end loop;

  return jsonb_build_object('ok',true,'preview',not coalesce(p_confirmed, false),'new',v_new,'switched_on',v_re,
    'already',v_have,'new_rows',to_jsonb(v_newrows),'new_zone', v_zone_code is not null and v_zone is null,
    'locations',v_out);
end $$;

-- change type / zone / pick rule / on-off for a list of locations.
--   p_pick: 'type' (follow the type), 'always', 'never'.  null = leave as is.
--   A location can only be switched off when empty, and can't stop being pickable
--   while stock in it is reserved for a cart.
create or replace function wms_admin_update_locations(
  p_codes text[], p_type text default null, p_zone text default null, p_pick text default null, p_active boolean default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := wms__require_staff(); v_wh uuid := wms__main_warehouse(); v_zone uuid; v_zone_code text := upper(nullif(trim(coalesce(p_zone, '')), ''));
  b bins; v_code text; v_units int; v_res int; v_type text; v_allow boolean; v_act boolean; v_blocked jsonb := '[]'; v_done int := 0; v_missing jsonb := '[]';
begin
  if not wms_has_role(array['admin']::staff_role[]) then return jsonb_build_object('ok',false,'error','FORBIDDEN'); end if;
  if p_type is not null and p_type not in (select unnest(enum_range(null::location_type))::text) then
    return jsonb_build_object('ok',false,'error','BAD_TYPE');
  end if;
  if p_pick is not null and p_pick not in ('type','always','never') then return jsonb_build_object('ok',false,'error','BAD_PICK'); end if;
  if v_zone_code is not null then
    select id into v_zone from zones where warehouse_id = v_wh and upper(code) = v_zone_code;
    if v_zone is null then return jsonb_build_object('ok',false,'error','UNKNOWN_ZONE','zone',v_zone_code); end if;
  end if;
  if coalesce(array_length(p_codes, 1), 0) > 2000 then return jsonb_build_object('ok',false,'error','TOO_MANY','max',2000); end if;

  for v_code in select distinct upper(trim(x)) from unnest(coalesce(p_codes, '{}')) x where trim(coalesce(x, '')) <> '' loop
    select * into b from bins where warehouse_id = v_wh and upper(code) = v_code for update;
    if b.id is null then v_missing := v_missing || to_jsonb(v_code); continue; end if;
    select coalesce(sum(qty_on_hand), 0), coalesce(sum(qty_allocated), 0) into v_units, v_res from bin_inventory where bin_id = b.id;
    v_type  := coalesce(p_type, b.location_type::text);
    v_allow := case p_pick when 'type' then null when 'always' then true when 'never' then false else b.pick_allowed end;
    v_act   := coalesce(p_active, b.is_active);
    if b.is_active and not v_act and v_units > 0 then
      v_blocked := v_blocked || jsonb_build_object('code', b.code, 'reason', 'Still holds ' || v_units || ' units. Move them out first.');
      continue;
    end if;
    if b.is_pickable and not (v_act and coalesce(v_allow, wms__type_pickable(v_type))) and v_res > 0 then
      v_blocked := v_blocked || jsonb_build_object('code', b.code, 'reason', v_res || ' units here are reserved for a cart.');
      continue;
    end if;
    update bins set location_type = v_type::location_type, pick_allowed = v_allow, is_active = v_act,
                    zone_id = coalesce(v_zone, zone_id)
     where id = b.id;
    v_done := v_done + 1;
  end loop;
  return jsonb_build_object('ok',true,'updated',v_done,'blocked',v_blocked,'not_found',v_missing);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Replenishment report
--   Low = a shelf location holding p_low units or fewer of an item (or under its
--   replenishment rule minimum). Fill to = rule max, else the location's max
--   units, else p_fill_to. Backstock = active Backstock / Reserved / Receiving /
--   Staging locations with free units of that item.
-- ---------------------------------------------------------------------------
create or replace function wms_replenishment_report(
  p_low int default 2, p_fill_to int default 6, p_zone text default null,
  p_search text default null, p_only_backstock boolean default true
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q text := nullif(trim(coalesce(p_search, '')), ''); v_low int := greatest(coalesce(p_low, 2), 0);
        v_fill int := greatest(coalesce(p_fill_to, 6), 1); v_rows jsonb; v_only jsonb; v_empty int;
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;

  with demand as (
    select ol.product_id, sum(ol.qty_ordered - ol.qty_allocated) as units, count(distinct o.id) as orders
      from order_lines ol join orders o on o.id = ol.order_id
     where o.status = 'awaiting_pick' and not o.is_held and ol.qty_allocated < ol.qty_ordered
     group by ol.product_id
  ), back as (
    select bi.product_id, sum(bi.qty_on_hand - bi.qty_allocated) as units,
           jsonb_agg(jsonb_build_object('code', b.code, 'type', b.location_type, 'qty', bi.qty_on_hand - bi.qty_allocated)
                     order by bi.qty_on_hand - bi.qty_allocated desc, b.row_seq nulls last, b.code) as locs,
           (array_agg(b.code order by bi.qty_on_hand - bi.qty_allocated desc, b.row_seq nulls last, b.code))[1] as first_code,
           min(b.row_seq) as first_row
      from bin_inventory bi join bins b on b.id = bi.bin_id
     where b.is_active and b.location_type in ('backfill','reserved','receiving','staging')
       and bi.qty_on_hand - bi.qty_allocated > 0
     group by bi.product_id
  ), shelf_all as (
    select bi.product_id, sum(bi.qty_on_hand - bi.qty_allocated) as free_units
      from bin_inventory bi join bins b on b.id = bi.bin_id
     where b.is_active and b.location_type = 'pick' group by bi.product_id
  ), sold as (
    select product_id, -sum(qty_delta) as units from inventory_transactions
     where txn_type = 'pick' and occurred_at > now() - interval '30 days' group by product_id
  ), low as (
    select b.code as bin, b.row_seq, b.shelf_seq, b.bin_seq, z.code as zone, p.id as product_id, p.sku, p.name, p.variant_title,
           bi.qty_on_hand as on_hand, bi.qty_allocated as reserved,
           coalesce(rr.max_qty, b.max_units, v_fill) as fill_to, rr.min_qty,
           coalesce(d.units, 0) as demand, coalesce(d.orders, 0) as demand_orders,
           greatest(coalesce(d.units, 0) - coalesce(sa.free_units, 0), 0) as short,
           coalesce(sa.free_units, 0) - (bi.qty_on_hand - bi.qty_allocated) as other_shelves,
           coalesce(bk.units, 0) as back_units, coalesce(bk.locs, '[]') as back_locs, bk.first_code, bk.first_row,
           coalesce(so.units, 0) as sold_30d
      from bin_inventory bi
      join bins b on b.id = bi.bin_id
      join products p on p.id = bi.product_id
      left join zones z on z.id = b.zone_id
      left join replenishment_rules rr on rr.bin_id = b.id and rr.product_id = p.id and rr.is_active
      left join demand d on d.product_id = p.id
      left join back bk on bk.product_id = p.id
      left join shelf_all sa on sa.product_id = p.id
      left join sold so on so.product_id = p.id
     where b.is_active and b.location_type = 'pick'
       and (bi.qty_on_hand <= v_low or (rr.min_qty is not null and bi.qty_on_hand <= rr.min_qty))
       and (p_zone is null or p_zone = '' or z.code = p_zone)
       and (q is null or p.sku ilike '%' || q || '%' or p.name ilike '%' || q || '%' or b.code ilike q || '%')
       and (not coalesce(p_only_backstock, true) or coalesce(bk.units, 0) > 0)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'bin', bin, 'zone', zone, 'sku', sku, 'product', name, 'variant', variant_title,
           'on_hand', on_hand, 'reserved', reserved, 'fill_to', fill_to, 'min', min_qty,
           'demand', demand, 'demand_orders', demand_orders, 'short', short, 'other_shelves', other_shelves,
           'back_units', back_units, 'back_locs', back_locs, 'from', first_code, 'sold_30d', sold_30d,
           'move', least(back_units, greatest(fill_to - on_hand, short)),
           'level', case when on_hand = 0 or short > 0 then 'red' else 'amber' end)
         order by (on_hand = 0 or short > 0) desc, short desc, demand desc, sold_30d desc, row_seq nulls last, shelf_seq, bin_seq, bin), '[]')
    into v_rows
    from (select * from low order by (on_hand = 0 or short > 0) desc, short desc, demand desc, sold_30d desc limit 1500) l;

  -- items in backstock with no shelf location at all
  with back as (
    select bi.product_id, sum(bi.qty_on_hand - bi.qty_allocated) as units,
           jsonb_agg(jsonb_build_object('code', b.code, 'type', b.location_type, 'qty', bi.qty_on_hand - bi.qty_allocated)
                     order by bi.qty_on_hand - bi.qty_allocated desc, b.code) as locs
      from bin_inventory bi join bins b on b.id = bi.bin_id
     where b.is_active and b.location_type in ('backfill','reserved','receiving','staging') and bi.qty_on_hand - bi.qty_allocated > 0
     group by bi.product_id
  )
  select coalesce(jsonb_agg(jsonb_build_object('sku', p.sku, 'product', p.name, 'variant', p.variant_title,
           'back_units', bk.units, 'back_locs', bk.locs,
           'demand', (select coalesce(sum(ol.qty_ordered - ol.qty_allocated), 0) from order_lines ol join orders o on o.id = ol.order_id
                       where ol.product_id = p.id and o.status = 'awaiting_pick' and not o.is_held))
         order by p.sku), '[]')
    into v_only
    from (select * from back limit 2000) bk join products p on p.id = bk.product_id
   where not exists (select 1 from bin_inventory bi join bins b on b.id = bi.bin_id
                      where bi.product_id = bk.product_id and b.is_active and b.location_type = 'pick')
     and (q is null or p.sku ilike '%' || q || '%' or p.name ilike '%' || q || '%');

  select count(*) into v_empty from bins b
   where b.is_active and b.location_type = 'pick' and b.shelf_id is not null
     and not exists (select 1 from bin_inventory bi where bi.bin_id = b.id and bi.qty_on_hand > 0);

  return jsonb_build_object('rows', v_rows, 'backstock_only', v_only, 'empty_shelf_bins', v_empty,
    'low', v_low, 'fill_to', v_fill, 'generated_at', now(),
    'zones', (select coalesce(jsonb_agg(code order by sequence, code), '[]') from zones));
end $$;

revoke execute on function wms__type_pickable(text) from public, anon, authenticated;
revoke execute on function wms__main_warehouse() from public, anon, authenticated;
revoke execute on function wms_admin_carts() from public, anon;
revoke execute on function wms_admin_save_cart(uuid, text, boolean) from public, anon;
revoke execute on function wms_admin_set_cart_totes(uuid, text[], boolean) from public, anon;
revoke execute on function wms_admin_locations(text, text, text, text, int, int) from public, anon;
revoke execute on function wms_admin_add_locations(text[], text, text, boolean) from public, anon;
revoke execute on function wms_admin_update_locations(text[], text, text, text, boolean) from public, anon;
revoke execute on function wms_replenishment_report(int, int, text, text, boolean) from public, anon;
grant execute on function wms_admin_carts() to authenticated;
grant execute on function wms_admin_save_cart(uuid, text, boolean) to authenticated;
grant execute on function wms_admin_set_cart_totes(uuid, text[], boolean) to authenticated;
grant execute on function wms_admin_locations(text, text, text, text, int, int) to authenticated;
grant execute on function wms_admin_add_locations(text[], text, text, boolean) to authenticated;
grant execute on function wms_admin_update_locations(text[], text, text, text, boolean) to authenticated;
grant execute on function wms_replenishment_report(int, int, text, text, boolean) to authenticated;
