-- =============================================================================
-- TWL WMS | Migration 007 | Importing the SkuVault layout + Shopify products
--   * bins: allow 2-part codes (SA-01) and 1-part floor codes (0-RECEIVE)
--   * wms_import_*: bulk loaders, callable by an admin (desktop app) OR with a
--     short-lived one-time token (used for the first load from Ben's Mac)
-- =============================================================================

-- 2-part codes like 'SA-01' (row SA, shelf 01, no bin level)
create or replace function wms__bins_before_write() returns trigger
language plpgsql set search_path = public as $$
declare r record; wh_code text;
begin
  if new.shelf_id is not null then
    select ar.code as row_code, ar.sequence as row_seq, ar.zone_id,
           sh.code as shelf_code, sh.sequence as shelf_seq, sh.side, ar.warehouse_id
      into r
      from shelves sh join aisle_rows ar on ar.id = sh.row_id
     where sh.id = new.shelf_id;
    if r.warehouse_id <> new.warehouse_id then
      raise exception 'Bin warehouse does not match its shelf warehouse';
    end if;
    new.code       := r.row_code || '-' || r.shelf_code || case when new.bin_code = '' then '' else '-' || new.bin_code end;
    new.row_seq    := r.row_seq;
    new.shelf_seq  := r.shelf_seq;
    new.shelf_side := r.side;
    new.zone_id    := coalesce(new.zone_id, r.zone_id);
  else
    new.code := coalesce(nullif(new.code, ''), new.bin_code);   -- floor areas: '0-RECEIVE'
  end if;
  new.bin_seq := coalesce(nullif(regexp_replace(new.bin_code, '\D', '', 'g'), '')::int, 0);
  if new.barcode is null or new.barcode = '' or tg_op = 'UPDATE' and new.code <> old.code then
    select code into wh_code from warehouses where id = new.warehouse_id;
    new.barcode := 'LOC:' || wh_code || ':' || new.code;
  end if;
  return new;
end $$;

-- one-time import tokens (no RLS policy = invisible to the apps)
create table if not exists import_tokens (
  token       text primary key,
  expires_at  timestamptz not null,
  created_at  timestamptz not null default now()
);
alter table import_tokens enable row level security;

create or replace function wms__import_allowed(p_token text) returns boolean
language sql stable security definer set search_path = public as $$
  select wms_has_role(array['admin']::staff_role[])
      or exists (select 1 from import_tokens where token = p_token and expires_at > now())
$$;

-- ---------------------------------------------------------------------------
-- Layout import. rows = [{code, row, shelf, bin, type, zone}]
--   code  'A-09-01' | 'SA-01' | '0-RECEIVE'
--   type  pick | backfill | reserved | receiving | staging | quarantine
-- Idempotent: re-running updates types and adds new bins, never deletes.
-- ---------------------------------------------------------------------------
create or replace function wms_import_layout(p_warehouse_code text, p_rows jsonb, p_token text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_wh uuid; v_n int := 0; r jsonb; v_zone uuid; v_row uuid; v_shelf uuid; v_seq int;
begin
  if not wms__import_allowed(p_token) then raise exception 'FORBIDDEN'; end if;
  select id into v_wh from warehouses where code = p_warehouse_code;
  if v_wh is null then raise exception 'UNKNOWN_WAREHOUSE %', p_warehouse_code; end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    v_zone := null; v_row := null; v_shelf := null;
    if r->>'zone' is not null then
      insert into zones(warehouse_id, code, name, sequence)
      values (v_wh, r->>'zone', coalesce(r->>'zone_name', r->>'zone'), coalesce((r->>'zone_seq')::int, 0))
      on conflict (warehouse_id, code) do update set name = excluded.name, sequence = excluded.sequence
      returning id into v_zone;
    end if;
    if r->>'row' is not null then
      select id into v_row from aisle_rows where warehouse_id = v_wh and code = r->>'row';
      if v_row is null then
        v_seq := coalesce((r->>'row_seq')::int,
                          (select coalesce(max(sequence),0) + 1 from aisle_rows where warehouse_id = v_wh));
        insert into aisle_rows(warehouse_id, zone_id, code, sequence) values (v_wh, v_zone, r->>'row', v_seq)
        returning id into v_row;
      end if;
      select id into v_shelf from shelves where row_id = v_row and code = r->>'shelf';
      if v_shelf is null then
        insert into shelves(row_id, code, sequence)
        values (v_row, r->>'shelf', coalesce(nullif(regexp_replace(r->>'shelf','\D','','g'),'')::int, 0))
        returning id into v_shelf;
      end if;
    end if;
    insert into bins(warehouse_id, shelf_id, zone_id, bin_code, code, barcode, location_type)
    values (v_wh, v_shelf, v_zone, coalesce(r->>'bin', r->>'code'), coalesce(r->>'code',''), '',
            (r->>'type')::location_type)
    on conflict (warehouse_id, code) do update set location_type = excluded.location_type,
                                                   zone_id = coalesce(excluded.zone_id, bins.zone_id);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'rows', v_n);
end $$;

-- ---------------------------------------------------------------------------
-- Product import (Shopify variants). rows = [{sku, name, variant_title, size,
--   colour, shopify_variant_id, barcode, weight_grams, image_url, is_active}]
-- Upsert on SKU. Barcodes are added, never removed.
-- ---------------------------------------------------------------------------
create or replace function wms_import_products(p_rows jsonb, p_token text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_ins int := 0; v_bc int := 0;
begin
  if not wms__import_allowed(p_token) then raise exception 'FORBIDDEN'; end if;

  with src as (
    select distinct on (x->>'sku') x from jsonb_array_elements(p_rows) x
     where coalesce(x->>'sku','') <> ''
     order by x->>'sku'
  ), up as (
    insert into products(sku, name, variant_title, size, colour, shopify_variant_id, weight_grams, image_url, is_active, updated_at)
    select x->>'sku', x->>'name', x->>'variant_title', x->>'size', x->>'colour',
           (x->>'shopify_variant_id')::bigint, (x->>'weight_grams')::int, x->>'image_url',
           coalesce((x->>'is_active')::boolean, true), now()
      from src
    on conflict (sku) do update set
      name = excluded.name, variant_title = excluded.variant_title, size = excluded.size,
      colour = excluded.colour, shopify_variant_id = excluded.shopify_variant_id,
      weight_grams = coalesce(excluded.weight_grams, products.weight_grams),
      image_url = coalesce(excluded.image_url, products.image_url),
      is_active = excluded.is_active, updated_at = now()
    returning 1
  )
  select count(*) into v_ins from up;

  insert into product_barcodes(barcode, product_id, is_primary)
  select distinct on (x->>'barcode') x->>'barcode', p.id, true
    from jsonb_array_elements(p_rows) x join products p on p.sku = x->>'sku'
   where coalesce(x->>'barcode','') <> ''
  on conflict (barcode) do nothing;
  get diagnostics v_bc = row_count;

  return jsonb_build_object('ok', true, 'products', v_ins, 'new_barcodes', v_bc);
end $$;

revoke execute on function wms__import_allowed(text) from public, anon, authenticated;
revoke execute on function wms_import_layout(text, jsonb, text) from public;
revoke execute on function wms_import_products(jsonb, text) from public;
grant  execute on function wms_import_layout(text, jsonb, text) to anon, authenticated;  -- still needs admin or a live token
grant  execute on function wms_import_products(jsonb, text)     to anon, authenticated;
