// =============================================================================
// Edge Function: pack-and-ship
// -----------------------------------------------------------------------------
// Called by the Desktop pack bench app AFTER wms_pack_complete() returns ok.
//
//   1. load the packed shipment (weight, dims, box) from Supabase
//   2. find the matching ShipStation v2 shipment (the imported Shopify order)
//   3. PUT the exact weight / dimensions / carrier+service onto it
//   4. POST /v2/labels/shipment/{id}  -> buys the label. ShipStation marks the
//      order shipped and notifies Shopify (per your store notification setting)
//   5. download the label and send it to the bench's thermal printer (PrintNode)
//   6. record tracking/cost and close the order in the WMS
//
// Secrets (Supabase dashboard > Edge Functions > Secrets):
//   SHIPSTATION_API_KEY   ShipStation v2 API key (Settings > Account > API Settings)
//   PRINTNODE_API_KEY     PrintNode API key
//   TEST_LABELS           "true" while testing -> no real postage is bought
// SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are injected automatically.
// =============================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const SS_BASE = "https://api.shipstation.com";
const PN_BASE = "https://api.printnode.com";
const TEST_LABELS = (Deno.env.get("TEST_LABELS") ?? "true") === "true";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// ---------------------------------------------------------------------------
// Carrier/service fallback when ShipStation automation hasn't set one.
// IDs come from TWL's ShipStation account (GET /v2/carriers, 31 Oct 2026).
// Confirm these with the team before going live.
// ---------------------------------------------------------------------------
const AUSPOST = "se-1821526";
function chooseService(requested: string | null, countryCode: string) {
  const r = (requested ?? "").toLowerCase();
  if (countryCode !== "AU") return null; // international: must be set in ShipStation / by a human
  if (r.includes("express")) return { carrier_id: AUSPOST, service_code: "au_post_express_post_signature_3J35" };
  return { carrier_id: AUSPOST, service_code: "au_post_parcel_post_signature_3D85" };
}

// bytes -> base64 in 32KB chunks (spreading a whole PDF overflows the stack)
function encodeBase64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

// ---------------------------------------------------------------------------
async function logCall(action: string, refId: string, ok: boolean, status: number | null,
                       request: unknown, response: unknown, started: number, system = "shipstation") {
  await db.from("integration_log").insert({
    system, action, ref_id: refId, ok, http_status: status, request, response,
    duration_ms: Date.now() - started,
  });
}

async function ss(method: string, path: string, refId: string, action: string, body?: unknown) {
  const started = Date.now();
  const res = await fetch(`${SS_BASE}${path}`, {
    method,
    headers: { "API-Key": Deno.env.get("SHIPSTATION_API_KEY")!, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  await logCall(action, refId, res.ok, res.status, body ?? { path }, data, started);
  if (!res.ok) {
    const msg = data?.errors?.map((e: { message: string }) => e.message).join("; ") ?? text;
    throw new Error(`ShipStation ${action} failed (${res.status}): ${msg}`);
  }
  return data;
}

// Fields ShipStation returns on GET but rejects / ignores on PUT
const READ_ONLY = ["shipment_id", "created_at", "modified_at", "shipment_status", "items", "tags",
  "sales_order_ids", "batch_ids", "zone", "amount_paid", "shipping_paid", "tax_paid", "store_id"];

// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  // ---- 0. caller must be logged-in WMS staff ----------------------------
  const jwt = req.headers.get("Authorization")?.replace("Bearer ", "");
  const { data: auth } = await db.auth.getUser(jwt ?? "");
  if (!auth?.user) return json({ ok: false, error: "UNAUTHENTICATED" }, 401);
  const { data: staff } = await db.from("staff").select("id").eq("id", auth.user.id).eq("is_active", true).maybeSingle();
  if (!staff) return json({ ok: false, error: "NOT_STAFF" }, 403);

  const { shipment_id } = await req.json();
  if (!shipment_id) return json({ ok: false, error: "shipment_id required" }, 400);

  // ---- 1. lock the shipment (packed|failed -> label_requested) ----------
  const { data: sh } = await db.from("shipments")
    .update({ status: "label_requested" })
    .eq("id", shipment_id).in("status", ["packed", "failed"])
    .select("*, orders(*), package_types(*), pack_stations(*)")
    .maybeSingle();
  if (!sh) return json({ ok: false, error: "SHIPMENT_NOT_READY (must be packed, or already in progress)" }, 409);

  const order = sh.orders;
  try {
    // ---- 2. find the ShipStation shipment for this order ------------------
    let ssShip = order.shipstation_shipment_id
      ? await ss("GET", `/v2/shipments/${order.shipstation_shipment_id}`, sh.id, "get_shipment")
      : await ss("GET", `/v2/shipments/external_shipment_id/${encodeURIComponent(order.external_order_id)}`,
                 sh.id, "get_shipment_by_external_id");

    if (ssShip.shipment_status === "label_purchased") throw new Error("ALREADY_LABELLED in ShipStation - check for a duplicate before re-printing");
    if (ssShip.shipment_status === "cancelled") throw new Error("ORDER_CANCELLED in ShipStation - do not ship");

    // ---- 3. write exact weight / dims / service --------------------------
    const service = ssShip.carrier_id && ssShip.service_code
      ? { carrier_id: ssShip.carrier_id, service_code: ssShip.service_code }
      : (sh.carrier_id && sh.service_code ? { carrier_id: sh.carrier_id, service_code: sh.service_code }
        : chooseService(order.requested_service ?? ssShip.requested_shipment_service, ssShip.ship_to?.country_code));
    if (!service) throw new Error("NEEDS_SERVICE: no carrier/service set for this order (international?) - set it in ShipStation");

    const put = Object.fromEntries(Object.entries(ssShip).filter(([k]) => !READ_ONLY.includes(k)));
    const updated = {
      ...put,
      ...service,
      packages: [{
        package_code: sh.package_types?.carrier_package_code ?? "package",
        weight: { value: sh.weight_grams, unit: "gram" },
        dimensions: sh.length_cm
          ? { unit: "centimeter", length: Number(sh.length_cm), width: Number(sh.width_cm), height: Number(sh.height_cm) }
          : undefined,
        label_messages: { reference1: `#${order.order_number}`, reference2: null, reference3: null },
      }],
    };
    ssShip = await ss("PUT", `/v2/shipments/${ssShip.shipment_id}`, sh.id, "update_shipment", updated);

    // ---- 4. buy the label -------------------------------------------------
    const fmt = sh.pack_stations?.label_format ?? "pdf";
    const label = await ss("POST", `/v2/labels/shipment/${ssShip.shipment_id}`, sh.id, "create_label", {
      label_format: fmt,          // 'pdf' or 'zpl'
      label_layout: "4x6",
      label_download_type: "url",
      test_label: TEST_LABELS,
    });

    // ---- 5. print: fetch the label, send to PrintNode as base64 ----------
    // The label is now BOUGHT. From here on, never throw: a print problem must
    // not mark the order failed (a retry would try to buy a second label).
    let printJobId: number | null = null;
    let printError: string | null = null;
    const printerId = sh.pack_stations?.printnode_printer_id;
    if (printerId) try {
      const url = label.label_download?.[fmt] ?? label.label_download?.href;
      const file = await fetch(url, { headers: { "API-Key": Deno.env.get("SHIPSTATION_API_KEY")! } });
      if (!file.ok) throw new Error(`label download failed (${file.status})`);
      const b64 = encodeBase64(new Uint8Array(await file.arrayBuffer()));
      const started = Date.now();
      const pnBody = {
        printerId: Number(printerId),
        title: `TWL #${order.order_number} ${label.tracking_number}`,
        contentType: fmt === "zpl" ? "raw_base64" : "pdf_base64",
        content: b64,
        source: "TWL WMS",
        expireAfter: 600,
      };
      const pn = await fetch(`${PN_BASE}/printjobs`, {
        method: "POST",
        headers: { Authorization: "Basic " + btoa(Deno.env.get("PRINTNODE_API_KEY")! + ":"), "Content-Type": "application/json" },
        body: JSON.stringify(pnBody),
      });
      const pnData = await pn.json();
      await logCall("print", sh.id, pn.ok, pn.status, { ...pnBody, content: `<${b64.length} chars>` }, pnData, started, "printnode");
      if (pn.ok) printJobId = pnData; // PrintNode returns the job id as a bare number
      else printError = `PrintNode ${pn.status}: ${JSON.stringify(pnData)}`;
    } catch (pe) {
      printError = pe instanceof Error ? pe.message : String(pe);
    }

    // ---- 6. close it out in the WMS --------------------------------------
    await db.rpc("wms_record_label", {
      p_shipment_id: sh.id, p_ok: true,
      p_ss_shipment_id: ssShip.shipment_id, p_label_id: label.label_id,
      p_tracking: label.tracking_number, p_label_url: label.label_download?.href ?? null,
      p_cost: label.shipment_cost?.amount ?? null,
      p_carrier_id: label.carrier_id, p_service_code: label.service_code,
      p_printnode_job_id: printJobId,
    });

    return json({
      ok: true, order_number: order.order_number, tracking_number: label.tracking_number,
      carrier: label.carrier_code, service: label.service_code, cost: label.shipment_cost,
      printed: printJobId !== null, print_error: printError, test_label: TEST_LABELS,
      label_url: label.label_download?.href, // the desktop app can open this if printing failed
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await db.rpc("wms_record_label", { p_shipment_id: sh.id, p_ok: false, p_error: msg });
    return json({ ok: false, error: msg }, 502);
  }
});
