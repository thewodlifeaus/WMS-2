-- =============================================================================
-- TWL WMS | Migration 021 | Unassign a picker from a cart (cart stays together)
--   Supervisor/admin: takes the cart off its picker. Orders, totes and anything
--   already picked stay on the cart exactly as they are. The cart shows as
--   "Needs a picker" on the tablets and anyone can scan it to carry on.
-- =============================================================================

create or replace function wms_release_cart(p_session_id uuid, p_reason text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); s pick_sessions; v_was text;
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then
    return jsonb_build_object('ok',false,'error','FORBIDDEN');
  end if;
  select * into s from pick_sessions where id = p_session_id for update;
  if s.id is null or s.status not in ('draft','assigned','in_progress') then
    return jsonb_build_object('ok',false,'error','NOT_OPEN');
  end if;
  if s.assigned_to is null then return jsonb_build_object('ok',false,'error','NO_PICKER'); end if;
  select display_name into v_was from staff where id = s.assigned_to;
  -- close the picker's active time, then free the cart
  insert into pick_session_events(session_id, staff_id, event, reason)
  values (s.id, s.assigned_to, 'release', coalesce(nullif(trim(p_reason), ''), 'unassigned by supervisor'));
  update pick_sessions
     set assigned_to = null,
         status = case when status = 'assigned' then 'draft'::session_status else status end,
         paused_at = case when status = 'in_progress' then now() else paused_at end,
         pause_reason = case when status = 'in_progress' then 'unassigned' else pause_reason end
   where id = s.id;
  return jsonb_build_object('ok',true,'cart',(select code from carts where id = s.cart_id),'was',v_was);
end $$;

create or replace function wms_carts_overview() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'sort'), '[]') from (
    select jsonb_build_object(
      'session_id', ps.id, 'cart', coalesce(c.code, '(no cart)'), 'status', ps.status, 'method', ps.method,
      'created_at', ps.created_at, 'started_at', ps.started_at, 'completed_at', ps.completed_at,
      'created_by', (select display_name from staff where id = ps.created_by),
      'picker', (select display_name from staff where id = ps.assigned_to),
      'paused', ps.paused_at is not null, 'pause_reason', ps.pause_reason,
      'orders', (select count(*) from pick_session_orders where session_id = ps.id),
      'totes', (select count(basket_id) from pick_session_orders where session_id = ps.id),
      'units', (select coalesce(sum(qty_required), 0) from pick_tasks where session_id = ps.id),
      'picked', (select coalesce(sum(qty_picked), 0) from pick_tasks where session_id = ps.id),
      'stops', (select count(*) from pick_tasks where session_id = ps.id),
      'stops_done', (select count(*) from pick_tasks where session_id = ps.id and status in ('done','short')),
      'first_bin', (select b.code from pick_tasks t join bins b on b.id = t.bin_id where t.session_id = ps.id order by t.sequence limit 1),
      'sort', case ps.status when 'in_progress' then '1' when 'assigned' then '2' when 'draft' then '3' else '4' end || coalesce(c.code, 'zz')
    ) x
      from pick_sessions ps left join carts c on c.id = ps.cart_id
     where wms_is_staff()
       and (ps.status in ('draft','assigned','in_progress')
            or (ps.status = 'completed' and ps.completed_at >= date_trunc('day', now() at time zone 'Australia/Adelaide') at time zone 'Australia/Adelaide'))
  ) t
$$;


create or replace function wms_cart_detail(p_session_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not wms_is_staff() then null else jsonb_build_object(
    'session', (select jsonb_build_object('id', ps.id, 'cart', c.code, 'status', ps.status, 'route', ps.route,
                  'created_at', ps.created_at, 'started_at', ps.started_at, 'completed_at', ps.completed_at,
                  'created_by', (select display_name from staff where id = ps.created_by),
                  'picker', (select display_name from staff where id = ps.assigned_to),
                  'paused', ps.paused_at is not null, 'pause_reason', ps.pause_reason, 'paused_at', ps.paused_at,
                  'tote_slots', (select count(distinct coalesce(slot::text, order_id::text)) from pick_session_orders where session_id = ps.id))
                  from pick_sessions ps left join carts c on c.id = ps.cart_id where ps.id = p_session_id),
    'orders', (select coalesce(jsonb_agg(jsonb_build_object(
                  'order_number', o.order_number, 'customer', o.customer_name, 'service', o.requested_service,
                  'express', o.priority < 100, 'status', o.status, 'tote', cb.barcode, 'slot', pso.slot, 'is_held', o.is_held,
                  'units', (select sum(qty) from pick_allocations pa join pick_tasks t on t.id = pa.task_id
                             where t.session_id = p_session_id and pa.order_id = o.id),
                  'picked', (select sum(pa.qty_picked) from pick_allocations pa join pick_tasks t on t.id = pa.task_id
                              where t.session_id = p_session_id and pa.order_id = o.id))
                  order by pso.slot nulls last, cb.barcode nulls last, o.priority, o.ordered_at), '[]')
                 from pick_session_orders pso join orders o on o.id = pso.order_id
                 left join cart_baskets cb on cb.id = pso.basket_id where pso.session_id = p_session_id),
    'picks', (select coalesce(jsonb_agg(jsonb_build_object(
                  'seq', t.sequence, 'bin', b.code, 'row', ar.code, 'bin_type', b.location_type,
                  'sku', p.sku, 'name', p.name, 'variant', p.variant_title, 'image_url', p.image_url,
                  'qty', t.qty_required, 'picked', t.qty_picked, 'status', t.status,
                  'split', (select jsonb_agg(jsonb_build_object('order_number', o2.order_number, 'tote', cb2.barcode,
                                             'slot', (select slot from pick_session_orders x where x.session_id = p_session_id and x.order_id = o2.id),
                                             'qty', pa.qty) order by pa.fill_order)
                              from pick_allocations pa join orders o2 on o2.id = pa.order_id
                              left join cart_baskets cb2 on cb2.id = pa.basket_id where pa.task_id = t.id))
                  order by t.sequence), '[]')
                from pick_tasks t join bins b on b.id = t.bin_id
                left join shelves sh on sh.id = b.shelf_id left join aisle_rows ar on ar.id = sh.row_id
                join products p on p.id = t.product_id where t.session_id = p_session_id)
  ) end
$$;


-- picking scans stop once a cart is paused or unassigned
create or replace function wms_pick_scan(
  p_task_id uuid, p_barcode text, p_device_id uuid default null, p_qty int default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := wms__require_staff();
  t pick_tasks; s pick_sessions; v_current uuid;
  v_prod uuid; v_units int; v_left int; a record; v_put jsonb := '[]'::jsonb; v_take int;
  v_session_done boolean; v_warn jsonb := '[]'::jsonb;
begin
  select * into t from pick_tasks where id = p_task_id for update;
  if not found then return jsonb_build_object('ok',false,'error','TASK_NOT_FOUND'); end if;
  select * into s from pick_sessions where id = t.session_id;
  if s.status <> 'in_progress' then return jsonb_build_object('ok',false,'error','SESSION_NOT_STARTED'); end if;
  -- cart paused or taken off this picker (eg unassigned by a supervisor): stop scanning
  if s.paused_at is not null then return jsonb_build_object('ok',false,'error','CART_PAUSED','alarm',true); end if;
  if s.assigned_to is distinct from v_staff and not wms_has_role(array['admin','supervisor']::staff_role[]) then
    return jsonb_build_object('ok',false,'error','NOT_YOUR_CART','alarm',true,
                              'picker',(select display_name from staff where id = s.assigned_to));
  end if;

  -- cannot skip ahead: only the lowest pending task may be scanned
  select id into v_current from pick_tasks where session_id = t.session_id and status = 'pending'
   order by sequence limit 1;
  if v_current is distinct from t.id then
    return jsonb_build_object('ok',false,'error','NOT_CURRENT_TASK','alarm',true,
                              'current', wms_get_current_task(t.session_id));
  end if;

  select pb.product_id, pb.units_per_scan into v_prod, v_units
    from product_barcodes pb where pb.barcode = trim(p_barcode);

  if v_prod is null then
    perform wms__log_scan('pick','unknown_barcode',p_barcode,t.product_id,null,t.session_id,t.id,null,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','UNKNOWN_BARCODE','alarm',true);
  end if;

  -- RULE 1: the scanned item must be the item this order needs from this bin
  if v_prod <> t.product_id then
    perform wms__log_scan('pick','wrong_item',p_barcode,t.product_id,v_prod,t.session_id,t.id,null,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','WRONG_ITEM','alarm',true,
      'expected_sku',(select sku from products where id = t.product_id),
      'scanned_sku',(select sku from products where id = v_prod));
  end if;

  -- RULE 2: quantity entered by the picker (or 1 scan's worth)
  if p_qty is not null and wms__setting(s.warehouse_id, 'pick_enter_quantity') then
    if p_qty <= 0 then return jsonb_build_object('ok',false,'error','BAD_QTY'); end if;
    v_units := p_qty;
  end if;

  if t.qty_picked + v_units > t.qty_required then
    perform wms__log_scan('pick','over_qty',p_barcode,t.product_id,v_prod,t.session_id,t.id,null,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','OVER_QTY','alarm',true,
      'remaining', t.qty_required - t.qty_picked);
  end if;

  -- RULE 3: warn (do not block) if any order this item is going to is on hold
  if wms__setting(s.warehouse_id, 'warn_on_hold') then
    select coalesce(jsonb_agg(distinct jsonb_build_object('type','ORDER_ON_HOLD','order_number',o.order_number,
                                                           'reason',o.hold_reason)), '[]')
      into v_warn
      from pick_allocations pa join orders o on o.id = pa.order_id
     where pa.task_id = t.id and pa.qty_picked < pa.qty and o.is_held;
  end if;

  -- fill allocations in order; tell the picker which basket(s) to drop into
  v_left := v_units;
  for a in select pa.*, cb.position, o.order_number
             from pick_allocations pa join orders o on o.id = pa.order_id
             left join cart_baskets cb on cb.id = pa.basket_id
            where pa.task_id = t.id and pa.qty_picked < pa.qty
            order by pa.fill_order for update of pa
  loop
    exit when v_left = 0;
    v_take := least(v_left, a.qty - a.qty_picked);
    update pick_allocations set qty_picked = qty_picked + v_take where id = a.id;
    update order_lines set qty_picked = qty_picked + v_take where id = a.order_line_id;
    v_put := v_put || jsonb_build_object('basket',a.position,'order_number',a.order_number,'qty',v_take);
    v_left := v_left - v_take;
  end loop;

  perform wms__apply_delta(t.bin_id, t.product_id, -v_units, 'pick', 'pick_task', t.id,
                           v_staff, p_device_id, null, null, v_units);

  update pick_tasks set qty_picked = qty_picked + v_units,
         started_at = coalesce(started_at, now()),
         status = case when qty_picked + v_units >= qty_required then 'done'::task_status else 'pending'::task_status end,
         completed_at = case when qty_picked + v_units >= qty_required then now() end
   where id = t.id;
  perform wms__log_scan('pick','ok',p_barcode,t.product_id,v_prod,t.session_id,t.id,null,v_staff,p_device_id);

  v_session_done := wms__close_session_if_done(t.session_id);
  return jsonb_build_object('ok',true,'qty',v_units,'put_into',v_put,'warnings',v_warn,
    'task_done', t.qty_picked + v_units >= t.qty_required,
    'session_done', v_session_done,
    'next', wms_get_current_task(t.session_id));
end $$;


revoke execute on function wms_release_cart(uuid, text) from public, anon;
grant execute on function wms_release_cart(uuid, text) to authenticated;
