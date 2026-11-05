-- Cart stages + history (migration 037). Rolls itself back.
begin;
do $$
declare boss uuid := gen_random_uuid(); wh uuid; sh uuid; bn uuid; p1 uuid; c1 uuid; o uuid[] := '{}'; oid uuid; res jsonb; sess uuid; r jsonb; i int;
begin
  insert into auth.users(id, email) values (boss, 'ch1@twl.test');
  insert into staff(id, display_name, role, username) values (boss, 'Cleo', 'supervisor', 'cleoch');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', boss::text, true);
  insert into warehouses(code, name) values ('CHT', 'History test') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'A', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', '') returning id into bn;
  insert into products(sku, name) values ('CH-TEE', 'History Tee') returning id into p1;
  perform wms__apply_delta(bn, p1, 50, 'adjust');
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZCH1', 'ZCH1', 48) returning id into c1;
  for i in 1..2 loop
    insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code, customer_name)
    values (wh, 'CH' || i, now(), 'se', 'svc', 'Cust ' || i) returning id into oid;
    insert into order_lines(order_id, product_id, sku, qty_ordered) values (oid, p1, 'CH-TEE', 1);
    o := o || oid;
  end loop;
  res := wms_build_carts(o, 5, p_cart_ids => array[c1]);
  sess := (res->'carts'->0->>'session_id')::uuid;
  assert (select x->>'stage' from jsonb_array_elements(wms_carts_overview()) x where (x->>'session_id')::uuid = sess) = 'draft', 'draft';

  -- picking finished: ready for packing, even when it finished yesterday
  update pick_sessions set status = 'completed', started_at = now() - interval '1 day 1 hour', completed_at = now() - interval '1 day' where id = sess;
  update orders set status = 'picked' where id = any(o);
  r := (select x from jsonb_array_elements(wms_carts_overview()) x where (x->>'session_id')::uuid = sess);
  assert r->>'stage' = 'ready_to_pack' and (r->>'orders_packed')::int = 0, coalesce(r::text, 'cart missing from board');

  -- one packed: still ready for packing; both packed: picked & packed
  update orders set status = 'packed' where id = o[1];
  assert wms__cart_stage(sess) = 'ready_to_pack', 'half packed';
  update orders set status = 'shipped' where id = o[2];
  assert wms__cart_stage(sess) = 'picked_packed', 'all packed';
  -- finished yesterday and fully packed: off the board, but in history
  assert not exists (select 1 from jsonb_array_elements(wms_carts_overview()) x where (x->>'session_id')::uuid = sess), 'off the board';
  r := (select x from jsonb_array_elements(wms_cart_history()->'carts') x where (x->>'session_id')::uuid = sess);
  assert r->>'stage' = 'picked_packed' and (r->>'orders')::int = 2, coalesce(r::text, 'not in history');
  assert (select array_agg(e->>'what' order by e->>'what') from jsonb_array_elements(r->'timeline') e) = array['built','finish','start'], r->>'timeline';

  raise exception 'CART HISTORY TEST PASSED - all test data rolled back';
end $$;
rollback;
