#!/usr/bin/env python3
"""Offline mock of the OmniRoute management API used by the test-suite.

It mirrors the surface of the real npm package (v3.8.50) that setup.sh talks
to, including the quirks that were verified against the real server:

  * POST /api/auth/login answers {"success": true} and sets the
    `auth_token` management session cookie; every other /api/* route needs it.
  * POST /api/providers UPSERTS on (provider, name) and answers 201.
  * POST /api/keys requires the `name` field (the OpenAPI document says
    `label`, the implementation refuses to work without `name`) and creates a
    NEW key on every call - it is not idempotent.
  * POST /api/combos answers 400 when the combo name already exists, so an
    update has to go through PUT /api/combos/{id}.
  * GET /api/models/catalog returns the live model ids per provider.

Usage:
  mock_omniroute.py --port 20871 [--log requests.log]

Debug endpoints (used by the test-suite only):
  POST /__reset   -> clears all state
  GET  /__state   -> JSON dump of the current state
"""

from __future__ import annotations

import argparse
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SESSION_TOKEN = "mock-session-token"

# provider id -> catalog entries (mirrors the shape of the real catalog)
CATALOG = {
    "groq": [
        {"id": "groq/openai/gpt-oss-120b", "type": "chat", "capabilities": {"tool_calling": True}},
        {"id": "groq/openai/gpt-oss-20b", "type": "chat", "capabilities": {"tool_calling": True}},
        {"id": "groq/llama-3.3-70b-versatile", "type": "chat", "capabilities": {"tool_calling": True}},
        {"id": "groq/qwen/qwen3-coder-32b", "type": "chat", "capabilities": {"tool_calling": True}},
        {"id": "groq/whisper-large-v3", "type": "audio", "capabilities": {"tool_calling": False}},
        {"id": "groq/llama-3.1-8b-instant", "type": "chat", "capabilities": {"tool_calling": False}},
    ],
    "openrouter": [
        {"id": "openrouter/qwen/qwen3-coder:free", "type": "chat", "capabilities": {"tool_calling": True}},
        {"id": "openrouter/deepseek/deepseek-chat-v3.1:free", "type": "chat", "capabilities": {"tool_calling": True}},
        {"id": "openrouter/openai/text-embedding-3-large", "type": "embedding", "capabilities": {"tool_calling": False}},
    ],
    "gemini": [
        {"id": "gemini/gemini-2.5-flash", "type": "chat", "capabilities": {"tool_calling": True}},
        {"id": "gemini/gemini-2.0-flash", "type": "chat", "capabilities": {"tool_calling": True}},
    ],
    "cerebras": [
        {"id": "cerebras/gpt-oss-120b", "type": "chat", "capabilities": {"tool_calling": True}},
        {"id": "cerebras/zai-glm-4.7", "type": "chat", "capabilities": {"tool_calling": True}},
    ],
    "mistral": [
        {"id": "mistral/devstral-latest", "type": "chat", "capabilities": {"tool_calling": True}},
        {"id": "mistral/codestral-latest", "type": "chat", "capabilities": {"tool_calling": True}},
    ],
    "sambanova": [
        {"id": "sambanova/DeepSeek-V3.2", "type": "chat", "capabilities": {"tool_calling": True}},
    ],
    "nvidia": [
        {"id": "nvidia/z-ai/glm-5.2", "type": "chat", "capabilities": {"tool_calling": True}},
    ],
    "together": [
        {"id": "together/meta-llama/Llama-3.3-70B-Instruct-Turbo-Free", "type": "chat",
         "capabilities": {"tool_calling": True}},
    ],
    # not an API-key provider on the real server - must be rejected
    "github": [],
}

LOCK = threading.Lock()
STATE = {"connections": [], "keys": [], "combos": [], "seq": 0}
LOG_PATH = ""


def log_request_line(method: str, path: str, body: str) -> None:
    if not LOG_PATH:
        return
    with open(LOG_PATH, "a", encoding="utf-8") as handle:
        handle.write(f"{method} {path} {body}\n")


def next_id() -> str:
    STATE["seq"] += 1
    return f"id{STATE['seq']:04d}"


def mask_key(value: str) -> str:
    if len(value) >= 8:
        return f"{value[:4]}****{value[-4:]}"
    return "****"


def parse_models(models):
    """Normalise combo models exactly like the real server: a plain string is
    split into providerId/model, an object is used as-is."""
    parsed = []
    for index, item in enumerate(models or []):
        if isinstance(item, str):
            provider, _, model = item.partition("/")
            entry = {"id": f"combo-model-{index + 1}", "kind": "model",
                     "model": model, "providerId": provider, "weight": 0}
        elif isinstance(item, dict):
            entry = dict(item)
            entry.setdefault("kind", "model")
            entry.setdefault("weight", 0)
        else:
            continue
        parsed.append(entry)
    return parsed


class Handler(BaseHTTPRequestHandler):
    server_version = "MockOmniRoute/1.0"
    protocol_version = "HTTP/1.1"

    # -- helpers ---------------------------------------------------------
    def _send_json(self, status: int, payload, cookies=None) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for cookie in cookies or []:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(body)

    def _body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        raw = self.rfile.read(length).decode("utf-8", "replace")
        try:
            data = json.loads(raw)
        except Exception:
            return {}
        return data if isinstance(data, dict) else {}

    def _authenticated(self) -> bool:
        cookie = self.headers.get("Cookie") or ""
        auth = self.headers.get("Authorization") or ""
        if SESSION_TOKEN in cookie:
            return True
        return auth.startswith("Bearer ") and len(auth) > 12

    def log_message(self, fmt, *args):  # keep the test output clean
        return

    # -- routing ---------------------------------------------------------
    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        self._handle("POST")

    def do_PUT(self):
        self._handle("PUT")

    def do_PATCH(self):
        self._handle("PATCH")

    def do_DELETE(self):
        self._handle("DELETE")

    def _handle(self, method: str):
        path = self.path.split("?", 1)[0]
        body = self._body()
        log_request_line(method, path, json.dumps(body) if body else "")

        with LOCK:
            if path == "/healthz":
                self._send_json(200, {"status": "ok"})
                return
            if path == "/__reset" and method == "POST":
                STATE.update({"connections": [], "keys": [], "combos": [], "seq": 0})
                self._send_json(200, {"reset": True})
                return
            if path == "/__state" and method == "GET":
                self._send_json(200, STATE)
                return

            if method == "POST" and path == "/api/auth/login":
                expected = self.server.expected_password()  # type: ignore[attr-defined]
                given = str(body.get("password") or "")
                if self.server.reject_login or not given or (expected and given != expected):  # type: ignore[attr-defined]
                    self._send_json(401, {"error": {"message": "Invalid password"}})
                    return
                self._send_json(
                    200,
                    {"success": True},
                    cookies=[f"auth_token={SESSION_TOKEN}; Path=/; HttpOnly; SameSite=lax"],
                )
                return

            # inference API
            if path == "/v1/models":
                if not self._authenticated():
                    self._send_json(401, {"error": {"message": "Missing API key"}})
                    return
                data = [{"id": combo["name"], "object": "model", "owned_by": "combo"} for combo in STATE["combos"]]
                for provider, entries in CATALOG.items():
                    data += [{"id": e["id"], "object": "model", "owned_by": provider} for e in entries]
                self._send_json(200, {"object": "list", "data": data})
                return
            if path == "/v1/messages" and method == "POST":
                if not self._authenticated():
                    self._send_json(401, {"error": {"message": "Missing API key"}})
                    return
                names = {combo["name"] for combo in STATE["combos"]}
                model = str(body.get("model") or "")
                if model not in names:
                    self._send_json(404, {"error": {"message": f"model '{model}' not found"}})
                    return
                self._send_json(200, {"content": [{"type": "text", "text": "pong"}], "model": model})
                return

            # management API (session cookie or bearer)
            if path.startswith("/api/") and not self._authenticated():
                self._send_json(401, {"error": {"message": "Authentication required"}})
                return

            if path == "/api/providers":
                if method == "GET":
                    self._send_json(200, {"connections": STATE["connections"], "total": len(STATE["connections"])})
                    return
                if method == "POST":
                    provider = str(body.get("provider") or "")
                    if provider not in CATALOG:
                        self._send_json(400, {"error": {"message": f"Unknown provider '{provider}'"}})
                        return
                    name = str(body.get("name") or f"{provider}-connection")
                    existing = next((c for c in STATE["connections"]
                                     if c["provider"] == provider and c["name"] == name), None)
                    payload = {
                        "provider": provider,
                        "name": name,
                        "apiKey": mask_key(str(body.get("apiKey") or "")),
                        "isActive": bool(body.get("isActive", True)),
                    }
                    if existing:
                        existing.update(payload)
                        connection = existing
                    else:
                        connection = {"id": next_id(), **payload}
                        STATE["connections"].append(connection)
                    self._send_json(201, {"connection": connection})
                    return

            match = re.match(r"^/api/providers/([^/]+)$", path)
            if match:
                cid = match.group(1)
                row = next((c for c in STATE["connections"] if c["id"] == cid), None)
                if not row:
                    self._send_json(404, {"error": {"message": "Not found"}})
                    return
                if method == "DELETE":
                    STATE["connections"].remove(row)
                    self._send_json(200, {"deleted": True})
                    return
                if method in ("PATCH", "PUT"):
                    row.update({k: v for k, v in body.items() if k in ("name", "apiKey", "isActive")})
                    self._send_json(200, {"connection": row})
                    return

            match = re.match(r"^/api/providers/([^/]+)/test$", path)
            if match and method == "POST":
                self._send_json(200, {"ok": True})
                return

            if path == "/api/models/catalog" and method == "GET":
                catalog = {
                    provider: {"provider": provider, "active": True, "models": entries}
                    for provider, entries in CATALOG.items() if entries
                }
                self._send_json(200, {"catalog": catalog, "catalogVersion": "mock"})
                return

            if path == "/api/keys":
                if method == "GET":
                    self._send_json(200, {"keys": STATE["keys"], "total": len(STATE["keys"])})
                    return
                if method == "POST":
                    if not body.get("name"):
                        self._send_json(400, {"error": {"message": "Invalid request", "details": [
                            {"field": "name", "message": "Invalid input: expected string, received undefined"}]}})
                        return
                    index = len(STATE["keys"]) + 1
                    key = {
                        "id": next_id(),
                        "name": str(body["name"]),
                        "key": f"sk-mockkey{index:04d}",
                        "keyPreview": f"sk-mock****{index:04d}",
                        "createdAt": f"2026-01-{index:02d}T00:00:00.000Z",
                    }
                    STATE["keys"].append(key)
                    self._send_json(201, key)
                    return

            match = re.match(r"^/api/keys/([^/]+)$", path)
            if match:
                kid = match.group(1)
                row = next((k for k in STATE["keys"] if k["id"] == kid), None)
                if not row:
                    self._send_json(404, {"error": {"message": "Not found"}})
                    return
                if method == "DELETE":
                    STATE["keys"].remove(row)
                    self._send_json(200, {"deleted": True})
                    return
                if method in ("PATCH", "PUT"):
                    row.update(body)
                    self._send_json(200, row)
                    return

            if path == "/api/combos":
                if method == "GET":
                    self._send_json(200, {"combos": STATE["combos"]})
                    return
                if method == "POST":
                    name = str(body.get("name") or "")
                    if any(c["name"] == name for c in STATE["combos"]):
                        self._send_json(400, {"error": {
                            "message": f"A combo named '{name}' already exists - use PUT to update it."}})
                        return
                    combo = {
                        "id": next_id(),
                        "name": name,
                        "models": parse_models(body.get("models")),
                        "strategy": str(body.get("strategy") or "priority"),
                        "computed_context_length": 400000,
                    }
                    STATE["combos"].append(combo)
                    self._send_json(201, combo)
                    return

            match = re.match(r"^/api/combos/([^/]+)$", path)
            if match:
                cid = match.group(1)
                row = next((c for c in STATE["combos"] if c["id"] == cid), None)
                if not row:
                    self._send_json(404, {"error": {"message": "Not found"}})
                    return
                if method == "DELETE":
                    STATE["combos"].remove(row)
                    self._send_json(200, {"deleted": True})
                    return
                if method in ("PATCH", "PUT"):
                    if "models" in body:
                        row["models"] = parse_models(body["models"])
                    if "strategy" in body:
                        row["strategy"] = str(body["strategy"])
                    if "name" in body and body["name"]:
                        row["name"] = str(body["name"])
                    self._send_json(200, row)
                    return

        self._send_json(404, {"error": {"message": f"No mock route for {method} {path}"}})


def main() -> int:
    global LOG_PATH
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=20871)
    parser.add_argument("--log", default="")
    parser.add_argument("--env-file", default="", help="read INITIAL_PASSWORD from this .env")
    parser.add_argument("--reject-login", action="store_true", help="always answer 401 on login")
    args = parser.parse_args()
    LOG_PATH = args.log

    class Server(ThreadingHTTPServer):
        daemon_threads = True
        allow_reuse_address = True

        def __init__(self, *a, **kw):
            super().__init__(*a, **kw)
            self.env_file = args.env_file
            self.reject_login = args.reject_login

        def expected_password(self):
            """Mirror the real server: the dashboard password comes from
            INITIAL_PASSWORD in <DATA_DIR>/.env (empty = accept any value)."""
            if not self.env_file:
                return ""
            try:
                with open(self.env_file, encoding="utf-8") as handle:
                    for line in handle:
                        if line.startswith("INITIAL_PASSWORD="):
                            return line.split("=", 1)[1].strip()
            except OSError:
                return ""
            return ""

    server = Server(("127.0.0.1", args.port), Handler)
    print(f"mock-omniroute listening on 127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
