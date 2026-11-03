-- Orders queue + build carts + cart view (migration 016). Rolls itself back.
begin;
do $$
declare u uuid := gen_random_uuid(); pk uuid := gen_random_uuid(); wh uuid; sh uuid; p1 uuid; p2 uuid;
        o1 uuid; o2 uuid; o3 uuid; o4 uuid; o5 uuid; c1 uuid; c2 uuid; res jsonb; sess uuid; i int;
begin
  insert into auth.users(id, email) values (u, 'cart@twl.test'), (pk, 'picker@twl.test');
  insert into staff(id, display_name, role, username) values (u, 'Cart Boss', 'supervisor', 'cart.boss'), (pk, 'Pat Picker', 'picker', 'pat.p');
  perform set_config('request.jwt.claim.sub', u::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);

  insert into warehouses(code, name) values ('CTST', 'Cart test') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'A', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', ''), (wh, sh, '02', '', '');
  insert into products(sku, name, weight_grams) values ('CT-TEE', 'Cart Tee', 200) returning id into p1;
  insert into products(sku, name, weight_grams) values ('CT-CAP', 'Cart Cap', 100) returning id into p2;
  perform wms__apply_delta((select id from bins where warehouse_id = wh and code = 'A-01-01'), p1, 20, 'adjust');
  perform wms__apply_delta((select id from bins where warehouse_id = wh and code = 'A-01-02'), p2, 1, 'adjust');

  insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code, priority) values
    (wh, 'C1', now() - interval '3 hours', 'se-1', 'svc', 100) returning id into o1;
  insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code, priority) values
    (wh, 'C2', now() - interval '1 hour', 'se-1', 'svc', 50) returning id into o2;       -- express
  insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code) values
    (wh, 'C3', now() - interval '2 hours', 'se-1', 'svc') returning id into o3;
  insert into orders(warehouse_id, order_number, ordered_at) values (wh, 'C4', now()) returning id into o4;  -- no service
  insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code, is_held, hold_reason) values
    (wh, 'C5', now(), 'se-1', 'svc', true, 'Fraud check') returning id into o5;
  insert into order_lines(order_id, product_id, sku, qty_ordered) values
    (o1, p1, 'CT-TEE', 2), (o2, p1, 'CT-TEE', 1), (o2, p2, 'CT-CAP', 1), (o3, p1, 'CT-TEE', 1), (o4, p1, 'CT-TEE', 1), (o5, p1, 'CT-TEE', 1);
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZCART1', 'ZCART1', 2) returning id into c1;
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZCART2', 'ZCART2', 12) returning id into c2;

  -- queue
  res := wms_order_queue('all', 'C');
  assert exists (select 1 from jsonb_array_elements(res->'orders') x where x->>'order_number' = 'C4' and x->>'ready' = 'no_service'), res::text;
  assert exists (select 1 from jsonb_array_elements(res->'orders') x where x->>'order_number' = 'C5' and x->>'ready' = 'on_hold'), res::text;

  -- pickers can't build carts
  perform set_config('request.jwt.claim.sub', pk::text, true);
  begin perform wms_build_carts(array[o1,o2,o3], 12, p_cart_ids => array[c1,c2]); assert false, 'picker must not build carts';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub', u::text, true);

  -- build: 2 per cart; express C2 first, then C3 (older than C1? no: C1 is oldest) -> C2, C1 on ZCART1; C3 on ZCART2
  res := wms_build_carts(array[o1,o2,o3,o4,o5], 2, p_cart_ids => array[c1,c2]);
  assert (res->>'ok')::boolean and jsonb_array_length(res->'carts') = 2, res::text;
  assert jsonb_array_length(res->'skipped') = 2, 'no-service and held orders skipped: ' || res::text;
  assert res->'carts'->0->>'cart' = 'ZCART1' and (res->'carts'->0->>'orders')::int = 2, res::text;
  sess := (res->'carts'->0->>'session_id')::uuid;
  assert exists (select 1 from pick_session_orders where session_id = sess and order_id = o2), 'express order on first cart';
  assert (select status from orders where id = o2) = 'allocated', 'order allocated';

  -- cart now busy: building again finds no free cart among these two
  res := wms_build_carts(array[o1], 2, p_cart_ids => array[c1,c2]);
  assert res->>'error' in ('NO_READY_ORDERS','NO_FREE_CARTS'), res::text;

  -- overview + detail with locations
  assert exists (select 1 from jsonb_array_elements(wms_carts_overview()) x where x->>'cart' = 'ZCART1' and (x->>'orders')::int = 2), 'overview';
  res := wms_cart_detail(sess);
  assert res->'picks'->0->>'bin' = 'A-01-01' and jsonb_array_length(res->'orders') = 2, res::text;
  assert res->'picks'->0->'split' is not null, res::text;

  -- cancel: stock and orders released
  res := wms_cancel_pick_session(sess);
  assert (res->>'ok')::boolean, res::text;
  assert (select status from orders where id = o2) = 'awaiting_pick', 'released';
  assert (select qty_allocated from bin_inventory where product_id = p2) = 0, 'cap allocation released';
  assert (select qty_allocated from order_lines where order_id = o2 and sku = 'CT-CAP') = 0, 'line released';

  raise notice 'ORDERS/CARTS TEST PASSED';
end $$;
rollback;
