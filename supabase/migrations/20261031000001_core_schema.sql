-- =============================================================================
-- TWL WMS  |  Migration 001  |  Core schema
-- -----------------------------------------------------------------------------
-- Physical topology:  Warehouse -> Zone -> Row (aisle) -> Shelf (bay) -> Bin
-- Inventory:          1 SKU : many Bins   (bin_inventory is the live balance)
-- Ledger:             every movement is an append-only inventory_transactions row
-- Outbound:           orders -> pick_sessions -> pick_tasks -> allocations -> baskets
-- Pack/ship:          shipments (one box) -> ShipStation v2 label -> PrintNode
-- =============================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type location_type   as enum ('pick','backfill','receiving','packing','staging','quarantine');
create type route_strategy  as enum ('snake','zigzag','linear');
create type staff_role      as enum ('admin','supervisor','receiver','picker','packer');
create type po_status       as enum ('draft','ordered','in_transit','partially_received','received','closed','cancelled');
create type order_status    as enum ('awaiting_pick','allocated','picking','picked','packing','packed','shipped','on_hold','cancelled');
create type pick_method     as enum ('discrete','batch','wave','cluster','zone','hyper');
create type session_status  as enum ('draft','assigned','in_progress','completed','cancelled');
create type task_status     as enum ('pending','done','short','cancelled');
create type txn_type        as enum ('receive','move_out','move_in','pick','unpick','adjust','cycle_count','return','ship');
create type scan_context    as enum ('receive','move','pick','pack','count','lookup');
create type scan_result     as enum ('ok','wrong_item','unknown_barcode','over_qty','wrong_bin','wrong_basket');
create type backfill_status as enum ('open','in_progress','done','cancelled');
create type shipment_status as enum ('packing','packed','label_requested','label_created','printed','shipped','failed','voided');
create type wave_status     as enum ('planning','released','completed','cancelled');

-- ---------------------------------------------------------------------------
-- Staff & devices
-- ---------------------------------------------------------------------------
create table staff (
  id            uuid primary key references auth.users(id) on delete cascade,
  display_name  text not null,
  role          staff_role not null default 'picker',
  badge_barcode text unique,                 -- optional: scan a badge to log in on a tablet
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);

create table devices (
  id            uuid primary key default gen_random_uuid(),
  name          text not null unique,        -- e.g. 'Tablet 03', 'Pack Bench 1'
  kind          text not null check (kind in ('tablet','desktop')),
  current_staff uuid references staff(id),
  last_seen_at  timestamptz,
  created_at    timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Physical topology
-- ---------------------------------------------------------------------------
create table warehouses (
  id              uuid primary key default gen_random_uuid(),
  code            text not null unique,      -- 'ADL'
  name            text not null,
  address         jsonb,
  timezone        text not null default 'Australia/Adelaide',
  default_route   route_strategy not null default 'snake',
  shipstation_warehouse_id text,             -- e.g. 'se-96460'
  created_at      timestamptz not null default now()
);

create table zones (
  id            uuid primary key default gen_random_uuid(),
  warehouse_id  uuid not null references warehouses(id) on delete cascade,
  code          text not null,               -- 'Z1', 'SHOES', 'BULK'
  name          text not null,
  sequence      int  not null default 0,     -- order zones are visited
  unique (warehouse_id, code)
);

-- "Row" in the PRD. Called aisle_rows because ROW is a SQL keyword.
create table aisle_rows (
  id            uuid primary key default gen_random_uuid(),
  warehouse_id  uuid not null references warehouses(id) on delete cascade,
  zone_id       uuid references zones(id),
  code          text not null,               -- 'A', 'B', ... 'AA'
  sequence      int  not null,               -- walking order of rows (1 = nearest dispatch)
  unique (warehouse_id, code),
  unique (warehouse_id, sequence)
);

-- "Shelf" = a bay / section along a row. Shelf 01 is at the row's start.
create table shelves (
  id            uuid primary key default gen_random_uuid(),
  row_id        uuid not null references aisle_rows(id) on delete cascade,
  code          text not null,               -- '01', '02' ...
  sequence      int  not null,               -- position along the row
  side          text check (side in ('L','R')), -- optional: which side of the aisle
  unique (row_id, code)
);

-- "Bin" = one slot on a shelf (level / position).
create table bins (
  id             uuid primary key default gen_random_uuid(),
  warehouse_id   uuid not null references warehouses(id) on delete cascade,
  shelf_id       uuid references shelves(id) on delete cascade,  -- null for floor areas (receiving dock etc.)
  zone_id        uuid references zones(id),
  code           text not null,               -- 'A-02-04' (set by trigger from row/shelf/bin)
  bin_code       text not null,               -- '04' : the bin part only
  barcode        text not null unique,        -- system payload printed on the label: 'LOC:ADL:A-02-04'
  location_type  location_type not null default 'pick',
  is_active      boolean not null default true,
  is_pickable    boolean generated always as (location_type in ('pick','backfill') and is_active) stored,
  max_units      int check (max_units is null or max_units > 0),
  -- denormalised sort keys (maintained by trigger) so routing never needs joins
  row_seq        int,
  shelf_seq      int,
  bin_seq        int,
  shelf_side     text,
  created_at     timestamptz not null default now(),
  unique (warehouse_id, code)
);
create index bins_route_idx on bins (warehouse_id, row_seq, shelf_seq, bin_seq);

-- ---------------------------------------------------------------------------
-- Products
-- ---------------------------------------------------------------------------
create table products (
  id                 uuid primary key default gen_random_uuid(),
  sku                text not null unique,
  name               text not null,
  variant_title      text,                    -- 'M / Black'
  size               text,
  colour             text,
  shopify_variant_id bigint unique,
  cin7_product_id    text unique,
  weight_grams       int check (weight_grams is null or weight_grams >= 0),
  length_cm          numeric(6,1),
  width_cm           numeric(6,1),
  height_cm          numeric(6,1),
  image_url          text,
  velocity_class     char(1) check (velocity_class in ('A','B','C')),
  is_active          boolean not null default true,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- Every barcode that should resolve to a product (UPC/EAN, internal, carton).
create table product_barcodes (
  barcode        text primary key,
  product_id     uuid not null references products(id) on delete cascade,
  units_per_scan int  not null default 1 check (units_per_scan > 0),   -- e.g. a carton of 12
  is_primary     boolean not null default false
);
create index product_barcodes_product_idx on product_barcodes(product_id);

-- Stock policy per product (reorder engine)
create table product_stock_policy (
  product_id      uuid primary key references products(id) on delete cascade,
  safety_stock    int not null default 0 check (safety_stock >= 0),
  reorder_point   int not null default 0 check (reorder_point >= 0),
  reorder_qty     int not null default 0 check (reorder_qty >= 0),
  lead_time_days  int not null default 60
);

-- ---------------------------------------------------------------------------
-- Live inventory (SKU x Bin)
-- ---------------------------------------------------------------------------
create table bin_inventory (
  bin_id        uuid not null references bins(id) on delete restrict,
  product_id    uuid not null references products(id) on delete restrict,
  qty_on_hand   int  not null default 0 check (qty_on_hand >= 0),
  qty_allocated int  not null default 0 check (qty_allocated >= 0),   -- reserved by pick tasks
  updated_at    timestamptz not null default now(),
  primary key (bin_id, product_id),
  check (qty_allocated <= qty_on_hand)
);
create index bin_inventory_product_idx on bin_inventory(product_id);

-- Backfill rule: keep a pick bin between min and max for a product
create table replenishment_rules (
  id          uuid primary key default gen_random_uuid(),
  bin_id      uuid not null references bins(id) on delete cascade,
  product_id  uuid not null references products(id) on delete cascade,
  min_qty     int  not null check (min_qty >= 0),
  max_qty     int  not null check (max_qty > 0),
  is_active   boolean not null default true,
  unique (bin_id, product_id),
  check (max_qty > min_qty)
);

create table backfill_tasks (
  id             uuid primary key default gen_random_uuid(),
  rule_id        uuid references replenishment_rules(id) on delete set null,
  product_id     uuid not null references products(id),
  from_bin_id    uuid references bins(id),       -- suggested source (overstock); null = none found
  to_bin_id      uuid not null references bins(id),
  qty_suggested  int  not null check (qty_suggested > 0),
  qty_moved      int  not null default 0,
  status         backfill_status not null default 'open',
  assigned_to    uuid references staff(id),
  created_at     timestamptz not null default now(),
  completed_at   timestamptz
);
create unique index backfill_one_open_per_bin
  on backfill_tasks (to_bin_id, product_id) where status in ('open','in_progress');

-- ---------------------------------------------------------------------------
-- Inbound: Cin7 purchase orders (synced copy)
-- ---------------------------------------------------------------------------
create table purchase_orders (
  id             uuid primary key default gen_random_uuid(),
  cin7_id        text not null unique,          -- Cin7 Core purchase TaskID
  po_number      text not null,
  supplier_name  text,
  status         po_status not null default 'ordered',
  expected_date  date,
  warehouse_id   uuid references warehouses(id),
  raw            jsonb,                          -- last payload from Cin7
  synced_at      timestamptz not null default now(),
  created_at     timestamptz not null default now()
);
create index purchase_orders_open_idx on purchase_orders(status) where status in ('ordered','in_transit','partially_received');

create table purchase_order_lines (
  id            uuid primary key default gen_random_uuid(),
  po_id         uuid not null references purchase_orders(id) on delete cascade,
  product_id    uuid references products(id),   -- null until the SKU is matched
  sku           text not null,
  qty_ordered   int  not null check (qty_ordered >= 0),
  qty_received  int  not null default 0 check (qty_received >= 0),
  cin7_line_id  text,
  unique (po_id, sku)
);

-- ---------------------------------------------------------------------------
-- Outbound: orders (imported from ShipStation v2 "pending" shipments)
-- ---------------------------------------------------------------------------
create table waves (
  id            uuid primary key default gen_random_uuid(),
  warehouse_id  uuid not null references warehouses(id),
  name          text not null,                 -- 'AusPost Express 2pm cut-off'
  criteria      jsonb not null default '{}',    -- {carrier:'australia_post', service_like:'express', ship_by:'2026-11-03'}
  status        wave_status not null default 'planning',
  released_at   timestamptz,
  created_by    uuid references staff(id),
  created_at    timestamptz not null default now()
);

create table orders (
  id                       uuid primary key default gen_random_uuid(),
  warehouse_id             uuid not null references warehouses(id),
  order_number             text not null unique,   -- Shopify '#564704' -> '564704' (= ShipStation shipment_number)
  shipstation_shipment_id  text unique,            -- 'se-35477754'
  external_order_id        text,                   -- Shopify order id (= ShipStation external_shipment_id)
  channel                  text not null default 'shopify',
  status                   order_status not null default 'awaiting_pick',
  priority                 int  not null default 100,   -- lower = sooner
  requested_service        text,                   -- 'FREE EXPRESS SHIPPING - Authority to Leave'
  carrier_id               text,                   -- ShipStation carrier_id, e.g. 'se-1821526' (Australia Post)
  service_code             text,
  ship_by                  date,
  ship_to                  jsonb,
  customer_name            text,
  wave_id                  uuid references waves(id),
  hold_reason              text,
  ordered_at               timestamptz,
  imported_at              timestamptz not null default now(),
  raw                      jsonb
);
create index orders_status_idx on orders(status, priority, ordered_at);

create table order_lines (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references orders(id) on delete cascade,
  product_id     uuid references products(id),
  sku            text not null,
  name           text,
  qty_ordered    int  not null check (qty_ordered > 0),
  qty_allocated  int  not null default 0 check (qty_allocated >= 0),
  qty_picked     int  not null default 0 check (qty_picked >= 0),
  qty_packed     int  not null default 0 check (qty_packed >= 0),
  external_line_id text,                         -- ShipStation sales_order_item_id
  check (qty_allocated <= qty_ordered and qty_picked <= qty_allocated and qty_packed <= qty_picked)
);
create index order_lines_order_idx on order_lines(order_id);
create index order_lines_product_idx on order_lines(product_id);

-- ---------------------------------------------------------------------------
-- Carts, baskets, pick sessions
-- ---------------------------------------------------------------------------
create table carts (
  id            uuid primary key default gen_random_uuid(),
  warehouse_id  uuid not null references warehouses(id),
  code          text not null unique,           -- 'CART-03'
  barcode       text not null unique,           -- 'CART:03'
  basket_count  int  not null check (basket_count between 1 and 48),
  is_active     boolean not null default true
);

create table cart_baskets (
  id         uuid primary key default gen_random_uuid(),
  cart_id    uuid not null references carts(id) on delete cascade,
  position   int  not null,                     -- 1..basket_count
  barcode    text not null unique,              -- 'BSK:03-04'
  unique (cart_id, position)
);

create table pick_sessions (
  id              uuid primary key default gen_random_uuid(),
  warehouse_id    uuid not null references warehouses(id),
  method          pick_method not null,
  status          session_status not null default 'draft',
  route           route_strategy not null default 'snake',
  zone_id         uuid references zones(id),     -- zone picking: only bins in this zone
  wave_id         uuid references waves(id),
  cart_id         uuid references carts(id),
  assigned_to     uuid references staff(id),
  device_id       uuid references devices(id),
  created_by      uuid references staff(id),
  created_at      timestamptz not null default now(),
  started_at      timestamptz,
  completed_at    timestamptz
);
create index pick_sessions_status_idx on pick_sessions(status, assigned_to);
-- one active session per cart
create unique index pick_sessions_cart_active
  on pick_sessions(cart_id) where status in ('assigned','in_progress') and cart_id is not null;

-- Which order goes in which basket for this session
create table pick_session_orders (
  session_id  uuid not null references pick_sessions(id) on delete cascade,
  order_id    uuid not null references orders(id),
  basket_id   uuid references cart_baskets(id),   -- null for pure batch (sort at pack bench)
  primary key (session_id, order_id),
  unique (session_id, basket_id)
);

-- One stop on the route: go to bin X, pick N of SKU Y
create table pick_tasks (
  id            uuid primary key default gen_random_uuid(),
  session_id    uuid not null references pick_sessions(id) on delete cascade,
  sequence      int  not null,                  -- route order, 1..n
  bin_id        uuid not null references bins(id),
  product_id    uuid not null references products(id),
  qty_required  int  not null check (qty_required > 0),
  qty_picked    int  not null default 0 check (qty_picked >= 0),
  status        task_status not null default 'pending',
  started_at    timestamptz,
  completed_at  timestamptz,
  unique (session_id, sequence),
  check (qty_picked <= qty_required)
);

-- How a task's units are split between orders / baskets
create table pick_allocations (
  id             uuid primary key default gen_random_uuid(),
  task_id        uuid not null references pick_tasks(id) on delete cascade,
  order_line_id  uuid not null references order_lines(id),
  order_id       uuid not null references orders(id),
  basket_id      uuid references cart_baskets(id),
  qty            int  not null check (qty > 0),
  qty_picked     int  not null default 0,
  fill_order     int  not null,                 -- which allocation gets units first
  check (qty_picked between 0 and qty)
);
create index pick_allocations_task_idx on pick_allocations(task_id, fill_order);

-- ---------------------------------------------------------------------------
-- Pack & ship
-- ---------------------------------------------------------------------------
create table pack_stations (
  id                  uuid primary key default gen_random_uuid(),
  warehouse_id        uuid not null references warehouses(id),
  code                text not null unique,     -- 'BENCH-1'
  printnode_printer_id bigint,                  -- thermal label printer on this bench
  label_format        text not null default 'pdf' check (label_format in ('pdf','zpl')),
  device_id           uuid references devices(id)
);

create table package_types (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,           -- 'SATCHEL-A4', 'BOX-S'
  name          text not null,
  carrier_package_code text,                    -- e.g. 'aust_post_satchel'
  length_cm     numeric(6,1),
  width_cm      numeric(6,1),
  height_cm     numeric(6,1),
  tare_grams    int not null default 0,
  barcode       text unique                     -- scan the box to pick it
);

create table shipments (
  id                       uuid primary key default gen_random_uuid(),
  order_id                 uuid not null references orders(id),
  pack_station_id          uuid references pack_stations(id),
  packed_by                uuid references staff(id),
  status                   shipment_status not null default 'packing',
  package_type_id          uuid references package_types(id),
  weight_grams             int,
  length_cm                numeric(6,1),
  width_cm                 numeric(6,1),
  height_cm                numeric(6,1),
  shipstation_shipment_id  text,
  shipstation_label_id     text,
  carrier_id               text,
  service_code             text,
  tracking_number          text,
  label_url                text,
  shipment_cost            numeric(10,2),
  printnode_job_id         bigint,
  attempt_count            int not null default 0,
  last_error               text,
  started_at               timestamptz not null default now(),
  packed_at                timestamptz,
  labelled_at              timestamptz,
  shipped_at               timestamptz
);
create index shipments_order_idx on shipments(order_id);
-- one open (unfinished) box per order at a time
create unique index shipments_one_open_per_order
  on shipments(order_id) where status in ('packing','packed','label_requested');

create table shipment_items (
  shipment_id    uuid not null references shipments(id) on delete cascade,
  order_line_id  uuid not null references order_lines(id),
  qty            int  not null check (qty > 0),
  primary key (shipment_id, order_line_id)
);

-- ---------------------------------------------------------------------------
-- Audit: ledger, scans, integration log
-- ---------------------------------------------------------------------------
create table inventory_transactions (
  id            bigint generated always as identity primary key,
  occurred_at   timestamptz not null default now(),
  txn_type      txn_type not null,
  product_id    uuid not null references products(id),
  bin_id        uuid references bins(id),
  qty_delta     int  not null,                  -- + into bin, - out of bin
  qty_after     int,                            -- bin balance after this movement
  move_group    uuid,                           -- links move_out + move_in pairs
  ref_type      text,                           -- 'po_line','pick_task','backfill_task','adjustment','shipment'
  ref_id        uuid,
  staff_id      uuid references staff(id),
  device_id     uuid references devices(id),
  reason        text,
  metadata      jsonb not null default '{}'
);
create index inv_txn_product_time_idx on inventory_transactions(product_id, occurred_at desc);
create index inv_txn_type_time_idx on inventory_transactions(txn_type, occurred_at desc);
create index inv_txn_staff_time_idx on inventory_transactions(staff_id, occurred_at desc);

create table scan_events (
  id            bigint generated always as identity primary key,
  occurred_at   timestamptz not null default now(),
  context       scan_context not null,
  result        scan_result not null,
  scanned_value text not null,
  expected_product_id uuid references products(id),
  scanned_product_id  uuid references products(id),
  session_id    uuid references pick_sessions(id) on delete set null,
  task_id       uuid references pick_tasks(id) on delete set null,
  shipment_id   uuid references shipments(id) on delete set null,
  staff_id      uuid references staff(id),
  device_id     uuid references devices(id)
);
create index scan_events_staff_time_idx on scan_events(staff_id, occurred_at desc);

create table integration_log (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  system       text not null check (system in ('shipstation','cin7','printnode','shopify')),
  action       text not null,                   -- 'get_shipment','update_shipment','create_label','print'
  ref_id       uuid,
  http_status  int,
  ok           boolean not null,
  request      jsonb,
  response     jsonb,
  duration_ms  int
);
create index integration_log_ref_idx on integration_log(ref_id);

create table sync_state (
  system         text primary key,              -- 'shipstation_orders','cin7_pos'
  cursor         text,
  last_run_at    timestamptz,
  last_ok_at     timestamptz,
  last_error     text
);
