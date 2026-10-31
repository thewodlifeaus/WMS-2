// =============================================================================
// Edge Function: sync-cin7-pos   (run every 30 min via pg_cron)
// -----------------------------------------------------------------------------
// Copies open Cin7 Core purchase orders into purchase_orders / _lines so the
// tablet can receive against them.
// Cin7 Core API: https://dearinventory.docs.apiary.io  (rate limit 60 calls/min)
// Secrets: CIN7_ACCOUNT_ID, CIN7_APP_KEY
// NOTE: verify field names against one real PO on first run (logged to
//       integration_log) - Cin7 Simple/Omni use a different API.
// =============================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const BASE = "https://inventory.dearsystems.com/ExternalApi/v2";
const hdr = {
  "api-auth-accountid": Deno.env.get("CIN7_ACCOUNT_ID")!,
  "api-auth-applicationkey": Deno.env.get("CIN7_APP_KEY")!,
  "Content-Type": "application/json",
};
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Cin7 status -> WMS status
const STATUS: Record<string, string> = {
  DRAFT: "draft", ORDERING: "draft", ORDERED: "ordered", AUTHORISED: "ordered",
  RECEIVING: "partially_received", "PARTIALLY RECEIVED": "partially_received",
  RECEIVED: "received", COMPLETED: "closed", VOIDED: "cancelled",
};

async function get(path: string) {
  const r = await fetch(`${BASE}${path}`, { headers: hdr });
  if (r.status === 429) { await sleep(60_000); return get(path); }
  if (!r.ok) throw new Error(`Cin7 ${r.status} ${path}: ${await r.text()}`);
  return r.json();
}

Deno.serve(async () => {
  const { data: wh } = await db.from("warehouses").select("id").order("created_at").limit(1).single();
  let synced = 0;
  try {
    const since = new Date(Date.now() - 120 * 864e5).toISOString().slice(0, 10);
    for (let page = 1; ; page++) {
      const list = await get(`/purchaseList?Page=${page}&Limit=100&UpdatedSince=${since}`);
      const rows = list.PurchaseList ?? [];
      for (const p of rows) {
        const status = STATUS[(p.Status ?? "").toUpperCase()] ?? "ordered";
        if (["draft", "cancelled", "closed"].includes(status)) continue;

        const detail = await get(`/purchase?ID=${p.ID}`); await sleep(1100);   // stay under 60/min
        await db.from("integration_log").insert({ system: "cin7", action: "get_purchase", ok: true, response: detail });

        const { data: po } = await db.from("purchase_orders").upsert({
          cin7_id: p.ID, po_number: p.OrderNumber, supplier_name: p.Supplier,
          expected_date: p.RequiredBy?.slice(0, 10) ?? null, warehouse_id: wh!.id, raw: detail,
          synced_at: new Date().toISOString(),
        }, { onConflict: "cin7_id" }).select("id,status").single();
        // never move a PO backwards once the WMS has started receiving it
        if (po && !["partially_received", "received"].includes(po.status)) {
          await db.from("purchase_orders").update({ status }).eq("id", po.id);
        }

        const lines = (detail.Order?.Lines ?? []) as { SKU: string; Quantity: number; ProductID: string }[];
        const skus = lines.map((l) => l.SKU);
        const { data: prods } = await db.from("products").select("id,sku").in("sku", skus);
        const bySku = new Map((prods ?? []).map((x) => [x.sku, x.id]));
        // upsert keeps qty_received (WMS-owned) untouched
        await db.from("purchase_order_lines").upsert(lines.map((l) => ({
          po_id: po!.id, sku: l.SKU, qty_ordered: Math.round(l.Quantity), product_id: bySku.get(l.SKU) ?? null,
        })), { onConflict: "po_id,sku", ignoreDuplicates: false });
        synced++;
      }
      if (rows.length < 100) break;
    }
    await db.from("sync_state").upsert({ system: "cin7_pos", last_run_at: new Date().toISOString(), last_ok_at: new Date().toISOString(), last_error: null });
    return Response.json({ ok: true, synced });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await db.from("sync_state").upsert({ system: "cin7_pos", last_run_at: new Date().toISOString(), last_error: msg });
    return Response.json({ ok: false, error: msg }, { status: 500 });
  }
});
