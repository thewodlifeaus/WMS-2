-- Existing SkuVault carts and hyper-picking totes for TWLHQ (checked in SkuVault 1 Nov 2026).
-- Totes are not tied to carts in SkuVault; pickers scan one per order when a cart starts.
-- Barcode = the code printed on the current labels, so nothing needs relabelling.
-- basket_count on a tote cart = max orders per trip (edit per cart if needed).
-- SkuVault carts: CART01-CART20 and INV01-INV10 (Wave Pick > Carts)
insert into carts(warehouse_id, code, barcode, basket_count)
select w.id, c.code, c.code, 12
  from warehouses w,
       (select 'CART' || lpad(g::text, 2, '0') as code from generate_series(1, 20) g
        union all select 'INV' || lpad(g::text, 2, '0') from generate_series(1, 10) g) c
 where w.code = 'TWLHQ'
on conflict (code) do nothing;

insert into cart_baskets(cart_id, position, barcode, kind, warehouse_id)
select null, null, t.code, 'tote', w.id
  from warehouses w,
       (select 'BIN' || g as code from generate_series(406, 500) g
        union all select 'INV' || lpad(g::text, 3, '0') from generate_series(1, 5) g) t
 where w.code = 'TWLHQ'
on conflict (barcode) do nothing;
