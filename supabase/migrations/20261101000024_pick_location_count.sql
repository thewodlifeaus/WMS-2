-- =============================================================================
-- TWL WMS | Migration 024 | Picking: show the location count + quick count fix
--   The pick screen shows how many of the item the WMS thinks are in the
--   location, and the picker can correct it on the spot (add or remove) with a
--   reason. Every change is an 'adjust' inventory transaction against the picker,
--   linked to the pick task, so it can be reviewed later.
--   The count can't go below what is already reserved for picks in that location
--   (including this pick): if there aren't enough, the picker uses Can't pick.
-- =============================================================================

-- current pick task: + how many are in the location (and how many are reserved)
create or replace function wms_get_current_task(p_session_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare t record; v_total int; v_done int;
begin
  perform wms__require_staff();
  select count(*), count(*) filter (where status <> 'pending') into v_total, v_done
    from pick_tasks where session_id = p_session_id;

  select pt.id, pt.sequence, pt.qty_required, pt.qty_picked, b.code as bin_code, b.barcode as bin_barcode,
         p.sku, p.name, p.variant_title, p.image_url,
         coalesce(bi.qty_on_hand, 0) as bin_on_hand, coalesce(bi.qty_allocated, 0) as bin_reserved
    into t
    from pick_tasks pt join bins b on b.id = pt.bin_id join products p on p.id = pt.product_id
    left join bin_inventory bi on bi.bin_id = pt.bin_id and bi.product_id = pt.product_id
   where pt.session_id = p_session_id and pt.status = 'pending'
   order by pt.sequence limit 1;

  if not found then
    return jsonb_build_object('session_id',p_session_id,'done',true,'progress',jsonb_build_object('total',v_total,'done',v_done));
  end if;

  return jsonb_build_object(
    'session_id', p_session_id, 'done', false,
    'progress', jsonb_build_object('total', v_total, 'done', v_done),
    'task', jsonb_build_object(
      'id', t.id, 'sequence', t.sequence, 'bin', t.bin_code, 'bin_barcode', t.bin_barcode,
      'sku', t.sku, 'name', t.name, 'variant', t.variant_title, 'image_url', t.image_url,
      'qty_required', t.qty_required, 'qty_picked', t.qty_picked,
      'bin_on_hand', t.bin_on_hand, 'bin_reserved', t.bin_reserved,
      'put_into', (select jsonb_agg(jsonb_build_object(
                      'basket', cb.position, 'basket_barcode', cb.barcode,
                      'order_number', o.order_number, 'qty', pa.qty, 'qty_picked', pa.qty_picked,
                      'on_hold', o.is_held, 'hold_reason', o.hold_reason)
                    order by pa.fill_order)
                     from pick_allocations pa
                     join orders o on o.id = pa.order_id
                     left join cart_baskets cb on cb.id = pa.basket_id
                    where pa.task_id = t.id)));
end $$;

-- picker fixes the count of this item in this location
create or replace function wms_pick_adjust_bin(
  p_task_id uuid, p_new_qty int, p_reason text, p_note text default null, p_device_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := wms__require_staff();
  t pick_tasks; s pick_sessions; v_now int; v_res int; v_delta int; v_label text;
begin
  select * into t from pick_tasks where id = p_task_id;
  if not found then return jsonb_build_object('ok',false,'error','TASK_NOT_FOUND'); end if;
  select * into s from pick_sessions where id = t.session_id;
  if s.status <> 'in_progress' or t.status <> 'pending' then return jsonb_build_object('ok',false,'error','NOT_ACTIVE'); end if;
  if s.paused_at is not null then return jsonb_build_object('ok',false,'error','CART_PAUSED','alarm',true); end if;
  if s.assigned_to is distinct from v_staff and not wms_has_role(array['admin','supervisor']::staff_role[]) then
    return jsonb_build_object('ok',false,'error','NOT_YOUR_CART','alarm',true);
  end if;

  v_label := case p_reason
    when 'more_here'   then 'More here than the WMS showed'
    when 'fewer_here'  then 'Fewer here than the WMS showed'
    when 'damaged'     then 'Damaged stock removed'
    when 'other'       then 'Other'
    else null end;
  if v_label is null then return jsonb_build_object('ok',false,'error','BAD_REASON'); end if;
  if p_reason = 'other' and nullif(trim(coalesce(p_note, '')), '') is null then
    return jsonb_build_object('ok',false,'error','NOTE_REQUIRED');
  end if;
  if p_new_qty is null or p_new_qty < 0 or p_new_qty > 9999 then return jsonb_build_object('ok',false,'error','BAD_QTY'); end if;

  select coalesce(qty_on_hand, 0), coalesce(qty_allocated, 0) into v_now, v_res
    from bin_inventory where bin_id = t.bin_id and product_id = t.product_id for update;
  v_now := coalesce(v_now, 0); v_res := coalesce(v_res, 0);

  -- reserved stock (this pick and other carts) has to stay: short the pick instead
  if p_new_qty < v_res then
    return jsonb_build_object('ok',false,'error','BELOW_RESERVED','reserved',v_res,
                              'this_pick', t.qty_required - t.qty_picked, 'on_hand', v_now);
  end if;

  v_delta := p_new_qty - v_now;
  if v_delta <> 0 then
    perform wms__apply_delta(t.bin_id, t.product_id, v_delta, 'adjust', 'pick_task', t.id,
                             v_staff, p_device_id, null,
                             'Pick count fix: ' || v_label || coalesce(' - ' || nullif(trim(p_note), ''), ''));
  end if;

  return jsonb_build_object('ok',true,'before',v_now,'after',p_new_qty,'change',v_delta,
                            'current', wms_get_current_task(t.session_id));
end $$;

revoke execute on function wms_pick_adjust_bin(uuid, int, text, text, uuid) from public, anon;
grant execute on function wms_pick_adjust_bin(uuid, int, text, text, uuid) to authenticated;
