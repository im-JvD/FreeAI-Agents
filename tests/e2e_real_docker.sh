#!/usr/bin/env bash
#===============================================================================
# tests/e2e_real_docker.sh
#
# FULL real-world end-to-end test - meant to run on a REAL WSL2 Ubuntu
# distribution with internet access to ghcr.io (e.g. the user's machine).
#
# It executes the real script twice (Full Install + Full Uninstall) against
# REAL Docker and asserts on the live system:
#   - container "litellm" exists and is running (docker ps)
#   - restart policy is "unless-stopped" (docker inspect)
#   - port 4000 answers /health/liveliness with 200
#   - GET /v1/models with the generated master key returns all 7 models
#   - Claude Code settings.json exists on the Windows side
#   - after uninstall: container, linux config and windows config are gone
#
# By default it uses PLACEHOLDER provider keys: everything is validated except
# actual upstream model responses (a chat completion will fail upstream with
# 401, which is expected). To test with real keys export:
#   LITELLM_E2E_REAL_KEYS=1
#   LITELLM_E2E_GROQ="gsk_..."      (optional, plus OPENROUTER/GEMINI/
#                                    CEREBRAS/MISTRAL variants)
#
# Results: tests/results/E2E_real_docker.log
#
# Usage:  bash tests/e2e_real_docker.sh
#===============================================================================
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_FILE="${ROOT_DIR}/setup.sh"
RESULTS_DIR="${ROOT_DIR}/tests/results"
LOG_FILE="${RESULTS_DIR}/E2E_real_docker.log"

WORK="$(mktemp -d /tmp/litellm-dockere2e.XXXXXX)"
SRV_WAIT=90
FAILURES=0

cleanup() { rm -rf "$WORK"; return 0; }
trap cleanup EXIT INT TERM

log()  { echo "[DOCKER-E2E] $*" | tee -a "$LOG_FILE"; }
fail() { echo "[DOCKER-E2E] FAIL - $*" | tee -a "$LOG_FILE"; FAILURES=$((FAILURES+1)); }
ok()   { echo "[DOCKER-E2E] ok  - $*" | tee -a "$LOG_FILE"; }

: > "$LOG_FILE"
log "==============================================================="
log "REAL Docker end-to-end test (WSL2)"
log "==============================================================="

#-------------------------------------------------------------------------------
# [0] Preflight - this test ONLY runs in a real WSL2 with ghcr.io access
#-------------------------------------------------------------------------------
log "[0] preflight"
if ! grep -qi "microsoft" /proc/version 2>/dev/null; then
  log "SKIP - not running inside WSL (/proc/version has no Microsoft entry)."
  log "SKIP - this test targets a real WSL2 Ubuntu distribution."
  echo "E2E real_docker: SKIP (not WSL)" >> "${RESULTS_DIR}/summary.txt"
  exit 0
fi
GHCR_CODE="$(curl -sI -o /dev/null -w '%{http_code}' --max-time 15 https://ghcr.io/v2/ 2>/dev/null || true)"
if [ -z "$GHCR_CODE" ] || [ "$GHCR_CODE" = "000" ]; then
  log "SKIP - ghcr.io is not reachable from this network (code ${GHCR_CODE:-none})."
  echo "E2E real_docker: SKIP (no ghcr.io access)" >> "${RESULTS_DIR}/summary.txt"
  exit 0
fi
ok "WSL2 detected, ghcr.io reachable (code ${GHCR_CODE})"

if ! command -v curl >/dev/null 2>&1; then
  log "SKIP - curl is required for the assertions"; exit 0
fi

#-------------------------------------------------------------------------------
# [1] Prepare the installer input (real or placeholder keys)
#-------------------------------------------------------------------------------
if [ "${LITELLM_E2E_REAL_KEYS:-0}" = "1" ]; then
  GROQ_IN="${LITELLM_E2E_GROQ:-}"
  OR_IN="${LITELLM_E2E_OPENROUTER:-}"
  GEM_IN="${LITELLM_E2E_GEMINI:-}"
  CER_IN="${LITELLM_E2E_CEREBRAS:-}"
  MIS_IN="${LITELLM_E2E_MISTRAL:-}"
  log "[1] using REAL provider keys from environment"
else
  GROQ_IN="gsk_e2e_placeholder_groq_key"
  OR_IN="sk-or-e2e_placeholder_key"
  GEM_IN="AIzaE2ePlaceholderKey000000"
  CER_IN="csk-e2e-placeholder-key"
  MIS_IN="sk_e2e_placeholder_mistral"
  log "[1] using PLACEHOLDER provider keys (plumbing-only validation)"
  log "    export LITELLM_E2E_REAL_KEYS=1 (+ key vars) to test real upstreams"
fi

#-------------------------------------------------------------------------------
# [2] Full Install against real Docker
#-------------------------------------------------------------------------------
log "[2] running Full Install (this installs docker.io if missing and pulls"
log "    ghcr.io/berriai/litellm:main-latest - can take several minutes)"
printf '1\n\n\n%s\n%s\n%s\n%s\n%s\n' "$GROQ_IN" "$OR_IN" "$GEM_IN" "$CER_IN" "$MIS_IN" | \
  bash "$SCRIPT_FILE" >> "$LOG_FILE" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
  fail "Full Install exited with ${RC} (expected 0)"; exit 1
fi
ok "Full Install finished (exit 0)"

# [a] container is running with the right restart policy
if docker ps --format '{{.Names}}' | grep -qx "litellm"; then
  ok "container 'litellm' is running (docker ps)"
else
  fail "container 'litellm' not found in docker ps"
fi
POLICY="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' litellm 2>/dev/null || true)"
if [ "$POLICY" = "unless-stopped" ]; then
  ok "restart policy = unless-stopped"
else
  fail "restart policy = '${POLICY:-unknown}' (expected unless-stopped)"
fi

# [a2] admin panel env vars + management CLI installed
PANEL_ENV="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' litellm 2>/dev/null | grep -c '^UI_USERNAME=admin' || true)"
if [ "${PANEL_ENV:-0}" -ge 1 ]; then ok "UI_USERNAME=admin present in container env"; else fail "UI_USERNAME missing in container env"; fi
if command -v litellm >/dev/null 2>&1; then ok "management CLI installed (litellm)"; else fail "management CLI not installed"; fi
if litellm status >/dev/null 2>&1; then ok "litellm status -> OK"; else fail "litellm status failed"; fi
BOOT_FILE="/usr/local/bin/litellm-boot.sh"
if [ -f "$BOOT_FILE" ]; then ok "boot helper installed: ${BOOT_FILE}"; else fail "boot helper missing"; fi

# [b] Admin UI database container (required for UI login)
if docker ps --format '{{.Names}}' | grep -qx "litellm-db"; then
  ok "Admin UI database container 'litellm-db' is running"
else
  fail "Admin UI database container 'litellm-db' not running"
fi

# [b2] health endpoint (longer window: first boot runs DB migrations)
HEALTH=""
for i in $(seq 1 60); do
  HEALTH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:4000/health/liveliness 2>/dev/null || true)"
  [ "$HEALTH" = "200" ] && break
  sleep 2
done
if [ "$HEALTH" = "200" ]; then ok "health endpoint -> 200"; else fail "health endpoint -> ${HEALTH:-none}"; fi

# [b3] THE critical check: Admin UI login must NOT hit the no-DB error
LOGIN_CODE="$(curl -s -o "${WORK}/login.out" -w '%{http_code}' --max-time 20 \
  -X POST -d "username=admin&password=${MASTER_KEY}" \
  http://127.0.0.1:4000/login 2>/dev/null || true)"
case "$LOGIN_CODE" in
  200|302|303)
    ok "Admin UI login with admin/master-key works (HTTP ${LOGIN_CODE}) - no 'Not connected to DB' error"
    ;;
  400)
    fail "UI login returned 400 - the 'Not connected to DB!' error is still present"
    cat "${WORK}/login.out" >> "$LOG_FILE" 2>/dev/null || true
    ;;
  *)
    fail "UI login unexpected code: ${LOGIN_CODE:-none}"
    cat "${WORK}/login.out" >> "$LOG_FILE" 2>/dev/null || true
    ;;
esac

# [b4] deep diagnosis report (per-provider connectivity + live per-model tests)
if command -v litellm >/dev/null 2>&1; then
  if litellm doctor >> "$LOG_FILE" 2>&1; then
    ok "litellm doctor: ALL model tests passed"
  else
    log "    litellm doctor reported failures (expected with placeholder keys /"
    log "    region-blocked providers). Full report appended to the log file -"
    log "    it tells exactly which provider blocks what."
  fi
  grep -E "^\s+(OK|FAIL|REJECTED|UNREACHABLE|reachable)" "$LOG_FILE" | tail -20 >> "$LOG_FILE" 2>/dev/null || true
fi

# [c] /v1/models with the generated master key
MASTER_KEY="$(tr -d '\n' < "${HOME}/.litellm/master_key.txt" 2>/dev/null || true)"
if [ -z "$MASTER_KEY" ]; then fail "master key file missing"; exit 1; fi
MODELS_JSON="${WORK}/models.json"
CODE="$(curl -s -o "$MODELS_JSON" -w '%{http_code}' --max-time 10 \
  -H "Authorization: Bearer ${MASTER_KEY}" http://127.0.0.1:4000/v1/models 2>/dev/null || true)"
if [ "$CODE" = "200" ]; then ok "GET /v1/models with master key -> 200"; else fail "GET /v1/models -> ${CODE:-none}"; fi

python3 - "$MODELS_JSON" <<'PY' >> "$LOG_FILE" 2>&1
import sys, json
expected = ["claude-gpt-oss-120b", "claude-gpt-oss-20b",
            "claude-deepseek-v3.1", "claude-deepseek-v3-0324",
            "claude-gemini-2.0-flash", "claude-llama3.1-70b", "claude-codestral"]
try:
    ids = sorted(m["id"] for m in json.load(open(sys.argv[1]))["data"])
except Exception as e:
    print(f"[DOCKER-E2E] FAIL - cannot parse models: {e}"); sys.exit(1)
if ids == sorted(expected):
    print("[DOCKER-E2E] ok  - all 7 models registered in the live proxy")
else:
    print(f"[DOCKER-E2E] FAIL - models: {ids}"); sys.exit(1)
PY
[ $? -eq 0 ] && ok "all 7 models registered in the live proxy" || fail "model list mismatch"

# [d] Claude Code settings.json on the Windows side
OC_JSON="$(powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('UserProfile')" 2>/dev/null | tr -d '\r' | sed 's|^\\\(.\)|/mnt/\L\1|; s|\\\\|/|g')/.claude/settings.json"
if [ -f "$CC_JSON" ]; then ok "Claude settings.json exists: ${CC_JSON}"; else fail "Claude settings.json missing: ${CC_JSON}"; fi

# [e] optional: real upstream call (only with real keys)
if [ "${LITELLM_E2E_REAL_KEYS:-0}" = "1" ] && [ -n "$GROQ_IN" ]; then
  CODE="$(curl -s -o "${WORK}/chat.json" -w '%{http_code}' --max-time 60 \
    -X POST -H "Authorization: Bearer ${MASTER_KEY}" -H "Content-Type: application/json" \
    -d '{"model":"claude-gpt-oss-120b","messages":[{"role":"user","content":"say OK"}],"max_tokens":5}' \
    http://127.0.0.1:4000/v1/chat/completions 2>/dev/null || true)"
  if [ "$CODE" = "200" ]; then ok "real upstream chat completion -> 200"; else fail "real upstream chat completion -> ${CODE:-none}"; fi
fi

#-------------------------------------------------------------------------------
# [3] Full Uninstall against real Docker
#-------------------------------------------------------------------------------
log "[3] running Full Uninstall"
printf '6\n' | bash "$SCRIPT_FILE" >> "$LOG_FILE" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then fail "Full Uninstall exited with ${RC}"; else ok "Full Uninstall finished (exit 0)"; fi

if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "litellm"; then
  fail "container 'litellm' still exists after uninstall"
else
  ok "container removed"
fi
if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "litellm-db"; then
  fail "database container 'litellm-db' still exists after uninstall"
else
  ok "database container removed"
fi
[ ! -f "${HOME}/.litellm/config.yaml" ]  && ok "linux config removed"     || fail "linux config still present"
[ ! -f "${HOME}/.litellm/master_key.txt" ] && ok "master key file removed" || fail "master key still present"
[ ! -f "$CC_JSON" ]                       && ok "windows Claude settings.json removed" || fail "Claude settings.json still present"
[ ! -f /usr/local/bin/litellm ]           && ok "management CLI removed"        || fail "management CLI still present"
[ ! -f /usr/local/bin/litellm-boot.sh ]   && ok "boot helper removed"           || fail "boot helper still present"

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
echo >> "$LOG_FILE"
if [ "$FAILURES" -eq 0 ]; then
  log "==============================================================="
  log "E2E RESULT: PASS (real Docker lifecycle verified)"
  log "==============================================================="
  echo "E2E real_docker: PASS" >> "${RESULTS_DIR}/summary.txt"
  exit 0
else
  log "==============================================================="
  log "E2E RESULT: FAIL (${FAILURES} assertion(s) failed)"
  log "==============================================================="
  echo "E2E real_docker: FAIL (${FAILURES})" >> "${RESULTS_DIR}/summary.txt"
  exit 1
fi
