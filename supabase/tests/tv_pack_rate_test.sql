-- TV items packed per hour (migration 026). Rolls itself back.
begin;
do $$
declare u uuid := gen_random_uuid(); wh uuid; o1 uuid; l1 uuid; s1 uuid; s2 uuid; d timestamptz := '2001-03-05 00:00+10:30'; r jsonb; m jsonb;
begin
  insert into auth.users(id, email) values (u, 'tv1@twl.test');
  insert into staff(id, display_name, role, username) values (u, 'Tia', 'packer', 'tiatv');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', u::text, true);
  insert into warehouses(code, name) values ('TVT', 'TV test') returning id into wh;
  insert into orders(warehouse_id, order_number) values (wh, 'TV1') returning id into o1;
  insert into order_lines(order_id, sku, qty_ordered) values (o1, 'TV-A', 30) returning id into l1;
  -- 10 items at 9:00, 20 items at 11:00 (Adelaide); a voided one at 10:00 is ignored
  insert into shipments(order_id, packed_by, status, packed_at) values (o1, u, 'printed', d + interval '9 hours') returning id into s1;
  insert into shipment_items values (s1, l1, 10);
  insert into shipments(order_id, packed_by, status, packed_at) values (o1, u, 'printed', d + interval '11 hours') returning id into s2;
  insert into shipment_items values (s2, l1, 20);
  insert into shipments(order_id, packed_by, status, packed_at) values (o1, u, 'voided', d + interval '10 hours') returning id into s1;
  insert into shipment_items values (s1, l1, 99);

  -- full day: 30 items over 2 hours (first to last pack) = 15/h
  r := wms__pack_rate(d, d + interval '1 day');
  assert (r->>'items')::int = 30 and (r->>'per_hour')::int = 15, r::text;
  -- same time 10:00: 10 items over 1 hour (9:00 to 10:00) = 10/h
  r := wms__pack_rate(d, d + interval '10 hours');
  assert (r->>'items')::int = 10 and (r->>'per_hour')::int = 10, r::text;
  -- nothing packed
  r := wms__pack_rate(d, d + interval '8 hours');
  assert (r->>'items')::int = 0 and r->>'per_hour' is null, r::text;

  -- floor metrics carries the new sections
  m := wms_floor_metrics();
  assert m ? 'pack_rate' and m->'pack_rate' ? 'today' and m->'pack_rate' ? 'last_working_day_same_time'
     and m->'pack_rate' ? 'this_hour' and jsonb_array_length(m->'hourly_packed') = 11, m->'pack_rate';

  raise notice 'TV PACK RATE TEST PASSED';
end $$;
rollback;
