-- Unassign picker (migration 021). Rolls itself back.
begin;
do $$
declare u uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); boss uuid := gen_random_uuid();
        wh uuid; sh uuid; p1 uuid; o1 uuid; c1 uuid; res jsonb; sess uuid; tid uuid;
begin
  insert into auth.users(id, email) values (u, 'r1@twl.test'), (u2, 'r2@twl.test'), (boss, 'rb@twl.test');
  insert into staff(id, display_name, role, username) values (u, 'Rita', 'picker', 'rita'), (u2, 'Ron', 'picker', 'ron'), (boss, 'Rex', 'supervisor', 'rex');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', boss::text, true);
  insert into warehouses(code, name, settings) values ('RTST2', 'Release test', '{"pick_scan_cart_to_finish": true}') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'A', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', '');
  insert into products(sku, name) values ('RL-TEE', 'Release Tee') returning id into p1;
  insert into product_barcodes(barcode, product_id) values ('RL111', p1);
  perform wms__apply_delta((select id from bins where warehouse_id = wh), p1, 10, 'adjust');
  insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code) values (wh, 'R1', now(), 'se', 'svc') returning id into o1;
  insert into order_lines(order_id, product_id, sku, qty_ordered) values (o1, p1, 'RL-TEE', 3);
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZRC1', 'ZRC1', 48) returning id into c1;
  insert into cart_baskets(barcode, kind, warehouse_id) values ('ZR-T1', 'tote', wh);
  res := wms_build_carts(array[o1], 12, p_cart_ids => array[c1]);
  sess := (res->'carts'->0->>'session_id')::uuid;

  -- Rita starts and picks 1 of 3
  perform set_config('request.jwt.claim.sub', u::text, true);
  res := wms_pick_open_cart('ZRC1'); res := wms_assign_totes(sess, array['ZR-T1']);
  tid := ((wms_pick_state(sess))->'current'->'task'->>'id')::uuid;
  res := wms_pick_scan(tid, 'RL111', null, 1);
  assert (res->>'ok')::boolean, res::text;

  -- pickers can't unassign; supervisor can
  res := wms_release_cart(sess);
  assert res->>'error' = 'FORBIDDEN', res::text;
  perform set_config('request.jwt.claim.sub', boss::text, true);
  res := wms_release_cart(sess, 'Rita went home');
  assert (res->>'ok')::boolean and res->>'was' = 'Rita', res::text;
  assert exists (select 1 from jsonb_array_elements(wms_carts_overview()) x where x->>'cart' = 'ZRC1' and (x->>'paused')::boolean and x->>'picker' is null), 'overview';

  -- Rita's tablet can't keep scanning
  perform set_config('request.jwt.claim.sub', u::text, true);
  res := wms_pick_scan(tid, 'RL111', null, 1);
  assert res->>'error' = 'CART_PAUSED', res::text;

  -- Ron takes it over: same tote, 1 already picked, carries on
  perform set_config('request.jwt.claim.sub', u2::text, true);
  assert exists (select 1 from jsonb_array_elements(wms_pick_carts_available()) x where x->>'cart' = 'ZRC1' and x->>'state' = 'released'), 'listed as needs a picker';
  res := wms_pick_open_cart('ZRC1');
  assert (res->>'ok')::boolean and res->>'event' = 'resume' and (res->>'picked')::int = 1 and jsonb_array_length(res->'need_totes') = 0, res::text;
  res := wms_pick_scan(tid, 'RL111', null, 2);
  assert (res->>'ok')::boolean and (res->>'task_done')::boolean, res::text;
  -- Rita still can't scan Ron's cart
  perform set_config('request.jwt.claim.sub', u::text, true);
  res := wms_pick_scan(tid, 'RL111', null, 1);
  assert res->>'error' in ('NOT_YOUR_CART','OVER_QTY','NOT_CURRENT_TASK','TASK_NOT_FOUND') , res::text;

  raise notice 'RELEASE CART TEST PASSED';
end $$;
rollback;
