#!/usr/bin/env python3
"""
Load SkuVault products + stock-by-location into the WMS.

    WMS_IMPORT_TOKEN=xxxx python3 scripts/import_skuvault_products_stock.py \
        ProductDetails-....csv InventoryQuantitiesByLocation-....csv

Products: every SkuVault SKU (Code + Alternate Codes + Alternate SKU become scannable barcodes).
          Marked active if it has stock, stock incoming, or was modified in the last 2 years.
Stock:    each SKU x location is SET to SkuVault's quantity (logged as a cycle count),
          so re-running right before cutover simply syncs to SkuVault's latest numbers.
Safe to re-run.
"""
import csv, json, os, sys, urllib.request
from datetime import datetime, timedelta

BASE = "https://nklbnykqftzkbqbuammg.supabase.co/rest/v1/rpc/"
ANON = os.environ.get("WMS_ANON_KEY", "sb_publishable_gq6n7-kpJPZUwxGuQ9-nfQ_DyjeWSHS")
TOKEN = os.environ["WMS_IMPORT_TOKEN"]
TO_GRAMS = {"kgs": 1000, "kg": 1000, "g": 1, "lbs": 453.592, "lb": 453.592, "oz": 28.3495}

def rpc(fn, payload):
    req = urllib.request.Request(BASE + fn, data=json.dumps(payload).encode(), method="POST", headers={
        "apikey": ANON, "Authorization": f"Bearer {ANON}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.loads(resp.read())

def num(s):
    try: return float(str(s).replace("$", "").replace(",", "") or 0)
    except ValueError: return 0.0

products_csv, stock_csv = sys.argv[1], sys.argv[2]
cutoff = datetime.now() - timedelta(days=730)

# ---- products --------------------------------------------------------------
rows = []
for p in csv.DictReader(open(products_csv, newline="", encoding="utf-8-sig")):
    try: modified = datetime.strptime(p["Modified Date"], "%m/%d/%Y %I:%M %p")
    except ValueError: modified = datetime(2000, 1, 1)
    active = num(p["Quantity On Hand"]) > 0 or num(p["Quantity Incoming"]) > 0 or modified > cutoff
    w = num(p["Weight Value"]) * TO_GRAMS.get(p["Weight Unit"].strip().lower(), 0)
    title = p["Title"].strip()
    base = dict(sku=p["SKU"].strip(), name=title,
                variant_title=title.rsplit(" - ", 1)[-1] if " - " in title else None,
                weight_grams=round(w) if w else None, is_active=active)
    codes = [c.strip() for c in (p["Code"], p["Alternate Code 1"], p["Alternate Code 2"], p["Alternate Sku 1"]) if c.strip()]
    for c in codes or [""]:
        rows.append({**base, "barcode": c})

print(f"Products: {len({r['sku'] for r in rows})} SKUs, {sum(1 for r in rows if r['barcode'])} barcodes")
tot = 0
for i in range(0, len(rows), 1500):
    res = rpc("wms_import_products", {"p_rows": rows[i:i + 1500], "p_token": TOKEN})
    tot += res["products"]
    print(f"  products {min(i + 1500, len(rows))}/{len(rows)} rows sent")

# ---- stock -----------------------------------------------------------------
stock = [dict(sku=r["SKU"].strip(), location=r["Location"].strip(), qty=int(num(r["Quantity"])))
         for r in csv.DictReader(open(stock_csv, newline="", encoding="utf-8-sig")) if r["Warehouse"] == "TWLHQ"]
print(f"Stock: {len(stock)} SKU-in-location rows, {sum(s['qty'] for s in stock)} units")
changed, skipped = 0, []
for i in range(0, len(stock), 1000):
    res = rpc("wms_import_stock", {"p_warehouse_code": "TWLHQ", "p_rows": stock[i:i + 1000],
                                   "p_reason": "Opening balance from SkuVault export", "p_token": TOKEN})
    changed += res["changed"]; skipped += res["skipped"]
    print(f"  stock {min(i + 1000, len(stock))}/{len(stock)} rows sent")
print(f"Done. {changed} bin balances set, {len(skipped)} skipped")
for s in skipped[:20]: print("  skipped:", s)
