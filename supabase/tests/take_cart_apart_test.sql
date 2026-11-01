-- Take a cart apart at any stage (migration 030). Rolls itself back.
begin;
do $$
declare boss uuid := gen_random_uuid(); u uuid := gen_random_uuid(); wh uuid; sh uuid; b1 uuid; b2 uuid; p1 uuid; p2 uuid;
        c1 uuid; o uuid[] := '{}'; oid uuid; res jsonb; sess uuid; tid uuid; i int;
begin
  insert into auth.users(id, email) values (boss, 'dc1@twl.test'), (u, 'dc2@twl.test');
  insert into staff(id, display_name, role, username) values (boss, 'Dee', 'supervisor', 'deedc'), (u, 'Dan', 'picker', 'dandc');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', boss::text, true);
  insert into warehouses(code, name, settings) values ('DCT', 'Delete cart test', '{"pick_scan_cart_to_finish": true}') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'A', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', '') returning id into b1;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '02', '', '') returning id into b2;
  insert into products(sku, name) values ('DC-A', 'Del A') returning id into p1;
  insert into products(sku, name) values ('DC-B', 'Del B') returning id into p2;
  insert into product_barcodes(barcode, product_id) values ('DCA', p1), ('DCB', p2);
  perform wms__apply_delta(b1, p1, 10, 'adjust'); perform wms__apply_delta(b2, p2, 10, 'adjust');
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZDC1', 'ZDC1', 48) returning id into c1;
  insert into cart_baskets(cart_id, position, barcode, kind, warehouse_id) select c1, p, 'ZDC-' || p, 'tote', wh from generate_series(1, 5) p;
  for i in 1..3 loop
    insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code) values (wh, 'DC' || i, now() - make_interval(mins => 10 - i), 'se', 'svc') returning id into oid;
    insert into order_lines(order_id, product_id, sku, qty_ordered) values (oid, p1, 'DC-A', 1), (oid, p2, 'DC-B', 1);
    o := o || oid;
  end loop;
  res := wms_build_carts(o, 25, p_cart_ids => array[c1]);
  sess := (res->'carts'->0->>'session_id')::uuid;

  -- assigned to a picker, 3 x A picked
  perform set_config('request.jwt.claim.sub', u::text, true);
  res := wms_pick_open_cart('ZDC1');
  tid := ((wms_pick_state(sess))->'current'->'task'->>'id')::uuid;
  res := wms_pick_scan(tid, 'DCA', null, 3); assert (res->>'ok')::boolean, res::text;
  assert wms_take_cart_apart(sess, null, null, true)->>'error' = 'FORBIDDEN', 'picker blocked';

  perform set_config('request.jwt.claim.sub', boss::text, true);
  res := wms_take_cart_apart(sess);
  assert (res->>'preview')::boolean and (res->>'units_put_back')::int = 3 and (res->>'orders')::int = 3 and res->>'picker' = 'Dan', res::text;

  res := wms_take_cart_apart(sess, 'Rebuilding', null, true);
  assert (res->>'ok')::boolean and jsonb_array_length(res->'orders_back_in_queue') = 3 and (res->>'units_put_back')::int = 3, res::text;
  assert (select status from pick_sessions where id = sess) = 'cancelled', 'cart closed';
  assert (select count(*) from orders where id = any(o) and status = 'awaiting_pick' and not is_held) = 3, 'orders back in queue';
  assert (select qty_on_hand from bin_inventory where bin_id = b1 and product_id = p1) = 10
     and (select qty_allocated from bin_inventory where bin_id = b1 and product_id = p1) = 0
     and (select qty_allocated from bin_inventory where bin_id = b2 and product_id = p2) = 0, 'stock restored';
  assert wms__cart_free(c1), 'cart free';
  -- and they can go straight onto another cart
  res := wms_build_carts(o, 25, p_cart_ids => array[c1]);
  assert (res->>'ok')::boolean and (res->'carts'->0->>'orders')::int = 3, res::text;
  -- a fresh cart (nothing picked) comes apart too
  res := wms_take_cart_apart((res->'carts'->0->>'session_id')::uuid, null, null, true);
  assert (res->>'ok')::boolean and (res->>'units_put_back')::int = 0, res::text;

  raise notice 'TAKE CART APART TEST PASSED';
end $$;
rollback;
