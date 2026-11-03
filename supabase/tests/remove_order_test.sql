-- Take one order off a cart (migration 029). Rolls itself back.
begin;
do $$
declare boss uuid := gen_random_uuid(); u uuid := gen_random_uuid(); wh uuid; sh uuid; b1 uuid; b2 uuid; ret uuid; p1 uuid; p2 uuid;
        c1 uuid; o uuid[] := '{}'; oid uuid; res jsonb; sess uuid; st jsonb; tid uuid; i int;
begin
  insert into auth.users(id, email) values (boss, 'ro1@twl.test'), (u, 'ro2@twl.test');
  insert into staff(id, display_name, role, username) values (boss, 'Rae', 'supervisor', 'raero'), (u, 'Rob', 'picker', 'robro');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', boss::text, true);
  insert into warehouses(code, name, settings) values ('ROT', 'Remove test', '{"pick_scan_cart_to_finish": true}') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'A', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', '') returning id into b1;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '02', '', '') returning id into b2;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '09', '', '') returning id into ret;
  insert into products(sku, name) values ('RO-A', 'Remove A') returning id into p1;
  insert into products(sku, name) values ('RO-B', 'Remove B') returning id into p2;
  insert into product_barcodes(barcode, product_id) values ('ROA', p1), ('ROB', p2);
  perform wms__apply_delta(b1, p1, 10, 'adjust'); perform wms__apply_delta(b2, p2, 10, 'adjust');
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZRO1', 'ZRO1', 48) returning id into c1;
  insert into cart_baskets(cart_id, position, barcode, kind, warehouse_id) select c1, p, 'ZRO-' || p, 'tote', wh from generate_series(1, 5) p;
  -- 3 orders: each 1 x A + 1 x B
  for i in 1..3 loop
    insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code) values (wh, 'RO' || i, now() - make_interval(mins => 10 - i), 'se', 'svc') returning id into oid;
    insert into order_lines(order_id, product_id, sku, qty_ordered) values (oid, p1, 'RO-A', 1), (oid, p2, 'RO-B', 1);
    o := o || oid;
  end loop;
  res := wms_build_carts(o, 25, p_cart_ids => array[c1]);
  sess := (res->'carts'->0->>'session_id')::uuid;
  assert (select qty_allocated from bin_inventory where bin_id = b1 and product_id = p1) = 3, 'reserved 3';

  -- picker picks all 3 of A (first stop), nothing of B yet
  perform set_config('request.jwt.claim.sub', u::text, true);
  res := wms_pick_open_cart('ZRO1');
  tid := ((wms_pick_state(sess))->'current'->'task'->>'id')::uuid;
  res := wms_pick_scan(tid, 'ROA', null, 3); assert (res->>'ok')::boolean, res::text;

  -- pickers can't remove orders
  assert wms_remove_order_from_cart(o[2], 'cancel', 'x', null, true)->>'error' = 'FORBIDDEN', 'picker blocked';

  perform set_config('request.jwt.claim.sub', boss::text, true);
  -- preview: RO2 has 1 x A in tote ZRO-2 to put back, 1 x B only reserved
  res := wms_remove_order_from_cart(o[2], 'cancel', null);
  assert (res->>'preview')::boolean and res->>'tote' = 'ZRO-2' and (res->>'units_put_back')::int = 1 and (res->>'units_released')::int = 1
     and res->'put_back'->0->>'sku' = 'RO-A' and (res->>'other_orders')::int = 2, res::text;
  assert wms_remove_order_from_cart(o[2], 'cancel', '  ', null, true)->>'error' = 'REASON_REQUIRED', 'reason';

  -- do it: cancel RO2, put the picked A back to its shelf
  res := wms_remove_order_from_cart(o[2], 'cancel', 'Customer cancelled', null, true);
  assert (res->>'ok')::boolean and (res->>'orders_left')::int = 2, res::text;
  assert (select status from orders where id = o[2]) = 'cancelled', 'cancelled';
  assert (select qty_on_hand from bin_inventory where bin_id = b1 and product_id = p1) = 8, 'A back on shelf (10 - 3 + 1)';
  assert (select qty_allocated from bin_inventory where bin_id = b2 and product_id = p2) = 2, 'B reservation released';
  assert exists (select 1 from inventory_transactions where txn_type = 'unpick' and ref_id = o[2] and qty_delta = 1 and staff_id = boss
                   and reason = 'Removed from cart ZRO1: Customer cancelled'), 'unpick logged';
  assert (select sum(qty_required) from pick_tasks where session_id = sess) = 4 and (select sum(qty_picked) from pick_tasks where session_id = sess) = 2, 'cart shrunk';
  assert not exists (select 1 from pick_session_orders where order_id = o[2]), 'off cart';
  assert (select qty_allocated + qty_picked from order_lines where order_id = o[2] and sku = 'RO-A') = 0, 'lines reset';

  -- requeue RO3 with its item going to a returns location
  res := wms_remove_order_from_cart(o[3], 'requeue', 'Changed address', (select code from bins where id = ret), true);
  assert (res->>'ok')::boolean, res::text;
  assert (select status from orders where id = o[3]) = 'awaiting_pick' and wms__order_ready((select x from orders x where id = o[3])) = 'ready', 'back in queue';
  assert (select qty_on_hand from bin_inventory where bin_id = ret and product_id = p1) = 1, 'to returns location';

  -- picker finishes the cart with the one order left
  perform set_config('request.jwt.claim.sub', u::text, true);
  tid := ((wms_pick_state(sess))->'current'->'task'->>'id')::uuid;
  res := wms_pick_scan(tid, 'ROB', null, 1); assert (res->>'ok')::boolean, res::text;
  res := wms_pick_finish_cart(sess, 'ZRO1'); assert (res->>'ok')::boolean, res::text;
  perform set_config('request.jwt.claim.sub', boss::text, true);

  -- picked and waiting to pack: can still be taken off; last order -> cart free
  res := wms_remove_order_from_cart(o[1], 'hold', 'Customer wants to add items', null, true);
  assert (res->>'ok')::boolean and (res->>'units_put_back')::int = 2, res::text;
  assert (select is_held from orders where id = o[1]) and wms__cart_free(c1), 'held + cart free';
  assert wms_remove_order_from_cart(o[1], 'hold', 'again', null, true)->>'error' = 'NOT_ON_A_CART', 'not on cart';

  raise notice 'REMOVE ORDER TEST PASSED';
end $$;
rollback;
