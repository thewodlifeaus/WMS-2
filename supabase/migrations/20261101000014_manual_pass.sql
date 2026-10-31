-- =============================================================================
-- TWL WMS | Migration 014 | Manual pass at the pack desk
-- When an item can't be scanned (no barcode, damaged label, scanner fault) the
-- packer can pass ONE unit by hand after confirming it is the correct product.
-- Every manual pass is recorded: who, when, which desk, which product, why.
-- =============================================================================

create table if not exists pack_manual_passes (
  id              bigint generated always as identity primary key,
  occurred_at     timestamptz not null default now(),
  shipment_id     uuid not null references shipments(id) on delete cascade,
  order_id        uuid not null references orders(id),
  order_line_id   uuid not null references order_lines(id),
  product_id      uuid references products(id),
  sku             text not null,
  qty             int not null default 1 check (qty > 0),
  reason          text not null check (reason in ('no_barcode','damaged_label','barcode_not_recognised','scanner_fault','other')),
  note            text,
  staff_id        uuid not null references staff(id),
  pack_station_id uuid references pack_stations(id)
);
create index if not exists pack_manual_passes_staff_idx on pack_manual_passes(staff_id, occurred_at desc);
alter table pack_manual_passes enable row level security;
create policy pack_manual_passes_read on pack_manual_passes for select to authenticated using (wms_is_staff());

create or replace function wms_pack_manual_pass(
  p_shipment_id uuid, p_order_line_id uuid, p_reason text, p_confirmed boolean, p_note text default null
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_staff uuid := wms__require_staff(); sh shipments; l order_lines; v_wh uuid; v_np boolean; v_bin uuid;
        v_complete boolean; v_closed boolean := false; v_warn jsonb := '[]';
begin
  if not coalesce(p_confirmed, false) then
    return jsonb_build_object('ok',false,'error','NOT_CONFIRMED');
  end if;
  if p_reason is null or p_reason not in ('no_barcode','damaged_label','barcode_not_recognised','scanner_fault','other') then
    return jsonb_build_object('ok',false,'error','REASON_REQUIRED');
  end if;
  if p_reason = 'other' and coalesce(trim(p_note), '') = '' then
    return jsonb_build_object('ok',false,'error','NOTE_REQUIRED');
  end if;

  select * into sh from shipments where id = p_shipment_id for update;
  if sh.id is null or sh.status <> 'packing' then return jsonb_build_object('ok',false,'error','SHIPMENT_CLOSED'); end if;
  select * into l from order_lines where id = p_order_line_id and order_id = sh.order_id for update;
  if l.id is null then return jsonb_build_object('ok',false,'error','NOT_IN_ORDER'); end if;
  select warehouse_id into v_wh from orders where id = sh.order_id;
  v_np := wms__pack_without_pick(v_wh);

  if l.qty_packed + 1 > (case when v_np then l.qty_ordered else l.qty_picked end) then
    return jsonb_build_object('ok',false,'error','ALREADY_PACKED','sku',l.sku) || wms__pack_view(sh.id);
  end if;

  if v_np and l.qty_picked < l.qty_packed + 1 and l.product_id is not null then
    select bi.bin_id into v_bin from bin_inventory bi join bins b on b.id = bi.bin_id
     where bi.product_id = l.product_id and b.is_pickable and bi.qty_on_hand >= 1
     order by bi.qty_on_hand desc limit 1;
    if v_bin is null then
      select bi.bin_id into v_bin from bin_inventory bi where bi.product_id = l.product_id and bi.qty_on_hand >= 1
       order by bi.qty_on_hand desc limit 1;
    end if;
    if v_bin is not null then
      perform wms__apply_delta(v_bin, l.product_id, -1, 'pick', 'shipment', sh.id, v_staff, null, null, 'manual pass');
    else
      v_warn := jsonb_build_array(jsonb_build_object('type','NO_STOCK_RECORDED','sku',l.sku,
                  'message','WMS shows no stock for this item. Passed anyway; check the count.'));
    end if;
  end if;
  if v_np and l.qty_picked < l.qty_packed + 1 then
    update order_lines set qty_allocated = greatest(qty_allocated, qty_packed + 1),
                           qty_picked = qty_packed + 1 where id = l.id;
  end if;

  update order_lines set qty_packed = qty_packed + 1 where id = l.id;
  insert into shipment_items(shipment_id, order_line_id, qty) values (sh.id, l.id, 1)
  on conflict (shipment_id, order_line_id) do update set qty = shipment_items.qty + 1;
  insert into pack_manual_passes(shipment_id, order_id, order_line_id, product_id, sku, reason, note, staff_id, pack_station_id)
  values (sh.id, sh.order_id, l.id, l.product_id, l.sku, p_reason, nullif(trim(p_note), ''), v_staff, sh.pack_station_id);

  v_complete := not exists (select 1 from order_lines where order_id = sh.order_id and qty_packed < qty_ordered);
  if v_complete and wms__setting(v_wh, 'pack_auto_close') then
    perform wms__pack_close(sh.id, null, null, null, null, null);
    update shipments set weight_source = 'estimate' where id = sh.id;
    v_closed := true;
  end if;

  return jsonb_build_object('ok',true,'sku',l.sku,'manual',true,'auto_closed',v_closed,'warnings',v_warn) || wms__pack_view(sh.id);
end $$;

revoke execute on function wms_pack_manual_pass(uuid, uuid, text, boolean, text) from public, anon;
grant execute on function wms_pack_manual_pass(uuid, uuid, text, boolean, text) to authenticated;
