-- =============================================================================
-- TWL WMS  |  Migration 004  |  Scan-to-pack, label hooks, reporting, security
-- =============================================================================

-- ---------------------------------------------------------------------------
-- SCAN-TO-PACK
-- ---------------------------------------------------------------------------
create or replace function wms__pack_view(p_shipment_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'shipment_id', sh.id, 'status', sh.status,
    'order', jsonb_build_object('id', o.id, 'order_number', o.order_number, 'customer', o.customer_name,
                                'requested_service', o.requested_service, 'ship_to', o.ship_to),
    'lines', (select jsonb_agg(jsonb_build_object(
                 'order_line_id', l.id, 'sku', l.sku, 'name', l.name, 'image_url', p.image_url,
                 'qty_ordered', l.qty_ordered, 'qty_picked', l.qty_picked, 'qty_packed', l.qty_packed,
                 'remaining', l.qty_picked - l.qty_packed) order by l.sku)
                from order_lines l left join products p on p.id = l.product_id where l.order_id = o.id),
    'complete', not exists (select 1 from order_lines l where l.order_id = o.id and l.qty_packed < l.qty_ordered))
  from shipments sh join orders o on o.id = sh.order_id where sh.id = p_shipment_id
$$;

-- scan a basket barcode OR an order number / packing-slip barcode
create or replace function wms_pack_start(
  p_scan text, p_pack_station_id uuid default null, p_device_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); v_order orders; v_ship uuid;
begin
  -- basket -> the order in it from the most recent session using that basket
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

  select id into v_ship from shipments where order_id = v_order.id and status = 'packing';
  if v_ship is null then
    insert into shipments(order_id, pack_station_id, packed_by, status, carrier_id, service_code)
    values (v_order.id, p_pack_station_id, v_staff, 'packing', v_order.carrier_id, v_order.service_code)
    returning id into v_ship;
  end if;
  update orders set status = 'packing' where id = v_order.id;
  return jsonb_build_object('ok',true) || wms__pack_view(v_ship);
end $$;

create or replace function wms_pack_scan(p_shipment_id uuid, p_barcode text, p_device_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); sh shipments; v_prod uuid; v_units int; l order_lines;
begin
  select * into sh from shipments where id = p_shipment_id for update;
  if sh.status <> 'packing' then return jsonb_build_object('ok',false,'error','SHIPMENT_CLOSED'); end if;

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
  return jsonb_build_object('ok',true,'sku',l.sku) || wms__pack_view(sh.id);
end $$;

-- close the box: all units scanned + weight/dims captured -> ready for label
create or replace function wms_pack_complete(
  p_shipment_id uuid, p_package_type_id uuid default null, p_weight_grams int default null,
  p_length_cm numeric default null, p_width_cm numeric default null, p_height_cm numeric default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); sh shipments; pt package_types; v_weight int;
begin
  select * into sh from shipments where id = p_shipment_id for update;
  if sh.status <> 'packing' then return jsonb_build_object('ok',false,'error','SHIPMENT_CLOSED'); end if;
  if exists (select 1 from order_lines where order_id = sh.order_id and qty_packed < qty_ordered) then
    return jsonb_build_object('ok',false,'error','NOT_ALL_ITEMS_SCANNED') || wms__pack_view(sh.id);
  end if;
  select * into pt from package_types where id = p_package_type_id;

  -- fall back to product weights + packaging tare when there is no scale reading
  select coalesce(p_weight_grams,
                  sum(si.qty * coalesce(p.weight_grams, 0)) + coalesce(pt.tare_grams, 0))::int
    into v_weight
    from shipment_items si join order_lines l on l.id = si.order_line_id
    left join products p on p.id = l.product_id
   where si.shipment_id = sh.id;

  update shipments set status = 'packed', packed_at = now(), package_type_id = pt.id,
         weight_grams = greatest(v_weight, 1),
         length_cm = coalesce(p_length_cm, pt.length_cm), width_cm = coalesce(p_width_cm, pt.width_cm),
         height_cm = coalesce(p_height_cm, pt.height_cm)
   where id = sh.id;
  update orders set status = 'packed' where id = sh.order_id;
  return jsonb_build_object('ok',true,'next','call edge function pack-and-ship') || wms__pack_view(sh.id);
end $$;

-- called ONLY by the pack-and-ship edge function (service_role)
create or replace function wms_record_label(
  p_shipment_id uuid, p_ok boolean, p_ss_shipment_id text default null, p_label_id text default null,
  p_tracking text default null, p_label_url text default null, p_cost numeric default null,
  p_carrier_id text default null, p_service_code text default null,
  p_printnode_job_id bigint default null, p_error text default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_order uuid;
begin
  if p_ok then
    update shipments set
      status = case when p_printnode_job_id is not null then 'shipped'::shipment_status else 'label_created'::shipment_status end,
      shipstation_shipment_id = p_ss_shipment_id, shipstation_label_id = p_label_id,
      tracking_number = p_tracking, label_url = p_label_url, shipment_cost = p_cost,
      carrier_id = coalesce(p_carrier_id, carrier_id), service_code = coalesce(p_service_code, service_code),
      printnode_job_id = p_printnode_job_id, labelled_at = now(),
      shipped_at = case when p_printnode_job_id is not null then now() end,
      attempt_count = attempt_count + 1, last_error = null
    where id = p_shipment_id returning order_id into v_order;
    update orders set status = 'shipped' where id = v_order;
  else
    update shipments set status = 'failed', attempt_count = attempt_count + 1, last_error = p_error
     where id = p_shipment_id;
  end if;
end $$;

-- let a supervisor retry a failed label
create or replace function wms_retry_shipment(p_shipment_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform wms__require_staff();
  update shipments set status = 'packed', last_error = null where id = p_shipment_id and status = 'failed';
end $$;

-- ---------------------------------------------------------------------------
-- REPORTING VIEWS  (security_invoker so RLS still applies)
-- ---------------------------------------------------------------------------
create or replace view v_product_stock with (security_invoker = true) as
select p.id as product_id, p.sku, p.name, p.velocity_class,
       coalesce(sum(bi.qty_on_hand) filter (where b.location_type = 'pick'), 0)     as on_hand_pick,
       coalesce(sum(bi.qty_on_hand) filter (where b.location_type = 'backfill'), 0) as on_hand_backfill,
       coalesce(sum(bi.qty_on_hand), 0)                                              as on_hand_total,
       coalesce(sum(bi.qty_allocated), 0)                                            as allocated,
       coalesce(sum(bi.qty_on_hand - bi.qty_allocated) filter (where b.is_pickable), 0) as available,
       count(distinct bi.bin_id) filter (where bi.qty_on_hand > 0)                   as bins_holding
  from products p
  left join bin_inventory bi on bi.product_id = p.id
  left join bins b on b.id = bi.bin_id
 group by p.id;

-- Reorder engine. RAG: RED projected <= safety stock | AMBER <= reorder point | GREEN above
create or replace view v_reorder_suggestions with (security_invoker = true) as
with on_order as (
  select l.product_id, sum(l.qty_ordered - l.qty_received) as qty
    from purchase_order_lines l join purchase_orders po on po.id = l.po_id
   where po.status in ('ordered','in_transit','partially_received') and l.product_id is not null
   group by l.product_id
), demand as (   -- open order units not yet allocated to a bin
  select ol.product_id, sum(ol.qty_ordered - ol.qty_allocated) as qty
    from order_lines ol join orders o on o.id = ol.order_id
   where o.status in ('awaiting_pick','allocated','picking','on_hold') and ol.product_id is not null
   group by ol.product_id
)
select s.product_id, s.sku, s.name, s.available, coalesce(oo.qty,0) as on_order, coalesce(d.qty,0) as unallocated_demand,
       s.available + coalesce(oo.qty,0) - coalesce(d.qty,0) as projected,
       pol.safety_stock, pol.reorder_point, pol.reorder_qty,
       case when s.available + coalesce(oo.qty,0) - coalesce(d.qty,0) <= pol.safety_stock then 'RED'
            when s.available + coalesce(oo.qty,0) - coalesce(d.qty,0) <= pol.reorder_point then 'AMBER'
            else 'GREEN' end as rag,
       case when s.available + coalesce(oo.qty,0) - coalesce(d.qty,0) <= pol.reorder_point
            then greatest(pol.reorder_qty,
                          pol.reorder_point + pol.safety_stock - (s.available + coalesce(oo.qty,0) - coalesce(d.qty,0)))
            else 0 end as suggested_order_qty
  from v_product_stock s
  join product_stock_policy pol on pol.product_id = s.product_id
  left join on_order oo on oo.product_id = s.product_id
  left join demand d on d.product_id = s.product_id;

-- Picker velocity & accuracy per person per day (Adelaide time)
create or replace view v_picker_daily with (security_invoker = true) as
with picks as (
  select staff_id, (occurred_at at time zone 'Australia/Adelaide')::date as day,
         sum(-qty_delta) as units, count(*) as pick_scans,
         min(occurred_at) as first_pick, max(occurred_at) as last_pick
    from inventory_transactions where txn_type = 'pick' group by 1, 2
), scans as (
  select staff_id, (occurred_at at time zone 'Australia/Adelaide')::date as day,
         count(*) filter (where result = 'ok') as ok_scans,
         count(*) filter (where result in ('wrong_item','wrong_bin','unknown_barcode','over_qty')) as error_scans
    from scan_events where context = 'pick' group by 1, 2
), sess as (
  select assigned_to as staff_id, (completed_at at time zone 'Australia/Adelaide')::date as day,
         count(*) as sessions, avg(extract(epoch from completed_at - started_at)/60)::numeric(8,1) as avg_session_mins,
         sum(extract(epoch from completed_at - started_at)/3600) as session_hours
    from pick_sessions where status = 'completed' and started_at is not null group by 1, 2
)
select st.display_name, p.staff_id, p.day, p.units, p.pick_scans, coalesce(se.sessions,0) as sessions,
       se.avg_session_mins,
       round(p.units / nullif(greatest(se.session_hours, extract(epoch from p.last_pick - p.first_pick)/3600), 0), 1)
         as units_per_hour,
       round(100.0 * sc.ok_scans / nullif(sc.ok_scans + sc.error_scans, 0), 2) as accuracy_pct,
       coalesce(sc.error_scans,0) as error_scans
  from picks p
  join staff st on st.id = p.staff_id
  left join scans sc on sc.staff_id = p.staff_id and sc.day = p.day
  left join sess se on se.staff_id = p.staff_id and se.day = p.day;

-- ABC velocity on pick frequency (last 90 days) + re-slotting hint
create or replace view v_velocity_abc with (security_invoker = true) as
with freq as (
  select product_id, count(*) as pick_lines, sum(-qty_delta) as units
    from inventory_transactions
   where txn_type = 'pick' and occurred_at > now() - interval '90 days'
   group by product_id
), ranked as (
  select f.*, sum(pick_lines) over (order by pick_lines desc, product_id) / nullif(sum(pick_lines) over (), 0) as cum_share
    from freq f
), home as (   -- main pick face for each product and how far back it is (0 = front, 1 = back)
  select distinct on (bi.product_id) bi.product_id, b.code as pick_bin,
         percent_rank() over (order by b.row_seq, b.shelf_seq) as depth
    from bin_inventory bi join bins b on b.id = bi.bin_id
   where b.location_type = 'pick'
   order by bi.product_id, bi.qty_on_hand desc
)
select p.id as product_id, p.sku, p.name, coalesce(r.pick_lines,0) as pick_lines_90d, coalesce(r.units,0) as units_90d,
       case when r.cum_share <= 0.80 then 'A' when r.cum_share <= 0.95 then 'B' else 'C' end as velocity_class,
       h.pick_bin, round(h.depth::numeric, 2) as bin_depth,
       case when r.cum_share <= 0.80 and h.depth > 0.5 then 'Move closer to dispatch'
            when (r.cum_share is null or r.cum_share > 0.95) and h.depth < 0.25 then 'Move further back (frees a prime bin)'
            else null end as reslot_hint
  from products p
  left join ranked r on r.product_id = p.id
  left join home h on h.product_id = p.id
 where p.is_active;

create or replace function wms_refresh_velocity_classes() returns int
language sql security definer set search_path = public as $$
  with u as (update products p set velocity_class = v.velocity_class
               from v_velocity_abc v where v.product_id = p.id and p.velocity_class is distinct from v.velocity_class
             returning 1)
  select count(*)::int from u;
$$;

-- ---------------------------------------------------------------------------
-- ROW LEVEL SECURITY
--   read:  any active staff member
--   write master data: admin / supervisor
--   stock, orders, picks, scans: ONLY via the wms_* functions above (or service_role)
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'staff','devices','warehouses','zones','aisle_rows','shelves','bins','products','product_barcodes',
    'product_stock_policy','bin_inventory','replenishment_rules','backfill_tasks','purchase_orders',
    'purchase_order_lines','waves','orders','order_lines','carts','cart_baskets','pick_sessions',
    'pick_session_orders','pick_tasks','pick_allocations','pack_stations','package_types','shipments',
    'shipment_items','inventory_transactions','scan_events','integration_log','sync_state']
  loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy %I on %I for select to authenticated using (wms_is_staff())', t || '_read', t);
  end loop;

  foreach t in array array[
    'devices','warehouses','zones','aisle_rows','shelves','bins','products','product_barcodes',
    'product_stock_policy','replenishment_rules','waves','carts','cart_baskets','pack_stations','package_types']
  loop
    execute format($p$create policy %I on %I for all to authenticated
                     using (wms_has_role(array['admin','supervisor']::staff_role[]))
                     with check (wms_has_role(array['admin','supervisor']::staff_role[]))$p$, t || '_manage', t);
  end loop;
end $$;

create policy staff_admin on staff for all to authenticated
  using (wms_has_role(array['admin']::staff_role[])) with check (wms_has_role(array['admin']::staff_role[]));
-- supervisors can re-prioritise, hold, or put orders into a wave
create policy orders_supervise on orders for update to authenticated
  using (wms_has_role(array['admin','supervisor']::staff_role[]))
  with check (wms_has_role(array['admin','supervisor']::staff_role[]));
create policy backfill_assign on backfill_tasks for update to authenticated
  using (wms_is_staff()) with check (wms_is_staff());

-- ---------------------------------------------------------------------------
-- FUNCTION PERMISSIONS
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
-- internal helpers + service-only hooks: not callable from the apps
revoke execute on function wms__apply_delta(uuid,uuid,int,txn_type,text,uuid,uuid,uuid,uuid,text,int) from authenticated;
revoke execute on function wms__log_scan(scan_context,scan_result,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid) from authenticated;
revoke execute on function wms__close_session_if_done(uuid) from authenticated;
revoke execute on function wms_record_label(uuid,boolean,text,text,text,text,numeric,text,text,bigint,text) from authenticated;
revoke execute on function wms_refresh_velocity_classes() from authenticated;

-- realtime: tablets subscribe to their sessions + backfill tasks
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table pick_sessions, pick_tasks, backfill_tasks, shipments;
  end if;
end $$;
