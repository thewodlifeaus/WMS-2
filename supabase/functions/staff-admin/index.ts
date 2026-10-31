// =============================================================================
// Edge Function: staff-admin   (create staff logins, reset PINs, change roles)
// -----------------------------------------------------------------------------
// Everyone logs in with USERNAME + 6-digit PIN. Behind the scenes the auth email
// is <username>@staff.twlwms.app (never emailed), so floor staff need no email.
//
// POST body { action, ... }  with the caller's login token (Authorization: Bearer)
//   create   { username, display_name, role, pin?, contact_email? }   admin
//   set_pin  { username, pin? }        admin/supervisor, or yourself
//   set_role { username, role }        admin
//   set_active { username, active }    admin
//   list     {}                         admin/supervisor
// If pin is omitted a random 6-digit PIN is generated and returned ONCE.
// Bootstrap: when no admin exists yet, "create" is also accepted with the
// x-cron-secret header (used once to create the first admin).
// =============================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const DOMAIN = "staff.twlwms.app";
const ROLES = ["admin", "supervisor", "receiver", "picker", "packer", "display"];
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-secret",
};
const json = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const randomPin = () => String(crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000).padStart(6, "0");
const emailFor = (u: string) => `${u.toLowerCase()}@${DOMAIN}`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const body = await req.json().catch(() => ({}));
  const action = body.action as string;

  // ---- who is calling? -----------------------------------------------------
  let caller: { id: string; role: string } | null = null;
  const jwt = req.headers.get("Authorization")?.replace("Bearer ", "") ?? "";
  if (jwt) {
    const { data } = await db.auth.getUser(jwt);
    if (data?.user) {
      const { data: s } = await db.from("staff").select("id, role").eq("id", data.user.id).eq("is_active", true).maybeSingle();
      if (s) caller = s;
    }
  }
  let bootstrap = false;
  if (!caller && action === "create") {
    const { data: sec } = await db.from("app_secrets").select("value").eq("name", "cron_secret").single();
    const { count } = await db.from("staff").select("id", { count: "exact", head: true }).eq("role", "admin");
    bootstrap = !!sec?.value && req.headers.get("x-cron-secret") === sec.value && (count ?? 0) === 0;
  }
  if (!caller && !bootstrap) return json({ ok: false, error: "NOT_SIGNED_IN" }, 401);
  const isAdmin = bootstrap || caller?.role === "admin";
  const isSup = isAdmin || caller?.role === "supervisor";

  const username = String(body.username ?? "").trim().toLowerCase();
  const findStaff = async () =>
    (await db.from("staff").select("id, username, display_name, role, is_active").ilike("username", username).maybeSingle()).data;

  try {
    switch (action) {
      case "create": {
        if (!isAdmin) return json({ ok: false, error: "FORBIDDEN" }, 403);
        if (!/^[a-z0-9][a-z0-9._-]{1,30}$/.test(username)) return json({ ok: false, error: "BAD_USERNAME (letters, numbers, . _ -)" }, 400);
        if (!ROLES.includes(body.role)) return json({ ok: false, error: `BAD_ROLE (${ROLES.join(", ")})` }, 400);
        if (!String(body.display_name ?? "").trim()) return json({ ok: false, error: "NAME_REQUIRED" }, 400);
        const pin = body.pin ? String(body.pin) : randomPin();
        if (!/^\d{6}$/.test(pin)) return json({ ok: false, error: "PIN_MUST_BE_6_DIGITS" }, 400);
        const { data: u, error } = await db.auth.admin.createUser({
          email: emailFor(username), password: pin, email_confirm: true,
          app_metadata: { wms_role: body.role }, user_metadata: { name: body.display_name },
        });
        if (error) return json({ ok: false, error: error.message }, 400);
        const { error: e2 } = await db.from("staff").insert({
          id: u.user.id, username, display_name: String(body.display_name).trim(), role: body.role,
          contact_email: body.contact_email ?? null, pin_set_at: new Date().toISOString(),
        });
        if (e2) { await db.auth.admin.deleteUser(u.user.id); return json({ ok: false, error: e2.message }, 400); }
        return json({ ok: true, username, display_name: body.display_name, role: body.role, pin, note: "Give this PIN to the person. It is not shown again." });
      }
      case "set_pin": {
        const s = await findStaff();
        if (!s) return json({ ok: false, error: "NOT_FOUND" }, 404);
        if (!isSup && caller?.id !== s.id) return json({ ok: false, error: "FORBIDDEN" }, 403);
        const pin = body.pin ? String(body.pin) : randomPin();
        if (!/^\d{6}$/.test(pin)) return json({ ok: false, error: "PIN_MUST_BE_6_DIGITS" }, 400);
        const { error } = await db.auth.admin.updateUserById(s.id, { password: pin });
        if (error) return json({ ok: false, error: error.message }, 400);
        await db.from("staff").update({ pin_set_at: new Date().toISOString() }).eq("id", s.id);
        return json({ ok: true, username: s.username, pin: body.pin ? undefined : pin });
      }
      case "set_role": {
        if (!isAdmin) return json({ ok: false, error: "FORBIDDEN" }, 403);
        if (!ROLES.includes(body.role)) return json({ ok: false, error: "BAD_ROLE" }, 400);
        const s = await findStaff();
        if (!s) return json({ ok: false, error: "NOT_FOUND" }, 404);
        await db.from("staff").update({ role: body.role }).eq("id", s.id);
        await db.auth.admin.updateUserById(s.id, { app_metadata: { wms_role: body.role } });
        return json({ ok: true, username: s.username, role: body.role });
      }
      case "set_active": {
        if (!isAdmin) return json({ ok: false, error: "FORBIDDEN" }, 403);
        const s = await findStaff();
        if (!s) return json({ ok: false, error: "NOT_FOUND" }, 404);
        if (s.id === caller?.id) return json({ ok: false, error: "CANNOT_DEACTIVATE_YOURSELF" }, 400);
        await db.from("staff").update({ is_active: !!body.active }).eq("id", s.id);
        // a deactivated person is also locked out of login
        await db.auth.admin.updateUserById(s.id, { ban_duration: body.active ? "none" : "876000h" });
        return json({ ok: true, username: s.username, active: !!body.active });
      }
      case "list": {
        if (!isSup) return json({ ok: false, error: "FORBIDDEN" }, 403);
        const { data } = await db.from("staff").select("username, display_name, role, is_active, pin_set_at").order("display_name");
        return json({ ok: true, staff: data });
      }
      default:
        return json({ ok: false, error: "UNKNOWN_ACTION" }, 400);
    }
  } catch (e) {
    return json({ ok: false, error: e instanceof Error ? e.message : String(e) }, 500);
  }
});
