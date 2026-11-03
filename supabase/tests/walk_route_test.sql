-- Pick route from the floor layout (migration 034). Rolls itself back.
begin;
do $$
declare wh uuid; s uuid; p1 uuid; r record; seqs text; pos record; seq int := 0; L text; i int; k int;
  rowid uuid; boss uuid := gen_random_uuid();
begin
  insert into auth.users(id, email) values (boss, 'wr1@twl.test');
  insert into staff(id, display_name, role, username) values (boss, 'Wes', 'supervisor', 'weswr');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', boss::text, true);
  insert into warehouses(code, name) values ('WRT', 'Walk test') returning id into wh;
  insert into products(sku, name) values ('WR-A', 'Walk A') returning id into p1;
  insert into walk_config(id, warehouse_id, depot_way, depot_x, way_gap) values (1, wh, 3.5, 0, 0.11)
  on conflict (id) do update set warehouse_id = wh;
  -- single rows A (boxes 09-32), C (01-16), T (01-24)
  foreach L in array array['A','C','T'] loop
    seq := seq + 1;
    insert into aisle_rows(warehouse_id, code, sequence) values (wh, L, seq) returning id into rowid;
    insert into shelves(row_id, code, sequence)
    select rowid, lpad(n::text, 2, '0'), n from generate_series(case L when 'A' then 9 else 1 end, case L when 'A' then 32 when 'C' then 16 else 24 end) n;
  end loop;
  -- bay aisles: E F G (A-M, 8 boxes), N O (A-N, 24 boxes), S (SA-SE 3 boxes, SF 15)
  foreach L in array array['E','F','G','N','O','S'] loop
    for i in 0 .. case when L in ('N','O') then 13 when L = 'S' then 5 else 12 end loop
      seq := seq + 1;
      insert into aisle_rows(warehouse_id, code, sequence) values (wh, L || chr(65 + i), seq) returning id into rowid;
      insert into shelves(row_id, code, sequence)
      select rowid, lpad(n::text, 2, '0'), n from generate_series(1, case when L in ('N','O') then 24 when L = 'S' and i < 5 then 3 when L = 'S' then 15 else 8 end) n;
    end loop;
  end loop;
  seq := seq + 1;
  insert into aisle_rows(warehouse_id, code, sequence) values (wh, 'EZA', seq) returning id into rowid;
  insert into shelves(row_id, code, sequence) values (rowid, '99', 99);
  -- the locations used
  insert into bins(warehouse_id, shelf_id, bin_code, code, barcode)
  select wh, sh.id, x.bin, '', '' from (values ('C','02','00'), ('A','30','00'), ('EA','01','01'), ('GA','02','01'), ('FM','08','01'),
                                               ('NA','03','02'), ('OB','01','01'), ('SA','01',''), ('SF','15','01'), ('T','01','02'), ('EZA','99','99'))
         x(r, sh, bin)
    join aisle_rows ar on ar.warehouse_id = wh and ar.code = x.r join shelves sh on sh.row_id = ar.id and sh.code = x.sh;

  -- positions
  select * into pos from wms__walk_pos((select id from bins where warehouse_id = wh and code = 'SA-01'));
  assert pos.way = 3 and pos.x = 1, 'SA at walkway 3, east wall: ' || pos::text;
  select * into pos from wms__walk_pos((select id from bins where warehouse_id = wh and code = 'SF-15-01'));
  assert pos.way = 9, 'SF end at walkway 9: ' || pos::text;
  select * into pos from wms__walk_pos((select id from bins where warehouse_id = wh and code = 'C-02-00'));
  assert pos.way = 1 and pos.x < 0.1, 'C west: ' || pos::text;
  select * into pos from wms__walk_pos((select id from bins where warehouse_id = wh and code = 'FM-08-01'));
  assert pos.way = 3 and pos.x > 0.99, 'FM-08 east end: ' || pos::text;
  select * into pos from wms__walk_pos((select id from bins where warehouse_id = wh and code = 'EZA-99-99'));
  assert pos.way = 2 and pos.x between 0.03 and 0.05, 'EZA above EA: ' || pos::text;
  select * into pos from wms__walk_pos((select id from bins where warehouse_id = wh and code = 'T-01-02'));
  assert pos.way = 9 and pos.x < 0.05, 'T west: ' || pos::text;

  -- a cart: tasks inserted in a random order get re-sequenced on insert
  insert into pick_sessions(warehouse_id, status, method) values (wh, 'draft', 'cluster') returning id into s;
  insert into pick_tasks(session_id, sequence, bin_id, product_id, qty_required)
  select s, row_number() over (order by b.code desc), b.id, p1, 1 from bins b
   where b.warehouse_id = wh and b.code in ('NA-03-02','EA-01-01','A-30-00','FM-08-01','OB-01-01','C-02-00','GA-02-01');
  select string_agg(b.code, ' > ' order by t.sequence) into seqs from pick_tasks t join bins b on b.id = t.bin_id where t.session_id = s;
  -- from the desks: F/G west to east, up the east walkway to A-30, back west along A/C, D/E, then down to N/O and back to the desks
  assert seqs = 'GA-02-01 > FM-08-01 > A-30-00 > C-02-00 > EA-01-01 > NA-03-02 > OB-01-01', seqs;
  assert (select min(sequence) = 1 and max(sequence) = 7 from pick_tasks where session_id = s), 'numbered 1..7';

  -- only west-end stops: every walkway is in and out from the west
  insert into pick_sessions(warehouse_id, status, method) values (wh, 'draft', 'cluster') returning id into s;
  insert into pick_tasks(session_id, sequence, bin_id, product_id, qty_required)
  select s, row_number() over (order by b.code), b.id, p1, 1 from bins b
   where b.warehouse_id = wh and b.code in ('T-01-02','EA-01-01','NA-03-02','C-02-00');
  select string_agg(b.code, ' > ' order by t.sequence) into seqs from pick_tasks t join bins b on b.id = t.bin_id where t.session_id = s;
  assert seqs = 'EA-01-01 > C-02-00 > NA-03-02 > T-01-02', seqs;

  -- east wall: S stops picked while at the east end
  insert into pick_sessions(warehouse_id, status, method) values (wh, 'draft', 'cluster') returning id into s;
  insert into pick_tasks(session_id, sequence, bin_id, product_id, qty_required)
  select s, row_number() over (order by b.code), b.id, p1, 1 from bins b
   where b.warehouse_id = wh and b.code in ('SA-01','GA-02-01','FM-08-01','OB-01-01');
  select string_agg(b.code, ' > ' order by t.sequence) into seqs from pick_tasks t join bins b on b.id = t.bin_id where t.session_id = s;
  assert seqs = 'GA-02-01 > FM-08-01 > SA-01 > OB-01-01', seqs;

  assert jsonb_array_length(wms_walk_preview(array['SA-01','c-02-00'])) = 2, 'preview';
  raise exception 'WALK ROUTE TEST PASSED - all test data rolled back';
end $$;
rollback;
