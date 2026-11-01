-- =============================================================================
-- TWL WMS | Migration 036 | Build carts for the fastest picking (Ben, 1 Nov 2026)
--   Orders and carts > Build carts gets a choice:
--     * Most urgent first (as before): express first, then oldest, carts filled in order.
--     * Fastest picking: each cart starts with the most urgent order left, then
--       keeps adding the order that adds the fewest new places to walk to, so a
--       cart's orders sit close together on the walk. Still whole orders only,
--       one order type per cart, same tote rules.
--   Every cart records its walk (pick_sessions.walk_length, in aisle lengths:
--   1 = one west-to-east aisle) so the two choices can be compared.
--   New RPC wms_build_carts_sorted(..., p_sort 'urgent' | 'route').
-- =============================================================================

alter table pick_sessions add column if not exists walk_length real;

-- the walk cells an order will be picked from: walkway + eighth of an aisle (east wall by walkway)
create or replace function wms__order_cells(p_order uuid) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct case when p.lane is null then 'E' || round(p.y)::text
                                          else p.lane::text || ':' || least(floor(p.x * 8), 7)::text end), '{}')
    from order_lines ol
    join orders o on o.id = ol.order_id
    cross join lateral (
      select bi.bin_id from bin_inventory bi join bins b on b.id = bi.bin_id
       where bi.product_id = ol.product_id and b.warehouse_id = o.warehouse_id and b.is_pickable
         and bi.qty_on_hand - bi.qty_allocated > 0
       order by (b.location_type = 'pick') desc, bi.qty_on_hand - bi.qty_allocated >= ol.qty_ordered - ol.qty_allocated desc,
                b.row_seq, b.shelf_seq, b.bin_seq
       limit 1) best
    cross join lateral wms__walk_xy(best.bin_id) p
   where ol.order_id = p_order and ol.qty_allocated < ol.qty_ordered
$$;

create or replace function wms__route_session(p_session uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_bins uuid[]; v_ln int[]; v_x real[]; v_y real[]; n int; m int;
  lk_lo real[]; lk_hi real[]; lk_xl real[]; lk_xh real[]; nl int;
  v_gap real; v_dw real; v_dx real; v_d real[]; i int; j int; k int;
  v_tour int[] := '{}'; v_used boolean[]; v_cur int; v_best real; v_bj int; d real;
  v_improved boolean; v_pass int := 0; a int; b2 int; c int; e int; delta real; tmp int; lo int; hi int;
  xa real; xb real; g real; ylo real; yhi real; v_len real;
begin
  if not exists (select 1 from walk_layout) then return 0; end if;
  -- only for the warehouse the map describes; other warehouses keep their own order
  if not exists (select 1 from walk_config wc join pick_sessions ps on ps.warehouse_id = wc.warehouse_id
                  where wc.id = 1 and ps.id = p_session) then return 0; end if;
  select depot_way, depot_x, way_gap into v_dw, v_dx, v_gap from walk_config where id = 1;
  v_dw := coalesce(v_dw, 3.5); v_dx := coalesce(v_dx, 0); v_gap := coalesce(v_gap, 0.11);
  select array_agg(way_lo order by id), array_agg(way_hi order by id), array_agg(x_lo order by id), array_agg(x_hi order by id)
    into lk_lo, lk_hi, lk_xl, lk_xh from walk_links;
  nl := coalesce(array_length(lk_lo, 1), 0);

  -- one point per location (point 1 = the packing desks)
  select array_agg(q.bin_id order by q.code), array_agg(q.lane order by q.code), array_agg(q.x order by q.code), array_agg(q.y order by q.code)
    into v_bins, v_ln, v_x, v_y
    from (select distinct pt.bin_id, bn.code, p.lane, p.x, p.y
            from pick_tasks pt join bins bn on bn.id = pt.bin_id cross join lateral wms__walk_xy(pt.bin_id) p
           where pt.session_id = p_session) q;
  n := coalesce(array_length(v_bins, 1), 0);
  if n = 0 then return 0; end if;
  v_bins := array[null::uuid] || v_bins; v_ln := array[null::int] || v_ln; v_x := array[v_dx] || v_x; v_y := array[v_dw] || v_y;
  m := n + 1;

  -- walking distance between every pair of points
  v_d := array_fill(0::real, array[m * m]);
  for i in 1 .. m loop
    for j in i + 1 .. m loop
      xa := least(v_x[i], v_x[j]); xb := greatest(v_x[i], v_x[j]);
      if v_ln[i] is not null and v_ln[i] = v_ln[j] then
        d := xb - xa;                                   -- same walkway: straight along it
      else
        ylo := least(v_y[i], v_y[j]); yhi := greatest(v_y[i], v_y[j]); d := 'Infinity';
        for k in 1 .. nl loop                           -- along to a north-south walkway, across, along
          if lk_lo[k] <= ylo + 0.001 and lk_hi[k] >= yhi - 0.001 then
            g := greatest(lk_xl[k] - xb, xa - lk_xh[k], 0);
            d := least(d, (xb - xa) + 2 * g + (yhi - ylo) * v_gap);
          end if;
        end loop;
        if d = 'Infinity' then d := xa + xb + (yhi - ylo) * v_gap; end if;
      end if;
      v_d[(i - 1) * m + j] := d; v_d[(j - 1) * m + i] := d;
    end loop;
  end loop;

  -- nearest next location, starting at the desks
  v_used := array_fill(false, array[m]); v_cur := 1;
  for i in 1 .. n loop
    v_best := 'Infinity'; v_bj := null;
    for j in 2 .. m loop
      if not v_used[j] and v_d[(v_cur - 1) * m + j] < v_best then v_best := v_d[(v_cur - 1) * m + j]; v_bj := j; end if;
    end loop;
    v_tour := v_tour || v_bj; v_used[v_bj] := true; v_cur := v_bj;
  end loop;

  -- 2-opt: reverse any stretch of the walk that makes it shorter (desks at both ends)
  if n >= 3 and n <= 300 then
    loop
      v_improved := false; v_pass := v_pass + 1;
      for i in 1 .. n - 1 loop
        for k in i + 1 .. n loop
          a := case when i = 1 then 1 else v_tour[i - 1] end; b2 := v_tour[i];
          c := v_tour[k]; e := case when k = n then 1 else v_tour[k + 1] end;
          delta := v_d[(a - 1) * m + c] + v_d[(b2 - 1) * m + e] - v_d[(a - 1) * m + b2] - v_d[(c - 1) * m + e];
          if delta < -0.0001 then
            lo := i; hi := k;
            while lo < hi loop tmp := v_tour[lo]; v_tour[lo] := v_tour[hi]; v_tour[hi] := tmp; lo := lo + 1; hi := hi - 1; end loop;
            v_improved := true;
          end if;
        end loop;
      end loop;
      exit when not v_improved or v_pass >= 40;
    end loop;
  end if;

  -- renumber the cart's stops in walking order (negative first: (session, sequence) is unique)
  -- total walk (desks -> stops -> desks), in aisle lengths
  v_len := v_d[v_tour[1]] + v_d[(v_tour[n] - 1) * m + 1];
  for i in 1 .. n - 1 loop v_len := v_len + v_d[(v_tour[i] - 1) * m + v_tour[i + 1]]; end loop;
  update pick_sessions set walk_length = round(v_len::numeric, 2) where id = p_session;

  with walk as (select v_bins[node] as bin_id, ord from unnest(v_tour) with ordinality u(node, ord)),
  ranked as (
    select pt.id, row_number() over (order by w.ord, bn.bin_seq, pt.product_id) as k
      from pick_tasks pt join walk w on w.bin_id = pt.bin_id join bins bn on bn.id = pt.bin_id
     where pt.session_id = p_session
  )
  update pick_tasks t set sequence = -ranked.k from ranked where t.id = ranked.id;
  update pick_tasks set sequence = -sequence where session_id = p_session and sequence < 0;
  return n;
end $$;


create or replace function wms_build_carts(
  p_order_ids       uuid[],
  p_totes_per_cart  int default 12,      -- totes on each cart
  p_pieces_per_tote int default null,    -- null = one order per tote; a number = share totes up to this many pieces
  p_cart_ids        uuid[] default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff();
        v_ids uuid[]; v_units int[]; v_skipped jsonb; v_carts uuid[]; v_cart carts; v_cid uuid;
        v_used boolean[]; v_slot_units int[]; v_slot_of int[]; v_slots int; v_chunk uuid[]; v_chunk_slot int[];
        i int; j int; v_res jsonb; v_made jsonb := '[]'; v_failed jsonb := '[]'; v_left uuid[];
        v_mode text := case when p_pieces_per_tote is null then 'orders' else 'pieces' end;
        v_cap int; v_fixed int; v_sid uuid;
        v_sort text := coalesce(nullif(current_setting('wms.cart_sort', true), ''), 'urgent');
        v_cells text[]; v_cart_cells text[]; v_bi int; v_bcost bigint; v_cost bigint; v_bj int; k int;
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then
    raise exception 'FORBIDDEN: only admins and supervisors can build carts' using errcode = '42501';
  end if;
  if coalesce(p_totes_per_cart, 0) not between 1 and 48 then raise exception 'TOTES_PER_CART_1_TO_48'; end if;
  if p_pieces_per_tote is not null and p_pieces_per_tote < 1 then raise exception 'PIECES_PER_TOTE_AT_LEAST_1'; end if;

  -- ready orders only, express first then oldest
  select array_agg(o.id order by o.priority, o.ordered_at nulls last, o.order_number),
         array_agg(wms__order_units(o.id) order by o.priority, o.ordered_at nulls last, o.order_number)
    into v_ids, v_units
    from orders o where o.id = any(p_order_ids) and wms__order_ready(o) = 'ready';
  select coalesce(jsonb_agg(jsonb_build_object('order_number', o.order_number, 'reason', wms__order_ready(o))), '[]')
    into v_skipped from orders o where o.id = any(p_order_ids) and wms__order_ready(o) <> 'ready';
  if v_ids is null then return jsonb_build_object('ok', false, 'error', 'NO_READY_ORDERS', 'skipped', v_skipped); end if;

  select array_agg(c.id order by c.code like 'CART%' desc, c.code) into v_carts from carts c
   where c.is_active and (p_cart_ids is null or c.id = any(p_cart_ids))
     and wms__cart_free(c.id);
  if v_carts is null then return jsonb_build_object('ok', false, 'error', 'NO_FREE_CARTS'); end if;

  v_used := array_fill(false, array[array_length(v_ids, 1)]);
  -- fastest-picking mode: where each order will be picked from, as walk cells
  if v_sort = 'route' then
    select array_agg(array_to_string(wms__order_cells(x), ' ') order by ix) into v_cells
      from unnest(v_ids) with ordinality u(x, ix);
  end if;

  foreach v_cid in array v_carts loop
    exit when not (false = any(v_used));
    select * into v_cart from carts where id = v_cid;
    v_slots := 0; v_slot_units := '{}'; v_chunk := '{}'; v_chunk_slot := '{}';
    -- carts with totes fixed to them hold at most that many totes
    select count(*) into v_fixed from cart_baskets where cart_id = v_cart.id and is_active;
    v_cap := case when v_fixed > 0 then least(p_totes_per_cart, v_fixed) else p_totes_per_cart end;

    if v_sort = 'route' then
      -- fastest picking: start with the most urgent order left, then keep adding the order
      -- that adds the fewest new places to walk to (ties: most urgent). Whole orders only.
      v_cart_cells := '{}';
      loop
        v_bi := null; v_bcost := null; v_bj := null;
        for i in 1 .. array_length(v_ids, 1) loop
          continue when v_used[i];
          j := null;
          if v_mode = 'orders' then
            if v_slots < v_cap then j := v_slots + 1; end if;
          else
            if v_units[i] <= p_pieces_per_tote then
              for k in 1 .. v_slots loop
                if v_slot_units[k] + v_units[i] <= p_pieces_per_tote then j := k; exit; end if;
              end loop;
            end if;
            if j is null and v_slots < v_cap then j := v_slots + 1; end if;
          end if;
          continue when j is null;
          v_cost := case when array_length(v_chunk, 1) is null then i
                         else (select count(*) from unnest(string_to_array(coalesce(v_cells[i], ''), ' ')) c
                                where c <> '' and not (c = any(v_cart_cells))) * 100000 + i end;
          if v_bcost is null or v_cost < v_bcost then v_bcost := v_cost; v_bi := i; v_bj := j; end if;
        end loop;
        exit when v_bi is null;
        if v_bj > v_slots then v_slots := v_slots + 1; v_slot_units := v_slot_units || 0; end if;
        v_slot_units[v_bj] := v_slot_units[v_bj] + v_units[v_bi];
        v_chunk := v_chunk || v_ids[v_bi]; v_chunk_slot := v_chunk_slot || v_bj; v_used[v_bi] := true;
        v_cart_cells := v_cart_cells || string_to_array(coalesce(v_cells[v_bi], ''), ' ');
      end loop;
    end if;

    -- fill this cart: walk the queue in priority order; an order goes in only if it fits whole
    for i in 1 .. array_length(v_ids, 1) loop
      exit when v_sort = 'route';
      continue when v_used[i];
      if v_mode = 'orders' then
        exit when v_slots >= v_cap;
        v_slots := v_slots + 1; v_slot_units := v_slot_units || v_units[i];
        v_chunk := v_chunk || v_ids[i]; v_chunk_slot := v_chunk_slot || v_slots; v_used[i] := true;
      else
        j := null;
        if v_units[i] <= p_pieces_per_tote then   -- first tote with room for the whole order
          for k in 1 .. v_slots loop
            if v_slot_units[k] + v_units[i] <= p_pieces_per_tote then j := k; exit; end if;
          end loop;
        end if;
        if j is null and v_slots < v_cap then   -- open a new tote (big orders always get their own)
          v_slots := v_slots + 1; v_slot_units := v_slot_units || 0; j := v_slots;
        end if;
        continue when j is null;                    -- does not fit on this cart: try the next cart
        v_slot_units[j] := v_slot_units[j] + v_units[i];
        v_chunk := v_chunk || v_ids[i]; v_chunk_slot := v_chunk_slot || j; v_used[i] := true;
      end if;
    end loop;
    continue when array_length(v_chunk, 1) is null;

    begin
      v_res := wms_create_pick_session('cluster', v_chunk, v_cart.id);
      v_sid := (v_res->>'session_id')::uuid;
      update pick_session_orders pso set slot = s.slot, basket_id = null
        from unnest(v_chunk, v_chunk_slot) as s(order_id, slot)
       where pso.session_id = v_sid and pso.order_id = s.order_id;
      -- fixed totes: tote slot N = the Nth tote on the cart (eg CART02 slot 1 = BIN026)
      perform wms__fill_fixed_totes(v_sid);
      v_made := v_made || jsonb_build_object('cart', v_cart.code, 'session_id', v_res->'session_id',
                  'orders', v_res->'orders', 'stops', v_res->'tasks', 'shortages', v_res->'shortages',
                  'totes', (select count(distinct slot) from pick_session_orders where session_id = (v_res->>'session_id')::uuid),
                  'fixed_totes', v_fixed > 0,
                  'walk', (select walk_length from pick_sessions where id = v_sid),
                  'units', (select coalesce(sum(qty_required), 0) from pick_tasks where session_id = (v_res->>'session_id')::uuid));
    exception when others then
      v_failed := v_failed || jsonb_build_object('cart', v_cart.code, 'error', sqlerrm,
                    'orders', (select jsonb_agg(order_number) from orders where id = any(v_chunk)));
    end;
  end loop;

  select array_agg(v_ids[ix]) into v_left from generate_subscripts(v_ids, 1) ix where not v_used[ix];
  return jsonb_build_object('ok', jsonb_array_length(v_made) > 0, 'mode', v_mode, 'sort', v_sort, 'carts', v_made, 'failed', v_failed,
    'skipped', v_skipped, 'left_over', coalesce(array_length(v_left, 1), 0),
    'left_over_orders', (select jsonb_agg(order_number) from orders where id = any(v_left)));
end $$;


-- build carts choosing the sort ('urgent' = most urgent first, 'route' = fastest picking)
create or replace function wms_build_carts_sorted(
  p_order_ids uuid[], p_totes_per_cart int default 12, p_pieces_per_tote int default null,
  p_cart_ids uuid[] default null, p_sort text default 'urgent'
) returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(p_sort, 'urgent') not in ('urgent', 'route') then raise exception 'BAD_SORT'; end if;
  perform set_config('wms.cart_sort', coalesce(p_sort, 'urgent'), true);
  return wms_build_carts(p_order_ids, p_totes_per_cart, p_pieces_per_tote, p_cart_ids);
end $$;

-- record the walk for carts already built
do $$ declare s uuid; begin
  for s in select id from pick_sessions where status in ('draft','assigned') and walk_length is null loop perform wms__route_session(s); end loop;
end $$;

revoke execute on function wms__order_cells(uuid) from public, anon, authenticated;
revoke execute on function wms_build_carts_sorted(uuid[], int, int, uuid[], text) from public, anon;
grant execute on function wms_build_carts_sorted(uuid[], int, int, uuid[], text) to authenticated;
