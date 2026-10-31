-- Order types (migration 023). Rolls itself back.
begin;
do $$
declare boss uuid := gen_random_uuid(); wh uuid; res jsonb; c1 uuid; p1 uuid; o uuid;
  tg_reg jsonb := '[{"name":"Regular Order"},{"name":"STANDARD SHIPPING"}]';
  tg_pri jsonb := '[{"name":"priority-order"}]';
begin
  insert into auth.users(id, email) values (boss, 'og@twl.test');
  insert into staff(id, display_name, role, username) values (boss, 'Olga', 'supervisor', 'olga');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', boss::text, true);
  insert into warehouses(code, name) values ('OGT', 'Group test') returning id into wh;

  insert into orders(warehouse_id, order_number, requested_service, raw) values
    (wh, 'G-REG', 'Standard Shipping', jsonb_build_object('tags', tg_reg, 'ship_to', '{"country_code":"AU"}'::jsonb)),
    (wh, 'G-PAU', 'Recommended - Express Shipping', jsonb_build_object('tags', tg_pri, 'ship_to', '{"country_code":"AU"}'::jsonb)),
    (wh, 'G-PINT', 'International Shipping', jsonb_build_object('tags', tg_pri, 'ship_to', '{"country_code":"NZ"}'::jsonb)),
    (wh, 'G-ICON', 'Standard', '{"tags":[{"name":"The Iconic"}],"ship_to":{"country_code":"AU"}}'),
    (wh, 'G-OF', 'Warehouse Pickup', '{"tags":[{"name":"OPENFREIGHT"}],"ship_to":{"country_code":"AU"}}'),
    (wh, 'G-PK', 'Warehouse Pickup', jsonb_build_object('tags', tg_reg, 'ship_to', '{"country_code":"AU"}'::jsonb)),
    (wh, 'G-NONE', 'Redo Exchange Shipping', '{"tags":[],"ship_to":{"country_code":"AU"}}');

  assert (select pick_group from orders where order_number = 'G-REG') = 'REGS', 'REGS';
  assert (select pick_group from orders where order_number = 'G-PAU') = 'PRIO_AU', 'PRIO_AU';
  assert (select pick_group from orders where order_number = 'G-PINT') = 'PRIO_INT', 'PRIO_INT';
  assert (select pick_group from orders where order_number = 'G-ICON') = 'ICON', 'ICON';
  assert (select pick_group from orders where order_number = 'G-OF') = 'OPENFR8', 'OPENFR8 beats pickup';
  assert (select pick_group from orders where order_number = 'G-PK') = 'PKUP', 'PKUP';
  assert (select pick_group from orders where order_number = 'G-NONE') = 'OTHER', 'OTHER';

  -- a service change in ShipStation re-groups the order
  update orders set requested_service = 'Warehouse Pickup' where order_number = 'G-REG';
  assert (select pick_group from orders where order_number = 'G-REG') = 'PKUP', 'regroup';

  -- queue returns the group and counts
  res := wms_order_queue('all', 'G-');
  assert (res->'groups'->>'PKUP')::int >= 2, res->'groups';
  assert exists (select 1 from jsonb_array_elements(res->'orders') x where x->>'order_number' = 'G-ICON' and x->>'group' = 'ICON'), 'queue group';

  -- cart shows its type
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'A', 1);
  insert into shelves(row_id, code, sequence) select id, '01', 1 from aisle_rows where warehouse_id = wh;
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode) select wh, id, '01', '', '' from shelves where row_id = (select id from aisle_rows where warehouse_id = wh);
  insert into products(sku, name) values ('OG-TEE', 'Group Tee') returning id into p1;
  perform wms__apply_delta((select id from bins where warehouse_id = wh), p1, 10, 'adjust');
  select id into o from orders where order_number = 'G-ICON';
  update orders set carrier_id = 'se', service_code = 'svc', ordered_at = now() where id = o;
  insert into order_lines(order_id, product_id, sku, qty_ordered) values (o, p1, 'OG-TEE', 1);
  insert into carts(warehouse_id, code, barcode, basket_count) values (wh, 'ZOG1', 'ZOG1', 48) returning id into c1;
  res := wms_build_carts(array[o], 12, p_cart_ids => array[c1]);
  assert (res->>'ok')::boolean, res::text;
  assert exists (select 1 from jsonb_array_elements(wms_carts_overview()) x where x->>'cart' = 'ZOG1' and x->>'group' = 'ICON'), 'overview group';
  assert (wms_cart_detail((res->'carts'->0->>'session_id')::uuid))->'session'->>'group' = 'ICON', 'detail group';
  assert exists (select 1 from jsonb_array_elements(wms_pick_carts_available()) x where x->>'cart' = 'ZOG1' and x->>'group' = 'ICON'), 'tablet group';

  raise exception 'order_groups_test PASSED - all test data rolled back';
end $$;
rollback;
