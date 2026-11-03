-- =============================================================================
-- TWL WMS | Migration 025 | Stock tools: add / remove / set stock in a location
--   Tablet: scan (or type) a location, then a product, then add or remove pieces.
--   "What's in a location" can also set the count of any item in it.
--   Every change is an 'adjust' inventory transaction against the staff member
--   with a reason (ref_type 'stock_tool'). Stock reserved for carts can't be
--   removed. TV (display) logins can't adjust (wms__require_staff).
-- =============================================================================

create or replace function wms_adjust_stock(
  p_bin text, p_product text, p_mode text, p_qty int, p_reason text,
  p_note text default null, p_device_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := wms__require_staff();
  b bins; v_prod uuid; v_sku text; v_now int; v_res int; v_new int; v_delta int; v_label text;
begin
  if p_mode not in ('add','remove','set') then return jsonb_build_object('ok',false,'error','BAD_MODE'); end if;
  if p_qty is null or p_qty < 0 or p_qty > 99999 or (p_mode <> 'set' and p_qty = 0) then
    return jsonb_build_object('ok',false,'error','BAD_QTY');
  end if;

  v_label := case p_reason
    when 'count_fix' then 'Count was wrong'
    when 'found'     then 'Found stock'
    when 'damaged'   then 'Damaged / faulty'
    when 'return'    then 'Customer return'
    when 'other'     then 'Other'
    else null end;
  if v_label is null then return jsonb_build_object('ok',false,'error','BAD_REASON'); end if;
  if p_reason = 'other' and nullif(trim(coalesce(p_note, '')), '') is null then
    return jsonb_build_object('ok',false,'error','NOTE_REQUIRED');
  end if;

  b := wms__find_bin(p_bin);
  if b.id is null then return jsonb_build_object('ok',false,'error','UNKNOWN_BIN','scanned',p_bin); end if;
  v_prod := wms__find_product(p_product);
  if v_prod is null then return jsonb_build_object('ok',false,'error','UNKNOWN_BARCODE','scanned',p_product); end if;
  select sku into v_sku from products where id = v_prod;

  select qty_on_hand, qty_allocated into v_now, v_res
    from bin_inventory where bin_id = b.id and product_id = v_prod for update;
  v_now := coalesce(v_now, 0); v_res := coalesce(v_res, 0);

  v_new := case p_mode when 'add' then v_now + p_qty when 'remove' then v_now - p_qty else p_qty end;
  if v_new > v_now and not b.is_active then return jsonb_build_object('ok',false,'error','BIN_INACTIVE','bin',b.code); end if;
  if v_new < 0 then
    return jsonb_build_object('ok',false,'error','NOT_ENOUGH','on_hand',v_now,'sku',v_sku,'bin',b.code);
  end if;
  if v_new < v_res then
    return jsonb_build_object('ok',false,'error','BELOW_RESERVED','reserved',v_res,'on_hand',v_now,'sku',v_sku,'bin',b.code);
  end if;

  v_delta := v_new - v_now;
  if v_delta <> 0 then
    perform wms__apply_delta(b.id, v_prod, v_delta, 'adjust', 'stock_tool', null, v_staff, p_device_id, null,
                             'Stock tool: ' || v_label || coalesce(' - ' || nullif(trim(p_note), ''), ''));
  end if;
  return jsonb_build_object('ok',true,'bin',b.code,'sku',v_sku,'before',v_now,'after',v_new,'change',v_delta);
end $$;

-- my moves AND adjustments today (newest first)
create or replace function wms_my_recent_moves(p_limit int default 10) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]') from (
    select x from (
      select jsonb_build_object('at', max(it.occurred_at), 'sku', max(p.sku), 'qty', max(abs(it.qty_delta)) filter (where it.qty_delta > 0),
               'from', max(b.code) filter (where it.qty_delta < 0), 'to', max(b.code) filter (where it.qty_delta > 0),
               'kind', max(it.ref_type)) as x, max(it.occurred_at) as at
        from inventory_transactions it join bins b on b.id = it.bin_id join products p on p.id = it.product_id
       where it.staff_id = auth.uid() and it.txn_type in ('move_out','move_in') and it.occurred_at > now() - interval '1 day'
       group by it.move_group, it.product_id
      union all
      select jsonb_build_object('at', it.occurred_at, 'sku', p.sku, 'qty', it.qty_delta, 'bin', b.code, 'after', it.qty_after,
               'kind', 'adjust', 'reason', it.reason), it.occurred_at
        from inventory_transactions it join bins b on b.id = it.bin_id join products p on p.id = it.product_id
       where it.staff_id = auth.uid() and it.txn_type = 'adjust' and it.ref_type in ('stock_tool','pick_task')
         and it.occurred_at > now() - interval '1 day'
    ) u order by at desc limit p_limit
  ) t
$$;

revoke execute on function wms_adjust_stock(text, text, text, int, text, text, uuid) from public, anon;
grant execute on function wms_adjust_stock(text, text, text, int, text, text, uuid) to authenticated;
