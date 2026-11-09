-- Kits (migration 041). Rolls itself back.
begin;
do $$
declare boss uuid := gen_random_uuid(); pk uuid := gen_random_uuid(); wh uuid; sh uuid; b1 uuid; b2 uuid;
        pTape uuid; pSock uuid; pBlk uuid; pWht uuid; pKit3 uuid; o1 uuid; o2 uuid; o3 uuid; res jsonb; tok text := 'kt-' || gen_random_uuid();
begin
  insert into auth.users(id, email) values (boss, 'kt1@twl.test'), (pk, 'kt2@twl.test');
  insert into staff(id, display_name, role, username) values (boss, 'Kit Boss', 'supervisor', 'kitboss'), (pk, 'Kit Picker', 'picker', 'kitpick');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', boss::text, true);

  insert into warehouses(code, name) values ('KTST', 'Kit test') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'K', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', ''), (wh, sh, '02', '', '');
  select id into b1 from bins where warehouse_id = wh and code = 'K-01-01';
  select id into b2 from bins where warehouse_id = wh and code = 'K-01-02';
  insert into products(sku, name) values ('KT-TAPE-1', 'Tape 1 pack') returning id into pTape;
  insert into products(sku, name) values ('KT-SOCK', 'Sock') returning id into pSock;
  insert into products(sku, name) values ('KT-WPI-BLK', 'Protein choc') returning id into pBlk;
  insert into products(sku, name) values ('KT-WPI-WHT', 'Protein vanilla') returning id into pWht;
  insert into products(sku, name) values ('KT-TAPE-3PK', 'Tape 3 pack') returning id into pKit3;
  perform wms__apply_delta(b1, pTape, 10, 'adjust');
  perform wms__apply_delta(b1, pSock, 4, 'adjust');
  perform wms__apply_delta(b2, pBlk, 1, 'adjust');
  perform wms__apply_delta(b2, pWht, 9, 'adjust');

  -- an order that came in before the kit existed (kit SKU unknown -> held)
  insert into orders(warehouse_id, order_number, ordered_at, status, is_held, hold_reason)
  values (wh, 'KT-OLD', now(), 'on_hold', true, 'Unknown SKU - add product to WMS') returning id into o3;
  insert into order_lines(order_id, product_id, sku, name, qty_ordered) values (o3, null, 'KT-BUNDLE', 'Bundle', 1);

  -- import: pickers / no token refused
  perform set_config('request.jwt.claim.sub', pk::text, true);
  begin perform wms_import_kits('[]'::jsonb, 'nope'); raise exception 'import should be refused';
  exception when others then if sqlerrm <> 'FORBIDDEN' then raise; end if; end;
  insert into import_tokens(token, expires_at) values (tok, now() + interval '5 minutes');

  -- SkuVault rows: 3-pack (1 line x3); bundle with a substitute line + a sock line; a part SKU missing
  res := wms_import_kits(jsonb_build_array(
    jsonb_build_array('KT-TAPE-3PK', '4000015557', 'Tape 3 pack', 'Tape', '3', 'KT-TAPE-1', 'Disabled'),
    jsonb_build_array('KT-BUNDLE', '7000000194', 'Protein bundle', 'Protein', '2', 'KT-WPI-BLK', 'Disabled'),
    jsonb_build_array('KT-BUNDLE', '7000000194', 'Protein bundle', 'Protein', '2', 'KT-WPI-WHT', 'Disabled'),
    jsonb_build_array('KT-BUNDLE', '7000000194', 'Protein bundle', 'Socks', '1', 'KT-SOCK', 'Disabled'),
    jsonb_build_array('KT-GHOST', '1', 'Ghost', 'x', '1', 'KT-NOT-HERE', 'Disabled')), tok);
  assert (res->>'kits')::int = 2 and (res->>'missing_part_skus')::int = 1, res::text;
  assert (res->>'new_kit_products')::int = 2, 'KT-BUNDLE and KT-GHOST created as products: ' || res::text;
  assert (select count(*) from kit_lines l join kits k on k.product_id = l.kit_id and l.version = k.version
           where k.product_id = (select id from products where sku = 'KT-BUNDLE')) = 2, 'bundle has 2 lines';
  assert (select count(*) from kit_line_skus ls join kit_lines l on l.id = ls.line_id where l.name = 'Protein'
           and l.kit_id = (select id from products where sku = 'KT-BUNDLE')) = 2, 'protein line has a substitute';
  -- re-import is safe (new version, same shape)
  res := wms_import_kits(jsonb_build_array(jsonb_build_array('KT-TAPE-3PK', '4000015557', 'Tape 3 pack', 'Tape', '3', 'KT-TAPE-1', 'Disabled')), tok);
  assert (select version from kits where product_id = pKit3) = 2, 're-import bumps version';
  perform set_config('request.jwt.claim.sub', boss::text, true);

  -- availability: tape 10/3 = 3; bundle = min(floor((1+9)/2), 4) = 4
  assert wms__kit_available(pKit3, wh) = 3, 'tape kit available';
  assert wms__kit_available((select id from products where sku = 'KT-BUNDLE'), wh) = 4, 'bundle available';

  -- new order with 2 x 3-pack + 1 bundle: kit lines become parts
  insert into orders(warehouse_id, order_number, ordered_at) values (wh, 'KT-1', now()) returning id into o1;
  insert into order_lines(order_id, product_id, sku, name, qty_ordered, external_line_id) values
    (o1, pKit3, 'KT-TAPE-3PK', 'Tape 3 pack', 2, 'x1'),
    (o1, (select id from products where sku = 'KT-BUNDLE'), 'KT-BUNDLE', 'Protein bundle', 1, 'x2'),
    (o1, pSock, 'KT-SOCK', 'Sock', 1, 'x3');
  assert not exists (select 1 from order_lines where order_id = o1 and sku in ('KT-TAPE-3PK','KT-BUNDLE')), 'kit lines not saved';
  assert (select qty_ordered from order_lines where order_id = o1 and sku = 'KT-TAPE-1') = 6, '2 x 3-pack = 6 tapes';
  assert (select kit_sku || '/' || kit_qty from order_lines where order_id = o1 and sku = 'KT-TAPE-1') = 'KT-TAPE-3PK/2', 'kit remembered';
  -- main protein (choc) has only 1 free, needs 2 -> substitute vanilla
  assert exists (select 1 from order_lines where order_id = o1 and sku = 'KT-WPI-WHT' and qty_ordered = 2 and kit_line = 'Protein'), 'substitute used';
  assert (select count(*) from order_lines where order_id = o1 and sku = 'KT-SOCK') = 2, 'loose sock + kit sock are separate lines';
  assert (select sum(qty_ordered) from order_lines where order_id = o1) = 10, 'units on order';

  -- pack view shows the kit
  res := (select jsonb_agg(x) from (select jsonb_build_object('sku', sku, 'kit', kit_sku) x from order_lines where order_id = o1) t);
  assert res::text like '%KT-BUNDLE%', res::text;

  -- the held order: queue fix matches the now-known kit SKU, splits it and releases the hold
  res := wms_kits_fix_queue();
  assert (res->>'lines_matched')::int >= 1 and (res->>'kit_lines_split')::int >= 1 and (res->>'holds_released')::int >= 1, res::text;
  assert (select status from orders where id = o3) = 'awaiting_pick', 'hold released';
  assert (select count(*) from order_lines where order_id = o3) = 2 and not exists (select 1 from order_lines where order_id = o3 and sku = 'KT-BUNDLE'), 'old order split';

  -- create a NEW kit for a future product (SKU not in the WMS yet)
  perform set_config('request.jwt.claim.sub', pk::text, true);
  res := wms_kit_save('KT-NEW-5PK', 'Sock 5 pack', null, '[{"name":"Sock","qty":5,"skus":["KT-SOCK"]}]'::jsonb, null, true);
  assert res->>'error' = 'FORBIDDEN', 'pickers cannot edit kits';
  perform set_config('request.jwt.claim.sub', boss::text, true);
  res := wms_kit_save('KT-NEW-5PK', 'Sock 5 pack', null, '[{"name":"Sock","qty":0,"skus":["KT-NOPE"]}]'::jsonb, null, true);
  assert not (res->>'ok')::boolean and jsonb_array_length(res->'errors') = 2, res::text;
  res := wms_kit_save('KT-NEW-5PK', 'Sock 5 pack', null, '[{"name":"Sock","qty":5,"skus":["KT-SOCK"]}]'::jsonb, null, false);
  assert (res->>'preview')::boolean and (res->>'new_product')::boolean, 'preview: ' || res::text;
  assert not exists (select 1 from products where sku = 'KT-NEW-5PK'), 'preview saves nothing';
  res := wms_kit_save('KT-NEW-5PK', 'Sock 5 pack', '9300000000001', '[{"name":"Sock","qty":5,"skus":["KT-SOCK"]}]'::jsonb, null, true);
  assert (res->>'saved')::boolean and res->'kit'->>'source' = 'wms', res::text;
  assert (select is_active from products where sku = 'KT-NEW-5PK'), 'product created for the new kit';

  -- edit: becomes 2 lines; old version kept, new version current
  res := wms_kit_save('KT-NEW-5PK', 'Sock + tape', null, '[{"qty":3,"skus":["KT-SOCK"]},{"name":"Tape","qty":1,"skus":["KT-TAPE-1","KT-TAPE-3PK"]}]'::jsonb, null, true);
  assert (res->>'version')::int = 2 and jsonb_array_length(res->'kit'->'lines') = 2, res::text;
  assert res->'kit'->'lines'->0->>'name' = 'Sock', 'blank line name takes the product name';
  assert (select count(*) from kit_lines where kit_id = (select id from products where sku = 'KT-NEW-5PK')) = 3, 'history kept';
  -- a kit edited in the WMS is not overwritten by a SkuVault re-import
  res := wms_import_kits(jsonb_build_array(jsonb_build_array('KT-NEW-5PK', '', 'x', 'x', '9', 'KT-SOCK', 'Disabled')), tok);
  assert (res->>'skipped_edited_in_wms')::int = 1, res::text;

  -- list / search / detail / finder
  res := wms_kits('KT-WPI', 'active', 50, 0);
  assert (res->>'total')::int = 1 and res->'kits'->0->>'kit_sku' = 'KT-BUNDLE', 'search by part SKU: ' || res::text;
  res := wms_kit('KT-TAPE-3PK');
  assert (res->'kit'->>'available')::int = 3 and res->'kit'->'lines'->0->'skus'->0->>'sku' = 'KT-TAPE-1', res::text;
  res := wms_kit_find_products('KT-WPI');
  assert jsonb_array_length(res) = 2, res::text;

  -- switch off: new orders keep the kit SKU as is
  res := wms_kit_set_active('KT-TAPE-3PK', false);
  assert not (res->'kit'->>'active')::boolean, res::text;
  insert into orders(warehouse_id, order_number, ordered_at) values (wh, 'KT-2', now()) returning id into o2;
  insert into order_lines(order_id, product_id, sku, qty_ordered) values (o2, pKit3, 'KT-TAPE-3PK', 1);
  assert exists (select 1 from order_lines where order_id = o2 and sku = 'KT-TAPE-3PK'), 'switched-off kit not split';
  assert (select count(*) from (select jsonb_array_elements(wms_kits(null, 'off', 50, 0)->'kits')) t) >= 1, 'off list';

  -- recon treats kits as kits
  assert wms__recon_auto_kit('KT-BUNDLE', 'Protein bundle', null), 'recon kit rule';

  raise exception 'KITS TEST PASSED - all test data rolled back';
end $$;
rollback;
