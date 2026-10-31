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

// Send people without a session back to the login page.
export async function requireLogin() {
  const { data } = await sb.auth.getSession();
  if (!data.session) { location.href = `/index.html?next=${encodeURIComponent(location.pathname)}`; return null; }
  const m = await me();
  if (!m) { await sb.auth.signOut(); location.href = "/index.html"; return null; }
  return m;
}

export async function signOut() { await sb.auth.signOut(); location.href = "/index.html"; }

export const fmt = (n) => (n ?? 0).toLocaleString("en-AU");
export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
