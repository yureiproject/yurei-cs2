#!/usr/bin/env python3
"""Yurei CS2 Hub: local SQLite server with account sessions and shared team data."""
from __future__ import annotations

import hashlib
import hmac
import json
import mimetypes
import os
import secrets
import sqlite3
import time
import urllib.error
import urllib.parse
import urllib.request
from http.cookies import SimpleCookie
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

ROOT = Path(__file__).resolve().parent
DB_PATH = Path(os.environ.get("REDLINE_DB", ROOT / "redline.sqlite3"))
HOST = os.environ.get("REDLINE_HOST", "127.0.0.1")
PORT = int(os.environ.get("REDLINE_PORT", "8765"))
PLAYERS = {"blue", "ina", "tom", "max", "leo"}
SESSION_SECONDS = 14 * 24 * 60 * 60
MAX_BODY = 125 * 1024 * 1024
FACEIT_API = "https://open.faceit.com/data/v4"
LEETIFY_API = "https://api-public.cs-prod.leetify.com"
FERNET_PATH = ROOT / ".redline-fernet.key"

try:
    from cryptography.fernet import Fernet, InvalidToken
except ImportError:
    Fernet = None
    InvalidToken = Exception


def connect():
    db = sqlite3.connect(DB_PATH, timeout=30)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA foreign_keys=ON")
    return db


def init_db():
    with connect() as db:
        db.executescript("""
        CREATE TABLE IF NOT EXISTS teams(id INTEGER PRIMARY KEY, name TEXT NOT NULL, created_at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS users(
          id INTEGER PRIMARY KEY, team_id INTEGER NOT NULL REFERENCES teams(id), email TEXT NOT NULL UNIQUE,
          display_name TEXT NOT NULL, member_id TEXT NOT NULL, password_hash BLOB NOT NULL,
          is_admin INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL,
          UNIQUE(team_id, member_id));
        CREATE TABLE IF NOT EXISTS sessions(token_hash BLOB PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE, expires_at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS invites(token_hash BLOB PRIMARY KEY, team_id INTEGER NOT NULL REFERENCES teams(id) ON DELETE CASCADE, member_id TEXT NOT NULL, created_by INTEGER NOT NULL REFERENCES users(id), expires_at INTEGER NOT NULL, used_at INTEGER);
        CREATE TABLE IF NOT EXISTS team_integrations(team_id INTEGER PRIMARY KEY REFERENCES teams(id) ON DELETE CASCADE, faceit_key BLOB, leetify_key BLOB, updated_at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS player_integrations(team_id INTEGER NOT NULL REFERENCES teams(id) ON DELETE CASCADE, member_id TEXT NOT NULL, faceit_nickname TEXT NOT NULL, steam_id64 TEXT NOT NULL, updated_at INTEGER NOT NULL, PRIMARY KEY(team_id,member_id));
        CREATE TABLE IF NOT EXISTS team_data(team_id INTEGER PRIMARY KEY REFERENCES teams(id) ON DELETE CASCADE, state_json TEXT NOT NULL, updated_at INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS media(id TEXT PRIMARY KEY, team_id INTEGER NOT NULL REFERENCES teams(id) ON DELETE CASCADE, title TEXT NOT NULL, filename TEXT NOT NULL, mime TEXT NOT NULL, content BLOB NOT NULL, created_at INTEGER NOT NULL);
        CREATE INDEX IF NOT EXISTS sessions_expiry ON sessions(expires_at);
        CREATE INDEX IF NOT EXISTS invites_team ON invites(team_id, used_at);
        """)


def _cipher():
    if Fernet is None:
        raise RuntimeError("Le module cryptography manque. Installe requirements.txt.")
    if not FERNET_PATH.exists():
        key = Fernet.generate_key()
        with open(FERNET_PATH, "xb") as stream:
            stream.write(key)
        try:
            os.chmod(FERNET_PATH, 0o600)
        except OSError:
            pass
    return Fernet(FERNET_PATH.read_bytes())


def encrypt_secret(value: str) -> bytes:
    return _cipher().encrypt(value.encode("utf-8")) if value else b""


def decrypt_secret(value) -> str:
    if not value:
        return ""
    try:
        return _cipher().decrypt(bytes(value)).decode("utf-8")
    except (InvalidToken, ValueError, OSError):
        raise RuntimeError("Impossible de déchiffrer les clés API. Vérifie le fichier .redline-fernet.key.")


def upstream_json(url: str, api_key: str, *, bearer=True):
    headers = {"Accept": "application/json", "User-Agent": "Yurei-CS2-Team-Hub/1.0"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}" if bearer else api_key
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=12) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise ValueError("Clé API refusée par le service.") from None
        if exc.code == 404:
            raise ValueError("Profil ou donnée introuvable. Vérifie l’identifiant et la visibilité du profil.") from None
        if exc.code == 429:
            raise ValueError("Limite de requêtes atteinte. Réessaie dans un instant.") from None
        raise ValueError(f"Le service externe a répondu {exc.code}.") from None
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise ValueError("Service externe indisponible ou réponse invalide.") from exc


def validate_api_keys(faceit_key: str, leetify_key: str):
    if not faceit_key or not leetify_key:
        raise ValueError("Les clés API FACEIT et Leetify sont requises.")
    upstream_json(f"{FACEIT_API}/games?limit=1", faceit_key)
    upstream_json(f"{LEETIFY_API}/api-key/validate", leetify_key)


def validate_player_links(faceit_key: str, leetify_key: str, nickname: str, steam_id64: str):
    if not nickname or len(nickname) > 50:
        raise ValueError("Renseigne ton pseudo FACEIT.")
    if not steam_id64.isdigit() or len(steam_id64) != 17:
        raise ValueError("L’identifiant Steam doit contenir 17 chiffres (SteamID64).")
    query = urllib.parse.urlencode({"nickname": nickname, "game": "cs2"})
    faceit = upstream_json(f"{FACEIT_API}/players?{query}", faceit_key)
    faceit_id = faceit.get("player_id")
    linked_steam = str(faceit.get("steam_id_64") or "")
    if not faceit_id:
        raise ValueError("Pseudo FACEIT introuvable. Vérifie le pseudo exact et le profil CS2.")
    if linked_steam and linked_steam != steam_id64:
        raise ValueError("Le SteamID64 ne correspond pas au compte FACEIT indiqué.")
    leetify = upstream_json(f"{LEETIFY_API}/v3/profile?{urllib.parse.urlencode({'steamId': steam_id64})}", leetify_key)
    returned_id = str(leetify.get("steam64_id") or leetify.get("steam_id") or "")
    if returned_id and returned_id != steam_id64:
        raise ValueError("Le profil Leetify renvoyé ne correspond pas au SteamID64.")
    return faceit, leetify


def password_hash(password: str) -> bytes:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, 310_000)
    return salt + digest


def verify_password(password: str, saved: bytes) -> bool:
    if len(saved) != 48:
        return False
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), saved[:16], 310_000)
    return hmac.compare_digest(saved[16:], digest)


def token_hash(token: str) -> bytes:
    return hashlib.sha256(token.encode()).digest()


class Handler(SimpleHTTPRequestHandler):
    server_version = "YureiHub/1.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def log_message(self, fmt, *args):
        print("[%s] %s" % (self.log_date_time_string(), fmt % args))

    def _send(self, status, value, headers=None):
        body = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for key, val in (headers or {}).items():
            self.send_header(key, val)
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        size = int(self.headers.get("Content-Length", "0"))
        if size > MAX_BODY:
            raise ValueError("Fichier ou requête trop volumineux")
        raw = self.rfile.read(size)
        return json.loads(raw or b"{}")

    def _session(self):
        cookies = SimpleCookie(self.headers.get("Cookie", ""))
        morsel = cookies.get("redline_session")
        if not morsel:
            return None
        with connect() as db:
            return db.execute("""SELECT u.*, t.name team_name FROM sessions s JOIN users u ON u.id=s.user_id
                JOIN teams t ON t.id=u.team_id WHERE s.token_hash=? AND s.expires_at>?""",
                (token_hash(morsel.value), int(time.time()))).fetchone()

    def _required_user(self):
        user = self._session()
        if not user:
            self._send(401, {"error": "Connexion requise"})
        return user

    def _issue_session(self, user_id):
        token = secrets.token_urlsafe(32)
        with connect() as db:
            db.execute("INSERT INTO sessions VALUES(?,?,?)", (token_hash(token), user_id, int(time.time()) + SESSION_SECONDS))
        return {"Set-Cookie": f"redline_session={token}; HttpOnly; SameSite=Lax; Path=/; Max-Age={SESSION_SECONDS}"}

    def do_GET(self):
        u = urlparse(self.path)
        path = u.path
        if path.startswith("/api/"):
            if path == "/api/auth/status":
                with connect() as db:
                    setup = db.execute("SELECT 1 FROM teams LIMIT 1").fetchone() is None
                user = self._session()
                self._send(200, {"setupRequired": setup, "user": self._public_user(user) if user else None})
                return
            if path == "/api/auth/me":
                user = self._required_user()
                if user: self._send(200, {"user": self._public_user(user)})
                return
            if path == "/api/onboarding/status":
                user = self._required_user()
                if not user: return
                with connect() as db:
                    integration = db.execute("SELECT faceit_key,leetify_key FROM team_integrations WHERE team_id=?", (user["team_id"],)).fetchone()
                    profile = db.execute("SELECT 1 FROM player_integrations WHERE team_id=? AND member_id=?", (user["team_id"], user["member_id"])).fetchone()
                keys_ready = bool(integration and integration["faceit_key"] and integration["leetify_key"])
                self._send(200, {"complete": bool(keys_ready and profile), "admin": bool(user["is_admin"]), "keysReady": keys_ready, "profileReady": bool(profile)})
                return
            if path == "/api/admin/invites":
                user = self._required_user()
                if not user: return
                if not user["is_admin"]:
                    self._send(403, {"error": "Réservé à l’administrateur"}); return
                with connect() as db:
                    rows = db.execute("SELECT member_id,expires_at,used_at FROM invites WHERE team_id=? ORDER BY expires_at DESC", (user["team_id"],)).fetchall()
                self._send(200, {"invites": [{"memberId":r["member_id"],"expiresAt":r["expires_at"],"used":bool(r["used_at"]),"expired":r["expires_at"]<=int(time.time())} for r in rows]})
                return
            if path == "/api/admin/roster-status":
                user = self._required_user()
                if not user: return
                if not user["is_admin"]:
                    self._send(403, {"error": "Réservé à l’administrateur"}); return
                with connect() as db:
                    registered = [r[0] for r in db.execute("SELECT member_id FROM users WHERE team_id=?", (user["team_id"],)).fetchall()]
                    pending = [r[0] for r in db.execute("SELECT DISTINCT member_id FROM invites WHERE team_id=? AND used_at IS NULL AND expires_at>?", (user["team_id"], int(time.time()))).fetchall()]
                self._send(200, {"registered":registered,"pending":pending})
                return
            if path == "/api/admin/integrations":
                user = self._required_user()
                if not user: return
                if not user["is_admin"]:
                    self._send(403, {"error": "Réservé à l’administrateur"}); return
                with connect() as db:
                    row = db.execute("SELECT faceit_key,leetify_key FROM team_integrations WHERE team_id=?", (user["team_id"],)).fetchone()
                self._send(200, {"faceitConfigured":bool(row and row["faceit_key"]),"leetifyConfigured":bool(row and row["leetify_key"])})
                return
            if path == "/api/stats/match":
                user = self._required_user()
                if not user: return
                if not self._require_onboarding(user): return
                query = parse_qs(u.query)
                source = query.get("source", [""])[0]
                match_id = query.get("id", [""])[0]
                if source not in ("FACEIT", "CS2", "LEETIFY") or not match_id or len(match_id) > 128:
                    self._send(400, {"error": "Match ou source invalide"}); return
                with connect() as db:
                    keys = db.execute("SELECT faceit_key,leetify_key FROM team_integrations WHERE team_id=?", (user["team_id"],)).fetchone()
                if not keys:
                    self._send(409, {"error": "Intégrations manquantes"}); return
                try:
                    safe_id = urllib.parse.quote(match_id, safe="")
                    if source == "FACEIT":
                        api_key = decrypt_secret(keys["faceit_key"])
                        details = upstream_json(f"{FACEIT_API}/matches/{safe_id}", api_key)
                        stats = upstream_json(f"{FACEIT_API}/matches/{safe_id}/stats", api_key)
                        result = {"details":details,"stats":stats}
                    else:
                        api_key = decrypt_secret(keys["leetify_key"])
                        result = {"details":upstream_json(f"{LEETIFY_API}/v2/matches/{safe_id}", api_key)}
                except (ValueError, RuntimeError) as exc:
                    self._send(502, {"error":str(exc)}); return
                self._send(200, result)
                return
            if path == "/api/stats/team":
                user = self._required_user()
                if not user: return
                if not self._require_onboarding(user): return
                with connect() as db:
                    keys = db.execute("SELECT faceit_key,leetify_key FROM team_integrations WHERE team_id=?", (user["team_id"],)).fetchone()
                    profiles = db.execute("SELECT member_id,faceit_nickname,steam_id64 FROM player_integrations WHERE team_id=?", (user["team_id"],)).fetchall()
                if not keys or not keys["faceit_key"] or not keys["leetify_key"]:
                    self._send(409, {"error": "Les intégrations doivent être configurées par l’administrateur."}); return
                try:
                    faceit_key, leetify_key = decrypt_secret(keys["faceit_key"]), decrypt_secret(keys["leetify_key"])
                except RuntimeError as exc:
                    self._send(500, {"error": str(exc)}); return
                # Responses are returned for display only and deliberately never written to SQLite.
                from concurrent.futures import ThreadPoolExecutor
                def fetch_one(profile):
                    member_id = profile["member_id"]
                    try:
                        q = urllib.parse.urlencode({"nickname":profile["faceit_nickname"],"game":"cs2"})
                        fp = upstream_json(f"{FACEIT_API}/players?{q}", faceit_key)
                        fid = urllib.parse.quote(str(fp["player_id"]), safe="")
                        fs = upstream_json(f"{FACEIT_API}/players/{fid}/stats/cs2", faceit_key)
                        fh = upstream_json(f"{FACEIT_API}/players/{fid}/history?{urllib.parse.urlencode({'game':'cs2','limit':10})}", faceit_key)
                        faceit = {"profile":fp,"stats":fs,"history":fh}
                    except (ValueError, KeyError, RuntimeError) as exc:
                        faceit = {"error":str(exc)}
                    try:
                        sid = profile["steam_id64"]
                        query = urllib.parse.urlencode({"steamId":sid})
                        lp = upstream_json(f"{LEETIFY_API}/v3/profile?{query}", leetify_key)
                        lm = upstream_json(f"{LEETIFY_API}/v3/profile/matches?{urllib.parse.urlencode({'steamId':sid,'limit':10})}", leetify_key)
                        leetify = {"profile":lp,"matches":lm}
                    except (ValueError, RuntimeError) as exc:
                        leetify = {"error":str(exc)}
                    return member_id, {"faceit":faceit,"leetify":leetify}
                with ThreadPoolExecutor(max_workers=5) as pool:
                    result = dict(pool.map(fetch_one, profiles))
                self._send(200, {"players":result,"fetchedAt":int(time.time())})
                return
            if path == "/api/data":
                user = self._required_user()
                if not user: return
                if not self._require_onboarding(user): return
                with connect() as db:
                    row = db.execute("SELECT state_json FROM team_data WHERE team_id=?", (user["team_id"],)).fetchone()
                state = json.loads(row[0]) if row else None
                if state is not None:
                    state["profile"] = user["member_id"]
                self._send(200, {"data": state})
                return
            if path.startswith("/api/media/"):
                user = self._required_user()
                if not user: return
                if not self._require_onboarding(user): return
                media_id = path.rsplit("/", 1)[-1]
                with connect() as db:
                    row = db.execute("SELECT mime,content FROM media WHERE id=? AND team_id=?", (media_id, user["team_id"])).fetchone()
                if not row:
                    self._send(404, {"error": "Média introuvable"}); return
                self.send_response(200); self.send_header("Content-Type", row["mime"]); self.send_header("Cache-Control", "private, max-age=3600")
                self.send_header("Content-Length", str(len(row["content"]))); self.end_headers(); self.wfile.write(row["content"]); return
            self._send(404, {"error": "Route inconnue"}); return
        if path not in ("/", "/index.html"):
            self.send_error(404)
            return
        return super().do_GET()

    @staticmethod
    def _public_user(user):
        return {"id": user["id"], "email": user["email"], "name": user["display_name"],
                "memberId": user["member_id"], "isAdmin": bool(user["is_admin"]), "team": user["team_name"]}

    def _require_onboarding(self, user):
        """Keep team data and media inaccessible until integrations/profile are validated."""
        with connect() as db:
            keys = db.execute("SELECT faceit_key,leetify_key FROM team_integrations WHERE team_id=?", (user["team_id"],)).fetchone()
            profile = db.execute("SELECT 1 FROM player_integrations WHERE team_id=? AND member_id=?", (user["team_id"], user["member_id"])).fetchone()
        if not (keys and keys["faceit_key"] and keys["leetify_key"] and profile):
            self._send(428, {"error": "Termine la configuration obligatoire de ton profil FACEIT et Steam avant d’entrer dans l’application."})
            return False
        return True

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/media":
            body = {}
        else:
            try:
                body = self._body()
            except (ValueError, json.JSONDecodeError) as exc:
                self._send(400, {"error": str(exc) or "Requête JSON invalide"}); return
        if path == "/api/auth/setup":
            team = str(body.get("team", "")).strip()[:80]
            name = str(body.get("name", "")).strip()[:60]
            email = str(body.get("email", "")).strip().lower()[:254]
            password = body.get("password", "")
            member = body.get("memberId")
            faceit_key = str(body.get("faceitApiKey", "")).strip()
            leetify_key = str(body.get("leetifyApiKey", "")).strip()
            nickname = str(body.get("faceitNickname", "")).strip()
            steam_id64 = str(body.get("steamId64", "")).strip()
            if not team or not name or not email or "@" not in email or member not in PLAYERS or not isinstance(password, str) or len(password) < 12:
                self._send(400, {"error": "Équipe, nom, e-mail, profil et mot de passe (12 caractères minimum) requis"}); return
            try:
                validate_api_keys(faceit_key, leetify_key)
                validate_player_links(faceit_key, leetify_key, nickname, steam_id64)
            except ValueError as exc:
                self._send(400, {"error": str(exc)}); return
            with connect() as db:
                db.execute("BEGIN IMMEDIATE")
                if db.execute("SELECT 1 FROM teams LIMIT 1").fetchone():
                    db.rollback()
                    self._send(409, {"error": "La configuration initiale est déjà terminée"}); return
                try:
                    cur = db.execute("INSERT INTO teams(name,created_at) VALUES(?,?)", (team, int(time.time())))
                    uid = db.execute("INSERT INTO users(team_id,email,display_name,member_id,password_hash,is_admin,created_at) VALUES(?,?,?,?,?,1,?)",
                                     (cur.lastrowid, email, name, member, password_hash(password), int(time.time()))).lastrowid
                    db.execute("INSERT INTO team_integrations(team_id,faceit_key,leetify_key,updated_at) VALUES(?,?,?,?)", (cur.lastrowid, encrypt_secret(faceit_key), encrypt_secret(leetify_key), int(time.time())))
                    db.execute("INSERT INTO player_integrations(team_id,member_id,faceit_nickname,steam_id64,updated_at) VALUES(?,?,?,?,?)", (cur.lastrowid, member, nickname, steam_id64, int(time.time())))
                except sqlite3.IntegrityError:
                    db.rollback()
                    self._send(409, {"error": "Cette adresse e-mail est déjà utilisée"}); return
            self._send(201, {"ok": True}, self._issue_session(uid)); return
        if path == "/api/auth/login":
            email = str(body.get("email", "")).strip().lower()
            password = body.get("password", "")
            with connect() as db:
                user = db.execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()
            if not user or not isinstance(password, str) or not verify_password(password, user["password_hash"]):
                self._send(401, {"error": "E-mail ou mot de passe incorrect"}); return
            self._send(200, {"ok": True}, self._issue_session(user["id"])); return
        if path in ("/api/auth/email", "/api/auth/password"):
            user = self._required_user()
            if not user: return
            current = body.get("currentPassword", "")
            if not isinstance(current, str) or not verify_password(current, user["password_hash"]):
                self._send(401, {"error": "Mot de passe actuel incorrect"}); return
            if path == "/api/auth/email":
                email = str(body.get("email", "")).strip().lower()[:254]
                if len(email) < 5 or "@" not in email or "." not in email.rsplit("@", 1)[-1]:
                    self._send(400, {"error": "Adresse e-mail invalide"}); return
                try:
                    with connect() as db:
                        db.execute("UPDATE users SET email=? WHERE id=?", (email, user["id"]))
                except sqlite3.IntegrityError:
                    self._send(409, {"error": "Cette adresse e-mail est déjà utilisée"}); return
                self._send(200, {"ok": True, "email": email}); return
            new_password = body.get("newPassword", "")
            if not isinstance(new_password, str) or len(new_password) < 12:
                self._send(400, {"error": "Le nouveau mot de passe doit contenir au moins 12 caractères"}); return
            with connect() as db:
                db.execute("UPDATE users SET password_hash=? WHERE id=?", (password_hash(new_password), user["id"]))
            self._send(200, {"ok": True}); return
        if path == "/api/onboarding":
            user = self._required_user()
            if not user: return
            nickname = str(body.get("faceitNickname", "")).strip()
            steam_id64 = str(body.get("steamId64", "")).strip()
            with connect() as db:
                integration = db.execute("SELECT faceit_key,leetify_key FROM team_integrations WHERE team_id=?", (user["team_id"],)).fetchone()
            faceit_key = str(body.get("faceitApiKey", "")).strip() if user["is_admin"] else ""
            leetify_key = str(body.get("leetifyApiKey", "")).strip() if user["is_admin"] else ""
            if not faceit_key and integration and integration["faceit_key"]:
                faceit_key = decrypt_secret(integration["faceit_key"])
            if not leetify_key and integration and integration["leetify_key"]:
                leetify_key = decrypt_secret(integration["leetify_key"])
            if not faceit_key or not leetify_key:
                if not user["is_admin"]:
                    self._send(409, {"error": "L’administrateur doit d’abord configurer les clés API FACEIT et Leetify."}); return
                self._send(400, {"error": "Ajoute les deux clés API. Les statistiques ne peuvent pas être activées sans elles."}); return
            try:
                validate_api_keys(faceit_key, leetify_key)
                validate_player_links(faceit_key, leetify_key, nickname, steam_id64)
            except ValueError as exc:
                self._send(400, {"error": str(exc)}); return
            with connect() as db:
                if user["is_admin"]:
                    db.execute("INSERT INTO team_integrations(team_id,faceit_key,leetify_key,updated_at) VALUES(?,?,?,?) ON CONFLICT(team_id) DO UPDATE SET faceit_key=excluded.faceit_key,leetify_key=excluded.leetify_key,updated_at=excluded.updated_at", (user["team_id"], encrypt_secret(faceit_key), encrypt_secret(leetify_key), int(time.time())))
                db.execute("INSERT INTO player_integrations(team_id,member_id,faceit_nickname,steam_id64,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(team_id,member_id) DO UPDATE SET faceit_nickname=excluded.faceit_nickname,steam_id64=excluded.steam_id64,updated_at=excluded.updated_at", (user["team_id"], user["member_id"], nickname, steam_id64, int(time.time())))
            self._send(200, {"ok": True, "complete": True}); return
        if path == "/api/admin/integrations":
            user = self._required_user()
            if not user: return
            if not user["is_admin"]:
                self._send(403, {"error": "Réservé à l’administrateur"}); return
            faceit_key = str(body.get("faceitApiKey", "")).strip()
            leetify_key = str(body.get("leetifyApiKey", "")).strip()
            try:
                validate_api_keys(faceit_key, leetify_key)
            except ValueError as exc:
                self._send(400, {"error": str(exc)}); return
            with connect() as db:
                db.execute("INSERT INTO team_integrations(team_id,faceit_key,leetify_key,updated_at) VALUES(?,?,?,?) ON CONFLICT(team_id) DO UPDATE SET faceit_key=excluded.faceit_key,leetify_key=excluded.leetify_key,updated_at=excluded.updated_at", (user["team_id"], encrypt_secret(faceit_key), encrypt_secret(leetify_key), int(time.time())))
            self._send(200, {"ok": True}); return
        if path == "/api/auth/register":
            name = str(body.get("name", "")).strip()[:60]
            email = str(body.get("email", "")).strip().lower()[:254]
            password = body.get("password", "")
            code = str(body.get("invite", "")).strip()
            if not name or "@" not in email or not isinstance(password, str) or len(password) < 12 or not code:
                self._send(400, {"error": "Nom, e-mail, code d’invitation et mot de passe (12 caractères minimum) requis"}); return
            with connect() as db:
                try:
                    db.execute("BEGIN IMMEDIATE")
                    inv = db.execute("SELECT * FROM invites WHERE token_hash=? AND used_at IS NULL AND expires_at>?", (token_hash(code), int(time.time()))).fetchone()
                    if not inv:
                        db.rollback()
                        self._send(400, {"error": "Code d’activation invalide, déjà utilisé ou expiré"}); return
                    uid = db.execute("INSERT INTO users(team_id,email,display_name,member_id,password_hash,is_admin,created_at) VALUES(?,?,?,?,?,0,?)",
                        (inv["team_id"], email, name, inv["member_id"], password_hash(password), int(time.time()))).lastrowid
                    consumed = db.execute("UPDATE invites SET used_at=? WHERE token_hash=? AND used_at IS NULL AND expires_at>?", (int(time.time()), token_hash(code), int(time.time())))
                    if consumed.rowcount != 1:
                        raise sqlite3.IntegrityError("Code d’activation déjà utilisé")
                except sqlite3.IntegrityError:
                    db.rollback()
                    self._send(409, {"error": "E-mail ou membre déjà associé à un compte"}); return
            self._send(201, {"ok": True}, self._issue_session(uid)); return
        if path == "/api/auth/logout":
            cookies = SimpleCookie(self.headers.get("Cookie", "")); c = cookies.get("redline_session")
            if c:
                with connect() as db: db.execute("DELETE FROM sessions WHERE token_hash=?", (token_hash(c.value),))
            self._send(200, {"ok": True}, {"Set-Cookie": "redline_session=; HttpOnly; SameSite=Lax; Path=/; Max-Age=0"}); return
        if path == "/api/auth/invites":
            user = self._required_user()
            if not user: return
            if not user["is_admin"]:
                self._send(403, {"error": "Réservé à l’administrateur"}); return
            member = body.get("memberId")
            if member not in PLAYERS:
                self._send(400, {"error": "Membre invalide"}); return
            code = secrets.token_urlsafe(9)
            with connect() as db:
                exists = db.execute("SELECT 1 FROM users WHERE team_id=? AND member_id=?", (user["team_id"], member)).fetchone()
                if exists:
                    self._send(409, {"error": "Un compte existe déjà pour ce membre"}); return
                # Keep one usable activation code per roster slot. Codes are stored as hashes only.
                db.execute("UPDATE invites SET expires_at=? WHERE team_id=? AND member_id=? AND used_at IS NULL", (int(time.time()), user["team_id"], member))
                db.execute("INSERT INTO invites(token_hash,team_id,member_id,created_by,expires_at) VALUES(?,?,?,?,?)",
                           (token_hash(code), user["team_id"], member, user["id"], int(time.time()) + 7*24*3600))
            self._send(201, {"code": code, "memberId": member, "expiresInDays": 7}); return
        if path == "/api/data":
            user = self._required_user()
            if not user: return
            if not self._require_onboarding(user): return
            incoming = body.get("data")
            if not isinstance(incoming, dict):
                self._send(400, {"error": "Données invalides"}); return
            self._save_team_data(user, incoming); self._send(200, {"ok": True}); return
        if path == "/api/media":
            user = self._required_user()
            if not user: return
            if not self._require_onboarding(user): return
            size = int(self.headers.get("Content-Length", "0"))
            if size < 1 or size > MAX_BODY:
                self._send(413, {"error": "Fichier vide ou supérieur à 120 Mo"}); return
            query = parse_qs(urlparse(self.path).query)
            map_name = query.get("map", [""])[0]
            group = query.get("group", [""])[0]
            title = unquote(self.headers.get("X-Media-Title", "")).strip()[:100]
            filename = unquote(self.headers.get("X-File-Name", "media"))[:255]
            mime = self.headers.get("Content-Type", "application/octet-stream").split(";")[0]
            valid_video = group == "lineups" and (mime in ("video/mp4", "video/webm", "video/quicktime") or filename.lower().endswith((".mp4", ".webm", ".mov")))
            valid_png = group == "callouts" and (mime == "image/png" or filename.lower().endswith(".png"))
            if map_name not in ("Mirage", "Inferno", "Ancient", "Nuke", "Anubis", "Dust II") or not title or not (valid_video or valid_png):
                self._send(400, {"error": "Map, nom ou format de fichier invalide"}); return
            content = self.rfile.read(size)
            media_id = "media-" + secrets.token_urlsafe(18)
            with connect() as db:
                db.execute("INSERT INTO media VALUES(?,?,?,?,?,?,?)", (media_id, user["team_id"], title, filename, mime, content, int(time.time())))
            self._send(201, {"id": media_id, "title": title, "fileName": filename, "mime": mime}); return
        self._send(404, {"error": "Route inconnue"})

    def _save_team_data(self, user, incoming):
        team_id, member = user["team_id"], user["member_id"]
        incoming["profile"] = member
        with connect() as db:
            row = db.execute("SELECT state_json FROM team_data WHERE team_id=?", (team_id,)).fetchone()
            old = json.loads(row[0]) if row else {}
            if user["is_admin"] and not row:
                merged = incoming
            else:
                merged = old.copy()
                # Team admins own roster-wide stats and profile edits. Regular members
                # may update only their own avatar and lineup notes in playerNotes.
                for key in ("view", "matches", "roleNotes", "mapNotes", "mapMedia"):
                    if key in incoming: merged[key] = incoming[key]
                if user["is_admin"]:
                    for key in ("playerStats", "playerNotes"):
                        if key in incoming: merged[key] = incoming[key]
                else:
                    old_notes = old.get("playerNotes", {})
                    new_notes = incoming.get("playerNotes", {})
                    if not isinstance(old_notes, dict): old_notes = {}
                    if not isinstance(new_notes, dict): new_notes = {}
                    notes = old_notes.copy()
                    old_mine = notes.get(member, {})
                    new_mine = new_notes.get(member, {})
                    if isinstance(old_mine, dict) and isinstance(new_mine, dict):
                        mine = old_mine.copy()
                        for field in ("avatarData", "lineups"):
                            if field in new_mine: mine[field] = new_mine[field]
                        notes[member] = mine
                    merged["playerNotes"] = notes
                if user["is_admin"] and "playerStats" in incoming:
                    merged["playerStats"] = incoming["playerStats"]
                old_routines = old.get("routines", {})
                new_routines = incoming.get("routines", {})
                routines = old_routines.copy() if isinstance(old_routines, dict) else {}
                if isinstance(new_routines, dict) and member in new_routines: routines[member] = new_routines[member]
                merged["routines"] = routines
                old_avail = old.get("availability", {})
                new_avail = incoming.get("availability", {})
                availability = old_avail.copy() if isinstance(old_avail, dict) else {}
                if isinstance(new_avail, dict):
                    for key in list(availability):
                        if key.startswith(member + "|"): availability.pop(key, None)
                    availability.update({k:v for k,v in new_avail.items() if isinstance(k,str) and k.startswith(member + "|")})
                merged["availability"] = availability
                old_events = old.get("events", [])
                new_events = incoming.get("events", [])
                if not isinstance(old_events, list): old_events = []
                if not isinstance(new_events, list): new_events = []
                merged["events"] = [e for e in old_events if not isinstance(e,dict) or e.get("owner") != member] + [e for e in new_events if isinstance(e,dict) and e.get("owner") == member]
                # Preserve the known shared sections above; accept no arbitrary keys
                # from a regular member, which could bypass field-level permissions.
            merged["profile"] = member
            db.execute("INSERT INTO team_data(team_id,state_json,updated_at) VALUES(?,?,?) ON CONFLICT(team_id) DO UPDATE SET state_json=excluded.state_json,updated_at=excluded.updated_at",
                       (team_id, json.dumps(merged, ensure_ascii=False, separators=(",", ":")), int(time.time())))

    def do_PUT(self):
        path = urlparse(self.path).path
        if path == "/api/data":
            user = self._required_user()
            if not user: return
            if not self._require_onboarding(user): return
            try: body = self._body()
            except (ValueError, json.JSONDecodeError) as exc:
                self._send(400, {"error": str(exc) or "Requête JSON invalide"}); return
            state = body.get("data")
            if not isinstance(state, dict): self._send(400, {"error": "Données invalides"}); return
            self._save_team_data(user, state); self._send(200, {"ok": True}); return
        self._send(404, {"error": "Route inconnue"})

    def do_DELETE(self):
        path = urlparse(self.path).path
        if path == "/api/admin/invites":
            user = self._required_user()
            if not user: return
            if not user["is_admin"]:
                self._send(403, {"error": "Réservé à l’administrateur"}); return
            member = parse_qs(urlparse(self.path).query).get("memberId", [""])[0]
            if member not in PLAYERS:
                self._send(400, {"error": "Membre invalide"}); return
            with connect() as db:
                db.execute("UPDATE invites SET expires_at=? WHERE team_id=? AND member_id=? AND used_at IS NULL", (int(time.time()), user["team_id"], member))
            self._send(200, {"ok": True}); return
        if path.startswith("/api/media/"):
            user = self._required_user()
            if not user: return
            if not self._require_onboarding(user): return
            media_id = path.rsplit("/", 1)[-1]
            with connect() as db: db.execute("DELETE FROM media WHERE id=? AND team_id=?", (media_id, user["team_id"]))
            self._send(200, {"ok": True}); return
        self._send(404, {"error": "Route inconnue"})


if __name__ == "__main__":
    if Fernet is None:
        raise SystemExit("Dépendance manquante : exécute `py -3 -m pip install -r requirements.txt`.")
    init_db()
    print(f"Yurei Team Hub actif : http://{HOST}:{PORT}/")
    print(f"Base SQLite : {DB_PATH}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
