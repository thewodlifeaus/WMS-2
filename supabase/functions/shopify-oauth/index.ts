// =============================================================================
// Edge Function: shopify-oauth   (one-time "Connect to Shopify")
// -----------------------------------------------------------------------------
// The TWL WMS Shopify app lives in a developer (Partner) organisation, so the
// simple client-credentials login is refused (shop_not_permitted). Instead an
// admin opens this function's URL once, approves in Shopify, and the access
// token is stored in app_secrets for the sync jobs to use.
//
//   GET .../functions/v1/shopify-oauth            -> redirects to Shopify approval
//   GET .../functions/v1/shopify-oauth?code=...   -> Shopify's callback (HMAC checked)
//
// The app's Dev Dashboard version must list this URL under "Redirect URLs":
//   https://nklbnykqftzkbqbuammg.supabase.co/functions/v1/shopify-oauth
// =============================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const STORE = Deno.env.get("SHOPIFY_STORE") ?? "thewodlife";
const CLIENT_ID = Deno.env.get("SHOPIFY_CLIENT_ID")!;
const CLIENT_SECRET = Deno.env.get("SHOPIFY_CLIENT_SECRET")!;
const SELF = "https://nklbnykqftzkbqbuammg.supabase.co/functions/v1/shopify-oauth";
const SCOPES = "read_products,read_inventory,write_inventory,read_locations";

const page = (title: string, msg: string, ok: boolean) => new Response(
  `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
   <title>${title}</title>
   <body style="font-family:Montserrat,system-ui,sans-serif;max-width:560px;margin:15vh auto;padding:0 16px;color:#111">
   <h1 style="color:${ok ? "#1a7f37" : "#b42318"}">${title}</h1><p style="font-size:18px;line-height:1.5">${msg}</p></body>`,
  { status: ok ? 200 : 400, headers: { "Content-Type": "text/html; charset=utf-8" } });

async function setSecret(name: string, value: string) {
  await db.from("app_secrets").upsert({ name, value });
}

async function hmacHex(message: string) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(CLIENT_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req) => {
  const url = new URL(req.url);
  const p = url.searchParams;

  // ---- step 1: send the admin to Shopify's approval screen -----------------
  if (!p.get("code")) {
    const state = crypto.randomUUID();
    await setSecret("shopify_oauth_state", state);
    const auth = new URL(`https://${STORE}.myshopify.com/admin/oauth/authorize`);
    auth.searchParams.set("client_id", CLIENT_ID);
    auth.searchParams.set("scope", SCOPES);
    auth.searchParams.set("redirect_uri", SELF);
    auth.searchParams.set("state", state);
    return Response.redirect(auth.toString(), 302);
  }

  // ---- step 2: Shopify's callback ---------------------------------------
  const shop = p.get("shop") ?? "";
  if (shop !== `${STORE}.myshopify.com`) return page("Wrong store", `Expected ${STORE}.myshopify.com.`, false);

  const { data: st } = await db.from("app_secrets").select("value").eq("name", "shopify_oauth_state").maybeSingle();
  if (!st || p.get("state") !== st.value) return page("Link expired", "Please start again from the connect link.", false);

  const given = p.get("hmac") ?? "";
  const message = [...p.entries()].filter(([k]) => k !== "hmac" && k !== "signature")
    .sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => `${k}=${v}`).join("&");
  if ((await hmacHex(message)) !== given) return page("Security check failed", "The request did not come from Shopify.", false);

  const res = await fetch(`https://${shop}/admin/oauth/access_token`, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ client_id: CLIENT_ID, client_secret: CLIENT_SECRET, code: p.get("code") }),
  });
  const tok = await res.json().catch(() => ({}));
  if (!res.ok || !tok.access_token) {
    return page("Shopify refused the connection", `(${res.status}) ${JSON.stringify(tok).slice(0, 300)}`, false);
  }

  await setSecret("shopify_access_token", tok.access_token);
  await setSecret("shopify_scope", tok.scope ?? "");
  // newer apps may issue expiring offline tokens with a refresh token
  await setSecret("shopify_refresh_token", tok.refresh_token ?? "");
  await setSecret("shopify_token_expires_at",
    tok.expires_in ? new Date(Date.now() + (tok.expires_in - 120) * 1000).toISOString() : "");
  await setSecret("shopify_oauth_state", crypto.randomUUID());   // one-time use

  return page("Shopify connected", `The WMS can now read products and stock for ${shop}.<br>Scopes: ${tok.scope}.<br>You can close this tab.`, true);
});
