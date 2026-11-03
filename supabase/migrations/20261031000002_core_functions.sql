-- =============================================================================
-- TWL WMS  |  Migration 002  |  Helpers, triggers, routing key, stock movements
-- All stock changes go through wms__apply_delta() so the ledger can never drift
-- from bin_inventory.
-- =============================================================================

-- ---------------------------------------------------------------------------
-- Who is calling?
-- ---------------------------------------------------------------------------
create or replace function wms_current_staff() returns uuid
language sql stable security definer set search_path = public as $$
  select s.id from staff s where s.id = auth.uid() and s.is_active
$$;

create or replace function wms_is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff s where s.id = auth.uid() and s.is_active)
$$;

create or replace function wms_has_role(p_roles staff_role[]) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from staff s where s.id = auth.uid() and s.is_active and s.role = any(p_roles))
$$;

create or replace function wms__require_staff() returns uuid
language plpgsql stable security definer set search_path = public as $$
declare v uuid := wms_current_staff();
begin
  if v is null then raise exception 'NOT_STAFF: user is not an active WMS staff member' using errcode = '42501'; end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Bins: build the coordinate code, barcode and sort keys automatically
-- ---------------------------------------------------------------------------
create or replace function wms__bins_before_write() returns trigger
language plpgsql set search_path = public as $$
declare r record; wh_code text;
begin
  if new.shelf_id is not null then
    select ar.code as row_code, ar.sequence as row_seq, ar.zone_id,
           sh.code as shelf_code, sh.sequence as shelf_seq, sh.side, ar.warehouse_id
      into r
      from shelves sh join aisle_rows ar on ar.id = sh.row_id
     where sh.id = new.shelf_id;
    if r.warehouse_id <> new.warehouse_id then
      raise exception 'Bin warehouse does not match its shelf warehouse';
    end if;
    new.code       := r.row_code || '-' || r.shelf_code || '-' || new.bin_code;
    new.row_seq    := r.row_seq;
    new.shelf_seq  := r.shelf_seq;
    new.shelf_side := r.side;
    new.zone_id    := coalesce(new.zone_id, r.zone_id);
  else
    new.code := coalesce(nullif(new.code, ''), new.bin_code);   -- floor areas: 'DOCK-1'
  end if;
  new.bin_seq := coalesce(nullif(regexp_replace(new.bin_code, '\D', '', 'g'), '')::int, 0);
  if new.barcode is null or new.barcode = '' or tg_op = 'UPDATE' and new.code <> old.code then
    select code into wh_code from warehouses where id = new.warehouse_id;
    new.barcode := 'LOC:' || wh_code || ':' || new.code;
  end if;
  return new;
end $$;

create trigger bins_before_write before insert or update on bins
  for each row execute function wms__bins_before_write();

-- keep bin sort keys in sync if a row/shelf is renumbered
create or replace function wms__topology_changed() returns trigger
language plpgsql set search_path = public as $$
begin
  if tg_table_name = 'aisle_rows' then
    update bins b set bin_code = b.bin_code
      from shelves sh where sh.id = b.shelf_id and sh.row_id = new.id;
  else
    update bins set bin_code = bin_code where shelf_id = new.id;
  end if;
  return new;
end $$;
create trigger aisle_rows_after_update after update of code, sequence, zone_id on aisle_rows
  for each row execute function wms__topology_changed();
create trigger shelves_after_update after update of code, sequence, side on shelves
  for each row execute function wms__topology_changed();

-- every product gets its SKU as a scannable barcode too
create or replace function wms__products_after_insert() returns trigger
language plpgsql set search_path = public as $$
begin
  insert into product_barcodes(barcode, product_id, is_primary) values (new.sku, new.id, false)
  on conflict (barcode) do nothing;
  return new;
end $$;
create trigger products_after_insert after insert on products
  for each row execute function wms__products_after_insert();

-- ---------------------------------------------------------------------------
-- Routing key (see docs/PICK_ROUTING.md)
--   p_visit_idx = 1,2,3... the order this row is visited IN THIS SESSION
--   (not the physical row number) so direction alternates only across rows
--   that are actually walked: no backtracking even when rows are skipped.
-- ---------------------------------------------------------------------------
create or replace function wms_route_key(
  p_strategy route_strategy, p_visit_idx int, p_row_seq int,
  p_shelf_seq int, p_side text, p_bin_seq int
) returns bigint
language sql immutable as $$
  select
    coalesce(p_row_seq, 0)::bigint * 100000000
    + (case
         when p_strategy = 'linear' or p_visit_idx % 2 = 1 then coalesce(p_shelf_seq, 0)
         else 9999 - coalesce(p_shelf_seq, 0)
       end)::bigint * 10000
    + (case
         when p_side is null then 0
         when p_strategy = 'zigzag' then
           -- alternate which side is picked first at each bay so the picker
           -- crosses the aisle once per bay instead of twice
           case when ((coalesce(p_shelf_seq,0) % 2 = 1) = (p_side = 'L')) then 0 else 1 end
         else case when p_side = 'L' then 0 else 1 end
       end)::bigint * 1000
    + least(coalesce(p_bin_seq, 0), 999)
$$;

-- ---------------------------------------------------------------------------
-- Barcode resolver: one call tells the app what was scanned
-- ---------------------------------------------------------------------------
create or replace function wms_resolve_scan(p_value text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v text := trim(p_value); j jsonb;
begin
  perform wms__require_staff();
  select jsonb_build_object('type','bin','id',id,'code',code,'location_type',location_type)
    into j from bins where barcode = v or code = v limit 1;
  if j is not null then return j; end if;
  select jsonb_build_object('type','product','id',p.id,'sku',p.sku,'name',p.name,
                            'variant',p.variant_title,'units_per_scan',pb.units_per_scan)
    into j from product_barcodes pb join products p on p.id = pb.product_id where pb.barcode = v;
  if j is not null then return j; end if;
  select jsonb_build_object('type','basket','id',b.id,'cart_id',b.cart_id,'position',b.position)
    into j from cart_baskets b where b.barcode = v;
  if j is not null then return j; end if;
  select jsonb_build_object('type','cart','id',id,'code',code,'basket_count',basket_count)
    into j from carts where barcode = v or code = v;
  if j is not null then return j; end if;
  select jsonb_build_object('type','order','id',id,'order_number',order_number,'status',status)
    into j from orders where order_number = ltrim(v, '#');
  if j is not null then return j; end if;
  select jsonb_build_object('type','package','id',id,'code',code)
    into j from package_types where barcode = v;
  return coalesce(j, jsonb_build_object('type','unknown','value',v));
end $$;

-- ---------------------------------------------------------------------------
-- THE single place stock changes. Upserts bin_inventory + writes ledger.
-- ---------------------------------------------------------------------------
create or replace function wms__apply_delta(
  p_bin uuid, p_product uuid, p_delta int, p_type txn_type,
  p_ref_type text default null, p_ref_id uuid default null,
  p_staff uuid default null, p_device uuid default null,
  p_move_group uuid default null, p_reason text default null,
  p_release_allocated int default 0
) returns int
language plpgsql security definer set search_path = public as $$
declare v_after int;
begin
  if p_delta = 0 then return null; end if;
  if p_delta < 0 then
    update bin_inventory
       set qty_on_hand   = qty_on_hand + p_delta,
           qty_allocated = qty_allocated - p_release_allocated,
           updated_at    = now()
     where bin_id = p_bin and product_id = p_product
    returning qty_on_hand into v_after;
    if not found then
      raise exception 'INSUFFICIENT_STOCK: nothing in that bin to remove' using errcode = 'P0001';
    end if;
  else
    insert into bin_inventory as bi (bin_id, product_id, qty_on_hand)
    values (p_bin, p_product, p_delta)
    on conflict (bin_id, product_id) do update
       set qty_on_hand = bi.qty_on_hand + p_delta, updated_at = now()
    returning qty_on_hand into v_after;
  end if;
  insert into inventory_transactions(txn_type, product_id, bin_id, qty_delta, qty_after,
                                     move_group, ref_type, ref_id, staff_id, device_id, reason)
  values (p_type, p_product, p_bin, p_delta, v_after,
          p_move_group, p_ref_type, p_ref_id, p_staff, p_device, p_reason);
  return v_after;
exception when check_violation then
  raise exception 'INSUFFICIENT_STOCK: bin does not hold enough available units' using errcode = 'P0001';
end $$;

create or replace function wms__log_scan(
  p_ctx scan_context, p_result scan_result, p_value text,
  p_expected uuid, p_scanned uuid, p_session uuid, p_task uuid, p_shipment uuid,
  p_staff uuid, p_device uuid
) returns void language sql security definer set search_path = public as $$
  insert into scan_events(context, result, scanned_value, expected_product_id, scanned_product_id,
                          session_id, task_id, shipment_id, staff_id, device_id)
  values (p_ctx, p_result, p_value, p_expected, p_scanned, p_session, p_task, p_shipment, p_staff, p_device);
$$;

-- ---------------------------------------------------------------------------
-- Backfill alerts: pick bin drops to/below min -> open a move task
-- ---------------------------------------------------------------------------
create or replace function wms__check_backfill() returns trigger
language plpgsql security definer set search_path = public as $$
declare rule record; src record; v_qty int;
begin
  select rr.* into rule from replenishment_rules rr
   where rr.bin_id = new.bin_id and rr.product_id = new.product_id and rr.is_active;
  if not found or new.qty_on_hand > rule.min_qty then return new; end if;
  if exists (select 1 from backfill_tasks where to_bin_id = new.bin_id and product_id = new.product_id
                                            and status in ('open','in_progress')) then
    return new;
  end if;
  -- best source = overstock bin with the most available units (same warehouse)
  select bi.bin_id, bi.qty_on_hand - bi.qty_allocated as avail into src
    from bin_inventory bi
    join bins b on b.id = bi.bin_id
    join bins tb on tb.id = new.bin_id
   where bi.product_id = new.product_id and b.location_type = 'backfill' and b.is_active
     and b.warehouse_id = tb.warehouse_id and bi.qty_on_hand - bi.qty_allocated > 0
   order by bi.qty_on_hand - bi.qty_allocated desc limit 1;
  v_qty := rule.max_qty - new.qty_on_hand;
  if src.bin_id is not null then v_qty := least(v_qty, src.avail); end if;
  if v_qty > 0 then
    insert into backfill_tasks(rule_id, product_id, from_bin_id, to_bin_id, qty_suggested)
    values (rule.id, new.product_id, src.bin_id, new.bin_id, v_qty)
    on conflict do nothing;
  end if;
  return new;
end $$;

create trigger bin_inventory_backfill
  after insert or update of qty_on_hand on bin_inventory
  for each row execute function wms__check_backfill();

-- ---------------------------------------------------------------------------
-- INBOUND: receive against a Cin7 PO.  Item scan -> bin scan -> +qty
-- ---------------------------------------------------------------------------
create or replace function wms_receive_scan(
  p_po_id uuid, p_product_barcode text, p_bin_barcode text,
  p_qty int default null, p_device_id uuid default null, p_allow_over boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := wms__require_staff();
  v_po purchase_orders; v_prod record; v_bin bins; v_line purchase_order_lines;
  v_qty int; v_after int;
begin
  select * into v_po from purchase_orders where id = p_po_id;
  if not found or v_po.status not in ('ordered','in_transit','partially_received') then
    return jsonb_build_object('ok',false,'error','PO_NOT_OPEN');
  end if;

  select p.id, p.sku, pb.units_per_scan into v_prod
    from product_barcodes pb join products p on p.id = pb.product_id where pb.barcode = trim(p_product_barcode);
  if not found then
    perform wms__log_scan('receive','unknown_barcode',p_product_barcode,null,null,null,null,null,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','UNKNOWN_BARCODE');
  end if;

  select * into v_line from purchase_order_lines
   where po_id = p_po_id and (product_id = v_prod.id or (product_id is null and sku = v_prod.sku))
   for update;
  if not found then
    perform wms__log_scan('receive','wrong_item',p_product_barcode,null,v_prod.id,null,null,null,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','NOT_ON_PO','sku',v_prod.sku);
  end if;

  select * into v_bin from bins where barcode = trim(p_bin_barcode) or code = trim(p_bin_barcode);
  if not found or not v_bin.is_active then
    return jsonb_build_object('ok',false,'error','UNKNOWN_BIN');
  end if;

  v_qty := coalesce(p_qty, v_prod.units_per_scan);
  if v_qty <= 0 then return jsonb_build_object('ok',false,'error','BAD_QTY'); end if;
  if not p_allow_over and v_line.qty_received + v_qty > v_line.qty_ordered then
    perform wms__log_scan('receive','over_qty',p_product_barcode,v_prod.id,v_prod.id,null,null,null,v_staff,p_device_id);
    return jsonb_build_object('ok',false,'error','OVER_RECEIPT',
      'ordered',v_line.qty_ordered,'received',v_line.qty_received);
  end if;

  v_after := wms__apply_delta(v_bin.id, v_prod.id, v_qty, 'receive', 'po_line', v_line.id, v_staff, p_device_id);
  update purchase_order_lines set qty_received = qty_received + v_qty, product_id = v_prod.id where id = v_line.id;
  update purchase_orders po set status = case
           when not exists (select 1 from purchase_order_lines l where l.po_id = po.id and l.qty_received < l.qty_ordered)
           then 'received'::po_status else 'partially_received'::po_status end
   where po.id = p_po_id;
  perform wms__log_scan('receive','ok',p_product_barcode,v_prod.id,v_prod.id,null,null,null,v_staff,p_device_id);

  return jsonb_build_object('ok',true,'sku',v_prod.sku,'bin',v_bin.code,'qty',v_qty,
    'bin_qty_after',v_after,'line_received',v_line.qty_received + v_qty,'line_ordered',v_line.qty_ordered);
end $$;

-- ---------------------------------------------------------------------------
-- MOVE: scan from-bin, scan SKU, qty, scan to-bin
-- ---------------------------------------------------------------------------
create or replace function wms_move_stock(
  p_from_bin text, p_product_barcode text, p_qty int, p_to_bin text,
  p_device_id uuid default null, p_backfill_task_id uuid default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_staff uuid := wms__require_staff();
  v_from bins; v_to bins; v_prod uuid; v_sku text; v_avail int; v_group uuid := gen_random_uuid();
  v_from_after int; v_to_after int;
begin
  if p_qty is null or p_qty <= 0 then return jsonb_build_object('ok',false,'error','BAD_QTY'); end if;
  select * into v_from from bins where barcode = trim(p_from_bin) or code = trim(p_from_bin);
  select * into v_to   from bins where barcode = trim(p_to_bin)   or code = trim(p_to_bin);
  if v_from.id is null or v_to.id is null then return jsonb_build_object('ok',false,'error','UNKNOWN_BIN'); end if;
  if v_from.id = v_to.id then return jsonb_build_object('ok',false,'error','SAME_BIN'); end if;
  if not v_to.is_active then return jsonb_build_object('ok',false,'error','BIN_INACTIVE'); end if;
  if v_from.warehouse_id <> v_to.warehouse_id then return jsonb_build_object('ok',false,'error','CROSS_WAREHOUSE'); end if;

  select p.id, p.sku into v_prod, v_sku from product_barcodes pb join products p on p.id = pb.product_id
   where pb.barcode = trim(p_product_barcode);
  if v_prod is null then return jsonb_build_object('ok',false,'error','UNKNOWN_BARCODE'); end if;

  select qty_on_hand - qty_allocated into v_avail from bin_inventory
   where bin_id = v_from.id and product_id = v_prod for update;
  if coalesce(v_avail,0) < p_qty then
    return jsonb_build_object('ok',false,'error','INSUFFICIENT_STOCK','available',coalesce(v_avail,0));
  end if;

  v_from_after := wms__apply_delta(v_from.id, v_prod, -p_qty, 'move_out', 'move', v_group, v_staff, p_device_id, v_group);
  v_to_after   := wms__apply_delta(v_to.id,   v_prod,  p_qty, 'move_in',  'move', v_group, v_staff, p_device_id, v_group);

  -- credit an open backfill task for this destination
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

-- ---------------------------------------------------------------------------
-- ADJUST / CYCLE COUNT (supervisor+)
-- ---------------------------------------------------------------------------
create or replace function wms_set_bin_qty(
  p_bin text, p_product_barcode text, p_counted int, p_reason text,
  p_device_id uuid default null, p_is_cycle_count boolean default true
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); v_bin uuid; v_prod uuid; v_cur int; v_alloc int; v_after int;
begin
  if not wms_has_role(array['admin','supervisor']::staff_role[]) then
    return jsonb_build_object('ok',false,'error','FORBIDDEN');
  end if;
  if p_counted < 0 then return jsonb_build_object('ok',false,'error','BAD_QTY'); end if;
  select id into v_bin from bins where barcode = trim(p_bin) or code = trim(p_bin);
  select product_id into v_prod from product_barcodes where barcode = trim(p_product_barcode);
  if v_bin is null or v_prod is null then return jsonb_build_object('ok',false,'error','NOT_FOUND'); end if;
  select qty_on_hand, qty_allocated into v_cur, v_alloc from bin_inventory
   where bin_id = v_bin and product_id = v_prod for update;
  if p_counted < coalesce(v_alloc,0) then
    return jsonb_build_object('ok',false,'error','BELOW_ALLOCATED','allocated',v_alloc);
  end if;
  v_after := wms__apply_delta(v_bin, v_prod, p_counted - coalesce(v_cur,0),
              case when p_is_cycle_count then 'cycle_count'::txn_type else 'adjust'::txn_type end,
              'adjustment', null, v_staff, p_device_id, null, p_reason);
  return jsonb_build_object('ok',true,'before',coalesce(v_cur,0),'after',p_counted,'delta',p_counted - coalesce(v_cur,0));
end $$;
