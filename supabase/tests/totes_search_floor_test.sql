-- Totes, search and TV metrics test. Rolls itself back.
begin;
do $$
declare u uuid := gen_random_uuid(); wh uuid; sh uuid; p1 uuid; o1 uuid; o2 uuid; cart uuid; res jsonb; cur jsonb; sess uuid; ship uuid;
begin
  insert into auth.users(id, email) values (u, 'tote@twl.test');
  perform set_config('request.jwt.claim.sub', u::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  insert into staff(id, display_name, role, username) values (u, 'Tote Tester', 'admin', 'tote.tester');

  insert into warehouses(code, name) values ('TTST', 'Tote test') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'A', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', '');
  insert into products(sku, name, variant_title, weight_grams) values ('ZZ-TOTE-TEE-M', 'Zebra Tote Tee', 'BLACK / M', 200) returning id into p1;
  insert into product_barcodes(barcode, product_id) values ('ZZ999', p1);
  perform wms__apply_delta((select id from bins where warehouse_id = wh), p1, 10, 'adjust');
  insert into orders(warehouse_id, order_number, ordered_at) values (wh, 'T1', now()) returning id into o1;
  insert into orders(warehouse_id, order_number, ordered_at) values (wh, 'T2', now()) returning id into o2;
  insert into order_lines(order_id, product_id, sku, qty_ordered) values (o1, p1, 'ZZ-TOTE-TEE-M', 2), (o2, p1, 'ZZ-TOTE-TEE-M', 1);
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'TCART', 'TCART', 12) returning id into cart;
  insert into cart_baskets(barcode, kind, warehouse_id) values ('TBIN1', 'tote', wh), ('TBIN2', 'tote', wh);

  -- hyper picking on a tote cart: session created, then asks for totes
  res := wms_hyper_next_session('TCART');
  sess := (res->'created'->>'session_id')::uuid;
  assert res->'current'->>'error' = 'SCAN_TOTES_FIRST', res::text;
  res := wms_assign_totes(sess, array['TBIN1']);
  assert (res->>'still_need')::int = 1, res::text;
  res := wms_assign_totes(sess, array['TBIN1']);
  assert res->>'error' = 'TOTE_IN_USE', 'a tote can only hold one order: ' || res::text;
  res := wms_assign_totes(sess, array['TBIN2']);
  assert (res->>'still_need')::int = 0, res::text;
  cur := wms_start_pick_session(sess);
  assert cur->'task'->>'sku' = 'ZZ-TOTE-TEE-M', cur::text;
  res := wms_pick_scan((cur->'task'->>'id')::uuid, 'ZZ999', null, 3);
  assert (res->>'session_done')::boolean, res::text;
  -- pack by scanning the tote
  res := wms_pack_start('TBIN1');
  assert (res->>'ok')::boolean and res->'order'->>'order_number' = 'T1', res::text;
  ship := (res->>'shipment_id')::uuid;
  perform wms_pack_scan(ship, 'ZZ999');
  res := wms_pack_scan(ship, 'ZZ999');
  assert (res->>'auto_closed')::boolean, res::text;

  -- search: barcode, SKU fragment, words in title
  res := wms_search_inventory('ZZ999');
  assert res->0->>'sku' = 'ZZ-TOTE-TEE-M' and (res->0->>'on_hand')::int = 7, res::text;
  res := wms_search_inventory('tote-tee');
  assert res->0->>'sku' = 'ZZ-TOTE-TEE-M', res::text;
  res := wms_search_inventory('zebra black');
  assert res->0->>'sku' = 'ZZ-TOTE-TEE-M', res::text;

  -- TV metrics
  res := wms_floor_metrics();
  assert (res->'now'->>'items_picked')::int >= 3 and (res->'now'->>'items_packed')::int >= 2, res::text;
  assert res->'top_pickers'->0->>'name' is not null, res::text;

  -- display (TV) account can read metrics but cannot scan
  update staff set role = 'display' where id = u;
  res := wms_floor_metrics();
  begin
    perform wms_resolve_scan('ZZ999');
    assert false, 'display role must not scan';
  exception when insufficient_privilege then null;
  end;

  raise notice 'TOTES/SEARCH/FLOOR TEST PASSED';
end $$;
rollback;
