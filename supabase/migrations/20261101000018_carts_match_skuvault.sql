-- TWL WMS | Migration 018 | Carts match SkuVault (Wave Pick > Carts, checked 1 Nov 2026)
-- SkuVault carts: CART01-CART20 and INV01-INV10. Totes (Wave Pick > Bins) are not tied to carts:
-- BIN406-BIN500 (type TOTE) and INV001-INV005 (type INV-CAGE), scanned onto a cart when picking starts.
update carts set is_active = false where code between 'CART21' and 'CART30';
insert into carts(warehouse_id, code, barcode, basket_count)
select w.id, 'INV' || lpad(g::text, 2, '0'), 'INV' || lpad(g::text, 2, '0'), 12
  from warehouses w, generate_series(1, 10) g where w.code = 'TWLHQ'
on conflict (code) do update set is_active = true;

create or replace function wms__find_cart(p_text text) returns carts
language sql stable security definer set search_path = public as $$
  select c.* from carts c
   where c.is_active and (upper(c.barcode) = upper(trim(p_text)) or upper(c.code) = upper(trim(p_text))
      or (trim(p_text) ~ '^\D*\d{1,3}$' and c.code ~ '\d+$'
          and substring(c.code from '(\d+)$')::int = substring(trim(p_text) from '(\d+)$')::int
          -- "INV3" only matches INV carts; a bare number ("3") prefers CART carts
          and (substring(trim(p_text) from '^(\D*)') = ''
               or upper(c.code) like upper(substring(trim(p_text) from '^(\D*)')) || '%')))
   order by (upper(c.barcode) = upper(trim(p_text))) desc, (c.code like 'CART%') desc, c.code limit 1
$$;
