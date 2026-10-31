-- TWL WMS | Migration 015 | TV numbers ignore voided shipments (eg reset test labels)
create or replace function wms__floor_window(p_from timestamptz, p_to timestamptz)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'items_picked',   coalesce((select sum(-it.qty_delta) from inventory_transactions it
                                 where it.txn_type = 'pick' and it.occurred_at >= p_from and it.occurred_at < p_to
                                   and not exists (select 1 from shipments v where v.id = it.ref_id and v.status = 'voided')), 0),
    'items_packed',   coalesce((select sum(si.qty) from shipment_items si join shipments sh on sh.id = si.shipment_id
                                 where sh.packed_at >= p_from and sh.packed_at < p_to and sh.status <> 'voided'), 0),
    'labels',         (select count(*) from shipments where labelled_at >= p_from and labelled_at < p_to and status <> 'voided'),
    'orders_shipped', (select count(distinct order_id) from shipments where labelled_at >= p_from and labelled_at < p_to and status <> 'voided'),
    'orders_received',(select count(*) from orders where coalesce(ordered_at, imported_at) >= p_from
                                               and coalesce(ordered_at, imported_at) < p_to)
  )
$$;
