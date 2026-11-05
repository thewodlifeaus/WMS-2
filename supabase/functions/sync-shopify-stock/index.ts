// =============================================================================
// Edge Function: sync-shopify-stock   (Inventory reconciliation, migration 038)
// -----------------------------------------------------------------------------
// Reads on hand + committed for every inventory item at the Shopify "TWL"
// location with ONE Shopify bulk query (no rate limits, ~28k items) and saves it
// into shopify_stock for the reconciliation report (/recon).
//
//   {action:"start"}  -> starts two bulk reads (or returns the ones already running):
//                        stock at the TWL location, and the SKUs of products tagged
//                        "dropshipping"/"dropship" (skipped by the report, migration 039)
//   {action:"status"} -> checks it; when Shopify has finished, downloads the file,
//                        saves every row, then switches the report to this pull
//
// Called by a signed-in admin/supervisor ("Get latest from Shopify" on /recon,
// which polls status every few seconds) or pg_cron (x-cron-secret).
// Uses the same Shopify app token as sync-catalogue (app_secrets).
// Optional secret SHOPIFY_STOCK_LOCATION_ID (default 31072848 = "TWL", Ridleyton).
// =============================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const env = (k: string) => Deno.env.get(k) ?? "";
const LOCATION = env("SHOPIFY_STOCK_LOCATION_ID") || "31072848";
const API = () => `https://${env("SHOPIFY_STORE")}.myshopify.com/admin/api/2026-10/graphql.json`;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
};
const reply = (b: unknown, status = 200) =>
  new Response(JSON.stringify(b), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function secret(name: string) {
  const { data } = await db.from("app_secrets").select("value").eq("name", name).maybeSingle();
  return data?.value ?? "";
}

// Same token handling as sync-catalogue: stored OAuth token, refreshed when it expires.
async function shopifyToken() {
  const stored = await secret("shopify_access_token");
  const expires = await secret("shopify_token_expires_at");
  if (stored && (!expires || new Date(expires).getTime() > Date.now())) return stored;
  const refresh = await secret("shopify_refresh_token");
  if (!refresh) throw new Error("NOT_CONNECTED: Shopify is not connected (run shopify-oauth once)");
  const r = await fetch(`https://${env("SHOPIFY_STORE")}.myshopify.com/admin/oauth/access_token`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ client_id: env("SHOPIFY_CLIENT_ID"), client_secret: env("SHOPIFY_CLIENT_SECRET"),
                           grant_type: "refresh_token", refresh_token: refresh }),
  });
  const t = await r.json().catch(() => ({}));
  if (!r.ok || !t.access_token) throw new Error(`Shopify token refresh ${r.status}: ${JSON.stringify(t).slice(0, 200)}`);
  await db.from("app_secrets").upsert([
    { name: "shopify_access_token", value: t.access_token },
    { name: "shopify_refresh_token", value: t.refresh_token ?? refresh },
    { name: "shopify_token_expires_at", value: t.expires_in ? new Date(Date.now() + (t.expires_in - 120) * 1000).toISOString() : "" },
  ]);
  return t.access_token as string;
}

async function gql(query: string, variables: Record<string, unknown> = {}) {
  const res = await fetch(API(), {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Shopify-Access-Token": await shopifyToken() },
    body: JSON.stringify({ query, variables }),
  });
  const json = await res.json();
  if (json.errors) throw new Error(`Shopify: ${JSON.stringify(json.errors).slice(0, 400)}`);
  return json.data;
}

const BULK_QUERY = `{
  location(id: "gid://shopify/Location/${LOCATION}") {
    inventoryLevels {
      edges { node {
        quantities(names: ["on_hand", "committed", "available", "reserved"]) { name quantity }
        item { id sku tracked }
      } }
    }
  }
}`;

const DROPSHIP_QUERY = `{
  products(query: "tag:dropshipping OR tag:dropship") {
    edges { node { id variants { edges { node { sku } } } } }
  }
}`;

type State = { run_at?: string; op_id?: string; op_status?: string; started_at?: string; finished_at?: string;
               items?: number; imported_op?: string; started_by?: string;
               ds_op_id?: string; ds_status?: string; dropship_skus?: number };

async function runBulk(q: string) {
  const d = await gql(`mutation($q: String!) {
    bulkOperationRunQuery(query: $q, groupObjects: false) { bulkOperation { id status createdAt } userErrors { field message } }
  }`, { q });
  const p = d.bulkOperationRunQuery;
  if (p.userErrors?.length) throw new Error(`Shopify: ${p.userErrors.map((e: { message: string }) => e.message).join("; ")}`);
  return p.bulkOperation as { id: string; status: string };
}
async function bulkInfo(id: string) {
  const d = await gql(`query($id: ID!) { node(id: $id) { ... on BulkOperation {
      id status errorCode objectCount url partialDataUrl completedAt } } }`, { id });
  if (!d.node) throw new Error("Shopify bulk read not found");
  return d.node as { status: string; errorCode: string | null; objectCount: string; url: string | null };
}
const BAD = ["FAILED", "CANCELED", "EXPIRED"];

async function getState(): Promise<{ cur: State; last_error: string | null }> {
  const { data } = await db.from("sync_state").select("cursor,last_error").eq("system", "shopify_stock").maybeSingle();
  let cur: State = {};
  try { cur = data?.cursor ? JSON.parse(data.cursor) : {}; } catch { /* ignore */ }
  return { cur, last_error: data?.last_error ?? null };
}
async function saveState(cur: State, patch: Record<string, unknown> = {}) {
  await db.from("sync_state").upsert({ system: "shopify_stock", cursor: JSON.stringify(cur), last_run_at: new Date().toISOString(), ...patch });
}

async function start(who: string) {
  const { cur } = await getState();
  if (cur.op_id && cur.imported_op !== cur.op_id && !BAD.includes(cur.op_status ?? "")) {
    const st = await status();                       // already running: just report it
    if (st.imported_op !== st.op_id && !BAD.includes(st.op_status ?? "")) return { ...st, already_running: true };
  }
  const op = await runBulk(BULK_QUERY);
  const ds = await runBulk(DROPSHIP_QUERY);
  const next: State = { ...cur, op_id: op.id, op_status: op.status, ds_op_id: ds.id, ds_status: ds.status,
                        started_at: new Date().toISOString(), finished_at: undefined, started_by: who };
  await saveState(next, { last_error: null });
  return next;
}

async function status() {
  const { cur } = await getState();
  if (!cur.op_id) return cur;
  if (cur.imported_op === cur.op_id) return cur;                       // already done
  const op = await bulkInfo(cur.op_id);
  cur.op_status = op.status;
  const ds = cur.ds_op_id ? await bulkInfo(cur.ds_op_id) : null;
  if (ds) cur.ds_status = ds.status;
  if (BAD.includes(op.status) || (ds && BAD.includes(ds.status))) {
    const bad = BAD.includes(op.status) ? op : ds!;
    await saveState(cur, { last_error: `Shopify bulk read ${bad.status}${bad.errorCode ? ` (${bad.errorCode})` : ""}` });
    return cur;
  }
  if (op.status !== "COMPLETED" || (ds && ds.status !== "COMPLETED")) { await saveState(cur); return { ...cur, objects: Number(op.objectCount) }; }

  // Finished: download the JSONL (one line per inventory level) and save it in chunks
  const runAt = new Date().toISOString();
  let dsCount = 0;
  if (ds?.url) {                                                       // variant lines carry a sku
    const res = await fetch(ds.url);
    if (!res.ok) throw new Error(`Download ${res.status}`);
    const skus = new Set<string>();
    for (const line of (await res.text()).split("\n")) {
      if (!line.trim()) continue;
      const n = JSON.parse(line);
      if (typeof n.sku === "string" && n.sku.trim()) skus.add(n.sku.trim());
    }
    const list = [...skus];
    for (let i = 0; i < list.length; i += 5000) {
      const { data, error } = await db.rpc("wms_import_shopify_dropship", { p_run_at: runAt, p_skus: list.slice(i, i + 5000) });
      if (error) throw new Error(`wms_import_shopify_dropship: ${error.message}`);
      dsCount += data as number;
    }
  }
  let rows: Record<string, unknown>[] = [], saved = 0;
  const flush = async () => {
    if (!rows.length) return;
    const { data, error } = await db.rpc("wms_import_shopify_stock", { p_run_at: runAt, p_location: Number(LOCATION), p_rows: rows });
    if (error) throw new Error(`wms_import_shopify_stock: ${error.message}`);
    saved += data as number; rows = [];
  };
  if (op.url) {                                                        // url is null when the location has no items
    const res = await fetch(op.url);
    if (!res.ok) throw new Error(`Download ${res.status}`);
    const text = await res.text();
    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      const n = JSON.parse(line);
      if (!n.item?.id) continue;
      const q: Record<string, number> = {};
      for (const x of n.quantities ?? []) q[x.name] = Number(x.quantity) || 0;
      rows.push({ item: Number(String(n.item.id).split("/").pop()), sku: n.item.sku ?? "", tracked: n.item.tracked !== false,
                  on_hand: q.on_hand ?? 0, committed: q.committed ?? 0, available: q.available ?? 0, reserved: q.reserved ?? 0 });
      if (rows.length >= 4000) await flush();
    }
    await flush();
  }
  // switch the report over to this pull only now that every row is in
  const next: State = { ...cur, run_at: runAt, finished_at: new Date().toISOString(), items: saved, imported_op: cur.op_id, op_status: "COMPLETED", dropship_skus: dsCount };
  await saveState(next, { last_ok_at: new Date().toISOString(), last_error: null });
  return next;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  // pg_cron (cron secret) or a signed-in admin/supervisor
  let who = "cron";
  const sec = await secret("cron_secret");
  let allowed = !!sec && req.headers.get("x-cron-secret") === sec;
  if (!allowed) {
    const jwt = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
    const { data: auth } = await db.auth.getUser(jwt);
    if (auth?.user) {
      const { data: st } = await db.from("staff").select("role,display_name").eq("id", auth.user.id).eq("is_active", true).maybeSingle();
      allowed = st?.role === "admin" || st?.role === "supervisor";
      who = st?.display_name ?? "staff";
    }
  }
  if (!allowed) return reply({ ok: false, error: "FORBIDDEN" }, 403);
  const body = await req.json().catch(() => ({}));
  try {
    const out = body.action === "start" ? await start(who) : await status();
    return reply({ ok: true, ...out });
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await db.from("sync_state").update({ last_error: msg }).eq("system", "shopify_stock");
    return reply({ ok: false, error: msg });
  }
});
