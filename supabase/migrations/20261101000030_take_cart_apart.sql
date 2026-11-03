-- =============================================================================
-- TWL WMS | Migration 030 | Take a cart apart at any stage
--   Admin / supervisor can take a cart apart even if it is assigned to a picker or
--   picking has started. Every order on it goes back to the queue, ready to be
--   built onto another cart. Anything already picked is put back on the shelf
--   (where it was picked from, or one location you choose), logged as 'unpick'.
--   Orders that have reached the pack desk are left alone and reported.
--   Works on open carts and on finished carts whose orders are still waiting to
--   be packed. p_confirmed = false returns a preview (what to put back).
-- =============================================================================

create or replace function wms_take_cart_apart(
  p_session_id uuid, p_reason text default null, p_return_bin text default null, p_confirmed boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := wms__require_staff();
  s pick_sessions; v_cart text; r record; v_res jsonb; v_ret bins;
  v_back jsonb := '[]'; v_done jsonb := '[]'; v_kept jsonb := '[]'; v_units int := 0; v_reason text;
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then return jsonb_build_object('ok',false,'error','FORBIDDEN'); end if;
  select * into s from pick_sessions where id = p_session_id for update;
  if s.id is null then return jsonb_build_object('ok',false,'error','NOT_FOUND'); end if;
  if s.status = 'cancelled' then return jsonb_build_object('ok',false,'error','ALREADY_CLOSED'); end if;
  select code into v_cart from carts where id = s.cart_id;
  if p_return_bin is not null and trim(p_return_bin) <> '' then
    v_ret := wms__find_bin(p_return_bin);
    if v_ret.id is null then return jsonb_build_object('ok',false,'error','UNKNOWN_BIN','scanned',p_return_bin); end if;
    if not v_ret.is_active then return jsonb_build_object('ok',false,'error','BIN_INACTIVE','bin',v_ret.code); end if;
  end if;

  -- preview: everything already picked on this cart and where it goes back
  if not coalesce(p_confirmed, false) then
    select coalesce(jsonb_agg(jsonb_build_object('sku', p.sku, 'name', p.name, 'variant', p.variant_title, 'qty', pa.qty_picked,
                                                 'tote', cb.barcode, 'order_number', o.order_number, 'to_bin', coalesce(v_ret.code, b.code))
                              order by b.code, p.sku), '[]'), coalesce(sum(pa.qty_picked), 0)
      into v_back, v_units
      from pick_allocations pa join pick_tasks t on t.id = pa.task_id join products p on p.id = t.product_id
      join bins b on b.id = t.bin_id join orders o on o.id = pa.order_id
      left join cart_baskets cb on cb.id = pa.basket_id
     where t.session_id = s.id and pa.qty_picked > 0
       and o.status not in ('packing','packed','shipped');
    return jsonb_build_object('ok',true,'preview',true,'cart',v_cart,'status',s.status,
      'picker',(select display_name from staff where id = s.assigned_to),
      'orders',(select count(*) from pick_session_orders where session_id = s.id),
      'at_pack_desk',(select coalesce(jsonb_agg(o.order_number), '[]') from pick_session_orders x join orders o on o.id = x.order_id
                       where x.session_id = s.id and o.status in ('packing','packed','shipped')),
      'put_back',v_back,'units_put_back',v_units);
  end if;

  v_reason := coalesce(nullif(trim(coalesce(p_reason, '')), ''), 'Cart taken apart');
  -- each order: off the cart and back to the queue (puts picked items back)
  for r in select x.order_id, o.order_number from pick_session_orders x join orders o on o.id = x.order_id
            where x.session_id = s.id order by x.slot nulls last, o.order_number loop
    v_res := wms_remove_order_from_cart(r.order_id, 'requeue', v_reason, p_return_bin, true);
    if coalesce((v_res->>'ok')::boolean, false) then
      v_done := v_done || to_jsonb(r.order_number);
      v_back := v_back || coalesce(v_res->'put_back', '[]');
      v_units := v_units + coalesce((v_res->>'units_put_back')::int, 0);
    else
      v_kept := v_kept || jsonb_build_object('order_number', r.order_number, 'why', v_res->>'error');
    end if;
  end loop;

  -- close the cart if anything is left on it (eg orders already at the pack desk)
  update pick_tasks set status = 'cancelled' where session_id = s.id and status = 'pending';
  update pick_sessions set status = case when status = 'completed' then status else 'cancelled'::session_status end,
         completed_at = coalesce(completed_at, now()), paused_at = null
   where id = s.id;
  -- close the picker's active time (same as unassigning)
  if s.assigned_to is not null and s.status = 'in_progress' then
    insert into pick_session_events(session_id, staff_id, event, reason) values (s.id, s.assigned_to, 'release', 'Cart taken apart: ' || v_reason);
  end if;

  return jsonb_build_object('ok',true,'cart',v_cart,'orders_back_in_queue',v_done,'kept',v_kept,
                            'put_back',v_back,'units_put_back',v_units);
end $$;

revoke execute on function wms_take_cart_apart(uuid, text, text, boolean) from public, anon;
grant execute on function wms_take_cart_apart(uuid, text, text, boolean) to authenticated;
