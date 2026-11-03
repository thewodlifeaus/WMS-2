-- =============================================================================
-- TWL WMS | Migration 022 | Totes can be typed as well as scanned
--   "BIN412", "bin412" or just "412" -> BIN412;  "001" or "1" -> INV001
--   (tote numbers are unique across BIN and INV totes, checked 1 Nov 2026)
-- =============================================================================

create or replace function wms__find_tote(p_text text) returns cart_baskets
language sql stable security definer set search_path = public as $$
  select cb.* from cart_baskets cb
   where cb.is_active
     and (upper(cb.barcode) = upper(trim(p_text))
          or (trim(p_text) ~ '^\D*\d{1,4}$' and cb.barcode ~ '\d+$'
              and substring(cb.barcode from '(\d+)$')::int = substring(trim(p_text) from '(\d+)$')::int
              and (substring(trim(p_text) from '^(\D*)') = ''
                   or upper(cb.barcode) like upper(substring(trim(p_text) from '^(\D*)')) || '%')))
   order by (upper(cb.barcode) = upper(trim(p_text))) desc, cb.barcode limit 1
$$;

create or replace function wms_assign_totes(p_session_id uuid, p_tote_barcodes text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); r record; v_tote cart_baskets; i int := 0; v_out jsonb := '[]';
begin
  if (select status from pick_sessions where id = p_session_id) not in ('draft','assigned','in_progress') then
    return jsonb_build_object('ok',false,'error','SESSION_CLOSED');
  end if;
  for r in select coalesce(pso.slot::text, pso.order_id::text) as grp, min(pso.slot) as slot,
                  array_agg(pso.order_id) as order_ids, string_agg(o.order_number, ', ' order by o.order_number) as orders,
                  min(o.priority) as prio, min(o.ordered_at) as oldest
             from pick_session_orders pso join orders o on o.id = pso.order_id
            where pso.session_id = p_session_id and pso.basket_id is null
            group by 1 order by min(pso.slot) nulls last, min(o.priority), min(o.ordered_at) nulls last, min(o.order_number)
  loop
    i := i + 1;
    exit when i > coalesce(array_length(p_tote_barcodes, 1), 0);
    v_tote := wms__find_tote(p_tote_barcodes[i]);
    if v_tote.id is null then
      return jsonb_build_object('ok',false,'error','UNKNOWN_TOTE','tote',p_tote_barcodes[i],'alarm',true);
    end if;
    if wms__tote_busy(v_tote.id) or exists (select 1 from pick_session_orders where session_id = p_session_id and basket_id = v_tote.id) then
      return jsonb_build_object('ok',false,'error','TOTE_IN_USE','tote',v_tote.barcode,'alarm',true);
    end if;
    update pick_session_orders set basket_id = v_tote.id where session_id = p_session_id and order_id = any(r.order_ids);
    update pick_allocations pa set basket_id = v_tote.id
      from pick_tasks t where t.id = pa.task_id and t.session_id = p_session_id and pa.order_id = any(r.order_ids);
    v_out := v_out || jsonb_build_object('orders', r.orders, 'tote', v_tote.barcode);
  end loop;
  return jsonb_build_object('ok',true,'assigned',v_out,
    'still_need', (select count(distinct coalesce(slot::text, order_id::text)) from pick_session_orders
                    where session_id = p_session_id and basket_id is null));
end $$;

revoke execute on function wms__find_tote(text) from public, anon, authenticated;
grant execute on function wms_assign_totes(uuid, text[]) to authenticated;
