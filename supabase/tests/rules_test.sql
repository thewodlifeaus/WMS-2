-- =============================================================================
-- Pick & pack rules test (migration 010). Rolls itself back: safe on live.
--   1 pick checked against order   2 quantity entry   3 hold warnings / skip
--   4 full pack check              5 auto close on pass
-- =============================================================================
begin;
do $$
declare
  u uuid := gen_random_uuid(); wh uuid; sh uuid; p1 uuid; p2 uuid; o1 uuid; o2 uuid; o3 uuid;
  cart uuid; res jsonb; cur jsonb; sess uuid; ship uuid; r record;
begin
  insert into auth.users(id, email) values (u, 'rules@twl.test');
  perform set_config('request.jwt.claim.sub', u::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  insert into staff(id, display_name, role) values (u, 'Rules Tester', 'admin');

  insert into warehouses(code, name) values ('RTST', 'Rules test') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'A', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', ''), (wh, sh, '02', '', '');
  insert into products(sku, name, weight_grams) values ('R-TEE', 'Rules Tee', 200) returning id into p1;
  insert into products(sku, name, weight_grams) values ('R-SOCK', 'Rules Sock', 50) returning id into p2;
  insert into product_barcodes(barcode, product_id) values ('R111', p1), ('R222', p2);
  perform wms__apply_delta((select id from bins where warehouse_id = wh and code = 'A-01-01'), p1, 20, 'adjust');
  perform wms__apply_delta((select id from bins where warehouse_id = wh and code = 'A-01-02'), p2, 20, 'adjust');

  insert into orders(warehouse_id, order_number, ordered_at) values (wh, 'R1', now()) returning id into o1;
  insert into orders(warehouse_id, order_number, ordered_at) values (wh, 'R2', now()) returning id into o2;
  insert into orders(warehouse_id, order_number, ordered_at, is_held, hold_reason) values (wh, 'R3', now(), true, 'Address check') returning id into o3;
  insert into order_lines(order_id, product_id, sku, qty_ordered) values
    (o1, p1, 'R-TEE', 5), (o1, p2, 'R-SOCK', 1), (o2, p1, 'R-TEE', 1), (o3, p2, 'R-SOCK', 2);
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'RC1', 'CART:RC1', 4) returning id into cart;
  insert into cart_baskets(cart_id, position, barcode) select cart, g, 'BSK:RC1-' || g from generate_series(1, 4) g;

  -- RULE 3a: the held order is left out of the new pick and reported
  res := wms_create_pick_session('cluster', array[o1, o2, o3], cart, null, u);
  sess := (res->>'session_id')::uuid;
  assert (res->>'orders')::int = 2, 'held order must be skipped: ' || res::text;
  assert res->'skipped_on_hold'->0->>'order_number' = 'R3', res::text;

  cur := wms_start_pick_session(sess);
  assert cur->'task'->>'sku' = 'R-TEE' and (cur->'task'->>'qty_required')::int = 6, cur::text;

  -- RULE 1: wrong item rejected
  res := wms_pick_scan((cur->'task'->>'id')::uuid, 'R222');
  assert res->>'error' = 'WRONG_ITEM', res::text;

  -- RULE 3b: order put on hold mid-pick -> warning, pick still allowed
  perform wms_set_order_hold(o2, true, 'Customer changed address');

  -- RULE 2: scan once, enter quantity 7 -> too many (only 6 needed)
  res := wms_pick_scan((cur->'task'->>'id')::uuid, 'R111', null, 7);
  assert res->>'error' = 'OVER_QTY' and (res->>'remaining')::int = 6, res::text;
  -- scan once, enter 6 -> fills basket 1 (5 for R1) and basket 2 (1 for R2)
  res := wms_pick_scan((cur->'task'->>'id')::uuid, 'R111', null, 6);
  assert (res->>'ok')::boolean and (res->>'qty')::int = 6 and (res->>'task_done')::boolean, res::text;
  assert jsonb_array_length(res->'put_into') = 2, res::text;
  assert res->'warnings'->0->>'type' = 'ORDER_ON_HOLD' and res->'warnings'->0->>'order_number' = 'R2', res::text;

  res := wms_pick_scan((res->'next'->'task'->>'id')::uuid, 'R222');
  assert (res->>'session_done')::boolean, res::text;

  -- RULE 3c: packing a held order stops and asks for an override
  res := wms_pack_start('R2');
  assert res->>'error' = 'ORDER_ON_HOLD', res::text;
  res := wms_pack_start('R2', null, null, true);
  assert (res->>'ok')::boolean and res->'warnings'->0->>'type' = 'ORDER_ON_HOLD', res::text;

  -- RULE 4 + 5 on R1: 5 tees + 1 sock, every unit scanned, box closes itself on the last one
  res := wms_pack_start('R1');
  ship := (res->>'shipment_id')::uuid;
  for i in 1..5 loop
    res := wms_pack_scan(ship, 'R111');
    assert (res->>'ok')::boolean and not (res->>'auto_closed')::boolean, res::text;
  end loop;
  res := wms_pack_complete(ship);
  assert res->>'error' = 'NOT_ALL_ITEMS_SCANNED', 'no partial boxes: ' || res::text;
  res := wms_pack_scan(ship, 'R111');
  assert res->>'error' = 'ALREADY_PACKED', 'a 6th tee must be rejected: ' || res::text;
  res := wms_pack_scan(ship, 'R222');
  assert (res->>'auto_closed')::boolean, 'last scan must close the box: ' || res::text;
  assert (select status from shipments where id = ship) = 'packed', 'shipment packed';
  assert (select status from orders where id = o1) = 'packed', 'order packed';
  assert (select weight_grams from shipments where id = ship) = 1050, 'weight 5x200 + 50';
  -- box can still be changed before the label is bought
  res := wms_pack_complete(ship, null, 1200);
  assert (res->>'ok')::boolean and (select weight_grams from shipments where id = ship) = 1200, res::text;

  -- rules can be switched off per warehouse
  update warehouses set settings = settings || '{"pack_auto_close": false}' where id = wh;
  assert not wms__setting(wh, 'pack_auto_close'), 'setting toggle';

  raise notice 'RULES TEST PASSED';
end $$;
rollback;
