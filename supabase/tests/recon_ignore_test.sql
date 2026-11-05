-- Inventory reconciliation: skip dropship + kits/bundles, manual ignore (migration 039). Rolls itself back.
begin;
do $$
declare boss uuid := gen_random_uuid(); u uuid := gen_random_uuid(); wh uuid; sh uuid; b1 uuid;
        pReal uuid; pKit uuid; pPackReal uuid; pDs uuid; pOdd uuid; pComp uuid;
        run1 timestamptz := '2026-11-05 12:00+10:30'; res jsonb; r jsonb;
begin
  insert into auth.users(id, email) values (boss, 'ri1@twl.test'), (u, 'ri2@twl.test');
  insert into staff(id, display_name, role, username) values (boss, 'Ada', 'admin', 'adari'), (u, 'Pip', 'picker', 'pipri');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', u::text, true);
  assert wms_recon_set_ignore('RI-ODD', 'ignore')->>'error' = 'FORBIDDEN', 'picker blocked';
  perform set_config('request.jwt.claim.sub', boss::text, true);

  wh := wms__main_warehouse();
  if wh is null then insert into warehouses(code, name) values ('RIT', 'Ignore test') returning id into wh; end if;
  insert into zones(warehouse_id, code, name, sequence) values (wh, 'ZRI', 'Zone RI', 98);
  insert into aisle_rows(warehouse_id, zone_id, code, sequence) values (wh, (select id from zones where code = 'ZRI' and warehouse_id = wh), 'ZRI', 98);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh and code = 'ZRI' returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', '') returning id into b1;

  insert into products(sku, name) values ('RI-REAL', 'Real tee') returning id into pReal;
  insert into products(sku, name, variant_title) values ('RI-TAPE-3PAK', 'Finger Tape', '3 PACK / BLACK') returning id into pKit;
  insert into products(sku, name) values ('RI-BANDS', '4 PACK MINI RESISTANCE BANDS') returning id into pPackReal;   -- real, sits in a bin
  insert into products(sku, name) values ('RI-DS', 'Toe Spacer') returning id into pDs;
  insert into products(sku, name) values ('RI-ODD', 'Barbell and collars') returning id into pOdd;
  insert into products(sku, name) values ('RI-SOCK', 'PACE SOCKS (Bundles App Component)') returning id into pComp;
  insert into bin_inventory(bin_id, product_id, qty_on_hand) values (b1, pReal, 5), (b1, pPackReal, 4), (b1, pDs, 1);

  perform wms_import_shopify_stock(run1, 31072848, jsonb_build_array(
    jsonb_build_object('item', 8101, 'sku', 'RI-REAL', 'on_hand', 9),
    jsonb_build_object('item', 8102, 'sku', 'RI-TAPE-3PAK', 'on_hand', 300),
    jsonb_build_object('item', 8103, 'sku', 'RI-BANDS', 'on_hand', 20),
    jsonb_build_object('item', 8104, 'sku', 'RI-DS', 'on_hand', 50),
    jsonb_build_object('item', 8105, 'sku', 'RI-ODD', 'on_hand', 7),
    jsonb_build_object('item', 8106, 'sku', 'RI-SOCK', 'on_hand', 3),
    jsonb_build_object('item', 8107, 'sku', 'RI-MYS-001', 'on_hand', 12)));   -- unknown to the WMS, no name
  perform wms_import_shopify_dropship(run1, array['RI-DS']);
  perform wms_import_shopify_dropship(run1 - interval '1 day', array['RI-OLDDS']);   -- old pull: not used
  insert into sync_state(system, cursor) values ('shopify_stock', jsonb_build_object('run_at', run1)::text)
    on conflict (system) do update set cursor = excluded.cursor;

  res := wms_inventory_recon('all', 'RI-');
  assert (select array_agg(x->>'sku' order by x->>'sku') from jsonb_array_elements(res->'rows') x)
       = array['RI-BANDS','RI-MYS-001','RI-ODD','RI-REAL','RI-SOCK'], 'checked rows: ' || (res->'rows')::text;
  res := wms_inventory_recon('ignored', 'RI-');
  select x into r from jsonb_array_elements(res->'rows') x where x->>'sku' = 'RI-DS';
  assert r->>'ignored' = 'dropship' and r->>'ignore_how' = 'auto', 'dropship skipped: ' || coalesce(r::text, 'missing');
  select x into r from jsonb_array_elements(res->'rows') x where x->>'sku' = 'RI-TAPE-3PAK';
  assert r->>'ignored' = 'kit', '3 pack never in a bin = kit: ' || coalesce(r::text, 'missing');
  assert (res->>'total_rows')::int = 2, 'only 2 ignored: ' || res::text;

  -- ignore one by hand, then force a kit back in, then back to the rules
  assert (wms_recon_set_ignore('RI-ODD', 'ignore', 'kit', 'barbell + collars')->>'ok')::boolean;
  res := wms_inventory_recon('ignored', 'RI-ODD');
  r := res->'rows'->0;
  assert r->>'ignored' = 'kit' and r->>'ignore_how' = 'manual' and r->>'ignore_by' = 'Ada' and r->>'ignore_note' = 'barbell + collars', r::text;
  perform wms_recon_set_ignore('RI-TAPE-3PAK', 'include');
  res := wms_inventory_recon('all', 'RI-TAPE');
  assert res->'rows'->0->>'sku' = 'RI-TAPE-3PAK' and (res->'rows'->0->>'forced_in')::boolean, 'forced back in: ' || res::text;
  perform wms_recon_set_ignore('RI-TAPE-3PAK', 'auto');
  res := wms_inventory_recon('ignored', 'RI-TAPE');
  assert res->'rows'->0->>'ignored' = 'kit' and res->'rows'->0->>'ignore_how' = 'auto', 'back to rules: ' || res::text;
  assert (wms_inventory_recon('all', 'RI-')->'tiles'->>'ignored_dropship')::int >= 1, 'tile counts dropship';
  assert wms_recon_set_ignore('RI-ODD', 'maybe')->>'error' = 'BAD_MODE', 'bad mode';

  raise exception 'RECON IGNORE TEST PASSED - all test data rolled back';
end $$;
rollback;
