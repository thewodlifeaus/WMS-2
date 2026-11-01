-- Totes fixed to carts + find an order (migration 028). Rolls itself back.
begin;
do $$
declare boss uuid := gen_random_uuid(); u uuid := gen_random_uuid(); wh uuid; sh uuid; bn uuid; p1 uuid;
        c1 uuid; c2 uuid; o uuid[] := '{}'; oid uuid; res jsonb; sess uuid; st jsonb; tid uuid; i int;
begin
  insert into auth.users(id, email) values (boss, 'ft1@twl.test'), (u, 'ft2@twl.test');
  insert into staff(id, display_name, role, username) values (boss, 'Fay', 'supervisor', 'fayft'), (u, 'Fin', 'picker', 'finft');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', boss::text, true);
  insert into warehouses(code, name, settings) values ('FTT', 'Fixed tote test', '{"pick_scan_cart_to_finish": true}') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'A', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', '') returning id into bn;
  insert into products(sku, name) values ('FT-TEE', 'Fixed Tee') returning id into p1;
  insert into product_barcodes(barcode, product_id) values ('FT111', p1);
  perform wms__apply_delta(bn, p1, 100, 'adjust');
  -- two carts with 3 fixed totes each
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZFT1', 'ZFT1', 48) returning id into c1;
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZFT2', 'ZFT2', 48) returning id into c2;
  insert into cart_baskets(cart_id, position, barcode, kind, warehouse_id)
  select c, p, 'ZFT' || n || '-' || p, 'tote', wh from (values (c1, 1), (c2, 2)) v(c, n), generate_series(1, 3) p;
  -- 5 orders of 1 unit
  for i in 1..5 loop
    insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code, customer_name)
    values (wh, 'FT' || i, now() - make_interval(mins => 10 - i), 'se', 'svc', 'Cust ' || i) returning id into oid;
    insert into order_lines(order_id, product_id, sku, qty_ordered) values (oid, p1, 'FT-TEE', 1);
    o := o || oid;
  end loop;

  -- asked for 12 totes per cart, but each cart only has 3: 3 + 2 orders, never split
  res := wms_build_carts(o, 12, p_cart_ids => array[c1, c2]);
  assert (res->>'ok')::boolean and jsonb_array_length(res->'carts') = 2, res::text;
  assert (res->'carts'->0->>'orders')::int = 3 and (res->'carts'->1->>'orders')::int = 2, res::text;
  -- totes already assigned: oldest order FT1 in tote 1 of the first cart
  assert (select cb.barcode from pick_session_orders pso join cart_baskets cb on cb.id = pso.basket_id where pso.order_id = o[1]) = 'ZFT1-1', 'FT1 tote';
  assert (select cb.barcode from pick_session_orders pso join cart_baskets cb on cb.id = pso.basket_id where pso.order_id = o[4]) = 'ZFT2-1', 'FT4 tote';
  assert not exists (select 1 from pick_allocations pa where pa.order_id = any(o) and pa.basket_id is null), 'allocations have totes';
  sess := (res->'carts'->0->>'session_id')::uuid;

  -- find an order
  res := wms_find_order('#FT2');
  assert res->0->>'cart' = 'ZFT1' and res->0->>'tote' = 'ZFT1-2' and res->0->>'where' like 'On ZFT1, tote ZFT1-2%', res::text;
  assert (wms_find_order('ZFT2-1'))->0->>'order_number' = 'FT4', 'find by tote';
  assert (wms_find_order('Cust 5'))->0->>'order_number' = 'FT5', 'find by customer';

  -- picker: no tote scanning needed, goes straight to picking
  perform set_config('request.jwt.claim.sub', u::text, true);
  res := wms_pick_open_cart('ZFT1');
  st := wms_pick_state(sess);
  assert jsonb_array_length(st->'need_totes') = 0 and st->'current'->'task' is not null, st::text;
  tid := (st->'current'->'task'->>'id')::uuid;
  res := wms_pick_scan(tid, 'FT111', null, 3);
  assert (res->>'ok')::boolean, res::text;
  res := wms_pick_finish_cart(sess, 'ZFT1');
  assert (res->>'ok')::boolean, res::text;

  -- picked orders still sit in the cart's totes: the cart is not free to rebuild
  assert not wms__cart_free(c1), 'cart with picked orders is busy';
  res := wms_find_order('FT1');
  assert res->0->>'where' = 'Picked into tote ZFT1-1, waiting to pack', res::text;
  perform set_config('request.jwt.claim.sub', boss::text, true);
  assert (wms_order_queue('all', 'FT1'))->'orders'->0->>'on_cart' = 'ZFT1 · ZFT1-1', 'queue shows tote';
  -- once packed the cart frees up
  update orders set status = 'packed' where id = any(o[1:3]);
  assert wms__cart_free(c1), 'free after packing';

  raise notice 'FIXED TOTES TEST PASSED';
end $$;
rollback;
