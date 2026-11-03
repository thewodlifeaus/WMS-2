-- =============================================================================
-- TWL WMS | Migration 023 | Order types (SkuVault "channel accounts")
--   SkuVault splits orders by the ShipStation TAG on each order (all orders come
--   from the one Shopify store in ShipStation), plus country and shipping service.
--   Checked 1 Nov 2026 against SkuVault saved filters + 21 days of ShipStation:
--     ICON     tag "The Iconic"
--     OPENFR8  tag "OPENFREIGHT"
--     PKUP     shipping service "Warehouse Pickup" (Priority / Regular orders)
--     PRIO_AU  tag "priority-order", ship to AU
--     PRIO_INT tag "priority-order", ship outside AU (all international orders)
--     REGS     tag "Regular Order"
--     OTHER    none of the above (eg exchanges with no tag)
-- =============================================================================

create or replace function wms__pick_group(p_raw jsonb, p_service text) returns text
language sql immutable set search_path = public as $$
  with t as (select coalesce(array_agg(lower(trim(x->>'name'))), '{}') as tags
               from jsonb_array_elements(coalesce(p_raw->'tags', '[]')) x),
       c as (select coalesce(upper(p_raw->'ship_to'->>'country_code'), 'AU') as cc)
  select case
    when 'openfreight' = any(t.tags)                                   then 'OPENFR8'
    when coalesce(p_service, '') ilike '%pickup%'                      then 'PKUP'
    when 'the iconic' = any(t.tags)                                    then 'ICON'
    when 'priority-order' = any(t.tags) and c.cc <> 'AU'               then 'PRIO_INT'
    when 'priority-order' = any(t.tags)                                then 'PRIO_AU'
    when 'regular order' = any(t.tags)                                 then 'REGS'
    when c.cc <> 'AU'                                                  then 'PRIO_INT'
    else 'OTHER' end
  from t, c
$$;

alter table orders add column if not exists pick_group text;

create or replace function wms__orders_set_group() returns trigger
language plpgsql set search_path = public as $$
begin
  new.pick_group := wms__pick_group(new.raw, new.requested_service);
  return new;
end $$;

create or replace trigger orders_set_group before insert or update of raw, requested_service on orders
  for each row execute function wms__orders_set_group();

update orders set pick_group = wms__pick_group(raw, requested_service) where pick_group is distinct from wms__pick_group(raw, requested_service);
create index if not exists orders_pick_group_idx on orders (pick_group) where status in ('awaiting_pick','on_hold');

-- the order types on a cart, eg 'REGS' or 'REGS+PKUP' (mixed carts built before this change)
create or replace function wms__session_groups(p_session_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select string_agg(distinct o.pick_group, '+' order by o.pick_group)
    from pick_session_orders pso join orders o on o.id = pso.order_id where pso.session_id = p_session_id
$$;

-- ---------------------------------------------------------------- order queue
create or replace function wms_order_queue(p_view text default 'ready', p_search text default null, p_limit int default 1000)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb; s jsonb; g jsonb; q text := nullif(trim(coalesce(p_search, '')), '');
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
    'free_carts', (select count(*) from carts c where c.is_active and not exists (
                     select 1 from pick_sessions ps where ps.cart_id = c.id and ps.status in ('draft','assigned','in_progress'))));
end $$;

-- ---------------------------------------------------------------- carts overview (021 + group)
create or replace function wms_carts_overview() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'sort'), '[]') from (
    select jsonb_build_object(
      'session_id', ps.id, 'cart', coalesce(c.code, '(no cart)'), 'status', ps.status, 'method', ps.method,
      'created_at', ps.created_at, 'started_at', ps.started_at, 'completed_at', ps.completed_at,
      'created_by', (select display_name from staff where id = ps.created_by),
      'picker', (select display_name from staff where id = ps.assigned_to),
      'paused', ps.paused_at is not null, 'pause_reason', ps.pause_reason,
      'group', wms__session_groups(ps.id),
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

-- ---------------------------------------------------------------- cart detail (021 + group)
create or replace function wms_cart_detail(p_session_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not wms_is_staff() then null else jsonb_build_object(
    'session', (select jsonb_build_object('id', ps.id, 'cart', c.code, 'status', ps.status, 'route', ps.route,
                  'created_at', ps.created_at, 'started_at', ps.started_at, 'completed_at', ps.completed_at,
                  'created_by', (select display_name from staff where id = ps.created_by),
                  'picker', (select display_name from staff where id = ps.assigned_to),
                  'paused', ps.paused_at is not null, 'pause_reason', ps.pause_reason, 'paused_at', ps.paused_at,
                  'group', wms__session_groups(ps.id),
                  'tote_slots', (select count(distinct coalesce(slot::text, order_id::text)) from pick_session_orders where session_id = ps.id))
                  from pick_sessions ps left join carts c on c.id = ps.cart_id where ps.id = p_session_id),
    'orders', (select coalesce(jsonb_agg(jsonb_build_object(
                  'order_number', o.order_number, 'customer', o.customer_name, 'service', o.requested_service,
                  'express', o.priority < 100, 'status', o.status, 'tote', cb.barcode, 'slot', pso.slot, 'is_held', o.is_held,
                  'group', o.pick_group,
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

-- ---------------------------------------------------------------- tablet: carts waiting (017 + group)
create or replace function wms_pick_carts_available() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not wms_is_staff() then '[]'::jsonb else coalesce(jsonb_agg(x order by x->>'sort'), '[]') end from (
    select jsonb_build_object(
      'session_id', ps.id, 'cart', c.code, 'cart_barcode', c.barcode,
      'state', case when ps.status = 'in_progress' and ps.paused_at is null then 'picking'
                    when ps.paused_at is not null and ps.assigned_to is null then 'released'
                    when ps.paused_at is not null then 'paused' else 'not_started' end,
      'mine', ps.assigned_to = auth.uid(),
      'picker', (select display_name from staff where id = ps.assigned_to),
      'pause_reason', ps.pause_reason,
      'group', wms__session_groups(ps.id),
      'orders', (select count(*) from pick_session_orders where session_id = ps.id),
      'units', (select coalesce(sum(qty_required), 0) from pick_tasks where session_id = ps.id),
      'picked', (select coalesce(sum(qty_picked), 0) from pick_tasks where session_id = ps.id),
      'stops', (select count(*) from pick_tasks where session_id = ps.id),
      'express', exists (select 1 from pick_session_orders pso join orders o on o.id = pso.order_id
                          where pso.session_id = ps.id and o.priority < 100),
      'first_bin', (select b.code from pick_tasks t join bins b on b.id = t.bin_id
                     where t.session_id = ps.id and t.status = 'pending' order by t.sequence limit 1),
      'created_at', ps.created_at,
      'sort', case when ps.assigned_to = auth.uid() then '0' when ps.paused_at is not null and ps.assigned_to is null then '1'
                   when ps.status in ('draft','assigned') then '2' else '3' end || to_char(ps.created_at, 'YYYYMMDDHH24MISS')
    ) x
      from pick_sessions ps join carts c on c.id = ps.cart_id
     where ps.status in ('draft','assigned','in_progress')
  ) t
$$;

revoke execute on function wms__pick_group(jsonb, text) from public, anon, authenticated;
revoke execute on function wms__session_groups(uuid) from public, anon, authenticated;
revoke execute on function wms__orders_set_group() from public, anon, authenticated;
