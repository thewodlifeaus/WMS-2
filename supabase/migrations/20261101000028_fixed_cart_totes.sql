-- =============================================================================
-- TWL WMS | Migration 028 | Totes fixed to carts + find an order on a cart
--   From Ben's sheet (1 Nov 2026): CART01-CART19 each carry 25 totes, in order:
--   CART01 = BIN001-BIN025, CART02 = BIN026-BIN050 ... CART19 = BIN451-BIN475.
--   The tote barcode is the label on the cart (scannable).
--   * Building a cart puts each order (or shared-tote group) straight into a tote
--     on that cart: tote slot 1 = first tote on the cart. No tote scanning at start.
--   * A cart is only free when it has no open pick AND none of its totes still
--     hold picked orders waiting to be packed. Orders are never split across carts.
--   * Carts with no fixed totes (CART20, INV01-INV10) keep the scan-a-tote flow
--     with the loose totes (BIN476-BIN500, INV001-INV005).
--   * wms_find_order: where an order is (cart, tote, picked so far, picker) for
--     cancellations and changes.
-- =============================================================================

-- 1. fixed totes (moves BIN406-BIN475 from loose onto CART17-CART19)
insert into cart_baskets(cart_id, position, barcode, kind, warehouse_id, is_active)
select c.id, p, 'BIN' || lpad(((n - 1) * 25 + p)::text, 3, '0'), 'tote', c.warehouse_id, true
  from generate_series(1, 19) n
  join carts c on c.code = 'CART' || lpad(n::text, 2, '0')
  cross join generate_series(1, 25) p
on conflict (barcode) do update
   set cart_id = excluded.cart_id, position = excluded.position, kind = 'tote',
       warehouse_id = excluded.warehouse_id, is_active = true;

-- 2. is a cart free to build onto?
create or replace function wms__cart_free(p_cart uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (select 1 from pick_sessions ps where ps.cart_id = p_cart and ps.status in ('draft','assigned','in_progress'))
     and not exists (select 1 from cart_baskets cb where cb.cart_id = p_cart and wms__tote_busy(cb.id))
$$;

-- 3. put a session's tote slots into the cart's fixed totes (slot N -> position N)
create or replace function wms__fill_fixed_totes(p_session_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare v_cart uuid; n int;
begin
  select cart_id into v_cart from pick_sessions where id = p_session_id;
  if v_cart is null or not exists (select 1 from cart_baskets where cart_id = v_cart) then return 0; end if;
  -- orders without a slot (built before slots existed) get one in priority order
  with r as (
    select pso.order_id, dense_rank() over (order by o.priority, o.ordered_at nulls last, o.order_number)
             + coalesce((select max(slot) from pick_session_orders where session_id = p_session_id), 0) as s
      from pick_session_orders pso join orders o on o.id = pso.order_id
     where pso.session_id = p_session_id and pso.slot is null)
  update pick_session_orders pso set slot = r.s from r where pso.session_id = p_session_id and pso.order_id = r.order_id;
  update pick_session_orders pso set basket_id = cb.id
    from cart_baskets cb
   where pso.session_id = p_session_id and pso.basket_id is null
     and cb.cart_id = v_cart and cb.position = pso.slot and cb.is_active;
  get diagnostics n = row_count;
  update pick_allocations pa set basket_id = pso.basket_id
    from pick_tasks t, pick_session_orders pso
   where t.id = pa.task_id and t.session_id = p_session_id
     and pso.session_id = p_session_id and pso.order_id = pa.order_id and pa.basket_id is distinct from pso.basket_id;
  return n;
end $$;

-- open carts already on CART01-CART19: fill their fixed totes now
select wms__fill_fixed_totes(ps.id) from pick_sessions ps join carts c on c.id = ps.cart_id
 where ps.status in ('draft','assigned','in_progress') and exists (select 1 from cart_baskets cb where cb.cart_id = c.id);

-- 4. build carts (019 + fixed totes + cart free check)
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
        v_cap int; v_fixed int; v_sid uuid;
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
     and wms__cart_free(c.id);
  if v_carts is null then return jsonb_build_object('ok', false, 'error', 'NO_FREE_CARTS'); end if;

  v_used := array_fill(false, array[array_length(v_ids, 1)]);

  foreach v_cid in array v_carts loop
    exit when not (false = any(v_used));
    select * into v_cart from carts where id = v_cid;
    v_slots := 0; v_slot_units := '{}'; v_chunk := '{}'; v_chunk_slot := '{}';
    -- carts with totes fixed to them hold at most that many totes
    select count(*) into v_fixed from cart_baskets where cart_id = v_cart.id and is_active;
    v_cap := case when v_fixed > 0 then least(p_totes_per_cart, v_fixed) else p_totes_per_cart end;

    -- fill this cart: walk the queue in priority order; an order goes in only if it fits whole
    for i in 1 .. array_length(v_ids, 1) loop
      continue when v_used[i];
      if v_mode = 'orders' then
        exit when v_slots >= v_cap;
        v_slots := v_slots + 1; v_slot_units := v_slot_units || v_units[i];
        v_chunk := v_chunk || v_ids[i]; v_chunk_slot := v_chunk_slot || v_slots; v_used[i] := true;
      else
        j := null;
        if v_units[i] <= p_pieces_per_tote then   -- first tote with room for the whole order
          for k in 1 .. v_slots loop
            if v_slot_units[k] + v_units[i] <= p_pieces_per_tote then j := k; exit; end if;
          end loop;
        end if;
        if j is null and v_slots < v_cap then   -- open a new tote (big orders always get their own)
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
      v_sid := (v_res->>'session_id')::uuid;
      update pick_session_orders pso set slot = s.slot, basket_id = null
        from unnest(v_chunk, v_chunk_slot) as s(order_id, slot)
       where pso.session_id = v_sid and pso.order_id = s.order_id;
      -- fixed totes: tote slot N = the Nth tote on the cart (eg CART02 slot 1 = BIN026)
      perform wms__fill_fixed_totes(v_sid);
      v_made := v_made || jsonb_build_object('cart', v_cart.code, 'session_id', v_res->'session_id',
                  'orders', v_res->'orders', 'stops', v_res->'tasks', 'shortages', v_res->'shortages',
                  'totes', (select count(distinct slot) from pick_session_orders where session_id = (v_res->>'session_id')::uuid),
                  'fixed_totes', v_fixed > 0,
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

-- 5. order queue (023 + tote on "On cart", picked orders still in a tote, free = no busy totes)
create or replace function wms_order_queue(p_view text default 'ready', p_search text default null, p_limit int default 1000)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb; s jsonb; g jsonb; q text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not wms_is_staff() then raise exception 'NOT_STAFF' using errcode = '42501'; end if;

  with base as (
    select o.*, wms__order_ready(o) as ready,
           (select c.code || coalesce(' · ' || cb.barcode, '') from pick_session_orders pso join pick_sessions ps on ps.id = pso.session_id
              left join carts c on c.id = ps.cart_id left join cart_baskets cb on cb.id = pso.basket_id
             where pso.order_id = o.id and (ps.status in ('draft','assigned','in_progress') or o.status in ('picked','packing'))
             order by ps.created_at desc limit 1) as on_cart
      from orders o
     where o.status in ('awaiting_pick','on_hold','allocated','picking','picked','packing')
  ), lines as (
    select l.order_id, sum(l.qty_ordered) as units, count(*) as line_count,
           bool_and(l.product_id is not null and coalesce((
             select sum(bi.qty_on_hand - bi.qty_allocated) from bin_inventory bi join bins b on b.id = bi.bin_id
              where bi.product_id = l.product_id and b.is_pickable), 0) >= l.qty_ordered - l.qty_allocated) as stock_ok
      from order_lines l where l.order_id in (select id from base) group by l.order_id
  )
  select jsonb_build_object(
      'ready',       count(*) filter (where ready = 'ready'),
      'no_service',  count(*) filter (where ready = 'no_service'),
      'on_hold',     count(*) filter (where ready = 'on_hold'),
      'in_progress', count(*) filter (where ready = 'in_progress'),
      'no_stock',    count(*) filter (where ready = 'ready' and not coalesce(ln.stock_ok, false))),
    coalesce(jsonb_agg(jsonb_build_object(
      'id', b.id, 'order_number', b.order_number, 'customer', b.customer_name,
      'city', b.ship_to->>'city_locality', 'state', b.ship_to->>'state_province', 'country', b.ship_to->>'country_code',
      'service', b.requested_service, 'carrier_id', b.carrier_id, 'service_code', b.service_code,
      'express', b.priority < 100, 'ordered_at', b.ordered_at, 'status', b.status, 'ready', b.ready,
      'hold_reason', b.hold_reason, 'on_cart', b.on_cart, 'group', coalesce(b.pick_group, 'OTHER'),
      'tags', (select jsonb_agg(t->>'name') from jsonb_array_elements(coalesce(b.raw->'tags','[]')) t),
      'store_id', b.raw->>'store_id',
      'units', ln.units, 'lines', ln.line_count, 'stock_ok', coalesce(ln.stock_ok, false))
      order by b.priority, b.ordered_at nulls last, b.order_number)
      filter (where (p_view = 'all' or b.ready = p_view)
                and (q is null or b.order_number ilike '%' || ltrim(q, '#') || '%' or b.customer_name ilike '%' || q || '%'
                     or b.requested_service ilike '%' || q || '%'
                     or exists (select 1 from order_lines l2 where l2.order_id = b.id and l2.sku ilike q || '%')))
    , '[]')
    into s, v
    from base b left join lines ln on ln.order_id = b.id;

  -- order types in this view (for the type filter chips)
  select coalesce(jsonb_object_agg(k, n), '{}') into g
    from (select x->>'group' as k, count(*) as n from jsonb_array_elements(v) x group by 1) t;

  return jsonb_build_object('summary', s, 'groups', g,
    'orders', (select coalesce(jsonb_agg(x), '[]') from (select x from jsonb_array_elements(v) x limit p_limit) t),
    'free_carts', (select count(*) from carts c where c.is_active and wms__cart_free(c.id)));
end $$;


-- 6. where is this order? (order number with or without #, customer name, or tote barcode)
create or replace function wms_find_order(p_text text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q text := ltrim(nullif(trim(coalesce(p_text, '')), ''), '#');
begin
  if not wms_is_staff() then raise exception 'NOT_STAFF' using errcode = '42501'; end if;
  if q is null or length(q) < 2 then return '[]'; end if;
  return (select coalesce(jsonb_agg(x order by x->>'sort'), '[]') from (
    select jsonb_build_object(
      'order_id', o.id, 'order_number', o.order_number, 'customer', o.customer_name, 'status', o.status,
      'group', o.pick_group, 'is_held', o.is_held, 'hold_reason', o.hold_reason, 'service', o.requested_service,
      'session_id', ps.id, 'session_status', ps.status, 'cart', c.code, 'tote', cb.barcode, 'slot', pso.slot,
      'picker', (select display_name from staff where id = ps.assigned_to),
      'units', (select coalesce(sum(qty_ordered), 0) from order_lines where order_id = o.id),
      'picked', (select coalesce(sum(qty_picked), 0) from order_lines where order_id = o.id),
      'shared_with', (select string_agg('#' || o2.order_number, ', ' order by o2.order_number)
                        from pick_session_orders p2 join orders o2 on o2.id = p2.order_id
                       where pso.basket_id is not null and p2.session_id = pso.session_id and p2.basket_id = pso.basket_id and p2.order_id <> o.id),
      'where', case
         when o.status in ('shipped','packed') then 'Packed / shipped'
         when o.status = 'cancelled' then 'Cancelled'
         when ps.id is null then 'Not on a cart'
         when ps.status in ('draft','assigned') then 'On ' || c.code || coalesce(', tote ' || cb.barcode, '') || ' (not started)'
         when ps.status = 'in_progress' then 'On ' || c.code || coalesce(', tote ' || cb.barcode, '') || ' (being picked)'
         when o.status in ('picked','packing') then 'Picked into ' || coalesce('tote ' || cb.barcode, c.code) || ', waiting to pack'
         else o.status::text end,
      'sort', case when o.order_number ilike q then '0' else '1' end || coalesce(o.order_number, '')) x
      from orders o
      left join lateral (select pso.* from pick_session_orders pso join pick_sessions s on s.id = pso.session_id
                          where pso.order_id = o.id and s.status <> 'cancelled' order by s.created_at desc limit 1) pso on true
      left join pick_sessions ps on ps.id = pso.session_id
      left join carts c on c.id = ps.cart_id
      left join cart_baskets cb on cb.id = pso.basket_id
     where o.order_number ilike '%' || q || '%' or o.customer_name ilike '%' || q || '%'
        or exists (select 1 from pick_session_orders p3 join cart_baskets b3 on b3.id = p3.basket_id
                    join pick_sessions s3 on s3.id = p3.session_id
                    where p3.order_id = o.id and upper(b3.barcode) = upper(q)
                      and (s3.status in ('draft','assigned','in_progress') or o.status in ('picked','packing')))
     order by o.ordered_at desc nulls last limit 20) t);
end $$;

revoke execute on function wms__cart_free(uuid) from public, anon, authenticated;
revoke execute on function wms__fill_fixed_totes(uuid) from public, anon, authenticated;
revoke execute on function wms_find_order(text) from public, anon;
grant execute on function wms_find_order(text) to authenticated;
