-- =============================================================================
-- TWL WMS | Migration 017 | Tablet picking (Android + Bluetooth scanner)
--   * scan (or type) a cart -> its pick session opens for this picker
--   * one tote per order is scanned at the start (existing wms_assign_totes)
--   * go to location -> scan location -> scan product (+ quantity)
--   * can't pick? override with warning + reason; the packer sees it later
--   * pause (break / bathroom / end of shift) and resume, with picking time tracked
--   * last item picked -> scan the cart again to finish ("ready for packing")
--   * picking rate per picker (units per active hour, pauses excluded)
-- =============================================================================

alter table pick_sessions add column if not exists paused_at    timestamptz;
alter table pick_sessions add column if not exists pause_reason text;
alter table pick_sessions add column if not exists all_picked_at timestamptz;

-- carts must be scanned again to finish (TWLHQ on; other warehouses default off)
update warehouses set settings = settings || jsonb_build_object('pick_scan_cart_to_finish', code = 'TWLHQ')
 where not settings ? 'pick_scan_cart_to_finish';

create table if not exists pick_session_events (
  id          bigint generated always as identity primary key,
  session_id  uuid not null references pick_sessions(id) on delete cascade,
  staff_id    uuid references staff(id),
  event       text not null check (event in ('start','resume','pause','release','finish','take_over')),
  reason      text,
  occurred_at timestamptz not null default now()
);
create index if not exists pick_session_events_idx on pick_session_events(session_id, occurred_at);
create index if not exists pick_session_events_staff_idx on pick_session_events(staff_id, occurred_at);

create table if not exists pick_exceptions (
  id            bigint generated always as identity primary key,
  occurred_at   timestamptz not null default now(),
  session_id    uuid not null references pick_sessions(id) on delete cascade,
  task_id       uuid not null references pick_tasks(id) on delete cascade,
  order_id      uuid not null references orders(id),
  order_line_id uuid references order_lines(id),
  product_id    uuid references products(id),
  sku           text,
  bin_code      text,
  qty           int not null check (qty > 0),
  kind          text not null check (kind in ('missing','picked_without_scan')),
  reason        text not null check (reason in ('not_in_location','damaged_stock','not_enough','no_barcode','barcode_wont_scan','other')),
  note          text,
  staff_id      uuid references staff(id)
);
create index if not exists pick_exceptions_order_idx on pick_exceptions(order_id);
alter table pick_session_events enable row level security;
alter table pick_exceptions enable row level security;
create policy pick_session_events_read on pick_session_events for select to authenticated using (wms_is_staff());
create policy pick_exceptions_read on pick_exceptions for select to authenticated using (wms_is_staff());

-- ---------------------------------------------------------------------------
-- last task picked: on TWLHQ the session waits for the cart scan instead of
-- closing itself. wms_pick_finish_cart sets wms.finishing so it really closes.
-- ---------------------------------------------------------------------------
create or replace function wms__close_session_if_done(p_session_id uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare s pick_sessions;
begin
  if exists (select 1 from pick_tasks where session_id = p_session_id and status = 'pending') then
    return false;
  end if;
  select * into s from pick_sessions where id = p_session_id;
  if s.cart_id is not null
     and coalesce((select (settings->>'pick_scan_cart_to_finish')::boolean from warehouses where id = s.warehouse_id), false)
     and coalesce(current_setting('wms.finishing', true), '') <> 'on' then
    update pick_sessions set all_picked_at = coalesce(all_picked_at, now()) where id = p_session_id;
    return true;   -- everything picked; waiting for the cart scan
  end if;

  update pick_sessions set status = 'completed', completed_at = now(), paused_at = null where id = p_session_id;
  update orders o set
    status = case
      when not exists (select 1 from order_lines l where l.order_id = o.id and l.qty_picked < l.qty_ordered)
        then 'picked'::order_status
      when exists (select 1 from pick_session_orders x join pick_sessions s2 on s2.id = x.session_id
                    where x.order_id = o.id and s2.id <> p_session_id
                      and s2.status in ('draft','assigned','in_progress'))
        then 'picking'::order_status
      else 'picked'::order_status end          -- short orders still go to the desk: the packer sees the flag and decides
   where o.id in (select order_id from pick_session_orders where session_id = p_session_id);
  return true;
end $$;

-- cart number helpers: "3", "03", "cart3", "CART03" all mean CART03
create or replace function wms__find_cart(p_text text) returns carts
language sql stable security definer set search_path = public as $$
  select c.* from carts c
   where c.is_active and (upper(c.barcode) = upper(trim(p_text)) or upper(c.code) = upper(trim(p_text))
      or (trim(p_text) ~ '^\D*\d{1,3}$' and c.code ~ '\d+$'
          and substring(c.code from '(\d+)$')::int = substring(trim(p_text) from '(\d+)$')::int))
   order by (upper(c.barcode) = upper(trim(p_text))) desc, c.code limit 1
$$;

-- what the picker sees when they open a cart
create or replace function wms__pick_state(p_session_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'session_id', ps.id, 'cart', c.code, 'cart_barcode', c.barcode, 'status', ps.status,
    'paused', ps.paused_at is not null, 'all_picked', ps.all_picked_at is not null,
    'orders', (select count(*) from pick_session_orders where session_id = ps.id),
    'units', (select coalesce(sum(qty_required), 0) from pick_tasks where session_id = ps.id),
    'picked', (select coalesce(sum(qty_picked), 0) from pick_tasks where session_id = ps.id),
    'need_totes', (select coalesce(jsonb_agg(o.order_number order by o.priority, o.ordered_at nulls last, o.order_number), '[]')
                     from pick_session_orders pso join orders o on o.id = pso.order_id
                    where pso.session_id = ps.id and pso.basket_id is null),
    'totes', (select coalesce(jsonb_agg(jsonb_build_object('order_number', o.order_number, 'tote', cb.barcode)
                     order by o.priority, o.ordered_at nulls last, o.order_number), '[]')
                from pick_session_orders pso join orders o on o.id = pso.order_id
                join cart_baskets cb on cb.id = pso.basket_id where pso.session_id = ps.id),
    'exceptions', (select count(*) from pick_exceptions where session_id = ps.id),
    'current', wms_get_current_task(ps.id))
  from pick_sessions ps left join carts c on c.id = ps.cart_id where ps.id = p_session_id
$$;

-- scan / type a cart to start or resume it
create or replace function wms_pick_open_cart(p_cart text, p_take_over boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); v_cart carts; s pick_sessions; v_event text;
begin
  v_cart := wms__find_cart(p_cart);
  if v_cart.id is null then return jsonb_build_object('ok',false,'error','CART_NOT_FOUND','alarm',true); end if;

  select * into s from pick_sessions where cart_id = v_cart.id and status in ('draft','assigned','in_progress')
   order by created_at limit 1 for update;
  if s.id is null then
    return jsonb_build_object('ok',false,'error','NOTHING_ON_CART','cart',v_cart.code);
  end if;

  -- someone else is actively picking this cart (not paused, not released)
  if s.status = 'in_progress' and s.assigned_to is not null and s.assigned_to <> v_staff and s.paused_at is null then
    if not (p_take_over and wms_has_role(array['admin','supervisor']::staff_role[])) then
      return jsonb_build_object('ok',false,'error','CART_IN_USE','cart',v_cart.code,
        'picker',(select display_name from staff where id = s.assigned_to),
        'can_take_over', wms_has_role(array['admin','supervisor']::staff_role[]));
    end if;
    insert into pick_session_events(session_id, staff_id, event, reason) values (s.id, s.assigned_to, 'pause', 'taken over');
    insert into pick_session_events(session_id, staff_id, event) values (s.id, v_staff, 'take_over');
  end if;

  v_event := case when s.started_at is null then 'start' else 'resume' end;
  update pick_sessions set status = 'in_progress', assigned_to = v_staff, started_at = coalesce(started_at, now()),
         paused_at = null, pause_reason = null where id = s.id;
  update orders set status = 'picking'
   where id in (select order_id from pick_session_orders where session_id = s.id) and status in ('awaiting_pick','allocated');
  insert into pick_session_events(session_id, staff_id, event) values (s.id, v_staff, v_event);
  return jsonb_build_object('ok',true,'event',v_event) || wms__pick_state(s.id);
end $$;

-- refresh the screen (eg after the tablet woke up)
create or replace function wms_pick_state(p_session_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform wms__require_staff();
  return wms__pick_state(p_session_id);
end $$;

-- pause: break / bathroom / end of shift (end of shift releases the cart to anyone)
create or replace function wms_pick_pause(p_session_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); s pick_sessions;
begin
  if p_reason not in ('break','bathroom','end_of_shift','other') then
    return jsonb_build_object('ok',false,'error','REASON_REQUIRED');
  end if;
  select * into s from pick_sessions where id = p_session_id for update;
  if s.status <> 'in_progress' then return jsonb_build_object('ok',false,'error','NOT_PICKING'); end if;
  if s.assigned_to <> v_staff and not wms_has_role(array['admin','supervisor']::staff_role[]) then
    return jsonb_build_object('ok',false,'error','NOT_YOUR_CART');
  end if;
  update pick_sessions set paused_at = now(), pause_reason = p_reason,
         assigned_to = case when p_reason = 'end_of_shift' then null else assigned_to end
   where id = s.id;
  insert into pick_session_events(session_id, staff_id, event, reason)
  values (s.id, v_staff, case when p_reason = 'end_of_shift' then 'release' else 'pause' end, p_reason);
  return jsonb_build_object('ok',true,'cart',(select code from carts where id = s.cart_id));
end $$;

-- internal: put units of the current task into the cart without a product scan
create or replace function wms__pick_units(p_task_id uuid, p_units int, p_staff uuid) returns void
language plpgsql security definer set search_path = public as $$
declare t pick_tasks; a record; v_left int := p_units; v_take int;
begin
  select * into t from pick_tasks where id = p_task_id for update;
  for a in select pa.* from pick_allocations pa where pa.task_id = t.id and pa.qty_picked < pa.qty
            order by pa.fill_order for update loop
    exit when v_left = 0;
    v_take := least(v_left, a.qty - a.qty_picked);
    update pick_allocations set qty_picked = qty_picked + v_take where id = a.id;
    update order_lines set qty_picked = qty_picked + v_take where id = a.order_line_id;
    v_left := v_left - v_take;
  end loop;
  perform wms__apply_delta(t.bin_id, t.product_id, -p_units, 'pick', 'pick_task', t.id, p_staff, null, null,
                           'picked without scan', p_units);
  update pick_tasks set qty_picked = qty_picked + p_units, started_at = coalesce(started_at, now()),
         status = case when qty_picked + p_units >= qty_required then 'done'::task_status else 'pending'::task_status end,
         completed_at = case when qty_picked + p_units >= qty_required then now() end
   where id = t.id;
end $$;

-- can't pick: override with a reason (recorded, shown to the packer)
create or replace function wms_pick_exception(
  p_task_id uuid, p_reason text, p_confirmed boolean, p_qty int default null, p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); t pick_tasks; s pick_sessions; v_current uuid; v_left int;
        v_kind text; v_qty int; a record; v_bin text; v_sku text; v_take int; v_done boolean;
begin
  if not coalesce(p_confirmed, false) then return jsonb_build_object('ok',false,'error','NOT_CONFIRMED'); end if;
  if p_reason is null or p_reason not in ('not_in_location','damaged_stock','not_enough','no_barcode','barcode_wont_scan','other') then
    return jsonb_build_object('ok',false,'error','REASON_REQUIRED');
  end if;
  if p_reason = 'other' and coalesce(trim(p_note), '') = '' then return jsonb_build_object('ok',false,'error','NOTE_REQUIRED'); end if;

  select * into t from pick_tasks where id = p_task_id for update;
  if t.id is null or t.status <> 'pending' then return jsonb_build_object('ok',false,'error','TASK_CLOSED'); end if;
  select * into s from pick_sessions where id = t.session_id;
  if s.status <> 'in_progress' or s.paused_at is not null then return jsonb_build_object('ok',false,'error','SESSION_NOT_STARTED'); end if;
  select id into v_current from pick_tasks where session_id = t.session_id and status = 'pending' order by sequence limit 1;
  if v_current <> t.id then return jsonb_build_object('ok',false,'error','NOT_CURRENT_TASK'); end if;

  v_left := t.qty_required - t.qty_picked;
  v_kind := case when p_reason in ('no_barcode','barcode_wont_scan') then 'picked_without_scan' else 'missing' end;
  v_qty := least(greatest(coalesce(p_qty, v_left), 1), v_left);
  select code into v_bin from bins where id = t.bin_id;
  select sku into v_sku from products where id = t.product_id;

  -- one record per order affected (so the packer of each order sees it)
  if v_kind = 'picked_without_scan' then
    v_take := v_qty;
    for a in select pa.* from pick_allocations pa where pa.task_id = t.id and pa.qty_picked < pa.qty order by pa.fill_order loop
      exit when v_take = 0;
      insert into pick_exceptions(session_id, task_id, order_id, order_line_id, product_id, sku, bin_code, qty, kind, reason, note, staff_id)
      values (t.session_id, t.id, a.order_id, a.order_line_id, t.product_id, v_sku, v_bin, least(v_take, a.qty - a.qty_picked),
              v_kind, p_reason, nullif(trim(p_note), ''), v_staff);
      v_take := v_take - least(v_take, a.qty - a.qty_picked);
    end loop;
    perform wms__pick_units(t.id, v_qty, v_staff);
    v_done := wms__close_session_if_done(t.session_id);
  else
    for a in select pa.* from pick_allocations pa where pa.task_id = t.id and pa.qty_picked < pa.qty order by pa.fill_order loop
      insert into pick_exceptions(session_id, task_id, order_id, order_line_id, product_id, sku, bin_code, qty, kind, reason, note, staff_id)
      values (t.session_id, t.id, a.order_id, a.order_line_id, t.product_id, v_sku, v_bin, a.qty - a.qty_picked,
              v_kind, p_reason, nullif(trim(p_note), ''), v_staff);
    end loop;
    perform wms_pick_short(t.id);            -- releases the reservation, logs a cycle count, moves on
    v_done := not exists (select 1 from pick_tasks where session_id = t.session_id and status = 'pending');
  end if;

  return jsonb_build_object('ok',true,'kind',v_kind,'qty',case when v_kind = 'missing' then v_left else v_qty end,
                            'all_picked', v_done) || wms__pick_state(t.session_id);
end $$;

-- scan the cart again to finish: cart goes to packing, session ends
create or replace function wms_pick_finish_cart(p_session_id uuid, p_cart text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); s pick_sessions; v_cart carts; v_units int; v_mins numeric;
begin
  select * into s from pick_sessions where id = p_session_id for update;
  if s.status <> 'in_progress' then return jsonb_build_object('ok',false,'error','NOT_PICKING'); end if;
  v_cart := wms__find_cart(p_cart);
  if v_cart.id is distinct from s.cart_id then
    return jsonb_build_object('ok',false,'error','WRONG_CART','alarm',true,'expected',(select code from carts where id = s.cart_id));
  end if;
  if exists (select 1 from pick_tasks where session_id = s.id and status = 'pending') then
    return jsonb_build_object('ok',false,'error','NOT_FINISHED',
      'left', (select count(*) from pick_tasks where session_id = s.id and status = 'pending'));
  end if;
  perform set_config('wms.finishing', 'on', true);
  perform wms__close_session_if_done(s.id);
  perform set_config('wms.finishing', '', true);
  insert into pick_session_events(session_id, staff_id, event) values (s.id, v_staff, 'finish');

  select coalesce(sum(qty_picked), 0) into v_units from pick_tasks where session_id = s.id;
  v_mins := wms__active_minutes(s.id, v_staff);
  return jsonb_build_object('ok',true,'cart',v_cart.code,'units',v_units,'orders',(select count(*) from pick_session_orders where session_id = s.id),
    'minutes', round(v_mins, 1), 'units_per_hour', case when v_mins > 0 then round(v_units / (v_mins / 60.0)) end,
    'missing', (select coalesce(jsonb_agg(jsonb_build_object('order_number', o.order_number, 'sku', e.sku, 'qty', e.qty, 'reason', e.reason)), '[]')
                  from pick_exceptions e join orders o on o.id = e.order_id where e.session_id = s.id and e.kind = 'missing'));
end $$;

-- active picking minutes for one picker on one session (pauses excluded)
create or replace function wms__active_minutes(p_session_id uuid, p_staff uuid,
  p_from timestamptz default '-infinity', p_to timestamptz default 'infinity') returns numeric
language sql stable security definer set search_path = public as $$
  with ev as (
    select event, staff_id, occurred_at, lead(occurred_at) over (order by occurred_at, id) as nxt
      from pick_session_events where session_id = p_session_id
  ), spans as (
    select greatest(e.occurred_at, p_from) as a,
           least(coalesce(e.nxt,
                          (select max(it.occurred_at) from inventory_transactions it join pick_tasks t on t.id = it.ref_id
                            where t.session_id = p_session_id and it.staff_id = p_staff),
                          e.occurred_at), p_to) as b
      from ev e
     where e.event in ('start','resume','take_over') and e.staff_id = p_staff
  )
  select coalesce(sum(extract(epoch from (b - a)) / 60.0) filter (where b > a), 0) from spans
$$;

-- carts a picker can go to next
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

-- picking rates for a day (Adelaide time): units, carts, active hours, units/hour, overrides
create or replace function wms_pick_rates(p_day date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_day, (now() at time zone 'Australia/Adelaide')::date);
        t0 timestamptz := d::timestamp at time zone 'Australia/Adelaide';
        t1 timestamptz := (d + 1)::timestamp at time zone 'Australia/Adelaide';
begin
  if not wms_is_staff() then raise exception 'NOT_STAFF' using errcode = '42501'; end if;
  return (
    with units as (
      select it.staff_id, sum(-it.qty_delta) as units
        from inventory_transactions it
       where it.txn_type = 'pick' and it.ref_type = 'pick_task' and it.occurred_at >= t0 and it.occurred_at < t1
       group by it.staff_id
    ), mins as (
      select e.staff_id, sum(wms__active_minutes(e.session_id, e.staff_id, t0, t1)) as minutes
        from (select distinct session_id, staff_id from pick_session_events
               where occurred_at >= t0 - interval '1 day' and occurred_at < t1 and staff_id is not null) e
       group by e.staff_id
    ), carts as (
      select staff_id, count(*) as carts from pick_session_events
       where event = 'finish' and occurred_at >= t0 and occurred_at < t1 group by staff_id
    ), exc as (
      select staff_id, count(*) filter (where kind = 'missing') as missing,
             count(*) filter (where kind = 'picked_without_scan') as unscanned
        from pick_exceptions where occurred_at >= t0 and occurred_at < t1 group by staff_id
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'staff_id', st.id, 'name', st.display_name, 'units', coalesce(u.units, 0), 'carts', coalesce(c.carts, 0),
             'active_minutes', round(coalesce(m.minutes, 0), 0),
             'units_per_hour', case when coalesce(m.minutes, 0) >= 1 then round(coalesce(u.units, 0) / (m.minutes / 60.0)) end,
             'missing', coalesce(x.missing, 0), 'unscanned', coalesce(x.unscanned, 0))
           order by coalesce(u.units, 0) desc), '[]')
      from staff st
      left join units u on u.staff_id = st.id left join mins m on m.staff_id = st.id
      left join carts c on c.staff_id = st.id left join exc x on x.staff_id = st.id
     where coalesce(u.units, 0) > 0 or coalesce(m.minutes, 0) > 0
  );
end $$;

-- ---------------------------------------------------------------------------
-- pack desk: show what the picker flagged, and let the packer hold the order
-- ---------------------------------------------------------------------------
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
                 'remaining', l.qty_ordered - l.qty_packed,
                 'pick_flag', (select jsonb_agg(jsonb_build_object('kind', e.kind, 'reason', e.reason, 'qty', e.qty,
                                      'bin', e.bin_code, 'picker', (select display_name from staff where id = e.staff_id), 'note', e.note))
                                 from pick_exceptions e where e.order_line_id = l.id))
                 order by (l.qty_ordered - l.qty_packed) = 0, l.sku)
                from order_lines l left join products p on p.id = l.product_id where l.order_id = o.id),
    'pick_flags', (select coalesce(jsonb_agg(jsonb_build_object('kind', e.kind, 'reason', e.reason, 'qty', e.qty, 'sku', e.sku,
                                      'bin', e.bin_code, 'picker', (select display_name from staff where id = e.staff_id), 'note', e.note)
                                      order by e.occurred_at), '[]')
                     from pick_exceptions e where e.order_id = o.id),
    'units_total', (select sum(qty_ordered) from order_lines where order_id = o.id),
    'units_packed', (select sum(qty_packed) from order_lines where order_id = o.id),
    'complete', not exists (select 1 from order_lines l where l.order_id = o.id and l.qty_packed < l.qty_ordered))
  from shipments sh join orders o on o.id = sh.order_id where sh.id = p_shipment_id
$$;

-- any packer can put the order they are packing on hold (eg missing item)
create or replace function wms_pack_hold(p_shipment_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); sh shipments;
begin
  if coalesce(trim(p_reason), '') = '' then return jsonb_build_object('ok',false,'error','REASON_REQUIRED'); end if;
  select * into sh from shipments where id = p_shipment_id for update;
  if sh.id is null or sh.status not in ('packing','packed','failed') then return jsonb_build_object('ok',false,'error','NOT_PACKING'); end if;
  update orders set is_held = true, hold_reason = trim(p_reason), held_at = now(), held_by = v_staff where id = sh.order_id;
  return jsonb_build_object('ok',true);
end $$;

revoke execute on function wms__find_cart(text) from public, anon, authenticated;
revoke execute on function wms__pick_state(uuid) from public, anon, authenticated;
revoke execute on function wms__pick_units(uuid, int, uuid) from public, anon, authenticated;
revoke execute on function wms__active_minutes(uuid, uuid, timestamptz, timestamptz) from public, anon, authenticated;
revoke execute on function wms_pick_open_cart(text, boolean) from public, anon;
revoke execute on function wms_pick_state(uuid) from public, anon;
revoke execute on function wms_pick_pause(uuid, text) from public, anon;
revoke execute on function wms_pick_exception(uuid, text, boolean, int, text) from public, anon;
revoke execute on function wms_pick_finish_cart(uuid, text) from public, anon;
revoke execute on function wms_pick_carts_available() from public, anon;
revoke execute on function wms_pick_rates(date) from public, anon;
revoke execute on function wms_pack_hold(uuid, text) from public, anon;
grant execute on function wms_pick_open_cart(text, boolean) to authenticated;
grant execute on function wms_pick_state(uuid) to authenticated;
grant execute on function wms_pick_pause(uuid, text) to authenticated;
grant execute on function wms_pick_exception(uuid, text, boolean, int, text) to authenticated;
grant execute on function wms_pick_finish_cart(uuid, text) to authenticated;
grant execute on function wms_pick_carts_available() to authenticated;
grant execute on function wms_pick_rates(date) to authenticated;
grant execute on function wms_pack_hold(uuid, text) to authenticated;
grant execute on function wms_confirm_bin(uuid, text, uuid) to authenticated;
grant execute on function wms_assign_totes(uuid, text[]) to authenticated;
