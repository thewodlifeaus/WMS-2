-- =============================================================================
-- TWL WMS | Migration 032 | Undo a stock change from Stock history
--   Admin / supervisor can undo:
--     * an add / remove / count change (stock tools or pick count fix): the same
--       number goes back the other way in the same location;
--     * a move or merge row: the units move back from where they went to where
--       they came from.
--   Not undoable: picks, packing, put-backs off carts, receiving, or a change
--   that was already undone (or is itself an undo).
--   An undo needs the stock to still be there and free: if it has since been
--   picked, moved or reserved for a cart, the undo is refused and says why.
--   Both rows are linked: original.metadata.undone_* and undo.metadata.undo_of.
--   The undo is logged against the person who did it, with their reason.
-- =============================================================================

create or replace function wms__undoable(p_txn bigint) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select (t.txn_type = 'adjust' and coalesce(t.ref_type, '') in ('stock_tool','pick_task'))
        or (t.txn_type = 'move_in' and t.move_group is not null and coalesce(t.ref_type, '') in ('move','merge'))
      from inventory_transactions t
     where t.id = p_txn and t.metadata->>'undone_at' is null and t.metadata->>'undo_of' is null), false)
$$;

create or replace function wms_undo_stock_change(p_txn_id bigint, p_reason text default null, p_confirmed boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := wms__require_staff();
  t inventory_transactions; v_out inventory_transactions; b bins; b_from bins; v_sku text; v_free int; v_now int;
  v_group uuid := gen_random_uuid(); v_note text; v_new bigint; v_name text; v_after int; v_after2 int;
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then return jsonb_build_object('ok',false,'error','FORBIDDEN'); end if;
  select * into t from inventory_transactions where id = p_txn_id for update;
  if t.id is null then return jsonb_build_object('ok',false,'error','NOT_FOUND'); end if;
  if t.metadata->>'undone_at' is not null then
    return jsonb_build_object('ok',false,'error','ALREADY_UNDONE','by',t.metadata->>'undone_by_name','at',t.metadata->>'undone_at');
  end if;
  if not wms__undoable(t.id) then return jsonb_build_object('ok',false,'error','NOT_UNDOABLE','type',t.txn_type); end if;
  select sku into v_sku from products where id = t.product_id;
  select * into b from bins where id = t.bin_id;
  select display_name into v_name from staff where id = v_staff;
  v_note := 'Undo #' || t.id || coalesce(': ' || nullif(trim(coalesce(p_reason, '')), ''), '');

  if t.txn_type = 'adjust' then
    -- adds come back out, removes go back in (same location)
    select coalesce(qty_on_hand, 0), coalesce(qty_on_hand - qty_allocated, 0) into v_now, v_free
      from bin_inventory where bin_id = t.bin_id and product_id = t.product_id for update;
    v_now := coalesce(v_now, 0); v_free := coalesce(v_free, 0);
    if t.qty_delta > 0 and v_free < t.qty_delta then
      return jsonb_build_object('ok',false,'error','NOT_ENOUGH_FREE','sku',v_sku,'bin',b.code,'need',t.qty_delta,'free',v_free,'on_hand',v_now);
    end if;
    if not coalesce(p_confirmed, false) then
      return jsonb_build_object('ok',true,'preview',true,'kind','adjust','sku',v_sku,'bin',b.code,'change',-t.qty_delta,
                                'now',v_now,'after',v_now - t.qty_delta,'original_reason',t.reason);
    end if;
    v_after := wms__apply_delta(t.bin_id, t.product_id, -t.qty_delta, 'adjust', 'undo', null, v_staff, null, null, v_note);
    select max(id) into v_new from inventory_transactions where staff_id = v_staff and ref_type = 'undo' and bin_id = t.bin_id and product_id = t.product_id;
    update inventory_transactions set metadata = metadata || jsonb_build_object('undo_of', t.id) where id = v_new;
    update inventory_transactions set metadata = metadata || jsonb_build_object('undone_at', now(), 'undone_by', v_staff, 'undone_by_name', v_name, 'undone_by_txn', v_new)
     where id = t.id;
    return jsonb_build_object('ok',true,'kind','adjust','sku',v_sku,'bin',b.code,'change',-t.qty_delta,'after',v_after);
  end if;

  -- move / merge: take the units back from where they went to where they came from
  select * into v_out from inventory_transactions
   where move_group = t.move_group and product_id = t.product_id and txn_type = 'move_out' order by id limit 1 for update;
  if v_out.id is null then return jsonb_build_object('ok',false,'error','NOT_UNDOABLE','type','move'); end if;
  select * into b_from from bins where id = v_out.bin_id;
  select coalesce(qty_on_hand - qty_allocated, 0) into v_free from bin_inventory where bin_id = t.bin_id and product_id = t.product_id for update;
  v_free := coalesce(v_free, 0);
  if v_free < t.qty_delta then
    return jsonb_build_object('ok',false,'error','NOT_ENOUGH_FREE','sku',v_sku,'bin',b.code,'need',t.qty_delta,'free',v_free);
  end if;
  if not b_from.is_active then return jsonb_build_object('ok',false,'error','BIN_INACTIVE','bin',b_from.code); end if;
  if not coalesce(p_confirmed, false) then
    return jsonb_build_object('ok',true,'preview',true,'kind','move','sku',v_sku,'qty',t.qty_delta,'from',b.code,'to',b_from.code,
      'from_now',(select qty_on_hand from bin_inventory where bin_id = t.bin_id and product_id = t.product_id),
      'to_now',coalesce((select qty_on_hand from bin_inventory where bin_id = v_out.bin_id and product_id = t.product_id), 0));
  end if;
  v_after  := wms__apply_delta(t.bin_id,     t.product_id, -t.qty_delta, 'move_out', 'undo', null, v_staff, null, v_group, v_note);
  v_after2 := wms__apply_delta(v_out.bin_id, t.product_id,  t.qty_delta, 'move_in',  'undo', null, v_staff, null, v_group, v_note);
  update inventory_transactions set metadata = metadata || jsonb_build_object('undo_of', t.id) where move_group = v_group;
  select id into v_new from inventory_transactions where move_group = v_group and txn_type = 'move_in';
  update inventory_transactions set metadata = metadata || jsonb_build_object('undone_at', now(), 'undone_by', v_staff, 'undone_by_name', v_name, 'undone_by_txn', v_new)
   where id in (t.id, v_out.id);
  return jsonb_build_object('ok',true,'kind','move','sku',v_sku,'qty',t.qty_delta,'from',b.code,'from_after',v_after,'to',b_from.code,'to_after',v_after2);
end $$;

-- stock history (027 + undo flags)
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
           -- undo (032): already undone? is this row itself an undo? can it be undone?
           'undone_at', pg.metadata->>'undone_at', 'undone_by', pg.metadata->>'undone_by_name', 'undo_of', pg.metadata->>'undo_of',
           'undoable', wms__undoable(pg.id),
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

revoke execute on function wms__undoable(bigint) from public, anon;
grant execute on function wms__undoable(bigint) to authenticated;
revoke execute on function wms_undo_stock_change(bigint, text, boolean) from public, anon;
grant execute on function wms_undo_stock_change(bigint, text, boolean) to authenticated;
