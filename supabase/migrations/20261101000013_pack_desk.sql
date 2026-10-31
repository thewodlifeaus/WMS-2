-- =============================================================================
-- TWL WMS | Migration 013 | Pack desk (Windows PCs, Chrome, USB scale, label printer)
--   * pack desks twldesk2-8 (same names as SkuVault) locked per computer
--   * "pack without WMS pick": while SkuVault/paper still does the picking, the
--     desk can pack straight from the order number. Each scan counts as the pick
--     too and takes the unit out of the fullest pick bin. Switch OFF at cutover.
--   * label results recorded for browser printing (no PrintNode)
-- =============================================================================

alter table pack_stations add column if not exists name text;
alter table pack_stations add column if not exists is_active boolean not null default true;
alter table shipments add column if not exists weight_source text
  check (weight_source in ('scale','manual','estimate'));
alter table shipments add column if not exists test_label boolean not null default false;
alter table shipments add column if not exists printed_at timestamptz;

-- desks: same names SkuVault used
insert into pack_stations(warehouse_id, code, name, label_format)
select w.id, 'twldesk' || g, 'Desk ' || g, 'pdf'
  from warehouses w, generate_series(2, 8) g where w.code = 'TWLHQ'
on conflict (code) do nothing;

-- every warehouse gets an explicit value (missing keys default to TRUE in wms__setting)
update warehouses set settings = settings || jsonb_build_object('pack_without_pick', code = 'TWLHQ')
 where not settings ? 'pack_without_pick';

create or replace function wms__pack_without_pick(p_warehouse uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select (settings->>'pack_without_pick')::boolean from warehouses where id = p_warehouse), false)
$$;

-- pack view: remaining = still to scan for the order; adds label + weight info
create or replace function wms__pack_view(p_shipment_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'shipment_id', sh.id, 'status', sh.status, 'weight_grams', sh.weight_grams, 'weight_source', sh.weight_source,
    'tracking_number', sh.tracking_number, 'last_error', sh.last_error, 'test_label', sh.test_label,
    'order', jsonb_build_object('id', o.id, 'order_number', o.order_number, 'customer', o.customer_name,
                                'requested_service', o.requested_service, 'is_held', o.is_held,
                                'hold_reason', o.hold_reason,
                                'city', o.ship_to->>'city_locality', 'state', o.ship_to->>'state_province',
                                'country', o.ship_to->>'country_code'),
    'lines', (select jsonb_agg(jsonb_build_object(
                 'order_line_id', l.id, 'sku', l.sku, 'name', coalesce(p.name, l.name),
                 'variant', p.variant_title, 'image_url', p.image_url,
                 'qty_ordered', l.qty_ordered, 'qty_picked', l.qty_picked, 'qty_packed', l.qty_packed,
                 'remaining', l.qty_ordered - l.qty_packed) order by (l.qty_ordered - l.qty_packed) = 0, l.sku)
                from order_lines l left join products p on p.id = l.product_id where l.order_id = o.id),
    'units_total', (select sum(qty_ordered) from order_lines where order_id = o.id),
    'units_packed', (select sum(qty_packed) from order_lines where order_id = o.id),
    'complete', not exists (select 1 from order_lines l where l.order_id = o.id and l.qty_packed < l.qty_ordered))
  from shipments sh join orders o on o.id = sh.order_id where sh.id = p_shipment_id
$$;

-- start packing: tote/basket, order number (with or without #)
create or replace function wms_pack_start(
  p_scan text, p_pack_station_id uuid default null, p_device_id uuid default null,
  p_override_hold boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); v_order orders; v_ship uuid; v_ok_status order_status[];
begin
  select o.* into v_order
    from cart_baskets cb
    join pick_session_orders pso on pso.basket_id = cb.id
    join pick_sessions s on s.id = pso.session_id
    join orders o on o.id = pso.order_id
   where cb.barcode = upper(trim(p_scan)) and o.status in ('picked','packing')
   order by s.completed_at desc nulls last limit 1;

  if v_order.id is null then
    select * into v_order from orders where order_number = ltrim(trim(p_scan), '#');
  end if;
  if v_order.id is null then return jsonb_build_object('ok',false,'error','ORDER_NOT_FOUND'); end if;

  v_ok_status := case when wms__pack_without_pick(v_order.warehouse_id)
                      then array['awaiting_pick','allocated','picked','packing','on_hold']::order_status[]
                      else array['picked','packing']::order_status[] end;
  if v_order.status in ('packed','shipped') then
    return jsonb_build_object('ok',false,'error','ALREADY_PACKED','order_number',v_order.order_number,
      'status',v_order.status,
      'shipment_id',(select id from shipments where order_id = v_order.id order by started_at desc limit 1));
  end if;
  if v_order.status = 'cancelled' then
    return jsonb_build_object('ok',false,'error','ORDER_CANCELLED','alarm',true,'order_number',v_order.order_number);
  end if;
  if not (v_order.status = any (v_ok_status)) then
    return jsonb_build_object('ok',false,'error','ORDER_NOT_READY','status',v_order.status,'order_number',v_order.order_number);
  end if;

  if (v_order.is_held or v_order.status = 'on_hold') and not p_override_hold and wms__setting(v_order.warehouse_id, 'warn_on_hold') then
    return jsonb_build_object('ok',false,'error','ORDER_ON_HOLD','alarm',true,
      'order_number',v_order.order_number,'reason',v_order.hold_reason,
      'hint','Confirm with a supervisor, then start again with override');
  end if;

  select id into v_ship from shipments where order_id = v_order.id and status = 'packing';
  if v_ship is null then
    insert into shipments(order_id, pack_station_id, packed_by, status, carrier_id, service_code)
    values (v_order.id, p_pack_station_id, v_staff, 'packing', v_order.carrier_id, v_order.service_code)
    returning id into v_ship;
  else
    update shipments set pack_station_id = coalesce(p_pack_station_id, pack_station_id), packed_by = v_staff where id = v_ship;
  end if;
  update orders set status = 'packing' where id = v_order.id;
  return jsonb_build_object('ok',true,
           'warnings', case when v_order.is_held then jsonb_build_array(jsonb_build_object(
                         'type','ORDER_ON_HOLD','order_number',v_order.order_number,'reason',v_order.hold_reason))
                       else '[]'::jsonb end) || wms__pack_view(v_ship);
end $$;

-- every unit scanned; in pack-without-pick mode the scan is also the pick
create or replace function wms_pack_scan(p_shipment_id uuid, p_barcode text, p_device_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); sh shipments; v_prod uuid; v_units int; l order_lines;
        v_wh uuid; v_np boolean; v_bin uuid; v_complete boolean; v_closed boolean := false; v_warn jsonb := '[]';
begin
  select * into sh from shipments where id = p_shipment_id for update;
  if sh.status <> 'packing' then return jsonb_build_object('ok',false,'error','SHIPMENT_CLOSED'); end if;
  select warehouse_id into v_wh from orders where id = sh.order_id;
  v_np := wms__pack_without_pick(v_wh);

  select product_id, units_per_scan into v_prod, v_units from product_barcodes where barcode = trim(p_barcode);
  if v_prod is null then
    select id, 1 into v_prod, v_units from products where sku = trim(p_barcode);   -- SKU label also accepted
  end if;
  if v_prod is null then
    perform wms__log_scan('pack','unknown_barcode',p_barcode,null,null,null,null,sh.id,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','UNKNOWN_BARCODE','alarm',true) || wms__pack_view(sh.id);
  end if;

  select * into l from order_lines
   where order_id = sh.order_id and product_id = v_prod
   order by (qty_ordered - qty_packed) desc limit 1 for update;
  if l.id is null then
    perform wms__log_scan('pack','wrong_item',p_barcode,null,v_prod,null,null,sh.id,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','NOT_IN_ORDER','alarm',true,
                              'scanned_sku',(select sku from products where id = v_prod)) || wms__pack_view(sh.id);
  end if;
  if l.qty_packed + v_units > (case when v_np then l.qty_ordered else l.qty_picked end) then
    perform wms__log_scan('pack','over_qty',p_barcode,v_prod,v_prod,null,null,sh.id,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','ALREADY_PACKED','alarm',true,'sku',l.sku) || wms__pack_view(sh.id);
  end if;

  if v_np and l.qty_picked < l.qty_packed + v_units then
    -- the scan is the pick: take it from the fullest pickable bin
    select bi.bin_id into v_bin from bin_inventory bi join bins b on b.id = bi.bin_id
     where bi.product_id = v_prod and b.is_pickable and bi.qty_on_hand >= v_units
     order by bi.qty_on_hand desc limit 1;
    if v_bin is null then
      select bi.bin_id into v_bin from bin_inventory bi where bi.product_id = v_prod and bi.qty_on_hand >= v_units
       order by bi.qty_on_hand desc limit 1;
    end if;
    if v_bin is not null then
      perform wms__apply_delta(v_bin, v_prod, -v_units, 'pick', 'shipment', sh.id, v_staff, p_device_id);
    else
      v_warn := jsonb_build_array(jsonb_build_object('type','NO_STOCK_RECORDED','sku',l.sku,
                  'message','WMS shows no stock for this item. Packed anyway; check the count.'));
    end if;
    update order_lines set qty_allocated = greatest(qty_allocated, qty_packed + v_units),
                           qty_picked = qty_packed + v_units where id = l.id;
  end if;

  update order_lines set qty_packed = qty_packed + v_units where id = l.id;
  insert into shipment_items(shipment_id, order_line_id, qty) values (sh.id, l.id, v_units)
  on conflict (shipment_id, order_line_id) do update set qty = shipment_items.qty + excluded.qty;
  perform wms__log_scan('pack','ok',p_barcode,v_prod,v_prod,null,null,sh.id,v_staff,p_device_id);

  v_complete := not exists (select 1 from order_lines where order_id = sh.order_id and qty_packed < qty_ordered);
  if v_complete and wms__setting(v_wh, 'pack_auto_close') then
    perform wms__pack_close(sh.id, null, null, null, null, null);
    update shipments set weight_source = 'estimate' where id = sh.id;
    v_closed := true;
  end if;

  return jsonb_build_object('ok',true,'sku',l.sku,'auto_closed',v_closed,'warnings',v_warn) || wms__pack_view(sh.id);
end $$;

-- set the scale (or typed) weight just before the label is bought
create or replace function wms_pack_set_weight(p_shipment_id uuid, p_weight_grams int, p_source text default 'scale')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); sh shipments;
begin
  select * into sh from shipments where id = p_shipment_id for update;
  if sh.status not in ('packed','failed') then return jsonb_build_object('ok',false,'error','NOT_READY','status',sh.status); end if;
  if p_weight_grams is null or p_weight_grams < 1 or p_weight_grams > 30000 then
    return jsonb_build_object('ok',false,'error','BAD_WEIGHT');
  end if;
  update shipments set weight_grams = p_weight_grams,
         weight_source = case when p_source in ('scale','manual') then p_source else 'manual' end
   where id = sh.id;
  return jsonb_build_object('ok',true) || wms__pack_view(sh.id);
end $$;

-- browser confirms the label was sent to the printer
create or replace function wms_mark_printed(p_shipment_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform wms__require_staff();
  update shipments set printed_at = now(),
         status = case when status = 'label_created' then 'shipped'::shipment_status else status end,
         shipped_at = coalesce(shipped_at, now())
   where id = p_shipment_id and status in ('label_created','shipped');
end $$;

-- label result from the pack-and-ship edge function (service role only)
drop function if exists wms_record_label(uuid, boolean, text, text, text, text, numeric, text, text, bigint, text);
create or replace function wms_record_label(
  p_shipment_id uuid, p_ok boolean, p_ss_shipment_id text default null, p_label_id text default null,
  p_tracking text default null, p_label_url text default null, p_cost numeric default null,
  p_carrier_id text default null, p_service_code text default null,
  p_test boolean default false, p_error text default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_order uuid;
begin
  if p_ok then
    update shipments set status = 'label_created',
      shipstation_shipment_id = p_ss_shipment_id, shipstation_label_id = p_label_id,
      tracking_number = p_tracking, label_url = p_label_url, shipment_cost = p_cost, test_label = p_test,
      carrier_id = coalesce(p_carrier_id, carrier_id), service_code = coalesce(p_service_code, service_code),
      labelled_at = now(), attempt_count = attempt_count + 1, last_error = null
    where id = p_shipment_id returning order_id into v_order;
    update orders set status = 'shipped' where id = v_order;
  else
    update shipments set status = 'failed', attempt_count = attempt_count + 1, last_error = p_error
     where id = p_shipment_id;
  end if;
end $$;

-- desks for the setup screen
create or replace function wms_pack_desks() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', ps.id, 'code', ps.code, 'name', coalesce(ps.name, ps.code),
           'warehouse', w.code) order by ps.code), '[]')
    from pack_stations ps join warehouses w on w.id = ps.warehouse_id
   where ps.is_active and wms_is_staff()
$$;

revoke execute on function wms__pack_without_pick(uuid) from public, anon, authenticated;
revoke execute on function wms__pack_view(uuid) from public, anon, authenticated;
revoke execute on function wms_record_label(uuid, boolean, text, text, text, text, numeric, text, text, boolean, text) from public, anon, authenticated;
revoke execute on function wms_pack_set_weight(uuid, int, text) from public, anon;
revoke execute on function wms_mark_printed(uuid) from public, anon;
revoke execute on function wms_pack_desks() from public, anon;
grant execute on function wms_record_label(uuid, boolean, text, text, text, text, numeric, text, text, boolean, text) to service_role;
grant execute on function wms_pack_set_weight(uuid, int, text) to authenticated;
grant execute on function wms_mark_printed(uuid) to authenticated;
grant execute on function wms_pack_desks() to authenticated;
grant execute on function wms_pack_start(text, uuid, uuid, boolean) to authenticated;
grant execute on function wms_pack_scan(uuid, text, uuid) to authenticated;

-- ShipStation orders into the WMS every 5 minutes (read only while SkuVault is live)
select cron.schedule('wms-shipstation-orders', '*/5 * * * *', $cron$
  select net.http_post(
    url := 'https://nklbnykqftzkbqbuammg.supabase.co/functions/v1/sync-shipstation-orders',
    headers := jsonb_build_object('Content-Type','application/json',
                                  'x-cron-secret', (select value from public.app_secrets where name = 'cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 120000)
$cron$);
