-- =============================================================================
-- TWL WMS | Migration 016 | Orders queue + build carts + cart view (SkuVault style)
--   * every order comes from ShipStation (sync-shipstation-orders); an order can
--     only go on a cart when ShipStation has a carrier + service on it
--   * admins/supervisors filter the queue, then build carts: N orders per cart,
--     one tote per order (totes scanned when the picker starts the cart)
--   * cart list + cart detail with the full pick list in walking order
-- =============================================================================

-- is this order ready to go on a cart?
create or replace function wms__order_ready(o orders) returns text
language sql stable security definer set search_path = public as $$
  select case
    when o.status = 'cancelled'                         then 'cancelled'
    when o.status not in ('awaiting_pick')              then 'in_progress'
    when o.is_held or o.status = 'on_hold'              then 'on_hold'
    when o.carrier_id is null or o.service_code is null then 'no_service'
    else 'ready' end
$$;

-- the queue the admin builds carts from
create or replace function wms_order_queue(p_view text default 'ready', p_search text default null, p_limit int default 1000)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb; s jsonb; q text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not wms_is_staff() then raise exception 'NOT_STAFF' using errcode = '42501'; end if;

  with base as (
    select o.*, wms__order_ready(o) as ready,
           (select c.code from pick_session_orders pso join pick_sessions ps on ps.id = pso.session_id
              left join carts c on c.id = ps.cart_id
             where pso.order_id = o.id and ps.status in ('draft','assigned','in_progress')
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
      'hold_reason', b.hold_reason, 'on_cart', b.on_cart,
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

  return jsonb_build_object('summary', s,
    'orders', (select coalesce(jsonb_agg(x), '[]') from (select x from jsonb_array_elements(v) x limit p_limit) t),
    'free_carts', (select count(*) from carts c where c.is_active and not exists (
                     select 1 from pick_sessions ps where ps.cart_id = c.id and ps.status in ('draft','assigned','in_progress'))));
end $$;

-- build carts from selected orders (admin / supervisor)
create or replace function wms_build_carts(p_order_ids uuid[], p_per_cart int default 12, p_cart_ids uuid[] default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); v_ids uuid[]; v_skipped jsonb; v_carts uuid[]; v_cart carts; v_cid uuid;
        v_chunk uuid[]; v_i int := 1; v_per int; v_res jsonb; v_made jsonb := '[]'; v_failed jsonb := '[]'; v_n int;
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then
    raise exception 'FORBIDDEN: only admins and supervisors can build carts' using errcode = '42501';
  end if;
  if coalesce(p_per_cart, 0) < 1 then raise exception 'PER_CART_MUST_BE_AT_LEAST_1'; end if;

  -- keep only ready orders, express first then oldest
  select array_agg(o.id order by o.priority, o.ordered_at nulls last, o.order_number) into v_ids
    from orders o where o.id = any(p_order_ids) and wms__order_ready(o) = 'ready';
  select coalesce(jsonb_agg(jsonb_build_object('order_number', o.order_number, 'reason', wms__order_ready(o))), '[]')
    into v_skipped from orders o where o.id = any(p_order_ids) and wms__order_ready(o) <> 'ready';
  if v_ids is null then
    return jsonb_build_object('ok', false, 'error', 'NO_READY_ORDERS', 'skipped', v_skipped);
  end if;

  select array_agg(c.id order by c.code) into v_carts from carts c
   where c.is_active and (p_cart_ids is null or c.id = any(p_cart_ids))
     and not exists (select 1 from pick_sessions ps where ps.cart_id = c.id and ps.status in ('draft','assigned','in_progress'));
  if v_carts is null then return jsonb_build_object('ok', false, 'error', 'NO_FREE_CARTS'); end if;

  foreach v_cid in array v_carts loop
    exit when v_i > array_length(v_ids, 1);
    select * into v_cart from carts where id = v_cid;
    v_per := least(p_per_cart, v_cart.basket_count);
    v_chunk := v_ids[v_i : v_i + v_per - 1];
    v_i := v_i + v_per;
    begin
      v_res := wms_create_pick_session('cluster', v_chunk, v_cart.id);
      v_made := v_made || jsonb_build_object('cart', v_cart.code, 'session_id', v_res->'session_id',
                  'orders', v_res->'orders', 'stops', v_res->'tasks', 'shortages', v_res->'shortages');
    exception when others then
      v_failed := v_failed || jsonb_build_object('cart', v_cart.code, 'error', sqlerrm,
                    'orders', (select jsonb_agg(order_number) from orders where id = any(v_chunk)));
    end;
  end loop;

  v_n := greatest(array_length(v_ids, 1) - v_i + 1, 0);
  return jsonb_build_object('ok', jsonb_array_length(v_made) > 0, 'carts', v_made, 'failed', v_failed,
    'skipped', v_skipped, 'left_over', v_n,
    'left_over_orders', case when v_n > 0 then (select jsonb_agg(order_number) from orders where id = any(v_ids[v_i:])) end);
end $$;

-- take a cart apart again before picking starts (admin / supervisor)
create or replace function wms_cancel_pick_session(p_session_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); s pick_sessions; a record;
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then
    raise exception 'FORBIDDEN' using errcode = '42501';
  end if;
  select * into s from pick_sessions where id = p_session_id for update;
  if not found then return jsonb_build_object('ok',false,'error','NOT_FOUND'); end if;
  if s.status not in ('draft','assigned','in_progress') then return jsonb_build_object('ok',false,'error','ALREADY_CLOSED'); end if;
  if exists (select 1 from pick_tasks where session_id = s.id and qty_picked > 0) then
    return jsonb_build_object('ok',false,'error','PICKING_STARTED','hint','Items have already been picked on this cart.');
  end if;

  for a in select pa.*, t.bin_id, t.product_id from pick_allocations pa join pick_tasks t on t.id = pa.task_id
            where t.session_id = s.id loop
    update bin_inventory set qty_allocated = greatest(qty_allocated - a.qty, 0), updated_at = now()
     where bin_id = a.bin_id and product_id = a.product_id;
    update order_lines set qty_allocated = greatest(qty_allocated - a.qty, 0) where id = a.order_line_id;
  end loop;
  update pick_tasks set status = 'cancelled' where session_id = s.id;
  update orders set status = 'awaiting_pick'
   where id in (select order_id from pick_session_orders where session_id = s.id) and status in ('allocated','picking');
  update pick_sessions set status = 'cancelled', completed_at = now() where id = s.id;
  return jsonb_build_object('ok', true, 'orders_released', (select count(*) from pick_session_orders where session_id = s.id));
end $$;

-- every cart in use (plus today's finished ones)
create or replace function wms_carts_overview() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'sort'), '[]') from (
    select jsonb_build_object(
      'session_id', ps.id, 'cart', coalesce(c.code, '(no cart)'), 'status', ps.status, 'method', ps.method,
      'created_at', ps.created_at, 'started_at', ps.started_at, 'completed_at', ps.completed_at,
      'created_by', (select display_name from staff where id = ps.created_by),
      'picker', (select display_name from staff where id = ps.assigned_to),
      'orders', (select count(*) from pick_session_orders where session_id = ps.id),
      'totes', (select count(basket_id) from pick_session_orders where session_id = ps.id),
      'units', (select coalesce(sum(qty_required), 0) from pick_tasks where session_id = ps.id),
      'picked', (select coalesce(sum(qty_picked), 0) from pick_tasks where session_id = ps.id),
      'stops', (select count(*) from pick_tasks where session_id = ps.id),
      'stops_done', (select count(*) from pick_tasks where session_id = ps.id and status in ('done','short')),
      'first_bin', (select b.code from pick_tasks t join bins b on b.id = t.bin_id where t.session_id = ps.id order by t.sequence limit 1),
      'sort', case ps.status when 'in_progress' then '1' when 'assigned' then '2' when 'draft' then '3' else '4' end || coalesce(c.code, 'zz')
    ) x
      from pick_sessions ps left join carts c on c.id = ps.cart_id
     where wms_is_staff()
       and (ps.status in ('draft','assigned','in_progress')
            or (ps.status = 'completed' and ps.completed_at >= date_trunc('day', now() at time zone 'Australia/Adelaide') at time zone 'Australia/Adelaide'))
  ) t
$$;

-- one cart: orders/totes + the pick list in walking order
create or replace function wms_cart_detail(p_session_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not wms_is_staff() then null else jsonb_build_object(
    'session', (select jsonb_build_object('id', ps.id, 'cart', c.code, 'status', ps.status, 'route', ps.route,
                  'created_at', ps.created_at, 'started_at', ps.started_at, 'completed_at', ps.completed_at,
                  'created_by', (select display_name from staff where id = ps.created_by),
                  'picker', (select display_name from staff where id = ps.assigned_to))
                  from pick_sessions ps left join carts c on c.id = ps.cart_id where ps.id = p_session_id),
    'orders', (select coalesce(jsonb_agg(jsonb_build_object(
                  'order_number', o.order_number, 'customer', o.customer_name, 'service', o.requested_service,
                  'express', o.priority < 100, 'status', o.status, 'tote', cb.barcode, 'is_held', o.is_held,
                  'units', (select sum(qty) from pick_allocations pa join pick_tasks t on t.id = pa.task_id
                             where t.session_id = p_session_id and pa.order_id = o.id),
                  'picked', (select sum(pa.qty_picked) from pick_allocations pa join pick_tasks t on t.id = pa.task_id
                              where t.session_id = p_session_id and pa.order_id = o.id))
                  order by cb.barcode nulls last, o.priority, o.ordered_at), '[]')
                 from pick_session_orders pso join orders o on o.id = pso.order_id
                 left join cart_baskets cb on cb.id = pso.basket_id where pso.session_id = p_session_id),
    'picks', (select coalesce(jsonb_agg(jsonb_build_object(
                  'seq', t.sequence, 'bin', b.code, 'row', ar.code, 'bin_type', b.location_type,
                  'sku', p.sku, 'name', p.name, 'variant', p.variant_title, 'image_url', p.image_url,
                  'qty', t.qty_required, 'picked', t.qty_picked, 'status', t.status,
                  'split', (select jsonb_agg(jsonb_build_object('order_number', o2.order_number, 'tote', cb2.barcode, 'qty', pa.qty)
                                             order by pa.fill_order)
                              from pick_allocations pa join orders o2 on o2.id = pa.order_id
                              left join cart_baskets cb2 on cb2.id = pa.basket_id where pa.task_id = t.id))
                  order by t.sequence), '[]')
                from pick_tasks t join bins b on b.id = t.bin_id
                left join shelves sh on sh.id = b.shelf_id left join aisle_rows ar on ar.id = sh.row_id
                join products p on p.id = t.product_id where t.session_id = p_session_id)
  ) end
$$;

revoke execute on function wms__order_ready(orders) from public, anon, authenticated;
revoke execute on function wms_order_queue(text, text, int) from public, anon;
revoke execute on function wms_build_carts(uuid[], int, uuid[]) from public, anon;
revoke execute on function wms_cancel_pick_session(uuid) from public, anon;
revoke execute on function wms_carts_overview() from public, anon;
revoke execute on function wms_cart_detail(uuid) from public, anon;
grant execute on function wms_order_queue(text, text, int) to authenticated;
grant execute on function wms_build_carts(uuid[], int, uuid[]) to authenticated;
grant execute on function wms_cancel_pick_session(uuid) to authenticated;
grant execute on function wms_carts_overview() to authenticated;
grant execute on function wms_cart_detail(uuid) to authenticated;
