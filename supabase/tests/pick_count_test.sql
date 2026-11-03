-- Pick screen location count + quick count fix (migration 024). Rolls itself back.
begin;
do $$
declare u uuid := gen_random_uuid(); u2 uuid := gen_random_uuid();
        wh uuid; sh uuid; p1 uuid; o1 uuid; c1 uuid; res jsonb; sess uuid; tid uuid; bn uuid;
begin
  insert into auth.users(id, email) values (u, 'pc1@twl.test'), (u2, 'pc2@twl.test');
  insert into staff(id, display_name, role, username) values (u, 'Pat', 'picker', 'patc'), (u2, 'Pam', 'picker', 'pamc');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', u::text, true);
  insert into warehouses(code, name) values ('PCT', 'Pick count test') returning id into wh;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'A', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh returning id into sh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) values (wh, sh, '01', '', '') returning id into bn;
  insert into products(sku, name) values ('PC-TEE', 'Count Tee') returning id into p1;
  insert into product_barcodes(barcode, product_id) values ('PC111', p1);
  perform wms__apply_delta(bn, p1, 5, 'adjust');
  insert into orders(warehouse_id, order_number, ordered_at, carrier_id, service_code) values (wh, 'PC1', now(), 'se', 'svc') returning id into o1;
  insert into order_lines(order_id, product_id, sku, qty_ordered) values (o1, p1, 'PC-TEE', 2);
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZPC1', 'ZPC1', 48) returning id into c1;
  insert into cart_baskets(barcode, kind, warehouse_id) values ('ZPC-T1', 'tote', wh);
  update staff set role = 'supervisor' where id = u;
  res := wms_build_carts(array[o1], 12, p_cart_ids => array[c1]);
  update staff set role = 'picker' where id = u;
  sess := (res->'carts'->0->>'session_id')::uuid;
  res := wms_pick_open_cart('ZPC1'); res := wms_assign_totes(sess, array['ZPC-T1']);

  -- pick screen shows 5 in the location, 2 reserved
  res := (wms_pick_state(sess))->'current'->'task';
  tid := (res->>'id')::uuid;
  assert (res->>'bin_on_hand')::int = 5 and (res->>'bin_reserved')::int = 2, res::text;

  -- bad inputs
  assert wms_pick_adjust_bin(tid, 3, 'nonsense')->>'error' = 'BAD_REASON', 'reason';
  assert wms_pick_adjust_bin(tid, 3, 'other')->>'error' = 'NOTE_REQUIRED', 'note';
  assert wms_pick_adjust_bin(tid, -1, 'fewer_here')->>'error' = 'BAD_QTY', 'qty';
  -- can't go below what's reserved
  res := wms_pick_adjust_bin(tid, 1, 'fewer_here');
  assert res->>'error' = 'BELOW_RESERVED' and (res->>'reserved')::int = 2, res::text;

  -- fewer: 5 -> 3, logged as adjust against the picker
  res := wms_pick_adjust_bin(tid, 3, 'fewer_here');
  assert (res->>'ok')::boolean and (res->>'change')::int = -2 and (res->'current'->'task'->>'bin_on_hand')::int = 3, res::text;
  assert exists (select 1 from inventory_transactions where ref_id = tid and txn_type = 'adjust' and qty_delta = -2 and staff_id = u
                   and reason like 'Pick count fix: Fewer here%'), 'txn';
  -- more: 3 -> 8
  res := wms_pick_adjust_bin(tid, 8, 'other', 'found a bag behind');
  assert (res->>'change')::int = 5 and (select qty_on_hand from bin_inventory where bin_id = bn and product_id = p1) = 8, res::text;
  -- same number: no change
  assert (wms_pick_adjust_bin(tid, 8, 'more_here')->>'change')::int = 0, 'nochange';

  -- someone else's cart
  perform set_config('request.jwt.claim.sub', u2::text, true);
  assert wms_pick_adjust_bin(tid, 9, 'more_here')->>'error' = 'NOT_YOUR_CART', 'not yours';
  perform set_config('request.jwt.claim.sub', u::text, true);

  -- still picks normally afterwards
  res := wms_pick_scan(tid, 'PC111', null, 2);
  assert (res->>'ok')::boolean, res::text;
  assert (select qty_on_hand from bin_inventory where bin_id = bn and product_id = p1) = 6, 'after pick';

  raise notice 'PICK COUNT TEST PASSED';
end $$;
rollback;
