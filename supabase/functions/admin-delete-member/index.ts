import { createClient } from "npm:@supabase/supabase-js@2.110.8";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...cors, "Content-Type": "application/json" },
});
function firstKey(raw: string | undefined, prefix: string): string | undefined {
  if (!raw) return undefined;
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    return Object.values(parsed).find((value) => typeof value === "string" && value.startsWith(prefix)) as string | undefined;
  } catch { return raw.startsWith(prefix) ? raw : undefined; }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Méthode invalide" }, 405);

  const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Connexion requise" }, 401);
  const url = Deno.env.get("SUPABASE_URL");
  const publishable = firstKey(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS"), "sb_publishable_") || Deno.env.get("SUPABASE_ANON_KEY");
  const secret = firstKey(Deno.env.get("SUPABASE_SECRET_KEYS"), "sb_secret_") || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !publishable || !secret) return json({ error: "Configuration serveur Supabase incomplète" }, 500);

  const callerClient = createClient(url, publishable, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: callerData, error: callerError } = await callerClient.auth.getUser(token);
  if (callerError || !callerData.user) return json({ error: "Session invalide" }, 401);

  const admin = createClient(url, secret, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: callerMember, error: callerMemberError } = await admin.from("team_members")
    .select("team_id,role").eq("user_id", callerData.user.id).maybeSingle();
  if (callerMemberError || !callerMember) return json({ error: "Compte d’équipe introuvable" }, 403);
  if (callerMember.role !== "admin") return json({ error: "Réservé à l’administrateur" }, 403);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "JSON invalide" }, 400); }
  const targetUserId = String(body.targetUserId || "");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(targetUserId)) {
    return json({ error: "Identifiant de compte invalide" }, 400);
  }
  if (targetUserId === callerData.user.id) return json({ error: "Tu ne peux pas supprimer ton propre compte administrateur" }, 400);

  const { data: target, error: targetError } = await admin.from("team_members")
    .select("user_id,team_id,player_id,role,display_name")
    .eq("user_id", targetUserId).eq("team_id", callerMember.team_id).maybeSingle();
  if (targetError || !target) return json({ error: "Ce joueur n’appartient pas à ton équipe" }, 404);
  if (target.role !== "player") return json({ error: "La suppression d’un compte administrateur est bloquée" }, 403);

  const { error: authDeleteError } = await admin.auth.admin.deleteUser(target.user_id);
  if (authDeleteError) return json({ error: "Suppression Auth impossible: " + authDeleteError.message }, 500);

  const { error: integrationError } = await admin.from("player_integrations")
    .delete().eq("team_id", target.team_id).eq("player_id", target.player_id);
  const { data: stateRow, error: stateReadError } = await admin.from("team_state")
    .select("state").eq("team_id", target.team_id).maybeSingle();
  let stateError: string | null = stateReadError?.message || null;
  if (!stateError && stateRow?.state) {
    const state = { ...stateRow.state } as Record<string, any>;
    for (const key of ["routines", "playerNotes", "playerStats", "roleNotes"]) {
      if (state[key] && typeof state[key] === "object") delete state[key][target.player_id];
    }
    state.availability = Object.fromEntries(Object.entries(state.availability || {})
      .filter(([key]) => !key.startsWith(target.player_id + "|")));
    state.events = (Array.isArray(state.events) ? state.events : [])
      .filter((event: any) => event?.owner !== target.player_id);
    const { error } = await admin.from("team_state").update({ state, updated_at: new Date().toISOString() })
      .eq("team_id", target.team_id);
    stateError = error?.message || null;
  }
  if (integrationError || stateError) {
    return json({ ok: true, warning: "Le compte a été supprimé, mais certaines données liées n’ont pas pu être nettoyées." });
  }
  return json({ ok: true });
});
