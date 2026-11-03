-- Tablet picking (migration 017). Rolls itself back.
begin;
do $$
declare u uuid := gen_random_uuid(); u2 uuid := gen_random_uuid(); boss uuid := gen_random_uuid();
        wh uuid; sh uuid; p1 uuid; p2 uuid; p3 uuid; o1 uuid; o2 uuid; c1 uuid; res jsonb; sess uuid; tid uuid; ship uuid;
begin
  insert into auth.users(id, email) values (u, 'pk1@twl.test'), (u2, 'pk2@twl.test'), (boss, 'boss@twl.test');
  insert into staff(id, display_name, role, username) values (u, 'Pia', 'picker', 'pia'), (u2, 'Ned', 'picker', 'ned'), (boss, 'Sue', 'supervisor', 'sue');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', boss::text, true);

  insert into warehouses(code, name, settings) values ('PTST', 'Pick test', '{"pick_scan_cart_to_finish": true, "pack_without_pick": false}') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'A', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', ''), (wh, sh, '02', '', ''), (wh, sh, '03', '', '');
  insert into products(sku, name) values ('PT-TEE', 'Pick Tee') returning id into p1;
  insert into products(sku, name) values ('PT-CAP', 'Pick Cap') returning id into p2;
  insert into products(sku, name) values ('PT-SOCK', 'Pick Sock') returning id into p3;
  insert into product_barcodes(barcode, product_id) values ('PT111', p1), ('PT222', p2), ('PT333', p3);
  perform wms__apply_delta((select id from bins where warehouse_id = wh and code = 'A-01-01'), p1, 10, 'adjust');
  perform wms__apply_delta((select id from bins where warehouse_id = wh and code = 'A-01-02'), p2, 10, 'adjust');
  perform wms__apply_delta((select id from bins where warehouse_id = wh and code = 'A-01-03'), p3, 10, 'adjust');
  insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code) values (wh, 'P1', now(), 'se', 'svc') returning id into o1;
  insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code) values (wh, 'P2', now(), 'se', 'svc') returning id into o2;
  insert into order_lines(order_id, product_id, sku, qty_ordered) values (o1, p1, 'PT-TEE', 2), (o1, p2, 'PT-CAP', 1), (o2, p3, 'PT-SOCK', 1);
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZPCART07', 'ZPCART07', 12) returning id into c1;
  insert into cart_baskets(barcode, kind, warehouse_id) values ('ZT1', 'tote', wh), ('ZT2', 'tote', wh);
  res := wms_build_carts(array[o1, o2], 12, p_cart_ids => array[c1]);
  sess := (res->'carts'->0->>'session_id')::uuid;

  -- picker opens the cart by typing its number
  perform set_config('request.jwt.claim.sub', u::text, true);
  assert exists (select 1 from jsonb_array_elements(wms_pick_carts_available()) x where x->>'cart' = 'ZPCART07' and x->>'state' = 'not_started'), 'listed';
  res := wms_pick_open_cart('ZPCART07');
  assert (res->>'ok')::boolean and jsonb_array_length(res->'need_totes') = 2, res::text;
  res := wms_assign_totes(sess, array['ZT1']); res := wms_assign_totes(sess, array['ZT2']);
  res := wms_pick_state(sess);
  assert jsonb_array_length(res->'need_totes') = 0, res::text;

  -- another picker cannot take it; a supervisor can
  perform set_config('request.jwt.claim.sub', u2::text, true);
  res := wms_pick_open_cart('ZPCART07');
  assert res->>'error' = 'CART_IN_USE' and res->>'picker' = 'Pia', res::text;
  perform set_config('request.jwt.claim.sub', u::text, true);

  -- stop 1: wrong location, right location, scan product with qty 2
  tid := (res->'current'->'task'->>'id')::uuid;
  tid := ((wms_pick_state(sess))->'current'->'task'->>'id')::uuid;
  res := wms_confirm_bin(tid, 'A-01-02');
  assert res->>'error' = 'WRONG_BIN', res::text;
  res := wms_confirm_bin(tid, 'A-01-01');
  assert (res->>'ok')::boolean, res::text;
  res := wms_pick_scan(tid, 'PT111', null, 2);
  assert (res->>'ok')::boolean, res::text;

  -- pause for a break, resume
  res := wms_pick_pause(sess, 'break');
  assert (res->>'ok')::boolean, res::text;
  assert exists (select 1 from jsonb_array_elements(wms_pick_carts_available()) x where x->>'cart' = 'ZPCART07' and x->>'state' = 'paused'), 'paused';
  res := wms_pick_open_cart('7');                       -- cart number only
  assert (res->>'ok')::boolean and res->>'event' = 'resume', res::text;

  -- stop 2: cap not in location -> override; packer will see it
  tid := (res->'current'->'task'->>'id')::uuid;
  res := wms_pick_exception(tid, 'not_in_location', false);
  assert res->>'error' = 'NOT_CONFIRMED', res::text;
  res := wms_pick_exception(tid, 'not_in_location', true);
  assert (res->>'ok')::boolean and res->>'kind' = 'missing', res::text;

  -- stop 3: sock has no barcode -> picked without scan
  tid := (res->'current'->'task'->>'id')::uuid;
  res := wms_pick_exception(tid, 'no_barcode', true);
  assert (res->>'ok')::boolean and res->>'kind' = 'picked_without_scan' and (res->>'all_picked')::boolean, res::text;

  -- everything picked: session waits for the cart scan
  assert (select status from pick_sessions where id = sess) = 'in_progress', 'waits for cart scan';
  res := wms_pick_finish_cart(sess, 'ZT1');
  assert res->>'error' = 'WRONG_CART', res::text;
  res := wms_pick_finish_cart(sess, 'ZPCART07');
  assert (res->>'ok')::boolean and (res->>'units')::int = 3 and jsonb_array_length(res->'missing') = 1, res::text;
  assert (select status from pick_sessions where id = sess) = 'completed', 'completed';
  assert (select status from orders where id = o1) = 'picked' and not (select is_held from orders where id = o1), 'packer decides';
  assert (select status from orders where id = o2) = 'picked', 'o2 picked';

  -- rates
  res := wms_pick_rates();
  assert exists (select 1 from jsonb_array_elements(res) x where x->>'name' = 'Pia' and (x->>'units')::int = 3 and (x->>'carts')::int = 1
                 and (x->>'missing')::int = 1 and (x->>'unscanned')::int = 1), res::text;

  -- pack desk sees the flags and can hold the order
  res := wms_pack_start('ZT1');
  assert (res->>'ok')::boolean and jsonb_array_length(res->'pick_flags') = 1 and res->'pick_flags'->0->>'reason' = 'not_in_location', res::text;
  ship := (res->>'shipment_id')::uuid;
  res := wms_pack_hold(ship, 'Missing PT-CAP');
  assert (res->>'ok')::boolean and (select is_held from orders where id = o1), res::text;

  raise notice 'TABLET PICKING TEST PASSED';
end $$;
rollback;
