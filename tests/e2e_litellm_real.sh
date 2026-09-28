#!/usr/bin/env bash
#===============================================================================
# tests/e2e_litellm_real.sh
#
# REAL end-to-end test of the LiteLLM gateway produced by the unified setup.sh.
#
#   1. runs the REAL setup script (with stubbed docker/powershell, since the
#      focus here is configuration correctness, not container plumbing)
#   2. installs the REAL LiteLLM proxy from PyPI into a venv
#   3. boots the REAL proxy with the generated config.yaml + master key, using
#      exactly the CLI flags the installer uses inside the container
#   4. asserts against the live HTTP API:
#        - GET  /health/liveliness             -> 200
#        - GET  /v1/models (master key)        -> exactly ["claude-freeagents"]
#        - GET  /v1/models (no key)            -> rejected (not 200)
#        - POST /v1/chat/completions (unknown) -> 400 (invalid model)
#        - POST /v1/chat/completions (model)   -> routed (upstream error is fine:
#                                                 the keys are intentionally fake)
#        - POST /v1/messages (model)           -> the Anthropic route Claude Code
#                                                 uses also routes the model
#        - the hidden desktop alias (claude-sonnet-4-5) routes to the same group
#
# Results: tests/results/E2E_litellm_real.log
#
# Env overrides:
#   LITELLM_E2E_VENV  - venv path (created when missing)
#   SKIP_INSTALL      - set to 1 when the venv already contains litellm
#   E2E_PORT          - port for the temporary proxy (default: first free one)
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
FAKE_ROOT="${WORK}/fakeroot"
T_WORKSTATE="${WORK}/state"
PROFILE_DIR="/mnt/c/Users/Test User"
PROFILE_CREATED=0
SRV_PID=""
FAILURES=0
MODEL_ID="claude-freeagents"

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

mkdir -p "$RESULTS_DIR"
log()  { echo "[E2E] $*" | tee -a "$LOG_FILE"; }
fail() { echo "[E2E] FAIL - $*" | tee -a "$LOG_FILE"; FAILURES=$((FAILURES+1)); }
ok()   { echo "[E2E] ok  - $*" | tee -a "$LOG_FILE"; }

: > "$LOG_FILE"
log "==================================================================="
log "REAL LiteLLM end-to-end test"
log "script under test: ${SCRIPT_FILE}"
log "==================================================================="

#-------------------------------------------------------------------------------
# [0] Preflight
#-------------------------------------------------------------------------------
log "[0] preflight"
command -v python3 >/dev/null 2>&1 || { log "SKIP - python3 not available"; exit 0; }
python3 -c "import venv" 2>/dev/null || { log "SKIP - python3 venv module not available"; exit 0; }
PYPI_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://pypi.org/simple/ 2>/dev/null || true)"
if [ "${SKIP_INSTALL:-0}" != "1" ] && [ "$PYPI_CODE" != "200" ]; then
  log "SKIP - PyPI not reachable (http_code=${PYPI_CODE:-none}); cannot install real LiteLLM"
  exit 0
fi
ok "python3 + venv present"

#-------------------------------------------------------------------------------
# [1] Real LiteLLM in a venv
#-------------------------------------------------------------------------------
log "[1] preparing REAL LiteLLM installation (venv: ${VENV})"
if [ "${SKIP_INSTALL:-0}" != "1" ] && [ ! -x "${VENV}/bin/litellm" ]; then
  rm -rf "$VENV"
  python3 -m venv "$VENV" || { log "FAIL - venv creation failed"; exit 1; }
  log "    installing litellm[proxy] from PyPI (this can take a few minutes)..."
  "${VENV}/bin/pip" install --quiet --upgrade pip >>"$LOG_FILE" 2>&1 || { log "FAIL - pip upgrade failed"; exit 1; }
  "${VENV}/bin/pip" install --quiet 'litellm[proxy]' >>"$LOG_FILE" 2>&1 || { log "FAIL - litellm installation failed"; exit 1; }
fi
[ -x "${VENV}/bin/litellm" ] || { log "FAIL - litellm binary not found in venv"; exit 1; }
LITELLM_VER="$("${VENV}/bin/litellm" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
ok "real LiteLLM ready (version: ${LITELLM_VER:-unknown})"

#-------------------------------------------------------------------------------
# [2] Run the REAL setup script (stubbed docker/powershell) to produce the real
#     artifacts: config.yaml + master_key.txt + Claude settings.json
#-------------------------------------------------------------------------------
log "[2] running the setup script to generate real configuration artifacts"
rm -f "${STUBBIN}/docker" "${STUBBIN}/omniroute"   # deterministic reruns
mkdir -p "$T_WORKSTATE" "$FAKE_ROOT" "$HOME_DIR"
: > "${T_WORKSTATE}/docker-calls.log"
: > "${T_WORKSTATE}/containers.txt"
if [ ! -d "$PROFILE_DIR" ]; then
  if as_root mkdir -p "$PROFILE_DIR" 2>/dev/null && \
     as_root chown "$(id -u):$(id -g)" "$PROFILE_DIR" 2>/dev/null; then
    PROFILE_CREATED=1
  else
    log "SKIP - cannot create fake Windows profile under /mnt/c"; exit 0
  fi
fi
# menu: 1 install -> 1 (LiteLLM only) -> ENTER (no windows proxy) -> 5 keys ->
# ENTER (no extra providers) -> 0 (exit)
printf '1\n1\n\n%s\n%s\n%s\n%s\n%s\n\n0\n' \
  "gsk_e2e_groq_0123456789abcd" \
  "sk-or-e2e_0123456789abcd" \
  "AIzaE2eTest0123456789ab" \
  "csk-e2e_0123456789abcd" \
  "sk_e2e_mistral0123456789" | \
  env -u DOCKER_PULL_FAIL -u DOCKER_APT_FAIL -u HEALTH_CODE -u PS_USERNAME \
    LITELLM_UI_DB="0" \
    HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" \
    STUBBIN="$STUBBIN" T_WORKSTATE="$T_WORKSTATE" FAKE_ROOT="$FAKE_ROOT" \
    HEALTH_CODE="200" KEYCHECK_CODE="200" PS_USERNAME="Test User" \
    bash "$SCRIPT_FILE" >> "$LOG_FILE" 2>&1
SCRIPT_RC=$?
if [ "$SCRIPT_RC" -ne 0 ]; then
  log "FAIL - setup script exited with ${SCRIPT_RC}"; exit 1
fi

CONFIG="${HOME_DIR}/.litellm/config.yaml"
KEYFILE="${HOME_DIR}/.litellm/master_key.txt"
[ -f "$CONFIG" ]  || { log "FAIL - config.yaml was not generated"; exit 1; }
[ -f "$KEYFILE" ] || { log "FAIL - master_key.txt was not generated"; exit 1; }
MASTER_KEY="$(cat "$KEYFILE")"
GROUP_COUNT="$(grep -c "model_name: ${MODEL_ID}" "$CONFIG" || true)"
[ "${GROUP_COUNT:-0}" -ge 1 ] || fail "config.yaml has no '${MODEL_ID}' deployments"
grep -q "model_group_alias" "$CONFIG" || fail "model_group_alias missing from config.yaml"
grep -q "claude-sonnet-4-5" "$CONFIG"  || fail "hidden desktop alias missing from config.yaml"
ok "config.yaml generated (${GROUP_COUNT} deployment(s) in the '${MODEL_ID}' group)"

#-------------------------------------------------------------------------------
# [3] Boot the REAL proxy with the generated config
#-------------------------------------------------------------------------------
pick_port() {
  local p
  for p in $(seq "${E2E_PORT:-4015}" "$(( ${E2E_PORT:-4015} + 20 ))"); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then echo "$p"; return 0; fi
  done
  echo "${E2E_PORT:-4015}"
}
PORT="$(pick_port)"
log "[3] booting the real proxy on port ${PORT}"

# the config references os.environ/<PROVIDER>_API_KEY; feed it the generated values
set -a
# shellcheck disable=SC1091
[ -f "${HOME_DIR}/.free-ai-agents/provider_keys.env" ] && . "${HOME_DIR}/.free-ai-agents/provider_keys.env"
set +a
export LITELLM_MASTER_KEY="$MASTER_KEY"

"${VENV}/bin/litellm" --config "$CONFIG" --host 127.0.0.1 --port "$PORT" >>"$LOG_FILE" 2>&1 &
SRV_PID=$!

HEALTH=000
for _ in $(seq 1 45); do
  HEALTH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${PORT}/health/liveliness" 2>/dev/null || true)"
  [ "$HEALTH" = "200" ] && break
  kill -0 "$SRV_PID" 2>/dev/null || break
  sleep 2
done
[ "$HEALTH" = "200" ] || { log "FAIL - proxy never became healthy (last code: ${HEALTH})"; exit 1; }
ok "GET /health/liveliness -> 200"

#-------------------------------------------------------------------------------
# [4] Live API assertions
#-------------------------------------------------------------------------------
log "[4] live API assertions"

MODELS="$(curl -s --max-time 10 "http://127.0.0.1:${PORT}/v1/models" \
  -H "Authorization: Bearer ${MASTER_KEY}" | \
  python3 -c 'import json,sys; print(",".join(sorted(m["id"] for m in json.load(sys.stdin).get("data",[]))))' 2>/dev/null || true)"
if [ "$MODELS" = "$MODEL_ID" ]; then
  ok "GET /v1/models -> exactly ['${MODEL_ID}'] (alias is hidden)"
else
  fail "GET /v1/models returned '${MODELS}' (expected '${MODEL_ID}')"
fi

CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PORT}/v1/models")"
[ "$CODE" != "200" ] && ok "GET /v1/models without a key -> ${CODE} (rejected)" \
                    || fail "GET /v1/models without a key was accepted"

chat_code() { # $1 = model id
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer ${MASTER_KEY}" -H 'content-type: application/json' \
    -d "{\"model\":\"$1\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" \
    "http://127.0.0.1:${PORT}/v1/chat/completions" 2>/dev/null || true
}
UNKNOWN_CODE="$(chat_code "definitely-not-a-model")"
[ "$UNKNOWN_CODE" = "400" ] && ok "unknown model -> 400 (invalid model)" \
                          || fail "unknown model returned ${UNKNOWN_CODE} (expected 400)"

ROUTED_CODE="$(chat_code "$MODEL_ID")"
if [ "$ROUTED_CODE" != "400" ] && [ "$ROUTED_CODE" != "404" ]; then
  ok "POST /v1/chat/completions model=${MODEL_ID} -> ${ROUTED_CODE} (routed upstream; fake keys)"
else
  fail "model ${MODEL_ID} was not routed (code ${ROUTED_CODE})"
fi

ALIAS_CODE="$(chat_code "claude-sonnet-4-5")"
if [ "$ALIAS_CODE" != "400" ] && [ "$ALIAS_CODE" != "404" ]; then
  ok "hidden desktop alias 'claude-sonnet-4-5' -> ${ALIAS_CODE} (resolves to the same group)"
else
  fail "desktop alias was not routed (code ${ALIAS_CODE})"
fi

MSG_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
  -H "Authorization: Bearer ${MASTER_KEY}" -H 'content-type: application/json' \
  -d "{\"model\":\"${MODEL_ID}\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" \
  "http://127.0.0.1:${PORT}/v1/messages" 2>/dev/null || true)"
if [ "$MSG_CODE" != "400" ] && [ "$MSG_CODE" != "404" ]; then
  ok "POST /v1/messages (the Claude Code route) -> ${MSG_CODE} (model routed)"
else
  fail "POST /v1/messages did not route the model (code ${MSG_CODE})"
fi

if grep -q "not a valid router_settings parameter" "$LOG_FILE"; then
  fail "LiteLLM rejected a router_settings key"
else
  ok "no invalid router_settings parameters"
fi

#-------------------------------------------------------------------------------
# [5] Summary
#-------------------------------------------------------------------------------
log "==================================================================="
if [ "$FAILURES" -eq 0 ]; then
  log "E2E_LITELLM_REAL: PASS (0 failures)"
  exit 0
fi
log "E2E_LITELLM_REAL: FAIL (${FAILURES} failure(s))"
exit 1
