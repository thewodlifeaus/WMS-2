-- =============================================================================
-- End-to-end smoke test. Runs inside a transaction and ROLLS BACK, so it is
-- safe to run against the live project: nothing is kept.
--   receive -> move -> backfill alert -> cluster pick (incl. wrong scan)
--   -> pack -> label hook -> hyper pick -> reports
-- =============================================================================
begin;

do $$
declare
  u uuid := gen_random_uuid();
  wh uuid; z uuid; r record; sh uuid; i int; j int;
  p_tm uuid; p_tl uuid; p_sm uuid;
  po uuid; cart uuid; o1 uuid; o2 uuid; o3 uuid; o4 uuid; o5 uuid;
  res jsonb; cur jsonb; sess uuid; task jsonb; bc text; n int; ship uuid; prod_bc text;
begin
  -- ---- staff (fake auth user) ---------------------------------------------
  insert into auth.users(id, email) values (u, 'smoke@twl.test');
  perform set_config('request.jwt.claim.sub', u::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
  insert into staff(id, display_name, role) values (u, 'Smoke Tester', 'admin');

  -- ---- layout: rows A,B,C x shelves 01-04 x bins 01-03 ----------------------
  insert into warehouses(code, name) values ('TST', 'Test HQ') returning id into wh;
  insert into zones(warehouse_id, code, name, sequence) values (wh, 'Z1', 'Main', 1) returning id into z;
  for r in select * from (values ('A',1),('B',2),('C',3)) v(code, seq) loop
    insert into aisle_rows(warehouse_id, zone_id, code, sequence) values (wh, z, r.code, r.seq);
    for i in 1..4 loop
      insert into shelves(row_id, code, sequence)
      select id, lpad(i::text,2,'0'), i from aisle_rows where warehouse_id = wh and code = r.code
      returning id into sh;
      for j in 1..3 loop
        insert into bins(warehouse_id, shelf_id, bin_code, code, barcode, location_type)
        values (wh, sh, lpad(j::text,2,'0'), '', '', case when r.code = 'C' then 'backfill' else 'pick' end::location_type);
      end loop;
    end loop;
  end loop;
  assert (select count(*) from bins where warehouse_id = wh) = 36, 'expected 36 bins';
  assert (select barcode from bins where warehouse_id = wh and code = 'A-02-03') = 'LOC:TST:A-02-03', 'bin barcode';

  -- ---- products ------------------------------------------------------------
  insert into products(sku, name, size, weight_grams) values ('TST-TEE-M','Test Tee','M',180) returning id into p_tm;
  insert into products(sku, name, size, weight_grams) values ('TST-TEE-L','Test Tee','L',190) returning id into p_tl;
  insert into products(sku, name, size, weight_grams) values ('TST-SHO-M','Test Shorts','M',150) returning id into p_sm;
  insert into product_barcodes(barcode, product_id, is_primary) values
    ('9300000000011', p_tm, true), ('9300000000028', p_tl, true), ('9300000000035', p_sm, true);

  -- ---- inbound PO + receive ------------------------------------------------
  insert into purchase_orders(cin7_id, po_number, supplier_name, status, warehouse_id)
  values ('TEST-PO-1', 'PO-TEST-1', 'Test Supplier', 'in_transit', wh) returning id into po;
  insert into purchase_order_lines(po_id, sku, qty_ordered) values (po,'TST-TEE-M',20),(po,'TST-TEE-L',10),(po,'TST-SHO-M',10);

  res := wms_receive_scan(po, '9300000000011', 'LOC:TST:B-03-01', 5);   assert (res->>'ok')::boolean, res::text;
  res := wms_receive_scan(po, '9300000000011', 'LOC:TST:C-01-01', 15);  assert (res->>'ok')::boolean, res::text;
  res := wms_receive_scan(po, '9300000000028', 'LOC:TST:A-04-02', 10);  assert (res->>'ok')::boolean, res::text;
  res := wms_receive_scan(po, '9300000000035', 'LOC:TST:A-01-03', 11);
  assert res->>'error' = 'OVER_RECEIPT', 'over receipt must be blocked: ' || res::text;
  res := wms_receive_scan(po, '9300000000035', 'LOC:TST:A-01-03', 10);  assert (res->>'ok')::boolean, res::text;
  assert (select status from purchase_orders where id = po) = 'received', 'PO should be fully received';

  -- ---- move + backfill rule --------------------------------------------------
  insert into replenishment_rules(bin_id, product_id, min_qty, max_qty)
  select id, p_tm, 2, 8 from bins where barcode = 'LOC:TST:B-03-01';
  res := wms_move_stock('LOC:TST:B-03-01', '9300000000011', 4, 'LOC:TST:C-02-01');
  assert (res->>'ok')::boolean, res::text;   -- pick bin now 1 <= min 2 -> backfill alert
  assert exists (select 1 from backfill_tasks bt join bins b on b.id = bt.to_bin_id
                  where b.code = 'B-03-01' and bt.status = 'open' and bt.qty_suggested = 7), 'backfill task expected';
  res := wms_move_stock('C-01-01', '9300000000011', 7, 'B-03-01');
  assert (res->>'ok')::boolean, res::text;
  assert exists (select 1 from backfill_tasks where product_id = p_tm and status = 'done'), 'backfill should complete';

  -- ---- orders ----------------------------------------------------------------
  insert into orders(warehouse_id, order_number, priority, ordered_at) values (wh,'T1001',100,now()-interval '3 h') returning id into o1;
  insert into orders(warehouse_id, order_number, priority, ordered_at) values (wh,'T1002',100,now()-interval '2 h') returning id into o2;
  insert into orders(warehouse_id, order_number, priority, ordered_at) values (wh,'T1003', 50,now()-interval '1 h') returning id into o3;
  insert into order_lines(order_id, product_id, sku, qty_ordered) values
    (o1,p_tm,'TST-TEE-M',2),(o1,p_sm,'TST-SHO-M',1),
    (o2,p_tl,'TST-TEE-L',1),(o2,p_tm,'TST-TEE-M',1),
    (o3,p_sm,'TST-SHO-M',3);

  insert into carts(warehouse_id, code, barcode, basket_count) values (wh,'CART-T1','CART:T1',4) returning id into cart;
  insert into cart_baskets(cart_id, position, barcode) select cart, g, 'BSK:T1-' || g from generate_series(1,4) g;

  -- ---- cluster pick ------------------------------------------------------------
  res := wms_create_pick_session('cluster', array[o1,o2,o3], cart, null, u);
  sess := (res->>'session_id')::uuid;
  assert (res->>'tasks')::int = 3, 'expected 3 consolidated stops: ' || res::text;

  -- route check: snake. Rows A then B. A is walked forward (01 -> 04)
  assert (select string_agg(b.code, ',' order by t.sequence) from pick_tasks t join bins b on b.id = t.bin_id
           where t.session_id = sess) = 'A-01-03,A-04-02,B-03-01',
         'route order wrong: ' || (select string_agg(b.code, ',' order by t.sequence) from pick_tasks t join bins b on b.id = t.bin_id where t.session_id = sess);

  cur := wms_start_pick_session(sess);
  -- wrong item at the first stop must be rejected with an alarm
  res := wms_pick_scan((cur->'task'->>'id')::uuid, '9300000000028');
  assert res->>'error' = 'WRONG_ITEM' and (res->>'alarm')::boolean, 'wrong item must fail: ' || res::text;
  -- skipping ahead is blocked
  res := wms_pick_scan((select id from pick_tasks where session_id = sess and sequence = 3), '9300000000011');
  assert res->>'error' = 'NOT_CURRENT_TASK', 'skip ahead must fail';

  n := 0;
  loop
    cur := wms_get_current_task(sess);
    exit when (cur->>'done')::boolean;
    select barcode into prod_bc from product_barcodes pb join products p on p.id = pb.product_id
     where p.sku = cur->'task'->>'sku' and pb.is_primary;
    res := wms_pick_scan((cur->'task'->>'id')::uuid, prod_bc);
    assert (res->>'ok')::boolean, res::text;
    n := n + 1;
    assert n < 50, 'runaway loop';
  end loop;
  assert n = 8, 'expected 8 unit scans, got ' || n;
  assert (select status from pick_sessions where id = sess) = 'completed', 'session should complete';
  assert (select count(*) from orders where id in (o1,o2,o3) and status = 'picked') = 3, 'all 3 orders picked';
  -- priority 50 order (T1003) goes first -> basket 1
  assert (select cb.position from pick_session_orders pso join cart_baskets cb on cb.id = pso.basket_id
           where pso.session_id = sess and pso.order_id = o1) = 1, 'basket mapping follows input order';

  -- ---- pack + label hook ---------------------------------------------------------
  res := wms_pack_start('BSK:T1-1');
  assert (res->>'ok')::boolean and res->'order'->>'order_number' = 'T1001', res::text;
  ship := (res->>'shipment_id')::uuid;
  res := wms_pack_scan(ship, '9300000000028');
  assert res->>'error' = 'NOT_IN_ORDER', 'wrong item at pack must fail';
  res := wms_pack_complete(ship);
  assert res->>'error' = 'NOT_ALL_ITEMS_SCANNED', 'cannot close an incomplete box';
  perform wms_pack_scan(ship, '9300000000011');
  perform wms_pack_scan(ship, '9300000000011');
  res := wms_pack_scan(ship, '9300000000035');
  assert (res->>'complete')::boolean, res::text;
  res := wms_pack_complete(ship);
  assert (res->>'ok')::boolean, res::text;
  assert (select weight_grams from shipments where id = ship) = 510, 'weight from products: 2x180 + 150';
  perform wms_record_label(ship, true, 'se-TEST', 'se-LBL', 'TEST123', 'https://example/label.pdf', 9.95,
                           'se-1821526', 'au_post_parcel_post_signature_3D85', true);
  assert (select status from orders where id = o1) = 'shipped', 'order shipped';

  -- ---- hyper picking -------------------------------------------------------------
  insert into orders(warehouse_id, order_number, ordered_at) values (wh,'T2001',now()) returning id into o4;
  insert into orders(warehouse_id, order_number, ordered_at) values (wh,'T2002',now()) returning id into o5;
  insert into order_lines(order_id, product_id, sku, qty_ordered) values (o4,p_tl,'TST-TEE-L',1),(o5,p_tl,'TST-TEE-L',2);
  res := wms_hyper_next_session('CART:T1');
  assert (res->>'ok')::boolean, res::text;
  assert (res->'created'->>'orders')::int = 2 and (res->'created'->>'tasks')::int = 1, 'hyper should batch both orders into one stop: ' || res::text;

  -- ---- stock integrity: ledger == live balance -----------------------------------
  assert not exists (
    select 1 from bin_inventory bi
     where bi.qty_on_hand <> coalesce((select sum(qty_delta) from inventory_transactions t
                                         where t.bin_id = bi.bin_id and t.product_id = bi.product_id), 0)),
    'ledger and bin_inventory disagree';

  -- reports run
  perform * from v_product_stock; perform * from v_reorder_suggestions;
  perform * from v_picker_daily;  perform * from v_velocity_abc;
  assert (select units from v_picker_daily where staff_id = u) = 8, 'picker metrics';

  -- ---- wave release + short pick ------------------------------------------------
  update pick_sessions set status = 'cancelled' where cart_id = cart and status in ('assigned','in_progress');
  insert into waves(warehouse_id, name) values (wh, 'Test wave') returning id into sess;
  insert into orders(warehouse_id, order_number, ordered_at, wave_id) values (wh,'T3001',now(),sess),(wh,'T3002',now(),sess),(wh,'T3003',now(),sess);
  insert into order_lines(order_id, product_id, sku, qty_ordered)
  select id, p_sm, 'TST-SHO-M', 1 from orders where order_number in ('T3001','T3002','T3003');
  res := wms_release_wave(sess, 2);
  assert (res->>'chunks')::int = 2, 'wave should split 3 orders into 2 carts: ' || res::text;
  sess := (res->'sessions'->0->>'session_id')::uuid;
  begin
    perform wms_start_pick_session(sess);
    assert false, 'multi-order wave session must require a cart scan';
  exception when others then
    assert sqlerrm like 'SCAN_CART_FIRST%', sqlerrm;
  end;
  cur := wms_start_pick_session(sess, 'CART:T1');
  res := wms_pick_short((cur->'task'->>'id')::uuid);
  assert (res->>'ok')::boolean and (res->>'session_done')::boolean, res::text;
  assert (select count(*) from orders where order_number in ('T3001','T3002') and status = 'on_hold') = 2, 'short orders go on hold';
  assert (select qty_allocated from bin_inventory bi join bins b on b.id = bi.bin_id
           where b.code = 'A-01-03' and bi.product_id = p_sm) = 1, 'short pick releases its allocation (1 left for the 2nd wave cart)';

  raise notice 'SMOKE TEST PASSED';
end $$;

rollback;
