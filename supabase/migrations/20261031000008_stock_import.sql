-- =============================================================================
-- TWL WMS | Migration 008 | Opening stock from SkuVault
-- rows = [{sku, location, qty}]  -> sets each SKU x bin to exactly qty
-- Every change is written to the ledger as a 'cycle_count' with the reason given,
-- so re-running before cutover just tops up / trims to SkuVault's latest numbers.
-- Allocated stock is never trimmed below what pickers have reserved.
-- =============================================================================
create or replace function wms_import_stock(p_warehouse_code text, p_rows jsonb, p_reason text,
                                            p_token text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_wh uuid; r record; v_cur int; v_alloc int; v_set int := 0; v_skipped jsonb := '[]';
begin
  if not wms__import_allowed(p_token) then raise exception 'FORBIDDEN'; end if;
  select id into v_wh from warehouses where code = p_warehouse_code;

  for r in
    select x->>'sku' as sku, x->>'location' as loc, (x->>'qty')::int as qty, p.id as product_id, b.id as bin_id
      from jsonb_array_elements(p_rows) x
      left join products p on p.sku = x->>'sku'
      left join bins b on b.warehouse_id = v_wh and b.code = x->>'location'
  loop
    if r.product_id is null or r.bin_id is null or r.qty < 0 then
      v_skipped := v_skipped || jsonb_build_object('sku', r.sku, 'location', r.loc,
                     'why', case when r.product_id is null then 'UNKNOWN_SKU' when r.bin_id is null then 'UNKNOWN_BIN' else 'BAD_QTY' end);
      continue;
    end if;
    select qty_on_hand, qty_allocated into v_cur, v_alloc from bin_inventory
     where bin_id = r.bin_id and product_id = r.product_id for update;
    if greatest(r.qty, coalesce(v_alloc,0)) <> coalesce(v_cur,0) then
      perform wms__apply_delta(r.bin_id, r.product_id, greatest(r.qty, coalesce(v_alloc,0)) - coalesce(v_cur,0),
                               'cycle_count', 'import', null, null, null, null, p_reason);
      v_set := v_set + 1;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'changed', v_set, 'skipped', v_skipped);
end $$;

revoke execute on function wms_import_stock(text, jsonb, text, text) from public;
grant  execute on function wms_import_stock(text, jsonb, text, text) to anon, authenticated;  -- needs admin or live token
