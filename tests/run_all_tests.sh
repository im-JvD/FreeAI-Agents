#!/usr/bin/env bash
#===============================================================================
# tests/run_all_tests.sh
#
# OFFLINE (simulated) test-suite for the LiteLLM <-> Claude Code setup script.
#
# How it works:
#   - every external command the script touches (docker, apt-get, service,
#     systemctl, curl, powershell.exe, sudo) is replaced by a deterministic
#     stub from tests/helpers/stubbin
#   - /etc/docker writes are virtualized into a temporary FAKE_ROOT
#   - the Windows user profile is emulated under /mnt/c/Users/<Test User>
#     (a dedicated fake folder, never a real profile; removed on exit)
#   - every scenario runs the REAL script end-to-end and asserts on:
#       exit codes, generated config.yaml, generated Claude settings.json,
#       master-key consistency, daemon.json mirrors, docker run arguments,
#       container lifecycle and uninstall behavior
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
REAL_DAEMON_STATE=""   # "", "was-present", "seeded-absent"
REAL_DAEMON_BACKUP=""
CREATED_PROFILE_DIRS=()
CURRENT_LOG=""

ALL7_MODELS=$'claude-gpt-oss-120b\nclaude-gpt-oss-20b\nclaude-deepseek-v3.1\nclaude-deepseek-v3-0324\nclaude-gemini-2.0-flash\nclaude-llama3.1-70b\nclaude-codestral\nclaude-sonnet-4-5\nclaude-haiku-4-5'
GROQ2_MODELS=$'claude-gpt-oss-120b\nclaude-gpt-oss-20b\nclaude-sonnet-4-5\nclaude-haiku-4-5'
OR2_MODELS=$'claude-deepseek-v3.1\nclaude-deepseek-v3-0324\nclaude-sonnet-4-5\nclaude-haiku-4-5'
GEMINI1_MODELS=$'claude-gemini-2.0-flash\nclaude-sonnet-4-5\nclaude-haiku-4-5'

cleanup() {
  # remove fake Windows profile dirs created for the tests (never real ones)
  local d
  for d in "${CREATED_PROFILE_DIRS[@]:-}"; do
    [ -n "$d" ] && rm_rf_sudo "$d"
  done
  # restore host daemon.json if the backup test seeded it
  if [ "$REAL_DAEMON_STATE" = "was-present" ] && [ -f "$REAL_DAEMON_BACKUP" ]; then
    cp_sudo "$REAL_DAEMON_BACKUP" /etc/docker/daemon.json
  elif [ "$REAL_DAEMON_STATE" = "seeded-absent" ]; then
    rm_f_sudo /etc/docker/daemon.json
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

# root/sudo helpers (work as root or via sudo, otherwise fail softly)
as_root() {
  if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo -n "$@"; fi
}
rm_rf_sudo() { as_root rm -rf "$1" 2>/dev/null || true; }
rm_f_sudo()  { as_root rm -f "$1" 2>/dev/null || true; }
cp_sudo()    { as_root cp "$1" "$2" 2>/dev/null || true; }

start_test() {
  T_NAME="$1"
  CURRENT_LOG="${RESULTS_DIR}/${T_NAME}.log"
  : > "$CURRENT_LOG"
}

#-------------------------------------------------------------------------------
# Fresh isolated environment per test
#-------------------------------------------------------------------------------
fresh_env() {
  # deterministic start: make sure no docker stub is left in STUBBIN
  # (tests that need it install it explicitly, e.g. T16)
  rm -f "${STUBBIN}/docker"
  T_WORK="$(mktemp -d /tmp/litellm-test.XXXXXX)"
  T_WORKSTATE="${T_WORK}/state"
  FAKE_ROOT="${T_WORK}/fakeroot"
  HOME_DIR="${T_WORK}/home"
  mkdir -p "$T_WORKSTATE" "$FAKE_ROOT" "$HOME_DIR"
  : > "${T_WORKSTATE}/docker-calls.log"
  : > "${T_WORKSTATE}/apt-calls.log"
  : > "${T_WORKSTATE}/containers.txt"
  : > "${T_WORKSTATE}/container-running.txt"
  : > "${T_WORKSTATE}/images.txt"
  # reset shared fake Windows profiles so every test starts clean
  for u in "Test User" "Ali Rezaei"; do
    for d in "/mnt/c/Users/${u}/.config" "/mnt/c/Users/${u}/.claude"; do
      [ -w "$d" ] && rm -rf "$d"
    done
  done
  return 0 2>/dev/null || true
  # mirror the host /etc/docker/daemon.json into the virtual root (if any),
  # so the script's backup branch behaves consistently
  if [ -f /etc/docker/daemon.json ]; then
    mkdir -p "${FAKE_ROOT}/etc/docker"
    cp /etc/docker/daemon.json "${FAKE_ROOT}/etc/docker/daemon.json"
  fi
}

# Runs the real script inside the isolated environment.
# Expected input (menu choices / keys) is piped in by the caller.
run_script() { # optional $1 = path of the script copy to run (default: the real one)
  local script_file="${1:-$SCRIPT_FILE}"
  env -u DOCKER_PULL_FAIL -u DOCKER_APT_FAIL \
    HOME="$HOME_DIR" \
    PATH="${STUBBIN}:${PATH}" \
    STUBBIN="$STUBBIN" \
    T_WORKSTATE="$T_WORKSTATE" \
    FAKE_ROOT="$FAKE_ROOT" \
    HEALTH_CODE="${T_HEALTH_CODE:-200}" \
    LITELLM_BOOT_MODE="${T_BOOT_MODE:-auto}" \
    LITELLM_PULL_RETRIES="${T_PULL_RETRIES:-3}" \
    LITELLM_UI_DB="${T_UI_DB:-1}" \
    LITELLM_HEALTH_WAIT_SEC="${T_HEALTH_WAIT_SEC:-}" \
    KEYCHECK_CODE="${T_KEYCHECK_CODE:-200}" \
    PROXY_CALL_CODE="${T_PROXY_CALL_CODE:-}" \
    PS_DESKTOP_DENY="${T_PS_DESKTOP_DENY:-}" \
    FAKE_OMNI_SCRIPT="${T_FAKE_OMNI:-}" \
    bash "$script_file" >> "$CURRENT_LOG" 2>&1
}

#-------------------------------------------------------------------------------
# Assertion helpers (each failure is logged and counted)
#-------------------------------------------------------------------------------
A_FAILURES=0
a_ok()   { echo "    ok: $*" >> "$CURRENT_LOG"; }
a_bad()  { echo "    ASSERTION FAILED: $*" >> "$CURRENT_LOG"; A_FAILURES=$((A_FAILURES+1)); }

assert_rc() { # $1 expected rc
  if [ "${T_RC:-999}" = "$1" ]; then a_ok "exit code = $1"; else a_bad "exit code expected $1, got ${T_RC:-unset}"; fi
}
assert_contains() { # $1 file, $2 needle (fixed string)
  if grep -qF -- "$2" "$1" 2>/dev/null; then a_ok "contains: $2"; else a_bad "expected to contain: $2"; fi
}
assert_not_contains() { # $1 file, $2 needle
  if grep -qF -- "$2" "$1" 2>/dev/null; then a_bad "expected NOT to contain: $2"; else a_ok "not contains: $2"; fi
}
assert_file_exists() {
  if [ -e "$1" ]; then a_ok "file exists: $1"; else a_bad "file missing: $1"; fi
}
assert_file_missing() {
  if [ ! -e "$1" ]; then a_ok "file missing: $1"; else a_bad "file should not exist: $1"; fi
}
assert_models() { # $1 config.yaml path, $2 expected (newline separated)
  local got expected="$2"
  got="$(model_names "$1")"
  if [ -z "$got" ]; then a_bad "could not extract models from: $1"; return; fi
  if [ "$got" = "$expected" ]; then
    a_ok "models match (${expected//$'\n'/, })"
  else
    a_bad "models mismatch: got [${got//$'\n'/, }] expected [${expected//$'\n'/, }]"
  fi
}

# Extract model_name list from generated config.yaml
# Uses PyYAML when available; falls back to a structural sed extraction.
model_names() {
  local out rc
  out="$(python3 - "$1" <<'PY' 2>/dev/null
import sys
try:
    import yaml
except Exception:
    sys.exit(3)
try:
    cfg = yaml.safe_load(open(sys.argv[1]))
except Exception:
    sys.exit(4)
for m in (cfg.get("model_list") or []):
    print(m.get("model_name", ""))
PY
)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf '%s' "$out"
    return 0
  fi
  # structural fallback (no PyYAML installed)
  sed -n 's/^  - model_name: //p' "$1" 2>/dev/null
}

# Full validation of a generated Claude Code settings.json
# $1 = file, $2 = master key, $3 = expected main model, $4 = expected fast/background model
assert_claude_settings() {
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import sys, json
path, mkey, main_model, fast_model = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
fails = 0
def bad(msg):
    global fails
    fails += 1
    print(f"    ASSERTION FAILED (settings.json): {msg}")
try:
    cfg = json.load(open(path))
except Exception as e:
    bad(f"invalid JSON: {e}")
    sys.exit(1)
env = cfg.get("env") or {}
if env.get("ANTHROPIC_BASE_URL") != "http://127.0.0.1:4000":
    bad(f"ANTHROPIC_BASE_URL mismatch: {env.get('ANTHROPIC_BASE_URL')} (must have NO /v1 suffix)")
if env.get("ANTHROPIC_AUTH_TOKEN") != mkey:
    bad("ANTHROPIC_AUTH_TOKEN does not match master key")
if env.get("ANTHROPIC_MODEL") != main_model:
    bad(f"ANTHROPIC_MODEL mismatch: {env.get('ANTHROPIC_MODEL')}")
if env.get("ANTHROPIC_SMALL_FAST_MODEL") != fast_model:
    bad(f"ANTHROPIC_SMALL_FAST_MODEL mismatch: {env.get('ANTHROPIC_SMALL_FAST_MODEL')}")
if env.get("ANTHROPIC_DEFAULT_SONNET_MODEL") != main_model:
    bad("ANTHROPIC_DEFAULT_SONNET_MODEL mismatch")
if env.get("ANTHROPIC_DEFAULT_HAIKU_MODEL") != fast_model:
    bad("ANTHROPIC_DEFAULT_HAIKU_MODEL mismatch")
if env.get("CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY") != "1":
    bad("gateway model discovery not enabled")
if fails == 0:
    print("    ok: Claude Code settings.json fully valid")
sys.exit(1 if fails else 0)
PY
  local rc=$?
  if [ $rc -ne 0 ]; then A_FAILURES=$((A_FAILURES+1)); else a_ok "Claude settings valid ($1)"; fi
  return $rc
}

assert_daemon_json_mirrors() { # $1 = daemon.json path
  python3 - "$1" <<'PY'
import sys, json
expected = ["https://docker.arvancloud.ir",
            "https://docker.hub.iran.liara.run",
            "https://docker.iranserver.com"]
try:
    mirrors = json.load(open(sys.argv[1])).get("registry-mirrors")
except Exception as e:
    print(f"    ASSERTION FAILED: daemon.json invalid: {e}"); sys.exit(1)
if mirrors != expected:
    print(f"    ASSERTION FAILED: mirrors mismatch: {mirrors}"); sys.exit(1)
print("    ok: daemon.json mirrors exact")
PY
  if [ $? -ne 0 ]; then A_FAILURES=$((A_FAILURES+1)); else a_ok "daemon.json mirrors exact ($1)"; fi
}

finish_test() {
  if [ "$A_FAILURES" -eq 0 ]; then pass_test; else fail_test "${A_FAILURES} assertion(s) failed - see ${CURRENT_LOG}"; fi
  A_FAILURES=0
  [ -n "$T_WORK" ] && [ -d "$T_WORK" ] && rm -rf "$T_WORK"
}

# dump auxiliary state into the test log (for committed evidence)
dump_state() {
  {
    echo; echo "--- docker-calls.log ---";     cat "${T_WORKSTATE}/docker-calls.log" 2>/dev/null
    echo; echo "--- apt-calls.log ---";        cat "${T_WORKSTATE}/apt-calls.log" 2>/dev/null
    echo; echo "--- containers.txt ---";       cat "${T_WORKSTATE}/containers.txt" 2>/dev/null
    echo; echo "--- generated config.yaml ---";  cat "${HOME_DIR}/.litellm/config.yaml" 2>/dev/null
    echo; echo "--- generated daemon.json (virtual) ---"; cat "${FAKE_ROOT}/etc/docker/daemon.json" 2>/dev/null
    echo; echo "--- generated Claude settings.json ---"; cat "/mnt/c/Users/Test User/.claude/settings.json" 2>/dev/null
  } >> "$CURRENT_LOG"
}

master_key_from() { cat "${HOME_DIR}/.litellm/master_key.txt" 2>/dev/null | tr -d '\n'; }
master_key_in_docker_run() {
  grep -o 'LITELLM_MASTER_KEY=[^ ]*' "${T_WORKSTATE}/docker-calls.log" 2>/dev/null | head -1 | cut -d= -f2
}

#-------------------------------------------------------------------------------
# Preflight
#-------------------------------------------------------------------------------
msg "LiteLLM <-> Claude Code offline test-suite"
msg "script under test: ${SCRIPT_FILE}"

echo "SUITE RUN - $(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$SUMMARY_FILE"
echo "host: $(uname -sr) | user: $(id -un) | bash: ${BASH_VERSION}" >> "$SUMMARY_FILE"

start_test "T00_static_checks"
A_FAILURES=0
if [ -f "$SCRIPT_FILE" ]; then a_ok "script file exists"; else a_bad "script file missing"; fi
if bash -n "$SCRIPT_FILE" 2>>"$CURRENT_LOG"; then a_ok "bash -n (syntax) OK"; else a_bad "bash -n failed"; fi
if head -1 "$SCRIPT_FILE" | grep -q '^#!/usr/bin/env bash'; then a_ok "shebang OK"; else a_bad "shebang missing"; fi
if [ -x "$SCRIPT_FILE" ]; then a_ok "executable bit set"; else a_bad "not executable"; fi
# CRITICAL RULE: script source + terminal output must be 100% ASCII (RTL-safe)
if LC_ALL=C grep -qP '[^\x09\x0A\x0D\x20-\x7E]' "$SCRIPT_FILE"; then
  a_bad "non-ASCII characters found in script (breaks RTL terminals)"
  LC_ALL=C grep -nP '[^\x09\x0A\x0D\x20-\x7E]' "$SCRIPT_FILE" | head -5 >> "$CURRENT_LOG"
else
  a_ok "script is 100% printable ASCII (RTL-safe)"
fi
finish_test

# prepare the fake Windows profiles under /mnt/c (targeted names only)
MNT_OK=1
for u in "Test User" "Ali Rezaei"; do
  d="/mnt/c/Users/${u}"
  if [ ! -d "$d" ]; then
    if as_root mkdir -p "$d" 2>/dev/null && as_root chown "$(id -u):$(id -g)" "$d" 2>/dev/null; then
      CREATED_PROFILE_DIRS+=("$d")
    else
      MNT_OK=0
    fi
  else
    # directory already exists (e.g. re-run); make sure we can write into it
    [ -w "$d" ] || MNT_OK=0
  fi
done
if [ "$MNT_OK" -eq 1 ]; then
  msg "fake Windows profiles ready under /mnt/c/Users (isolated names, removed on exit)"
else
  msg "WARNING: cannot create /mnt/c fake profiles - profile-dependent tests will SKIP"
fi

# permissions to manage /etc/docker/daemon.json (needed only by T12/T13)
CAN_MANAGE_DAEMON=1
if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
  CAN_MANAGE_DAEMON=0
fi

#===============================================================================
# T01 - full install with all 5 API keys (apt install path)
#===============================================================================
start_test "T01_full_install_all_keys"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  # simulate leftovers from an OLDER script version: a non-UUID profile plus
  # an applied entry from the other engine that must survive untouched
  leglib="/mnt/c/Users/Test User/AppData/Local/Claude-3p/configLibrary"
  mkdir -p "$leglib"
  printf '{"inferenceProvider":"gateway"}\n' > "${leglib}/litellm-free-ai-agents.json"
  printf '{"appliedId":"00000000-0000-4000-8000-0000000a110e","entries":[{"id":"00000000-0000-4000-8000-0000000a110e","name":"OmniRoute"},{"id":"litellm-free-ai-agents","name":"LiteLLM"}]}\n' > "${leglib}/_meta.json"
  printf '1\n\n\n\n\n\n\n\ngsk_test_groq_0123456789abcd\nsk-or-test_0123456789abcd\nAIzaTest0123456789abcd\ncsk-test_0123456789abcd\nsk_mistral_test012345678\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "INSTALLATION COMPLETED SUCCESSFULLY"
  assert_contains "${T_WORKSTATE}/apt-calls.log" "install -y docker.io"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "pull ghcr.io/berriai/litellm:main-latest"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "run -d --name litellm --restart unless-stopped -p 4000:4000"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-v ${HOME_DIR}/.litellm/config.yaml:/app/config.yaml:ro"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "--config /app/config.yaml --port 4000"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e GROQ_API_KEY=gsk_test_groq_0123456789abcd"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e OPENROUTER_API_KEY=sk-or-test_0123456789abcd"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e GEMINI_API_KEY=AIzaTest0123456789abcd"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e CEREBRAS_API_KEY=csk-test_0123456789abcd"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e MISTRAL_API_KEY=sk_mistral_test012345678"
  if grep -qxF "litellm" "${T_WORKSTATE}/containers.txt"; then a_ok "container registered"; else a_bad "container not registered"; fi
  assert_file_exists "${HOME_DIR}/.litellm/config.yaml"
  assert_file_exists "${HOME_DIR}/.litellm/master_key.txt"
  assert_models "${HOME_DIR}/.litellm/config.yaml" "$ALL7_MODELS"  # now 9 entries (2 aliases)
  MK="$(master_key_from)"
  if [ -n "$MK" ] && [ "$MK" = "$(master_key_in_docker_run)" ]; then a_ok "master key consistent (file == docker env)"; else a_bad "master key mismatch"; fi
  assert_file_exists "${HOME_DIR}/.litellm/dashboard_credentials.txt"
  assert_contains "${HOME_DIR}/.litellm/dashboard_credentials.txt" "Username : admin"
  assert_contains "${HOME_DIR}/.litellm/dashboard_credentials.txt" "Password : ${MK}"
  assert_contains "$CURRENT_LOG" "Password  : ${MK}"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e UI_PASSWORD=${MK}"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e UI_USERNAME=admin"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e UI_PASSWORD=${MK}"
  assert_file_exists "${HOME_DIR}/.litellm/db_password.txt"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "run -d --name litellm-db --restart unless-stopped --network litellm-net"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e POSTGRES_USER=litellm"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-v ${HOME_DIR}/.litellm/pgdata:/var/lib/postgresql/data"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "exec litellm-db pg_isready"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e DATABASE_URL=postgresql://litellm:"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "@litellm-db:5432/litellm"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "--network litellm-net"
  assert_contains "${HOME_DIR}/.litellm/config.yaml" "database_url: os.environ/DATABASE_URL"
  assert_file_exists "${FAKE_ROOT}/usr/local/bin/freeagents"
  assert_file_exists "${FAKE_ROOT}/usr/local/bin/litellm-boot.sh"
  if grep -qF "command = /usr/local/bin/litellm-boot.sh" "${FAKE_ROOT}/etc/wsl.conf" 2>/dev/null \
     || [ -f "${FAKE_ROOT}/etc/systemd/system/litellm.service" ]; then
    a_ok "boot persistence configured (wsl.conf entry or systemd unit)"
  else
    a_bad "no boot persistence found (neither wsl.conf entry nor systemd unit)"
  fi
  assert_daemon_json_mirrors "${FAKE_ROOT}/etc/docker/daemon.json"
  if [ -f /etc/docker/daemon.json ]; then
    assert_contains "$CURRENT_LOG" "Existing daemon.json backed up"
  else
    assert_not_contains "$CURRENT_LOG" "backed up"
  fi
  assert_file_exists "/mnt/c/Users/Test User/.claude/settings.json"
  assert_claude_settings "/mnt/c/Users/Test User/.claude/settings.json" "$MK" "claude-gpt-oss-120b" "claude-gemini-2.0-flash"
  assert_contains "$CURRENT_LOG" "Writing the LiteLLM profile into the Claude Desktop app..."
  assert_contains "$CURRENT_LOG" "Desktop profile written (configLibrary)"
  assert_contains "$CURRENT_LOG" "ALREADY CONFIGURED automatically"
  dprof="/mnt/c/Users/Test User/AppData/Local/Claude-3p/configLibrary/00000000-0000-4000-8000-0000000a119e.json"
  assert_file_exists "$dprof"
  assert_file_missing "${leglib}/litellm-free-ai-agents.json"
  assert_contains "$CURRENT_LOG" "Removed an outdated desktop profile (old id)."
  if python3 -c "
import json,sys
d=json.load(open('$dprof'))
assert d['inferenceGatewayBaseUrl']=='http://127.0.0.1:4000', d
assert d['inferenceProvider']=='gateway'
assert d['inferenceGatewayApiKey']==sys.argv[1]
names=[e['name'] for e in d['inferenceModels']]
assert names==['claude-sonnet-4-5','claude-haiku-4-5'], names
labels=[e['labelOverride'] for e in d['inferenceModels']]
assert labels[0]=='FreeAgents/LiteLLM gpt-oss-120b', labels
assert labels[1] in ('FreeAgents/LiteLLM gpt-oss-20b','FreeAgents/LiteLLM gemini-2.0-flash','FreeAgents/LiteLLM deepseek-chat-v3-0324'), labels
" "$MK" 2>/dev/null; then a_ok "Desktop profile valid (catalog ids + FreeAgents/LiteLLM labels)"; else a_bad "Desktop profile JSON invalid"; fi
  if python3 -c "
import json
m=json.load(open('/mnt/c/Users/Test User/AppData/Local/Claude-3p/configLibrary/_meta.json'))
assert any(e.get('id')=='00000000-0000-4000-8000-0000000a119e' and e.get('name')=='Free Agents' for e in m['entries']), m
assert not any(e.get('id')=='litellm-free-ai-agents' for e in m['entries']), m
assert m['appliedId']=='00000000-0000-4000-8000-0000000a110e', m
" 2>/dev/null; then a_ok "_meta: new entry added, legacy purged, applied pick NOT stolen"; else a_bad "_meta.json merge wrong"; fi
  assert_contains "${HOME_DIR}/.litellm/config.yaml" "model_name: claude-sonnet-4-5"
  assert_contains "${HOME_DIR}/.litellm/config.yaml" "model_name: claude-haiku-4-5"
  assert_contains "${HOME_DIR}/.litellm/config.yaml" "model: groq/openai/gpt-oss-120b"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T02 - install with ONLY the Groq key
#===============================================================================
start_test "T02_install_groq_only"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n\n\ngsk_only_groq_0123456789ab\n\n\n\n\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Collected 1 API key(s)"
  assert_models "${HOME_DIR}/.litellm/config.yaml" "$GROQ2_MODELS"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e GROQ_API_KEY=gsk_only_groq_0123456789ab"
  assert_not_contains "${T_WORKSTATE}/docker-calls.log" "OPENROUTER_API_KEY"
  assert_not_contains "${T_WORKSTATE}/docker-calls.log" "GEMINI_API_KEY"
  MK="$(master_key_from)"
  assert_claude_settings "/mnt/c/Users/Test User/.claude/settings.json" "$MK" "claude-gpt-oss-120b" "claude-gpt-oss-20b"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T03 - install with ONLY the Google AI key (default model selection)
#===============================================================================
start_test "T03_install_gemini_only"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n\n\n\n\nAIzaOnlyTest0123456789ab\n\n\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_models "${HOME_DIR}/.litellm/config.yaml" "$GEMINI1_MODELS"
  MK="$(master_key_from)"
  assert_claude_settings "/mnt/c/Users/Test User/.claude/settings.json" "$MK" "claude-gemini-2.0-flash" "claude-gemini-2.0-flash"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T04 - zero keys on first round -> forced retry -> success on second round
#===============================================================================
start_test "T04_no_keys_retry_then_success"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n\n\n\n\n\n\n\n\nsk_or_second_0123456789ab\n\n\n\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "At least ONE API key is required. Let's try again."
  assert_contains "$CURRENT_LOG" "Collected 1 API key(s)"
  assert_models "${HOME_DIR}/.litellm/config.yaml" "$OR2_MODELS"
  MK="$(master_key_from)"
  assert_claude_settings "/mnt/c/Users/Test User/.claude/settings.json" "$MK" "claude-deepseek-v3.1" "claude-deepseek-v3.1"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T05 - zero keys on all 3 attempts -> script must exit non-zero
#===============================================================================
start_test "T05_no_keys_three_attempts_fails"
fresh_env
printf '1\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n' | run_script
T_RC=$?
assert_rc 1
assert_contains "$CURRENT_LOG" "Exiting after 3 attempts"
dump_state
finish_test

#===============================================================================
# T06 - reinstall over an existing container replaces it
#===============================================================================
start_test "T06_reinstall_replaces_container"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n\n\ngsk_first_0123456789abcdef\n\n\n\n\n' | run_script
  # second run: answer 'n' -> replace all keys
  printf '1\n\n\nn\ngsk_second_0123456789abcdef\n\n\n\n\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Existing API keys found (from the previous install)"
  assert_contains "$CURRENT_LOG" "OK - enter the replacement keys below."
  assert_contains "$CURRENT_LOG" "Found existing container 'litellm'. Removing it..."
  assert_contains "${T_WORKSTATE}/docker-calls.log" "rm -f litellm"
  if [ "$(grep -cx 'litellm' "${T_WORKSTATE}/containers.txt")" = "1" ]; then a_ok "exactly one container registered"; else a_bad "container registry not deduplicated"; fi
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e GROQ_API_KEY=gsk_second_0123456789abcdef"
  MK="$(master_key_from)"
  assert_claude_settings "/mnt/c/Users/Test User/.claude/settings.json" "$MK" "claude-gpt-oss-120b" "claude-gpt-oss-20b"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T07 - full uninstall removes container + linux folder + windows config
#===============================================================================
start_test "T07_full_uninstall"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n\n\ngsk_uninstall_0123456789ab\n\n\n\n\n' | run_script
  printf '6\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "UNINSTALL COMPLETED SUCCESSFULLY"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "stop litellm"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "rm litellm"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "rm litellm-db"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "network rm litellm-net"
  if [ ! -s "${T_WORKSTATE}/containers.txt" ]; then a_ok "container registry empty"; else a_bad "container still registered"; fi
  assert_file_missing "${HOME_DIR}/.litellm/config.yaml"
  assert_file_missing "${HOME_DIR}/.litellm/master_key.txt"
  assert_file_missing "${HOME_DIR}/.litellm/dashboard_credentials.txt"
  assert_file_missing "/mnt/c/Users/Test User/.claude/settings.json"
  assert_file_missing "${FAKE_ROOT}/usr/local/bin/freeagents"
  assert_file_missing "${FAKE_ROOT}/usr/local/bin/litellm-boot.sh"
  assert_not_contains "${FAKE_ROOT}/etc/wsl.conf" "litellm-boot.sh"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T08 - uninstall when nothing is installed (idempotent, must not fail)
#===============================================================================
start_test "T08_uninstall_idempotent"
fresh_env
printf '6\n' | run_script
T_RC=$?
assert_rc 0
assert_contains "$CURRENT_LOG" "No container named 'litellm' found"
assert_contains "$CURRENT_LOG" "UNINSTALL COMPLETED SUCCESSFULLY"
dump_state
finish_test

#===============================================================================
# T09 - invalid menu choice exits with code 1
#===============================================================================
start_test "T09_invalid_menu_choice"
fresh_env
printf '9\n0\n' | run_script
T_RC=$?
assert_rc 0
assert_contains "$CURRENT_LOG" "Invalid choice: '9'. Pick 0-8."
assert_contains "$CURRENT_LOG" "Bye!"
dump_state
finish_test

#===============================================================================
# T10 - quit option exits cleanly
#===============================================================================
start_test "T10_menu_quit"
fresh_env
printf 'q\n' | run_script
T_RC=$?
assert_rc 0
assert_contains "$CURRENT_LOG" "Bye!"
dump_state
finish_test

#===============================================================================
# T11 - Windows username containing a space
#===============================================================================
start_test "T11_username_with_space"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n\n\ngsk_spaceuser_0123456789ab\n\n\n\n\n' | \
    env -u DOCKER_PULL_FAIL -u DOCKER_APT_FAIL -u HEALTH_CODE \
      HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" \
      STUBBIN="$STUBBIN" T_WORKSTATE="$T_WORKSTATE" FAKE_ROOT="$FAKE_ROOT" \
      HEALTH_CODE="200" PS_USERNAME="Ali Rezaei" \
      bash "$SCRIPT_FILE" >> "$CURRENT_LOG" 2>&1
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "/mnt/c/Users/Ali Rezaei"
  assert_file_exists "/mnt/c/Users/Ali Rezaei/.claude/settings.json"
  MK="$(master_key_from)"
  assert_claude_settings "/mnt/c/Users/Ali Rezaei/.claude/settings.json" "$MK" "claude-gpt-oss-120b" "claude-gpt-oss-20b"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T12 - existing daemon.json is backed up before being replaced
#===============================================================================
start_test "T12_daemon_json_backup"
if [ "$CAN_MANAGE_DAEMON" -eq 1 ]; then
  fresh_env
  REAL_DAEMON_BACKUP="${T_WORK}/host-daemon.json.orig"
  if [ -f /etc/docker/daemon.json ]; then
    REAL_DAEMON_STATE="was-present"
    cp /etc/docker/daemon.json "$REAL_DAEMON_BACKUP"
  else
    REAL_DAEMON_STATE="seeded-absent"
  fi
  as_root mkdir -p /etc/docker 2>/dev/null || true
  printf '{\n  "user-custom-key": "keep-me"\n}\n' | as_root tee /etc/docker/daemon.json >/dev/null
  # re-mirror the seeded host file into the virtual root (fresh_env ran before seeding)
  mkdir -p "${FAKE_ROOT}/etc/docker"
  cp /etc/docker/daemon.json "${FAKE_ROOT}/etc/docker/daemon.json"
  printf '1\n\n\ngsk_backup_0123456789abcdef\n\n\n\n\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Existing daemon.json backed up"
  bak_count="$(find "${FAKE_ROOT}/etc/docker" -name 'daemon.json.bak.*' 2>/dev/null | wc -l)"
  if [ "${bak_count:-0}" -ge 1 ]; then a_ok "backup file created in virtual /etc/docker"; else a_bad "no daemon.json.bak.* created"; fi
  assert_daemon_json_mirrors "${FAKE_ROOT}/etc/docker/daemon.json"
  dump_state
  # restore host state BEFORE finish_test (which deletes $T_WORK)
  if [ "$REAL_DAEMON_STATE" = "was-present" ]; then
    cp_sudo "$REAL_DAEMON_BACKUP" /etc/docker/daemon.json
  else
    rm_f_sudo /etc/docker/daemon.json
  fi
  REAL_DAEMON_STATE=""
  finish_test
else
  skip_test "requires root/sudo to manage /etc/docker/daemon.json"
fi

#===============================================================================
# T13 - powershell.exe found via /mnt/c fallback (no PATH interop)
#===============================================================================
start_test "T13_powershell_fallback_path"
if [ "$MNT_OK" -eq 1 ] && [ "$CAN_MANAGE_DAEMON" -eq 1 ]; then
  fresh_env
  FALLBACK_BIN="${T_WORK}/bin-without-ps"
  mkdir -p "$FALLBACK_BIN"
  for f in sudo apt-get service systemctl curl docker.installer; do
    cp "$STUBBIN/$f" "$FALLBACK_BIN/${f%.installer}"
  done
  chmod +x "$FALLBACK_BIN"/*
  PS_MNT="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  as_root mkdir -p "/mnt/c/Windows/System32/WindowsPowerShell/v1.0" 2>/dev/null || true
  CREATED_PS=0
  if [ ! -f "$PS_MNT" ]; then
    as_root cp "$STUBBIN/powershell.exe" "$PS_MNT" && as_root chmod 755 "$PS_MNT" && CREATED_PS=1
  fi
  if [ -x "$PS_MNT" ]; then
    printf '1\n\n\ngsk_fallback_0123456789abc\n\n\n\n\n' | \
      env -u DOCKER_PULL_FAIL -u DOCKER_APT_FAIL -u HEALTH_CODE -u PS_USERNAME \
        HOME="$HOME_DIR" PATH="${FALLBACK_BIN}:${PATH}" \
        STUBBIN="$FALLBACK_BIN" T_WORKSTATE="$T_WORKSTATE" FAKE_ROOT="$FAKE_ROOT" \
        HEALTH_CODE="200" \
        bash "$SCRIPT_FILE" >> "$CURRENT_LOG" 2>&1
    T_RC=$?
    assert_rc 0
    assert_contains "$CURRENT_LOG" "/mnt/c/Users/Test User"
    assert_file_exists "/mnt/c/Users/Test User/.claude/settings.json"
    if [ "$CREATED_PS" -eq 1 ]; then rm_f_sudo "$PS_MNT"; fi
  else
    a_bad "could not stage powershell.exe under /mnt/c"
  fi
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c + sudo"
fi

#===============================================================================
# T14 - health check timeout path (server never becomes healthy)
#===============================================================================
start_test "T14_health_check_timeout"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  T_HEALTH_CODE="000"
  T_HEALTH_WAIT_SEC="4"
  printf '1\n\n\ngsk_timeout_0123456789abcd\n\n\n\n\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Health check timed out"
  assert_contains "$CURRENT_LOG" "INSTALLATION COMPLETED SUCCESSFULLY"
  T_HEALTH_CODE=""
  T_HEALTH_WAIT_SEC=""
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T15 - docker pull failure -> script must die with a clear error
#===============================================================================
start_test "T15_pull_failure"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n\n\ngsk_pullfail_0123456789abc\n\n\n\n\n' | \
    env -u DOCKER_APT_FAIL -u HEALTH_CODE -u PS_USERNAME \
      DOCKER_PULL_FAIL="1" LITELLM_PULL_RETRIES="1" \
      HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" \
      STUBBIN="$STUBBIN" T_WORKSTATE="$T_WORKSTATE" FAKE_ROOT="$FAKE_ROOT" \
      HEALTH_CODE="200" \
      bash "$SCRIPT_FILE" >> "$CURRENT_LOG" 2>&1
  T_RC=$?
  assert_rc 1
  assert_contains "$CURRENT_LOG" "Image pull failed"
  assert_file_missing "/mnt/c/Users/Test User/.claude/settings.json"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T16 - docker already installed -> apt-get must be skipped
#===============================================================================
start_test "T16_docker_already_installed"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  cp "$STUBBIN/docker.installer" "${STUBBIN}/docker"
  chmod +x "${STUBBIN}/docker"
  printf '1\n\n\ngsk_predocker_0123456789ab\n\n\n\n\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Docker binary already present, skipping apt installation"
  if [ ! -s "${T_WORKSTATE}/apt-calls.log" ]; then a_ok "apt-get never called"; else a_bad "apt-get was called unexpectedly"; fi
  rm -f "${STUBBIN}/docker"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T17 - CRLF self-heal: a Windows-line-endings copy must still work end-to-end
#===============================================================================
start_test "T17_crlf_self_heal"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  CRLF_COPY="${T_WORK}/LiteLLM.crlf.sh"
  sed 's/$/\r/' "$SCRIPT_FILE" > "$CRLF_COPY"
  printf '1\n\n\ngsk_crlf_0123456789abcdef\n\n\n\n\n' | run_script "$CRLF_COPY"
  T_RC=$?
  assert_rc 0
  assert_not_contains "$CURRENT_LOG" "invalid option name"
  assert_contains "$CURRENT_LOG" "INSTALLATION COMPLETED SUCCESSFULLY"
  MK="$(master_key_from)"
  assert_claude_settings "/mnt/c/Users/Test User/.claude/settings.json" "$MK" "claude-gpt-oss-120b" "claude-gpt-oss-20b"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T18 - systemd branch: litellm.service unit created and enabled
#===============================================================================
start_test "T18_autostart_systemd_unit"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  T_BOOT_MODE="systemd"
  printf '1\n\n\ngsk_systemd_0123456789abc\n\n\n\n\n' | run_script
  T_RC=$?
  T_BOOT_MODE=""
  assert_rc 0
  UNIT="${FAKE_ROOT}/etc/systemd/system/litellm.service"
  assert_file_exists "$UNIT"
  assert_contains "$UNIT" "ExecStart=/usr/local/bin/litellm-boot.sh"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "systemctl enable litellm.service"
  assert_contains "$CURRENT_LOG" "systemd service: litellm.service (enabled)"
  if [ -f "${FAKE_ROOT}/etc/wsl.conf" ]; then
    assert_not_contains "${FAKE_ROOT}/etc/wsl.conf" "litellm-boot.sh"
  fi
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T19 - management CLI: up / down / restart / status / uninstall
#===============================================================================
start_test "T19_management_cli"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n\n\ngsk_cli_0123456789abcdef\n\n\n\n\n' | run_script
  T_RC=$?
  assert_rc 0
  CLI="${FAKE_ROOT}/usr/local/bin/freeagents"
  if [ -x "$CLI" ]; then a_ok "CLI installed and executable"; else a_bad "CLI missing or not executable"; fi
  run_cli() {
    env -u DOCKER_PULL_FAIL -u DOCKER_APT_FAIL -u HEALTH_CODE -u PS_USERNAME \
      HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" \
      STUBBIN="$STUBBIN" T_WORKSTATE="$T_WORKSTATE" FAKE_ROOT="$FAKE_ROOT" \
      HEALTH_CODE="200" PS_USERNAME="Test User" \
      bash "$CLI" "$@" >> "$CURRENT_LOG" 2>&1
  }
  run_cli status
  assert_contains "$CURRENT_LOG" "Container state : running"
  assert_contains "$CURRENT_LOG" "Restart policy  : unless-stopped"
  assert_contains "$CURRENT_LOG" "Admin panel     : http://127.0.0.1:4000/ui"
  run_cli down
  assert_contains "${T_WORKSTATE}/docker-calls.log" "stop litellm"
  if grep -qxF "litellm" "${T_WORKSTATE}/container-running.txt"; then a_bad "container still marked running after down"; else a_ok "running state cleared after down"; fi
  run_cli up
  assert_contains "${T_WORKSTATE}/docker-calls.log" "start litellm"
  run_cli restart
  assert_contains "${T_WORKSTATE}/docker-calls.log" "restart litellm"
  MK="$(master_key_from)"
  run_cli credentials
  assert_contains "$CURRENT_LOG" "Username : admin"
  assert_contains "$CURRENT_LOG" "Password : ${MK}"
  run_cli uninstall --yes
  assert_contains "$CURRENT_LOG" "UNINSTALL COMPLETED."
  assert_contains "$CURRENT_LOG" "Removed the legacy Claude Desktop registry policy"
  if [ ! -s "${T_WORKSTATE}/containers.txt" ]; then a_ok "container registry empty after CLI uninstall"; else a_bad "container still registered after CLI uninstall"; fi
  assert_file_missing "${HOME_DIR}/.litellm/config.yaml"
  assert_file_missing "/mnt/c/Users/Test User/.claude/settings.json"
  assert_file_missing "$CLI"
  assert_file_missing "${FAKE_ROOT}/usr/local/bin/litellm-boot.sh"
  assert_not_contains "${FAKE_ROOT}/etc/wsl.conf" "litellm-boot.sh"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T20 - wsl.conf boot-command branch (forced via LITELLM_BOOT_MODE=wslconf)
#===============================================================================
start_test "T20_autostart_wslconf_boot"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  T_BOOT_MODE="wslconf"
  printf '1\n\n\ngsk_wslconf_0123456789abc\n\n\n\n\n' | run_script
  T_RC=$?
  T_BOOT_MODE=""
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Boot command added to /etc/wsl.conf"
  assert_contains "${FAKE_ROOT}/etc/wsl.conf" "command = /usr/local/bin/litellm-boot.sh"
  assert_file_missing "${FAKE_ROOT}/etc/systemd/system/litellm.service"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T21 - pull fails but a local image exists -> continue with the local copy
#===============================================================================
start_test "T21_pull_failure_with_local_image"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  echo "ghcr.io/berriai/litellm:main-latest" > "${T_WORKSTATE}/images.txt"
  printf '1\n\n\ngsk_localimg_0123456789abc\n\n\n\n\n' | \
    env -u DOCKER_APT_FAIL -u HEALTH_CODE -u PS_USERNAME \
      DOCKER_PULL_FAIL="1" LITELLM_PULL_RETRIES="1" \
      HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" \
      STUBBIN="$STUBBIN" T_WORKSTATE="$T_WORKSTATE" FAKE_ROOT="$FAKE_ROOT" \
      HEALTH_CODE="200" \
      bash "$SCRIPT_FILE" >> "$CURRENT_LOG" 2>&1
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Image already exists locally"
  assert_contains "$CURRENT_LOG" "continuing with the local copy"
  assert_contains "$CURRENT_LOG" "INSTALLATION COMPLETED SUCCESSFULLY"
  assert_file_exists "/mnt/c/Users/Test User/.claude/settings.json"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T22 - ghcr fallback mirror is used when the direct pull fails
#===============================================================================
start_test "T22_ghcr_mirror_fallback"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n\n\ngsk_mirror_0123456789abcd\n\n\n\n\n' | \
    env -u DOCKER_APT_FAIL -u HEALTH_CODE -u PS_USERNAME \
      DOCKER_PULL_FAIL_MATCH="ghcr.io" LITELLM_PULL_RETRIES="1" \
      LITELLM_GHCR_MIRROR="ghcr.nju.edu.cn/" \
      HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" \
      STUBBIN="$STUBBIN" T_WORKSTATE="$T_WORKSTATE" FAKE_ROOT="$FAKE_ROOT" \
      HEALTH_CODE="200" \
      bash "$SCRIPT_FILE" >> "$CURRENT_LOG" 2>&1
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Trying the ghcr fallback mirror"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "pull ghcr.nju.edu.cn/berriai/litellm:main-latest"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "tag ghcr.nju.edu.cn/berriai/litellm:main-latest ghcr.io/berriai/litellm:main-latest"
  assert_contains "$CURRENT_LOG" "INSTALLATION COMPLETED SUCCESSFULLY"
  MK="$(master_key_from)"
  assert_claude_settings "/mnt/c/Users/Test User/.claude/settings.json" "$MK" "claude-gpt-oss-120b" "claude-gpt-oss-20b"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T23 - reinstall keeps existing keys by default (Enter = keep)
#===============================================================================
start_test "T23_reinstall_keeps_existing_keys"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n\n\ngsk_keepme_0123456789abc\n\n\n\n\n' | run_script
  # second run: only the menu answer -> default keeps existing keys
  printf '1\n\n\n\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Database container 'litellm-db' already present."
  assert_contains "$CURRENT_LOG" "Existing API keys found (from the previous install)"
  assert_contains "$CURRENT_LOG" "Groq       : gsk_****9abc"
  assert_contains "$CURRENT_LOG" "Keeping the existing 1 API key(s)."
  assert_not_contains "$CURRENT_LOG" "Groq API key"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "-e GROQ_API_KEY=gsk_keepme_0123456789abc"
  MK1="$(grep -o 'LITELLM_MASTER_KEY=[^ ]*' "${T_WORKSTATE}/docker-calls.log" | head -1 | cut -d= -f2)"
  MK2="$(grep -o 'LITELLM_MASTER_KEY=[^ ]*' "${T_WORKSTATE}/docker-calls.log" | tail -1 | cut -d= -f2)"
  if [ -n "$MK1" ] && [ "$MK1" = "$MK2" ]; then a_ok "master key stable across reinstall"; else a_bad "master key changed on reinstall"; fi
  MK="$(master_key_from)"
  assert_claude_settings "/mnt/c/Users/Test User/.claude/settings.json" "$MK" "claude-gpt-oss-120b" "claude-gpt-oss-20b"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T24 - LITELLM_UI_DB=0: no database stack, config without database_url
#===============================================================================
start_test "T24_ui_db_disabled"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  T_UI_DB="0"
  printf '1\n\n\ngsk_nodb_0123456789abcd\n\n\n\n\n' | run_script
  T_RC=$?
  T_UI_DB=""
  assert_rc 0
  assert_not_contains "${T_WORKSTATE}/docker-calls.log" "litellm-db"
  assert_not_contains "${T_WORKSTATE}/docker-calls.log" "DATABASE_URL"
  assert_not_contains "${HOME_DIR}/.litellm/config.yaml" "database_url"
  assert_not_contains "${T_WORKSTATE}/docker-calls.log" "--network litellm-net"
  assert_contains "$CURRENT_LOG" "Admin UI database               : disabled"
  assert_file_exists "/mnt/c/Users/Test User/.claude/settings.json"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T26 - live key verification: rejected keys are flagged and re-entry offered
#===============================================================================
start_test "T26_key_verification_rejects_bad_keys"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  T_KEYCHECK_CODE="403"
  printf '1\n\n\ngsk_prefix_ok_but_rejected\n\n\n\n\nn\n' | run_script
  T_RC=$?
  T_KEYCHECK_CODE=""
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Verifying API keys against the providers"
  assert_contains "$CURRENT_LOG" "Groq: REJECTED (HTTP 403)"
  assert_contains "$CURRENT_LOG" "Re-enter the rejected keys now?"
  assert_contains "$CURRENT_LOG" "INSTALLATION COMPLETED SUCCESSFULLY"
  # all-valid default flow must NOT show the re-entry prompt
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T27 - verification passes by default (no re-entry prompt on normal flows)
#===============================================================================
start_test "T27_key_verification_all_valid"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n\n\ngsk_valid_flow_0123456789\n\n\n\n\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Groq: valid (HTTP 200)"
  assert_not_contains "$CURRENT_LOG" "Re-enter the rejected keys now?"
  assert_not_contains "$CURRENT_LOG" "REJECTED"
  assert_contains "$CURRENT_LOG" "INSTALLATION COMPLETED SUCCESSFULLY"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T28 - litellm doctor: stack + provider + live per-model test output
#===============================================================================
start_test "T28_doctor_command"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n\n\ngsk_doctor_0123456789abcd\n\n\n\n\n' | run_script
  CLI="${FAKE_ROOT}/usr/local/bin/freeagents"
  if [ -x "$CLI" ]; then
    env -u DOCKER_PULL_FAIL -u DOCKER_APT_FAIL -u HEALTH_CODE -u PS_USERNAME \
      HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" \
      STUBBIN="$STUBBIN" T_WORKSTATE="$T_WORKSTATE" FAKE_ROOT="$FAKE_ROOT" \
      HEALTH_CODE="200" KEYCHECK_CODE="200" PS_USERNAME="Test User" \
      bash "$CLI" doctor >> "$CURRENT_LOG" 2>&1
    T_RC=$?
    assert_rc 0
    assert_contains "$CURRENT_LOG" "[STACK]"
    assert_contains "$CURRENT_LOG" "[PROVIDER CONNECTIVITY + KEYS]"
    assert_contains "$CURRENT_LOG" "Groq: reachable, key valid (HTTP 200)"
    assert_contains "$CURRENT_LOG" "OpenRouter: no key configured"
    assert_contains "$CURRENT_LOG" "[MODEL LIVE TESTS]"
    assert_contains "$CURRENT_LOG" "OK   claude-gpt-oss-120b"
    assert_contains "$CURRENT_LOG" "OK   claude-gpt-oss-20b"
    assert_contains "$CURRENT_LOG" "ALL 2 MODEL TESTS PASSED"
  else
    a_bad "CLI missing for doctor test"
  fi
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T29 - Windows proxy: enabled with default address, kept on reinstall
#===============================================================================
start_test "T29_windows_proxy_enabled"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  GW="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
  printf '1\n\ny\n\ngsk_winproxy_0123456789\n\n\n\n\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Route provider traffic through your Windows proxy?"
  assert_contains "$CURRENT_LOG" "Proxy reachable - test call through it returned HTTP 200"
  assert_contains "$CURRENT_LOG" "Windows proxy enabled: http://${GW}:7890"
  assert_file_exists "${HOME_DIR}/.litellm/windows_proxy.txt"
  assert_contains "${HOME_DIR}/.litellm/windows_proxy.txt" "http://${GW}:7890"
  assert_contains "$CURRENT_LOG" "Windows proxy routing           : http://${GW}:7890"
  # container env carries the proxy (and NO_PROXY keeps local traffic direct)
  assert_contains "$T_WORKSTATE/docker-calls.log" "-e HTTP_PROXY=http://${GW}:7890"
  assert_contains "$T_WORKSTATE/docker-calls.log" "-e HTTPS_PROXY=http://${GW}:7890"
  assert_contains "$T_WORKSTATE/docker-calls.log" "-e NO_PROXY=localhost,127.0.0.1,litellm-db"
  # reinstall (keep keys + keep proxy): proxy must survive
  printf '1\n\n\n\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Windows proxy kept: http://${GW}:7890"
  assert_contains "$T_WORKSTATE/docker-calls.log" "-e HTTP_PROXY=http://${GW}:7890"
  assert_file_exists "/mnt/c/Users/Test User/.claude/settings.json"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T30 - Windows proxy: replace flow, default-off, and file persistence
#===============================================================================
start_test "T30_windows_proxy_replace_and_off"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  mkdir -p "${HOME_DIR}/.litellm"
  printf 'http://10.10.10.10:7890\n' > "${HOME_DIR}/.litellm/windows_proxy.txt"
  # install: previous proxy setting found -> kept by default
  printf '1\n\n\ngsk_t30_first_012345678\n\n\n\n\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Windows proxy kept: http://10.10.10.10:7890"
  assert_contains "$T_WORKSTATE/docker-calls.log" "-e HTTP_PROXY=http://10.10.10.10:7890"
  # reinstall: answer 'n' -> enter a NEW address (accepted by the stub test call)
  printf '1\n\nn\n127.0.0.1:9999\n\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Windows proxy enabled: http://127.0.0.1:9999"
  assert_contains "${HOME_DIR}/.litellm/windows_proxy.txt" "http://127.0.0.1:9999"
  assert_contains "$T_WORKSTATE/docker-calls.log" "-e HTTP_PROXY=http://127.0.0.1:9999"
  # a fresh install that answers the proxy prompt with ENTER stays direct
  fresh_env
  printf '1\n\n\ngsk_t30_off_0123456789a\n\n\n\n\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Windows proxy: disabled (direct connections)"
  assert_file_missing "${HOME_DIR}/.litellm/windows_proxy.txt"
  if grep -q "HTTP_PROXY" "$T_WORKSTATE/docker-calls.log"; then
    a_bad "proxy env vars present but proxy was disabled"
  else
    a_ok "no proxy env vars when disabled"
  fi
  # failing proxy test call with a 127.x address -> dedicated hint, not saved
  fresh_env
  T_PROXY_CALL_CODE="000"
  printf '1\n\ny\n127.0.0.1:10808\nn\ngsk_failpath_012345678\n\n\n\n\n' | run_script
  T_RC=$?
  T_PROXY_CALL_CODE=""
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Test call through the proxy FAILED (code 000)"
  assert_contains "$CURRENT_LOG" "127.0.0.1 inside WSL is the WSL VM itself, NOT Windows"
  assert_contains "$CURRENT_LOG" "Save it anyway?"
  assert_contains "$CURRENT_LOG" "Windows proxy: disabled"
  assert_file_missing "${HOME_DIR}/.litellm/windows_proxy.txt"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T31 - Claude Desktop app: auto policy by default, LITELLM_DESKTOP_CONFIG=0 skip
#===============================================================================
start_test "T31_desktop_policy_auto_config"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n\n\ngsk_desktop_0123456789ab\n\n\n\n\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Desktop profile written (configLibrary)"
  assert_contains "$CURRENT_LOG" "ALREADY CONFIGURED automatically"
  assert_file_exists "/mnt/c/Users/Test User/AppData/Local/Claude-3p/configLibrary/00000000-0000-4000-8000-0000000a119e.json"
  grep -q "LocalApplicationData" "$T_WORKSTATE/powershell-calls.log" 2>/dev/null \
    && a_ok "LOCALAPPDATA detection intact" || a_bad "LocalApplicationData never queried"
  # disabled via knob: no registry writes at all
  : > "${T_WORKSTATE}/powershell-calls.log"
  fresh_env
  printf '1\n\n\ngsk_desktop_off_01234567\n\n\n\n\n' | \
  env -u DOCKER_PULL_FAIL -u DOCKER_APT_FAIL \
    HOME="$HOME_DIR" PATH="${STUBBIN}:${PATH}" \
    STUBBIN="$STUBBIN" T_WORKSTATE="$T_WORKSTATE" FAKE_ROOT="$FAKE_ROOT" \
    HEALTH_CODE="200" KEYCHECK_CODE="200" PS_USERNAME="Test User" \
    LITELLM_DESKTOP_CONFIG="0" \
    LITELLM_BOOT_MODE="${T_BOOT_MODE:-auto}" LITELLM_PULL_RETRIES="3" \
    LITELLM_UI_DB="1" \
    bash "$SCRIPT_FILE" >> "$CURRENT_LOG" 2>&1
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Claude Desktop auto-config disabled"
  assert_contains "$CURRENT_LOG" "NOT auto-configured (LITELLM_DESKTOP_CONFIG=0)"
  if grep -q "New-ItemProperty" "$T_WORKSTATE/powershell-calls.log" 2>/dev/null; then
    a_bad "registry write happened despite LITELLM_DESKTOP_CONFIG=0"
  else
    a_ok "no registry writes when disabled"
  fi
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T32 - unified menu: banner, config manager navigation, update-cancel, exit
#===============================================================================
start_test "T32_menu_and_config_manager"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '8\n0\n4\nn\n0\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Free AI Agents"
  assert_contains "$CURRENT_LOG" "BOT Version [ 3.0.0 ]"
  assert_contains "$CURRENT_LOG" "Config Manager"
  assert_contains "$CURRENT_LOG" "CONFIG MANAGER"
  assert_contains "$CURRENT_LOG" "Gateway proxy ON"
  assert_contains "$CURRENT_LOG" "Re-enter provider tokens (applied to BOTH engines)"
  assert_contains "$CURRENT_LOG" "Re-apply Claude configs"
  assert_contains "$CURRENT_LOG" "Switch the ACTIVE desktop profile"
  assert_contains "$CURRENT_LOG" "Update cancelled."
  assert_contains "$CURRENT_LOG" "Bye!"
  fresh_env
  printf 'x\n0\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Invalid choice: 'x'. Pick 0-8."
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T33 - Both engines: tokens & proxy asked ONCE, shared with the second engine
#===============================================================================
start_test "T33_both_engines_single_prompt"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  # fake secondary installer: records args + provider/proxy env for assertions
  cat > "${T_WORKSTATE}/fake-omni.sh" <<'FAKEOMNI'
#!/usr/bin/env bash
echo "fake-omni-stdout $*"
echo "fake-omni $*" >> "${T_WORKSTATE}/omni-calls.log"
env | grep -E '^OMNIRoute_(GROQ|OPENROUTER|GEMINI|CEREBRAS|MISTRAL)_KEY=' | sort >> "${T_WORKSTATE}/omni-env.log"
env | grep -E '^OMNIRoute_(USE_PROXY|PROXY_URL|FORCE_NO_TTY)=' | sort >> "${T_WORKSTATE}/omni-env.log"
exit 0
FAKEOMNI
  T_FAKE_OMNI="${T_WORKSTATE}/fake-omni.sh"
  # menu 1 -> engine 3 (both) -> proxy ENTER (off) -> groq key + 4 skips
  printf '1\n3\n\ngsk_both_0123456789abcd\n\n\n\n\n\n' | run_script
  T_RC=$?
  T_FAKE_OMNI=""
  assert_rc 0
  assert_contains "$CURRENT_LOG" "INSTALLATION COMPLETED SUCCESSFULLY"
  assert_contains "$CURRENT_LOG" "SECONDARY GATEWAY REPORT"
  assert_contains "$CURRENT_LOG" "Provider tokens handed over"
  assert_contains "$CURRENT_LOG" "SECONDARY ENGINE: installing with the SAME keys & proxy"
  # exactly ONE keys-setup block for the whole run
  keys_blocks="$(grep -c "API keys setup" "$CURRENT_LOG" || true)"
  if [ "$keys_blocks" -eq 1 ]; then a_ok "keys asked exactly ONCE"; else a_bad "keys asked ${keys_blocks} time(s)"; fi
  # the same groq token reached the second engine via env + seeded file
  assert_contains "${T_WORKSTATE}/omni-env.log" "OMNIRoute_GROQ_KEY=gsk_both_0123456789abcd"
  assert_contains "${T_WORKSTATE}/omni-env.log" "OMNIRoute_USE_PROXY=0"
  assert_contains "${T_WORKSTATE}/omni-env.log" "OMNIRoute_FORCE_NO_TTY=1"
  assert_contains "$CURRENT_LOG" "Watch live progress in a second terminal"
  grep -q "GROQ_KEY=gsk_both_0123456789abcd" "${HOME_DIR}/omniroute-keys.env" \
    && a_ok "secondary keys file seeded with the SAME token" || a_bad "secondary keys file missing token"
  assert_contains "${T_WORKSTATE}/omni-calls.log" "fake-omni --install"
  assert_file_exists "${HOME_DIR}/.free-ai-agents/setup.sh"
  # --- menu operations with the secondary installed: SILENT delegation ---
  printf '2\n5\n3\n0\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "Primary gateway is up"
  assert_contains "$CURRENT_LOG" "Secondary gateway: restart - done"
  assert_contains "$CURRENT_LOG" "Secondary gateway: stop - done"
  assert_contains "$CURRENT_LOG" "status    : responding (HTTP 200)"
  assert_not_contains "$CURRENT_LOG" "fake-omni-stdout"
  assert_contains "${T_WORKSTATE}/omni-calls.log" "fake-omni --restart"
  assert_contains "${T_WORKSTATE}/omni-calls.log" "fake-omni --down"
  grep -q "fake-omni --status" "${T_WORKSTATE}/omni-calls.log" \
    && a_bad "status must be a local probe (no delegation)" || a_ok "status is a local probe (no delegation)"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# T34 - menu operations: Start/Restart, Status, Stop use the internal engine
#===============================================================================
start_test "T34_menu_operations"
if [ "$MNT_OK" -eq 1 ]; then
  fresh_env
  printf '1\n\n\ngsk_menuops_012345678\n\n\n\n\n' | run_script
  # menu 2 (start/restart) -> 5 (status) -> 3 (stop) -> 0 (exit)
  printf '2\n5\n3\n0\n' | run_script
  T_RC=$?
  assert_rc 0
  assert_contains "$CURRENT_LOG" "=== START / RESTART ==="
  assert_contains "$CURRENT_LOG" "Primary gateway is up"
  assert_contains "$CURRENT_LOG" "=== PRIMARY GATEWAY (port 4000) ==="
  assert_contains "$CURRENT_LOG" "=== SECONDARY GATEWAY (port 20128) ==="
  assert_contains "$CURRENT_LOG" "not installed"
  assert_contains "$CURRENT_LOG" "=== STOP ==="
  assert_contains "$CURRENT_LOG" "Primary gateway stopped."
  assert_contains "${T_WORKSTATE}/docker-calls.log" "restart litellm"
  assert_contains "${T_WORKSTATE}/docker-calls.log" "stop litellm"
  if grep -q "command not found" "$CURRENT_LOG"; then
    a_bad "menu produced 'command not found'"
  else
    a_ok "no 'command not found' anywhere in menu operations"
  fi
  # installed CLI is the unified freeagents command
  assert_file_exists "${FAKE_ROOT}/usr/local/bin/freeagents"
  grep -q "run_secondary" "${FAKE_ROOT}/usr/local/bin/freeagents" \
    && a_ok "freeagents CLI manages both gateways" || a_bad "freeagents CLI misses secondary handling"
  grep -q 'MANAGER_COPY' "${FAKE_ROOT}/usr/local/bin/freeagents" \
    && a_ok "bare freeagents re-opens the manager menu" || a_bad "bare freeagents has no menu re-open"
  dump_state
  finish_test
else
  skip_test "requires writable /mnt/c"
fi

#===============================================================================
# Summary
#===============================================================================
echo >> "$SUMMARY_FILE"
echo "TOTAL: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped" >> "$SUMMARY_FILE"

echo
msg "==============================================================="
msg "RESULTS: ${PASS} passed / ${FAIL} failed / ${SKIP} skipped"
msg "logs:    ${RESULTS_DIR}/"
msg "summary: ${SUMMARY_FILE}"
msg "==============================================================="

[ "$FAIL" -eq 0 ]
