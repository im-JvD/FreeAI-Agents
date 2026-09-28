#!/usr/bin/env bash
#===============================================================================
# tests/e2e_real_docker.sh
#
# FULL real-world end-to-end test - meant to run on a REAL WSL2 Ubuntu
# distribution with internet access (ghcr.io + the npm registry). This is the
# test that exercises everything the sandbox cannot: real Docker, the real
# LiteLLM container, the real OmniRoute npm package and the Windows side.
#
# Flow
#   [1] Full Install through the real menu (engine selectable)
#   [2] LiteLLM: container + restart policy + env, Admin-UI DB, health,
#       Admin-UI login, /v1/models == ["claude-freeagents"], the Anthropic
#       route (/v1/messages) and the hidden desktop alias
#   [3] OmniRoute: healthz, .env secrets, launcher, live dashboard login and
#       the managed 'claude-freeagents' combo
#   [4] Integration: freeagents CLI (status/credentials/doctor), boot helper,
#       Claude Code settings.json (Windows), Claude Desktop profiles
#   [5] optional real upstream chat completion (LITELLM_E2E_REAL_KEYS=1)
#   [6] Full Uninstall through the real menu -> everything must be gone
#
# By default PLACEHOLDER provider keys are used, so upstream model calls are
# expected to fail (the plumping is what is validated). Live key checking is
# skipped (FREEAGENTS_KEY_CHECK=0) to keep the run deterministic.
#
# Env overrides:
#   E2E_ENGINE=both|litellm|omniroute     (default: both)
#   LITELLM_E2E_REAL_KEYS=1               + LITELLM_E2E_GROQ / OPENROUTER /
#                                         GEMINI / CEREBRAS / MISTRAL
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

WORK="$(mktemp -d /tmp/freeagents-dockere2e.XXXXXX)"
ENGINE="${E2E_ENGINE:-both}"
MODEL_ID="claude-freeagents"
CATALOG_ID="claude-sonnet-4-5"
LITELLM_PORT="${LITELLM_PORT:-4000}"
OMNI_PORT="${OMNIROUTE_PORT:-20128}"
FAILURES=0

cleanup() { rm -rf "$WORK"; return 0; }
trap cleanup EXIT INT TERM

log()  { echo "[DOCKER-E2E] $*" | tee -a "$LOG_FILE"; }
fail() { echo "[DOCKER-E2E] FAIL - $*" | tee -a "$LOG_FILE"; FAILURES=$((FAILURES+1)); }
ok()   { echo "[DOCKER-E2E] ok  - $*" | tee -a "$LOG_FILE"; }

mkdir -p "$RESULTS_DIR"
: > "$LOG_FILE"
log "==============================================================="
log "REAL Docker end-to-end test (WSL2, engine: ${ENGINE})"
log "==============================================================="

case "$ENGINE" in
  litellm|omniroute|both) : ;;
  *) log "FAIL - E2E_ENGINE must be litellm, omniroute or both"; exit 1 ;;
esac

#-------------------------------------------------------------------------------
# [0] Preflight - real WSL2 + real Docker + reachable registries
#-------------------------------------------------------------------------------
log "[0] preflight"
if ! grep -qi "microsoft" /proc/version 2>/dev/null; then
  log "SKIP - not running inside WSL (/proc/version has no Microsoft entry)."
  echo "E2E real_docker: SKIP (not WSL)" >> "${RESULTS_DIR}/summary.txt"
  exit 0
fi
GHCR_CODE="$(curl -sI -o /dev/null -w '%{http_code}' --max-time 15 https://ghcr.io/v2/ 2>/dev/null || true)"
if [ -z "$GHCR_CODE" ] || [ "$GHCR_CODE" = "000" ]; then
  log "SKIP - ghcr.io is not reachable (code ${GHCR_CODE:-none})."
  echo "E2E real_docker: SKIP (no ghcr.io access)" >> "${RESULTS_DIR}/summary.txt"
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  log "SKIP - curl is required for the assertions"; exit 0
fi
if [ "$ENGINE" != "omniroute" ]; then
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    log "SKIP - docker is not usable on this machine"; exit 0
  fi
fi
ok "WSL2 detected, ghcr.io reachable (code ${GHCR_CODE})"

#-------------------------------------------------------------------------------
# [1] Full Install through the real menu
#-------------------------------------------------------------------------------
case "$ENGINE" in
  litellm)   ENGINE_CHOICE="1" ;;
  omniroute) ENGINE_CHOICE="2" ;;
  *)         ENGINE_CHOICE="3" ;;
esac

if [ "${LITELLM_E2E_REAL_KEYS:-0}" = "1" ]; then
  K_GROQ="${LITELLM_E2E_GROQ:-}"
  K_OR="${LITELLM_E2E_OPENROUTER:-}"
  K_GEM="${LITELLM_E2E_GEMINI:-}"
  K_CER="${LITELLM_E2E_CEREBRAS:-}"
  K_MIS="${LITELLM_E2E_MISTRAL:-}"
  log "[1] using REAL provider keys from the environment"
else
  K_GROQ="gsk_e2e_placeholder_groq_key"
  K_OR="sk-or-e2e_placeholder_key"
  K_GEM="AIzaE2ePlaceholderKey000000"
  K_CER="csk-e2e-placeholder-key"
  K_MIS="sk_e2e_placeholder_mistral"
  log "[1] using PLACEHOLDER provider keys (plumbing-only validation)"
fi

log "[1] running Full Install (manager menu: 1 -> ${ENGINE_CHOICE});"
log "    docker.io / the ghcr image / the official npm package may be downloaded"
printf '1\n%s\n\n%s\n%s\n%s\n%s\n%s\n\n0\n' "$ENGINE_CHOICE" \
  "$K_GROQ" "$K_OR" "$K_GEM" "$K_CER" "$K_MIS" | \
  env FREEAGENTS_KEY_CHECK=0 bash "$SCRIPT_FILE" >> "$LOG_FILE" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then fail "Full Install exited with ${RC} (expected 0)"; exit 1; fi
ok "Full Install finished (exit 0)"

if [ ! -f /usr/local/bin/freeagents ]; then
  fail "management CLI /usr/local/bin/freeagents is missing"
else
  ok "management CLI installed: /usr/local/bin/freeagents"
fi
if [ -f /usr/local/bin/freeagents-boot.sh ]; then
  ok "boot helper installed: /usr/local/bin/freeagents-boot.sh"
else
  fail "boot helper /usr/local/bin/freeagents-boot.sh is missing"
fi

#-------------------------------------------------------------------------------
# [2] LiteLLM: the live container and its API
#-------------------------------------------------------------------------------
MASTER_KEY="$(tr -d '\n' < "${HOME}/.litellm/master_key.txt" 2>/dev/null || true)"

if [ "$ENGINE" != "omniroute" ]; then
  log "[2] LiteLLM assertions"

  if docker ps --format '{{.Names}}' | grep -qx "litellm"; then
    ok "container 'litellm' is running"
  else
    fail "container 'litellm' not found in docker ps"
  fi
  POLICY="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' litellm 2>/dev/null || true)"
  [ "$POLICY" = "unless-stopped" ] && ok "restart policy = unless-stopped" \
                                  || fail "restart policy = '${POLICY:-unknown}'"

  CENV="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' litellm 2>/dev/null || true)"
  printf '%s\n' "$CENV" | grep -q '^UI_USERNAME=admin' && ok "UI_USERNAME=admin in container env" \
                                                     || fail "UI_USERNAME missing in container env"
  printf '%s\n' "$CENV" | grep -q "^LITELLM_MASTER_KEY=${MASTER_KEY}" && ok "master key passed to the container" \
                                                                     || fail "LITELLM_MASTER_KEY not passed to the container"
  printf '%s\n' "$CENV" | grep -q '^GROQ_API_KEY=' && ok "provider keys passed to the container" \
                                                   || fail "provider keys missing in container env"

  if docker ps --format '{{.Names}}' | grep -qx "litellm-db"; then
    ok "Admin-UI database container 'litellm-db' is running"
  else
    fail "Admin-UI database container 'litellm-db' is not running"
  fi
  printf '%s\n' "$CENV" | grep -q '^DATABASE_URL=postgresql://' && ok "DATABASE_URL wired to the container" \
                                                                || fail "DATABASE_URL missing"

  HEALTH=""
  for _ in $(seq 1 60); do
    HEALTH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
      "http://127.0.0.1:${LITELLM_PORT}/health/liveliness" 2>/dev/null || true)"
    [ "$HEALTH" = "200" ] && break
    sleep 2
  done
  [ "$HEALTH" = "200" ] && ok "health endpoint -> 200" || fail "health endpoint -> ${HEALTH:-none}"

  # Admin UI login must NOT hit the "Not connected to DB!" error
  LOGIN_CODE="$(curl -s -o "${WORK}/login.out" -w '%{http_code}' --max-time 20 \
    -X POST -d "username=admin&password=${MASTER_KEY}" \
    "http://127.0.0.1:${LITELLM_PORT}/login" 2>/dev/null || true)"
  case "$LOGIN_CODE" in
    200|302|303) ok "Admin UI login with admin/master-key works (HTTP ${LOGIN_CODE})" ;;
    400)         fail "UI login returned 400 - 'Not connected to DB!' is back"; cat "${WORK}/login.out" >> "$LOG_FILE" 2>/dev/null || true ;;
    *)           fail "UI login unexpected code: ${LOGIN_CODE:-none}"; cat "${WORK}/login.out" >> "$LOG_FILE" 2>/dev/null || true ;;
  esac

  # Exactly ONE model id is advertised; the desktop alias stays hidden
  MODELS="$(curl -s --max-time 10 -H "Authorization: Bearer ${MASTER_KEY}" \
    "http://127.0.0.1:${LITELLM_PORT}/v1/models" | \
    python3 -c 'import json,sys; print(",".join(sorted(m["id"] for m in json.load(sys.stdin).get("data",[]))))' 2>/dev/null || true)"
  [ "$MODELS" = "$MODEL_ID" ] && ok "GET /v1/models -> exactly ['${MODEL_ID}']" \
                              || fail "GET /v1/models returned '${MODELS}'"

  chat_code() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
      -H "Authorization: Bearer ${MASTER_KEY}" -H 'content-type: application/json' \
      -d "{\"model\":\"$1\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" \
      "http://127.0.0.1:${LITELLM_PORT}/v1/chat/completions" 2>/dev/null || true
  }
  UNKNOWN="$(chat_code "definitely-not-a-model")"
  [ "$UNKNOWN" = "400" ] && ok "unknown model -> 400" || fail "unknown model -> ${UNKNOWN} (expected 400)"

  ROUTED="$(chat_code "$MODEL_ID")"
  if [ "$ROUTED" != "400" ] && [ "$ROUTED" != "404" ]; then
    ok "the single model group is routed (HTTP ${ROUTED})"
  else
    fail "model ${MODEL_ID} was not routed (HTTP ${ROUTED})"
  fi
  ALIAS="$(chat_code "$CATALOG_ID")"
  if [ "$ALIAS" != "400" ] && [ "$ALIAS" != "404" ]; then
    ok "hidden desktop alias '${CATALOG_ID}' resolves (HTTP ${ALIAS})"
  else
    fail "desktop alias was not routed (HTTP ${ALIAS})"
  fi

  MSG="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
    -H "Authorization: Bearer ${MASTER_KEY}" -H 'content-type: application/json' \
    -d "{\"model\":\"${MODEL_ID}\",\"max_tokens\":8,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" \
    "http://127.0.0.1:${LITELLM_PORT}/v1/messages" 2>/dev/null || true)"
  if [ "$MSG" != "400" ] && [ "$MSG" != "404" ]; then
    ok "POST /v1/messages (the Claude Code route) is routed (HTTP ${MSG})"
  else
    fail "POST /v1/messages did not route the model (HTTP ${MSG})"
  fi

  PERM="$(stat -c '%a' "${HOME}/.litellm/master_key.txt" 2>/dev/null || true)"
  [ "$PERM" = "600" ] && ok "master key file is 0600" || fail "master key file mode = ${PERM:-none} (expected 600)"

  if [ "${LITELLM_E2E_REAL_KEYS:-0}" = "1" ] && [ -n "$K_GROQ" ]; then
    CODE="$(curl -s -o "${WORK}/chat.json" -w '%{http_code}' --max-time 90 \
      -X POST -H "Authorization: Bearer ${MASTER_KEY}" -H "Content-Type: application/json" \
      -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"say OK\"}],\"max_tokens\":5}" \
      "http://127.0.0.1:${LITELLM_PORT}/v1/chat/completions" 2>/dev/null || true)"
    [ "$CODE" = "200" ] && ok "real upstream chat completion -> 200" \
                        || fail "real upstream chat completion -> ${CODE:-none}"
  fi
else
  log "[2] LiteLLM assertions skipped (engine: ${ENGINE})"
fi

#-------------------------------------------------------------------------------
# [3] OmniRoute: npm service, .env secrets, dashboard API and the managed combo
#-------------------------------------------------------------------------------
if [ "$ENGINE" != "litellm" ]; then
  log "[3] OmniRoute assertions"

  OMNI_HEALTH=""
  for _ in $(seq 1 45); do
    OMNI_HEALTH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 \
      "http://127.0.0.1:${OMNI_PORT}/healthz" 2>/dev/null || true)"
    [ "$OMNI_HEALTH" = "200" ] && break
    sleep 2
  done
  [ "$OMNI_HEALTH" = "200" ] && ok "OmniRoute /healthz -> 200" \
                             || fail "OmniRoute /healthz -> ${OMNI_HEALTH:-none}"

  [ -f "${HOME}/.omniroute/.env" ] && ok "OmniRoute .env exists" || fail "OmniRoute .env is missing"
  for var in JWT_SECRET API_KEY_SECRET INITIAL_PASSWORD REQUIRE_API_KEY; do
    grep -q "^${var}=" "${HOME}/.omniroute/.env" 2>/dev/null && ok "${var} present in .env" \
                                                             || fail "${var} missing from .env"
  done
  ENV_PERM="$(stat -c '%a' "${HOME}/.omniroute/.env" 2>/dev/null || true)"
  [ "$ENV_PERM" = "600" ] && ok ".env is 0600" || fail ".env mode = ${ENV_PERM:-none} (expected 600)"
  LAUNCH_PERM="$(stat -c '%a' "${HOME}/.free-ai-agents/omniroute-run.sh" 2>/dev/null || true)"
  [ "$LAUNCH_PERM" = "700" ] && ok "launcher omniroute-run.sh is 0700" \
                             || fail "launcher omniroute-run.sh mode = ${LAUNCH_PERM:-none} (expected 700)"

  OMNI_PASS="$(sed -n 's/^INITIAL_PASSWORD=//p' "${HOME}/.omniroute/.env" 2>/dev/null | head -1)"
  JAR="${WORK}/omni-cookies.txt"
  LOGIN_JSON="$(curl -s -o "${WORK}/omni-login.json" -w '%{http_code}' --max-time 20 \
    -c "$JAR" -H 'content-type: application/json' \
    -d "{\"password\":\"${OMNI_PASS}\"}" \
    "http://127.0.0.1:${OMNI_PORT}/api/auth/login" 2>/dev/null || true)"
  case "$LOGIN_JSON" in
    200|201) ok "dashboard login through /api/auth/login works" ;;
    *)       fail "dashboard login failed (HTTP ${LOGIN_JSON:-none})" ;;
  esac

  COMBOS="$(curl -s --max-time 20 -b "$JAR" "http://127.0.0.1:${OMNI_PORT}/api/combos" | \
    python3 -c 'import json,sys
d=json.load(sys.stdin)
d=d if isinstance(d,list) else d.get("combos",[])
print(",".join(sorted(str(c.get("name")) for c in d if isinstance(c,dict))))' 2>/dev/null || true)"
  case ",$COMBOS," in
    *",${MODEL_ID},"*) ok "combo '${MODEL_ID}' exists (single model for Claude)" ;;
    *)                  fail "combo '${MODEL_ID}' not found (got: ${COMBOS:-none})" ;;
  esac

  PROVIDERS="$(curl -s --max-time 20 -b "$JAR" "http://127.0.0.1:${OMNI_PORT}/api/providers" | \
    python3 -c 'import json,sys
d=json.load(sys.stdin)
d=d if isinstance(d,list) else d.get("providers") or d.get("connections") or []
print(len(d))' 2>/dev/null || true)"
  if [ "${PROVIDERS:-0}" -ge 1 ]; then
    ok "provider connection(s) registered: ${PROVIDERS}"
  else
    fail "no provider connection was registered (got: ${PROVIDERS:-none})"
  fi
else
  log "[3] OmniRoute assertions skipped (engine: ${ENGINE})"
fi

#-------------------------------------------------------------------------------
# [4] Integration: CLI, boot persistence, Claude Code + Claude Desktop
#-------------------------------------------------------------------------------
log "[4] integration assertions"

if freeagents status >> "$LOG_FILE" 2>&1; then ok "freeagents status -> exit 0"; else fail "freeagents status failed"; fi
if freeagents credentials >> "$LOG_FILE" 2>&1; then ok "freeagents credentials -> exit 0"; else fail "freeagents credentials failed"; fi
if grep -q "freeagents" /usr/local/bin/freeagents 2>/dev/null; then ok "CLI content sane"; else fail "CLI content unexpected"; fi
for legacy in litellm omni; do
  [ -e "/usr/local/bin/${legacy}" ] && fail "legacy per-gateway command still present: /usr/local/bin/${legacy}" \
                                    || ok "legacy command '${legacy}' absent"
done

if [ -f /etc/systemd/system/omniroute.service ] || [ -f /etc/systemd/system/litellm.service ] || \
   grep -q "freeagents-boot.sh" /etc/wsl.conf 2>/dev/null; then
  ok "boot persistence installed (systemd unit or wsl.conf boot command)"
else
  fail "no boot persistence found (systemd unit / wsl.conf)"
fi

CC_JSON=""
if command -v powershell.exe >/dev/null 2>&1; then
  WINHOME="$(powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('UserProfile')" 2>/dev/null | tr -d '\r')"
  WSLHOME="$(printf '%s' "$WINHOME" | sed 's|^\\\(.\)|/mnt/\L\1|; s|\\|/|g')"
  CC_JSON="${WSLHOME}/.claude/settings.json"
  if [ -f "$CC_JSON" ]; then
    ok "Claude Code settings.json exists: ${CC_JSON}"
    grep -q "\"ANTHROPIC_MODEL\": \"${MODEL_ID}\"" "$CC_JSON" && ok "ANTHROPIC_MODEL=${MODEL_ID}" \
                                                             || fail "ANTHROPIC_MODEL is not ${MODEL_ID}"
    grep -q '"ANTHROPIC_AUTH_TOKEN"' "$CC_JSON" && ok "ANTHROPIC_AUTH_TOKEN is set" \
                                                || fail "ANTHROPIC_AUTH_TOKEN missing"
    BASE="$(sed -n 's/.*"ANTHROPIC_BASE_URL": "\([^"]*\)".*/\1/p' "$CC_JSON" | head -1)"
    case "$BASE" in
      "http://127.0.0.1:${LITELLM_PORT}"|"http://127.0.0.1:${OMNI_PORT}") ok "ANTHROPIC_BASE_URL points at a gateway (${BASE})" ;;
      *) fail "ANTHROPIC_BASE_URL unexpected: ${BASE:-none}" ;;
    esac
  else
    fail "Claude Code settings.json missing: ${CC_JSON}"
  fi

  LOCAL_APP="$(powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('LocalApplicationData')" 2>/dev/null | tr -d '\r')"
  WSL_LOCAL="$(printf '%s' "$LOCAL_APP" | sed 's|^\\\(.\)|/mnt/\L\1|; s|\\|/|g')"
  LIB="${WSL_LOCAL}/Claude-3p/configLibrary"
  if [ -d "$LIB" ]; then
    for id in "00000000-0000-4000-8000-0000000a119e" "00000000-0000-4000-8000-0000000a110e"; do
      if compgen -G "${LIB}/*${id}*" >/dev/null || [ -f "${LIB}/${id}.json" ]; then
        ok "Claude Desktop profile present (${id})"
      else
        fail "Claude Desktop profile missing (${id})"
      fi
    done
  else
    fail "Claude Desktop configLibrary folder not found: ${LIB}"
  fi
else
  log "    powershell.exe unavailable - Windows-side assertions skipped"
fi

#-------------------------------------------------------------------------------
# [5] Full Uninstall through the real menu -> everything must be gone
#-------------------------------------------------------------------------------
log "[5] running Full Uninstall (manager menu: 6 + confirmation)"
printf '6\ny\n' | bash "$SCRIPT_FILE" >> "$LOG_FILE" 2>&1
RC=$?
[ "$RC" -eq 0 ] && ok "Full Uninstall finished (exit 0)" || fail "Full Uninstall exited with ${RC}"

if command -v docker >/dev/null 2>&1; then
  for c in litellm litellm-db omniroute-app; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
      fail "container '${c}' still exists after uninstall"
    else
      ok "container '${c}' absent"
    fi
  done
fi
[ ! -d "${HOME}/.litellm" ]        && ok ".litellm removed"        || fail ".litellm still present"
[ ! -d "${HOME}/.omniroute" ]      && ok ".omniroute removed"      || fail ".omniroute still present"
[ ! -d "${HOME}/.free-ai-agents" ] && ok ".free-ai-agents removed" || fail ".free-ai-agents still present"
[ ! -f /usr/local/bin/freeagents ]           && ok "freeagents CLI removed"  || fail "freeagents CLI still present"
[ ! -f /usr/local/bin/freeagents-boot.sh ]   && ok "boot helper removed"     || fail "boot helper still present"
[ ! -f /etc/systemd/system/litellm.service ] && ok "litellm.service removed"  || fail "litellm.service still present"
[ ! -f /etc/systemd/system/omniroute.service ] && ok "omniroute.service removed" || fail "omniroute.service still present"
if grep -q "freeagents-boot.sh" /etc/wsl.conf 2>/dev/null; then
  fail "stale boot command still in /etc/wsl.conf"
else
  ok "no stale boot command in /etc/wsl.conf"
fi
if command -v npm >/dev/null 2>&1; then
  if npm ls -g --depth=0 2>/dev/null | grep -q " omniroute@"; then
    fail "omniroute npm package still installed"
  else
    ok "omniroute npm package removed"
  fi
else
  log "    npm unavailable - the package check was skipped"
fi
if [ -n "$CC_JSON" ] && [ -f "$CC_JSON" ]; then
  grep -q '"ANTHROPIC_AUTH_TOKEN"' "$CC_JSON" && fail "gateway wiring still present in settings.json" \
                                              || ok "settings.json restored/cleaned"
else
  ok "Claude Code settings.json removed"
fi

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
echo >> "$LOG_FILE"
log "==============================================================="
if [ "$FAILURES" -eq 0 ]; then
  log "E2E RESULT: PASS (real Docker + npm lifecycle verified)"
  log "==============================================================="
  echo "E2E real_docker: PASS" >> "${RESULTS_DIR}/summary.txt"
  exit 0
fi
log "E2E RESULT: FAIL (${FAILURES} assertion(s) failed)"
log "==============================================================="
echo "E2E real_docker: FAIL (${FAILURES})" >> "${RESULTS_DIR}/summary.txt"
exit 1
