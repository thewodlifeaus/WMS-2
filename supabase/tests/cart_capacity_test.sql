-- Cart capacity + shared totes (migration 019). Rolls itself back.
begin;
do $$
declare u uuid := gen_random_uuid(); wh uuid; sh uuid; p1 uuid; c1 uuid; c2 uuid; c3 uuid; res jsonb; s1 uuid; s2 uuid;
        o uuid[] := '{}'; v uuid; i int; n int[] := array[2,3,1,5,7,4];
begin
  insert into auth.users(id, email) values (u, 'cap@twl.test');
  insert into staff(id, display_name, role, username) values (u, 'Cap Boss', 'supervisor', 'cap.boss');
  perform set_config('request.jwt.claim.sub', u::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  insert into warehouses(code, name) values ('KTST', 'Capacity test') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'A', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', '');
  insert into products(sku, name) values ('KT-TEE', 'Cap Tee') returning id into p1;
  perform wms__apply_delta((select id from bins where warehouse_id = wh), p1, 100, 'adjust');
  for i in 1..6 loop
    insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code)
    values (wh, 'K' || i, now() - make_interval(mins => 10 - i), 'se', 'svc') returning id into v;
    insert into order_lines(order_id, product_id, sku, qty_ordered) values (v, p1, 'KT-TEE', n[i]);
    o := o || v;
  end loop;
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZKC1', 'ZKC1', 48) returning id into c1;
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZKC2', 'ZKC2', 48) returning id into c2;
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZKC3', 'ZKC3', 48) returning id into c3;
  insert into cart_baskets(barcode, kind, warehouse_id) values ('ZK-T1','tote',wh), ('ZK-T2','tote',wh);

  -- pieces mode: 6 pieces per tote, 2 totes per cart
  res := wms_build_carts(o, 2, 6, array[c1, c2, c3]);
  assert (res->>'ok')::boolean and res->>'mode' = 'pieces' and jsonb_array_length(res->'carts') = 2, res::text;
  s1 := (res->'carts'->0->>'session_id')::uuid; s2 := (res->'carts'->1->>'session_id')::uuid;
  -- cart 1: K1+K2+K3 share tote 1 (6 pieces), K4 in tote 2 (5); K5 (7) and K6 (4) don't fit whole -> cart 2
  assert (select array_agg(o2.order_number order by o2.order_number) from pick_session_orders x join orders o2 on o2.id = x.order_id where x.session_id = s1)
         = array['K1','K2','K3','K4'], 'cart 1 orders';
  assert (select count(distinct slot) from pick_session_orders where session_id = s1) = 2, 'cart 1 uses 2 totes';
  assert (select array_agg(slot order by o2.order_number) from pick_session_orders x join orders o2 on o2.id = x.order_id where x.session_id = s1)
         = array[1,1,1,2], 'slots';
  assert (select array_agg(o2.order_number order by o2.order_number) from pick_session_orders x join orders o2 on o2.id = x.order_id where x.session_id = s2)
         = array['K5','K6'], 'cart 2 orders: big order gets its own tote';
  -- no order on two carts, and every unit of each order is on its cart
  assert (select count(*) from pick_session_orders where order_id = any(o)) = 6, 'no order split across carts';
  assert (select sum(qty_required) from pick_tasks where session_id = s1) = 11 and (select sum(qty_required) from pick_tasks where session_id = s2) = 11, 'units';

  -- picker scans one tote per tote slot: 2 scans for 4 orders
  res := wms_pick_open_cart('ZKC1');
  assert jsonb_array_length(res->'need_totes') = 2 and res->'need_totes'->>0 = '#K1, #K2, #K3', res::text;
  res := wms_assign_totes(s1, array['ZK-T1']);
  assert (res->>'still_need')::int = 1, res::text;
  assert (select count(*) from pick_session_orders where session_id = s1 and basket_id = (select id from cart_baskets where barcode = 'ZK-T1')) = 3, 'shared tote';
  res := wms_assign_totes(s1, array['zk-t2']);
  assert (res->>'still_need')::int = 0, res::text;

  -- pack desk: scanning the shared tote lists its orders
  update orders set status = 'picked' where order_number in ('K1','K2','K3') and warehouse_id = wh;
  res := wms_pack_start('ZK-T1');
  assert res->>'error' = 'TOTE_HAS_ORDERS' and jsonb_array_length(res->'orders') = 3, res::text;
  res := wms_pack_start('K2');
  assert (res->>'ok')::boolean and res->'order'->>'order_number' = 'K2', res::text;

  -- orders mode: one order per tote, 3 totes per cart (take carts apart first)
  perform wms_cancel_pick_session(s2);
  res := wms_build_carts(array[o[5], o[6]], 1, null, array[c2, c3]);
  assert jsonb_array_length(res->'carts') = 2 and res->>'mode' = 'orders', 'one order per tote, 1 tote per cart -> 2 carts: ' || res::text;

  raise notice 'CART CAPACITY TEST PASSED';
end $$;
rollback;
