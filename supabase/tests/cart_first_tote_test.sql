-- Choose a cart, confirm with its first tote (migration 031). Rolls itself back.
begin;
do $$
declare boss uuid := gen_random_uuid(); u uuid := gen_random_uuid(); wh uuid; sh uuid; b1 uuid; p1 uuid; c1 uuid; oid uuid; res jsonb; sess uuid; tid uuid;
begin
  insert into auth.users(id, email) values (boss, 'cf1@twl.test'), (u, 'cf2@twl.test');
  insert into staff(id, display_name, role, username) values (boss, 'Cy', 'supervisor', 'cycf'), (u, 'Cal', 'picker', 'calcf');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', boss::text, true);
  insert into warehouses(code, name, settings) values ('CFT', 'First tote test', '{"pick_scan_cart_to_finish": true}') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'A', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', '') returning id into b1;
  insert into products(sku, name) values ('CF-A', 'First A') returning id into p1;
  insert into product_barcodes(barcode, product_id) values ('CFA', p1);
  perform wms__apply_delta(b1, p1, 10, 'adjust');
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZCF1', 'ZCF1', 48) returning id into c1;
  insert into cart_baskets(cart_id, position, barcode, kind, warehouse_id) select c1, p, 'ZCFT' || lpad(p::text, 3, '0'), 'tote', wh from generate_series(1, 3) p;
  insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code) values (wh, 'CF1', now(), 'se', 'svc') returning id into oid;
  insert into order_lines(order_id, product_id, sku, qty_ordered) values (oid, p1, 'CF-A', 1);
  res := wms_build_carts(array[oid], 25, p_cart_ids => array[c1]);
  sess := (res->'carts'->0->>'session_id')::uuid;

  -- the list says which tote confirms the cart
  assert exists (select 1 from jsonb_array_elements(wms_pick_carts_available()) x where x->>'cart' = 'ZCF1' and x->>'first_tote' = 'ZCFT001'), 'first tote';
  -- any fixed tote identifies the cart
  assert (wms__find_cart('zcft001')).code = 'ZCF1' and (wms__find_cart('ZCFT003')).code = 'ZCF1', 'tote -> cart';

  -- picker opens the cart with the first tote, picks, finishes with the first tote
  perform set_config('request.jwt.claim.sub', u::text, true);
  res := wms_pick_open_cart('ZCFT001');
  assert (res->>'ok')::boolean and res->>'cart' = 'ZCF1', res::text;
  tid := ((wms_pick_state(sess))->'current'->'task'->>'id')::uuid;
  res := wms_pick_scan(tid, 'CFA', null, 1); assert (res->>'ok')::boolean, res::text;
  res := wms_pick_finish_cart(sess, 'ZCFT001');
  assert (res->>'ok')::boolean, res::text;

  raise notice 'CART FIRST TOTE TEST PASSED';
end $$;
rollback;
