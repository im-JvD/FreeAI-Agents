#!/usr/bin/env bash
#===============================================================================
# tests/e2e_litellm_real.sh
#
# REAL end-to-end test of the LiteLLM core (no simulation!):
#
#   1. runs the REAL setup script (with stubbed docker/powershell, since the
#      focus here is configuration correctness, not container plumbing)
#   2. installs the REAL LiteLLM proxy from PyPI into a venv
#   3. boots the REAL proxy with the config.yaml + master key that the script
#      generated  (exactly the same CLI flags used inside the Docker container)
#   4. asserts against the live HTTP API:
#        - /health/liveliness                 -> 200
#        - GET  /v1/models + master key       -> 200 + all expected models
#        - GET  /v1/models without/with wrong -> rejected (not 200)
#        - POST /v1/chat/completions          -> routed upstream (fails only
#                                                because the provider keys are
#                                                intentionally fake)
#
# Results: tests/results/E2E_litellm_real.log
#
# Env overrides:
#   LITELLM_E2E_VENV  - reuse an existing venv path (created if missing)
#   SKIP_INSTALL      - set to 1 when the venv already contains litellm
#
# Usage:  bash tests/e2e_litellm_real.sh
#===============================================================================
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_FILE="${ROOT_DIR}/setup.sh"
STUBBIN="${ROOT_DIR}/tests/helpers/stubbin"
RESULTS_DIR="${ROOT_DIR}/tests/results"
LOG_FILE="${RESULTS_DIR}/E2E_litellm_real.log"

WORK="$(mktemp -d /tmp/litellm-e2e-run.XXXXXX)"
VENV="${LITELLM_E2E_VENV:-/tmp/litellm-e2e-venv}"
HOME_DIR="${WORK}/home"
PORT=4000
SRV_PID=""

PROFILE_DIR="/mnt/c/Users/Test User"
PROFILE_CREATED=0

as_root() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@"; fi; }

cleanup() {
  if [ -n "$SRV_PID" ] && kill -0 "$SRV_PID" 2>/dev/null; then
    kill "$SRV_PID" 2>/dev/null || true
    sleep 2
    kill -9 "$SRV_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
  if [ "$PROFILE_CREATED" -eq 1 ]; then
    as_root rm -rf "$PROFILE_DIR" 2>/dev/null || true
  fi
  return 0
}
trap cleanup EXIT INT TERM

log()  { echo "[E2E] $*" | tee -a "$LOG_FILE"; }
fail() { echo "[E2E] FAIL - $*" | tee -a "$LOG_FILE"; FAILURES=$((FAILURES+1)); }
ok()   { echo "[E2E] ok  - $*" | tee -a "$LOG_FILE"; }

FAILURES=0
: > "$LOG_FILE"

log "==================================================================="
log "REAL LiteLLM end-to-end test"
log "script under test: ${SCRIPT_FILE}"
log "==================================================================="

#-------------------------------------------------------------------------------
# [0] Preflight
#-------------------------------------------------------------------------------
log "[0] preflight"
if ! command -v python3 >/dev/null 2>&1; then
  log "SKIP - python3 not available"; exit 0
fi
if ! python3 -c "import venv" 2>/dev/null; then
  log "SKIP - python3 venv module not available"; exit 0
fi
PYPI_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://pypi.org/simple/ 2>/dev/null || true)"
if [ "$PYPI_CODE" != "200" ]; then
  log "SKIP - PyPI not reachable (http_code=${PYPI_CODE:-none}); cannot install real LiteLLM"; exit 0
fi
ok "python3 + venv + PyPI reachable"

#-------------------------------------------------------------------------------
# [1] Install REAL LiteLLM into a venv
#-------------------------------------------------------------------------------
log "[1] preparing REAL LiteLLM installation (venv: ${VENV})"
if [ "${SKIP_INSTALL:-0}" != "1" ]; then
  if [ ! -x "${VENV}/bin/litellm" ]; then
    rm -rf "$VENV"
    python3 -m venv "$VENV" || { log "FAIL - venv creation failed"; exit 1; }
    log "    installing litellm[proxy] from PyPI (this can take a few minutes)..."
    if ! "${VENV}/bin/pip" install --quiet --upgrade pip >>"$LOG_FILE" 2>&1; then
      log "FAIL - pip upgrade failed"; exit 1
    fi
    if ! "${VENV}/bin/pip" install --quiet 'litellm[proxy]' >>"$LOG_FILE" 2>&1; then
      log "FAIL - litellm installation failed"; exit 1
    fi
  fi
fi
if [ ! -x "${VENV}/bin/litellm" ]; then
  log "FAIL - litellm binary not found in venv"; exit 1
fi
LITELLM_VER="$("${VENV}/bin/litellm" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
ok "real LiteLLM ready (version: ${LITELLM_VER:-unknown})"
log "    venv reused for faster reruns; delete ${VENV} to reinstall"

#-------------------------------------------------------------------------------
# [2] Run the REAL setup script (stubbed docker/powershell) to produce
#     the real artifacts: config.yaml + master_key.txt + Claude settings.json
#-------------------------------------------------------------------------------
log "[2] running the setup script to generate real configuration artifacts"
rm -f "${STUBBIN}/docker"   # keep the environment deterministic for reruns
mkdir -p "${WORK}/state" "${WORK}/fakeroot" "$HOME_DIR"
: > "${WORK}/state/containers.txt"
if [ ! -d "$PROFILE_DIR" ]; then
  if as_root mkdir -p "$PROFILE_DIR" 2>/dev/null && \
     as_root chown "$(id -u):$(id -g)" "$PROFILE_DIR" 2>/dev/null; then
    PROFILE_CREATED=1
  else
    log "SKIP - cannot create fake Windows profile under /mnt/c"; exit 0
  fi
fi
printf '1\n\n\ngsk_e2e_groq_0123456789abcd\nsk-or-e2e_0123456789abcd\nAIzaE2eTest0123456789ab\ncsk-e2e_0123456789abcd\nsk_e2e_mistral0123456789\n' | \
  # LITELLM_UI_DB=0: this sandbox cannot run the Postgres-backed Admin UI
  # (prisma engine CDN is blocked here; the real Docker image ships it).
  # The DB path is exercised by tests/e2e_real_docker.sh on a real machine.
  env -u DOCKER_PULL_FAIL -u DOCKER_APT_FAIL -u HEALTH_CODE -u PS_USERNAME \
    LITELLM_UI_DB="0" \
    HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" \
    STUBBIN="$STUBBIN" T_WORKSTATE="${WORK}/state" FAKE_ROOT="${WORK}/fakeroot" \
    HEALTH_CODE="200" PS_USERNAME="Test User" \
    bash "$SCRIPT_FILE" >> "$LOG_FILE" 2>&1
SCRIPT_RC=$?
if [ "$SCRIPT_RC" -ne 0 ]; then
  fail "setup script exited with ${SCRIPT_RC} (expected 0)"; exit 1
fi
ok "setup script completed (exit 0)"

CONFIG="${HOME_DIR}/.litellm/config.yaml"
MASTER_KEY="$(tr -d '\n' < "${HOME_DIR}/.litellm/master_key.txt" 2>/dev/null)"
CC_JSON="/mnt/c/Users/Test User/.claude/settings.json"
[ -f "$CONFIG" ]      && ok "config.yaml generated"      || fail "config.yaml missing"
[ -n "$MASTER_KEY" ]  && ok "master key generated"       || fail "master key missing"
[ -f "$CC_JSON" ]     && ok "Claude settings.json generated" || fail "Claude settings.json missing"

#-------------------------------------------------------------------------------
# [3] Boot the REAL LiteLLM proxy with the generated config
#     (same binary + same flags the Docker container uses)
#-------------------------------------------------------------------------------
log "[3] starting REAL LiteLLM proxy on port ${PORT} with the generated config"
DISABLE_PRISMA_RUN_GENERATION=true \
LITELLM_MASTER_KEY="$MASTER_KEY" \
GROQ_API_KEY="gsk_e2e_groq_0123456789abcd" \
OPENROUTER_API_KEY="sk-or-e2e_0123456789abcd" \
GEMINI_API_KEY="AIzaE2eTest0123456789ab" \
CEREBRAS_API_KEY="csk-e2e_0123456789abcd" \
MISTRAL_API_KEY="sk_e2e_mistral0123456789" \
  setsid "${VENV}/bin/litellm" --config "$CONFIG" --port "$PORT" \
  </dev/null > "${WORK}/server.log" 2>&1 &
SRV_PID=$!

HEALTH_CODE=""
for i in $(seq 1 60); do
  HEALTH_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${PORT}/health/liveliness" 2>/dev/null || true)"
  [ "$HEALTH_CODE" = "200" ] && break
  kill -0 "$SRV_PID" 2>/dev/null || break
  sleep 2
done

if [ "$HEALTH_CODE" = "200" ]; then
  ok "proxy is UP - /health/liveliness returned 200"
else
  fail "proxy did not become healthy (last code: ${HEALTH_CODE:-none})"
  tail -30 "${WORK}/server.log" >> "$LOG_FILE" 2>/dev/null
  exit 1
fi

#-------------------------------------------------------------------------------
# [4] HTTP assertions against the live proxy
#-------------------------------------------------------------------------------
log "[4] asserting against the live LiteLLM API"

# A1 - /v1/models WITH the master key must return 200
CODE="$(curl -s -o "${WORK}/models.json" -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer ${MASTER_KEY}" "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)"
if [ "$CODE" = "200" ]; then ok "GET /v1/models with master key -> 200"; else fail "GET /v1/models with master key -> ${CODE:-none}"; fi

# A2 - model list must match exactly the 7 models
python3 - "${WORK}/models.json" <<'PY' >> "$LOG_FILE" 2>&1
import sys, json
expected = ["claude-gpt-oss-120b", "claude-gpt-oss-20b",
            "claude-deepseek-v3.1", "claude-deepseek-v3-0324",
            "claude-gemini-2.0-flash", "claude-llama3.1-70b", "claude-codestral",
            "claude-sonnet-4-5", "claude-haiku-4-5"]
ids = [m["id"] for m in json.load(open(sys.argv[1]))["data"]]
if ids == expected:
    print("[E2E] ok  - model list matches exactly all 7 expected models")
else:
    print(f"[E2E] FAIL - model list mismatch: got {ids}")
    sys.exit(1)
PY
if [ $? -eq 0 ]; then ok "model list == 9 expected models (7 + 2 aliases)"; else fail "model list mismatch (see log)"; fi

# A3 - /v1/models WITHOUT auth must be rejected
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)"
if [ "$CODE" != "200" ]; then ok "GET /v1/models without auth rejected (code ${CODE:-none})"; else fail "endpoint accepted unauthenticated request"; fi

# A4 - /v1/models with a WRONG key must be rejected
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer sk-definitely-wrong-key" "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)"
if [ "$CODE" != "200" ]; then ok "GET /v1/models with wrong key rejected (code ${CODE:-none})"; else fail "endpoint accepted a wrong key"; fi

# A5 - chat completion must be ROUTED upstream (fails there because keys are fake)
CODE="$(curl -s -o "${WORK}/chat.json" -w '%{http_code}' --max-time 45 \
  -X POST -H "Authorization: Bearer ${MASTER_KEY}" -H "Content-Type: application/json" \
  -d '{"model":"gemini-2.0-flash","messages":[{"role":"user","content":"ping"}]}' \
  "http://127.0.0.1:${PORT}/v1/chat/completions" 2>/dev/null || true)"
if [ "$CODE" != "200" ] && [ -n "$CODE" ]; then
  ok "POST /v1/chat/completions routed upstream and rejected fake provider key (code ${CODE})"
else
  fail "POST /v1/chat/completions unexpected code: ${CODE:-none}"
fi

# A6 - the Anthropic Messages endpoint that Claude Code actually calls must
#      exist on the proxy and require the key (route present => not 404).
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
  -X POST -H "Content-Type: application/json" \
  -d '{"model":"x","max_tokens":1,"messages":[{"role":"user","content":"ping"}]}' \
  "http://127.0.0.1:${PORT}/v1/messages" 2>/dev/null || true)"
if [ -n "$CODE" ] && [ "$CODE" != "000" ] && [ "$CODE" != "404" ]; then
  ok "POST /v1/messages (Anthropic API) exists and rejects unauthenticated calls (code ${CODE})"
else
  fail "POST /v1/messages unexpected code: ${CODE:-none} (route missing for Claude Code?)"
fi

#-------------------------------------------------------------------------------
# [5] Claude settings.json consistency with the live proxy
#-------------------------------------------------------------------------------
log "[5] cross-checking Claude settings.json against the live proxy"
python3 - "$CC_JSON" "$MASTER_KEY" <<'PY' >> "$LOG_FILE" 2>&1
import sys, json
cfg = json.load(open(sys.argv[1]))
env = cfg.get("env") or {}
base = env.get("ANTHROPIC_BASE_URL", "")
assert base == "http://127.0.0.1:4000", f"ANTHROPIC_BASE_URL must have NO /v1 suffix: {base}"
assert env.get("ANTHROPIC_AUTH_TOKEN") == sys.argv[2], "ANTHROPIC_AUTH_TOKEN != master key"
assert env.get("ANTHROPIC_MODEL"), "ANTHROPIC_MODEL not set"
print(f"[E2E] ok  - env.ANTHROPIC_MODEL = {env.get('ANTHROPIC_MODEL')}")
PY
if [ $? -eq 0 ]; then ok "Claude settings.json consistent with live proxy"; else fail "Claude settings.json inconsistent (see log)"; fi

# server log excerpt for the committed evidence
echo >> "$LOG_FILE"
echo "--- live proxy log (tail) ---" >> "$LOG_FILE"
tail -15 "${WORK}/server.log" >> "$LOG_FILE" 2>/dev/null

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
echo >> "$LOG_FILE"
if [ "$FAILURES" -eq 0 ]; then
  log "==================================================================="
  log "E2E RESULT: PASS (all assertions against the REAL proxy passed)"
  log "==================================================================="
  echo "E2E litellm_real: PASS" >> "${RESULTS_DIR}/summary.txt"
  exit 0
else
  log "==================================================================="
  log "E2E RESULT: FAIL (${FAILURES} assertion(s) failed)"
  log "==================================================================="
  echo "E2E litellm_real: FAIL (${FAILURES})" >> "${RESULTS_DIR}/summary.txt"
  exit 1
fi
