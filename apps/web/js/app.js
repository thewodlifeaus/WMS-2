// Shared Supabase client + login helpers for the TWL WMS web pages.
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/+esm";

export const SUPABASE_URL = "https://nklbnykqftzkbqbuammg.supabase.co";
export const SUPABASE_KEY = "sb_publishable_gq6n7-kpJPZUwxGuQ9-nfQ_DyjeWSHS"; // public key; data is protected by staff logins + RLS
export const sb = createClient(SUPABASE_URL, SUPABASE_KEY, { auth: { persistSession: true, autoRefreshToken: true } });

const STAFF_DOMAIN = "staff.twlwms.app";

export async function signIn(username, pin) {
  const email = `${username.trim().toLowerCase()}@${STAFF_DOMAIN}`;
  const { error } = await sb.auth.signInWithPassword({ email, password: pin.trim() });
  if (error) throw new Error("Username or PIN not recognised");
  return me();
}

export async function me() {
  const { data, error } = await sb.rpc("wms_me");
  if (error || !data) return null;
  return data;
}

// Wipe the saved login from this browser, even if the server has already ended it.
export async function clearLogin() {
  try { await sb.auth.signOut({ scope: "local" }); } catch {}
  try { for (const k of Object.keys(localStorage)) if (k.startsWith("sb-")) localStorage.removeItem(k); } catch {}
}

// Check the saved login is still valid on the server (it ends when a PIN changes).
export async function validSession() {
  const { data } = await sb.auth.getSession();
  if (!data.session) return false;
  const { data: u, error } = await sb.auth.getUser();
  if (error || !u?.user) { await clearLogin(); return false; }
  return true;
}

// Which screens each role can open (admins and supervisors see everything)
export const ACCESS = {
  pick:    ["admin", "supervisor", "picker"],
  stock:   ["admin", "supervisor", "picker", "receiver"],
  orders:  ["admin", "supervisor"],
  pack:    ["admin", "supervisor", "packer"],
  search:  ["admin", "supervisor", "picker", "packer", "receiver"],
  tv:      ["admin", "supervisor", "display"],
  history: ["admin", "supervisor"],
  staff:   ["admin", "supervisor"],
  replenish: ["admin", "supervisor"],
  settings: ["admin"],
};
export const canOpen = (role, page) => (ACCESS[page] ?? []).includes(role);
const pageName = () => location.pathname.replace(/^\//, "").replace(/\.html$/, "") || "index";

// Send people without a valid login back to the login page, and people without
// access to this screen back to their menu.
export async function requireLogin() {
  if (!(await validSession())) { location.href = `/index.html?next=${encodeURIComponent(location.pathname)}`; return null; }
  const m = await me();
  if (!m) { await clearLogin(); location.href = "/index.html"; return null; }
  const page = pageName();
  if (ACCESS[page] && !canOpen(m.role, page)) {
    location.href = m.role === "display" ? "/tv.html" : `/index.html?denied=${encodeURIComponent(page)}`;
    await new Promise(() => {});   // stop this page here
  }
  return m;
}

export async function signOut() { await clearLogin(); location.href = "/index.html"; }

export const fmt = (n) => (n ?? 0).toLocaleString("en-AU");
export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
