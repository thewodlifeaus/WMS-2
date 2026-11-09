-- =============================================================================
-- 041  Kits (bundles / multipacks), set up like SkuVault
--
-- A kit is a product SKU (eg TWLPOWERTAPE3PAK) that holds no stock itself.
-- It has lines; each line has a name, a quantity and one or more SKUs that can
-- fill it (the first is the main SKU, the rest are substitutes).
--
-- When an order comes in with a kit SKU, the kit line is swapped for its parts
-- (one order line per kit line) before it is saved. Parts are normal order
-- lines, so stock check, carts, picking, routing and the pack desk all work
-- unchanged. Each part line remembers the kit it came from (kit_sku etc.).
--
-- Editing a kit never removes rows: each save writes a new version of the
-- lines and kits.version points at the current one.
-- =============================================================================

create table if not exists kits (
  product_id    uuid primary key references products(id),
  code          text,                               -- SkuVault kit code / barcode
  title         text,
  is_active     boolean not null default true,
  qty_sync_off  boolean not null default false,     -- SkuVault "Disable Quantity Sync"
  source        text not null default 'wms' check (source in ('skuvault','wms')),
  version       int  not null default 1,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    uuid references staff(id)
);

create table if not exists kit_lines (
  id        uuid primary key default gen_random_uuid(),
  kit_id    uuid not null references kits(product_id),
  version   int  not null,
  line_no   int  not null,
  name      text not null,
  qty       int  not null check (qty > 0),
  unique (kit_id, version, line_no)
);

create table if not exists kit_line_skus (
  line_id    uuid not null references kit_lines(id),
  product_id uuid not null references products(id),
  priority   int  not null,                          -- 1 = main SKU, 2+ = substitutes in order
  primary key (line_id, product_id)
);
create index if not exists kit_line_skus_product_idx on kit_line_skus(product_id);

alter table kits          enable row level security;
alter table kit_lines     enable row level security;
alter table kit_line_skus enable row level security;

-- part lines remember which kit they came from
alter table order_lines add column if not exists kit_product_id uuid references products(id);
alter table order_lines add column if not exists kit_sku   text;
alter table order_lines add column if not exists kit_title text;
alter table order_lines add column if not exists kit_qty   int;     -- how many kits were ordered
alter table order_lines add column if not exists kit_line  text;    -- kit line name
create index if not exists order_lines_kit_idx on order_lines(kit_product_id) where kit_product_id is not null;

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
-- free (pickable, not reserved) units of a product in a warehouse
create or replace function wms__free_units(p_product uuid, p_wh uuid) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(sum(greatest(bi.qty_on_hand - bi.qty_allocated, 0)), 0)::int
    from bin_inventory bi join bins b on b.id = bi.bin_id
   where bi.product_id = p_product and b.is_pickable and (p_wh is null or b.warehouse_id = p_wh)
$$;

-- current lines of an active kit: line_id, line_no, name, qty
create or replace function wms__kit_current_lines(p_kit uuid)
returns table(line_id uuid, line_no int, name text, qty int)
language sql stable security definer set search_path = public as $$
  select l.id, l.line_no, l.name, l.qty
    from kits k join kit_lines l on l.kit_id = k.product_id and l.version = k.version
   where k.product_id = p_kit and k.is_active
   order by l.line_no
$$;

-- which SKU fills a kit line: the main SKU if it has enough free stock, else the
-- first substitute that does, else the substitute with the most free stock, else the main SKU
create or replace function wms__kit_line_pick(p_line uuid, p_need int, p_wh uuid) returns uuid
language sql stable security definer set search_path = public as $$
  with s as (select ls.product_id, ls.priority, wms__free_units(ls.product_id, p_wh) as free
               from kit_line_skus ls where ls.line_id = p_line)
  select coalesce(
    (select product_id from s where free >= p_need order by priority limit 1),
    (select product_id from s where free > 0 order by free desc, priority limit 1),
    (select product_id from s order by priority limit 1))
$$;

-- how many kits can be made from free stock (substitutes on a line add together)
create or replace function wms__kit_available(p_kit uuid, p_wh uuid default null) returns int
language sql stable security definer set search_path = public as $$
  select min(t.can)::int from (
    select floor(coalesce(sum(wms__free_units(ls.product_id, p_wh)), 0) / l.qty) as can
      from wms__kit_current_lines(p_kit) l left join kit_line_skus ls on ls.line_id = l.line_id
     group by l.line_id, l.qty) t
$$;

-- ---------------------------------------------------------------------------
-- Order lines: a kit line is replaced by its part lines when it is inserted
-- ---------------------------------------------------------------------------
create or replace function wms__order_line_kit() returns trigger
language plpgsql security definer set search_path = public as $$
declare k kits; l record; v_wh uuid; v_prod uuid; v_sku text; v_name text;
begin
  if new.product_id is null or pg_trigger_depth() > 3 then return new; end if;
  select * into k from kits where product_id = new.product_id and is_active;
  if k.product_id is null or not exists (select 1 from wms__kit_current_lines(k.product_id)) then return new; end if;

  select warehouse_id into v_wh from orders where id = new.order_id;
  for l in select * from wms__kit_current_lines(k.product_id) loop
    v_prod := wms__kit_line_pick(l.line_id, new.qty_ordered * l.qty, v_wh);
    select sku, name into v_sku, v_name from products where id = v_prod;
    insert into order_lines(order_id, product_id, sku, name, qty_ordered, external_line_id,
                            kit_product_id, kit_sku, kit_title, kit_qty, kit_line)
    values (new.order_id, v_prod, v_sku, v_name, new.qty_ordered * l.qty, new.external_line_id,
            coalesce(new.kit_product_id, k.product_id), coalesce(new.kit_sku, new.sku),
            coalesce(new.kit_title, k.title, new.name), coalesce(new.kit_qty, new.qty_ordered), l.name);
  end loop;
  return null;   -- the kit line itself is not saved, its parts are
end $$;

do $$ begin
  if not exists (select 1 from pg_trigger where tgname = 'order_lines_kit' and tgrelid = 'public.order_lines'::regclass) then
    create trigger order_lines_kit before insert on order_lines for each row execute function wms__order_line_kit();
  end if;
end $$;

-- Orders already in the queue (not on a cart yet): match unknown SKUs that are
-- now known, swap kit lines for their parts, and release "Unknown SKU" holds.
create or replace function wms__kit_expand_queue() returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; l record; v_first boolean; v_prod uuid; v_sku text; v_name text;
        v_matched int; v_expanded int := 0; v_released int;
begin
  update order_lines ol set product_id = p.id
    from products p, orders o
   where ol.product_id is null and p.sku = ol.sku and o.id = ol.order_id
     and o.status in ('awaiting_pick','on_hold');
  get diagnostics v_matched = row_count;

  for r in select ol.*, o.warehouse_id, k.title as k_title
             from order_lines ol join orders o on o.id = ol.order_id
             join kits k on k.product_id = ol.product_id and k.is_active
            where o.status in ('awaiting_pick','on_hold') and ol.qty_allocated = 0 and ol.qty_picked = 0
              and ol.kit_product_id is null
              and exists (select 1 from wms__kit_current_lines(k.product_id)) loop
    v_first := true;
    for l in select * from wms__kit_current_lines(r.product_id) loop
      v_prod := wms__kit_line_pick(l.line_id, r.qty_ordered * l.qty, r.warehouse_id);
      select sku, name into v_sku, v_name from products where id = v_prod;
      if v_first then
        update order_lines set product_id = v_prod, sku = v_sku, name = v_name, qty_ordered = r.qty_ordered * l.qty,
               kit_product_id = r.product_id, kit_sku = r.sku, kit_title = coalesce(r.k_title, r.name),
               kit_qty = r.qty_ordered, kit_line = l.name
         where id = r.id;
        v_first := false;
      else
        insert into order_lines(order_id, product_id, sku, name, qty_ordered, external_line_id,
                                kit_product_id, kit_sku, kit_title, kit_qty, kit_line)
        values (r.order_id, v_prod, v_sku, v_name, r.qty_ordered * l.qty, r.external_line_id,
                r.product_id, r.sku, coalesce(r.k_title, r.name), r.qty_ordered, l.name);
      end if;
    end loop;
    v_expanded := v_expanded + 1;
  end loop;

  update orders o set status = 'awaiting_pick', is_held = false, hold_reason = null
   where o.status = 'on_hold' and o.hold_reason = 'Unknown SKU - add product to WMS'
     and not exists (select 1 from order_lines ol where ol.order_id = o.id and ol.product_id is null);
  get diagnostics v_released = row_count;

  return jsonb_build_object('lines_matched', v_matched, 'kit_lines_split', v_expanded, 'holds_released', v_released);
end $$;

-- ---------------------------------------------------------------------------
-- Import from the SkuVault "Kit Details" export
-- rows = [[kit_sku, kit_code, kit_title, line_name, qty, product_sku, disable_qty_sync], ...]
-- Rows with the same kit + line name are one line; extra SKUs are substitutes.
-- Kits created or edited in the WMS (source 'wms') are left alone.
-- ---------------------------------------------------------------------------
create or replace function wms_import_kits(p_rows jsonb, p_token text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_new_products int; v_kits int; v_skipped int; v_missing jsonb;
begin
  if not wms__import_allowed(p_token) then raise exception 'FORBIDDEN'; end if;

  -- part SKUs not in the WMS (their rows are skipped)
  select coalesce(jsonb_agg(distinct trim(x->>5)), '[]') into v_missing
    from jsonb_array_elements(p_rows) x
   where coalesce(trim(x->>5), '') <> '' and not exists (select 1 from products p where p.sku = trim(x->>5));

  -- kit SKUs become products if the WMS doesn't know them yet (Shopify sync fills in the rest later)
  insert into products(sku, name, is_active)
  select distinct on (trim(x->>0)) trim(x->>0), coalesce(nullif(trim(x->>2), ''), trim(x->>0)), true
    from jsonb_array_elements(p_rows) x where coalesce(trim(x->>0), '') <> ''
   order by trim(x->>0)
  on conflict (sku) do nothing;
  get diagnostics v_new_products = row_count;

  select count(distinct p.id) into v_skipped
    from jsonb_array_elements(p_rows) x join products p on p.sku = trim(x->>0) join kits k on k.product_id = p.id and k.source = 'wms';

  with src as (
    select ord::int as rn, kp.id as kit_id, nullif(trim(x->>1), '') as code, nullif(trim(x->>2), '') as title,
           coalesce(nullif(trim(x->>3), ''), 'Line') as line, greatest(coalesce(nullif(x->>4, '')::numeric, 1), 1)::int as qty,
           pp.id as part_id, coalesce(x->>6, '') ilike 'enabled' as sync_off
      from jsonb_array_elements(p_rows) with ordinality as t(x, ord)
      join products kp on kp.sku = trim(x->>0)
      join products pp on pp.sku = trim(x->>5)
     where kp.id <> pp.id
       and not exists (select 1 from kits k where k.product_id = kp.id and k.source = 'wms')
  ), kk as (
    insert into kits(product_id, code, title, qty_sync_off, source, version)
    select kit_id, min(code), min(title), bool_or(sync_off), 'skuvault', 1 from src group by kit_id
    on conflict (product_id) do update set code = excluded.code, title = excluded.title,
           qty_sync_off = excluded.qty_sync_off, is_active = true, version = kits.version + 1, updated_at = now()
    returning product_id, version
  ), ln as (
    select s.kit_id, s.line, min(s.rn) as first_rn, max(s.qty) as qty from src s group by s.kit_id, s.line
  ), ins as (
    insert into kit_lines(kit_id, version, line_no, name, qty)
    select ln.kit_id, kk.version, row_number() over (partition by ln.kit_id order by ln.first_rn), ln.line, ln.qty
      from ln join kk on kk.product_id = ln.kit_id
    returning id, kit_id, name
  ), sk as (
    insert into kit_line_skus(line_id, product_id, priority)
    select ins.id, s.part_id, row_number() over (partition by ins.id order by min(s.rn))
      from ins join src s on s.kit_id = ins.kit_id and s.line = ins.name
     group by ins.id, s.part_id
    on conflict do nothing
    returning 1
  )
  select (select count(*) from kk) into v_kits from (select count(*) from sk) z;

  return jsonb_build_object('ok', true, 'kits', v_kits, 'skipped_edited_in_wms', v_skipped,
                            'new_kit_products', v_new_products,
                            'missing_part_skus', jsonb_array_length(v_missing),
                            'missing_sample', (select jsonb_agg(e) from (select e from jsonb_array_elements(v_missing) e limit 25) t));
end $$;

-- admin: split kit lines on orders already waiting (after an import)
create or replace function wms_kits_fix_queue() returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return jsonb_build_object('ok', true) || wms__kit_expand_queue();
end $$;

-- ---------------------------------------------------------------------------
-- Kits screen (admin + supervisor)
-- ---------------------------------------------------------------------------
create or replace function wms__kit_json(p_kit uuid, p_wh uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'kit_sku', p.sku, 'product_name', p.name, 'title', coalesce(k.title, p.name), 'code', k.code,
    'active', k.is_active, 'source', k.source, 'version', k.version,
    'updated_at', k.updated_at, 'updated_by', (select display_name from staff where id = k.updated_by),
    'available', case when k.is_active then wms__kit_available(k.product_id, p_wh) end,
    'kit_stock', (select coalesce(sum(qty_on_hand), 0) from bin_inventory where product_id = k.product_id),
    'orders_30d', (select count(distinct ol.order_id) from order_lines ol join orders o on o.id = ol.order_id
                    where ol.kit_product_id = k.product_id and o.ordered_at > now() - interval '30 days'),
    'lines', (select coalesce(jsonb_agg(jsonb_build_object('line_no', l.line_no, 'name', l.name, 'qty', l.qty,
                'skus', (select jsonb_agg(jsonb_build_object('sku', sp.sku, 'name', sp.name, 'variant', sp.variant_title,
                                                             'free', wms__free_units(sp.id, p_wh)) order by ls.priority)
                           from kit_line_skus ls join products sp on sp.id = ls.product_id where ls.line_id = l.id))
                order by l.line_no), '[]')
                from kit_lines l where l.kit_id = k.product_id and l.version = k.version))
  from kits k join products p on p.id = k.product_id where k.product_id = p_kit
$$;

create or replace function wms_kits(p_search text default null, p_show text default 'active',
                                    p_limit int default 100, p_offset int default 0) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_wh uuid := wms__main_warehouse(); v_q text := nullif(trim(coalesce(p_search, '')), '');
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  return (
    with f as (
      select k.product_id, p.sku
        from kits k join products p on p.id = k.product_id
       where (p_show = 'all' or (p_show = 'off') = not k.is_active)
         and (v_q is null or p.sku ilike '%' || v_q || '%' or coalesce(k.title, p.name) ilike '%' || v_q || '%'
              or k.code = v_q
              or exists (select 1 from kit_lines l join kit_line_skus ls on ls.line_id = l.id join products sp on sp.id = ls.product_id
                          where l.kit_id = k.product_id and l.version = k.version and sp.sku ilike '%' || v_q || '%'))
    )
    select jsonb_build_object(
      'total', (select count(*) from f),
      'counts', jsonb_build_object('active', (select count(*) from kits where is_active), 'off', (select count(*) from kits where not is_active)),
      'kits', (select coalesce(jsonb_agg(wms__kit_json(x.product_id, v_wh) order by x.sku), '[]')
                 from (select * from f order by sku limit least(greatest(p_limit, 1), 500) offset greatest(p_offset, 0)) x))
  );
end $$;

create or replace function wms_kit(p_kit_sku text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_kit uuid;
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  select k.product_id into v_kit from kits k join products p on p.id = k.product_id where p.sku = trim(p_kit_sku);
  if v_kit is null then return jsonb_build_object('ok', false, 'error', 'NOT_A_KIT'); end if;
  return jsonb_build_object('ok', true, 'kit', wms__kit_json(v_kit, wms__main_warehouse()));
end $$;

-- product finder for the kit editor (SKU, name or barcode)
create or replace function wms_kit_find_products(p_q text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_q text := trim(coalesce(p_q, '')); v_wh uuid := wms__main_warehouse();
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then raise exception 'FORBIDDEN' using errcode = '42501'; end if;
  if length(v_q) < 2 then return '[]'::jsonb; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('sku', x.sku, 'name', x.name, 'variant', x.variant_title,
                                    'free', wms__free_units(x.id, v_wh), 'is_kit', x.is_kit) order by x.rank, x.sku), '[]')
    from (select p.id, p.sku, p.name, p.variant_title, exists (select 1 from kits k where k.product_id = p.id) as is_kit,
                 case when p.sku ilike v_q then 0 when p.sku ilike v_q || '%' then 1 else 2 end as rank
            from products p
           where p.sku ilike '%' || v_q || '%' or p.name ilike '%' || v_q || '%'
              or p.id in (select product_id from product_barcodes where barcode = v_q)
           order by rank, p.is_active desc, p.sku limit 25) x);
end $$;

-- Create or change a kit.
-- p_lines = [{name, qty, skus: [main, substitute, ...]}]
-- p_confirmed false = check only (returns what would happen, nothing saved)
create or replace function wms_kit_save(p_kit_sku text, p_title text, p_code text, p_lines jsonb,
                                        p_new_product_name text default null, p_confirmed boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); v_sku text := trim(coalesce(p_kit_sku, '')); v_kit uuid; k kits;
        v_errors jsonb := '[]'; v_warn jsonb := '[]'; ln jsonb; s jsonb; v_no int := 0; v_prio int; v_line uuid;
        v_prod uuid; v_ver int; v_new_product boolean := false; v_stock int; v_seen text[]; v_orders int;
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then return jsonb_build_object('ok',false,'error','FORBIDDEN'); end if;
  if v_sku = '' then return jsonb_build_object('ok',false,'error','KIT_SKU_REQUIRED'); end if;

  select id into v_kit from products where sku = v_sku;
  v_new_product := v_kit is null;
  if v_kit is not null then
    select * into k from kits where product_id = v_kit;
    select coalesce(sum(qty_on_hand), 0) into v_stock from bin_inventory where product_id = v_kit;
    if v_stock > 0 then
      v_warn := v_warn || jsonb_build_array(format('%s units of %s are in locations. Orders for it will pick the parts instead, so that stock won''t be used.', v_stock, v_sku));
    end if;
  end if;

  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    v_errors := v_errors || '["Add at least one line"]'::jsonb;
  else
    for ln in select * from jsonb_array_elements(p_lines) loop
      v_no := v_no + 1; v_seen := array[]::text[];
      if coalesce((ln->>'qty')::int, 0) < 1 then v_errors := v_errors || jsonb_build_array(format('Line %s: quantity must be 1 or more', v_no)); end if;
      if jsonb_typeof(ln->'skus') <> 'array' or jsonb_array_length(ln->'skus') = 0 then
        v_errors := v_errors || jsonb_build_array(format('Line %s: add a SKU', v_no));
      else
        for s in select * from jsonb_array_elements(ln->'skus') loop
          if trim(s #>> '{}') = v_sku then v_errors := v_errors || jsonb_build_array(format('Line %s: a kit can''t contain itself', v_no));
          elsif not exists (select 1 from products where sku = trim(s #>> '{}')) then
            v_errors := v_errors || jsonb_build_array(format('Line %s: SKU %s is not in the WMS', v_no, s #>> '{}'));
          elsif trim(s #>> '{}') = any(v_seen) then
            v_errors := v_errors || jsonb_build_array(format('Line %s: SKU %s is listed twice', v_no, s #>> '{}'));
          elsif exists (select 1 from kits kk join products pp on pp.id = kk.product_id where pp.sku = trim(s #>> '{}') and kk.is_active) then
            v_warn := v_warn || jsonb_build_array(format('Line %s: %s is itself a kit, it will be split into its parts too', v_no, s #>> '{}'));
          end if;
          v_seen := v_seen || trim(s #>> '{}');
        end loop;
      end if;
    end loop;
  end if;

  select count(distinct ol.order_id) into v_orders
    from order_lines ol join orders o on o.id = ol.order_id
   where ol.sku = v_sku and ol.kit_product_id is null and o.status in ('awaiting_pick','on_hold');

  if jsonb_array_length(v_errors) > 0 or not p_confirmed then
    return jsonb_build_object('ok', jsonb_array_length(v_errors) = 0, 'preview', true, 'errors', v_errors, 'warnings', v_warn,
                              'new_kit', k.product_id is null, 'new_product', v_new_product,
                              'orders_waiting', v_orders, 'lines', jsonb_array_length(coalesce(p_lines, '[]')));
  end if;

  if v_new_product then
    insert into products(sku, name, is_active) values (v_sku, coalesce(nullif(trim(p_new_product_name), ''), nullif(trim(p_title), ''), v_sku), true)
    returning id into v_kit;
  end if;

  insert into kits(product_id, code, title, source, version, updated_by)
  values (v_kit, nullif(trim(p_code), ''), nullif(trim(p_title), ''), 'wms', 1, v_staff)
  on conflict (product_id) do update set code = excluded.code, title = excluded.title, source = 'wms',
         is_active = true, version = kits.version + 1, updated_at = now(), updated_by = v_staff
  returning version into v_ver;

  v_no := 0;
  for ln in select * from jsonb_array_elements(p_lines) loop
    v_no := v_no + 1;
    insert into kit_lines(kit_id, version, line_no, name, qty)
    values (v_kit, v_ver, v_no, coalesce(nullif(trim(ln->>'name'), ''), (select name from products where sku = trim(ln->'skus'->>0))), (ln->>'qty')::int)
    returning id into v_line;
    v_prio := 0;
    for s in select * from jsonb_array_elements(ln->'skus') loop
      v_prio := v_prio + 1;
      insert into kit_line_skus(line_id, product_id, priority)
      values (v_line, (select id from products where sku = trim(s #>> '{}')), v_prio) on conflict do nothing;
    end loop;
  end loop;

  return jsonb_build_object('ok', true, 'saved', true, 'version', v_ver, 'new_product', v_new_product,
                            'queue', wms__kit_expand_queue(), 'kit', wms__kit_json(v_kit, wms__main_warehouse()));
end $$;

create or replace function wms_kit_set_active(p_kit_sku text, p_active boolean) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); v_kit uuid;
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then return jsonb_build_object('ok',false,'error','FORBIDDEN'); end if;
  select k.product_id into v_kit from kits k join products p on p.id = k.product_id where p.sku = trim(p_kit_sku);
  if v_kit is null then return jsonb_build_object('ok', false, 'error', 'NOT_A_KIT'); end if;
  update kits set is_active = p_active, updated_at = now(), updated_by = v_staff where product_id = v_kit;
  return jsonb_build_object('ok', true, 'kit', wms__kit_json(v_kit, wms__main_warehouse()));
end $$;

-- ---------------------------------------------------------------------------
-- Pack desk: show which kit a part belongs to
-- ---------------------------------------------------------------------------
create or replace function wms__pack_view(p_shipment_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'shipment_id', sh.id, 'status', sh.status, 'weight_grams', sh.weight_grams, 'weight_source', sh.weight_source,
    'tracking_number', sh.tracking_number, 'last_error', sh.last_error, 'test_label', sh.test_label,
    'order', jsonb_build_object('id', o.id, 'order_number', o.order_number, 'customer', o.customer_name,
                                'requested_service', o.requested_service, 'is_held', o.is_held,
                                'hold_reason', o.hold_reason,
                                'city', o.ship_to->>'city_locality', 'state', o.ship_to->>'state_province',
                                'country', o.ship_to->>'country_code'),
    'lines', (select jsonb_agg(jsonb_build_object(
                 'order_line_id', l.id, 'sku', l.sku, 'name', coalesce(p.name, l.name),
                 'variant', p.variant_title, 'image_url', p.image_url,
                 'qty_ordered', l.qty_ordered, 'qty_picked', l.qty_picked, 'qty_packed', l.qty_packed,
                 'remaining', l.qty_ordered - l.qty_packed,
                 'kit_sku', l.kit_sku, 'kit_title', l.kit_title, 'kit_qty', l.kit_qty,
                 'pick_flag', (select jsonb_agg(jsonb_build_object('kind', e.kind, 'reason', e.reason, 'qty', e.qty,
                                      'bin', e.bin_code, 'picker', (select display_name from staff where id = e.staff_id), 'note', e.note))
                                 from pick_exceptions e where e.order_line_id = l.id))
                 order by (l.qty_ordered - l.qty_packed) = 0, l.kit_sku nulls first, l.sku)
                from order_lines l left join products p on p.id = l.product_id where l.order_id = o.id),
    'pick_flags', (select coalesce(jsonb_agg(jsonb_build_object('kind', e.kind, 'reason', e.reason, 'qty', e.qty, 'sku', e.sku,
                                      'bin', e.bin_code, 'picker', (select display_name from staff where id = e.staff_id), 'note', e.note)
                                      order by e.occurred_at), '[]')
                     from pick_exceptions e where e.order_id = o.id),
    'units_total', (select sum(qty_ordered) from order_lines where order_id = o.id),
    'units_packed', (select sum(qty_packed) from order_lines where order_id = o.id),
    'complete', not exists (select 1 from order_lines l where l.order_id = o.id and l.qty_packed < l.qty_ordered))
  from shipments sh join orders o on o.id = sh.order_id where sh.id = p_shipment_id
$$;

-- ---------------------------------------------------------------------------
-- Inventory reconciliation: real kits are skipped as kits too
-- ---------------------------------------------------------------------------
create or replace function wms__recon_auto_kit(p_sku text, p_name text, p_variant text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from kits k join products p on p.id = k.product_id where p.sku = p_sku and k.is_active)
      or (coalesce(p_name, '') !~* 'component'
     and (coalesce(p_name, '') ~* '(bundle|mystery box|\mpack\M|\mpackages?\M| \+ )'
       or coalesce(p_variant, '') ~* '\m([2-9]|[1-9][0-9]+) ?-?(pack|pk|pak)\M'
       or (coalesce(p_name, '') || ' ' || coalesce(p_variant, '')) ~* '(\mplus\M|\m[0-9]+ ?x [0-9.]+ ?(lb|kg))'
       or coalesce(p_sku, '') ~* '([2-9]|[1-9][0-9])(pk|pak|pack)|-pair$|bundle'))
$$;

-- ---------------------------------------------------------------------------
-- permissions
-- ---------------------------------------------------------------------------
revoke execute on function wms__free_units(uuid, uuid) from public, anon, authenticated;
revoke execute on function wms__kit_current_lines(uuid) from public, anon, authenticated;
revoke execute on function wms__kit_line_pick(uuid, int, uuid) from public, anon, authenticated;
revoke execute on function wms__kit_available(uuid, uuid) from public, anon, authenticated;
revoke execute on function wms__order_line_kit() from public, anon, authenticated;
revoke execute on function wms__kit_expand_queue() from public, anon, authenticated;
revoke execute on function wms__kit_json(uuid, uuid) from public, anon, authenticated;
revoke execute on function wms_import_kits(jsonb, text) from public;
grant  execute on function wms_import_kits(jsonb, text) to anon, authenticated, service_role;   -- still needs admin or a live token
revoke execute on function wms_kits_fix_queue() from public, anon;
revoke execute on function wms_kits(text, text, int, int) from public, anon;
revoke execute on function wms_kit(text) from public, anon;
revoke execute on function wms_kit_find_products(text) from public, anon;
revoke execute on function wms_kit_save(text, text, text, jsonb, text, boolean) from public, anon;
revoke execute on function wms_kit_set_active(text, boolean) from public, anon;
grant execute on function wms_kits_fix_queue() to authenticated;
grant execute on function wms_kits(text, text, int, int) to authenticated;
grant execute on function wms_kit(text) to authenticated;
grant execute on function wms_kit_find_products(text) to authenticated;
grant execute on function wms_kit_save(text, text, text, jsonb, text, boolean) to authenticated;
grant execute on function wms_kit_set_active(text, boolean) to authenticated;
