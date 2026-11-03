-- =============================================================================
-- TWL WMS | Migration 027 | Stock reasons + stock history log
--   * Add / remove stock reasons: + Receiving stock, + Stocktake (add or remove).
--     Reasons that only make sense one way are checked (eg Receiving can't remove).
--   * wms_stock_history: every stock change (adjustments, moves, merges, picks,
--     receiving, counts) with when, who, what, where, change, balance after and
--     reason. Admins and supervisors only. Filter by date, person, type, and
--     SKU / product / location text. Moves show both locations on one row.
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
    when 'receiving' then 'Receiving stock'
    when 'stocktake' then 'Stocktake'
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
  -- one-way reasons
  if (p_reason in ('receiving','found','return') and v_new < v_now) or (p_reason = 'damaged' and v_new > v_now) then
    return jsonb_build_object('ok',false,'error','REASON_WRONG_WAY');
  end if;
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

-- stock history log (admin / supervisor)
--   p_kind: 'changes' (default: adjustments, moves, receiving, counts, returns), 'all',
--           or one of 'adjust','move','pick','receive','count','ship','return'
create or replace function wms_stock_history(
  p_from date default null, p_to date default null, p_staff uuid default null,
  p_search text default null, p_kind text default 'changes', p_limit int default 200, p_offset int default 0
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  tz constant text := 'Australia/Adelaide';
  d0 timestamptz; d1 timestamptz; q text := nullif(trim(coalesce(p_search, '')), ''); v jsonb; v_n int;
  kinds txn_type[];
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  d0 := (coalesce(p_from, (now() at time zone tz)::date - 6)::timestamp) at time zone tz;
  d1 := ((coalesce(p_to, (now() at time zone tz)::date) + 1)::timestamp) at time zone tz;
  kinds := case coalesce(p_kind, 'changes')
    when 'all'     then enum_range(null::txn_type)
    when 'changes' then array['adjust','move_out','move_in','receive','cycle_count','return','unpick']::txn_type[]
    when 'adjust'  then array['adjust']::txn_type[]
    when 'move'    then array['move_out','move_in']::txn_type[]
    when 'pick'    then array['pick','unpick']::txn_type[]
    when 'receive' then array['receive']::txn_type[]
    when 'count'   then array['cycle_count']::txn_type[]
    when 'ship'    then array['ship']::txn_type[]
    when 'return'  then array['return']::txn_type[]
    else array['adjust']::txn_type[] end;

  with t as (
    select it.*, p.sku, p.name as product, p.variant_title, b.code as bin, s.display_name as who
      from inventory_transactions it
      join products p on p.id = it.product_id
      left join bins b on b.id = it.bin_id
      left join staff s on s.id = it.staff_id
     where it.occurred_at >= d0 and it.occurred_at < d1
       and it.txn_type = any(kinds)
       and (p_staff is null or it.staff_id = p_staff)
       -- moves: show one row per move (the "into" side), with the from location
       and not (it.txn_type = 'move_out' and it.move_group is not null and exists (
                  select 1 from inventory_transactions x where x.move_group = it.move_group and x.product_id = it.product_id and x.txn_type = 'move_in'))
       and (q is null or p.sku ilike '%' || q || '%' or p.name ilike '%' || q || '%' or b.code ilike '%' || q || '%'
            or it.reason ilike '%' || q || '%'
            or (it.move_group is not null and exists (select 1 from inventory_transactions x join bins bx on bx.id = x.bin_id
                  where x.move_group = it.move_group and x.product_id = it.product_id and bx.code ilike '%' || q || '%')))
  ), counted as (select count(*) as cnt from t),
  page as (
    select * from t order by occurred_at desc, id desc limit least(greatest(coalesce(p_limit, 200), 1), 1000) offset greatest(coalesce(p_offset, 0), 0)
  )
  select (select cnt from counted),
         coalesce(jsonb_agg(jsonb_build_object(
           'id', pg.id, 'at', pg.occurred_at, 'type', pg.txn_type, 'ref', pg.ref_type, 'who', coalesce(pg.who, 'System'),
           'sku', pg.sku, 'product', pg.product, 'variant', pg.variant_title,
           'bin', pg.bin, 'change', pg.qty_delta, 'after', pg.qty_after, 'reason', pg.reason,
           'from_bin', case when pg.txn_type = 'move_in' and pg.move_group is not null then
                         (select bx.code from inventory_transactions x join bins bx on bx.id = x.bin_id
                           where x.move_group = pg.move_group and x.product_id = pg.product_id and x.txn_type = 'move_out' limit 1) end,
           'from_after', case when pg.txn_type = 'move_in' and pg.move_group is not null then
                         (select x.qty_after from inventory_transactions x
                           where x.move_group = pg.move_group and x.product_id = pg.product_id and x.txn_type = 'move_out' limit 1) end,
           'order_number', case when pg.ref_type = 'pick_task' then
                         (select string_agg(distinct o.order_number, ', ') from pick_allocations pa join orders o on o.id = pa.order_id where pa.task_id = pg.ref_id) end)
           order by pg.occurred_at desc, pg.id desc), '[]')
    into v_n, v
    from page pg;

  return jsonb_build_object('total', v_n, 'rows', v, 'from', d0, 'to', d1,
    'staff', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', display_name) order by display_name), '[]') from staff where role <> 'display'));
end $$;

create index if not exists inv_txn_move_group_idx on inventory_transactions(move_group) where move_group is not null;
create index if not exists inv_txn_time_idx on inventory_transactions(occurred_at desc);

revoke execute on function wms_stock_history(date, date, uuid, text, text, int, int) from public, anon;
grant execute on function wms_stock_history(date, date, uuid, text, text, int, int) to authenticated;
