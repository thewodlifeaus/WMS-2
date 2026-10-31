-- =============================================================================
-- TWL WMS | Migration 010 | Pick & pack rules (carried over from SkuVault)
--
--  1. Every pick is checked against the order   (already enforced; now explicit setting)
--  2. Pickers enter quantities                    wms_pick_scan(p_qty)
--  3. A warning shows if an order is on hold      orders.is_held + warnings[]
--  4. Every order goes through a full pack check  every unit scanned (no quantity entry at pack)
--  5. A passed check closes the order             last scan auto-closes the box -> 'packed'
--
-- Rules live in warehouses.settings so they can be switched in the desktop app.
-- =============================================================================

alter table warehouses add column if not exists settings jsonb not null default '{
  "pick_check_against_order": true,
  "pick_enter_quantity": true,
  "warn_on_hold": true,
  "pack_full_check": true,
  "pack_auto_close": true
}'::jsonb;

alter table orders add column if not exists is_held  boolean not null default false;
alter table orders add column if not exists held_at  timestamptz;
alter table orders add column if not exists held_by  uuid references staff(id);

alter table pack_stations add column if not exists default_package_type_id uuid references package_types(id);

create or replace function wms__setting(p_warehouse uuid, p_key text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select (settings->>p_key)::boolean from warehouses where id = p_warehouse), true)
$$;

-- ---------------------------------------------------------------------------
-- Holds: supervisors put an order on / off hold (also set by the ShipStation sync)
-- ---------------------------------------------------------------------------
create or replace function wms_set_order_hold(p_order_id uuid, p_held boolean, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff();
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then
    return jsonb_build_object('ok',false,'error','FORBIDDEN');
  end if;
  update orders set is_held = p_held,
         hold_reason = case when p_held then coalesce(p_reason, 'On hold') else null end,
         held_at = case when p_held then now() end,
         held_by = case when p_held then v_staff end
   where id = p_order_id;
  return jsonb_build_object('ok', found, 'order_id', p_order_id, 'held', p_held);
end $$;

-- held orders never start a NEW pick; they are skipped and reported back
create or replace function wms__held_orders(p_order_ids uuid[]) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('order_id', id, 'order_number', order_number,
                                               'reason', hold_reason)), '[]'::jsonb)
    from orders where id = any(p_order_ids) and is_held
$$;

-- ---------------------------------------------------------------------------
-- RULE 1 + 2 + 3: scan-to-pick with quantity entry and hold warnings
-- Scan the item once, then the quantity (defaults to 1 scan's worth).
-- If "pick_enter_quantity" is off, every unit must be scanned.
-- ---------------------------------------------------------------------------
drop function if exists wms_pick_scan(uuid, text, uuid);

create or replace function wms_pick_scan(
  p_task_id uuid, p_barcode text, p_device_id uuid default null, p_qty int default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := wms__require_staff();
  t pick_tasks; s pick_sessions; v_current uuid;
  v_prod uuid; v_units int; v_left int; a record; v_put jsonb := '[]'::jsonb; v_take int;
  v_session_done boolean; v_warn jsonb := '[]'::jsonb;
begin
  select * into t from pick_tasks where id = p_task_id for update;
  if not found then return jsonb_build_object('ok',false,'error','TASK_NOT_FOUND'); end if;
  select * into s from pick_sessions where id = t.session_id;
  if s.status <> 'in_progress' then return jsonb_build_object('ok',false,'error','SESSION_NOT_STARTED'); end if;

  -- cannot skip ahead: only the lowest pending task may be scanned
  select id into v_current from pick_tasks where session_id = t.session_id and status = 'pending'
   order by sequence limit 1;
  if v_current is distinct from t.id then
    return jsonb_build_object('ok',false,'error','NOT_CURRENT_TASK','alarm',true,
                              'current', wms_get_current_task(t.session_id));
  end if;

  select pb.product_id, pb.units_per_scan into v_prod, v_units
    from product_barcodes pb where pb.barcode = trim(p_barcode);

  if v_prod is null then
    perform wms__log_scan('pick','unknown_barcode',p_barcode,t.product_id,null,t.session_id,t.id,null,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','UNKNOWN_BARCODE','alarm',true);
  end if;

  -- RULE 1: the scanned item must be the item this order needs from this bin
  if v_prod <> t.product_id then
    perform wms__log_scan('pick','wrong_item',p_barcode,t.product_id,v_prod,t.session_id,t.id,null,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','WRONG_ITEM','alarm',true,
      'expected_sku',(select sku from products where id = t.product_id),
      'scanned_sku',(select sku from products where id = v_prod));
  end if;

  -- RULE 2: quantity entered by the picker (or 1 scan's worth)
  if p_qty is not null and wms__setting(s.warehouse_id, 'pick_enter_quantity') then
    if p_qty <= 0 then return jsonb_build_object('ok',false,'error','BAD_QTY'); end if;
    v_units := p_qty;
  end if;

  if t.qty_picked + v_units > t.qty_required then
    perform wms__log_scan('pick','over_qty',p_barcode,t.product_id,v_prod,t.session_id,t.id,null,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','OVER_QTY','alarm',true,
      'remaining', t.qty_required - t.qty_picked);
  end if;

  -- RULE 3: warn (do not block) if any order this item is going to is on hold
  if wms__setting(s.warehouse_id, 'warn_on_hold') then
    select coalesce(jsonb_agg(distinct jsonb_build_object('type','ORDER_ON_HOLD','order_number',o.order_number,
                                                           'reason',o.hold_reason)), '[]')
      into v_warn
      from pick_allocations pa join orders o on o.id = pa.order_id
     where pa.task_id = t.id and pa.qty_picked < pa.qty and o.is_held;
  end if;

  -- fill allocations in order; tell the picker which basket(s) to drop into
  v_left := v_units;
  for a in select pa.*, cb.position, o.order_number
             from pick_allocations pa join orders o on o.id = pa.order_id
             left join cart_baskets cb on cb.id = pa.basket_id
            where pa.task_id = t.id and pa.qty_picked < pa.qty
            order by pa.fill_order for update of pa
  loop
    exit when v_left = 0;
    v_take := least(v_left, a.qty - a.qty_picked);
    update pick_allocations set qty_picked = qty_picked + v_take where id = a.id;
    update order_lines set qty_picked = qty_picked + v_take where id = a.order_line_id;
    v_put := v_put || jsonb_build_object('basket',a.position,'order_number',a.order_number,'qty',v_take);
    v_left := v_left - v_take;
  end loop;

  perform wms__apply_delta(t.bin_id, t.product_id, -v_units, 'pick', 'pick_task', t.id,
                           v_staff, p_device_id, null, null, v_units);

  update pick_tasks set qty_picked = qty_picked + v_units,
         started_at = coalesce(started_at, now()),
         status = case when qty_picked + v_units >= qty_required then 'done'::task_status else 'pending'::task_status end,
         completed_at = case when qty_picked + v_units >= qty_required then now() end
   where id = t.id;
  perform wms__log_scan('pick','ok',p_barcode,t.product_id,v_prod,t.session_id,t.id,null,v_staff,p_device_id);

  v_session_done := wms__close_session_if_done(t.session_id);
  return jsonb_build_object('ok',true,'qty',v_units,'put_into',v_put,'warnings',v_warn,
    'task_done', t.qty_picked + v_units >= t.qty_required,
    'session_done', v_session_done,
    'next', wms_get_current_task(t.session_id));
end $$;

-- show hold flags on the picker's current-task screen as well
create or replace function wms_get_current_task(p_session_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t record; v_total int; v_done int;
begin
  perform wms__require_staff();
  select count(*), count(*) filter (where status <> 'pending') into v_total, v_done
    from pick_tasks where session_id = p_session_id;

  select pt.id, pt.sequence, pt.qty_required, pt.qty_picked, b.code as bin_code, b.barcode as bin_barcode,
         p.sku, p.name, p.variant_title, p.image_url
    into t
    from pick_tasks pt join bins b on b.id = pt.bin_id join products p on p.id = pt.product_id
   where pt.session_id = p_session_id and pt.status = 'pending'
   order by pt.sequence limit 1;

  if not found then
    return jsonb_build_object('session_id',p_session_id,'done',true,'progress',jsonb_build_object('total',v_total,'done',v_done));
  end if;

  return jsonb_build_object(
    'session_id', p_session_id, 'done', false,
    'progress', jsonb_build_object('total', v_total, 'done', v_done),
    'task', jsonb_build_object(
      'id', t.id, 'sequence', t.sequence, 'bin', t.bin_code, 'bin_barcode', t.bin_barcode,
      'sku', t.sku, 'name', t.name, 'variant', t.variant_title, 'image_url', t.image_url,
      'qty_required', t.qty_required, 'qty_picked', t.qty_picked,
      'put_into', (select jsonb_agg(jsonb_build_object(
                      'basket', cb.position, 'basket_barcode', cb.barcode,
                      'order_number', o.order_number, 'qty', pa.qty, 'qty_picked', pa.qty_picked,
                      'on_hold', o.is_held, 'hold_reason', o.hold_reason)
                    order by pa.fill_order)
                     from pick_allocations pa
                     join orders o on o.id = pa.order_id
                     left join cart_baskets cb on cb.id = pa.basket_id
                    where pa.task_id = t.id)));
end $$;

-- ---------------------------------------------------------------------------
-- RULE 4 + 5: full pack check, auto close on pass
-- ---------------------------------------------------------------------------
-- internal: weigh + close the box (used by the last scan and by wms_pack_complete)
create or replace function wms__pack_close(
  p_shipment_id uuid, p_package_type_id uuid, p_weight_grams int,
  p_length_cm numeric, p_width_cm numeric, p_height_cm numeric
) returns void language plpgsql security definer set search_path = public as $$
declare sh shipments; pt package_types; v_weight int;
begin
  select * into sh from shipments where id = p_shipment_id;
  select * into pt from package_types
   where id = coalesce(p_package_type_id, sh.package_type_id,
                       (select default_package_type_id from pack_stations where id = sh.pack_station_id));
  -- product weights + packaging tare when there is no scale reading
  select coalesce(p_weight_grams,
                  sum(si.qty * coalesce(p.weight_grams, 0)) + coalesce(pt.tare_grams, 0))::int
    into v_weight
    from shipment_items si join order_lines l on l.id = si.order_line_id
    left join products p on p.id = l.product_id
   where si.shipment_id = sh.id;

  update shipments set status = 'packed', packed_at = coalesce(packed_at, now()), package_type_id = pt.id,
         weight_grams = greatest(coalesce(v_weight, 1), 1),
         length_cm = coalesce(p_length_cm, pt.length_cm), width_cm = coalesce(p_width_cm, pt.width_cm),
         height_cm = coalesce(p_height_cm, pt.height_cm)
   where id = sh.id;
  update orders set status = 'packed' where id = sh.order_id;
end $$;

drop function if exists wms_pack_start(text, uuid, uuid);

create or replace function wms_pack_start(
  p_scan text, p_pack_station_id uuid default null, p_device_id uuid default null,
  p_override_hold boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); v_order orders; v_ship uuid;
begin
  select o.* into v_order
    from cart_baskets cb
    join pick_session_orders pso on pso.basket_id = cb.id
    join pick_sessions s on s.id = pso.session_id
    join orders o on o.id = pso.order_id
   where cb.barcode = trim(p_scan) and o.status in ('picked','packing')
   order by s.completed_at desc nulls last limit 1;

  if v_order.id is null then
    select * into v_order from orders where order_number = ltrim(trim(p_scan), '#');
  end if;
  if v_order.id is null then return jsonb_build_object('ok',false,'error','ORDER_NOT_FOUND'); end if;
  if v_order.status not in ('picked','packing') then
    return jsonb_build_object('ok',false,'error','ORDER_NOT_READY','status',v_order.status);
  end if;

  -- RULE 3 at the bench: stop and ask before packing a held order
  if v_order.is_held and not p_override_hold and wms__setting(v_order.warehouse_id, 'warn_on_hold') then
    return jsonb_build_object('ok',false,'error','ORDER_ON_HOLD','alarm',true,
      'order_number',v_order.order_number,'reason',v_order.hold_reason,
      'hint','Confirm with a supervisor, then start again with override');
  end if;

  select id into v_ship from shipments where order_id = v_order.id and status = 'packing';
  if v_ship is null then
    insert into shipments(order_id, pack_station_id, packed_by, status, carrier_id, service_code)
    values (v_order.id, p_pack_station_id, v_staff, 'packing', v_order.carrier_id, v_order.service_code)
    returning id into v_ship;
  end if;
  update orders set status = 'packing' where id = v_order.id;
  return jsonb_build_object('ok',true,
           'warnings', case when v_order.is_held then jsonb_build_array(jsonb_build_object(
                         'type','ORDER_ON_HOLD','order_number',v_order.order_number,'reason',v_order.hold_reason))
                       else '[]'::jsonb end) || wms__pack_view(v_ship);
end $$;

-- RULE 4: every unit is scanned (no typed quantities at the bench)
-- RULE 5: the scan that completes the order closes the box automatically
create or replace function wms_pack_scan(p_shipment_id uuid, p_barcode text, p_device_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); sh shipments; v_prod uuid; v_units int; l order_lines;
        v_wh uuid; v_complete boolean; v_closed boolean := false;
begin
  select * into sh from shipments where id = p_shipment_id for update;
  if sh.status <> 'packing' then return jsonb_build_object('ok',false,'error','SHIPMENT_CLOSED'); end if;
  select warehouse_id into v_wh from orders where id = sh.order_id;

  select product_id, units_per_scan into v_prod, v_units from product_barcodes where barcode = trim(p_barcode);
  if v_prod is null then
    perform wms__log_scan('pack','unknown_barcode',p_barcode,null,null,null,null,sh.id,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','UNKNOWN_BARCODE','alarm',true);
  end if;

  select * into l from order_lines
   where order_id = sh.order_id and product_id = v_prod
   order by (qty_picked - qty_packed) desc limit 1 for update;
  if l.id is null then
    perform wms__log_scan('pack','wrong_item',p_barcode,null,v_prod,null,null,sh.id,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','NOT_IN_ORDER','alarm',true,
                              'scanned_sku',(select sku from products where id = v_prod));
  end if;
  if l.qty_packed + v_units > l.qty_picked then
    perform wms__log_scan('pack','over_qty',p_barcode,v_prod,v_prod,null,null,sh.id,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','ALREADY_PACKED','alarm',true,'sku',l.sku);
  end if;

  update order_lines set qty_packed = qty_packed + v_units where id = l.id;
  insert into shipment_items(shipment_id, order_line_id, qty) values (sh.id, l.id, v_units)
  on conflict (shipment_id, order_line_id) do update set qty = shipment_items.qty + excluded.qty;
  perform wms__log_scan('pack','ok',p_barcode,v_prod,v_prod,null,null,sh.id,v_staff,p_device_id);

  v_complete := not exists (select 1 from order_lines where order_id = sh.order_id and qty_packed < qty_ordered);
  if v_complete and wms__setting(v_wh, 'pack_auto_close') then
    perform wms__pack_close(sh.id, null, null, null, null, null);
    v_closed := true;
  end if;

  return jsonb_build_object('ok',true,'sku',l.sku,'auto_closed',v_closed,
           'next', case when v_closed then 'print label (pack-and-ship)' end) || wms__pack_view(sh.id);
end $$;

-- manual close, or change the box / weight after an auto-close (until the label is bought)
create or replace function wms_pack_complete(
  p_shipment_id uuid, p_package_type_id uuid default null, p_weight_grams int default null,
  p_length_cm numeric default null, p_width_cm numeric default null, p_height_cm numeric default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); sh shipments;
begin
  select * into sh from shipments where id = p_shipment_id for update;
  if sh.status not in ('packing','packed') then return jsonb_build_object('ok',false,'error','SHIPMENT_CLOSED'); end if;
  -- RULE 4: no partial boxes, every unit must have been scanned
  if exists (select 1 from order_lines where order_id = sh.order_id and qty_packed < qty_ordered) then
    return jsonb_build_object('ok',false,'error','NOT_ALL_ITEMS_SCANNED') || wms__pack_view(sh.id);
  end if;
  perform wms__pack_close(sh.id, p_package_type_id, p_weight_grams, p_length_cm, p_width_cm, p_height_cm);
  return jsonb_build_object('ok',true,'next','print label (pack-and-ship)') || wms__pack_view(sh.id);
end $$;

-- ---------------------------------------------------------------------------
-- RULE 3: held orders are skipped when building new pick work
-- (wms_create_pick_session + wms_hyper_next_session, otherwise unchanged from 003)
-- ---------------------------------------------------------------------------
create or replace function wms_create_pick_session(
  p_method     pick_method,
  p_order_ids  uuid[],
  p_cart_id    uuid default null,
  p_zone_id    uuid default null,
  p_assign_to  uuid default null,
  p_route      route_strategy default null,
  p_wave_id    uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff   uuid := wms__require_staff();
  v_wh      uuid;
  v_route   route_strategy;
  v_session uuid;
  v_count   int;
  v_cart    carts;
  ln        record;
  bn        record;
  v_need    int;
  v_take    int;
  v_tasks   int;
  v_short   jsonb := '[]'::jsonb;
  v_held    jsonb;
begin
  -- RULE 3: orders on hold never start a new pick (reported back in 'skipped_on_hold')
  v_held := wms__held_orders(p_order_ids);
  select array_agg(u.id order by u.ord) into p_order_ids
    from unnest(p_order_ids) with ordinality u(id, ord)
   where not exists (select 1 from orders o where o.id = u.id and o.is_held);
  v_count := coalesce(array_length(p_order_ids, 1), 0);
  if v_count = 0 then raise exception 'NO_ORDERS: none left after removing orders on hold (%)', v_held::text; end if;
  if p_method = 'discrete' and v_count <> 1 then raise exception 'DISCRETE_NEEDS_ONE_ORDER'; end if;
  if p_method = 'zone' and p_zone_id is null then raise exception 'ZONE_REQUIRED'; end if;

  select min(warehouse_id::text)::uuid, count(distinct warehouse_id) into v_wh, v_count
    from orders where id = any(p_order_ids);
  if v_count <> 1 then raise exception 'ORDERS_MUST_SHARE_ONE_WAREHOUSE'; end if;

  if exists (select 1 from orders where id = any(p_order_ids)
              and status not in ('awaiting_pick','allocated','picking')) then
    raise exception 'ORDER_NOT_PICKABLE: one or more orders are not awaiting pick';
  end if;

  if p_cart_id is not null then
    select * into v_cart from carts where id = p_cart_id and is_active;
    if not found then raise exception 'CART_NOT_FOUND'; end if;
    if p_method <> 'batch' and v_cart.basket_count < array_length(p_order_ids,1) then
      raise exception 'CART_TOO_SMALL: % orders, % baskets', array_length(p_order_ids,1), v_cart.basket_count;
    end if;
  end if;

  select coalesce(p_route, default_route) into v_route from warehouses where id = v_wh;

  insert into pick_sessions(warehouse_id, method, status, route, zone_id, wave_id, cart_id, assigned_to, created_by)
  values (v_wh, p_method, case when p_assign_to is null then 'draft'::session_status else 'assigned'::session_status end,
          v_route, p_zone_id, p_wave_id, p_cart_id, p_assign_to, v_staff)
  returning id into v_session;

  -- orders -> baskets (input order = basket order). batch = no baskets.
  insert into pick_session_orders(session_id, order_id, basket_id)
  select v_session, o.oid,
         case when p_cart_id is null or p_method = 'batch' then null
              else (select b.id from cart_baskets b where b.cart_id = p_cart_id and b.position = o.ord) end
    from unnest(p_order_ids) with ordinality as o(oid, ord);

  -- ---- allocate stock line by line (priority, then oldest) --------------
  if to_regclass('pg_temp._alloc') is not null then drop table _alloc; end if;
  create temp table _alloc (
    order_line_id uuid, order_id uuid, bin_id uuid, product_id uuid, qty int, prio int, seq bigint
  ) on commit drop;

  for ln in
    select ol.id, ol.order_id, ol.product_id, ol.sku, ol.qty_ordered - ol.qty_allocated as remaining,
           o.priority, o.ordered_at
      from order_lines ol join orders o on o.id = ol.order_id
     where ol.order_id = any(p_order_ids) and ol.qty_allocated < ol.qty_ordered
     order by o.priority, o.ordered_at nulls last, ol.id
  loop
    if ln.product_id is null then
      v_short := v_short || jsonb_build_object('order_id',ln.order_id,'sku',ln.sku,'short',ln.remaining,'reason','UNKNOWN_SKU');
      continue;
    end if;
    v_need := ln.remaining;
    for bn in
      select bi.bin_id, bi.qty_on_hand - bi.qty_allocated as avail
        from bin_inventory bi join bins b on b.id = bi.bin_id
       where bi.product_id = ln.product_id and b.warehouse_id = v_wh and b.is_pickable
         and (p_zone_id is null or b.zone_id = p_zone_id)
         and bi.qty_on_hand - bi.qty_allocated > 0
       order by (b.location_type = 'pick') desc,            -- pick faces before overstock
                bi.qty_on_hand - bi.qty_allocated >= v_need desc, -- prefer one bin that covers it all
                b.row_seq, b.shelf_seq, b.bin_seq
       for update of bi
    loop
      exit when v_need <= 0;
      v_take := least(v_need, bn.avail);
      update bin_inventory set qty_allocated = qty_allocated + v_take, updated_at = now()
       where bin_id = bn.bin_id and product_id = ln.product_id;
      insert into _alloc values (ln.id, ln.order_id, bn.bin_id, ln.product_id, v_take, ln.priority, 0);
      v_need := v_need - v_take;
    end loop;
    update order_lines set qty_allocated = qty_allocated + (ln.remaining - v_need) where id = ln.id;
    if v_need > 0 and p_zone_id is null then
      v_short := v_short || jsonb_build_object('order_id',ln.order_id,'sku',ln.sku,'short',v_need,'reason','NO_STOCK');
    end if;
  end loop;

  -- ---- route: one task per (bin, product), ordered by snake/zigzag key ----
  with stops as (
    select a.bin_id, a.product_id, sum(a.qty) as qty,
           b.row_seq, b.shelf_seq, b.shelf_side, b.bin_seq
      from _alloc a join bins b on b.id = a.bin_id
     group by a.bin_id, a.product_id, b.row_seq, b.shelf_seq, b.shelf_side, b.bin_seq
  ), visited as (
    select s.*, dense_rank() over (order by s.row_seq) as visit_idx from stops s
  ), keyed as (
    select v.*, wms_route_key(v_route, v.visit_idx::int, v.row_seq, v.shelf_seq, v.shelf_side, v.bin_seq) as k
      from visited v
  )
  insert into pick_tasks(session_id, sequence, bin_id, product_id, qty_required)
  select v_session, row_number() over (order by k, product_id), bin_id, product_id, qty
    from keyed;
  get diagnostics v_tasks = row_count;

  if v_tasks = 0 then
    raise exception 'NOTHING_TO_PICK: no stock could be allocated (%)', v_short::text;
  end if;

  insert into pick_allocations(task_id, order_line_id, order_id, basket_id, qty, fill_order)
  select t.id, a.order_line_id, a.order_id, pso.basket_id, a.qty,
         row_number() over (partition by t.id order by a.prio, a.order_id)
    from _alloc a
    join pick_tasks t on t.session_id = v_session and t.bin_id = a.bin_id and t.product_id = a.product_id
    join pick_session_orders pso on pso.session_id = v_session and pso.order_id = a.order_id;

  -- orders with nothing allocated in this session are removed from it
  delete from pick_session_orders pso
   where pso.session_id = v_session
     and not exists (select 1 from pick_allocations pa join pick_tasks t on t.id = pa.task_id
                      where t.session_id = v_session and pa.order_id = pso.order_id);

  update orders set status = 'allocated'
   where id in (select order_id from pick_session_orders where session_id = v_session)
     and status = 'awaiting_pick';

  return jsonb_build_object('session_id', v_session, 'tasks', v_tasks,
    'orders', (select count(*) from pick_session_orders where session_id = v_session),
    'shortages', v_short, 'skipped_on_hold', v_held);
end $$;

create or replace function wms_hyper_next_session(
  p_cart_barcode text, p_device_id uuid default null,
  p_max_orders int default null, p_zone_id uuid default null, p_pool int default 300
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := wms__require_staff();
  v_cart carts; v_max int; v_rows int[] := '{}'; v_chosen uuid[] := '{}'; v_pick record; v_res jsonb;
begin
  select * into v_cart from carts where (barcode = trim(p_cart_barcode) or code = trim(p_cart_barcode)) and is_active;
  if not found then raise exception 'CART_NOT_FOUND'; end if;
  if exists (select 1 from pick_sessions where cart_id = v_cart.id and status in ('assigned','in_progress')) then
    raise exception 'CART_BUSY';
  end if;
  v_max := least(coalesce(p_max_orders, v_cart.basket_count), v_cart.basket_count);

  -- candidate orders: fully pickable now, with the set of rows they would visit
  if to_regclass('pg_temp._cand') is not null then drop table _cand; end if;
  create temp table _cand on commit drop as
  select o.id, o.priority, o.ordered_at,
         array_agg(distinct best.row_seq) as rows_needed
    from orders o
    join order_lines ol on ol.order_id = o.id
    join lateral (
      select b.row_seq from bin_inventory bi join bins b on b.id = bi.bin_id
       where bi.product_id = ol.product_id and b.is_pickable and b.warehouse_id = v_cart.warehouse_id
         and (p_zone_id is null or b.zone_id = p_zone_id)
         and bi.qty_on_hand - bi.qty_allocated >= ol.qty_ordered - ol.qty_allocated
       order by (b.location_type = 'pick') desc, b.row_seq, b.shelf_seq limit 1) best on true
   where o.status = 'awaiting_pick' and o.warehouse_id = v_cart.warehouse_id
     and not o.is_held
     and ol.qty_allocated < ol.qty_ordered
   group by o.id, o.priority, o.ordered_at
  having count(*) = (select count(*) from order_lines x where x.order_id = o.id and x.qty_allocated < x.qty_ordered)
   order by o.priority, o.ordered_at nulls last
   limit p_pool;

  -- seed with the most urgent order, then add whichever adds the fewest new rows
  while coalesce(array_length(v_chosen,1),0) < v_max loop
    select c.id, c.rows_needed,
           (select count(*) from unnest(c.rows_needed) r where not (r = any(v_rows))) as new_rows
      into v_pick
      from _cand c where not (c.id = any(v_chosen))
     order by case when coalesce(array_length(v_chosen,1),0) = 0 then 0
                   else (select count(*) from unnest(c.rows_needed) r where not (r = any(v_rows))) end,
              c.priority, c.ordered_at nulls last
     limit 1;
    exit when not found;
    v_chosen := v_chosen || v_pick.id;
    v_rows := array(select distinct unnest(v_rows || v_pick.rows_needed));
  end loop;

  if coalesce(array_length(v_chosen,1),0) = 0 then
    return jsonb_build_object('ok',false,'error','NO_WORK');
  end if;

  v_res := wms_create_pick_session(
             case when array_length(v_chosen,1) = 1 then 'discrete'::pick_method else 'hyper'::pick_method end,
             v_chosen, v_cart.id, p_zone_id, v_staff, null, null);
  return jsonb_build_object('ok',true,'rows_visited',array_length(v_rows,1),'created',v_res,
           'current', wms_start_pick_session((v_res->>'session_id')::uuid, null, p_device_id));
end $$;

-- ---------------------------------------------------------------------------
-- Permissions for the new / replaced functions
-- ---------------------------------------------------------------------------
revoke execute on function wms__setting(uuid, text)                     from public, anon, authenticated;
revoke execute on function wms__held_orders(uuid[])                     from public, anon, authenticated;
revoke execute on function wms__pack_close(uuid, uuid, int, numeric, numeric, numeric) from public, anon, authenticated;
revoke execute on function wms_set_order_hold(uuid, boolean, text)      from public, anon;
revoke execute on function wms_pick_scan(uuid, text, uuid, int)         from public, anon;
revoke execute on function wms_pack_start(text, uuid, uuid, boolean)    from public, anon;
revoke execute on function wms_pack_scan(uuid, text, uuid)              from public, anon;
revoke execute on function wms_pack_complete(uuid, uuid, int, numeric, numeric, numeric) from public, anon;
revoke execute on function wms_get_current_task(uuid)                   from public, anon;
grant execute on function wms_set_order_hold(uuid, boolean, text)      to authenticated;
grant execute on function wms_pick_scan(uuid, text, uuid, int)         to authenticated;
grant execute on function wms_pack_start(text, uuid, uuid, boolean)    to authenticated;
