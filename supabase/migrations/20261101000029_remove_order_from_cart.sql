-- =============================================================================
-- TWL WMS | Migration 029 | Take one order off a cart
--   For a customer who cancels or changes their order after it went on a cart.
--   * Anything not yet picked: the stock reservation is released.
--   * Anything already picked into the tote: put back on the shelf. By default
--     back where it was picked from, or into one location you choose. Each unit
--     put back is an 'unpick' stock movement against the person, with the reason.
--   * The order then goes back to the queue, on hold, or cancelled (WMS only;
--     ShipStation is not changed).
--   * The rest of the cart is untouched. A cart left with no orders is closed.
--   * Not allowed once the order is at the pack desk (packing started / packed).
--   Admin / supervisor only. p_confirmed = false returns a preview (what to put back).
-- =============================================================================

create or replace function wms_remove_order_from_cart(
  p_order_id uuid, p_action text, p_reason text, p_return_bin text default null,
  p_confirmed boolean default false, p_device_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := wms__require_staff();
  o orders; pso pick_session_orders; s pick_sessions; v_cart text; v_tote text; v_ret bins;
  a record; v_back jsonb := '[]'; v_released int := 0; v_putback int := 0; v_left int; v_note text;
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then
    return jsonb_build_object('ok',false,'error','FORBIDDEN');
  end if;
  if coalesce(p_action, '') not in ('requeue','hold','cancel') then return jsonb_build_object('ok',false,'error','BAD_ACTION'); end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null and coalesce(p_confirmed, false) then
    return jsonb_build_object('ok',false,'error','REASON_REQUIRED');
  end if;

  select * into o from orders where id = p_order_id for update;
  if o.id is null then return jsonb_build_object('ok',false,'error','NOT_FOUND'); end if;
  if o.status in ('packing','packed','shipped')
     or exists (select 1 from shipments sh where sh.order_id = o.id and sh.status <> 'voided') then
    return jsonb_build_object('ok',false,'error','AT_PACK_DESK','status',o.status);
  end if;

  -- the cart it is on (open cart, or a finished cart it is still sitting in)
  select x.* into pso from pick_session_orders x join pick_sessions ps on ps.id = x.session_id
   where x.order_id = o.id
     and (ps.status in ('draft','assigned','in_progress') or (ps.status = 'completed' and o.status in ('picked','picking')))
   order by ps.created_at desc limit 1;
  if pso.session_id is null then return jsonb_build_object('ok',false,'error','NOT_ON_A_CART'); end if;
  select * into s from pick_sessions where id = pso.session_id for update;
  select code into v_cart from carts where id = s.cart_id;
  select barcode into v_tote from cart_baskets where id = pso.basket_id;

  if p_return_bin is not null and trim(p_return_bin) <> '' then
    v_ret := wms__find_bin(p_return_bin);
    if v_ret.id is null then return jsonb_build_object('ok',false,'error','UNKNOWN_BIN','scanned',p_return_bin); end if;
    if not v_ret.is_active then return jsonb_build_object('ok',false,'error','BIN_INACTIVE','bin',v_ret.code); end if;
  end if;

  -- what is picked (goes back on a shelf) and what is only reserved
  select coalesce(jsonb_agg(jsonb_build_object('sku', p.sku, 'name', p.name, 'variant', p.variant_title, 'qty', pa.qty_picked,
                                               'from_tote', v_tote, 'to_bin', coalesce(v_ret.code, b.code))
                            order by b.code, p.sku) filter (where pa.qty_picked > 0), '[]'),
         coalesce(sum(pa.qty - pa.qty_picked), 0), coalesce(sum(pa.qty_picked), 0)
    into v_back, v_released, v_putback
    from pick_allocations pa join pick_tasks t on t.id = pa.task_id
    join products p on p.id = t.product_id join bins b on b.id = t.bin_id
   where t.session_id = s.id and pa.order_id = o.id;

  if not coalesce(p_confirmed, false) then
    return jsonb_build_object('ok',true,'preview',true,'order_number',o.order_number,'cart',v_cart,'tote',v_tote,
      'session_status',s.status,'put_back',v_back,'units_put_back',v_putback,'units_released',v_released,
      'other_orders',(select count(*) from pick_session_orders where session_id = s.id and order_id <> o.id),
      'cancelled_in_shopify', coalesce(o.hold_reason, '') ilike '%cancel%');
  end if;

  v_note := 'Removed from cart ' || coalesce(v_cart, '') || ': ' || trim(p_reason);

  for a in select pa.*, t.bin_id, t.product_id, t.qty_required, t.qty_picked as task_picked
             from pick_allocations pa join pick_tasks t on t.id = pa.task_id
            where t.session_id = s.id and pa.order_id = o.id
            for update of pa, t loop
    -- unpicked units: release the reservation
    if a.qty - a.qty_picked > 0 then
      update bin_inventory set qty_allocated = greatest(qty_allocated - (a.qty - a.qty_picked), 0), updated_at = now()
       where bin_id = a.bin_id and product_id = a.product_id;
    end if;
    -- picked units: back onto a shelf
    if a.qty_picked > 0 then
      perform wms__apply_delta(coalesce(v_ret.id, a.bin_id), a.product_id, a.qty_picked, 'unpick', 'order_removed', o.id,
                               v_staff, p_device_id, null, v_note);
    end if;
    update order_lines set qty_picked = greatest(qty_picked - a.qty_picked, 0),
                           qty_allocated = greatest(qty_allocated - a.qty, 0)
     where id = a.order_line_id;
    delete from pick_allocations where id = a.id;
    -- shrink the stop, or remove it if this order was all it was for
    if a.qty_required - a.qty <= 0 then
      if exists (select 1 from pick_exceptions where task_id = a.task_id) then
        update pick_tasks set status = 'cancelled', qty_picked = 0 where id = a.task_id;   -- keep the override record
      else
        delete from pick_tasks where id = a.task_id;
      end if;
    else
      update pick_tasks set qty_required = qty_required - a.qty,
                            qty_picked = greatest(qty_picked - a.qty_picked, 0),
                            status = case when status = 'cancelled' then status
                                          when qty_picked - a.qty_picked >= qty_required - a.qty then 'done'::task_status
                                          else status end,
                            completed_at = case when qty_picked - a.qty_picked >= qty_required - a.qty then coalesce(completed_at, now()) else completed_at end
       where id = a.task_id;
    end if;
  end loop;

  delete from pick_session_orders where session_id = s.id and order_id = o.id;

  update orders set
    status = case p_action when 'cancel' then 'cancelled'::order_status
                           when 'hold'   then 'on_hold'::order_status
                           else 'awaiting_pick'::order_status end,
    is_held = (p_action = 'hold'),
    held_at = case when p_action = 'hold' then now() else held_at end,
    held_by = case when p_action = 'hold' then v_staff else held_by end,
    hold_reason = case when p_action = 'requeue' then null else v_note end
   where id = o.id;

  -- the rest of the cart
  select count(*) into v_left from pick_session_orders where session_id = s.id;
  if v_left = 0 and s.status in ('draft','assigned','in_progress') then
    update pick_tasks set status = 'cancelled' where session_id = s.id and status = 'pending';
    update pick_sessions set status = 'cancelled', completed_at = now(), paused_at = null where id = s.id;
  elsif s.status = 'in_progress' then
    perform wms__close_session_if_done(s.id);
  end if;

  return jsonb_build_object('ok',true,'order_number',o.order_number,'cart',v_cart,'tote',v_tote,'action',p_action,
    'put_back',v_back,'units_put_back',v_putback,'units_released',v_released,'cart_closed',v_left = 0,'orders_left',v_left);
end $$;

revoke execute on function wms_remove_order_from_cart(uuid, text, text, text, boolean, uuid) from public, anon;
grant execute on function wms_remove_order_from_cart(uuid, text, text, text, boolean, uuid) to authenticated;
