-- Tablet stock tools (migration 020). Rolls itself back.
begin;
do $$
declare u uuid := gen_random_uuid(); wh uuid; sh uuid; p1 uuid; p2 uuid; a uuid; b uuid; res jsonb;
begin
  insert into auth.users(id, email) values (u, 'stk@twl.test');
  insert into staff(id, display_name, role, username) values (u, 'Stock Sam', 'picker', 'stock.sam');
  perform set_config('request.jwt.claim.sub', u::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  insert into warehouses(code, name) values ('STST', 'Stock test') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'ZQ', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', ''), (wh, sh, '02', '', '');
  select id into a from bins where warehouse_id = wh and code = 'ZQ-01-01';
  select id into b from bins where warehouse_id = wh and code = 'ZQ-01-02';
  insert into products(sku, name) values ('ST-TEE', 'Stock Tee') returning id into p1;
  insert into products(sku, name) values ('ST-CAP', 'Stock Cap') returning id into p2;
  insert into product_barcodes(barcode, product_id) values ('ST111', p1);
  perform wms__apply_delta(a, p1, 10, 'adjust');
  perform wms__apply_delta(a, p2, 4, 'adjust');
  update bin_inventory set qty_allocated = 3 where bin_id = a and product_id = p1;   -- 3 tees reserved for a cart

  res := wms_bin_contents('zq-01-01');
  assert (res->>'ok')::boolean and jsonb_array_length(res->'items') = 2 and (res->>'units')::int = 14, res::text;
  res := wms_bin_contents('NOPE');
  assert res->>'error' = 'UNKNOWN_BIN', res::text;

  -- move by SKU, lower case location
  res := wms_move_stock('zq-01-01', 'st-cap', 2, 'ZQ-01-02');
  assert (res->>'ok')::boolean and (res->>'from_after')::int = 2 and (res->>'to_after')::int = 2, res::text;
  -- can't move reserved stock
  res := wms_move_stock('ZQ-01-01', 'ST111', 8, 'ZQ-01-02');
  assert res->>'error' = 'INSUFFICIENT_STOCK' and (res->>'available')::int = 7 and (res->>'reserved')::int = 3, res::text;

  -- merge: free stock moves, reserved stays
  res := wms_merge_bins('ZQ-01-01', 'ZQ-01-02', false);
  assert res->>'error' = 'NOT_CONFIRMED', res::text;
  res := wms_merge_bins('ZQ-01-01', 'ZQ-01-02', true);
  assert (res->>'ok')::boolean and (res->>'units')::int = 9 and jsonb_array_length(res->'kept') = 1, res::text;
  assert (select qty_on_hand from bin_inventory where bin_id = a and product_id = p1) = 3, 'reserved tees stay';
  assert (select qty_on_hand from bin_inventory where bin_id = b and product_id = p1) = 7, 'free tees moved';
  assert (select qty_on_hand from bin_inventory where bin_id = b and product_id = p2) = 4, 'caps all moved';

  res := wms_my_recent_moves();
  assert jsonb_array_length(res) >= 2, res::text;

  raise notice 'STOCK TOOLS TEST PASSED';
end $$;
rollback;
