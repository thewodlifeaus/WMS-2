-- =============================================================================
-- TWL WMS | Migration 026 | TV: items packed per hour vs last working day
--   pack_rate: items packed ÷ packing hours (first pack of the day to now (or the
--   same clock time), or to the last pack for a finished day), for today, last working day at the same
--   time, and last working day in full. Plus this hour vs the same hour, and an
--   hourly packed chart (7am-5pm Adelaide). Voided (test/reset) labels ignored.
-- =============================================================================

create or replace function wms__pack_rate(p_from timestamptz, p_to timestamptz)
returns jsonb language sql stable security definer set search_path = public as $$
  with p as (
    select sh.packed_at, (select coalesce(sum(qty), 0) from shipment_items where shipment_id = sh.id) as items
      from shipments sh where sh.packed_at >= p_from and sh.packed_at < p_to and sh.status <> 'voided'
  ), s as (
    select coalesce(sum(items), 0) as items, min(packed_at) as first_at, max(packed_at) as last_at from p
  )
  select jsonb_build_object('items', s.items, 'first_at', s.first_at,
    -- hours: from the first pack to the end of the window (or to now), or to the last pack for a full day; at least 15 minutes
    'hours', round(greatest(extract(epoch from (case when p_to - p_from >= interval '1 day' then s.last_at else least(p_to, now()) end) - s.first_at) / 3600, 0.25)::numeric, 2),
    'per_hour', case when s.items > 0 then round(s.items / greatest(extract(epoch from (case when p_to - p_from >= interval '1 day' then s.last_at else least(p_to, now()) end) - s.first_at) / 3600, 0.25)) end)
  from s
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
  v_hour timestamptz := date_trunc('hour', now() at time zone 'Australia/Adelaide') at time zone 'Australia/Adelaide';
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
                 order by h) from generate_series(7, 17) h),
    -- items packed per hour (026): average pace today vs last working day, and by hour
    'pack_rate', jsonb_build_object(
       'today',            wms__pack_rate(t0, v_now),
       'last_working_day_same_time', wms__pack_rate(p0, p0 + v_elapsed),
       'last_working_day_full',      wms__pack_rate(p0, p0 + interval '1 day'),
       'this_hour', jsonb_build_object(
          'hour', extract(hour from v_now at time zone tz)::int,
          'today', coalesce((select sum(si.qty) from shipment_items si join shipments sh on sh.id = si.shipment_id
                              where sh.packed_at >= v_hour and sh.packed_at < v_now and sh.status <> 'voided'), 0),
          'last_working_day', coalesce((select sum(si.qty) from shipment_items si join shipments sh on sh.id = si.shipment_id
                              where sh.packed_at >= p0 + (v_hour - t0) and sh.packed_at < p0 + (v_hour - t0) + interval '1 hour'
                                and sh.status <> 'voided'), 0))),
    'hourly_packed', (select jsonb_agg(jsonb_build_object('hour', h,
                 'today', coalesce((select sum(si.qty) from shipment_items si join shipments sh on sh.id = si.shipment_id
                                     where sh.status <> 'voided' and sh.packed_at >= t0 + make_interval(hours => h) and sh.packed_at < t0 + make_interval(hours => h + 1)), 0),
                 'last_working_day', coalesce((select sum(si.qty) from shipment_items si join shipments sh on sh.id = si.shipment_id
                                     where sh.status <> 'voided' and sh.packed_at >= p0 + make_interval(hours => h) and sh.packed_at < p0 + make_interval(hours => h + 1)), 0))
                 order by h) from generate_series(7, 17) h)
  );
end $$;

revoke execute on function wms__pack_rate(timestamptz, timestamptz) from public, anon, authenticated;
