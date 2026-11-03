// =============================================================================
// Edge Function: sync-catalogue
// -----------------------------------------------------------------------------
// Called by pg_cron Mon-Fri 8:00-16:30 Adelaide (see migration 009).
//   1. SHOPIFY  -> new / changed products and variants (SKU, barcodes, weight,
//                 image, active status) upserted into products + product_barcodes
//   2. SKUVAULT -> every SKU x location quantity, so the WMS bins match
//                 SkuVault while SkuVault is still the live system.
//                 Set SKUVAULT_SYNC=false at cutover to switch this step off.
//
// Secrets (Supabase > Edge Functions > Secrets):
//   SHOPIFY_STORE          thewodlife            (the .myshopify.com subdomain)
//   SHOPIFY_CLIENT_ID      from the Dev Dashboard app > Settings
//   SHOPIFY_CLIENT_SECRET  from the Dev Dashboard app > Settings
//   SKUVAULT_TENANT_TOKEN  SkuVault API tokens
//   SKUVAULT_USER_TOKEN    SkuVault API tokens
//   SKUVAULT_SYNC          "true" until go-live, then "false"
// Each step is skipped (not failed) if its secrets are missing.
// =============================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const env = (k: string) => Deno.env.get(k) ?? "";
const WAREHOUSE = "TWLHQ";
let started = Date.now();
// Shopify gets ~70s per run, leaving time for SkuVault inside the edge time limit
const timeLeft = () => 90_000 - (Date.now() - started);

async function setState(system: string, patch: Record<string, unknown>) {
  await db.from("sync_state").upsert({ system, last_run_at: new Date().toISOString(), ...patch });
}

// ---------------------------------------------------------------------------
// 1. Shopify
// ---------------------------------------------------------------------------
// Token from the one-time "Connect to Shopify" (shopify-oauth function), refreshed
// when it is about to expire. Falls back to client credentials (same-org apps only).
async function secret(name: string) {
  const { data } = await db.from("app_secrets").select("value").eq("name", name).maybeSingle();
  return data?.value ?? "";
}

async function shopifyToken() {
  const stored = await secret("shopify_access_token");
  if (stored) {
    const expires = await secret("shopify_token_expires_at");
    if (!expires || new Date(expires).getTime() > Date.now()) return stored;
    const refresh = await secret("shopify_refresh_token");
    if (refresh) {
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
        { name: "shopify_token_expires_at",
          value: t.expires_in ? new Date(Date.now() + (t.expires_in - 120) * 1000).toISOString() : "" },
      ]);
      return t.access_token as string;
    }
  }
  const res = await fetch(`https://${env("SHOPIFY_STORE")}.myshopify.com/admin/oauth/access_token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: env("SHOPIFY_CLIENT_ID"),
      client_secret: env("SHOPIFY_CLIENT_SECRET"),
    }),
  });
  if (!res.ok) {
    const body = await res.text();
    if (body.includes("shop_not_permitted")) {
      throw new Error("NOT_CONNECTED: open https://nklbnykqftzkbqbuammg.supabase.co/functions/v1/shopify-oauth once to connect Shopify");
    }
    throw new Error(`Shopify token ${res.status}: ${body.slice(0, 200)}`);
  }
  return (await res.json()).access_token as string;
}

const VARIANTS_QUERY = `
query($q: String!, $after: String) {
  productVariants(first: 100, after: $after, query: $q, sortKey: ID) {
    pageInfo { hasNextPage endCursor }
    nodes {
      id sku title
      selectedOptions { name value }
      barcodes(first: 3) { nodes { value } }
      media(first: 1) { nodes { preview { image { url } } } }
      inventoryItem { measurement { weight { value unit } } }
      product { title status featuredMedia { preview { image { url } } } }
    }
  }
}`;

const GRAMS: Record<string, number> = { GRAMS: 1, KILOGRAMS: 1000, POUNDS: 453.592, OUNCES: 28.3495 };

// cursor = {since, runStart, after}: `since` only moves forward once a full pass
// finishes, so a long first sync is spread over several runs without gaps.
async function syncShopify() {
  if (!env("SHOPIFY_CLIENT_ID")) return { skipped: "no Shopify secrets" };
  const { data: st } = await db.from("sync_state").select("cursor").eq("system", "shopify_products").maybeSingle();
  const cur = st?.cursor ? JSON.parse(st.cursor) : {};
  const since: string = cur.since ?? "2023-01-01T00:00:00Z";        // first run: 3 years of changes
  const runStart: string = cur.after ? cur.runStart : new Date().toISOString();
  let after: string | null = cur.after ?? null, variants = 0, finished = false;
  const token = await shopifyToken();

  while (timeLeft() > 20_000) {
    const res = await fetch(`https://${env("SHOPIFY_STORE")}.myshopify.com/admin/api/2026-10/graphql.json`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Shopify-Access-Token": token },
      body: JSON.stringify({ query: VARIANTS_QUERY,
        variables: { q: `updated_at:>='${since}' AND gift_card:false`, after } }),
    });
    const json = await res.json();
    if (json.errors) throw new Error(`Shopify: ${JSON.stringify(json.errors).slice(0, 500)}`);
    const page = json.data.productVariants;

    const rows = [];
    for (const v of page.nodes) {
      if (!v.sku?.trim()) continue;                        // bundles / non-stock items have no SKU
      const p = v.product;
      const opt = (re: RegExp) => v.selectedOptions.find((o: { name: string }) => re.test(o.name))?.value ?? null;
      const w = v.inventoryItem?.measurement?.weight;
      const base = {
        sku: v.sku.trim(),
        name: p.title,
        variant_title: v.title === "Default Title" ? null : v.title,
        size: opt(/size/i),
        colour: opt(/colou?r/i),
        shopify_variant_id: Number(v.id.split("/").pop()),
        weight_grams: w?.value ? Math.round(w.value * (GRAMS[w.unit] ?? 0)) || null : null,
        image_url: v.media?.nodes?.[0]?.preview?.image?.url ?? p.featuredMedia?.preview?.image?.url ?? null,
        is_active: p.status === "ACTIVE",
      };
      const codes = v.barcodes.nodes.map((b: { value: string }) => b.value).filter(Boolean);
      for (const c of codes.length ? codes : [""]) rows.push({ ...base, barcode: c });
      variants++;
    }
    if (rows.length) {
      const { error } = await db.rpc("wms_import_products", { p_rows: rows });
      if (error) throw new Error(`wms_import_products: ${error.message}`);
    }
    if (!page.pageInfo.hasNextPage) { finished = true; after = null; break; }
    after = page.pageInfo.endCursor;
  }

  const next = finished ? { since: runStart } : { since, runStart, after };
  await setState("shopify_products", { cursor: JSON.stringify(next), last_ok_at: new Date().toISOString(), last_error: null });
  return { variants, finished };
}

// ---------------------------------------------------------------------------
// 2. SkuVault locations
// ---------------------------------------------------------------------------
type Loc = { WarehouseCode?: string; LocationCode?: string; Quantity?: number };

function parseCode(code: string) {
  const m3 = code.match(/^([A-Z]+)-(\d+)-(\d+)$/), m2 = code.match(/^([A-Z]+)-(\d+)$/);
  if (m3) return { code, row: m3[1], shelf: m3[2], bin: m3[3], type: "pick", zone: m3[1][0], zone_name: `Aisle ${m3[1][0]}` };
  if (m2) return { code, row: m2[1], shelf: m2[2], bin: "", type: "pick", zone: m2[1][0], zone_name: `Aisle ${m2[1][0]}` };
  return { code, type: "pick", zone: "DOCK", zone_name: "Dock & desks" };
}

async function syncSkuVault() {
  if (!env("SKUVAULT_TENANT_TOKEN") || env("SKUVAULT_SYNC") === "false") return { skipped: "SkuVault sync off" };
  const rows: { sku: string; location: string; qty: number }[] = [];
  for (let page = 0; page < 20; page++) {
    const res = await fetch("https://app.skuvault.com/api/inventory/getInventoryByLocation", {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({
        TenantToken: env("SKUVAULT_TENANT_TOKEN"), UserToken: env("SKUVAULT_USER_TOKEN"),
        PageNumber: page, PageSize: 10000,
      }),
    });
    if (!res.ok) throw new Error(`SkuVault ${res.status}: ${(await res.text()).slice(0, 300)}`);
    const json = await res.json();
    // Items: { "SKU": [ {WarehouseCode, LocationCode, Quantity}, ... ] }
    const items = (json.Items ?? {}) as Record<string, Loc[]>;
    const skus = Object.keys(items);
    for (const sku of skus) {
      for (const l of items[sku] ?? []) {
        if ((l.WarehouseCode ?? WAREHOUSE) !== WAREHOUSE || !l.LocationCode || !(Number(l.Quantity) > 0)) continue;
        rows.push({ sku, location: l.LocationCode.trim(), qty: Number(l.Quantity) });
      }
    }
    if (skus.length < 10000) break;
  }

  // any brand-new location in SkuVault gets created as a pick bin
  const codes = [...new Set(rows.map((r) => r.location))];
  const knownSet = new Set<string>();
  for (let from = 0; ; from += 1000) {                    // PostgREST returns max 1000 rows per call
    const { data, error } = await db.from("bins").select("code").order("code").range(from, from + 999);
    if (error) throw new Error(`bins: ${error.message}`);
    data.forEach((b) => knownSet.add(b.code));
    if (data.length < 1000) break;
  }
  const newBins = codes.filter((c) => !knownSet.has(c)).map(parseCode);
  if (newBins.length) {
    const { error } = await db.rpc("wms_import_layout", { p_warehouse_code: WAREHOUSE, p_rows: newBins });
    if (error) throw new Error(`wms_import_layout: ${error.message}`);
  }

  const { data, error } = await db.rpc("wms_sync_stock_snapshot", {
    p_warehouse_code: WAREHOUSE, p_rows: rows, p_reason: "Hourly sync from SkuVault",
  });
  if (error) throw new Error(`wms_sync_stock_snapshot: ${error.message}`);
  await setState("skuvault_locations", { last_ok_at: new Date().toISOString(), last_error: null });
  return { rows: rows.length, units: rows.reduce((a, r) => a + r.qty, 0), new_bins: newBins.length,
           changed: data.changed, zeroed: data.zeroed, skipped: data.skipped.length };
}

// ---------------------------------------------------------------------------
Deno.serve(async (req) => {
  started = Date.now();
  const { data: secret } = await db.from("app_secrets").select("value").eq("name", "cron_secret").single();
  if (req.headers.get("x-cron-secret") !== secret?.value) return new Response("forbidden", { status: 403 });

  const out: Record<string, unknown> = {};
  for (const [name, fn] of [["shopify", syncShopify], ["skuvault", syncSkuVault]] as const) {
    try { out[name] = await fn(); }
    catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      out[name] = { error: msg };
      await setState(name === "shopify" ? "shopify_products" : "skuvault_locations", { last_error: msg });
    }
  }
  console.log(JSON.stringify(out));
  return Response.json(out);
});
