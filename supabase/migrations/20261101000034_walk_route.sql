-- =============================================================================
-- TWL WMS | Migration 034 | Pick route from the real floor layout (Ben, 1 Nov 2026)
--   Packing desks are on the WEST side. Racking runs west-east. Pickers walk 9
--   walkways and pick both sides as they go:
--     1 A + C (receiving area between)   2 D + E   3 F + G   4 H + I   5 J + K
--     6 L + M   7 N + O   8 P + Q   9 R + T (south wall)
--   Bays go west to east (EA ... EM), boxes in a bay go west to east (01 = west),
--   the 2-digit level is ignored for walking. A-10 west ... A-31 east,
--   C-01 / D-01 west, the short C/D aisle ends about half way.
--   Z backstock (EZA-99-99 ...) sits above its bay. Aisle S is on the east wall,
--   SA lines up with walkway 3 (F/G) and the end of SF with walkway 9 (R/T).
--   Floor areas (0-RECEIVE ...) count as the west end of walkway 1.
--
--   Route per cart (shortest walk): walkways are visited north to south. In each
--   walkway with stops the picker either walks right through (and ends at the
--   other end) or goes in and comes back out the same end, whichever makes the
--   whole trip shortest, finishing back at the west side. Stops are ordered by
--   position along the walkway in the walking direction, both sides together.
--   Applied automatically whenever a cart's pick list is created.
--   Layout is data (walk_layout) so it can be adjusted without code.
-- =============================================================================

create table if not exists walk_layout (
  aisle      text primary key,          -- first letter of the location code, or a full floor code
  way_from   real not null,             -- walkway at the west / start end of the aisle
  way_to     real not null,             -- walkway at the east / finish end (differs only for S)
  x_from     real not null,             -- 0 = west wall, 1 = east wall
  x_to       real not null,
  weight_by  text not null default 'bay' check (weight_by in ('bay','box')),
  note       text
);
alter table walk_layout enable row level security;

insert into walk_layout(aisle, way_from, way_to, x_from, x_to, weight_by, note) values
  ('A', 1, 1, 0, 1,   'bay', 'North wall, A-10 west to A-31 east'),
  ('C', 1, 1, 0, 0.5, 'bay', 'Short aisle, faces A across receiving'),
  ('D', 2, 2, 0, 0.5, 'bay', 'Back of C, faces E'),
  ('E', 2, 2, 0, 1, 'bay', null), ('F', 3, 3, 0, 1, 'bay', null),
  ('G', 3, 3, 0, 1, 'bay', null), ('H', 4, 4, 0, 1, 'bay', null),
  ('I', 4, 4, 0, 1, 'bay', null), ('J', 5, 5, 0, 1, 'bay', null),
  ('K', 5, 5, 0, 1, 'bay', null), ('L', 6, 6, 0, 1, 'bay', null),
  ('M', 6, 6, 0, 1, 'bay', null), ('N', 7, 7, 0, 1, 'bay', null),
  ('O', 7, 7, 0, 1, 'bay', null), ('P', 8, 8, 0, 1, 'bay', null),
  ('Q', 8, 8, 0, 1, 'bay', null), ('R', 9, 9, 0, 1, 'bay', null),
  ('T', 9, 9, 0, 1, 'bay', 'South wall'),
  ('S', 3, 9, 1, 1, 'box', 'East wall, SA at F/G down to SF at R/T')
on conflict (aisle) do update set way_from = excluded.way_from, way_to = excluded.way_to,
  x_from = excluded.x_from, x_to = excluded.x_to, weight_by = excluded.weight_by, note = excluded.note;

-- where a location is on the walk: walkway (1 = north) and x (0 = west, 1 = east)
create or replace function wms__walk_pos(p_bin uuid, out way int, out x real)
language plpgsql stable security definer set search_path = public as $$
declare
  b record; L walk_layout; v_letter text; v_bay text; v_bays text[]; v_idx int; v_n int;
  v_lo int; v_hi int; v_before numeric; v_total numeric; f real;
begin
  select bn.code, bn.warehouse_id, bn.shelf_seq, ar.code as row_code, ar.id as row_id
    into b from bins bn left join shelves sh on sh.id = bn.shelf_id left join aisle_rows ar on ar.id = sh.row_id
   where bn.id = p_bin;
  if b.code is null then way := 99; x := 0; return; end if;
  if b.row_code is null then                       -- floor area
    select * into L from walk_layout where aisle = upper(b.code);
    way := coalesce(round(L.way_from)::int, 1); x := coalesce(L.x_from, 0); return;
  end if;
  v_letter := upper(left(b.row_code, 1));
  select * into L from walk_layout where aisle = v_letter;
  if L.aisle is null then way := 99; x := 0; return; end if;   -- not on the map: last

  if length(b.row_code) = 1 then                   -- A-10-00, C-01-00, T-04-02: boxes along one row
    select min(sequence), max(sequence) into v_lo, v_hi from shelves where row_id = b.row_id;
    f := (coalesce(b.shelf_seq, v_lo) - v_lo + 0.5) / greatest(v_hi - v_lo + 1, 1);
  else                                             -- bays: EA, EB ... (EZA = backstock above bay A)
    v_bay := upper(right(b.row_code, 1));
    select array_agg(distinct upper(right(code, 1)) order by upper(right(code, 1))) into v_bays
      from aisle_rows where warehouse_id = b.warehouse_id and upper(code) ~ ('^' || v_letter || '[A-Z]$');
    v_idx := coalesce(array_position(v_bays, v_bay), 1) - 1;
    v_n := greatest(coalesce(array_length(v_bays, 1), 1), 1);
    select min(sh.sequence), max(sh.sequence) into v_lo, v_hi
      from shelves sh join aisle_rows ar on ar.id = sh.row_id
     where ar.warehouse_id = b.warehouse_id and upper(ar.code) = v_letter || v_bay;
    if L.weight_by = 'box' then                    -- bays of different lengths (S): weight by boxes
      select coalesce(sum(cnt) filter (where bay < v_bay), 0), coalesce(sum(cnt), 0) into v_before, v_total
        from (select upper(right(ar.code, 1)) as bay, count(sh.id) as cnt
                from aisle_rows ar join shelves sh on sh.row_id = ar.id
               where ar.warehouse_id = b.warehouse_id and upper(ar.code) ~ ('^' || v_letter || '[A-Z]$')
               group by 1) t;
      f := (v_before + coalesce(b.shelf_seq, v_lo) - coalesce(v_lo, 1) + 0.5) / greatest(v_total, 1);
    elsif length(b.row_code) = 3 and upper(substr(b.row_code, 2, 1)) = 'Z' then
      f := (v_idx + 0.5) / v_n;                    -- backstock above the bay: middle of the bay
    else
      f := (v_idx + (coalesce(b.shelf_seq, v_lo) - coalesce(v_lo, 1) + 0.5) / greatest(coalesce(v_hi - v_lo + 1, 1), 1)) / v_n;
    end if;
  end if;
  f := least(greatest(f, 0), 1);
  way := round(L.way_from + (L.way_to - L.way_from) * f)::int;
  x := L.x_from + (L.x_to - L.x_from) * f;
end $$;

-- re-order a cart's pick list along the shortest walk (see header)
create or replace function wms__route_session(p_session uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  w record; v_ways int[] := '{}'; v_xmin real[] := '{}'; v_xmax real[] := '{}';
  cw real := 0; ce real := 'Infinity'; nw real; ne real; i int; n int;
  ch_w text[] := '{}'; ch_e text[] := '{}'; v_dir int[] := '{}'; v_end text; v_mode text; v_stops jsonb;
begin
  if not exists (select 1 from walk_layout) then return 0; end if;

  select coalesce(jsonb_agg(jsonb_build_object('task_id', t.id, 'way', p.way, 'x', p.x, 'lvl', coalesce(b.bin_seq, 0), 'code', b.code)), '[]')
    into v_stops
    from pick_tasks t join bins b on b.id = t.bin_id cross join lateral wms__walk_pos(t.bin_id) p
   where t.session_id = p_session;
  for w in select s.way, min(s.x) as xmin, max(s.x) as xmax
             from jsonb_to_recordset(v_stops) s(task_id uuid, way int, x real, lvl int, code text) group by s.way order by s.way loop
    v_ways := v_ways || w.way; v_xmin := v_xmin || w.xmin; v_xmax := v_xmax || w.xmax;
  end loop;
  n := coalesce(array_length(v_ways, 1), 0);
  if n = 0 then return 0; end if;

  -- cost to finish walkway i standing at the west (cw) or east (ce) end
  for i in 1 .. n loop
    if cw + 2 * v_xmax[i] <= ce + 1 then nw := cw + 2 * v_xmax[i]; ch_w := ch_w || 'in_out_west'::text;
    else nw := ce + 1; ch_w := ch_w || 'east_to_west'::text; end if;
    if ce + 2 * (1 - v_xmin[i]) <= cw + 1 then ne := ce + 2 * (1 - v_xmin[i]); ch_e := ch_e || 'in_out_east'::text;
    else ne := cw + 1; ch_e := ch_e || 'west_to_east'::text; end if;
    cw := nw; ce := ne;
  end loop;

  -- walk back from the last walkway to find each walkway's direction
  v_end := case when cw <= ce + 1 then 'W' else 'E' end;
  v_dir := array_fill(1, array[n]);
  for i in reverse n .. 1 loop
    v_mode := case when v_end = 'W' then ch_w[i] else ch_e[i] end;
    v_dir[i] := case when v_mode in ('in_out_west', 'west_to_east') then 1 else -1 end;
    v_end := case v_mode when 'in_out_west' then 'W' when 'east_to_west' then 'E'
                         when 'in_out_east' then 'E' else 'W' end;
  end loop;

  -- renumber (negative first: (session, sequence) is unique)
  with ord as (
    select s.task_id, row_number() over (
             order by array_position(v_ways, s.way), s.x * v_dir[array_position(v_ways, s.way)], s.lvl, s.code) as k
      from jsonb_to_recordset(v_stops) s(task_id uuid, way int, x real, lvl int, code text)
  )
  update pick_tasks t set sequence = -ord.k from ord where t.id = ord.task_id;
  update pick_tasks set sequence = -sequence where session_id = p_session and sequence < 0;
  return n;
end $$;

-- run it whenever pick tasks are created for a cart
create or replace function wms__route_new_tasks() returns trigger
language plpgsql security definer set search_path = public as $$
declare s uuid;
begin
  for s in select distinct session_id from new_tasks loop
    perform wms__route_session(s);
  end loop;
  return null;
end $$;

create or replace trigger pick_tasks_walk_route after insert on pick_tasks
  referencing new table as new_tasks for each statement execute function wms__route_new_tasks();

-- preview: the walk for any list of locations (admin / supervisor), for checking the map
create or replace function wms_walk_preview(p_codes text[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('code', b.code, 'way', p.way, 'x', round(p.x::numeric, 3)) order by p.way, p.x), '[]')
            from bins b cross join lateral wms__walk_pos(b.id) p where upper(b.code) = any(select upper(c) from unnest(p_codes) c));
end $$;

-- re-route carts that are built but not started yet
do $$ declare s uuid; begin
  for s in select id from pick_sessions where status in ('draft','assigned') loop perform wms__route_session(s); end loop;
end $$;

revoke execute on function wms__walk_pos(uuid) from public, anon, authenticated;
revoke execute on function wms__route_session(uuid) from public, anon, authenticated;
revoke execute on function wms__route_new_tasks() from public, anon, authenticated;
revoke execute on function wms_walk_preview(text[]) from public, anon;
grant execute on function wms_walk_preview(text[]) to authenticated;
