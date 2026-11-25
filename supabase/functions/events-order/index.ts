import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { corsHeaders } from "../_shared/cors.ts";

// events-order — kreira pending narudžbu ulaznica + REZERVACIJU inventoryja
// (TTL 20 min) kroz security-definer RPC create_ticket_order.
//
// Klijent (wallet app) generira random order UUID: idempotency ključ (retry
// nakon pada mreže vraća postojeću narudžbu) i bearer capability za
// events-tickets (presedan: pinka contribution_status). Wallet nema Supabase
// sesiju (self-custody, bez računa) → poziv ide service klijentom s
// buyer_account_id = null (gost put; isti kao pinka gost doprinosi).
// Ako Authorization header nosi validan GoTrue JWT (pinka SPA), koristi se
// user klijent pa RPC rezolvira account + KYC snapshot.
//
// Novac NIKAD ne prolazi ovuda: vraćamo iznos narudžbe, plaćanje ide kroz
// Stripe (events-stripe-intent / events-stripe-confirm). verify_jwt=false.
//
// Shema `ulaznice` (lanac ulaznice-shema, S4): onchain rail je ukinut (odluka
// 110) — RPC za poslani payer_address baca `onchain_rail_removed` (400), a
// `destination_address` u odgovoru je uvijek null (ključ ostaje, odluka 3).
//
// Besplatna ulaznica (2026-11-25, migracija events_free_online): narudžba od
// 0 centi se potvrđuje ODMAH, ovdje, kroz confirm_ticket_order_offchain s
// rail-om 'free' (service klijent). Nema uplate koju bi trebalo dokazati, a RPC
// odbija 'free' za svaku narudžbu koja nije 0 (order_not_free), pa otvorena
// funkcija ne može izdati plaćenu ulaznicu. Odgovor tada nosi i QR tokene
// (jednokratno, deliver_ticket_orders), kao events-stripe-confirm.

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: {
    order_id?: string;
    campaign_id?: string;
    tier_id?: string;
    quantity?: number;
    holders?: Array<{ full_name?: string; email?: string }>;
    payer_address?: string;
    buyer_email?: string;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }

  if (!UUID_RE.test(body.order_id ?? "")) return json({ error: "invalid_order_id" }, 400);
  if (!UUID_RE.test(body.campaign_id ?? "")) return json({ error: "invalid_campaign_id" }, 400);
  if (!UUID_RE.test(body.tier_id ?? "")) return json({ error: "invalid_tier_id" }, 400);
  const quantity = Number(body.quantity);
  if (!Number.isInteger(quantity) || quantity < 1 || quantity > 10) {
    return json({ error: "invalid_quantity" }, 400);
  }

  // user klijent kad postoji validna sesija (pinka SPA); inače service (wallet gost)
  const authHeader = req.headers.get("Authorization") ?? "";
  let client = createClient(URL, SERVICE, { auth: { persistSession: false } });
  if (authHeader) {
    const userClient = createClient(URL, ANON, { global: { headers: { Authorization: authHeader } } });
    const { data: { user } } = await userClient.auth.getUser();
    if (user) client = userClient;
  }

  const { data, error } = await client
    .schema("ulaznice")
    .rpc("create_ticket_order", {
      p_order_id: body.order_id,
      p_campaign_id: body.campaign_id,
      p_tier_id: body.tier_id,
      p_quantity: quantity,
      p_holders: Array.isArray(body.holders) ? body.holders : [],
      p_payer_address: body.payer_address ?? null,
    });
  if (error) {
    // strojni kodovi iz RPC-a (tier_sold_out, holders_incomplete, sale_ended…)
    return json({ error: normalizeDbError(error.message) }, 400);
  }

  const order = (data ?? {}) as Record<string, unknown>;
  if (order.amount_cents !== 0 || order.state !== "pending") return json(data, 200);

  // ── besplatna: potvrdi odmah i isporuči tokene ───────────────────────────
  const buyerEmail = (body.buyer_email ?? "").trim();
  if (buyerEmail.length > 200) return json({ error: "invalid_payer_email" }, 400);
  const service = createClient(URL, SERVICE, { auth: { persistSession: false } });
  const fin = service.schema("ulaznice");
  const { data: confirmed, error: cErr } = await fin.rpc("confirm_ticket_order_offchain", {
    p_order_id: body.order_id,
    p_rail: "free",
    p_external_ref: "free_" + String(body.order_id).replaceAll("-", ""),
    p_amount_cents: 0,
    p_payer_email: buyerEmail || null,
  });
  if (cErr) return json({ error: normalizeDbError(cErr.message) }, 400);
  const result = (confirmed ?? {}) as Record<string, unknown>;
  if (result.status !== "paid" && result.status !== "already_paid") return json({ ...order, ...result }, 409);

  const { data: delivered, error: dErr } = await fin.rpc("deliver_ticket_orders", { p_order_ids: [body.order_id] });
  const first = (Array.isArray(delivered) ? delivered[0] : null) as { tickets?: Array<Record<string, unknown>> } | null;
  const tickets = (first?.tickets ?? []).map((t) => ({
    serial: t.serial,
    holder_name: t.holder_name,
    holder_email: t.holder_email,
    state: t.state,
    qr_token: t.qr_token,
  }));
  return json({
    ...order,
    state: "paid",
    free: true,
    status: result.status,
    serials: result.serials,
    tickets,
    ...(dErr ? { delivery_error: dErr.message } : {}),
  }, 200);
});

// PostgREST prefiksira poruku exceptiona; zadrži samo strojni kod kad je čist.
function normalizeDbError(message: string): string {
  const code = message.trim().split(/\s/)[0];
  return /^[a-z_]+$/.test(code) ? code : message;
}

function json(b: unknown, status: number) {
  return new Response(JSON.stringify(b), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
