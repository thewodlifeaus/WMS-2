-- TWL WMS | Migration 006 | 'reserved' locations (SkuVault "Reserved = Yes")
-- Stock in a reserved bin counts as on hand but is never picked or used as a
-- backfill source (eg upper pallet levels, 0-RECEIVE2 holding stock).
alter type location_type add value if not exists 'reserved';
