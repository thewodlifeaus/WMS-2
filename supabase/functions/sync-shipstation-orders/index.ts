// =============================================================================
// Edge Function: sync-shipstation-orders   (run every 5 min via pg_cron)
// -----------------------------------------------------------------------------
// ShipStation is already receiving every Shopify order, so it is the order
// source for the WMS: each "pending" ShipStation v2 shipment = one order to pick.
//   - new pending shipments  -> orders + order_lines (SKU matched to products)
//   - shipments cancelled in ShipStation -> WMS order cancelled (if not shipped)
// Bundles: ShipStation items carry the component SKU; bundle_sku is ignored.
// =============================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const SS = "https://api.shipstation.com/v2";
const hdr = { "API-Key": Deno.env.get("SHIPSTATION_API_KEY")! };

type SsItem = { sku: string | null; name: string; quantity: number; sales_order_item_id: string };
type SsShipment = {
  shipment_id: string; shipment_number: string; external_shipment_id: string; shipment_status: string;
  carrier_id: string | null; service_code: string | null; requested_shipment_service: string | null;
  ship_by_date: string | null; created_at: string; modified_at: string;
  ship_to: { name: string; country_code: string } & Record<string, unknown>; items: SsItem[];
};

async function page(status: string, since: string, n: number) {
  const q = new URLSearchParams({
    shipment_status: status, modified_at_start: since, page: String(n), page_size: "100",
    sort_by: "modified_at", sort_dir: "asc",
  });
  const r = await fetch(`${SS}/shipments?${q}`, { headers: hdr });
  if (!r.ok) throw new Error(`ShipStation ${r.status}: ${await r.text()}`);
  return await r.json() as { shipments: SsShipment[]; pages: number };
}

Deno.serve(async () => {
  const { data: state } = await db.from("sync_state").select("*").eq("system", "shipstation_orders").maybeSingle();
  // first run: last 3 days only (avoid importing years of history)
  const since = state?.cursor ?? new Date(Date.now() - 3 * 864e5).toISOString();
  const { data: wh } = await db.from("warehouses").select("id").order("created_at").limit(1).single();
  let newest = since, imported = 0, cancelled = 0, unknownSkus = new Set<string>();

  try {
    // ---- pending -> import -------------------------------------------------
    for (let n = 1, pages = 1; n <= pages; n++) {
      const res = await page("pending", since, n);
      pages = res.pages;
      for (const s of res.shipments) {
        if (s.modified_at > newest) newest = s.modified_at;
        const { data: existing } = await db.from("orders").select("id,status").eq("shipstation_shipment_id", s.shipment_id).maybeSingle();
        if (existing) continue; // already imported; WMS owns it from here

        const lines = s.items.filter((i) => i.sku && i.quantity > 0);
        if (!lines.length) continue;
        const skus = [...new Set(lines.map((i) => i.sku!))];
        const { data: prods } = await db.from("products").select("id,sku").in("sku", skus);
        const bySku = new Map((prods ?? []).map((p) => [p.sku, p.id]));

        const { data: order, error } = await db.from("orders").insert({
          warehouse_id: wh!.id,
          order_number: s.shipment_number,
          shipstation_shipment_id: s.shipment_id,
          external_order_id: s.external_shipment_id,
          requested_service: s.requested_shipment_service,
          carrier_id: s.carrier_id, service_code: s.service_code,
          ship_by: s.ship_by_date?.slice(0, 10) ?? null,
          ship_to: s.ship_to, customer_name: s.ship_to?.name,
          priority: /express/i.test(s.requested_shipment_service ?? "") ? 50 : 100,
          ordered_at: s.created_at, raw: s,
          status: lines.every((l) => bySku.has(l.sku!)) ? "awaiting_pick" : "on_hold",
          hold_reason: lines.every((l) => bySku.has(l.sku!)) ? null : "Unknown SKU - add product to WMS",
        }).select("id").single();
        if (error) { console.error(s.shipment_number, error.message); continue; }

        // merge duplicate SKUs on one order
        const qty = new Map<string, { q: number; name: string; ext: string }>();
        for (const l of lines) {
          const cur = qty.get(l.sku!);
          qty.set(l.sku!, { q: (cur?.q ?? 0) + l.quantity, name: l.name, ext: l.sales_order_item_id });
        }
        await db.from("order_lines").insert([...qty].map(([sku, v]) => {
          if (!bySku.has(sku)) unknownSkus.add(sku);
          return { order_id: order.id, sku, name: v.name, qty_ordered: v.q, product_id: bySku.get(sku) ?? null, external_line_id: v.ext };
        }));
        imported++;
      }
    }

    // ---- cancelled in ShipStation -> cancel in WMS if not yet shipped -------
    for (let n = 1, pages = 1; n <= pages; n++) {
      const res = await page("cancelled", since, n);
      pages = res.pages;
      const ids = res.shipments.map((s) => s.shipment_id);
      if (ids.length) {
        const { data } = await db.from("orders")
          .update({ status: "cancelled", hold_reason: "Cancelled in ShipStation/Shopify" })
          .in("shipstation_shipment_id", ids).in("status", ["awaiting_pick", "on_hold"]).select("id");
        cancelled += data?.length ?? 0;
        // orders already allocated/picking are flagged for a supervisor instead of silently cancelled
        await db.from("orders").update({ hold_reason: "CANCELLED IN SHOPIFY - pull from cart" })
          .in("shipstation_shipment_id", ids).in("status", ["allocated", "picking", "picked", "packing"]);
      }
    }

    await db.from("sync_state").upsert({ system: "shipstation_orders", cursor: newest, last_run_at: new Date().toISOString(),
      last_ok_at: new Date().toISOString(), last_error: null });
    return Response.json({ ok: true, imported, cancelled, unknown_skus: [...unknownSkus] });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await db.from("sync_state").upsert({ system: "shipstation_orders", last_run_at: new Date().toISOString(), last_error: msg });
    return Response.json({ ok: false, error: msg }, { status: 500 });
  }
});
