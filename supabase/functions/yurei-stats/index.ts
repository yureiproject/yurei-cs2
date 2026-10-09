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
const faceitBase = "https://open.faceit.com/data/v4";
const leetifyBase = "https://api-public.cs-prod.leetify.com";

function firstKey(raw: string | undefined, prefix: string): string | undefined {
  if (!raw) return undefined;
  try {
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    return Object.values(parsed).find((value) => typeof value === "string" && value.startsWith(prefix)) as string | undefined;
  } catch { return raw.startsWith(prefix) ? raw : undefined; }
}

async function upstream(url: string, key: string) {
  const headers: Record<string, string> = {
    Accept: "application/json",
    Authorization: `Bearer ${key}`,
  };
  if (new URL(url).hostname === new URL(leetifyBase).hostname) {
    // Leetify also accepts this header as an API-key credential.
    headers._leetify_key = key;
  }
  const response = await fetch(url, { headers });
  if (!response.ok) {
    const provider = new URL(url).hostname === "open.faceit.com" ? "FACEIT" : "Leetify";
    const raw = await response.text();
    let detail = "";
    try {
      const body = JSON.parse(raw);
      detail = typeof body?.message === "string" ? body.message :
        Array.isArray(body?.errors) ? body.errors.map((item: { message?: string }) => item?.message).filter(Boolean).join("; ") :
        typeof body?.error === "string" ? body.error : "";
    } catch { /* The upstream response was not JSON. */ }
    throw new Error(`${provider} API HTTP ${response.status}${detail ? ` — ${detail.slice(0, 240)}` : ""}`);
  }
  return await response.json();
}

async function checkProfiles(faceitKey: string, leetifyKey: string, nickname: string, steamId64: string) {
  const faceitUrl = `${faceitBase}/players?${new URLSearchParams({ nickname, game: "cs2" })}`;
  const leetifyUrl = `${leetifyBase}/v3/profile?${new URLSearchParams({ steamId: steamId64 })}`;
  const [faceit, leetify] = await Promise.all([upstream(faceitUrl, faceitKey), upstream(leetifyUrl, leetifyKey)]);
  if (!faceit?.player_id) throw new Error("FACEIT ne renvoie aucun profil CS2 pour ce pseudo.");
  if (!leetify || typeof leetify !== "object") throw new Error("Leetify ne renvoie aucun profil pour ce SteamID64.");
  return { faceit, leetify };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Méthode invalide" }, 405);
  const authorization = req.headers.get("Authorization") || "";
  const token = authorization.replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "Connexion requise" }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const publishable = firstKey(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS"), "sb_publishable_") || Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = firstKey(Deno.env.get("SUPABASE_SECRET_KEYS"), "sb_secret_") || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !publishable || !serviceKey) return json({ error: "Configuration serveur Supabase incomplète" }, 500);

  const caller = createClient(url, publishable, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: userData, error: userError } = await caller.auth.getUser(token);
  if (userError || !userData.user) return json({ error: "Session invalide" }, 401);
  const userId = userData.user.id;
  const admin = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: member, error: memberError } = await admin.from("team_members")
    .select("team_id,player_id,role").eq("user_id", userId).maybeSingle();
  if (memberError || !member) return json({ error: "Compte Yurei non activé" }, 403);

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return json({ error: "JSON invalide" }, 400); }
  const action = body.action;
  if (action === "validate-setup" && member.role !== "admin") return json({ error: "Réservé à l’administrateur" }, 403);

  let faceitKey: string;
  let leetifyKey: string;
  if (action === "validate-setup") {
    faceitKey = String(body.faceitApiKey || "").trim();
    leetifyKey = String(body.leetifyApiKey || "").trim();
  } else {
    const { data: keys, error: keyError } = await admin.rpc("edge_get_team_api_keys", { target_team_id: member.team_id });
    if (keyError || !keys?.[0]?.faceit_api_key || !keys?.[0]?.leetify_api_key) {
      return json({ error: "Les clés FACEIT et Leetify de l’équipe ne sont pas configurées." }, 409);
    }
    faceitKey = keys[0].faceit_api_key;
    leetifyKey = keys[0].leetify_api_key;
  }

  try {
    if (action === "validate-setup" || action === "validate-profile") {
      const nickname = String(body.faceitNickname || "").trim();
      const steamId64 = String(body.steamId64 || "").trim();
      if (!nickname || !/^[0-9]{17}$/.test(steamId64)) return json({ error: "Pseudo FACEIT ou SteamID64 invalide." }, 400);
      await checkProfiles(faceitKey, leetifyKey, nickname, steamId64);
      return json({ ok: true });
    }

    if (action === "match") {
      const source = String(body.source || "").toUpperCase();
      const id = String(body.id || "");
      if (!id || id.length > 128 || !["FACEIT", "CS2", "LEETIFY"].includes(source)) return json({ error: "Match invalide" }, 400);
      const safeId = encodeURIComponent(id);
      if (source === "FACEIT") {
        const [details, stats] = await Promise.all([
          upstream(`${faceitBase}/matches/${safeId}`, faceitKey),
          upstream(`${faceitBase}/matches/${safeId}/stats`, faceitKey),
        ]);
        return json({ details, stats });
      }
      return json({ details: await upstream(`${leetifyBase}/v2/matches/${safeId}`, leetifyKey) });
    }

    if (action !== "team") return json({ error: "Action inconnue" }, 400);
    const [{ data: profiles, error: profilesError }, { data: roster, error: rosterError }] = await Promise.all([
      admin.from("player_integrations").select("player_id,faceit_nickname,steam_id64").eq("team_id", member.team_id),
      admin.from("team_members").select("player_id,display_name,player_role").eq("team_id", member.team_id),
    ]);
    if (profilesError || rosterError) return json({ error: "Impossible de lire les profils de l’équipe" }, 500);
    const results = await Promise.all((profiles || []).map(async (profile) => {
      const [faceit, leetify] = await Promise.all([
        (async () => {
          try {
            const faceitProfile = await upstream(faceitBase + "/players?" + new URLSearchParams({ nickname: profile.faceit_nickname, game: "cs2" }), faceitKey);
            const faceitId = encodeURIComponent(faceitProfile.player_id);
            const [stats, history] = await Promise.all([
              upstream(faceitBase + "/players/" + faceitId + "/stats/cs2", faceitKey),
              upstream(faceitBase + "/players/" + faceitId + "/history?" + new URLSearchParams({ game: "cs2", limit: "10" }), faceitKey),
            ]);
            return { profile: faceitProfile, stats, history };
          } catch (error) {
            return { error: error instanceof Error ? error.message : "FACEIT API indisponible" };
          }
        })(),
        (async () => {
          // The public v3 API expects steamId. Fetch profile and match history
          // independently so a history error never hides valid profile stats.
          const steamId = profile.steam_id64;
          const [profileResult, matchesResult] = await Promise.allSettled([
            upstream(leetifyBase + "/v3/profile?" + new URLSearchParams({ steamId }), leetifyKey),
            upstream(leetifyBase + "/v3/profile/matches?" + new URLSearchParams({ steamId, limit: "10" }), leetifyKey),
          ]);
          if (profileResult.status === "rejected") {
            return { error: profileResult.reason instanceof Error ? profileResult.reason.message : "Leetify API indisponible" };
          }
          const profileData = profileResult.value;
          const matchesPayload = matchesResult.status === "fulfilled" ? matchesResult.value : null;
          const matches = Array.isArray(matchesPayload)
            ? matchesPayload
            : Array.isArray(matchesPayload?.matches)
              ? matchesPayload.matches
              : Array.isArray(profileData?.recent_matches) ? profileData.recent_matches : [];
          return {
            profile: profileData,
            matches,
            matchesError: matchesResult.status === "rejected"
              ? matchesResult.reason instanceof Error ? matchesResult.reason.message : "Historique Leetify indisponible"
              : null,
          };
        })(),
      ]);
      return [profile.player_id, { faceit, leetify }];
    }));
    return json({ players: Object.fromEntries(results), roster, fetchedAt: Math.floor(Date.now() / 1000) });
  } catch (error) {
    const message = error instanceof Error ? error.message : "API inaccessible";
    return json({ error: message }, 502);
  }
});
