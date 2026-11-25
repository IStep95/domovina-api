import { corsHeaders } from "../_shared/cors.ts";

// events-confirm — UKINUTO: onchain (EURe na Gnosisu) plaćanje ulaznica.
//
// Do sheme `ulaznice` ovdje se vezala EURe uplata (tx hash, verificiran receipt
// na Gnosisu) uz narudžbu kroz stari RPC confirm_ticket_order. Odluka 110
// lanca ulaznice-shema ukida onchain rail: ulaznice.orders dopušta
// payment_rail 'onchain' samo za istekle narudžbe, a RPC confirm_ticket_order
// u shemi `ulaznice` ne postoji. Nijedna onchain narudžba ne može biti
// pending, pa ni potvrđena.
//
// Ruta ostaje (deploy unit, CORS, isti oblik greške {error}) da stari klijent
// dobije jasnu, trajnu 4xx grešku umjesto 404 ili 500: 410 Gone s kodom
// `onchain_rail_removed` (isti kod koji create_ticket_order baca za
// payer_address). Validacija tijela se namjerno ne radi — svaki POST je 410.
// verify_jwt=false.

Deno.serve((req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  return json({ error: "onchain_rail_removed" }, 410);
});

function json(b: unknown, status: number) {
  return new Response(JSON.stringify(b), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
