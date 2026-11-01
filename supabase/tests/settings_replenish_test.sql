-- Settings (carts, totes, locations) + replenishment report (migration 033). Rolls itself back.
begin;
do $$
declare boss uuid := gen_random_uuid(); sup uuid := gen_random_uuid(); u uuid := gen_random_uuid();
        wh uuid; sh uuid; b1 uuid; b2 uuid; bk uuid; p1 uuid; p2 uuid; p3 uuid; c1 uuid; c2 uuid; res jsonb; oid uuid; r jsonb;
begin
  insert into auth.users(id, email) values (boss, 'sr1@twl.test'), (sup, 'sr2@twl.test'), (u, 'sr3@twl.test');
  insert into staff(id, display_name, role, username) values (boss, 'Ada', 'admin', 'adasr'), (sup, 'Sue', 'supervisor', 'suesr'), (u, 'Pip', 'picker', 'pipsr');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', u::text, true);
  insert into warehouses(code, name) values ('SRT', 'Settings test') returning id into wh;
  insert into zones(warehouse_id, code, name, sequence) values (wh, 'ZS', 'Zone S', 1);
  insert into aisle_rows(warehouse_id, zone_id, code, sequence) values (wh, (select id from zones where code = 'ZS' and warehouse_id = wh), 'ZS', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', '') returning id into b1;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '02', '', '') returning id into b2;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode, location_type) values (wh, sh, '99', '', '', 'backfill') returning id into bk;
  insert into products(sku, name) values ('SR-A', 'Repl A') returning id into p1;
  insert into products(sku, name) values ('SR-B', 'Repl B') returning id into p2;
  insert into products(sku, name) values ('SR-C', 'Repl C') returning id into p3;
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZSR1', 'ZSR1', 48) returning id into c1;

  -- pickers and supervisors can't use settings
  assert wms_admin_save_cart(null, 'ZSR9')->>'error' = 'FORBIDDEN', 'picker blocked';
  perform set_config('request.jwt.claim.sub', sup::text, true);
  assert wms_admin_add_locations(array['ZS-01-03'])->>'error' = 'FORBIDDEN', 'supervisor blocked from settings';
  perform set_config('request.jwt.claim.sub', boss::text, true);

  -- ---- carts ----
  res := wms_admin_save_cart(null, 'zsr2');
  assert (res->>'ok')::boolean and res->>'code' = 'ZSR2', res::text;
  c2 := (res->>'id')::uuid;
  assert wms_admin_save_cart(null, 'ZSR1')->>'error' = 'CODE_TAKEN', 'unique code';
  -- 4 totes on cart 1: preview then save
  res := wms_admin_set_cart_totes(c1, array['srt01','SRT02','SRT03','SRT04']);
  assert (res->>'preview')::boolean and (res->>'totes')::int = 4 and res->>'first' = 'SRT01', res::text;
  assert not exists (select 1 from cart_baskets where barcode = 'SRT01'), 'preview changes nothing';
  res := wms_admin_set_cart_totes(c1, array['SRT01','SRT02','SRT03','SRT04'], true);
  assert (res->>'ok')::boolean and (select count(*) from cart_baskets where cart_id = c1) = 4, res::text;
  assert (select position from cart_baskets where barcode = 'SRT03') = 3, 'positions in order';
  assert (select basket_count from carts where id = c1) = 4, 'basket count follows';
  -- duplicates and totes on another cart are refused
  assert wms_admin_set_cart_totes(c2, array['X1','X1'])->>'error' = 'DUPLICATE', 'dup';
  res := wms_admin_set_cart_totes(c2, array['SRT04','SRT05']);
  assert res->>'error' = 'TOTE_ON_OTHER_CART' and res->'totes'->0->>'cart' = 'ZSR1', res::text;
  -- shrink cart 1 to 2 totes in a new order: the others become loose
  res := wms_admin_set_cart_totes(c1, array['SRT02','SRT01'], true);
  assert res->'made_loose' = '["SRT03","SRT04"]'::jsonb, res::text;
  assert (select cart_id from cart_baskets where barcode = 'SRT04') is null, 'loose';
  assert (select position from cart_baskets where barcode = 'SRT02') = 1, 'reordered';
  -- loose totes can go onto another cart
  res := wms_admin_set_cart_totes(c2, array['SRT03','SRT04','SRT05'], true);
  assert (res->>'ok')::boolean and res->'added' = '["SRT03","SRT04","SRT05"]'::jsonb, res::text;
  r := wms_admin_carts();
  assert (select x->'totes' from jsonb_array_elements(r->'carts') x where x->>'code' = 'ZSR2') = '["SRT03","SRT04","SRT05"]'::jsonb, r::text;
  -- a busy cart can't be changed or switched off
  insert into pick_sessions(warehouse_id, cart_id, status, assigned_to, method) values (wh, c1, 'assigned', u, 'cluster');
  assert wms_admin_set_cart_totes(c1, array['SRT01'], true)->>'error' = 'CART_BUSY', 'busy totes';
  assert wms_admin_save_cart(c1, 'ZSR1', false)->>'error' = 'CART_BUSY', 'busy off';
  assert (wms_admin_save_cart(c2, 'ZSR2B', false)->>'ok')::boolean, 'free cart off + rename';
  assert (select code || is_active::text from carts where id = c2) = 'ZSR2Bfalse', 'renamed';

  -- ---- locations ----
  res := wms_admin_add_locations(array['ZS-01-03', 'zs-02-01', 'NEWR-01-01', 'Z-RETURNS', 'ZS-01-01', 'bad code!'], 'pick');
  assert (res->>'preview')::boolean and (res->>'new')::int = 4 and (res->>'already')::int = 1, res::text;
  assert res->'new_rows' = '["NEWR"]'::jsonb, res::text;
  assert (select x->>'kind' from jsonb_array_elements(res->'locations') x where x->>'code' = 'Z-RETURNS') = 'floor', res::text;
  assert (select x->>'status' from jsonb_array_elements(res->'locations') x where x->>'code' = 'BAD CODE!') = 'bad_code', res::text;
  assert not exists (select 1 from bins where code = 'ZS-01-03'), 'preview only';
  res := wms_admin_add_locations(array['ZS-01-03', 'ZS-02-01', 'NEWR-01-01', 'Z-RETURNS'], 'pick', null, true);
  assert (select count(*) from bins where code in ('ZS-01-03','ZS-02-01','NEWR-01-01','Z-RETURNS') and is_active) = 4, res::text;
  assert (select barcode from bins where code = 'NEWR-01-01') = 'LOC:SRT:NEWR-01-01', 'barcode set';
  assert (select z.code from bins b join zones z on z.id = b.zone_id where b.code = 'ZS-02-01') = 'ZS', 'row zone';
  assert (select shelf_id from bins where code = 'Z-RETURNS') is null, 'floor';
  -- receiving locations are pickable, reserved are not, overrides win
  res := wms_admin_add_locations(array['Z-RECV'], 'receiving', 'DOCKX', true);
  assert (select is_pickable from bins where code = 'Z-RECV'), 'receiving pickable';
  assert (select z.code from bins b join zones z on z.id = b.zone_id where b.code = 'Z-RECV') = 'DOCKX', 'new zone';
  res := wms_admin_update_locations(array['Z-RECV'], 'reserved');
  assert (res->>'updated')::int = 1 and not (select is_pickable from bins where code = 'Z-RECV'), res::text;
  res := wms_admin_update_locations(array['Z-RECV'], null, null, 'always');
  assert (select is_pickable from bins where code = 'Z-RECV'), 'always';
  res := wms_admin_update_locations(array['Z-RECV'], 'pick', 'ZS', 'type');
  assert (select is_pickable and pick_allowed is null and location_type = 'pick' from bins where code = 'Z-RECV'), 'back to type';
  assert wms_admin_update_locations(array['Z-RECV'], null, 'NOPE')->>'error' = 'UNKNOWN_ZONE', 'zone must exist';

  -- stock: can't switch off a location with stock, or block picking with reserved stock
  insert into bin_inventory(bin_id, product_id, qty_on_hand, qty_allocated) values (b1, p1, 3, 1), (b2, p2, 0, 0), (bk, p1, 20, 0), (bk, p2, 8, 0), (bk, p3, 5, 0);
  res := wms_admin_update_locations(array['ZS-01-01', 'ZS-01-03'], null, null, null, false);
  assert (res->>'updated')::int = 1 and res->'blocked'->0->>'code' = 'ZS-01-01', res::text;
  assert not (select is_active from bins where code = 'ZS-01-03'), 'empty one off';
  res := wms_admin_update_locations(array['ZS-01-01'], null, null, 'never');
  assert res->'blocked'->0->>'reason' like '%reserved%', res::text;
  r := wms_admin_locations('ZS-01');
  assert (select (x->>'units')::int from jsonb_array_elements(r->'rows') x where x->>'code' = 'ZS-01-01') = 3, r::text;
  assert (select count(*) from jsonb_array_elements(wms_admin_locations('ZS-01', null, null, 'inactive')->'rows')) = 1, 'inactive filter';
  -- switch it back on via add
  res := wms_admin_add_locations(array['ZS-01-03'], 'pick', null, true);
  assert (res->>'switched_on')::int = 1 and (select is_active from bins where code = 'ZS-01-03'), res::text;

  -- ---- replenishment ----
  insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code, customer_name)
  values (wh, 'SR1', now(), 'se', 'svc', 'Cust') returning id into oid;
  insert into order_lines(order_id, product_id, sku, qty_ordered) values (oid, p2, 'SR-B', 2);
  perform set_config('request.jwt.claim.sub', u::text, true);
  begin perform wms_replenishment_report(); assert false, 'picker blocked'; exception when insufficient_privilege then null; end;
  perform set_config('request.jwt.claim.sub', sup::text, true);
  r := wms_replenishment_report(2, 6, null, 'SR-');
  -- B: shelf empty, 2 on orders, 8 in backstock -> red, move 6 (fill to 6)
  assert (select x->>'level' || ':' || (x->>'move') || ':' || (x->>'short') || ':' || (x->>'from') from jsonb_array_elements(r->'rows') x where x->>'sku' = 'SR-B')
         = 'red:6:2:ZS-01-99', r::text;
  -- A: 3 on hand is above the low mark of 2: not listed; with low 3 it is amber, move 3
  assert not exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'sku' = 'SR-A'), r::text;
  r := wms_replenishment_report(3, 6, null, 'SR-');
  assert (select x->>'level' || ':' || (x->>'move') from jsonb_array_elements(r->'rows') x where x->>'sku' = 'SR-A') = 'amber:3', r::text;
  assert (select x->>'sku' from jsonb_array_elements(r->'rows') x limit 1) = 'SR-B', 'red first';
  -- C only lives in backstock
  assert (select (x->>'back_units')::int from jsonb_array_elements(r->'backstock_only') x where x->>'sku' = 'SR-C') = 5, r::text;
  -- a rule overrides the fill-to
  insert into replenishment_rules(bin_id, product_id, min_qty, max_qty) values (b2, p2, 1, 4);
  r := wms_replenishment_report(2, 6, null, 'SR-B');
  assert (r->'rows'->0->>'move')::int = 4, r::text;
  assert (r->>'empty_shelf_bins')::int >= 1, r::text;

  raise exception 'SETTINGS + REPLENISH TEST PASSED - all test data rolled back';
end $$;
rollback;
