// =============================================================================
// Edge Function: pack-and-ship   (called by the Pack desk screen)
// -----------------------------------------------------------------------------
// POST { shipment_id, action?: "ship" | "reprint", force?: boolean }
//   ship    : packed box -> ShipStation label -> PDF back to the desk to print
//   reprint : download the existing label again
//
// TEST MODE (secret TEST_LABELS not set to "false"):
//   A free test label is made from a COPY of the order. The real ShipStation
//   order is never changed, so SkuVault and ShipStation carry on as normal.
// LIVE MODE (TEST_LABELS = "false"):
//   The real ShipStation order gets the exact weight/box/service, then the label
//   is bought. ShipStation marks it shipped and tells Shopify, as today.
//
// Secrets: SHIPSTATION_API_KEY, TEST_LABELS. SUPABASE_* are injected.
// =============================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const SS_BASE = "https://api.shipstation.com";
const TEST_LABELS = (Deno.env.get("TEST_LABELS") ?? "true") !== "false";
const KEY = Deno.env.get("SHIPSTATION_API_KEY")!;
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// Fallback service when ShipStation hasn't set one (Australia Post, TWL account)
const AUSPOST = "se-1821526";
function chooseService(requested: string | null, countryCode: string) {
  const r = (requested ?? "").toLowerCase();
  if (countryCode !== "AU") return null; // international: set in ShipStation
  if (r.includes("express")) return { carrier_id: AUSPOST, service_code: "au_post_express_post_signature_3J35" };
  return { carrier_id: AUSPOST, service_code: "au_post_parcel_post_signature_3D85" };
}

function encodeBase64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

async function logCall(action: string, refId: string, ok: boolean, status: number | null,
                       request: unknown, response: unknown, started: number) {
  await db.from("integration_log").insert({
    system: "shipstation", action, ref_id: refId, ok, http_status: status, request, response,
    duration_ms: Date.now() - started,
  });
}

async function ss(method: string, path: string, refId: string, action: string, body?: unknown) {
  const started = Date.now();
  const res = await fetch(`${SS_BASE}${path}`, {
    method, headers: { "API-Key": KEY, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data: any = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = { raw: text.slice(0, 500) }; }
  // keep addresses out of the log
  await logCall(action, refId, res.ok, res.status, body ? { path, keys: Object.keys(body as object) } : { path },
                res.ok ? { label_id: data?.label_id, shipment_id: data?.shipment_id, status: data?.status ?? data?.shipment_status } : data, started);
  if (!res.ok) {
    const msg = data?.errors?.map((e: { message: string }) => e.message).join("; ") ?? text.slice(0, 300);
    throw new Error(`ShipStation ${action} failed (${res.status}): ${msg}`);
  }
  return data;
}

async function downloadPdf(url: string) {
  const file = await fetch(url, { headers: { "API-Key": KEY } });
  if (!file.ok) throw new Error(`Label download failed (${file.status})`);
  return encodeBase64(new Uint8Array(await file.arrayBuffer()));
}

// Fields ShipStation returns on GET but rejects / ignores on write
const READ_ONLY = ["shipment_id", "created_at", "modified_at", "shipment_status", "items", "tags",
  "sales_order_ids", "batch_ids", "zone", "amount_paid", "shipping_paid", "tax_paid", "store_id"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  // ---- caller must be signed-in floor staff (not the TV login) ------------
  const jwt = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
  const { data: auth } = await db.auth.getUser(jwt);
  if (!auth?.user) return json({ ok: false, error: "NOT_SIGNED_IN" }, 401);
  const { data: staff } = await db.from("staff").select("id, role").eq("id", auth.user.id).eq("is_active", true).maybeSingle();
  if (!staff || staff.role === "display") return json({ ok: false, error: "NOT_STAFF" }, 403);

  const { shipment_id, action = "ship", force = false } = await req.json().catch(() => ({}));
  if (!shipment_id) return json({ ok: false, error: "shipment_id required" }, 400);

  // ---- reprint ---------------------------------------------------------------
  if (action === "reprint") {
    const { data: sh } = await db.from("shipments").select("id, label_url, tracking_number, test_label, orders(order_number)")
      .eq("id", shipment_id).maybeSingle();
    if (!sh?.label_url) return json({ ok: false, error: "NO_LABEL_YET" }, 404);
    try {
      return json({ ok: true, reprint: true, tracking_number: sh.tracking_number, test_label: sh.test_label,
                    order_number: (sh as any).orders?.order_number, label_pdf: await downloadPdf(sh.label_url) });
    } catch (e) { return json({ ok: false, error: e instanceof Error ? e.message : String(e) }, 502); }
  }

  // ---- lock the shipment (packed | failed -> label_requested) ------------
  const { data: sh } = await db.from("shipments")
    .update({ status: "label_requested" })
    .eq("id", shipment_id).in("status", ["packed", "failed"])
    .select("*, orders(*), package_types(*)")
    .maybeSingle();
  if (!sh) return json({ ok: false, error: "NOT_READY", hint: "Scan every item first, or the label is already being made." }, 409);
  const order = sh.orders;

  try {
    let ssShip = order.shipstation_shipment_id
      ? await ss("GET", `/v2/shipments/${order.shipstation_shipment_id}`, sh.id, "get_shipment")
      : await ss("GET", `/v2/shipments/external_shipment_id/${encodeURIComponent(order.external_order_id)}`, sh.id, "get_shipment_by_external_id");

    if (ssShip.shipment_status === "cancelled") throw new Error("ORDER_CANCELLED: cancelled in ShipStation/Shopify. Do not ship.");
    const alreadyLabelled = ssShip.shipment_status === "label_purchased";
    if (alreadyLabelled && !force) {
      await db.from("shipments").update({ status: "packed" }).eq("id", sh.id);   // unlock, nothing bought
      return json({ ok: false, error: "ALREADY_LABELLED",
        message: "This order already has a label in ShipStation. Making another creates a second label." }, 409);
    }

    const service = ssShip.carrier_id && ssShip.service_code
      ? { carrier_id: ssShip.carrier_id, service_code: ssShip.service_code }
      : (sh.carrier_id && sh.service_code ? { carrier_id: sh.carrier_id, service_code: sh.service_code }
        : chooseService(order.requested_service ?? ssShip.requested_shipment_service, ssShip.ship_to?.country_code));
    if (!service) throw new Error("NEEDS_SERVICE: no carrier/service on this order (international?). Set it in ShipStation, then try again.");

    const base: Record<string, unknown> = Object.fromEntries(Object.entries(ssShip).filter(([k]) => !READ_ONLY.includes(k)));
    // ShipStation rejects ship_from + warehouse_id together: the warehouse wins
    if (base.warehouse_id) delete base.ship_from;
    // Box: a WMS box type if the packer chose one, otherwise keep ShipStation's own package
    // (its carrier package code + dimensions) and only replace the weight, like SkuVault does.
    const ssPkg = (ssShip.packages ?? [])[0] ?? {};
    const ssDims = ssPkg.dimensions && ssPkg.dimensions.length > 0 ? ssPkg.dimensions : null;
    const packages = [{
      package_code: sh.package_types?.carrier_package_code ?? ssPkg.package_code ?? "package",
      weight: { value: sh.weight_grams, unit: "gram" },
      dimensions: sh.length_cm
        ? { unit: "centimeter", length: Number(sh.length_cm), width: Number(sh.width_cm), height: Number(sh.height_cm) }
        : (ssDims ?? { unit: "centimeter", length: 10, width: 10, height: 10 }),
      label_messages: { reference1: `#${order.order_number}`, reference2: null, reference3: null },
    }];
    const labelOpts = { label_format: "pdf", label_layout: "4x6", label_download_type: "url" };

    let label;
    if (TEST_LABELS || alreadyLabelled) {
      // a copy of the order: the real ShipStation order is left untouched
      // only the fields a label needs (no order ids, so ShipStation sees a brand-new shipment)
      const keep = ["ship_to", "ship_from", "warehouse_id", "return_to", "confirmation", "customs",
                    "advanced_options", "insurance_provider", "is_return", "ship_date"];
      const copy: Record<string, unknown> = { ...service, packages };
      for (const k of keep) if (base[k] != null) copy[k] = base[k];
      label = await ss("POST", `/v2/labels`, sh.id, TEST_LABELS ? "create_test_label" : "create_extra_label",
                       { shipment: copy, test_label: TEST_LABELS, ...labelOpts });
    } else {
      ssShip = await ss("PUT", `/v2/shipments/${ssShip.shipment_id}`, sh.id, "update_shipment", { ...base, ...service, packages });
      label = await ss("POST", `/v2/labels/shipment/${ssShip.shipment_id}`, sh.id, "create_label", { test_label: false, ...labelOpts });
    }

    // label exists from here on: record it before anything else can fail
    const pdfUrl = label.label_download?.pdf ?? label.label_download?.href;
    await db.rpc("wms_record_label", {
      p_shipment_id: sh.id, p_ok: true,
      p_ss_shipment_id: ssShip.shipment_id, p_label_id: label.label_id,
      p_tracking: label.tracking_number, p_label_url: pdfUrl ?? null,
      p_cost: label.shipment_cost?.amount ?? null,
      p_carrier_id: label.carrier_id, p_service_code: label.service_code, p_test: TEST_LABELS,
    });

    let labelPdf: string | null = null, printError: string | null = null;
    try { if (pdfUrl) labelPdf = await downloadPdf(pdfUrl); } catch (e) { printError = e instanceof Error ? e.message : String(e); }

    return json({
      ok: true, order_number: order.order_number, tracking_number: label.tracking_number,
      service: label.service_code, cost: label.shipment_cost, test_label: TEST_LABELS,
      label_pdf: labelPdf, print_error: printError,
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await db.rpc("wms_record_label", { p_shipment_id: sh.id, p_ok: false, p_error: msg });
    return json({ ok: false, error: msg }, 502);
  }
});
