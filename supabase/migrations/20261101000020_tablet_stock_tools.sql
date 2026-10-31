-- =============================================================================
-- TWL WMS | Migration 020 | Tablet stock tools
--   * location contents (scan a location -> what is in it)
--   * move stock: scan from-location, product (barcode OR SKU), quantity, to-location
--   * merge: move everything that is free from one location into another
-- Reserved stock (allocated to a cart) never moves; it stays for the picker.
-- Every move is in the stock history (move_out / move_in with a shared move group).
-- =============================================================================

create or replace function wms__find_bin(p_text text) returns bins
language sql stable security definer set search_path = public as $$
  select * from bins where upper(barcode) = upper(trim(p_text)) or upper(code) = upper(trim(p_text))
   order by (upper(code) = upper(trim(p_text))) desc limit 1
$$;

create or replace function wms__find_product(p_text text) returns uuid
language sql stable security definer set search_path = public as $$
  select coalesce((select product_id from product_barcodes where barcode = trim(p_text) limit 1),
                  (select id from products where upper(sku) = upper(trim(p_text)) limit 1))
$$;

-- what is in a location
create or replace function wms_bin_contents(p_bin text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b bins;
begin
  perform wms__require_staff();
  b := wms__find_bin(p_bin);
  if b.id is null then return jsonb_build_object('ok',false,'error','UNKNOWN_BIN','scanned',p_bin); end if;
  return jsonb_build_object('ok',true,
    'bin', jsonb_build_object('code', b.code, 'type', b.location_type, 'active', b.is_active, 'pickable', b.is_pickable),
    'units', (select coalesce(sum(qty_on_hand), 0) from bin_inventory where bin_id = b.id),
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
                'sku', p.sku, 'name', p.name, 'variant', p.variant_title, 'image_url', p.image_url,
                'on_hand', bi.qty_on_hand, 'allocated', bi.qty_allocated, 'free', bi.qty_on_hand - bi.qty_allocated,
                'other_bins', (select coalesce(jsonb_agg(jsonb_build_object('bin', b2.code, 'qty', bi2.qty_on_hand) order by b2.code), '[]')
                                 from bin_inventory bi2 join bins b2 on b2.id = bi2.bin_id
                                where bi2.product_id = p.id and bi2.bin_id <> b.id and bi2.qty_on_hand > 0))
                order by p.sku), '[]')
                from bin_inventory bi join products p on p.id = bi.product_id
               where bi.bin_id = b.id and bi.qty_on_hand > 0));
end $$;

-- move stock (product by barcode or SKU; locations by label or code, any case)
create or replace function wms_move_stock(
  p_from_bin text, p_product_barcode text, p_qty int, p_to_bin text,
  p_device_id uuid default null, p_backfill_task_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := wms__require_staff();
  v_from bins; v_to bins; v_prod uuid; v_sku text; v_avail int; v_alloc int; v_group uuid := gen_random_uuid();
  v_from_after int; v_to_after int;
begin
  if p_qty is null or p_qty <= 0 then return jsonb_build_object('ok',false,'error','BAD_QTY'); end if;
  v_from := wms__find_bin(p_from_bin);
  v_to   := wms__find_bin(p_to_bin);
  if v_from.id is null then return jsonb_build_object('ok',false,'error','UNKNOWN_BIN','scanned',p_from_bin); end if;
  if v_to.id is null then return jsonb_build_object('ok',false,'error','UNKNOWN_BIN','scanned',p_to_bin); end if;
  if v_from.id = v_to.id then return jsonb_build_object('ok',false,'error','SAME_BIN'); end if;
  if not v_to.is_active then return jsonb_build_object('ok',false,'error','BIN_INACTIVE','bin',v_to.code); end if;
  if v_from.warehouse_id <> v_to.warehouse_id then return jsonb_build_object('ok',false,'error','CROSS_WAREHOUSE'); end if;

  v_prod := wms__find_product(p_product_barcode);
  if v_prod is null then return jsonb_build_object('ok',false,'error','UNKNOWN_BARCODE'); end if;
  select sku into v_sku from products where id = v_prod;

  select qty_on_hand - qty_allocated, qty_allocated into v_avail, v_alloc from bin_inventory
   where bin_id = v_from.id and product_id = v_prod for update;
  if coalesce(v_avail,0) < p_qty then
    return jsonb_build_object('ok',false,'error','INSUFFICIENT_STOCK','available',coalesce(v_avail,0),
                              'reserved',coalesce(v_alloc,0),'sku',v_sku,'bin',v_from.code);
  end if;

  v_from_after := wms__apply_delta(v_from.id, v_prod, -p_qty, 'move_out', 'move', v_group, v_staff, p_device_id, v_group);
  v_to_after   := wms__apply_delta(v_to.id,   v_prod,  p_qty, 'move_in',  'move', v_group, v_staff, p_device_id, v_group);

  update backfill_tasks
     set qty_moved = qty_moved + p_qty,
         status = case when qty_moved + p_qty >= qty_suggested then 'done'::backfill_status else 'in_progress'::backfill_status end,
         completed_at = case when qty_moved + p_qty >= qty_suggested then now() end,
         assigned_to = coalesce(assigned_to, v_staff)
   where (id = p_backfill_task_id or p_backfill_task_id is null)
     and to_bin_id = v_to.id and product_id = v_prod and status in ('open','in_progress');

  return jsonb_build_object('ok',true,'sku',v_sku,'qty',p_qty,'from',v_from.code,'from_after',v_from_after,
                            'to',v_to.code,'to_after',v_to_after);
end $$;

-- merge: everything free in one location moves to another
create or replace function wms_merge_bins(p_from_bin text, p_to_bin text, p_confirmed boolean, p_device_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); v_from bins; v_to bins; r record; v_group uuid := gen_random_uuid();
        v_moved jsonb := '[]'; v_kept jsonb := '[]'; v_units int := 0;
begin
  if not coalesce(p_confirmed, false) then return jsonb_build_object('ok',false,'error','NOT_CONFIRMED'); end if;
  v_from := wms__find_bin(p_from_bin); v_to := wms__find_bin(p_to_bin);
  if v_from.id is null then return jsonb_build_object('ok',false,'error','UNKNOWN_BIN','scanned',p_from_bin); end if;
  if v_to.id is null then return jsonb_build_object('ok',false,'error','UNKNOWN_BIN','scanned',p_to_bin); end if;
  if v_from.id = v_to.id then return jsonb_build_object('ok',false,'error','SAME_BIN'); end if;
  if not v_to.is_active then return jsonb_build_object('ok',false,'error','BIN_INACTIVE','bin',v_to.code); end if;
  if v_from.warehouse_id <> v_to.warehouse_id then return jsonb_build_object('ok',false,'error','CROSS_WAREHOUSE'); end if;

  for r in select bi.product_id, p.sku, bi.qty_on_hand, bi.qty_allocated
             from bin_inventory bi join products p on p.id = bi.product_id
            where bi.bin_id = v_from.id and bi.qty_on_hand > 0 order by p.sku for update of bi loop
    if r.qty_on_hand - r.qty_allocated > 0 then
      perform wms__apply_delta(v_from.id, r.product_id, -(r.qty_on_hand - r.qty_allocated), 'move_out', 'merge', v_group, v_staff, p_device_id, v_group);
      perform wms__apply_delta(v_to.id,   r.product_id,  (r.qty_on_hand - r.qty_allocated), 'move_in',  'merge', v_group, v_staff, p_device_id, v_group);
      v_moved := v_moved || jsonb_build_object('sku', r.sku, 'qty', r.qty_on_hand - r.qty_allocated);
      v_units := v_units + (r.qty_on_hand - r.qty_allocated);
    end if;
    if r.qty_allocated > 0 then
      v_kept := v_kept || jsonb_build_object('sku', r.sku, 'qty', r.qty_allocated, 'why', 'reserved for a cart');
    end if;
  end loop;
  if jsonb_array_length(v_moved) = 0 and jsonb_array_length(v_kept) = 0 then
    return jsonb_build_object('ok',false,'error','BIN_EMPTY','bin',v_from.code);
  end if;
  return jsonb_build_object('ok',true,'from',v_from.code,'to',v_to.code,'units',v_units,'moved',v_moved,'kept',v_kept);
end $$;

-- my recent moves (tablet shows the last few so a mistake is easy to spot)
create or replace function wms_my_recent_moves(p_limit int default 10) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(x order by x->>'at' desc), '[]') from (
    select jsonb_build_object('at', max(it.occurred_at), 'sku', max(p.sku), 'qty', max(abs(it.qty_delta)) filter (where it.qty_delta > 0),
             'from', max(b.code) filter (where it.qty_delta < 0), 'to', max(b.code) filter (where it.qty_delta > 0),
             'kind', max(it.ref_type)) as x
      from inventory_transactions it join bins b on b.id = it.bin_id join products p on p.id = it.product_id
     where it.staff_id = auth.uid() and it.txn_type in ('move_out','move_in') and it.occurred_at > now() - interval '1 day'
     group by it.move_group, it.product_id
     order by max(it.occurred_at) desc limit p_limit
  ) t
$$;

revoke execute on function wms__find_bin(text) from public, anon, authenticated;
revoke execute on function wms__find_product(text) from public, anon, authenticated;
revoke execute on function wms_bin_contents(text) from public, anon;
revoke execute on function wms_merge_bins(text, text, boolean, uuid) from public, anon;
revoke execute on function wms_my_recent_moves(int) from public, anon;
grant execute on function wms_bin_contents(text) to authenticated;
grant execute on function wms_move_stock(text, text, int, text, uuid, uuid) to authenticated;
grant execute on function wms_merge_bins(text, text, boolean, uuid) to authenticated;
grant execute on function wms_my_recent_moves(int) to authenticated;
