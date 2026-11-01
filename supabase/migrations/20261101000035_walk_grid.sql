-- =============================================================================
-- TWL WMS | Migration 035 | Pick route on the real walkway grid (Ben, 1 Nov 2026)
--   Walkways running north-south (links between the west-east aisles):
--     * Front walkway on the west side, between the aisle ends and the packing
--       desks (desks run from about Aisle E to Aisle K): all aisles.
--     * Cross walkway from FB/FC down to PC/PD (walkways 3 to 8).
--     * Cross walkway from FF/FG down to the south wall (walkways 3 to 9).
--     * East walkway between FM/RL and the S racking on the east wall; A/C and
--       D/E connect to it too: all aisles.
--     * Open floor east of the short C/D aisle joins walkways 1 and 2.
--   A cart starts and finishes at the packing desks (west side, level with
--   walkway 3.5). Each location is a point; distances follow the walkways.
--   Route = shortest loop through the cart's locations: nearest-next, then
--   improved by 2-opt (untangles crossings). Both sides of a walkway are picked
--   together. Layout is data: walk_layout (aisles), walk_links (north-south
--   walkways), walk_config (desk position, walkway spacing).
-- =============================================================================

create table if not exists walk_links (
  id      serial primary key,
  way_lo  real not null,      -- northern-most walkway it reaches (1 = A/C)
  way_hi  real not null,      -- southern-most walkway (9 = R/T)
  x_lo    real not null,      -- where it crosses, 0 = west end .. 1 = east end
  x_hi    real not null,      -- (a range for open floor)
  note    text
);
alter table walk_links enable row level security;
insert into walk_links(way_lo, way_hi, x_lo, x_hi, note)
select * from (values
  (1::real, 9::real, 0::real, 0::real, 'Front walkway (west side, by the packing desks)'),
  (1, 9, 1, 1, 'East walkway (between FM/RL and the S racking)'),
  (3, 8, 0.18, 0.18, 'Cross walkway FB/FC to PC/PD'),
  (3, 9, 0.46, 0.46, 'Cross walkway FF/FG to the south wall'),
  (1, 2, 0.5, 1, 'Open floor east of the short C/D aisle')) v
where not exists (select 1 from walk_links);

create table if not exists walk_config (
  id        int primary key default 1 check (id = 1),
  warehouse_id uuid references warehouses(id),   -- the warehouse this map is for (TWL HQ)
  depot_way real not null,    -- packing desks: level with this walkway (3.5 = between F/G and H/I)
  depot_x   real not null default 0,
  way_gap   real not null     -- distance between neighbouring walkways, as a share of an aisle's length
);
alter table walk_config enable row level security;
insert into walk_config(id, warehouse_id, depot_way, depot_x, way_gap) values (1, wms__main_warehouse(), 3.5, 0, 0.11) on conflict (id) do nothing;

-- position of a location: lane = walkway it is picked from (null on the east
-- wall / floor links), x = 0 west .. 1 east, y = north-south position in walkways
create or replace function wms__walk_xy(p_bin uuid, out lane int, out x real, out y real)
language plpgsql stable security definer set search_path = public as $$
declare
  b record; L walk_layout; v_letter text; v_bay text; v_bays text[]; v_idx int; v_n int;
  v_lo int; v_hi int; v_before numeric; v_total numeric; f real; v_depot real;
begin
  select coalesce(depot_way, 3.5) into v_depot from walk_config where id = 1;
  select bn.code, bn.warehouse_id, bn.shelf_seq, ar.code as row_code, ar.id as row_id
    into b from bins bn left join shelves sh on sh.id = bn.shelf_id left join aisle_rows ar on ar.id = sh.row_id
   where bn.id = p_bin;
  if b.code is null then lane := null; x := 0; y := coalesce(v_depot, 3.5); return; end if;
  if b.row_code is null then                                  -- floor area
    select * into L from walk_layout where aisle = upper(b.code);
    lane := coalesce(round(L.way_from)::int, 1); x := coalesce(L.x_from, 0); y := lane; return;
  end if;
  v_letter := upper(left(b.row_code, 1));
  select * into L from walk_layout where aisle = v_letter;
  if L.aisle is null then lane := null; x := 0; y := coalesce(v_depot, 3.5); return; end if;   -- not on the map: by the desks

  if length(b.row_code) = 1 then
    select min(sequence), max(sequence) into v_lo, v_hi from shelves where row_id = b.row_id;
    f := (coalesce(b.shelf_seq, v_lo) - v_lo + 0.5) / greatest(v_hi - v_lo + 1, 1);
  else
    v_bay := upper(right(b.row_code, 1));
    select array_agg(distinct upper(right(code, 1)) order by upper(right(code, 1))) into v_bays
      from aisle_rows where warehouse_id = b.warehouse_id and upper(code) ~ ('^' || v_letter || '[A-Z]$');
    v_idx := coalesce(array_position(v_bays, v_bay), 1) - 1;
    v_n := greatest(coalesce(array_length(v_bays, 1), 1), 1);
    select min(sh.sequence), max(sh.sequence) into v_lo, v_hi
      from shelves sh join aisle_rows ar on ar.id = sh.row_id
     where ar.warehouse_id = b.warehouse_id and upper(ar.code) = v_letter || v_bay;
    if L.weight_by = 'box' then
      select coalesce(sum(cnt) filter (where bay < v_bay), 0), coalesce(sum(cnt), 0) into v_before, v_total
        from (select upper(right(ar.code, 1)) as bay, count(sh.id) as cnt
                from aisle_rows ar join shelves sh on sh.row_id = ar.id
               where ar.warehouse_id = b.warehouse_id and upper(ar.code) ~ ('^' || v_letter || '[A-Z]$')
               group by 1) t;
      f := (v_before + coalesce(b.shelf_seq, v_lo) - coalesce(v_lo, 1) + 0.5) / greatest(v_total, 1);
    elsif length(b.row_code) = 3 and upper(substr(b.row_code, 2, 1)) = 'Z' then
      f := (v_idx + 0.5) / v_n;
    else
      f := (v_idx + (coalesce(b.shelf_seq, v_lo) - coalesce(v_lo, 1) + 0.5) / greatest(coalesce(v_hi - v_lo + 1, 1), 1)) / v_n;
    end if;
  end if;
  f := least(greatest(f, 0), 1);
  x := L.x_from + (L.x_to - L.x_from) * f;
  y := L.way_from + (L.way_to - L.way_from) * f;
  lane := case when L.way_from = L.way_to then round(L.way_from)::int end;   -- S (east wall) has no lane
end $$;

-- keep the old helper (used by the preview) in step with the new one
create or replace function wms__walk_pos(p_bin uuid, out way int, out x real)
language sql stable security definer set search_path = public as $$
  select coalesce(p.lane, round(p.y)::int), p.x from wms__walk_xy(p_bin) p
$$;

-- shortest loop from the desks through every location on the cart and back
create or replace function wms__route_session(p_session uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  v_bins uuid[]; v_ln int[]; v_x real[]; v_y real[]; n int; m int;
  lk_lo real[]; lk_hi real[]; lk_xl real[]; lk_xh real[]; nl int;
  v_gap real; v_dw real; v_dx real; v_d real[]; i int; j int; k int;
  v_tour int[] := '{}'; v_used boolean[]; v_cur int; v_best real; v_bj int; d real;
  v_improved boolean; v_pass int := 0; a int; b2 int; c int; e int; delta real; tmp int; lo int; hi int;
  xa real; xb real; g real; ylo real; yhi real;
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

-- the walk for a list of locations, in walking order (admin / supervisor)
create or replace function wms_walk_preview(p_codes text[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('code', b.code, 'lane', p.lane, 'x', round(p.x::numeric, 3), 'y', round(p.y::numeric, 2))
            order by p.y, p.x), '[]')
            from bins b cross join lateral wms__walk_xy(b.id) p where upper(b.code) = any(select upper(c) from unnest(p_codes) c));
end $$;

do $$ declare s uuid; begin
  for s in select id from pick_sessions where status in ('draft','assigned') loop perform wms__route_session(s); end loop;
end $$;

revoke execute on function wms__walk_xy(uuid) from public, anon, authenticated;
revoke execute on function wms__walk_pos(uuid) from public, anon, authenticated;
revoke execute on function wms__route_session(uuid) from public, anon, authenticated;
