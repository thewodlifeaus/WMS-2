-- Existing SkuVault carts and hyper-picking totes for TWLHQ (31 Oct 2026).
-- Barcode = the code printed on the current labels, so nothing needs relabelling.
-- basket_count on a tote cart = max orders per trip (edit per cart if needed).
insert into carts(warehouse_id, code, barcode, basket_count)
select w.id, 'CART' || lpad(g::text, 2, '0'), 'CART' || lpad(g::text, 2, '0'), 12
  from warehouses w, generate_series(1, 30) g where w.code = 'TWLHQ'
on conflict (code) do nothing;

insert into cart_baskets(cart_id, position, barcode, kind, warehouse_id)
select null, null, t.code, 'tote', w.id
  from warehouses w,
       (select 'BIN' || g as code from generate_series(406, 500) g
        union all select 'INV' || lpad(g::text, 3, '0') from generate_series(1, 5) g) t
 where w.code = 'TWLHQ'
on conflict (barcode) do nothing;
