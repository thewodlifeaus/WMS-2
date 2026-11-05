-- =============================================================================
-- TWL WMS | Migration 037 | Cart stages + cart history (Ben, 5 Nov 2026)
--   Carts tab: a finished cart shows "Ready for packing" until every order on it
--   is packed (or shipped / cancelled), then "Picked & Packed". A picked cart
--   waiting to be packed stays on the board even from an earlier day.
--   History tab: every cart built today and on the last working day (Mon = Fri
--   + Mon), including carts taken apart, with a timeline: built, picking
--   started / paused / resumed / released / taken over / finished, missing
--   items, each order packed, taken apart.
-- =============================================================================

create or replace function wms__cart_stage(p_session uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when ps.status in ('draft','assigned','in_progress') then ps.status::text
    when ps.status = 'cancelled' then 'taken_apart'
    when exists (select 1 from pick_session_orders pso join orders o on o.id = pso.order_id
                  where pso.session_id = ps.id and o.status not in ('packed','shipped','cancelled')) then 'ready_to_pack'
    else 'picked_packed' end
  from pick_sessions ps where ps.id = p_session
$$;

create or replace function wms_carts_overview() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'sort'), '[]') from (
    select jsonb_build_object(
      'session_id', ps.id, 'cart', coalesce(c.code, '(no cart)'), 'status', ps.status, 'stage', st.stage, 'method', ps.method,
      'created_at', ps.created_at, 'started_at', ps.started_at, 'completed_at', ps.completed_at,
      'created_by', (select display_name from staff where id = ps.created_by),
      'picker', (select display_name from staff where id = ps.assigned_to),
      'paused', ps.paused_at is not null, 'pause_reason', ps.pause_reason,
      'group', wms__session_groups(ps.id),
      'orders', (select count(*) from pick_session_orders where session_id = ps.id),
      'orders_packed', (select count(*) from pick_session_orders pso join orders o on o.id = pso.order_id
                         where pso.session_id = ps.id and o.status in ('packed','shipped','cancelled')),
      'last_packed_at', (select max(sh.packed_at) from pick_session_orders pso join shipments sh on sh.order_id = pso.order_id
                          where pso.session_id = ps.id and sh.status <> 'voided'),
      'totes', (select count(basket_id) from pick_session_orders where session_id = ps.id),
      'units', (select coalesce(sum(qty_required), 0) from pick_tasks where session_id = ps.id),
      'picked', (select coalesce(sum(qty_picked), 0) from pick_tasks where session_id = ps.id),
      'stops', (select count(*) from pick_tasks where session_id = ps.id),
      'stops_done', (select count(*) from pick_tasks where session_id = ps.id and status in ('done','short')),
      'walk', ps.walk_length,
      'first_bin', (select b.code from pick_tasks t join bins b on b.id = t.bin_id where t.session_id = ps.id order by t.sequence limit 1),
      'sort', case st.stage when 'in_progress' then '1' when 'assigned' then '2' when 'draft' then '3'
                            when 'ready_to_pack' then '4' else '5' end || coalesce(c.code, 'zz')
    ) x
      from pick_sessions ps left join carts c on c.id = ps.cart_id
      cross join lateral (select wms__cart_stage(ps.id) as stage) st
     where wms_is_staff()
       and (ps.status in ('draft','assigned','in_progress')
            or (ps.status = 'completed' and (st.stage = 'ready_to_pack'
                 or ps.completed_at >= date_trunc('day', now() at time zone 'Australia/Adelaide') at time zone 'Australia/Adelaide')))
  ) t
$$;

-- carts built between two Adelaide days (default: last working day to today)
create or replace function wms_cart_history(p_from date default null, p_to date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  tz constant text := 'Australia/Adelaide';
  v_today date := (now() at time zone tz)::date;
  v_from date; v_to date; d0 timestamptz; d1 timestamptz; v jsonb;
begin
  if not wms_is_staff() then raise exception 'NOT_STAFF' using errcode = '42501'; end if;
  v_to := coalesce(p_to, v_today);
  v_from := coalesce(p_from, v_today - case extract(isodow from v_today)::int when 1 then 3 when 7 then 2 else 1 end);
  if v_to - v_from > 31 then v_from := v_to - 31; end if;
  d0 := v_from::timestamp at time zone tz; d1 := (v_to + 1)::timestamp at time zone tz;

  select coalesce(jsonb_agg(r order by r->>'created_at' desc), '[]') into v from (
    select jsonb_build_object(
      'session_id', ps.id, 'cart', coalesce(c.code, '(no cart)'), 'status', ps.status, 'stage', wms__cart_stage(ps.id),
      'group', wms__session_groups(ps.id),
      'created_at', ps.created_at, 'started_at', ps.started_at, 'completed_at', ps.completed_at,
      'created_by', (select display_name from staff where id = ps.created_by),
      'pickers', (select coalesce(jsonb_agg(distinct s.display_name), '[]') from staff s
                   where s.id = ps.assigned_to
                      or s.id in (select e.staff_id from pick_session_events e where e.session_id = ps.id)),
      'packers', (select coalesce(jsonb_agg(distinct s.display_name), '[]') from pick_session_orders pso
                    join shipments sh on sh.order_id = pso.order_id and sh.status <> 'voided'
                    join staff s on s.id = sh.packed_by where pso.session_id = ps.id),
      'orders', (select count(*) from pick_session_orders where session_id = ps.id),
      'orders_packed', (select count(*) from pick_session_orders pso join orders o on o.id = pso.order_id
                         where pso.session_id = ps.id and o.status in ('packed','shipped')),
      'units', (select coalesce(sum(qty_required), 0) from pick_tasks where session_id = ps.id and status <> 'cancelled'),
      'picked', (select coalesce(sum(qty_picked), 0) from pick_tasks where session_id = ps.id),
      'missing', (select coalesce(sum(qty), 0) from pick_exceptions where session_id = ps.id and kind = 'missing'),
      'not_scanned', (select coalesce(sum(qty), 0) from pick_exceptions where session_id = ps.id and kind = 'picked_without_scan'),
      'walk', ps.walk_length,
      'first_packed_at', (select min(sh.packed_at) from pick_session_orders pso join shipments sh on sh.order_id = pso.order_id
                           where pso.session_id = ps.id and sh.status <> 'voided'),
      'last_packed_at', (select max(sh.packed_at) from pick_session_orders pso join shipments sh on sh.order_id = pso.order_id
                          where pso.session_id = ps.id and sh.status <> 'voided'),
      'timeline', (select coalesce(jsonb_agg(ev order by ev->>'at'), '[]') from (
          select jsonb_build_object('at', ps.created_at, 'what', 'built',
                   'who', (select display_name from staff where id = ps.created_by),
                   'note', (select count(*) from pick_session_orders where session_id = ps.id) || ' orders') ev
          union all
          select jsonb_build_object('at', e.occurred_at, 'what', e.event, 'who', s.display_name, 'note', e.reason)
            from pick_session_events e left join staff s on s.id = e.staff_id where e.session_id = ps.id
          union all   -- older carts without a start event
          select jsonb_build_object('at', ps.started_at, 'what', 'start', 'who', null, 'note', null)
           where ps.started_at is not null
             and not exists (select 1 from pick_session_events e where e.session_id = ps.id and e.event = 'start')
          union all
          select jsonb_build_object('at', ps.completed_at, 'what', 'finish', 'who', null, 'note', null)
           where ps.status = 'completed' and ps.completed_at is not null
             and not exists (select 1 from pick_session_events e where e.session_id = ps.id and e.event = 'finish')
          union all
          select jsonb_build_object('at', x.occurred_at, 'what', x.kind, 'who', s.display_name,
                   'note', x.qty || ' × ' || coalesce(x.sku, '') || ' at ' || coalesce(x.bin_code, '') || ' (' || replace(x.reason, '_', ' ') || ')'
                           || coalesce(' #' || o.order_number, ''))
            from pick_exceptions x left join staff s on s.id = x.staff_id left join orders o on o.id = x.order_id
           where x.session_id = ps.id
          union all
          select jsonb_build_object('at', sh.packed_at, 'what', 'packed', 'who', s.display_name, 'note', '#' || o.order_number)
            from pick_session_orders pso join orders o on o.id = pso.order_id
            join shipments sh on sh.order_id = o.id and sh.status <> 'voided' and sh.packed_at is not null
            left join staff s on s.id = sh.packed_by
           where pso.session_id = ps.id
          union all
          select jsonb_build_object('at', ps.completed_at, 'what', 'taken_apart', 'who', null, 'note', null)
           where ps.status = 'cancelled' and ps.completed_at is not null) t)
    ) r
      from pick_sessions ps left join carts c on c.id = ps.cart_id
     where ps.created_at >= d0 and ps.created_at < d1
  ) q;

  return jsonb_build_object('from', v_from, 'to', v_to, 'carts', v);
end $$;

revoke execute on function wms__cart_stage(uuid) from public, anon, authenticated;
revoke execute on function wms_cart_history(date, date) from public, anon;
grant execute on function wms_cart_history(date, date) to authenticated;
