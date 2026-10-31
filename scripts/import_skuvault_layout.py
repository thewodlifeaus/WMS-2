#!/usr/bin/env python3
"""
Load the SkuVault location export into the WMS (rows, shelves, bins).

    WMS_IMPORT_TOKEN=xxxx python3 scripts/import_skuvault_layout.py ~/Downloads/edit_warehouse_locations_....csv

Mapping (mirrors how SkuVault treats each location today):
  Reserved = Yes   -> reserved  (counted, never picked)
  Backstock = Yes  -> backfill  (overstock: picked only after pick bins)
  otherwise        -> pick
Codes are kept exactly as in SkuVault, so the labels already on the racking keep scanning.
Re-running is safe: it updates types and adds new bins, it never deletes.
"""
import csv, json, os, re, sys, urllib.request

URL = "https://nklbnykqftzkbqbuammg.supabase.co/rest/v1/rpc/wms_import_layout"
ANON = os.environ.get("WMS_ANON_KEY", "sb_publishable_gq6n7-kpJPZUwxGuQ9-nfQ_DyjeWSHS")
TOKEN = os.environ["WMS_IMPORT_TOKEN"]
WAREHOUSE = "TWLHQ"

rows = list(csv.DictReader(open(sys.argv[1], newline="")))
three = re.compile(r"^([A-Z]+)-(\d+)-(\d+)$")
two = re.compile(r"^([A-Z]+)-(\d+)$")

def row_key(code):           # A, C, D, EA..EM, EZA.., FA.., ..., SA.., T
    return (code[0], len(code), code)

parsed = []
for r in rows:
    loc = r["Location"].strip()
    typ = "reserved" if r["Reserved"] == "Yes" else "backfill" if r["Backstock"] == "Yes" else "pick"
    m3, m2 = three.match(loc), two.match(loc)
    if m3:
        parsed.append(dict(code=loc, row=m3[1], shelf=m3[2], bin=m3[3], type=typ))
    elif m2:
        parsed.append(dict(code=loc, row=m2[1], shelf=m2[2], bin="", type=typ))
    else:                    # 0-RECEIVE, Z-TAGDESK ... floor / desk areas
        parsed.append(dict(code=loc, type=typ, zone="DOCK", zone_name="Dock & desks", zone_seq=0))

row_codes = sorted({p["row"] for p in parsed if "row" in p}, key=row_key)
row_seq = {c: i + 1 for i, c in enumerate(row_codes)}
zone_seq = {z: i + 1 for i, z in enumerate(sorted({c[0] for c in row_codes}))}
for p in parsed:
    if "row" in p:
        z = p["row"][0]
        p.update(row_seq=row_seq[p["row"]], zone=z, zone_name=f"Aisle {z}", zone_seq=zone_seq[z])

def post(batch):
    body = json.dumps({"p_warehouse_code": WAREHOUSE, "p_rows": batch, "p_token": TOKEN}).encode()
    req = urllib.request.Request(URL, data=body, method="POST", headers={
        "apikey": ANON, "Authorization": f"Bearer {ANON}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read())

done = 0
for i in range(0, len(parsed), 400):
    res = post(parsed[i:i + 400])
    done += res["rows"]
    print(f"  {done}/{len(parsed)} locations loaded")
print(f"Done: {len(parsed)} locations, {len(row_codes)} rows, {len(zone_seq)} aisles + dock")
