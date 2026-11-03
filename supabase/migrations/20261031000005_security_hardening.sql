-- =============================================================================
-- TWL WMS  |  Migration 005  |  Security advisor fixes
--   * pin search_path on wms_route_key
--   * internal helpers and trigger functions are not callable from the apps
--     (they still run: triggers and SECURITY DEFINER callers don't need the grant)
-- The remaining "signed-in users can execute SECURITY DEFINER" warnings are
-- intentional: those wms_* functions ARE the app API, and each one checks
-- wms__require_staff() / wms_has_role() itself.
-- =============================================================================
alter function wms_route_key(route_strategy, int, int, int, text, int) set search_path = public;

revoke execute on function wms__require_staff()          from authenticated;
revoke execute on function wms__pack_view(uuid)          from authenticated;
revoke execute on function wms__check_backfill()         from authenticated;
revoke execute on function wms__bins_before_write()      from authenticated;
revoke execute on function wms__topology_changed()       from authenticated;
revoke execute on function wms__products_after_insert()  from authenticated;
