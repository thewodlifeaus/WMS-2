-- =============================================================================
-- TWL WMS | Migration 009 | Hourly catalogue + location sync (Shopify, SkuVault)
--   Runs Mon-Fri, Adelaide time: 8:00, 9:00 ... 16:00 and a last run at 16:30.
--   pg_cron fires every 30 min (UTC); the Adelaide-time check below decides
--   whether to call the edge function, so daylight saving is handled.
-- =============================================================================
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- the edge function runs with the service role: let it use the import functions
create or replace function wms__import_allowed(p_token text) returns boolean
language sql stable security definer set search_path = public as $$
  select wms_has_role(array['admin']::staff_role[])
      or coalesce(auth.jwt()->>'role', '') = 'service_role'
      or exists (select 1 from import_tokens where token = p_token and expires_at > now())
$$;

-- shared secret between pg_cron and the edge function (no RLS policy = hidden from apps)
create table if not exists app_secrets (
  name   text primary key,
  value  text not null
);
alter table app_secrets enable row level security;
insert into app_secrets(name, value) values ('cron_secret', encode(gen_random_bytes(24), 'hex'))
on conflict (name) do nothing;

-- ---------------------------------------------------------------------------
-- Full stock snapshot from SkuVault: set every listed SKU x bin, and zero any
-- bin balance in the warehouse that SkuVault no longer lists (stock moved/sold).
-- Never zeroes allocated units, and refuses to run on a suspiciously small
-- snapshot (protects against an empty/failed export wiping the WMS).
-- ---------------------------------------------------------------------------
create or replace function wms_sync_stock_snapshot(p_warehouse_code text, p_rows jsonb, p_reason text,
                                                   p_token text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_wh uuid; v_res jsonb; v_zeroed int := 0; v_cur_rows int; r record;
begin
  if not wms__import_allowed(p_token) then raise exception 'FORBIDDEN'; end if;
  select id into v_wh from warehouses where code = p_warehouse_code;

  select count(*) into v_cur_rows from bin_inventory bi join bins b on b.id = bi.bin_id
   where b.warehouse_id = v_wh and bi.qty_on_hand > 0;
  if jsonb_array_length(p_rows) < v_cur_rows * 0.5 then
    raise exception 'SNAPSHOT_TOO_SMALL: % rows vs % in WMS - not applied', jsonb_array_length(p_rows), v_cur_rows;
  end if;

  v_res := wms_import_stock(p_warehouse_code, p_rows, p_reason, p_token);

  for r in
    select bi.bin_id, bi.product_id, bi.qty_on_hand, bi.qty_allocated
      from bin_inventory bi join bins b on b.id = bi.bin_id join products p on p.id = bi.product_id
     where b.warehouse_id = v_wh and bi.qty_on_hand > bi.qty_allocated
       and not exists (select 1 from jsonb_array_elements(p_rows) x
                        where x->>'sku' = p.sku and x->>'location' = b.code)
  loop
    perform wms__apply_delta(r.bin_id, r.product_id, r.qty_allocated - r.qty_on_hand, 'cycle_count',
                             'import', null, null, null, null, p_reason || ' (no longer in this location)');
    v_zeroed := v_zeroed + 1;
  end loop;
  return v_res || jsonb_build_object('zeroed', v_zeroed);
end $$;

revoke execute on function wms_sync_stock_snapshot(text, jsonb, text, text) from public;
grant  execute on function wms_sync_stock_snapshot(text, jsonb, text, text) to anon, authenticated, service_role;
grant  execute on function wms_import_products(jsonb, text) to service_role;
grant  execute on function wms_import_layout(text, jsonb, text) to service_role;

-- ---------------------------------------------------------------------------
-- Schedule. Adelaide is UTC+9:30/+10:30, so UTC :00/:30 lands on local :30/:00.
-- ---------------------------------------------------------------------------
create or replace function wms__catalogue_sync_due(p_at timestamptz default now()) returns boolean
language sql stable set search_path = public as $$
  with t as (select (p_at at time zone 'Australia/Adelaide') as lt)
  select extract(isodow from lt) between 1 and 5
     and ( (extract(hour from lt) between 8 and 16 and extract(minute from lt) < 15)
        or (extract(hour from lt) = 16 and extract(minute from lt) between 30 and 44) )
  from t
$$;

create or replace function wms__trigger_catalogue_sync() returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if not wms__catalogue_sync_due() then return null; end if;
  select net.http_post(
    url     := 'https://nklbnykqftzkbqbuammg.supabase.co/functions/v1/sync-catalogue',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-cron-secret', (select value from app_secrets where name = 'cron_secret')),
    body    := '{}'::jsonb,
    timeout_milliseconds := 5000
  ) into v_id;
  return v_id;
end $$;
revoke execute on function wms__trigger_catalogue_sync() from public, anon, authenticated;

select cron.schedule('wms-catalogue-sync', '*/30 * * * *', $$select public.wms__trigger_catalogue_sync()$$);
