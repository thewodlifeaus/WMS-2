-- Undo a stock change (migration 032). Rolls itself back.
begin;
do $$
declare boss uuid := gen_random_uuid(); u uuid := gen_random_uuid(); wh uuid; sh uuid; b1 uuid; b2 uuid; p1 uuid; res jsonb; tx bigint; mv bigint; r jsonb;
begin
  insert into auth.users(id, email) values (boss, 'un1@twl.test'), (u, 'un2@twl.test');
  insert into staff(id, display_name, role, username) values (boss, 'Una', 'supervisor', 'unaun'), (u, 'Uri', 'picker', 'uriun');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', u::text, true);
  insert into warehouses(code, name) values ('UNT', 'Undo test') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'ZU', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', '') returning id into b1;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '02', '', '') returning id into b2;
  insert into products(sku, name) values ('UN-A', 'Undo A') returning id into p1;

  -- picker adds 10 (receiving), then moves 4 to bin 2
  res := wms_adjust_stock((select code from bins where id = b1), 'UN-A', 'add', 10, 'receiving');
  select max(id) into tx from inventory_transactions where product_id = p1 and txn_type = 'adjust';
  res := wms_move_stock((select code from bins where id = b1), 'UN-A', 4, (select code from bins where id = b2));
  select max(id) into mv from inventory_transactions where product_id = p1 and txn_type = 'move_in';

  -- pickers can't undo
  assert wms_undo_stock_change(mv, null, true)->>'error' = 'FORBIDDEN', 'picker blocked';
  perform set_config('request.jwt.claim.sub', boss::text, true);

  -- the history marks both as undoable
  r := wms_stock_history(p_search => 'UN-A');
  assert (select bool_and((x->>'undoable')::boolean) from jsonb_array_elements(r->'rows') x), r::text;

  -- the add can't be undone yet: only 6 left in bin 1
  res := wms_undo_stock_change(tx);
  assert res->>'error' = 'NOT_ENOUGH_FREE' and (res->>'free')::int = 6, res::text;

  -- undo the move: preview, then do it
  res := wms_undo_stock_change(mv);
  assert (res->>'preview')::boolean and (res->>'qty')::int = 4 and res->>'to' = (select code from bins where id = b1), res::text;
  res := wms_undo_stock_change(mv, 'Wrong shelf', true);
  assert (res->>'ok')::boolean and (res->>'from_after')::int = 0 and (res->>'to_after')::int = 10, res::text;
  assert wms_undo_stock_change(mv, null, true)->>'error' = 'ALREADY_UNDONE', 'once only';
  assert exists (select 1 from inventory_transactions where ref_type = 'undo' and txn_type = 'move_in' and bin_id = b1 and qty_delta = 4
                   and staff_id = boss and reason = 'Undo #' || mv || ': Wrong shelf' and (metadata->>'undo_of')::bigint = mv), 'undo logged';
  -- the undo row itself can't be undone
  assert not wms__undoable((select id from inventory_transactions where ref_type = 'undo' and txn_type = 'move_in' and bin_id = b1)), 'no undo of undo';

  -- now the add can be undone: 10 back out
  res := wms_undo_stock_change(tx, 'Received into wrong SKU', true);
  assert (res->>'ok')::boolean and (res->>'after')::int = 0, res::text;
  assert (select qty_on_hand from bin_inventory where bin_id = b1 and product_id = p1) = 0, 'back to zero';

  -- history shows who undid it
  r := wms_stock_history(p_search => 'UN-A');
  assert exists (select 1 from jsonb_array_elements(r->'rows') x where (x->>'id')::bigint = tx and x->>'undone_by' = 'Una' and not (x->>'undoable')::boolean), r::text;

  -- reserved stock can't be undone away
  perform wms__apply_delta(b1, p1, 5, 'adjust', 'stock_tool', null, boss, null, null, 'Stock tool: Found stock');
  select max(id) into tx from inventory_transactions where product_id = p1 and txn_type = 'adjust' and ref_type = 'stock_tool';
  update bin_inventory set qty_allocated = 3 where bin_id = b1 and product_id = p1;
  assert wms_undo_stock_change(tx, null, true)->>'error' = 'NOT_ENOUGH_FREE', 'reserved';

  raise notice 'UNDO STOCK TEST PASSED';
end $$;
rollback;
