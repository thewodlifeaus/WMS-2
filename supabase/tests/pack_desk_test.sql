-- Pack desk test (migration 013). Rolls itself back.
begin;
do $$
declare u uuid := gen_random_uuid(); wh uuid; sh uuid; p1 uuid; p2 uuid; o1 uuid; o2 uuid; res jsonb; ship uuid; desk uuid; b1 uuid;
begin
  insert into auth.users(id, email) values (u, 'desk@twl.test');
  perform set_config('request.jwt.claim.sub', u::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  insert into staff(id, display_name, role, username) values (u, 'Desk Tester', 'packer', 'desk.tester');

  insert into warehouses(code, name, settings) values ('DTST', 'Desk test',
    '{"pack_without_pick": true, "pack_auto_close": true, "warn_on_hold": true}') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'A', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', ''), (wh, sh, '02', '', '');
  insert into products(sku, name, weight_grams) values ('DK-TEE', 'Desk Tee', 200) returning id into p1;
  insert into products(sku, name, weight_grams) values ('DK-CAP', 'Desk Cap', 100) returning id into p2;
  insert into product_barcodes(barcode, product_id) values ('DK111', p1);
  select id into b1 from bins where warehouse_id = wh and code = 'A-01-01';
  perform wms__apply_delta(b1, p1, 5, 'adjust');
  insert into pack_stations(warehouse_id, code, name) values (wh, 'dtdesk1', 'Desk 1') returning id into desk;
  insert into orders(warehouse_id, order_number, ordered_at) values (wh, 'D1', now()) returning id into o1;
  insert into orders(warehouse_id, order_number, ordered_at, status) values (wh, 'D2', now(), 'cancelled') returning id into o2;
  insert into order_lines(order_id, product_id, sku, qty_ordered) values (o1, p1, 'DK-TEE', 2), (o1, p2, 'DK-CAP', 1);

  -- desks listed
  assert exists (select 1 from jsonb_array_elements(wms_pack_desks()) d where d->>'code' = 'dtdesk1'), 'desk listed';

  -- cancelled order stopped at the desk
  res := wms_pack_start('D2', desk);
  assert res->>'error' = 'ORDER_CANCELLED', res::text;

  -- pack without WMS pick: order not picked, still packable by order number (with #)
  res := wms_pack_start('#D1', desk);
  assert (res->>'ok')::boolean and (res->>'units_total')::int = 3, res::text;
  ship := (res->>'shipment_id')::uuid;
  res := wms_pack_scan(ship, 'DK111');
  assert (res->>'ok')::boolean and (res->>'units_packed')::int = 1, res::text;
  assert (select qty_on_hand from bin_inventory where bin_id = b1 and product_id = p1) = 4, 'scan took stock from the pick bin';
  res := wms_pack_scan(ship, 'NOPE');
  assert res->>'error' = 'UNKNOWN_BARCODE', res::text;
  res := wms_pack_scan(ship, 'DK111');
  res := wms_pack_scan(ship, 'DK111');
  assert res->>'error' = 'ALREADY_PACKED', '3rd tee rejected: ' || res::text;
  -- manual pass: must be confirmed and have a reason; recorded against the packer
  res := wms_pack_manual_pass(ship, (select id from order_lines where order_id = o1 and sku = 'DK-CAP'), 'no_barcode', false);
  assert res->>'error' = 'NOT_CONFIRMED', res::text;
  res := wms_pack_manual_pass(ship, (select id from order_lines where order_id = o1 and sku = 'DK-CAP'), 'other', true);
  assert res->>'error' = 'NOTE_REQUIRED', res::text;
  res := wms_pack_manual_pass(ship, (select id from order_lines where order_id = o1 and sku = 'DK-TEE'), 'no_barcode', true);
  assert res->>'error' = 'ALREADY_PACKED', 'manual pass cannot exceed the order: ' || res::text;
  -- cap has no stock -> warning but still passes; last unit closes the box
  res := wms_pack_manual_pass(ship, (select id from order_lines where order_id = o1 and sku = 'DK-CAP'), 'damaged_label', true);
  assert (res->>'auto_closed')::boolean, res::text;
  assert res->'warnings'->0->>'type' = 'NO_STOCK_RECORDED', res::text;
  assert (select weight_source from shipments where id = ship) = 'estimate', 'estimated weight';
  assert (select count(*) from pack_manual_passes where shipment_id = ship and staff_id = u and reason = 'damaged_label') = 1, 'manual pass recorded';

  -- scale weight
  res := wms_pack_set_weight(ship, 0);
  assert res->>'error' = 'BAD_WEIGHT', res::text;
  res := wms_pack_set_weight(ship, 612, 'scale');
  assert (res->>'weight_grams')::int = 612 and res->>'weight_source' = 'scale', res::text;

  -- label recorded (test), then printed
  perform wms_record_label(ship, true, 'se-1', 'lbl-1', 'TRACK1', null, 9.95, 'se-ap', 'svc', true);
  assert (select status from orders where id = o1) = 'shipped', 'order shipped';
  perform wms_mark_printed(ship);
  assert (select status from shipments where id = ship) = 'shipped' and (select test_label from shipments where id = ship), 'printed';

  -- scanning a shipped order says so (so the desk can offer a reprint)
  res := wms_pack_start('D1', desk);
  assert res->>'error' = 'ALREADY_PACKED' and (res->>'shipment_id')::uuid = ship, res::text;

  raise notice 'PACK DESK TEST PASSED';
end $$;
rollback;
