-- =============================================================================
-- TWL WMS  |  Migration 003  |  Pick sessions, routing, scan-to-pick
-- One builder serves every method:
--   discrete  1 order, optional tote
--   batch     many orders, one tote, sorted at the pack bench (no baskets)
--   cluster   many orders, 1 basket per order on a cart
--   wave      cluster sessions released from a wave (cart scanned at start)
--   zone      cluster restricted to one zone; the cart is passed zone to zone
--   hyper     the system picks the orders for you (wms_hyper_next_session)
-- =============================================================================

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
begin
  v_count := coalesce(array_length(p_order_ids, 1), 0);
  if v_count = 0 then raise exception 'NO_ORDERS'; end if;
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
    'shortages', v_short);
end $$;

-- ---------------------------------------------------------------------------
-- Start / claim a session on a tablet (assigns baskets if a cart is scanned)
-- ---------------------------------------------------------------------------
create or replace function wms_start_pick_session(
  p_session_id uuid, p_cart_barcode text default null, p_device_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); s pick_sessions; v_cart carts; v_n int;
begin
  select * into s from pick_sessions where id = p_session_id for update;
  if not found then raise exception 'SESSION_NOT_FOUND'; end if;
  if s.status not in ('draft','assigned','in_progress') then raise exception 'SESSION_CLOSED'; end if;
  if s.assigned_to is not null and s.assigned_to <> v_staff
     and not wms_has_role(array['admin','supervisor']::staff_role[]) then
    raise exception 'ASSIGNED_TO_SOMEONE_ELSE';
  end if;

  if p_cart_barcode is not null and s.cart_id is null then
    select * into v_cart from carts where (barcode = trim(p_cart_barcode) or code = trim(p_cart_barcode)) and is_active;
    if not found then raise exception 'CART_NOT_FOUND'; end if;
    select count(*) into v_n from pick_session_orders where session_id = s.id;
    if s.method <> 'batch' and v_cart.basket_count < v_n then raise exception 'CART_TOO_SMALL'; end if;
    update pick_sessions set cart_id = v_cart.id where id = s.id;
    if s.method <> 'batch' then
      with numbered as (
        select order_id, row_number() over (order by order_id) as pos
          from pick_session_orders where session_id = s.id
      )
      update pick_session_orders pso
         set basket_id = (select b.id from cart_baskets b where b.cart_id = v_cart.id and b.position = n.pos)
        from numbered n where pso.session_id = s.id and pso.order_id = n.order_id;
      update pick_allocations pa set basket_id = pso.basket_id
        from pick_tasks t, pick_session_orders pso
       where t.id = pa.task_id and t.session_id = s.id
         and pso.session_id = s.id and pso.order_id = pa.order_id;
    end if;
  end if;

  if s.method in ('cluster','wave','zone','hyper')
     and (select cart_id from pick_sessions where id = s.id) is null
     and (select count(*) from pick_session_orders where session_id = s.id) > 1 then
    raise exception 'SCAN_CART_FIRST';
  end if;

  update pick_sessions
     set status = 'in_progress', assigned_to = coalesce(assigned_to, v_staff),
         device_id = coalesce(p_device_id, device_id), started_at = coalesce(started_at, now())
   where id = s.id;
  update orders set status = 'picking'
   where id in (select order_id from pick_session_orders where session_id = s.id)
     and status in ('awaiting_pick','allocated');

  return wms_get_current_task(s.id);
end $$;

-- ---------------------------------------------------------------------------
-- What should the picker do now?  (the app calls this after every scan)
-- ---------------------------------------------------------------------------
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
                      'order_number', o.order_number, 'qty', pa.qty, 'qty_picked', pa.qty_picked)
                    order by pa.fill_order)
                     from pick_allocations pa
                     join orders o on o.id = pa.order_id
                     left join cart_baskets cb on cb.id = pa.basket_id
                    where pa.task_id = t.id)));
end $$;

-- optional: verify the picker is standing at the right bin
create or replace function wms_confirm_bin(p_task_id uuid, p_bin_barcode text, p_device_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); t pick_tasks; b bins;
begin
  select * into t from pick_tasks where id = p_task_id;
  select * into b from bins where id = t.bin_id;
  if trim(p_bin_barcode) in (b.barcode, b.code) then
    update pick_tasks set started_at = coalesce(started_at, now()) where id = t.id;
    return jsonb_build_object('ok', true, 'bin', b.code);
  end if;
  perform wms__log_scan('pick','wrong_bin',p_bin_barcode,t.product_id,null,t.session_id,t.id,null,v_staff,p_device_id);
  return jsonb_build_object('ok', false, 'error', 'WRONG_BIN', 'expected_bin', b.code, 'alarm', true);
end $$;

-- ---------------------------------------------------------------------------
-- SCAN-TO-PICK: the accuracy gate
-- ---------------------------------------------------------------------------
create or replace function wms__close_session_if_done(p_session_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from pick_tasks where session_id = p_session_id and status = 'pending') then
    return false;
  end if;
  update pick_sessions set status = 'completed', completed_at = now() where id = p_session_id;

  update orders o set
    status = case
      when not exists (select 1 from order_lines l where l.order_id = o.id and l.qty_picked < l.qty_ordered)
        then 'picked'::order_status
      when exists (select 1 from pick_session_orders x join pick_sessions s on s.id = x.session_id
                    where x.order_id = o.id and s.id <> p_session_id
                      and s.status in ('draft','assigned','in_progress'))
        then 'picking'::order_status
      else 'on_hold'::order_status end,
    hold_reason = case
      when exists (select 1 from order_lines l where l.order_id = o.id and l.qty_picked < l.qty_ordered)
       and not exists (select 1 from pick_session_orders x join pick_sessions s on s.id = x.session_id
                        where x.order_id = o.id and s.id <> p_session_id
                          and s.status in ('draft','assigned','in_progress'))
        then 'Short pick: not all units found' else o.hold_reason end
   where o.id in (select order_id from pick_session_orders where session_id = p_session_id);
  return true;
end $$;

create or replace function wms_pick_scan(
  p_task_id uuid, p_barcode text, p_device_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := wms__require_staff();
  t pick_tasks; s pick_sessions; v_current uuid;
  v_prod uuid; v_units int; v_left int; a record; v_put jsonb := '[]'::jsonb; v_take int;
  v_session_done boolean;
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

  if v_prod <> t.product_id then
    perform wms__log_scan('pick','wrong_item',p_barcode,t.product_id,v_prod,t.session_id,t.id,null,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','WRONG_ITEM','alarm',true,
      'expected_sku',(select sku from products where id = t.product_id),
      'scanned_sku',(select sku from products where id = v_prod));
  end if;

  if t.qty_picked + v_units > t.qty_required then
    perform wms__log_scan('pick','over_qty',p_barcode,t.product_id,v_prod,t.session_id,t.id,null,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','OVER_QTY','alarm',true,
      'remaining', t.qty_required - t.qty_picked);
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
  return jsonb_build_object('ok',true,'put_into',v_put,
    'task_done', t.qty_picked + v_units >= t.qty_required,
    'session_done', v_session_done,
    'next', wms_get_current_task(t.session_id));
end $$;

-- Picker can't find enough: release the rest, flag for a count, move on
create or replace function wms_pick_short(p_task_id uuid, p_device_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); t pick_tasks; v_unpicked int;
begin
  select * into t from pick_tasks where id = p_task_id for update;
  if t.status <> 'pending' then return jsonb_build_object('ok',false,'error','TASK_CLOSED'); end if;
  v_unpicked := t.qty_required - t.qty_picked;

  update order_lines ol set qty_allocated = ol.qty_allocated - (pa.qty - pa.qty_picked)
    from pick_allocations pa where pa.task_id = t.id and pa.order_line_id = ol.id and pa.qty > pa.qty_picked;
  update bin_inventory set qty_allocated = qty_allocated - v_unpicked, updated_at = now()
   where bin_id = t.bin_id and product_id = t.product_id;
  update pick_tasks set status = 'short', completed_at = now() where id = t.id;

  insert into inventory_transactions(txn_type, product_id, bin_id, qty_delta, ref_type, ref_id, staff_id, device_id, reason)
  values ('adjust', t.product_id, t.bin_id, 0, 'pick_task', t.id, v_staff, p_device_id,
          'SHORT PICK: ' || v_unpicked || ' not found - cycle count required');

  return jsonb_build_object('ok',true,'short',v_unpicked,
    'session_done', wms__close_session_if_done(t.session_id),
    'next', wms_get_current_task(t.session_id));
end $$;

-- ---------------------------------------------------------------------------
-- WAVES: tag orders, then release as cart-sized cluster sessions
-- ---------------------------------------------------------------------------
create or replace function wms_release_wave(p_wave_id uuid, p_orders_per_cart int default 12)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); v_ids uuid[]; v_sessions jsonb := '[]'; v_res jsonb; i int := 0;
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then raise exception 'FORBIDDEN'; end if;
  for v_ids in
    select array_agg(id order by priority, ordered_at)
      from (select id, priority, ordered_at,
                   (row_number() over (order by priority, ordered_at) - 1) / p_orders_per_cart as chunk
              from orders where wave_id = p_wave_id and status = 'awaiting_pick') x
     group by chunk order by chunk
  loop
    begin
      v_res := wms_create_pick_session('wave', v_ids, null, null, null, null, p_wave_id);
      v_sessions := v_sessions || v_res;
    exception when others then
      v_sessions := v_sessions || jsonb_build_object('error', sqlerrm, 'orders', to_jsonb(v_ids));
    end;
    i := i + 1;
  end loop;
  update waves set status = 'released', released_at = now() where id = p_wave_id;
  return jsonb_build_object('wave_id',p_wave_id,'sessions',v_sessions,'chunks',i);
end $$;

-- ---------------------------------------------------------------------------
-- HYPER PICKING: "give me work". Greedy clustering of open orders so the
-- cart visits as few rows as possible, then starts it for the caller.
-- ---------------------------------------------------------------------------
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
