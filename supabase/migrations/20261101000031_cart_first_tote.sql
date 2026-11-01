-- =============================================================================
-- TWL WMS | Migration 031 | Pick a cart from a list, confirm with its first tote
--   Tablet: pickers choose a cart from the list, then scan the FIRST tote on it
--   (CART01 = BIN001, CART02 = BIN026, CART03 = BIN051 ...) to prove they are at
--   the right cart. Any tote fixed to a cart now identifies that cart, so the
--   first tote also works when starting or finishing a cart ("scan the cart").
-- =============================================================================

create or replace function wms__find_cart(p_text text) returns carts
language sql stable security definer set search_path = public as $$
  select c.* from carts c
   where c.is_active and (upper(c.barcode) = upper(trim(p_text)) or upper(c.code) = upper(trim(p_text))
      -- a tote fixed to the cart (eg BIN026 -> CART02)
      or exists (select 1 from cart_baskets cb where cb.cart_id = c.id and cb.is_active and upper(cb.barcode) = upper(trim(p_text)))
      or (trim(p_text) ~ '^\D*\d{1,3}$' and c.code ~ '\d+$'
          and substring(c.code from '(\d+)$')::int = substring(trim(p_text) from '(\d+)$')::int
          -- "INV3" only matches INV carts; a bare number ("3") prefers CART carts
          and (substring(trim(p_text) from '^(\D*)') = ''
               or upper(c.code) like upper(substring(trim(p_text) from '^(\D*)')) || '%')))
   order by (upper(c.barcode) = upper(trim(p_text)) or exists (select 1 from cart_baskets cb where cb.cart_id = c.id and upper(cb.barcode) = upper(trim(p_text)))) desc,
            (c.code like 'CART%') desc, c.code limit 1
$$;

-- tablet cart list (023 + first tote on the cart)
create or replace function wms_pick_carts_available() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not wms_is_staff() then '[]'::jsonb else coalesce(jsonb_agg(x order by x->>'sort'), '[]') end from (
    select jsonb_build_object(
      'session_id', ps.id, 'cart', c.code, 'cart_barcode', c.barcode,
      'first_tote', (select cb.barcode from cart_baskets cb where cb.cart_id = c.id and cb.is_active order by cb.position limit 1),
      'state', case when ps.status = 'in_progress' and ps.paused_at is null then 'picking'
                    when ps.paused_at is not null and ps.assigned_to is null then 'released'
                    when ps.paused_at is not null then 'paused' else 'not_started' end,
      'mine', ps.assigned_to = auth.uid(),
      'picker', (select display_name from staff where id = ps.assigned_to),
      'pause_reason', ps.pause_reason,
      'group', wms__session_groups(ps.id),
      'orders', (select count(*) from pick_session_orders where session_id = ps.id),
      'units', (select coalesce(sum(qty_required), 0) from pick_tasks where session_id = ps.id),
      'picked', (select coalesce(sum(qty_picked), 0) from pick_tasks where session_id = ps.id),
      'stops', (select count(*) from pick_tasks where session_id = ps.id),
      'express', exists (select 1 from pick_session_orders pso join orders o on o.id = pso.order_id
                          where pso.session_id = ps.id and o.priority < 100),
      'first_bin', (select b.code from pick_tasks t join bins b on b.id = t.bin_id
                     where t.session_id = ps.id and t.status = 'pending' order by t.sequence limit 1),
      'created_at', ps.created_at,
      'sort', case when ps.assigned_to = auth.uid() then '0' when ps.paused_at is not null and ps.assigned_to is null then '1'
                   when ps.status in ('draft','assigned') then '2' else '3' end || to_char(ps.created_at, 'YYYYMMDDHH24MISS')
    ) x
      from pick_sessions ps join carts c on c.id = ps.cart_id
     where ps.status in ('draft','assigned','in_progress')
  ) t
$$;
