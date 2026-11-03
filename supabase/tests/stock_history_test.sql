-- Stock reasons + stock history (migration 027). Rolls itself back.
begin;
do $$
declare u uuid := gen_random_uuid(); boss uuid := gen_random_uuid(); wh uuid; sh uuid; p1 uuid; b1 uuid; b2 uuid; res jsonb; r jsonb;
begin
  insert into auth.users(id, email) values (u, 'sh1@twl.test'), (boss, 'sh2@twl.test');
  insert into staff(id, display_name, role, username) values (u, 'Hal', 'picker', 'halsh'), (boss, 'Bea', 'supervisor', 'beash');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', u::text, true);
  insert into warehouses(code, name) values ('SHT', 'History test') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'ZH', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', '') returning id into b1;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '02', '', '') returning id into b2;
  insert into products(sku, name) values ('SH-TEE', 'History Tee') returning id into p1;

  -- new reasons
  res := wms_adjust_stock((select code from bins where id = b1), 'SH-TEE', 'add', 10, 'receiving');
  assert (res->>'after')::int = 10, res::text;
  res := wms_adjust_stock((select code from bins where id = b1), 'SH-TEE', 'remove', 2, 'stocktake');
  assert (res->>'after')::int = 8, res::text;
  res := wms_adjust_stock((select code from bins where id = b1), 'SH-TEE', 'add', 1, 'stocktake');
  assert (res->>'after')::int = 9, res::text;
  assert wms_adjust_stock((select code from bins where id = b1), 'SH-TEE', 'remove', 1, 'receiving')->>'error' = 'REASON_WRONG_WAY', 'wrong way';
  assert wms_adjust_stock((select code from bins where id = b1), 'SH-TEE', 'add', 1, 'damaged')->>'error' = 'REASON_WRONG_WAY', 'wrong way 2';
  res := wms_move_stock((select code from bins where id = b1), 'SH-TEE', 4, (select code from bins where id = b2));
  assert (res->>'ok')::boolean, res::text;

  -- pickers can't see the log
  begin perform wms_stock_history(); raise exception 'picker should not see history';
  exception when insufficient_privilege then null; end;

  -- supervisor sees it: 3 adjustments + 1 move (as one row) for this product
  perform set_config('request.jwt.claim.sub', boss::text, true);
  r := wms_stock_history(p_search => 'SH-TEE');
  assert (r->>'total')::int = 4, r::text;
  assert (r->'rows'->0->>'type') = 'move_in' and r->'rows'->0->>'from_bin' = (select code from bins where id = b1)
     and (r->'rows'->0->>'from_after')::int = 5 and r->'rows'->0->>'who' = 'Hal', r->'rows'->0;
  assert exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'reason' = 'Stock tool: Receiving stock' and (x->>'change')::int = 10), 'receiving row';
  assert exists (select 1 from jsonb_array_elements(r->'rows') x where x->>'reason' = 'Stock tool: Stocktake' and (x->>'change')::int = -2), 'stocktake row';
  -- filters
  assert (wms_stock_history(p_search => 'SH-TEE', p_kind => 'move')->>'total')::int = 1, 'move filter';
  assert (wms_stock_history(p_search => 'SH-TEE', p_staff => boss)->>'total')::int = 0, 'staff filter';
  assert (wms_stock_history(p_search => (select code from bins where id = b2))->>'total')::int >= 1, 'location search';
  assert (wms_stock_history(p_search => 'SH-TEE', p_limit => 2)->'rows') is not null
     and jsonb_array_length(wms_stock_history(p_search => 'SH-TEE', p_limit => 2)->'rows') = 2, 'paging';

  raise notice 'STOCK HISTORY TEST PASSED';
end $$;
rollback;
