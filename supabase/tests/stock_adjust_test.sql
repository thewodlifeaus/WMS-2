-- Stock tools add / remove / set (migration 025). Rolls itself back.
begin;
do $$
declare u uuid := gen_random_uuid(); tv uuid := gen_random_uuid(); wh uuid; sh uuid; p1 uuid; bn uuid; res jsonb;
begin
  insert into auth.users(id, email) values (u, 'sa1@twl.test'), (tv, 'sa2@twl.test');
  insert into staff(id, display_name, role, username) values (u, 'Sal', 'picker', 'salsa'), (tv, 'TV', 'display', 'tvsa');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', u::text, true);
  insert into warehouses(code, name) values ('SAT', 'Adjust test') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'Q', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', '') returning id into bn;
  insert into products(sku, name) values ('SA-TEE', 'Adjust Tee') returning id into p1;
  insert into product_barcodes(barcode, product_id) values ('SA111', p1);

  -- add to an empty location, by barcode
  res := wms_adjust_stock((select code from bins where id = bn), 'SA111', 'add', 4, 'found');
  assert (res->>'ok')::boolean and (res->>'after')::int = 4 and (res->>'change')::int = 4, res::text;
  -- remove by SKU, lower case
  res := wms_adjust_stock((select code from bins where id = bn), 'sa-tee', 'remove', 1, 'damaged');
  assert (res->>'after')::int = 3, res::text;
  -- set
  res := wms_adjust_stock((select code from bins where id = bn), 'SA-TEE', 'set', 10, 'count_fix');
  assert (res->>'change')::int = 7 and (select qty_on_hand from bin_inventory where bin_id = bn and product_id = p1) = 10, res::text;
  assert exists (select 1 from inventory_transactions where bin_id = bn and txn_type = 'adjust' and ref_type = 'stock_tool'
                   and staff_id = u and qty_delta = 7 and reason = 'Stock tool: Count was wrong'), 'txn';

  -- errors
  assert wms_adjust_stock((select code from bins where id = bn), 'SA111', 'remove', 11, 'count_fix')->>'error' = 'NOT_ENOUGH', 'not enough';
  assert wms_adjust_stock((select code from bins where id = bn), 'SA111', 'add', 0, 'found')->>'error' = 'BAD_QTY', 'zero';
  assert wms_adjust_stock((select code from bins where id = bn), 'SA111', 'add', 1, 'nope')->>'error' = 'BAD_REASON', 'reason';
  assert wms_adjust_stock((select code from bins where id = bn), 'SA111', 'add', 1, 'other')->>'error' = 'NOTE_REQUIRED', 'note';
  assert wms_adjust_stock('NO-SUCH-BIN', 'SA111', 'add', 1, 'found')->>'error' = 'UNKNOWN_BIN', 'bin';
  assert wms_adjust_stock((select code from bins where id = bn), 'XXNOPE', 'add', 1, 'found')->>'error' = 'UNKNOWN_BARCODE', 'product';

  -- reserved stock can't be removed
  update bin_inventory set qty_allocated = 6 where bin_id = bn and product_id = p1;
  res := wms_adjust_stock((select code from bins where id = bn), 'SA111', 'set', 5, 'count_fix');
  assert res->>'error' = 'BELOW_RESERVED' and (res->>'reserved')::int = 6, res::text;
  assert (wms_adjust_stock((select code from bins where id = bn), 'SA111', 'remove', 4, 'count_fix')->>'after')::int = 6, 'down to reserved ok';

  -- shows in my recent list
  assert exists (select 1 from jsonb_array_elements(wms_my_recent_moves(10)) x where x->>'kind' = 'adjust' and x->>'sku' = 'SA-TEE'), 'recent';

  -- TV login can't adjust
  perform set_config('request.jwt.claim.sub', tv::text, true);
  begin
    res := wms_adjust_stock((select code from bins where id = bn), 'SA111', 'add', 1, 'found');
    raise exception 'TV should not adjust';
  exception when insufficient_privilege then null;
  end;

  raise notice 'STOCK ADJUST TEST PASSED';
end $$;
rollback;
