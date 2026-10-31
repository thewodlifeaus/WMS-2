-- Typed tote numbers (migration 022). Rolls itself back.
begin;
do $$
begin
  insert into cart_baskets(barcode, kind) values ('XBIN7406', 'tote'), ('XINV7001', 'tote');
  assert (wms__find_tote('7406')).barcode = 'XBIN7406', 'number only';
  assert (wms__find_tote('xbin7406')).barcode = 'XBIN7406', 'lower case';
  assert (wms__find_tote('xinv7001')).barcode = 'XINV7001', 'prefix + number';
  assert (wms__find_tote('XBIN7001')).barcode is null, 'prefix must match';
  assert (wms__find_tote('99999')).barcode is null, 'unknown';
  raise notice 'TOTE TYPE-IN TEST PASSED';
end $$;
rollback;
