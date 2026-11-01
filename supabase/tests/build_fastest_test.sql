-- Build carts for the fastest picking (migration 036). Rolls itself back.
begin;
do $$
declare boss uuid := gen_random_uuid(); wh uuid; rowid uuid; c1 uuid; c2 uuid; pw uuid; pe uuid; L text; i int;
        o uuid[] := '{}'; oid uuid; res jsonb; w_urgent real; w_route real; first_cart uuid[];
begin
  insert into auth.users(id, email) values (boss, 'bf1@twl.test');
  insert into staff(id, display_name, role, username) values (boss, 'Bea', 'supervisor', 'beabf');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', boss::text, true);
  insert into warehouses(code, name) values ('BFT', 'Fastest test') returning id into wh;
  insert into walk_config(id, warehouse_id, depot_way, depot_x, way_gap) values (1, wh, 3.5, 0, 0.11)
  on conflict (id) do update set warehouse_id = wh;
  -- aisle G: bays GA-GM, 8 boxes each
  for i in 0 .. 12 loop
    insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'G' || chr(65 + i), i + 1) returning id into rowid;
    insert into shelves(row_id, code, sequence) select rowid, lpad(n::text, 2, '0'), n from generate_series(1, 8) n;
  end loop;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode, location_type)
  select wh, sh.id, '01', '', '', 'pick' from shelves sh join aisle_rows ar on ar.id = sh.row_id
   where ar.warehouse_id = wh and ((ar.code = 'GA' and sh.code = '01') or (ar.code = 'GM' and sh.code = '08'));
  insert into products(sku, name) values ('BF-W', 'West item') returning id into pw;
  insert into products(sku, name) values ('BF-E', 'East item') returning id into pe;
  perform wms__apply_delta((select id from bins where warehouse_id = wh and code = 'GA-01-01'), pw, 50, 'adjust');
  perform wms__apply_delta((select id from bins where warehouse_id = wh and code = 'GM-08-01'), pe, 50, 'adjust');
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZBF1', 'ZBF1', 48) returning id into c1;
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZBF2', 'ZBF2', 48) returning id into c2;
  -- oldest first: west, east, west, east
  for i in 1 .. 4 loop
    insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code, customer_name)
    values (wh, 'BF' || i, now() - make_interval(mins => 10 - i), 'se', 'svc', 'Cust ' || i) returning id into oid;
    insert into order_lines(order_id, product_id, sku, qty_ordered)
    values (oid, case when i % 2 = 1 then pw else pe end, case when i % 2 = 1 then 'BF-W' else 'BF-E' end, 1);
    o := o || oid;
  end loop;

  -- most urgent first: cart 1 = BF1 + BF2 (west and east)
  res := wms_build_carts_sorted(o, 2, null, array[c1, c2], 'urgent');
  assert res->>'sort' = 'urgent' and jsonb_array_length(res->'carts') = 2, res::text;
  select array_agg(pso.order_id order by pso.order_id) into first_cart from pick_session_orders pso where pso.session_id = (res->'carts'->0->>'session_id')::uuid;
  assert first_cart = (select array_agg(x order by x) from unnest(array[o[1], o[2]]) x), 'urgent pairs 1+2';
  select sum((c->>'walk')::real) into w_urgent from jsonb_array_elements(res->'carts') c;
  perform wms_take_cart_apart((res->'carts'->0->>'session_id')::uuid, 'test', null, true);
  perform wms_take_cart_apart((res->'carts'->1->>'session_id')::uuid, 'test', null, true);

  -- fastest picking: cart 1 = BF1 + BF3 (both west), cart 2 = BF2 + BF4 (both east)
  res := wms_build_carts_sorted(o, 2, null, array[c1, c2], 'route');
  assert res->>'sort' = 'route' and jsonb_array_length(res->'carts') = 2, res::text;
  select array_agg(pso.order_id order by pso.order_id) into first_cart from pick_session_orders pso where pso.session_id = (res->'carts'->0->>'session_id')::uuid;
  assert first_cart = (select array_agg(x order by x) from unnest(array[o[1], o[3]]) x), 'route pairs 1+3: ' || res::text;
  select sum((c->>'walk')::real) into w_route from jsonb_array_elements(res->'carts') c;
  assert w_route < w_urgent, format('route walk %s should beat urgent %s', w_route, w_urgent);
  -- the old call still works the old way
  assert wms_build_carts_sorted(o, 2, null, array[c1, c2], 'nope') is null, 'unreachable';
exception when others then
  if sqlerrm like 'BAD_SORT%' then raise exception 'BUILD FASTEST TEST PASSED - all test data rolled back'; end if;
  raise;
end $$;
rollback;
