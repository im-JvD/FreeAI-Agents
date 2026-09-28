#!/usr/bin/env bash
#===============================================================================
# tests/run_all_tests.sh
#
# OFFLINE (simulated) test-suite for the unified Free AI Agents installer
# (setup.sh v4: LiteLLM  +  OmniRoute  ->  Claude Code / Claude Desktop).
#
# How it works
#   - every external command the script touches (docker, apt-get, service,
#     systemctl, curl, npm, node, sudo, powershell.exe) is replaced by a
#     deterministic stub from tests/helpers/stubbin
#   - /etc/docker, /usr/local/bin, /etc/systemd and /etc/wsl.conf writes are
#     virtualized into a temporary FAKE_ROOT by the sudo stub
#   - the Windows user profile is emulated under /mnt/c/Users/<Test User>
#     (a dedicated fake folder, never a real profile; removed on exit)
#   - OmniRoute is a REAL HTTP server: tests/helpers/mock_omniroute.py mirrors
#     the official REST surface (session cookie login, provider upsert, API
#     keys, combos, live catalog), so the installer's management flow is
#     exercised end-to-end instead of being asserted on paper
#   - every scenario runs the REAL script and asserts on exit codes, the
#     generated LiteLLM config.yaml, the generated OmniRoute .env, the Claude
#     Code settings.json, the Claude Desktop profiles, docker/npm calls,
#     boot persistence and uninstall behavior
#
# Results:  tests/results/<test-name>.log  +  tests/results/summary.txt
#
# Usage:  bash tests/run_all_tests.sh
#===============================================================================
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_FILE="${ROOT_DIR}/setup.sh"
TESTS_DIR="${ROOT_DIR}/tests"
STUBBIN="${TESTS_DIR}/helpers/stubbin"
RESULTS_DIR="${TESTS_DIR}/results"
SUMMARY_FILE="${RESULTS_DIR}/summary.txt"
REAL_CURL="/usr/bin/curl"

MOCK_PORT="${MOCK_OMNI_PORT:-20871}"

mkdir -p "$RESULTS_DIR"

#-------------------------------------------------------------------------------
# Globals
#-------------------------------------------------------------------------------
PASS=0; FAIL=0; SKIP=0
T_NAME=""
T_WORK=""
T_WORKSTATE=""
FAKE_ROOT=""
HOME_DIR=""
T_RC=""
T_BOOT_MODE="wslconf"
T_UI_DB="1"
T_HEALTH_CODE="200"
T_KEYCHECK_CODE="200"
T_PROXY_CALL_CODE=""
T_PULL_RETRIES="1"
T_HEALTH_WAIT_SEC="2"
T_OMNI_WAIT_SEC="4"
T_SKIP_WINDOWS="0"
T_KEY_CHECK="1"
T_REJECT_LOGIN=""
T_SELF_UPDATE=""
CREATED_PROFILE_DIRS=()
CURRENT_LOG=""
MNT_OK=1

GROQ_KEY="gsk_test_groq_0123456789abcd"
OR_KEY="sk-or-test_0123456789abcd"
GEMINI_KEY="AIzaTest0123456789abcd"
CEREBRAS_KEY="csk-test_0123456789abcd"
MISTRAL_KEY="sk_mistral_test012345678"
GITHUB_KEY="ghp_test_0123456789abcd"
SAMBANOVA_KEY="sn-test_0123456789abcd"
NVIDIA_KEY="nvapi-test_0123456789abcd"
TOGETHER_KEY="tog-test_0123456789abcd"


cleanup() {
  mock_stop
  local d
  for d in "${CREATED_PROFILE_DIRS[@]:-}"; do
    [ -n "$d" ] && rm_rf_sudo "$d"
  done
  if [ "${MNT_OK:-0}" -eq 1 ] && [ -d /mnt/c/Users ]; then
    local u
    for u in "Test User" "Ali Rezaei"; do
      [ -d "/mnt/c/Users/${u}" ] && rm_rf_sudo "/mnt/c/Users/${u}"
    done
  fi
  [ -n "$T_WORK" ] && [ -d "$T_WORK" ] && rm -rf "$T_WORK"
  return 0
}
trap cleanup EXIT INT TERM

#-------------------------------------------------------------------------------
# Small helpers
#-------------------------------------------------------------------------------
msg()  { echo "[SUITE] $*"; }
pass_test() { PASS=$((PASS+1)); msg "PASS  ${T_NAME}"; echo "PASS  ${T_NAME}" >> "$SUMMARY_FILE"; }
skip_test() { SKIP=$((SKIP+1)); msg "SKIP  ${T_NAME} - $*"; echo "SKIP  ${T_NAME} - $*" >> "$SUMMARY_FILE"; }
fail_test() { FAIL=$((FAIL+1)); msg "FAIL  ${T_NAME} - $*"; echo "FAIL  ${T_NAME} - $*" >> "$SUMMARY_FILE"; }

as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@"; fi
}
rm_rf_sudo() { as_root rm -rf "$1" 2>/dev/null || true; }
cp_sudo()    { as_root cp "$1" "$2" 2>/dev/null || true; }

start_test() {
  T_NAME="$1"
  CURRENT_LOG="${RESULTS_DIR}/${T_NAME}.log"
  : > "$CURRENT_LOG"
  A_FAILURES=0
  T_RC=""
  T_BOOT_MODE="wslconf"; T_UI_DB="1"; T_HEALTH_CODE="200"; T_KEYCHECK_CODE="200"
  T_PROXY_CALL_CODE=""; T_PULL_RETRIES="1"; T_HEALTH_WAIT_SEC="2"; T_OMNI_WAIT_SEC="4"
  T_SKIP_WINDOWS="0"; T_KEY_CHECK="1"; T_REJECT_LOGIN=""
  T_SELF_UPDATE=""
}

#-------------------------------------------------------------------------------
# Mock OmniRoute server
#-------------------------------------------------------------------------------
port_in_use() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

pick_mock_port() {
  local candidate="${MOCK_OMNI_PORT:-20871}" i
  for i in $(seq 0 20); do
    if ! port_in_use "$((candidate + i))"; then
      MOCK_PORT="$((candidate + i))"
      export OMNIROUTE_PORT="$MOCK_PORT"
      return 0
    fi
  done
  msg "no free port for the mock OmniRoute server"; return 1
}

# The OmniRoute "server" is started by the installer itself (the npm stub execs
# the mock), so stopping it means killing the process its PID file points at.
mock_stop() {
  local pidf="${HOME_DIR}/.free-ai-agents/omniroute.pid" pid=""
  [ -n "${HOME_DIR:-}" ] && pid="$(cat "$pidf" 2>/dev/null | head -1 || true)"
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
    sleep 0.2
    kill -9 "$pid" 2>/dev/null || true
  fi
  return 0
}

mock_state() { "$REAL_CURL" -s --max-time 5 "http://127.0.0.1:${MOCK_PORT}/__state" 2>/dev/null; }
mock_requests() { cat "${T_WORKSTATE}/mock-requests.log" 2>/dev/null; }

#-------------------------------------------------------------------------------
# Fresh isolated environment per test
#-------------------------------------------------------------------------------
fresh_env() {
  rm -f "${STUBBIN}/docker" "${STUBBIN}/omniroute"
  pick_mock_port || return 1
  T_WORK="$(mktemp -d /tmp/freeai-test.XXXXXX)"
  T_WORKSTATE="${T_WORK}/state"
  FAKE_ROOT="${T_WORK}/fakeroot"
  HOME_DIR="${T_WORK}/home"
  mkdir -p "$T_WORKSTATE" "$FAKE_ROOT" "$HOME_DIR"
  mkdir -p "${FAKE_ROOT}/usr/local/bin" "${FAKE_ROOT}/etc/docker" "${FAKE_ROOT}/etc/systemd/system"
  : > "${T_WORKSTATE}/docker-calls.log"
  : > "${T_WORKSTATE}/apt-calls.log"
  : > "${T_WORKSTATE}/npm-calls.log"
  : > "${T_WORKSTATE}/node-calls.log"
  : > "${T_WORKSTATE}/omniroute-calls.log"
  : > "${T_WORKSTATE}/curl-calls.log"
  : > "${T_WORKSTATE}/mock-requests.log"
  : > "${T_WORKSTATE}/powershell-calls.log"
  : > "${T_WORKSTATE}/containers.txt"
  : > "${T_WORKSTATE}/container-running.txt"
  : > "${T_WORKSTATE}/images.txt"
  # Emulate an existing Windows profile (a real WSL always has one) so the
  # Claude Code / Claude Desktop writers exercise their full path.
  for u in "Test User" "Ali Rezaei"; do
    for d in "/mnt/c/Users/${u}/.claude" "/mnt/c/Users/${u}/AppData/Local/Claude-3p/configLibrary"; do
      rm -rf "$d" 2>/dev/null || true
      mkdir -p "$d" 2>/dev/null || true
    done
  done
  return 0
}

script_lib() { # writes a sourceable copy of setup.sh (without the main call)
  local lib="${T_WORK}/setup_lib.sh"
  sed '$ d' "$SCRIPT_FILE" > "$lib"
  printf '%s' "$lib"
}

run_script() { # optional $1 = path of the script copy to run (default: the real one)
  local script_file="${1:-$SCRIPT_FILE}"
  env -u DOCKER_PULL_FAIL -u DOCKER_APT_FAIL -u NPM_FAIL_REGISTRY \
    HOME="$HOME_DIR" \
    PATH="${STUBBIN}:/usr/bin:/bin:/usr/sbin:/sbin" \
    STUBBIN="$STUBBIN" \
    T_WORKSTATE="$T_WORKSTATE" \
    FAKE_ROOT="$FAKE_ROOT" \
    MOCK_OMNI_PORT="$MOCK_PORT" \
    OMNIROUTE_PORT="$MOCK_PORT" \
    MOCK_REJECT_LOGIN="$T_REJECT_LOGIN" \
    HEALTH_CODE="$T_HEALTH_CODE" \
    KEYCHECK_CODE="$T_KEYCHECK_CODE" \
    PROXY_CALL_CODE="$T_PROXY_CALL_CODE" \
    FAKE_SELF_SOURCE="$T_SELF_UPDATE" \
    FREEAGENTS_BOOT_MODE="$T_BOOT_MODE" \
    LITELLM_UI_DB="$T_UI_DB" \
    LITELLM_PULL_RETRIES="$T_PULL_RETRIES" \
    LITELLM_HEALTH_WAIT_SEC="$T_HEALTH_WAIT_SEC" \
    OMNIROUTE_HEALTH_WAIT_SEC="$T_OMNI_WAIT_SEC" \
    FREEAGENTS_SKIP_WINDOWS="$T_SKIP_WINDOWS" \
    FREEAGENTS_KEY_CHECK="$T_KEY_CHECK" \
    bash "$script_file" >> "$CURRENT_LOG" 2>&1
}

#-------------------------------------------------------------------------------
# Assertion helpers
#-------------------------------------------------------------------------------
A_FAILURES=0
a_ok()   { echo "    ok: $*" >> "$CURRENT_LOG"; }
a_bad()  { echo "    ASSERTION FAILED: $*" >> "$CURRENT_LOG"; A_FAILURES=$((A_FAILURES+1)); }

assert_rc() { # $1 expected rc
  if [ "${T_RC:-999}" = "$1" ]; then a_ok "exit code = $1"; else a_bad "exit code expected $1, got ${T_RC:-unset}"; fi
}
assert_contains() { # $1 file, $2 needle
  if grep -qF -- "$2" "$1" 2>/dev/null; then a_ok "contains: $2"; else a_bad "expected '$2' in $1"; fi
}
assert_not_contains() { # $1 file, $2 needle
  if grep -qF -- "$2" "$1" 2>/dev/null; then a_bad "did not expect '$2' in $1"; else a_ok "not contains: $2"; fi
}
assert_file_exists() {
  if [ -e "$1" ]; then a_ok "file exists: $1"; else a_bad "file missing: $1"; fi
}
assert_file_missing() {
  if [ ! -e "$1" ]; then a_ok "file missing: $1"; else a_bad "file should not exist: $1"; fi
}
assert_mode() { # $1 file, $2 octal
  local mode
  mode="$(stat -c '%a' "$1" 2>/dev/null || true)"
  if [ "$mode" = "$2" ]; then a_ok "mode $2 on $1"; else a_bad "mode of $1 is ${mode:-?}, expected $2"; fi
}
assert_json() { # $1 json file, $2 python expression over d, $3 label
  if python3 - "$1" "$2" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
assert eval(sys.argv[2]), sys.argv[2]
PY
  then a_ok "$3"; else a_bad "$3"; fi
}
assert_mock() { # $1 python expression over the mock state, $2 label
  if python3 - "$2" <<PY 2>/dev/null
import json, sys, urllib.request
state = json.load(urllib.request.urlopen("http://127.0.0.1:${MOCK_PORT}/__state"))
$1
PY
  then a_ok "$2"; else a_bad "$2"; fi
}
assert_models() { # $1 config.yaml, $2 expected count of the branded group
  local count
  count="$(grep -c "^  - model_name: " "$1" 2>/dev/null || true)"
  if [ "${count:-0}" = "$2" ]; then a_ok "config.yaml has $2 deployment(s)"; else a_bad "expected $2 deployments, got ${count:-0}"; fi
}
assert_mirrors() { # $1 daemon.json
  assert_json "$1" 'd["registry-mirrors"] == ["https://docker.arvancloud.ir","https://docker.hub.iran.liara.run","https://docker.iranserver.com"]' "daemon.json mirrors exact"
}
assert_claude_settings() { # $1 settings.json $2 expected token $3 expected base url
  assert_json "$1" "d['env']['ANTHROPIC_BASE_URL'] == '$3'" "settings.json base url = $3"
  assert_json "$1" "d['env']['ANTHROPIC_AUTH_TOKEN'] == '$2'" "settings.json token matches"
  assert_json "$1" "d['env']['ANTHROPIC_MODEL'] == 'claude-freeagents'" "settings.json model id"
  assert_json "$1" "d['env']['CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY'] == '1'" "gateway model discovery enabled"
  assert_json "$1" "d['env']['CLAUDE_CODE_AUTO_COMPACT_WINDOW'] == '120000'" "auto compact window set"
  assert_json "$1" "'ANTHROPIC_API_KEY' not in d['env']" "no ANTHROPIC_API_KEY (bearer only)"
}
assert_env_line() { # $1 env file, $2 key, $3 expected value
  local got
  got="$(awk -v k="$2" 'index($0, k "=") == 1 { sub("^" k "=", ""); print; exit }' "$1" 2>/dev/null)"
  if [ "$got" = "$3" ]; then a_ok "env $2 = $3"; else a_bad "env $2 is '${got}', expected '$3'"; fi
}

finish_test() {
  if [ "$A_FAILURES" -eq 0 ]; then pass_test; else fail_test "${A_FAILURES} assertion(s) failed - see ${CURRENT_LOG}"; fi
  A_FAILURES=0
  mock_stop
  [ -n "$T_WORK" ] && [ -d "$T_WORK" ] && rm -rf "$T_WORK"
}

dump_state() {
  {
    echo; echo "--- docker-calls.log ---"; cat "${T_WORKSTATE}/docker-calls.log" 2>/dev/null
    echo; echo "--- apt-calls.log ---"; cat "${T_WORKSTATE}/apt-calls.log" 2>/dev/null
    echo; echo "--- npm/node calls ---"; cat "${T_WORKSTATE}/npm-calls.log" "${T_WORKSTATE}/node-calls.log" 2>/dev/null
    echo; echo "--- mock requests ---"; mock_requests
    echo; echo "--- mock state ---"; mock_state
    echo; echo "--- generated config.yaml ---"; cat "${HOME_DIR}/.litellm/config.yaml" 2>/dev/null
    echo; echo "--- generated OmniRoute .env ---"; sed 's/^\(JWT_SECRET\|API_KEY_SECRET\|INITIAL_PASSWORD\)=.*/\1=<hidden>/' "${HOME_DIR}/.omniroute/.env" 2>/dev/null
    echo; echo "--- generated Claude settings.json ---"; cat "/mnt/c/Users/Test User/.claude/settings.json" 2>/dev/null
  } >> "$CURRENT_LOG"
}

master_key_from() { tr -d '\n' < "${HOME_DIR}/.litellm/master_key.txt" 2>/dev/null; }
litellm_docker_run() { grep -o 'LITELLM_MASTER_KEY=[^ ]*' "${T_WORKSTATE}/docker-calls.log" 2>/dev/null | head -1 | cut -d= -f2; }

#-------------------------------------------------------------------------------
# Preflight
#-------------------------------------------------------------------------------
# The Windows-side tests emulate C:\Users\<name> under /mnt/c. In a real WSL
# that mount is writable; inside a container it may have to be created once.
setup_windows_drive() {
  MNT_OK=1
  mkdir -p /mnt/c 2>/dev/null || true
  if [ -d /mnt/c ] && [ -w /mnt/c ]; then return 0; fi
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    if sudo mkdir -p /mnt/c/Users 2>/dev/null && sudo chmod 777 /mnt/c/Users 2>/dev/null; then
      return 0
    fi
  fi
  MNT_OK=0
  msg "Windows-side emulation unavailable (cannot write /mnt/c) - those scenarios will be SKIPPED"
}

# every stub must be executable (git does not always preserve the bit)
chmod +x "${STUBBIN}"/* 2>/dev/null || true

msg "Free AI Agents (LiteLLM + OmniRoute) offline test-suite"
msg "script under test: ${SCRIPT_FILE}"
setup_windows_drive

echo "SUITE RUN - $(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$SUMMARY_FILE"
echo "host: $(uname -sr) | user: $(id -un) | bash: ${BASH_VERSION}" >> "$SUMMARY_FILE"

start_test "T00_static_checks"
if [ -f "$SCRIPT_FILE" ]; then a_ok "script exists"; else a_bad "script missing"; fi
if bash -n "$SCRIPT_FILE" 2>>"$CURRENT_LOG"; then a_ok "bash -n OK"; else a_bad "bash -n failed"; fi
if head -1 "$SCRIPT_FILE" | grep -q '^#!/usr/bin/env bash'; then a_ok "shebang OK"; else a_bad "shebang missing"; fi
if [ -x "$SCRIPT_FILE" ]; then a_ok "executable bit set"; else a_bad "not executable"; fi
if LC_ALL=C grep -qP '[^\x09\x0A\x0D\x20-\x7E]' "$SCRIPT_FILE"; then
  a_bad "non-ASCII characters in the script"
  LC_ALL=C grep -nP '[^\x09\x0A\x0D\x20-\x7E]' "$SCRIPT_FILE" | head -5 >> "$CURRENT_LOG"
else
  a_ok "script is 100% printable ASCII"
fi
assert_contains "$SCRIPT_FILE" 'im-JvD/FreeAI-Agents'
assert_not_contains "$SCRIPT_FILE" 'OmniRoute-OpenCode'
assert_not_contains "$SCRIPT_FILE" 'git clone'
assert_not_contains "$SCRIPT_FILE" 'diegosouzapw/omniroute'
assert_contains "$SCRIPT_FILE" 'npm install -g'
assert_contains "$SCRIPT_FILE" 'FreeAgents/LiteLLM'
assert_contains "$SCRIPT_FILE" 'FreeAgents/Omni'
assert_contains "$SCRIPT_FILE" 'claude-freeagents'
if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck -S warning "$SCRIPT_FILE" >>"$CURRENT_LOG" 2>&1; then a_ok "shellcheck clean (warning level)"; else a_bad "shellcheck reported issues"; fi
else
  a_ok "shellcheck not installed - skipped"
fi
# a CRLF copy must still work (self-heal guard)
crlf="${T_WORK:-/tmp}/crlf.sh"
if [ -z "${T_WORK:-}" ]; then T_WORK="$(mktemp -d /tmp/freeai-test.XXXXXX)"; fi
crlf="${T_WORK}/crlf.sh"
sed 's/$/\r/' "$SCRIPT_FILE" > "$crlf"
if bash "$crlf" version >/dev/null 2>&1; then a_ok "CRLF copy runs (self-heal works)"; else a_bad "CRLF copy failed"; fi
dump_state 2>/dev/null || true
finish_test

#===============================================================================
# T01 - LiteLLM install (all 5 primary keys + the 4 optional providers)
#===============================================================================
start_test "T01_litellm_install_all_keys"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  # leftovers from the old per-gateway installers must disappear
  mkdir -p "${FAKE_ROOT}/usr/local/bin"
  printf '#!/bin/sh\n' > "${FAKE_ROOT}/usr/local/bin/omni"
  printf '#!/bin/sh\n' > "${FAKE_ROOT}/usr/local/bin/litellm"
  printf '#!/bin/sh\n' > "${FAKE_ROOT}/usr/local/bin/litellm-boot.sh"
  printf '1\n1\n\n%s\n%s\n%s\n%s\n%s\ny\n%s\n%s\n%s\n%s\n0\n' \
    "$GROQ_KEY" "$OR_KEY" "$GEMINI_KEY" "$CEREBRAS_KEY" "$MISTRAL_KEY" \
    "$GITHUB_KEY" "$SAMBANOVA_KEY" "$NVIDIA_KEY" "$TOGETHER_KEY" | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "INSTALLATION COMPLETED SUCCESSFULLY"
  assert_contains "${T_WORKSTATE}/apt-calls.log" "install -y docker.io"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "pull ghcr.io/berriai/litellm:main-latest"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "run -d --name litellm --restart unless-stopped -p 4000:4000"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-v ${HOME_DIR}/.litellm/config.yaml:/app/config.yaml:ro"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e GROQ_API_KEY=${GROQ_KEY}"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e TOGETHERAI_API_KEY=${TOGETHER_KEY}"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "run -d --name litellm-db --restart unless-stopped --network litellm-net"
  assert_file_exists "${HOME_DIR}/.litellm/config.yaml"
  assert_models "${HOME_DIR}/.litellm/config.yaml" 18
  assert_contains "${HOME_DIR}/.litellm/config.yaml" "model_name: claude-freeagents"
  assert_contains "${HOME_DIR}/.litellm/config.yaml" "model: nvidia_nim/meta/llama-3.3-70b-instruct"
  assert_contains "${HOME_DIR}/.litellm/config.yaml" "model: together_ai/meta-llama/Llama-3.3-70B-Instruct-Turbo"
  assert_contains "${HOME_DIR}/.litellm/config.yaml" "router_settings:"
  assert_not_contains "${HOME_DIR}/.litellm/config.yaml" "model_group_alias:"
  assert_not_contains "${HOME_DIR}/.litellm/config.yaml" "claude-sonnet-4-5:"
  assert_contains "${HOME_DIR}/.litellm/config.yaml" "enable_pre_call_checks: true"
  MK="$(master_key_from)"
  if [ -n "$MK" ] && [ "$MK" = "$(litellm_docker_run)" ]; then a_ok "master key consistent"; else a_bad "master key mismatch"; fi
  assert_mode "${HOME_DIR}/.litellm/master_key.txt" 600
  assert_file_exists "${HOME_DIR}/.free-ai-agents/provider_keys.env"
  assert_mode "${HOME_DIR}/.free-ai-agents/provider_keys.env" 600
  assert_contains "${HOME_DIR}/.free-ai-agents/provider_keys.env" "GROQ_API_KEY=${GROQ_KEY}"
  assert_mirrors "${FAKE_ROOT}/etc/docker/daemon.json"
  assert_file_exists "${FAKE_ROOT}/usr/local/bin/freeagents"
  assert_file_exists "${FAKE_ROOT}/usr/local/bin/freeagents-boot.sh"
  assert_file_exists "${HOME_DIR}/.free-ai-agents/live_test.sh"
  assert_contains "${HOME_DIR}/.free-ai-agents/live_test.sh" "LIVE upstream E2E"
  assert_contains "${HOME_DIR}/.free-ai-agents/live_test.sh" "claude-freeagents"
  assert_file_missing "${FAKE_ROOT}/usr/local/bin/omni"
  assert_file_missing "${FAKE_ROOT}/usr/local/bin/litellm"
  assert_file_missing "${FAKE_ROOT}/usr/local/bin/litellm-boot.sh"
  assert_contains "${FAKE_ROOT}/etc/wsl.conf" "command = /usr/local/bin/freeagents-boot.sh"
  assert_claude_settings "/mnt/c/Users/Test User/.claude/settings.json" "$MK" "http://127.0.0.1:4000"
  dprof="/mnt/c/Users/Test User/AppData/Local/Claude-3p/configLibrary/00000000-0000-4000-8000-0000000a119e.json"
  assert_file_exists "$dprof"
  assert_json "$dprof" "d['inferenceGatewayBaseUrl'] == 'http://127.0.0.1:4000' and d['modelDiscoveryEnabled'] is True" "desktop profile (LiteLLM) wired"
  assert_json "$dprof" "d['inferenceModels'][0]['labelOverride'] == 'FreeAgents/LiteLLM'" "desktop label FreeAgents/LiteLLM"
  assert_json "$dprof" "d['inferenceModels'][0]['name'] == 'claude-freeagents'" "desktop model is claude-freeagents (not ambiguous catalog id)"
  assert_json "$dprof" "len(d['inferenceModels']) == 1" "only one model advertised (avoids ambiguous error)"
  assert_json "/mnt/c/Users/Test User/AppData/Local/Claude-3p/configLibrary/_meta.json" "any(e.get('id') == '00000000-0000-4000-8000-0000000a119e' for e in d['entries'])" "_meta entry added"
  assert_not_contains "$CURRENT_LOG" "OmniRoute-OpenCode"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T02 - LiteLLM install with a single provider (Groq only)
#===============================================================================
start_test "T02_litellm_groq_only"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n1\n\n%s\n\n\n\n\n\n\n0\n' "$GROQ_KEY" | run_script
  T_RC=$?
  assert_rc 0
  assert_models "${HOME_DIR}/.litellm/config.yaml" 2
  assert_contains "$CURRENT_LOG" "Collected 1 provider key(s)"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e GROQ_API_KEY=${GROQ_KEY}"
  assert_not_contains "${T_WORKSTATE}/docker-calls.log" "OPENROUTER_API_KEY"
  assert_not_contains "${T_WORKSTATE}/docker-calls.log" "GEMINI_API_KEY"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T03 - OmniRoute install (official npm package, managed REST setup)
#===============================================================================
start_test "T03_omniroute_install_npm"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n2\n\n%s\n\n\n%s\n\n\n\n0\n' "$GROQ_KEY" "$CEREBRAS_KEY" | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "${T_WORKSTATE}/node-calls.log" "node -v"
  assert_contains "${T_WORKSTATE}/npm-calls.log" "install -g omniroute"
  assert_contains "${T_WORKSTATE}/omniroute-calls.log" "omniroute serve"
  assert_file_exists "${HOME_DIR}/.free-ai-agents/omniroute.pid"
  assert_contains "$CURRENT_LOG" "OmniRoute is healthy"
  assert_file_exists "${HOME_DIR}/.omniroute/.env"
  assert_mode "${HOME_DIR}/.omniroute/.env" 600
  assert_env_line "${HOME_DIR}/.omniroute/.env" "PORT" "$MOCK_PORT"
  assert_env_line "${HOME_DIR}/.omniroute/.env" "DATA_DIR" "${HOME_DIR}/.omniroute"
  assert_env_line "${HOME_DIR}/.omniroute/.env" "REQUIRE_API_KEY" "true"
  assert_not_contains "${HOME_DIR}/.omniroute/.env" "EXPOSE_CC_DISCOVERY_ALIASES"
  assert_not_contains "${HOME_DIR}/.omniroute/.env" "OMNIROUTE_MEMORY_MB"
  if python3 - "${HOME_DIR}/.omniroute/.env" <<'PY' 2>/dev/null
import sys
vals = {}
for line in open(sys.argv[1], encoding="utf-8"):
    if "=" in line and not line.startswith("#"):
        k, v = line.rstrip("\n").split("=", 1)
        vals[k] = v
assert len(vals.get("JWT_SECRET", "")) >= 32, vals.get("JWT_SECRET")
assert len(vals.get("API_KEY_SECRET", "")) >= 16, vals.get("API_KEY_SECRET")
assert len(vals.get("INITIAL_PASSWORD", "")) >= 8
PY
  then a_ok "OmniRoute secrets satisfy the startup minimums"; else a_bad "OmniRoute secrets too short"; fi
  assert_mock 'assert len(state["connections"]) == 2, state["connections"]' "two provider connections registered"
  assert_mock 'assert [c["provider"] for c in state["connections"]] == ["groq", "cerebras"]' "connections use the OmniRoute provider ids"
  assert_mock 'assert len(state["keys"]) == 1 and state["keys"][0]["name"] == "freeagents-claude"' "one managed client key"
  assert_mock 'assert len(state["combos"]) == 1 and state["combos"][0]["name"] == "claude-freeagents"' "one branded combo"
  assert_mock 'assert state["combos"][0]["strategy"] == "auto"' "combo strategy auto"
  assert_mock 'assert all(m["model"] for m in state["combos"][0]["models"]) and len(state["combos"][0]["models"]) >= 2' "combo models built from the live catalog"
  assert_contains "$CURRENT_LOG" "Anthropic endpoint /v1/messages answered 200"
  assert_not_contains "$CURRENT_LOG" "OmniRoute-OpenCode"
  assert_contains "${CURRENT_LOG}" "npm install -g omniroute"
  assert_file_exists "${HOME_DIR}/.free-ai-agents/live_test.sh"
  assert_contains "${HOME_DIR}/.free-ai-agents/live_test.sh" "LIVE upstream E2E"
  assert_claude_settings "/mnt/c/Users/Test User/.claude/settings.json" "$(tr -d '\n' < "${HOME_DIR}/.free-ai-agents/omniroute_claude.key")" "http://127.0.0.1:${MOCK_PORT}"
  dprof="/mnt/c/Users/Test User/AppData/Local/Claude-3p/configLibrary/00000000-0000-4000-8000-0000000a110e.json"
  assert_file_exists "$dprof"
  assert_json "$dprof" "d['inferenceModels'][0]['labelOverride'] == 'FreeAgents/Omni'" "desktop label FreeAgents/Omni"
  assert_json "$dprof" "d['inferenceModels'][0]['name'] == 'claude-freeagents'" "desktop model is claude-freeagents"
  assert_json "$dprof" "d['inferenceGatewayBaseUrl'] == 'http://127.0.0.1:${MOCK_PORT}'" "desktop profile points at OmniRoute"
  assert_file_missing "/mnt/c/Users/Test User/AppData/Local/Claude-3p/configLibrary/00000000-0000-4000-8000-0000000a119e.json"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T04 - both gateways in a single run (previous default behavior)
#===============================================================================
start_test "T04_both_gateways_single_run"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n3\n\n%s\n%s\n\n\n\n\n0\n' "$GROQ_KEY" "$MISTRAL_KEY" | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "${T_WORKSTATE}/docker-calls.log" "run -d --name litellm"
  assert_contains "${T_WORKSTATE}/npm-calls.log" "install -g omniroute"
  assert_file_exists "${HOME_DIR}/.litellm/config.yaml"
  assert_file_exists "${HOME_DIR}/.omniroute/.env"
  MK="$(master_key_from)"
  assert_claude_settings "/mnt/c/Users/Test User/.claude/settings.json" "$MK" "http://127.0.0.1:4000"
  assert_file_exists "/mnt/c/Users/Test User/AppData/Local/Claude-3p/configLibrary/00000000-0000-4000-8000-0000000a119e.json"
  assert_file_exists "/mnt/c/Users/Test User/AppData/Local/Claude-3p/configLibrary/00000000-0000-4000-8000-0000000a110e.json"
  assert_file_exists "${HOME_DIR}/.free-ai-agents/live_test.sh"
  assert_contains "${HOME_DIR}/.free-ai-agents/live_test.sh" "LIVE upstream E2E"
  assert_mock 'assert len(state["combos"]) == 1 and len(state["connections"]) == 2' "OmniRoute configured next to LiteLLM"
  assert_contains "${CURRENT_LOG}" "LiteLLM engine ready"
  assert_contains "${CURRENT_LOG}" "OmniRoute engine ready"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T05 - non-interactive commands (install / status / doctor)
#===============================================================================
start_test "T05_cli_commands"
fresh_env
env HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" STUBBIN="$STUBBIN" T_WORKSTATE="$T_WORKSTATE" \
  FAKE_ROOT="$FAKE_ROOT" MOCK_OMNI_PORT="$MOCK_PORT" OMNIROUTE_PORT="$MOCK_PORT" \
  HEALTH_CODE="$T_HEALTH_CODE" KEYCHECK_CODE="$T_KEYCHECK_CODE" \
  FREEAGENTS_BOOT_MODE=wslconf LITELLM_HEALTH_WAIT_SEC=2 OMNIROUTE_HEALTH_WAIT_SEC=4 \
  FREEAGENTS_SKIP_WINDOWS=1 \
  bash "$SCRIPT_FILE" install both < /dev/null >> "$CURRENT_LOG" 2>&1
T_RC=$?
if [ "$T_RC" = "1" ]; then a_ok "install aborts without keys (exit 1)"; else a_bad "expected exit 1 without keys, got $T_RC"; fi
assert_contains "$CURRENT_LOG" "At least ONE API key is required"
dump_state
finish_test

#===============================================================================
# T06 - command surface: both gateways, no per-gateway up/down commands
#===============================================================================
start_test "T06_command_surface"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n3\n\n%s\n\n\n\n\n\n0\n' "$GROQ_KEY" | run_script
  T_RC=$?
  assert_rc 0
  cli="${FAKE_ROOT}/usr/local/bin/freeagents"
  assert_file_exists "$cli"
  assert_contains "$cli" "freeagents up|down|restart"
  assert_contains "$cli" "start/stop/restart BOTH gateways"
  assert_contains "$cli" "doctor [engine]"
  assert_contains "$cli" "uninstall"
  assert_file_missing "${FAKE_ROOT}/usr/local/bin/omni"
  assert_contains "$SCRIPT_FILE" "Unknown command:"
  # run the CLI for real: status must report both engines
  env HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" STUBBIN="$STUBBIN" T_WORKSTATE="$T_WORKSTATE" \
    FAKE_ROOT="$FAKE_ROOT" MOCK_OMNI_PORT="$MOCK_PORT" OMNIROUTE_PORT="$MOCK_PORT" \
    HEALTH_CODE="$T_HEALTH_CODE" FREEAGENTS_SKIP_WINDOWS=1 \
    bash "$cli" status >> "$CURRENT_LOG" 2>&1
  assert_contains "$CURRENT_LOG" "=== LITELLM (port 4000) ==="
  assert_contains "$CURRENT_LOG" "=== OMNIROUTE (port ${MOCK_PORT}) ==="
  env HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" STUBBIN="$STUBBIN" T_WORKSTATE="$T_WORKSTATE" \
    FAKE_ROOT="$FAKE_ROOT" MOCK_OMNI_PORT="$MOCK_PORT" OMNIROUTE_PORT="$MOCK_PORT" \
    HEALTH_CODE="$T_HEALTH_CODE" FREEAGENTS_SKIP_WINDOWS=1 \
    bash "$cli" help >> "$CURRENT_LOG" 2>&1
  assert_contains "$CURRENT_LOG" "credentials          dashboard URLs, logins and Claude tokens"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T07 - menu: invalid input is handled, 0 exits cleanly
#===============================================================================
start_test "T07_menu_behavior"
fresh_env
printf 'x\n99\n0\n' | run_script
T_RC=$?
assert_rc 0
assert_contains "$CURRENT_LOG" "Install"
assert_contains "$CURRENT_LOG" "Doctor"
assert_contains "$CURRENT_LOG" "Config Manager"
assert_contains "$CURRENT_LOG" "Invalid choice: 'x'"
assert_contains "$CURRENT_LOG" "Invalid choice: '99'"
dump_state
finish_test

#===============================================================================
# T08 - profile switch: active gateway decides the Claude wiring
#===============================================================================
start_test "T08_profile_switch"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n3\n\n%s\n%s\n\n\n\n\n9\n5\n0\n0\n' "$GROQ_KEY" "$GEMINI_KEY" | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Active gateway for Claude: omniroute"
  OMNI_TOKEN="$(tr -d '\n' < "${HOME_DIR}/.free-ai-agents/omniroute_claude.key")"
  assert_claude_settings "/mnt/c/Users/Test User/.claude/settings.json" "$OMNI_TOKEN" "http://127.0.0.1:${MOCK_PORT}"
  assert_json "/mnt/c/Users/Test User/AppData/Local/Claude-3p/configLibrary/_meta.json" \
    "d['appliedId'] == '00000000-0000-4000-8000-0000000a110e'" "desktop app switched to the Omni profile"
  # switching back must restore the LiteLLM wiring
  printf '9\n5\n0\n0\n' | run_script
  assert_contains "$CURRENT_LOG" "Active gateway for Claude: litellm"
  assert_claude_settings "/mnt/c/Users/Test User/.claude/settings.json" "$(master_key_from)" "http://127.0.0.1:4000"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T09 - Windows proxy: ON (both engines), kept across re-runs, then OFF
#===============================================================================
start_test "T09_windows_proxy"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  T_PROXY_CALL_CODE="200"
  printf '1\n3\ny\n172.20.144.1:7890\n\n%s\n\n\n\n\n\n0\n' "$GROQ_KEY" | run_script
  T_RC=$?
  assert_rc 0
  assert_file_exists "${HOME_DIR}/.free-ai-agents/windows_proxy.txt"
  assert_contains "${HOME_DIR}/.free-ai-agents/windows_proxy.txt" "172.20.144.1:7890"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e HTTP_PROXY=http://172.20.144.1:7890"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e HTTPS_PROXY=http://172.20.144.1:7890"
  assert_env_line "${HOME_DIR}/.omniroute/.env" "HTTP_PROXY" "http://172.20.144.1:7890"
  assert_env_line "${HOME_DIR}/.omniroute/.env" "HTTPS_PROXY" "http://172.20.144.1:7890"
  assert_env_line "${HOME_DIR}/.omniroute/.env" "NO_PROXY" "localhost,127.0.0.1,::1"
  # turning it OFF must strip it from both engines
  printf '9\n2\n0\n0\n' | run_script
  assert_file_missing "${HOME_DIR}/.free-ai-agents/windows_proxy.txt"
  assert_not_contains "${HOME_DIR}/.omniroute/.env" "HTTP_PROXY"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T10 - re-entering keys keeps the proxy and applies to BOTH gateways
#===============================================================================
start_test "T10_rekey_keeps_proxy"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  T_PROXY_CALL_CODE="200"
  printf '1\n3\ny\n172.20.144.1:7890\n\n%s\n\n\n\n\n\n0\n' "$GROQ_KEY" | run_script
  T_RC=$?
  assert_rc 0
  printf '9\n3\n\n\n%s\n\n%s\n\n0\n' "$GEMINI_KEY" "$MISTRAL_KEY" | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e GEMINI_API_KEY=${GEMINI_KEY}"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e MISTRAL_API_KEY=${MISTRAL_KEY}"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e HTTP_PROXY=http://172.20.144.1:7890"
  assert_contains "${HOME_DIR}/.free-ai-agents/windows_proxy.txt" "172.20.144.1:7890"
  assert_mock 'assert sorted(c["provider"] for c in state["connections"]) == ["gemini", "mistral"], state["connections"]' "OmniRoute connections replaced"
  assert_mock 'assert len(state["combos"]) == 1' "single combo kept after rekey"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T11 - UPDATE: re-download from this repo, keys and proxy kept
#===============================================================================
start_test "T11_update_flow"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  cp "$SCRIPT_FILE" "${T_WORK}/self.sh"
  T_SELF_UPDATE="${T_WORK}/self.sh"
  printf '1\n3\n\n%s\n\n\n\n\n\n0\n' "$GROQ_KEY" | run_script
  T_RC=$?
  assert_rc 0
  printf '4\ny\n\n0\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "UPDATE: downloading the latest script from im-JvD/FreeAI-Agents"
  assert_contains "${T_WORKSTATE}/curl-calls.log" "raw.githubusercontent.com/im-JvD/FreeAI-Agents/main/setup.sh"
  assert_contains "$CURRENT_LOG" "Keeping the existing 1 provider key(s)"
  assert_contains "$CURRENT_LOG" "INSTALLATION COMPLETED SUCCESSFULLY"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T12 - self-heal: a broken manager copy is re-downloaded by the CLI
#===============================================================================
start_test "T12_cli_self_heal"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  cp "$SCRIPT_FILE" "${T_WORK}/self.sh"
  T_SELF_UPDATE="${T_WORK}/self.sh"
  printf '1\n1\n\n%s\n\n\n\n\n\n0\n' "$GROQ_KEY" | run_script
  T_RC=$?
  assert_rc 0
  printf 'GARBAGE-NOT-BASH\n' > "${HOME_DIR}/.free-ai-agents/setup.sh"
  env HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" STUBBIN="$STUBBIN" T_WORKSTATE="$T_WORKSTATE" \
    FAKE_ROOT="$FAKE_ROOT" FAKE_SELF_SOURCE="$T_SELF_UPDATE" MOCK_OMNI_PORT="$MOCK_PORT" OMNIROUTE_PORT="$MOCK_PORT" \
    HEALTH_CODE="$T_HEALTH_CODE" FREEAGENTS_SKIP_WINDOWS=1 \
    bash "${FAKE_ROOT}/usr/local/bin/freeagents" status >> "$CURRENT_LOG" 2>&1
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Fetching the Free AI Agents manager"
  assert_contains "$CURRENT_LOG" "=== LITELLM (port 4000) ==="
  if cmp -s "$SCRIPT_FILE" "${HOME_DIR}/.free-ai-agents/setup.sh"; then a_ok "manager copy restored"; else a_bad "manager copy not restored"; fi
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T13 - UNINSTALL removes everything the installer created
#===============================================================================
start_test "T13_uninstall"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n3\n\n%s\n%s\n\n\n\n\n0\n' "$GROQ_KEY" "$GEMINI_KEY" | run_script
  T_RC=$?
  assert_rc 0
  settings="/mnt/c/Users/Test User/.claude/settings.json"
  assert_file_exists "$settings"
  printf '6\ny\n0\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "UNINSTALL COMPLETED SUCCESSFULLY"
  if grep -qxF "litellm" "${T_WORKSTATE}/containers.txt" 2>/dev/null; then a_bad "litellm container still registered"; else a_ok "litellm container removed"; fi
  if grep -qxF "litellm-db" "${T_WORKSTATE}/containers.txt" 2>/dev/null; then a_bad "litellm-db container still registered"; else a_ok "litellm-db container removed"; fi
  assert_file_missing "${HOME_DIR}/.litellm"
  assert_file_missing "${HOME_DIR}/.omniroute"
  assert_file_missing "${HOME_DIR}/.free-ai-agents"
  assert_file_missing "${HOME_DIR}/.free-ai-agents/live_test.sh"
  assert_file_missing "${FAKE_ROOT}/usr/local/bin/freeagents"
  assert_file_missing "${FAKE_ROOT}/usr/local/bin/freeagents-boot.sh"
  assert_not_contains "${FAKE_ROOT}/etc/wsl.conf" "command = /usr/local/bin/freeagents-boot.sh"
  assert_not_contains "$settings" "ANTHROPIC_BASE_URL"
  assert_contains "${T_WORKSTATE}/npm-calls.log" "uninstall -g omniroute"
  assert_json "$settings" "'env' not in d or 'ANTHROPIC_MODEL' not in d['env']" "Claude Code settings cleaned"
  dprof="/mnt/c/Users/Test User/AppData/Local/Claude-3p/configLibrary/00000000-0000-4000-8000-0000000a119e.json"
  assert_file_missing "$dprof"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T14 - non-interactive 'install' + 'uninstall --yes' (scripted use)
#===============================================================================
start_test "T14_scripted_install_keys_file"
fresh_env
# pre-seed the key file: the installer must offer to keep it without prompting
mkdir -p "${HOME_DIR}/.free-ai-agents"
printf 'GROQ_API_KEY=%s\n' "$GROQ_KEY" > "${HOME_DIR}/.free-ai-agents/provider_keys.env"
chmod 600 "${HOME_DIR}/.free-ai-agents/provider_keys.env"
printf '\n\n' | env HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" STUBBIN="$STUBBIN" T_WORKSTATE="$T_WORKSTATE" \
  FAKE_ROOT="$FAKE_ROOT" MOCK_OMNI_PORT="$MOCK_PORT" OMNIROUTE_PORT="$MOCK_PORT" \
  HEALTH_CODE="$T_HEALTH_CODE" KEYCHECK_CODE="$T_KEYCHECK_CODE" \
  FREEAGENTS_BOOT_MODE=wslconf LITELLM_HEALTH_WAIT_SEC=2 OMNIROUTE_HEALTH_WAIT_SEC=4 \
  FREEAGENTS_SKIP_WINDOWS=1 \
  bash "$SCRIPT_FILE" install litellm >> "$CURRENT_LOG" 2>&1
T_RC=$?
assert_rc 0
assert_contains "$CURRENT_LOG" "Existing provider keys found"
assert_contains "$CURRENT_LOG" "Keeping the existing 1 provider key(s)"
assert_models "${HOME_DIR}/.litellm/config.yaml" 2
assert_contains "${T_WORKSTATE}/docker-calls.log" "-e GROQ_API_KEY=${GROQ_KEY}"
dump_state
finish_test

#===============================================================================
# T15 - no Windows integration: the install still succeeds and warns
#===============================================================================
start_test "T15_no_windows_integration"
fresh_env
T_SKIP_WINDOWS="1"
printf '1\n3\n\n%s\n\n\n\n\n\n0\n' "$GROQ_KEY" | run_script
T_RC=$?
assert_rc 0
assert_contains "$CURRENT_LOG" "Windows integration disabled on purpose"
assert_file_missing "/mnt/c/Users/Test User/.claude/settings.json"
assert_file_exists "${HOME_DIR}/.litellm/config.yaml"
assert_mock 'assert len(state["combos"]) == 1' "OmniRoute still configured headless"
dump_state
finish_test

#===============================================================================
# T16 - key verification: rejected keys are reported and can be re-entered
#===============================================================================
start_test "T16_key_verification"
fresh_env
T_KEYCHECK_CODE="401"
printf '1\n1\n\n%s\nn\nn\n%s\n\n\n\n\n0\n' "$GROQ_KEY" "$GROQ_KEY" | run_script
T_RC=$?
assert_rc 0
assert_contains "$CURRENT_LOG" "REJECTED (HTTP 401)"
assert_contains "$CURRENT_LOG" "Re-enter the rejected keys now?"
dump_state
finish_test

#===============================================================================
# T17 - re-install is idempotent: secrets, keys and the combo stay stable
#===============================================================================
start_test "T17_idempotent_reinstall"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n3\n\n%s\n%s\n\n\n\n\n0\n' "$GROQ_KEY" "$CEREBRAS_KEY" | run_script
  T_RC=$?
  assert_rc 0
  MK1="$(master_key_from)"
  SECRET1="$(awk -F= '/^API_KEY_SECRET=/{print $2}' "${HOME_DIR}/.omniroute/.env")"
  OMNIKEY1="$(tr -d '\n' < "${HOME_DIR}/.free-ai-agents/omniroute_claude.key")"
  printf '\n\n' | env HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" STUBBIN="$STUBBIN" T_WORKSTATE="$T_WORKSTATE" \
    FAKE_ROOT="$FAKE_ROOT" MOCK_OMNI_PORT="$MOCK_PORT" OMNIROUTE_PORT="$MOCK_PORT" \
    HEALTH_CODE="$T_HEALTH_CODE" KEYCHECK_CODE="$T_KEYCHECK_CODE" \
    FREEAGENTS_BOOT_MODE=wslconf LITELLM_HEALTH_WAIT_SEC=2 OMNIROUTE_HEALTH_WAIT_SEC=4 \
    FREEAGENTS_SKIP_WINDOWS=1 \
    bash "$SCRIPT_FILE" install both >> "$CURRENT_LOG" 2>&1
  T_RC=$?
  assert_rc 0
  if [ "$MK1" = "$(master_key_from)" ]; then a_ok "master key reused"; else a_bad "master key rotated"; fi
  SECRET2="$(awk -F= '/^API_KEY_SECRET=/{print $2}' "${HOME_DIR}/.omniroute/.env")"
  if [ -n "$SECRET1" ] && [ "$SECRET1" = "$SECRET2" ]; then a_ok "OmniRoute secrets reused"; else a_bad "OmniRoute secrets rotated"; fi
  OMNIKEY2="$(tr -d '\n' < "${HOME_DIR}/.free-ai-agents/omniroute_claude.key")"
  if [ -n "$OMNIKEY1" ] && [ "$OMNIKEY1" = "$OMNIKEY2" ]; then a_ok "client API key reused"; else a_bad "client API key rotated"; fi
  assert_mock 'assert len(state["connections"]) == 2 and len(state["keys"]) == 1 and len(state["combos"]) == 1' "no duplicates created"
  assert_contains "$CURRENT_LOG" "Reusing the stored managed API key"
  assert_contains "$CURRENT_LOG" "Routing combo 'claude-freeagents' updated"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T18 - OmniRoute login failure: install continues, manual setup is explained
#===============================================================================
start_test "T18_omniroute_login_failure"
fresh_env
T_SKIP_WINDOWS="1"
T_REJECT_LOGIN="1"
printf '1\n2\n\n%s\n\n\n\n\n\n0\n' "$GROQ_KEY" | run_script
T_RC=$?
assert_rc 0
assert_contains "$CURRENT_LOG" "Dashboard login failed (HTTP 401)"
assert_contains "$CURRENT_LOG" "must be added manually in the dashboard"
assert_file_exists "${HOME_DIR}/.omniroute/.env"
assert_mock 'assert len(state["combos"]) == 0' "no combo created without a session"
dump_state
finish_test

#===============================================================================
# T19 - provider registry sanity (read straight from the script)
#===============================================================================
start_test "T19_provider_registry"
fresh_env
lib="$(script_lib)"
if env HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" FAKE_ROOT="$FAKE_ROOT" T_WORKSTATE="$T_WORKSTATE" \
   bash -c "source '$lib' >/dev/null 2>&1; all_provider_ids | tr '\n' ' '" > "${T_WORK}/ids.txt" 2>>"$CURRENT_LOG"; then
  got="$(cat "${T_WORK}/ids.txt")"
  if [ "$got" = "groq openrouter gemini cerebras mistral github sambanova nvidia_nim together_ai " ]; then
    a_ok "provider registry complete"
  else
    a_bad "unexpected provider ids: $got"
  fi
else
  a_bad "could not load the script library"
fi
assert_contains "$SCRIPT_FILE" "PROVIDER_SPECS=("
assert_contains "$SCRIPT_FILE" "openrouter/deepseek/deepseek-chat-v3.1:free"
assert_contains "$SCRIPT_FILE" "github/gpt-4o-mini"
if [ "$(grep -c '"[a-z_]*|' "$SCRIPT_FILE" | head -1)" -ge 1 ]; then a_ok "spec table present"; else a_bad "spec table missing"; fi
dump_state
finish_test

#===============================================================================
# T20 - docker: mirror backup, pull retry and registry-fallback behavior
#===============================================================================
start_test "T20_docker_resilience"
fresh_env
mkdir -p "${FAKE_ROOT}/etc/docker"
printf '{"registry-mirrors":["https://old.example"]}\n' > "${FAKE_ROOT}/etc/docker/daemon.json"
T_PULL_RETRIES="2"
printf '1\n1\n\n%s\n\n\n\n\n\n\n0\n' "$GROQ_KEY" | env DOCKER_PULL_FAIL=1 PATH="${STUBBIN}:${PATH}" HOME="$HOME_DIR" \
  STUBBIN="$STUBBIN" T_WORKSTATE="$T_WORKSTATE" FAKE_ROOT="$FAKE_ROOT" MOCK_OMNI_PORT="$MOCK_PORT" \
  OMNIROUTE_PORT="$MOCK_PORT" HEALTH_CODE="$T_HEALTH_CODE" KEYCHECK_CODE="$T_KEYCHECK_CODE" \
  FREEAGENTS_BOOT_MODE="$T_BOOT_MODE" LITELLM_UI_DB="$T_UI_DB" LITELLM_PULL_RETRIES="$T_PULL_RETRIES" \
  LITELLM_HEALTH_WAIT_SEC="$T_HEALTH_WAIT_SEC" FREEAGENTS_SKIP_WINDOWS="$T_SKIP_WINDOWS" \
  bash "$SCRIPT_FILE" install litellm >> "$CURRENT_LOG" 2>&1
T_RC=$?
if [ "$T_RC" != "0" ]; then a_ok "install fails cleanly when the image cannot be pulled"; else a_bad "expected a failure when every pull fails"; fi
assert_contains "$CURRENT_LOG" "Image pull failed after 2 attempt(s)"
assert_contains "$CURRENT_LOG" "Existing daemon.json backed up"
assert_mirrors "${FAKE_ROOT}/etc/docker/daemon.json"
assert_not_contains "$CURRENT_LOG" "OmniRoute-OpenCode"
dump_state
finish_test

#===============================================================================
# T21 - OmniRoute with an existing short secret: regenerated, not fatal
#===============================================================================
start_test "T21_omniroute_weak_secret_recovery"
fresh_env
mkdir -p "${HOME_DIR}/.omniroute"
printf 'JWT_SECRET=short\nAPI_KEY_SECRET=x\nINITIAL_PASSWORD=pw\nPORT=1\n' > "${HOME_DIR}/.omniroute/.env"
printf '1\n2\n\n%s\n\n\n\n\n\n0\n' "$GROQ_KEY" | run_script
T_RC=$?
assert_rc 0
assert_contains "$CURRENT_LOG" "A stored OmniRoute secret was too short and has been regenerated"
if python3 - "${HOME_DIR}/.omniroute/.env" <<'PY' 2>/dev/null
import sys
vals = dict(l.rstrip("\n").split("=", 1) for l in open(sys.argv[1]) if "=" in l and not l.startswith("#"))
assert len(vals["JWT_SECRET"]) >= 32 and len(vals["API_KEY_SECRET"]) >= 16
PY
then a_ok "weak secrets replaced with strong ones"; else a_bad "weak secrets survived"; fi
assert_mock 'assert len(state["combos"]) == 1' "OmniRoute fully configured after the fix"
dump_state
finish_test

#===============================================================================
# T22 - Docker-less host: OmniRoute-only install must not touch docker
#===============================================================================
start_test "T22_omniroute_only_needs_no_docker"
fresh_env
printf '1\n2\n\n%s\n\n\n\n\n\n0\n' "$GROQ_KEY" | run_script
T_RC=$?
assert_rc 0
assert_not_contains "${T_WORKSTATE}/apt-calls.log" "install -y docker.io"
assert_not_contains "${T_WORKSTATE}/docker-calls.log" "docker pull"
assert_contains "$CURRENT_LOG" "npm install -g omniroute"
assert_mock 'assert len(state["combos"]) == 1' "OmniRoute configured without Docker"
dump_state
finish_test

#===============================================================================
# Summary
#===============================================================================
TOTAL=$((PASS+FAIL+SKIP))
echo
msg "==================================================================="
msg "TOTAL ${TOTAL} | PASS ${PASS} | FAIL ${FAIL} | SKIP ${SKIP}"
msg "logs:   ${RESULTS_DIR}/"
msg "summary ${SUMMARY_FILE}"
msg "==================================================================="
echo "TOTAL ${TOTAL} | PASS ${PASS} | FAIL ${FAIL} | SKIP ${SKIP}" >> "$SUMMARY_FILE"

if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
