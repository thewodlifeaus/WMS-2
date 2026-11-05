-- Inventory reconciliation (migration 038). Rolls itself back.
begin;
do $$
declare boss uuid := gen_random_uuid(); u uuid := gen_random_uuid();
        wh uuid; sh uuid; b1 uuid; b2 uuid; pA uuid; pB uuid; pC uuid; pD uuid; pE uuid; o1 uuid; o2 uuid;
        run1 timestamptz := '2026-11-05 10:00+10:30'; run2 timestamptz := '2026-11-05 11:00+10:30'; res jsonb; r jsonb;
begin
  insert into auth.users(id, email) values (boss, 'ir1@twl.test'), (u, 'ir2@twl.test');
  insert into staff(id, display_name, role, username) values (boss, 'Ada', 'admin', 'adair'), (u, 'Pip', 'picker', 'pipir');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', u::text, true);

  -- pickers can't run it; before any pull the report is empty
  begin perform wms_inventory_recon(); raise exception 'picker should be blocked';
  exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub', boss::text, true);

  wh := wms__main_warehouse();
  if wh is null then insert into warehouses(code, name) values ('IRT', 'Recon test') returning id into wh; end if;
  insert into zones(warehouse_id, code, name, sequence) values (wh, 'ZIR', 'Zone IR', 99);
  insert into aisle_rows(warehouse_id, zone_id, code, sequence) values (wh, (select id from zones where code = 'ZIR' and warehouse_id = wh), 'ZIR', 99);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh and code = 'ZIR' returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', '') returning id into b1;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode, location_type) values (wh, sh, '02', '', '', 'backfill') returning id into b2;
  insert into products(sku, name) values ('IR-A', 'Recon A') returning id into pA;   -- matches
  insert into products(sku, name) values ('IR-B', 'Recon B') returning id into pB;   -- 2 more in bins (amber)
  insert into products(sku, name) values ('IR-C', 'Recon C') returning id into pC;   -- 5 fewer in bins (red)
  insert into products(sku, name) values ('IR-D', 'Recon D') returning id into pD;   -- only in WMS
  insert into products(sku, name) values ('IR-E', 'Recon E') returning id into pE;   -- Shopify has it, no bins

  res := wms_inventory_recon();
  if not exists (select 1 from sync_state where system = 'shopify_stock') then
    assert res->'pulled_at' = 'null'::jsonb and jsonb_array_length(res->'rows') = 0, 'no pull yet: ' || res::text;
  end if;

  -- WMS: A 10 in bins (8 shelf + 2 backstock), open order needs 3 of A, 1 already picked (left the bins)
  insert into bin_inventory(bin_id, product_id, qty_on_hand) values (b1, pA, 8), (b2, pA, 2), (b1, pB, 6), (b1, pC, 1), (b2, pD, 4);
  insert into orders(warehouse_id, order_number, status) values (wh, 'IR-1001', 'awaiting_pick') returning id into o1;
  insert into order_lines(order_id, product_id, sku, qty_ordered) values (o1, pA, 'IR-A', 2);
  insert into orders(warehouse_id, order_number, status) values (wh, 'IR-1002', 'picking') returning id into o2;
  insert into order_lines(order_id, product_id, sku, qty_ordered, qty_allocated, qty_picked) values (o2, pA, 'IR-A', 2, 2, 1);
  -- shipped orders are ignored
  insert into orders(warehouse_id, order_number, status) values (wh, 'IR-1003', 'shipped') returning id into o2;
  insert into order_lines(order_id, product_id, sku, qty_ordered, qty_allocated, qty_picked, qty_packed) values (o2, pB, 'IR-B', 5, 5, 5, 5);

  -- Shopify: A on hand 11 (10 in bins + 1 in a tote), committed 4 -> free 7 = WMS 10 - 3 to pick
  -- old pull (run1) must be ignored once run2 is the latest
  perform wms_import_shopify_stock(run1, 31072848, '[{"item":9001,"sku":"IR-A","on_hand":99,"committed":0}]');
  perform wms_import_shopify_stock(run2, 31072848, jsonb_build_array(
    jsonb_build_object('item', 9001, 'sku', 'IR-A', 'tracked', true, 'on_hand', 11, 'committed', 4, 'available', 7),
    jsonb_build_object('item', 9002, 'sku', 'IR-B', 'on_hand', 4, 'committed', 0),
    jsonb_build_object('item', 9003, 'sku', 'IR-C', 'on_hand', 6, 'committed', 0),
    jsonb_build_object('item', 9005, 'sku', 'IR-E', 'on_hand', 3, 'committed', 1),
    jsonb_build_object('item', 9006, 'sku', 'IR-ZZ', 'on_hand', 2, 'committed', 0),
    jsonb_build_object('item', 9007, 'sku', 'IR-UNTRACKED', 'tracked', false, 'on_hand', -5, 'committed', 0)));
  insert into sync_state(system, cursor) values ('shopify_stock', jsonb_build_object('run_at', run2)::text)
    on conflict (system) do update set cursor = excluded.cursor;

  res := wms_inventory_recon('all', 'IR-');
  select x into r from jsonb_array_elements(res->'rows') x where x->>'sku' = 'IR-A';
  assert r->>'level' = 'green' and (r->>'sh_free')::int = 7 and (r->>'wms_free')::int = 7 and (r->>'to_pick')::int = 3
     and (r->>'picked')::int = 1 and (r->>'in_bins')::int = 10 and (r->>'diff')::int = 0, 'A matches: ' || r::text;
  assert r->>'first_loc' = 'ZIR-01-01', 'biggest location first: ' || r::text;
  select x into r from jsonb_array_elements(res->'rows') x where x->>'sku' = 'IR-B';
  assert r->>'level' = 'amber' and (r->>'diff')::int = 2, 'B amber +2: ' || r::text;
  select x into r from jsonb_array_elements(res->'rows') x where x->>'sku' = 'IR-C';
  assert r->>'level' = 'red' and (r->>'diff')::int = -5, 'C red -5: ' || r::text;
  select x into r from jsonb_array_elements(res->'rows') x where x->>'sku' = 'IR-D';
  assert r->>'level' = 'red' and r->>'note' like 'Not in Shopify%', 'D only in WMS: ' || r::text;
  select x into r from jsonb_array_elements(res->'rows') x where x->>'sku' = 'IR-E';
  assert r->>'level' = 'amber' and r->>'note' = 'No stock in any location' and (r->>'diff')::int = -2, 'E: ' || r::text;
  select x into r from jsonb_array_elements(res->'rows') x where x->>'sku' = 'IR-ZZ';
  assert r->>'level' = 'red' and r->>'note' = 'SKU not in the WMS', 'ZZ unknown: ' || r::text;
  assert not exists (select 1 from jsonb_array_elements(res->'rows') x where x->>'sku' = 'IR-UNTRACKED'), 'untracked ignored';
  assert (res->'tiles'->>'green')::int >= 1 and (res->'tiles'->>'amber')::int >= 1, res->'tiles'::text;

  -- default view = differences only (no green), red first
  res := wms_inventory_recon('diff', 'IR-');
  assert not exists (select 1 from jsonb_array_elements(res->'rows') x where x->>'level' = 'green'), 'diff hides green';
  assert res->'rows'->0->>'level' = 'red', 'red first';
  -- search by location code
  res := wms_inventory_recon('all', 'ZIR-01-02');
  assert (select count(*) from jsonb_array_elements(res->'rows')) = 2, 'location search finds A and D: ' || res::text;
  -- a duplicate SKU in Shopify is added together and flagged
  perform wms_import_shopify_stock(run2, 31072848, '[{"item":9008,"sku":"IR-B","on_hand":2,"committed":0}]');
  res := wms_inventory_recon('all', 'IR-B');
  r := res->'rows'->0;
  assert (r->>'sh_on_hand')::int = 6 and r->>'level' = 'green' and r->>'note' like 'Shopify has this SKU on 2%', 'dup: ' || r::text;

  raise exception 'INVENTORY RECON TEST PASSED - all test data rolled back';
end $$;
rollback;
