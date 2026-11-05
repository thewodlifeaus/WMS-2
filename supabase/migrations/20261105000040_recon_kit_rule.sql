-- =============================================================================
-- 040  Kit rule: also catch "plus" / "2 x" kits
-- e.g. "TWL - Plate Carrier Weight Vest" variant "BLACK / Light: Plate Carrier Pro plus
-- 2 x 3.5lb TWL Tech Plates". "N x <weight>" only (not sizes like 240 x 240cm).
-- Still only applied to SKUs never stocked in a bin.
-- =============================================================================
create or replace function wms__recon_auto_kit(p_sku text, p_name text, p_variant text)
returns boolean language sql immutable as $$
  select coalesce(p_name, '') !~* 'component'
     and (coalesce(p_name, '') ~* '(bundle|mystery box|\mpack\M|\mpackages?\M| \+ )'
       or coalesce(p_variant, '') ~* '\m([2-9]|[1-9][0-9]+) ?-?(pack|pk|pak)\M'
       or (coalesce(p_name, '') || ' ' || coalesce(p_variant, '')) ~* '(\mplus\M|\m[0-9]+ ?x [0-9.]+ ?(lb|kg))'
       or coalesce(p_sku, '') ~* '([2-9]|[1-9][0-9])(pk|pak|pack)|-pair$|bundle')
$$;
