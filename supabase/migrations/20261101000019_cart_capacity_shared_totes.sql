-- =============================================================================
-- TWL WMS | Migration 019 | Cart capacity: orders per cart OR pieces per tote
--   * Mode "orders":  one order per tote, N totes per cart
--   * Mode "pieces":  several orders may share a tote, up to P pieces per tote,
--                     N totes per cart (fewer carts, faster picking)
--   * An order is never split: it only goes onto a cart if ALL its units fit in
--     ONE tote on that cart (an order bigger than P pieces gets a tote to itself)
--   * Totes are scanned per tote "slot" when picking starts (SkuVault keeps no
--     fixed tote-to-cart list; checked 1 Nov 2026)
--   * Pack desk: scanning a shared tote lists its orders to choose from
-- =============================================================================

alter table pick_session_orders add column if not exists slot int;
alter table pick_session_orders drop constraint if exists pick_session_orders_session_id_basket_id_key;
create index if not exists pick_session_orders_basket_idx on pick_session_orders(basket_id);

-- the cart build below enforces its own limits; carts can carry up to 48 totes
update carts set basket_count = 48 where basket_count < 48;

-- order units (all lines) for capacity checks
create or replace function wms__order_units(p_order_id uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(qty_ordered), 0)::int from order_lines where order_id = p_order_id
$$;

drop function if exists wms_build_carts(uuid[], int, uuid[]);
create or replace function wms_build_carts(
  p_order_ids       uuid[],
  p_totes_per_cart  int default 12,      -- totes on each cart
  p_pieces_per_tote int default null,    -- null = one order per tote; a number = share totes up to this many pieces
  p_cart_ids        uuid[] default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff();
        v_ids uuid[]; v_units int[]; v_skipped jsonb; v_carts uuid[]; v_cart carts; v_cid uuid;
        v_used boolean[]; v_slot_units int[]; v_slot_of int[]; v_slots int; v_chunk uuid[]; v_chunk_slot int[];
        i int; j int; v_res jsonb; v_made jsonb := '[]'; v_failed jsonb := '[]'; v_left uuid[];
        v_mode text := case when p_pieces_per_tote is null then 'orders' else 'pieces' end;
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then
    raise exception 'FORBIDDEN: only admins and supervisors can build carts' using errcode = '42501';
  end if;
  if coalesce(p_totes_per_cart, 0) not between 1 and 48 then raise exception 'TOTES_PER_CART_1_TO_48'; end if;
  if p_pieces_per_tote is not null and p_pieces_per_tote < 1 then raise exception 'PIECES_PER_TOTE_AT_LEAST_1'; end if;

  -- ready orders only, express first then oldest
  select array_agg(o.id order by o.priority, o.ordered_at nulls last, o.order_number),
         array_agg(wms__order_units(o.id) order by o.priority, o.ordered_at nulls last, o.order_number)
    into v_ids, v_units
    from orders o where o.id = any(p_order_ids) and wms__order_ready(o) = 'ready';
  select coalesce(jsonb_agg(jsonb_build_object('order_number', o.order_number, 'reason', wms__order_ready(o))), '[]')
    into v_skipped from orders o where o.id = any(p_order_ids) and wms__order_ready(o) <> 'ready';
  if v_ids is null then return jsonb_build_object('ok', false, 'error', 'NO_READY_ORDERS', 'skipped', v_skipped); end if;

  select array_agg(c.id order by c.code like 'CART%' desc, c.code) into v_carts from carts c
   where c.is_active and (p_cart_ids is null or c.id = any(p_cart_ids))
     and not exists (select 1 from pick_sessions ps where ps.cart_id = c.id and ps.status in ('draft','assigned','in_progress'));
  if v_carts is null then return jsonb_build_object('ok', false, 'error', 'NO_FREE_CARTS'); end if;

  v_used := array_fill(false, array[array_length(v_ids, 1)]);

  foreach v_cid in array v_carts loop
    exit when not (false = any(v_used));
    select * into v_cart from carts where id = v_cid;
    v_slots := 0; v_slot_units := '{}'; v_chunk := '{}'; v_chunk_slot := '{}';

    -- fill this cart: walk the queue in priority order; an order goes in only if it fits whole
    for i in 1 .. array_length(v_ids, 1) loop
      continue when v_used[i];
      if v_mode = 'orders' then
        exit when v_slots >= p_totes_per_cart;
        v_slots := v_slots + 1; v_slot_units := v_slot_units || v_units[i];
        v_chunk := v_chunk || v_ids[i]; v_chunk_slot := v_chunk_slot || v_slots; v_used[i] := true;
      else
        j := null;
        if v_units[i] <= p_pieces_per_tote then   -- first tote with room for the whole order
          for k in 1 .. v_slots loop
            if v_slot_units[k] + v_units[i] <= p_pieces_per_tote then j := k; exit; end if;
          end loop;
        end if;
        if j is null and v_slots < p_totes_per_cart then   -- open a new tote (big orders always get their own)
          v_slots := v_slots + 1; v_slot_units := v_slot_units || 0; j := v_slots;
        end if;
        continue when j is null;                    -- does not fit on this cart: try the next cart
        v_slot_units[j] := v_slot_units[j] + v_units[i];
        v_chunk := v_chunk || v_ids[i]; v_chunk_slot := v_chunk_slot || j; v_used[i] := true;
      end if;
    end loop;
    continue when array_length(v_chunk, 1) is null;

    begin
      v_res := wms_create_pick_session('cluster', v_chunk, v_cart.id);
      update pick_session_orders pso set slot = s.slot
        from unnest(v_chunk, v_chunk_slot) as s(order_id, slot)
       where pso.session_id = (v_res->>'session_id')::uuid and pso.order_id = s.order_id;
      v_made := v_made || jsonb_build_object('cart', v_cart.code, 'session_id', v_res->'session_id',
                  'orders', v_res->'orders', 'stops', v_res->'tasks', 'shortages', v_res->'shortages',
                  'totes', (select count(distinct slot) from pick_session_orders where session_id = (v_res->>'session_id')::uuid),
                  'units', (select coalesce(sum(qty_required), 0) from pick_tasks where session_id = (v_res->>'session_id')::uuid));
    exception when others then
      v_failed := v_failed || jsonb_build_object('cart', v_cart.code, 'error', sqlerrm,
                    'orders', (select jsonb_agg(order_number) from orders where id = any(v_chunk)));
    end;
  end loop;

  select array_agg(v_ids[ix]) into v_left from generate_subscripts(v_ids, 1) ix where not v_used[ix];
  return jsonb_build_object('ok', jsonb_array_length(v_made) > 0, 'mode', v_mode, 'carts', v_made, 'failed', v_failed,
    'skipped', v_skipped, 'left_over', coalesce(array_length(v_left, 1), 0),
    'left_over_orders', (select jsonb_agg(order_number) from orders where id = any(v_left)));
end $$;

-- scan a physical tote for the next tote slot (shared slots get the same tote)
create or replace function wms_assign_totes(p_session_id uuid, p_tote_barcodes text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); r record; v_tote cart_baskets; i int := 0; v_out jsonb := '[]';
begin
  if (select status from pick_sessions where id = p_session_id) not in ('draft','assigned','in_progress') then
    return jsonb_build_object('ok',false,'error','SESSION_CLOSED');
  end if;
  for r in select coalesce(pso.slot::text, pso.order_id::text) as grp, min(pso.slot) as slot,
                  array_agg(pso.order_id) as order_ids, string_agg(o.order_number, ', ' order by o.order_number) as orders,
                  min(o.priority) as prio, min(o.ordered_at) as oldest
             from pick_session_orders pso join orders o on o.id = pso.order_id
            where pso.session_id = p_session_id and pso.basket_id is null
            group by 1 order by min(pso.slot) nulls last, min(o.priority), min(o.ordered_at) nulls last, min(o.order_number)
  loop
    i := i + 1;
    exit when i > coalesce(array_length(p_tote_barcodes, 1), 0);
    select * into v_tote from cart_baskets where upper(barcode) = upper(trim(p_tote_barcodes[i])) and is_active;
    if v_tote.id is null then
      return jsonb_build_object('ok',false,'error','UNKNOWN_TOTE','tote',p_tote_barcodes[i],'alarm',true);
    end if;
    if wms__tote_busy(v_tote.id) or exists (select 1 from pick_session_orders where session_id = p_session_id and basket_id = v_tote.id) then
      return jsonb_build_object('ok',false,'error','TOTE_IN_USE','tote',v_tote.barcode,'alarm',true);
    end if;
    update pick_session_orders set basket_id = v_tote.id where session_id = p_session_id and order_id = any(r.order_ids);
    update pick_allocations pa set basket_id = v_tote.id
      from pick_tasks t where t.id = pa.task_id and t.session_id = p_session_id and pa.order_id = any(r.order_ids);
    v_out := v_out || jsonb_build_object('orders', r.orders, 'tote', v_tote.barcode);
  end loop;
  return jsonb_build_object('ok',true,'assigned',v_out,
    'still_need', (select count(distinct coalesce(slot::text, order_id::text)) from pick_session_orders
                    where session_id = p_session_id and basket_id is null));
end $$;

-- picker screen state: tote slots instead of orders
create or replace function wms__pick_state(p_session_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'session_id', ps.id, 'cart', c.code, 'cart_barcode', c.barcode, 'status', ps.status,
    'paused', ps.paused_at is not null, 'all_picked', ps.all_picked_at is not null,
    'orders', (select count(*) from pick_session_orders where session_id = ps.id),
    'tote_slots', (select count(distinct coalesce(slot::text, order_id::text)) from pick_session_orders where session_id = ps.id),
    'units', (select coalesce(sum(qty_required), 0) from pick_tasks where session_id = ps.id),
    'picked', (select coalesce(sum(qty_picked), 0) from pick_tasks where session_id = ps.id),
    'need_totes', (select coalesce(jsonb_agg(g.orders order by g.slot nulls last, g.prio, g.oldest nulls last, g.orders), '[]') from (
                     select min(pso.slot) as slot, min(o.priority) as prio, min(o.ordered_at) as oldest,
                            string_agg('#' || o.order_number, ', ' order by o.order_number) as orders
                       from pick_session_orders pso join orders o on o.id = pso.order_id
                      where pso.session_id = ps.id and pso.basket_id is null
                      group by coalesce(pso.slot::text, pso.order_id::text)) g),
    'totes', (select coalesce(jsonb_agg(jsonb_build_object('tote', g.tote, 'orders', g.orders) order by g.tote), '[]') from (
                select cb.barcode as tote, string_agg('#' || o.order_number, ', ' order by o.order_number) as orders
                  from pick_session_orders pso join orders o on o.id = pso.order_id
                  join cart_baskets cb on cb.id = pso.basket_id where pso.session_id = ps.id group by cb.barcode) g),
    'exceptions', (select count(*) from pick_exceptions where session_id = ps.id),
    'current', wms_get_current_task(ps.id))
  from pick_sessions ps left join carts c on c.id = ps.cart_id where ps.id = p_session_id
$$;

-- cart detail: show tote slot per order
create or replace function wms_cart_detail(p_session_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not wms_is_staff() then null else jsonb_build_object(
    'session', (select jsonb_build_object('id', ps.id, 'cart', c.code, 'status', ps.status, 'route', ps.route,
                  'created_at', ps.created_at, 'started_at', ps.started_at, 'completed_at', ps.completed_at,
                  'created_by', (select display_name from staff where id = ps.created_by),
                  'picker', (select display_name from staff where id = ps.assigned_to),
                  'tote_slots', (select count(distinct coalesce(slot::text, order_id::text)) from pick_session_orders where session_id = ps.id))
                  from pick_sessions ps left join carts c on c.id = ps.cart_id where ps.id = p_session_id),
    'orders', (select coalesce(jsonb_agg(jsonb_build_object(
                  'order_number', o.order_number, 'customer', o.customer_name, 'service', o.requested_service,
                  'express', o.priority < 100, 'status', o.status, 'tote', cb.barcode, 'slot', pso.slot, 'is_held', o.is_held,
                  'units', (select sum(qty) from pick_allocations pa join pick_tasks t on t.id = pa.task_id
                             where t.session_id = p_session_id and pa.order_id = o.id),
                  'picked', (select sum(pa.qty_picked) from pick_allocations pa join pick_tasks t on t.id = pa.task_id
                              where t.session_id = p_session_id and pa.order_id = o.id))
                  order by pso.slot nulls last, cb.barcode nulls last, o.priority, o.ordered_at), '[]')
                 from pick_session_orders pso join orders o on o.id = pso.order_id
                 left join cart_baskets cb on cb.id = pso.basket_id where pso.session_id = p_session_id),
    'picks', (select coalesce(jsonb_agg(jsonb_build_object(
                  'seq', t.sequence, 'bin', b.code, 'row', ar.code, 'bin_type', b.location_type,
                  'sku', p.sku, 'name', p.name, 'variant', p.variant_title, 'image_url', p.image_url,
                  'qty', t.qty_required, 'picked', t.qty_picked, 'status', t.status,
                  'split', (select jsonb_agg(jsonb_build_object('order_number', o2.order_number, 'tote', cb2.barcode,
                                             'slot', (select slot from pick_session_orders x where x.session_id = p_session_id and x.order_id = o2.id),
                                             'qty', pa.qty) order by pa.fill_order)
                              from pick_allocations pa join orders o2 on o2.id = pa.order_id
                              left join cart_baskets cb2 on cb2.id = pa.basket_id where pa.task_id = t.id))
                  order by t.sequence), '[]')
                from pick_tasks t join bins b on b.id = t.bin_id
                left join shelves sh on sh.id = b.shelf_id left join aisle_rows ar on ar.id = sh.row_id
                join products p on p.id = t.product_id where t.session_id = p_session_id)
  ) end
$$;

-- pack desk: a shared tote lists its orders; the packer picks one (or scans its order number)
create or replace function wms_pack_start(
  p_scan text, p_pack_station_id uuid default null, p_device_id uuid default null,
  p_override_hold boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); v_order orders; v_ship uuid; v_ok_status order_status[];
        v_tote cart_baskets; v_session uuid; v_in_tote jsonb;
begin
  select * into v_tote from cart_baskets where upper(barcode) = upper(trim(p_scan));
  if v_tote.id is not null then
    -- the most recent session that used this tote
    select pso.session_id into v_session
      from pick_session_orders pso join pick_sessions s on s.id = pso.session_id join orders o on o.id = pso.order_id
     where pso.basket_id = v_tote.id and o.status in ('picked','packing')
     order by s.completed_at desc nulls last, s.created_at desc limit 1;
    select coalesce(jsonb_agg(jsonb_build_object('order_number', o.order_number, 'customer', o.customer_name,
                    'units', wms__order_units(o.id), 'status', o.status) order by o.order_number), '[]')
      into v_in_tote
      from pick_session_orders pso join orders o on o.id = pso.order_id
     where pso.session_id = v_session and pso.basket_id = v_tote.id and o.status in ('picked','packing');
    if jsonb_array_length(v_in_tote) > 1 then
      return jsonb_build_object('ok',false,'error','TOTE_HAS_ORDERS','tote',v_tote.barcode,'orders',v_in_tote);
    end if;
    select o.* into v_order
      from pick_session_orders pso join orders o on o.id = pso.order_id
     where pso.session_id = v_session and pso.basket_id = v_tote.id and o.status in ('picked','packing') limit 1;
  end if;

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

revoke execute on function wms__order_units(uuid) from public, anon, authenticated;
revoke execute on function wms_build_carts(uuid[], int, int, uuid[]) from public, anon;
grant execute on function wms_build_carts(uuid[], int, int, uuid[]) to authenticated;
grant execute on function wms_assign_totes(uuid, text[]) to authenticated;
grant execute on function wms_pack_start(text, uuid, uuid, boolean) to authenticated;
