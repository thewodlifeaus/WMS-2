-- =============================================================================
-- TWL WMS | Migration 012 | Logins, carts + totes, inventory search, TV metrics
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. LOGINS: everyone signs in with a username + 6-digit PIN.
--    Auth email is synthetic (<username>@staff.twlwms.app) so floor staff need
--    no email address; a real contact email is optional. Accounts are created
--    by the staff-admin edge function (admins only).
-- ---------------------------------------------------------------------------
alter table staff add column if not exists username      text;
alter table staff add column if not exists contact_email text;
alter table staff add column if not exists pin_set_at    timestamptz;
create unique index if not exists staff_username_key on staff (lower(username));
alter table staff add constraint staff_username_format
  check (username is null or username ~ '^[a-z0-9][a-z0-9._-]{1,30}$');

-- the TV screen account ('display') can read, but every scan/move/pick function refuses it
create or replace function wms__require_staff() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid;
begin
  select s.id into v from staff s where s.id = auth.uid() and s.is_active and s.role <> 'display';
  if v is null then raise exception 'NOT_STAFF: user is not an active WMS staff member' using errcode = '42501'; end if;
  return v;
end $$;

create or replace function wms_me() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', id, 'name', display_name, 'username', username, 'role', role)
    from staff where id = auth.uid() and is_active
$$;

-- ---------------------------------------------------------------------------
-- 2. CARTS + TOTES (SkuVault: CART01-CART30, hyper-picking totes BIN406-BIN500, INV001-INV005)
--    Totes are free-floating: they are not fixed to a cart. A picker scans a cart,
--    then scans one tote per order. Barcode = the code already on the label.
-- ---------------------------------------------------------------------------
alter table cart_baskets alter column cart_id  drop not null;
alter table cart_baskets alter column position drop not null;
alter table cart_baskets add column if not exists kind text not null default 'basket'
  check (kind in ('basket','tote'));
alter table cart_baskets add column if not exists warehouse_id uuid references warehouses(id);
alter table cart_baskets add column if not exists is_active boolean not null default true;

-- a tote is busy while it's on an active pick or holding an order waiting to be packed
create or replace function wms__tote_busy(p_basket uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from pick_session_orders pso
      join pick_sessions s on s.id = pso.session_id
      join orders o on o.id = pso.order_id
     where pso.basket_id = p_basket
       and (s.status in ('draft','assigned','in_progress') or o.status in ('picked','packing')))
$$;

-- scan one tote per order (in the order shown on screen)
create or replace function wms_assign_totes(p_session_id uuid, p_tote_barcodes text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); r record; v_tote cart_baskets; i int := 0; v_out jsonb := '[]';
begin
  if (select status from pick_sessions where id = p_session_id) not in ('draft','assigned','in_progress') then
    return jsonb_build_object('ok',false,'error','SESSION_CLOSED');
  end if;
  for r in select pso.order_id, o.order_number from pick_session_orders pso join orders o on o.id = pso.order_id
            where pso.session_id = p_session_id and pso.basket_id is null
            order by o.priority, o.ordered_at nulls last, o.order_number
  loop
    i := i + 1;
    exit when i > coalesce(array_length(p_tote_barcodes, 1), 0);
    select * into v_tote from cart_baskets where barcode = trim(p_tote_barcodes[i]) and is_active;
    if v_tote.id is null then
      return jsonb_build_object('ok',false,'error','UNKNOWN_TOTE','tote',p_tote_barcodes[i],'alarm',true);
    end if;
    if wms__tote_busy(v_tote.id) then
      return jsonb_build_object('ok',false,'error','TOTE_IN_USE','tote',v_tote.barcode,'alarm',true);
    end if;
    update pick_session_orders set basket_id = v_tote.id where session_id = p_session_id and order_id = r.order_id;
    update pick_allocations pa set basket_id = v_tote.id
      from pick_tasks t where t.id = pa.task_id and t.session_id = p_session_id and pa.order_id = r.order_id;
    v_out := v_out || jsonb_build_object('order_number', r.order_number, 'tote', v_tote.barcode);
  end loop;
  return jsonb_build_object('ok',true,'assigned',v_out,
    'still_need', (select count(*) from pick_session_orders where session_id = p_session_id and basket_id is null));
end $$;

-- start a session on a tote cart: returns SCAN_TOTES_FIRST until every order has a tote
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
    -- carts with fixed baskets number them automatically; tote carts get totes scanned per order
    if s.method <> 'batch' and exists (select 1 from cart_baskets where cart_id = v_cart.id) then
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
     and (select count(*) from pick_session_orders where session_id = s.id) > 1
     and exists (select 1 from pick_session_orders where session_id = s.id and basket_id is null) then
    if (select cart_id from pick_sessions where id = s.id) is null then
      raise exception 'SCAN_CART_FIRST';
    end if;
    -- cart is set (and kept); now scan one tote per order with wms_assign_totes, then start again
    return jsonb_build_object('ok',false,'error','SCAN_TOTES_FIRST','session_id',s.id,
      'orders_needing_tote', (select jsonb_agg(o.order_number order by o.priority, o.ordered_at nulls last, o.order_number)
                                from pick_session_orders pso join orders o on o.id = pso.order_id
                               where pso.session_id = s.id and pso.basket_id is null));
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
-- 3. INVENTORY SEARCH by SKU, title or barcode (tablet + desktop)
-- ---------------------------------------------------------------------------
create extension if not exists pg_trgm;
create index if not exists products_sku_trgm  on products using gin (sku gin_trgm_ops);
create index if not exists products_name_trgm on products using gin (name gin_trgm_ops);

create or replace function wms_search_inventory(p_query text, p_limit int default 25, p_in_stock_only boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare q text := trim(coalesce(p_query, '')); v_words text[];
begin
  if not wms_is_staff() then raise exception 'NOT_STAFF' using errcode = '42501'; end if;
  if length(q) < 2 then return '[]'::jsonb; end if;
  v_words := regexp_split_to_array(lower(q), '\s+');

  return coalesce((
    with hits as (
      select p.id, p.sku, p.name, p.variant_title, p.image_url, p.is_active,
             case when exists (select 1 from product_barcodes b where b.product_id = p.id and b.barcode = q) then 0
                  when lower(p.sku) = lower(q) then 1
                  when p.sku ilike q || '%' then 2
                  else 3 end as rank
        from products p
       where exists (select 1 from product_barcodes b where b.product_id = p.id and b.barcode = q)
          or p.sku ilike '%' || q || '%'
          or (select bool_and(lower(p.name || ' ' || coalesce(p.variant_title,'')) like '%' || w || '%') from unnest(v_words) w)
    ), stock as (
      select h.*, coalesce(sum(bi.qty_on_hand), 0) as on_hand,
             coalesce(sum(bi.qty_on_hand - bi.qty_allocated) filter (where b.is_pickable), 0) as available,
             coalesce(jsonb_agg(jsonb_build_object('bin', b.code, 'type', b.location_type,
                        'qty', bi.qty_on_hand, 'allocated', bi.qty_allocated) order by b.row_seq, b.shelf_seq, b.bin_seq)
                      filter (where bi.qty_on_hand > 0), '[]') as bins
        from hits h
        left join bin_inventory bi on bi.product_id = h.id
        left join bins b on b.id = bi.bin_id
       group by h.id, h.sku, h.name, h.variant_title, h.image_url, h.is_active, h.rank
    )
    select jsonb_agg(jsonb_build_object(
             'id', id, 'sku', sku, 'name', name, 'variant', variant_title, 'image_url', image_url,
             'active', is_active, 'on_hand', on_hand, 'available', available, 'bins', bins,
             'barcodes', (select jsonb_agg(barcode) from product_barcodes where product_id = s.id))
           order by rank, (on_hand > 0) desc, sku)
      from (select * from stock where not p_in_stock_only or on_hand > 0
             order by rank, (on_hand > 0) desc, sku limit greatest(1, least(p_limit, 100))) s
  ), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- 4. WAREHOUSE TV METRICS
--    Comparisons are "same time of day": today up to now vs the last working
--    day up to the same clock time, and vs the same weekday last week.
--    Score = average of (today / comparison) for items picked, items packed and
--    labels generated, x100. 100 = level. Dial bands: RED < 85, AMBER 85-99, GREEN >= 100.
-- ---------------------------------------------------------------------------
create or replace function wms__floor_window(p_from timestamptz, p_to timestamptz)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'items_picked',   coalesce((select sum(-qty_delta) from inventory_transactions
                                 where txn_type = 'pick' and occurred_at >= p_from and occurred_at < p_to), 0),
    'items_packed',   coalesce((select sum(si.qty) from shipment_items si join shipments sh on sh.id = si.shipment_id
                                 where sh.packed_at >= p_from and sh.packed_at < p_to), 0),
    'labels',         (select count(*) from shipments where labelled_at >= p_from and labelled_at < p_to),
    'orders_shipped', (select count(distinct order_id) from shipments where labelled_at >= p_from and labelled_at < p_to),
    'orders_received',(select count(*) from orders where coalesce(ordered_at, imported_at) >= p_from
                                               and coalesce(ordered_at, imported_at) < p_to)
  )
$$;

create or replace function wms_floor_metrics() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  tz constant text := 'Australia/Adelaide';
  v_now timestamptz := now();
  v_today date := (v_now at time zone tz)::date;
  v_prev date;
  t0 timestamptz; p0 timestamptz; w0 timestamptz; v_elapsed interval;
  v_t jsonb; v_p jsonb; v_w jsonb; v_pfull jsonb; v_wfull jsonb;
  v_score_p numeric; v_score_w numeric;
begin
  if not wms_is_staff() then raise exception 'NOT_STAFF' using errcode = '42501'; end if;
  -- last working day: Mon -> Fri, Sun -> Fri, Sat -> Fri, otherwise yesterday
  v_prev := v_today - case extract(isodow from v_today)::int when 1 then 3 when 7 then 2 else 1 end;
  t0 := (v_today::timestamp) at time zone tz;
  p0 := (v_prev::timestamp) at time zone tz;
  w0 := ((v_today - 7)::timestamp) at time zone tz;
  v_elapsed := v_now - t0;

  v_t := wms__floor_window(t0, v_now + interval '1 second');
  v_p := wms__floor_window(p0, p0 + v_elapsed);
  v_w := wms__floor_window(w0, w0 + v_elapsed);
  v_pfull := wms__floor_window(p0, p0 + interval '1 day');
  v_wfull := wms__floor_window(w0, w0 + interval '1 day');

  select round(100 * avg(least((v_t->>k)::numeric / nullif((v_p->>k)::numeric, 0), 2)))
    into v_score_p from unnest(array['items_picked','items_packed','labels']) k where (v_p->>k)::numeric > 0;
  select round(100 * avg(least((v_t->>k)::numeric / nullif((v_w->>k)::numeric, 0), 2)))
    into v_score_w from unnest(array['items_picked','items_packed','labels']) k where (v_w->>k)::numeric > 0;

  return jsonb_build_object(
    'generated_at', v_now,
    'today', v_today, 'last_working_day', v_prev, 'same_day_last_week', v_today - 7,
    'now', v_t,
    'last_working_day_same_time', v_p,
    'last_week_same_time', v_w,
    'last_working_day_full', v_pfull,
    'last_week_full', v_wfull,
    'to_pick', jsonb_build_object(
       'items',  coalesce((select sum(ol.qty_ordered - ol.qty_picked) from order_lines ol join orders o on o.id = ol.order_id
                            where o.status in ('awaiting_pick','allocated','picking') and not o.is_held), 0),
       'orders', (select count(*) from orders where status in ('awaiting_pick','allocated','picking') and not is_held),
       'on_hold',(select count(*) from orders where is_held and status not in ('shipped','cancelled')),
       'to_pack',(select count(*) from orders where status in ('picked','packing'))),
    'score', jsonb_build_object('vs_last_working_day', v_score_p, 'vs_last_week', v_score_w,
                                'bands', jsonb_build_object('red_below', 85, 'green_from', 100)),
    'top_pickers', coalesce((select jsonb_agg(x order by x->>'units' desc) from (
        select jsonb_build_object('name', s.display_name, 'units', sum(-t.qty_delta)) x
          from inventory_transactions t join staff s on s.id = t.staff_id
         where t.txn_type = 'pick' and t.occurred_at >= t0
         group by s.display_name order by sum(-t.qty_delta) desc limit 5) z), '[]'),
    'top_packers', coalesce((select jsonb_agg(x order by x->>'units' desc) from (
        select jsonb_build_object('name', s.display_name, 'units', sum(si.qty)) x
          from shipment_items si join shipments sh on sh.id = si.shipment_id join staff s on s.id = sh.packed_by
         where sh.packed_at >= t0
         group by s.display_name order by sum(si.qty) desc limit 5) z), '[]'),
    'hourly', (select jsonb_agg(jsonb_build_object('hour', h,
                 'today', coalesce((select sum(-qty_delta) from inventory_transactions where txn_type = 'pick'
                                     and occurred_at >= t0 + make_interval(hours => h) and occurred_at < t0 + make_interval(hours => h + 1)), 0),
                 'last_working_day', coalesce((select sum(-qty_delta) from inventory_transactions where txn_type = 'pick'
                                     and occurred_at >= p0 + make_interval(hours => h) and occurred_at < p0 + make_interval(hours => h + 1)), 0))
                 order by h) from generate_series(7, 17) h)
  );
end $$;

-- ---------------------------------------------------------------------------
-- 5. PERMISSIONS
-- ---------------------------------------------------------------------------
revoke execute on function wms__tote_busy(uuid) from public, anon, authenticated;
revoke execute on function wms__floor_window(timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function wms_assign_totes(uuid, text[]) from public, anon;
revoke execute on function wms_search_inventory(text, int, boolean) from public, anon;
revoke execute on function wms_floor_metrics() from public, anon;
revoke execute on function wms_me() from public, anon;
grant execute on function wms_assign_totes(uuid, text[]) to authenticated;
grant execute on function wms_search_inventory(text, int, boolean) to authenticated;
grant execute on function wms_floor_metrics() to authenticated;
grant execute on function wms_me() to authenticated;
