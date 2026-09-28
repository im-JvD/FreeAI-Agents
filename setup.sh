#!/usr/bin/env bash
#===============================================================================
#
#   Free AI Agents  |  LiteLLM <-> Claude Code Bridge  |  WSL2 Ubuntu Setup Script
#
#   Installs and configures a local LiteLLM proxy inside WSL2 Ubuntu
#   and wires Claude Code (on the Windows side) to it through the
#   Anthropic Messages API at http://127.0.0.1:4000/v1/messages
#
#   Features:
#     - Interactive menu: Full Install / Full Uninstall
#     - Docker installed from Ubuntu apt repo (docker.io), Iran-friendly
#     - Iranian Docker Hub mirrors for sanctioned networks (403 fix)
#     - Prebuilt image only: ghcr.io/berriai/litellm:main-latest (NO docker build)
#     - Auto-generated config.yaml from the API keys you provide
#     - Auto-generated Claude Code settings.json (env block) on Windows
#     - Claude DESKTOP app auto-configured via HKCU policy (Cowork gateway)
#
#   Usage (run WITHOUT sudo - the script escalates where needed):
#     bash setup.sh
#
#===============================================================================
#-----------------------------------------------------------------------------
# CRLF self-heal: if this file was saved with Windows line endings (CRLF),
# bash fails with "set: pipefail: invalid option name".
# The guard below is a deliberate SINGLE-line simple command (CRLF-safe):
# it detects CR bytes in this file and re-executes a stripped copy through
# process substitution. See docs/troubleshooting.md for the manual fix.
#-----------------------------------------------------------------------------
[ -f "$0" ] && grep -q $'\r' "$0" && exec bash <(tr -d '\r' < "$0") "$@"

set -euo pipefail

#-------------------------------------------------------------------------------
# Constants
#-------------------------------------------------------------------------------
CONTAINER_NAME="litellm"
# Overridable via env: LITELLM_IMAGE=<registry>/berriai/litellm:main-latest
LITELLM_IMAGE="${LITELLM_IMAGE:-ghcr.io/berriai/litellm:main-latest}"
LITELLM_PORT="4000"
LITELLM_DIR="${HOME}/.litellm"
LITELLM_CONFIG="${LITELLM_DIR}/config.yaml"
LITELLM_KEYFILE="${LITELLM_DIR}/master_key.txt"
LITELLM_CRED_FILE="${LITELLM_DIR}/dashboard_credentials.txt"
DAEMON_JSON="/etc/docker/daemon.json"
CLI_BIN="/usr/local/bin/freeagents"
BOOT_HELPER="/usr/local/bin/litellm-boot.sh"
SYSTEMD_UNIT="/etc/systemd/system/litellm.service"
WSL_CONF="/etc/wsl.conf"
BOOT_LINE="command = /usr/local/bin/litellm-boot.sh"
AUTOSTART_MODE=""
# Admin UI login requires a Postgres DB in recent LiteLLM versions.
# Disable with LITELLM_UI_DB=0 (the proxy itself keeps working without it).
UI_DB_ENABLED="${LITELLM_UI_DB:-1}"
DB_CONTAINER="litellm-db"
DB_NETWORK="litellm-net"
DB_IMAGE="${LITELLM_DB_IMAGE:-postgres:16-alpine}"
DB_USER="litellm"
DB_NAME="litellm"
DB_PASSWORD_FILE="${LITELLM_DIR}/db_password.txt"
# Optional Windows-side proxy (Clash / v2rayN / Hiddify / ...): when set,
# ALL provider traffic from the LiteLLM container is routed through it.
WIN_PROXY_FILE="${LITELLM_DIR}/windows_proxy.txt"
DESKTOP_POLICY_STATUS=""   # off | nops | ok | failed

# Unified manager: Free AI Agents (LiteLLM + OmniRoute engines)
FREE_AGENTS_VERSION="3.0.0"
FREE_AGENTS_DIR="${HOME}/.free-ai-agents"
OMNI_SCRIPT="${FREE_AGENTS_DIR}/OmniRoute.sh"
OMNI_RAW_URLS=(
  "https://raw.githubusercontent.com/im-JvD/OmniRoute-OpenCode/arena/01a0d9b5-omniroute-opencode/OmniRoute.sh"
  "https://cdn.jsdelivr.net/gh/im-JvD/OmniRoute-OpenCode@arena/01a0d9b5-omniroute-opencode/OmniRoute.sh"
)
SELF_RAW_URLS=(
  "https://raw.githubusercontent.com/im-JvD/FreeAI-Agents/main/setup.sh"
  "https://cdn.jsdelivr.net/gh/im-JvD/FreeAI-Agents@main/setup.sh"
  "https://raw.githubusercontent.com/im-JvD/FreeAI-Agents/arena/01a0d869-litellm-opencode/setup.sh"
)
# Claude Desktop 3P profile (configLibrary) id - MUST be a UUID (the app
# rejects non-UUID ids when listing saved configurations)
DESKTOP_PROFILE_ID="00000000-0000-4000-8000-0000000a119e"
MANAGER_COPY="${FREE_AGENTS_DIR}/setup.sh"
SECONDARY_KEYS_FILE="${HOME}/omniroute-keys.env"
WIN_PROXY_URL=""
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Iranian Docker Hub mirrors (403 / rate-limit workaround)
REGISTRY_MIRRORS=(
  "https://docker.arvancloud.ir"
  "https://docker.hub.iran.liara.run"
  "https://docker.iranserver.com"
)

#-------------------------------------------------------------------------------
# UI helpers (plain ASCII so Windows terminals render them correctly)
#-------------------------------------------------------------------------------
if [ -t 1 ]; then
  C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_RED='\033[0;31m'
  C_CYAN='\033[0;36m'; C_BLUE='\033[0;34m'; C_BOLD='\033[1m'; C_NC='\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_BLUE=''; C_BOLD=''; C_NC=''
fi

log_info()  { echo -e "${C_CYAN}[INFO]${C_NC} $*"; }
log_ok()    { echo -e "${C_GREEN}[ OK ]${C_NC} $*"; }
log_warn()  { echo -e "${C_YELLOW}[WARN]${C_NC} $*"; }
log_error() { echo -e "${C_RED}[FAIL]${C_NC} $*" >&2; }
die()       { log_error "$*"; exit 1; }

trap 'echo; log_warn "Interrupted by user. Exiting."; exit 130' INT TERM

#-------------------------------------------------------------------------------
# Pre-flight checks
#-------------------------------------------------------------------------------
SUDO=""
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
  log_warn "Running as root. Config will be created under /root/.litellm"
else
  if ! command -v sudo >/dev/null 2>&1; then
    die "'sudo' is not installed and you are not root. Install sudo first:  apt-get install -y sudo"
  fi
  SUDO="sudo"
  # Silent if passwordless; otherwise prompts once for the password.
  $SUDO -n true 2>/dev/null || $SUDO true 2>/dev/null || \
    die "Sudo authentication failed. Please configure sudo for this user."
fi

check_wsl_environment() {
  log_info "[1/9] Checking WSL2 environment..."
  if ! grep -qi "microsoft" /proc/version 2>/dev/null; then
    log_warn "This does not look like a WSL kernel (/proc/version)."
    log_warn "Continuing anyway - Windows/PowerShell integration may fail."
  fi
  find_powershell >/dev/null || \
    die "powershell.exe was not found. Enable WSL interop (append Windows PATH) and try again."
  log_ok "WSL2 environment looks good."
}

# Locate powershell.exe (works even if Windows PATH interop is disabled)
find_powershell() {
  if command -v powershell.exe >/dev/null 2>&1; then
    command -v powershell.exe
    return 0
  fi
  for p in /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe \
           /mnt/*/Windows/System32/WindowsPowerShell/v1.0/powershell.exe; do
    if [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  return 1
}

# Get the real Windows user profile path (safe with spaces in the username)
# and convert it to its WSL mount point, e.g.:
#   C:\Users\John Doe  ->  /mnt/c/Users/John Doe
get_windows_home() {
  local ps raw drive letter rest
  ps="$(find_powershell)" || return 1
  raw="$($ps -NoProfile -Command "[Environment]::GetFolderPath('UserProfile')" 2>/dev/null | tr -d '\r')"
  [ -n "$raw" ] || return 1

  drive="${raw%%:*}"
  letter="$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')"
  rest="${raw#*:}"
  rest="${rest//\\//}"          # backslashes -> forward slashes

  printf '/mnt/%s%s' "$letter" "$rest"
}

# Convert a WSL-side Windows path back to its Windows form:
#   /mnt/c/Users/John Doe/.claude/x.reg  ->  C:\Users\John Doe\.claude\x.reg
wsl_to_win_path() {
  local p="${1#/mnt/}"
  local drive="${p%%/*}"
  local rest="${p#*/}"
  printf '%s:\\%s' "$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')" "$(printf '%s' "$rest" | tr '/' '\\')"
}

#-------------------------------------------------------------------------------
# Docker installation (apt repo, NOT get.docker.com) + Iranian mirrors
#-------------------------------------------------------------------------------
install_docker() {
  log_info "[2/9] Installing Docker Engine (docker.io from Ubuntu apt repository)..."
  if ! command -v docker >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    $SUDO apt-get update -y
    $SUDO apt-get install -y docker.io
  else
    log_ok "Docker binary already present, skipping apt installation."
  fi
}

configure_docker_mirrors() {
  log_info "[3/9] Configuring Iranian Docker Hub mirrors (${DAEMON_JSON})..."
  $SUDO mkdir -p /etc/docker

  if [ -f "$DAEMON_JSON" ]; then
    local backup="${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
    $SUDO cp "$DAEMON_JSON" "$backup"
    log_warn "Existing daemon.json backed up to: ${backup}"
  fi

  local mirrors_json=""
  for m in "${REGISTRY_MIRRORS[@]}"; do
    [ -n "$mirrors_json" ] && mirrors_json+=",\n    "
    mirrors_json+="\"${m}\""
  done

  printf '{\n  "registry-mirrors": [\n    %b\n  ]\n}\n' "$mirrors_json" \
    | $SUDO tee "$DAEMON_JSON" >/dev/null

  log_ok "Registry mirrors written:"
  for m in "${REGISTRY_MIRRORS[@]}"; do echo "       - ${m}"; done
}

start_docker_daemon() {
  log_info "       Starting/restarting the Docker daemon..."
  $SUDO service docker restart >/dev/null 2>&1 || $SUDO service docker start >/dev/null 2>&1 || true

  # Enable auto-start on boot when systemd is available (WSL2 with systemd=true)
  if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable docker.service >/dev/null 2>&1 || true
  fi

  local i
  for i in $(seq 1 20); do
    if $SUDO docker info >/dev/null 2>&1; then
      log_ok "Docker daemon is up and running."
      return 0
    fi
    sleep 1
  done
  die "Docker daemon did not start. Try manually:  sudo service docker start"
}

#-------------------------------------------------------------------------------
# API keys
#-------------------------------------------------------------------------------
mask_key() {
  local k="$1"
  if [ -z "$k" ]; then echo "<skipped>"; return; fi
  if [ "${#k}" -ge 12 ]; then
    echo "${k:0:4}****${k: -4}"
  else
    echo "****"
  fi
}

# Read the provider API keys stored in an existing container (previous install).
# Sets EXISTING_* variables; returns 0 when at least one key was found.
read_existing_keys_from_container() {
  EXISTING_GROQ=""; EXISTING_OPENROUTER=""; EXISTING_GEMINI=""
  EXISTING_CEREBRAS=""; EXISTING_MISTRAL=""
  command -v docker >/dev/null 2>&1 || return 1
  local envs
  envs="$($SUDO docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  [ -n "$envs" ] || return 1
  EXISTING_GROQ="$(printf '%s\n' "$envs" | sed -n 's/^GROQ_API_KEY=//p' | head -1)"
  EXISTING_OPENROUTER="$(printf '%s\n' "$envs" | sed -n 's/^OPENROUTER_API_KEY=//p' | head -1)"
  EXISTING_GEMINI="$(printf '%s\n' "$envs" | sed -n 's/^GEMINI_API_KEY=//p' | head -1)"
  EXISTING_CEREBRAS="$(printf '%s\n' "$envs" | sed -n 's/^CEREBRAS_API_KEY=//p' | head -1)"
  EXISTING_MISTRAL="$(printf '%s\n' "$envs" | sed -n 's/^MISTRAL_API_KEY=//p' | head -1)"
  [ -n "$EXISTING_GROQ" ] || [ -n "$EXISTING_OPENROUTER" ] || \
    [ -n "$EXISTING_GEMINI" ] || [ -n "$EXISTING_CEREBRAS" ] || [ -n "$EXISTING_MISTRAL" ]
}

# Warn when a pasted value does not match the provider's known key prefix
# (catches keys pasted into the wrong prompt, e.g. Groq key into OpenRouter).
warn_key_prefix() {
  local val="$1" prefix="$2" name="$3"
  [ -n "$val" ] || return 0
  case "$val" in
    "$prefix"*) return 0 ;;
    *)
      log_warn "       NOTE: this value does not look like a ${name} key (expected prefix '${prefix}') - double-check it."
      ;;
  esac
}

ask_all_keys() {
  # Prompt for all five provider keys; at least one is mandatory.
  local attempts=0
  while true; do
    attempts=$((attempts + 1))
    read -r -p "       [1/5] Groq API key        (gsk_...): " GROQ_KEY || true
    read -r -p "       [2/5] OpenRouter API key (sk-or-...): " OPENROUTER_KEY || true
    read -r -p "       [3/5] Google AI key      (AIza...): " GEMINI_KEY || true
    read -r -p "       [4/5] Cerebras API key   (csk-...): " CEREBRAS_KEY || true
    read -r -p "       [5/5] Mistral API key    (sk-...) : " MISTRAL_KEY || true

    # Strip any accidental whitespace
    GROQ_KEY="${GROQ_KEY//[[:space:]]/}"
    OPENROUTER_KEY="${OPENROUTER_KEY//[[:space:]]/}"
    GEMINI_KEY="${GEMINI_KEY//[[:space:]]/}"
    CEREBRAS_KEY="${CEREBRAS_KEY//[[:space:]]/}"
    MISTRAL_KEY="${MISTRAL_KEY//[[:space:]]/}"

    warn_key_prefix "$GROQ_KEY"       "gsk_"   "Groq"
    warn_key_prefix "$OPENROUTER_KEY" "sk-or-" "OpenRouter"
    warn_key_prefix "$GEMINI_KEY"     "AIza"   "Google AI"
    warn_key_prefix "$CEREBRAS_KEY"   "csk-"   "Cerebras"

    KEY_COUNT=0
    [ -n "$GROQ_KEY" ]       && KEY_COUNT=$((KEY_COUNT + 1)) || true
    [ -n "$OPENROUTER_KEY" ] && KEY_COUNT=$((KEY_COUNT + 1)) || true
    [ -n "$GEMINI_KEY" ]     && KEY_COUNT=$((KEY_COUNT + 1)) || true
    [ -n "$CEREBRAS_KEY" ]   && KEY_COUNT=$((KEY_COUNT + 1)) || true
    [ -n "$MISTRAL_KEY" ]    && KEY_COUNT=$((KEY_COUNT + 1)) || true

    if [ "$KEY_COUNT" -ge 1 ]; then
      echo
      log_ok "Collected ${KEY_COUNT} API key(s):"
      echo "         Groq       : $(mask_key "$GROQ_KEY")"
      echo "         OpenRouter : $(mask_key "$OPENROUTER_KEY")"
      echo "         Google AI  : $(mask_key "$GEMINI_KEY")"
      echo "         Cerebras   : $(mask_key "$CEREBRAS_KEY")"
      echo "         Mistral    : $(mask_key "$MISTRAL_KEY")"
      return 0
    fi
    if [ "$attempts" -ge 3 ]; then
      die "At least ONE API key is required. Exiting after ${attempts} attempts."
    fi
    log_error "At least ONE API key is required. Let's try again."
    echo
  done
}

verify_api_keys() {
  # Live-check every provided key against its provider endpoint.
  # Non-fatal: unreachable providers are skipped (e.g. blocked networks);
  # genuinely rejected keys (401/403) are collected in VERIFY_FAILED.
  VERIFY_FAILED=""
  [ "${LITELLM_KEY_CHECK:-1}" = "1" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  local proxy_args=()
  [ -n "$WIN_PROXY_URL" ] && proxy_args=(-x "$WIN_PROXY_URL")

  echo
  log_info "       Verifying API keys against the providers..."
  local timeout="${LITELLM_KEY_CHECK_TIMEOUT:-10}"
  case "$timeout" in ''|*[!0-9]*) timeout=10 ;; esac

  _verify_one() { # $1 name  $2 key  $3 url  $4 auth(bearer|query)
    [ -n "$2" ] || return 0
    local code
    if [ "$4" = "query" ]; then
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$timeout" ${proxy_args[@]+"${proxy_args[@]}"} "$3?key=$2" 2>/dev/null || true)"
    else
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$timeout" ${proxy_args[@]+"${proxy_args[@]}"} -H "Authorization: Bearer $2" "$3" 2>/dev/null || true)"
    fi
    case "$code" in
      200)
        log_ok "         ${1}: valid (HTTP 200)"
        ;;
      401|403)
        log_warn "         ${1}: REJECTED (HTTP ${code}) - wrong/unknown key for this provider"
        VERIFY_FAILED="${VERIFY_FAILED}${1} "
        ;;
      000|'')
        log_warn "         ${1}: could not verify (network unreachable/blocked) - continuing"
        ;;
      *)
        log_warn "         ${1}: HTTP ${code} - continuing"
        VERIFY_FAILED="${VERIFY_FAILED}${1} "
        ;;
    esac
    return 0
  }

  _verify_one "Groq"       "$GROQ_KEY"       "https://api.groq.com/openai/v1/models"                   bearer
  _verify_one "OpenRouter" "$OPENROUTER_KEY" "https://openrouter.ai/api/v1/key"                        bearer
  _verify_one "Google AI"  "$GEMINI_KEY"     "https://generativelanguage.googleapis.com/v1beta/models" query
  _verify_one "Cerebras"   "$CEREBRAS_KEY"   "https://api.cerebras.ai/v1/models"                       bearer
  _verify_one "Mistral"    "$MISTRAL_KEY"    "https://api.mistral.ai/v1/models"                        bearer
  return 0
}

offer_key_reentry() {
  [ -n "$VERIFY_FAILED" ] || return 1
  echo
  printf "       Re-enter the rejected keys now? [y/N]: "
  local answer=""
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

#-------------------------------------------------------------------------------
# Optional: route provider traffic through a proxy running on WINDOWS
#-------------------------------------------------------------------------------
detect_windows_ip() {
  # WSL2 (NAT mode): the Windows host is the default gateway of eth0.
  local gw=""
  gw="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
  case "$gw" in
    ""|127.*|0.0.0.0|::1)
      # Mirrored networking mode or unusual setup - try resolv.conf.
      gw="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
      case "$gw" in
        ""|127.*|0.0.0.0|::1) return 1 ;;
      esac
      ;;
  esac
  printf '%s\n' "$gw"
  return 0
}

configure_windows_proxy() {
  # Asked once per install: should LiteLLM's outbound provider traffic be
  # routed through a proxy app running on the WINDOWS side? The answer is
  # stored in WIN_PROXY_FILE and injected into the container as
  # HTTP_PROXY / HTTPS_PROXY (NO_PROXY covers local traffic only).
  WIN_PROXY_URL=""
  local previous="" answer="" detected="" suggestion="" addr="" code=""
  [ -s "$WIN_PROXY_FILE" ] && previous="$(tr -d '\n' < "$WIN_PROXY_FILE" 2>/dev/null || true)"

  echo
  log_info "       --- Windows proxy routing (optional) ---"
  echo "       If a proxy app runs on Windows (Clash / v2rayN / Hiddify / Nekoray),"
  echo "       LiteLLM can route ALL provider traffic through it - this fixes region"
  echo "       blocks (Google / Cerebras / ...) without a system-wide VPN."
  if [ -n "$previous" ]; then
    printf "       Keep the Windows proxy setting? (%s) [Y/n]: " "$previous"
    read -r answer || answer=""
    case "$answer" in
      n|N|no|No|NO)
        echo "       OK - enter the new proxy details below."
        ;;
      *)
        WIN_PROXY_URL="$previous"
        log_ok "       Windows proxy kept: ${WIN_PROXY_URL}"
        return 0
        ;;
    esac
  else
    printf "       Route provider traffic through your Windows proxy? [y/N]: "
    read -r answer || answer=""
    case "$answer" in
      y|Y|yes|Yes|YES) : ;;
      *)
        log_info "       Windows proxy: disabled (direct connections)."
        rm -f "$WIN_PROXY_FILE" 2>/dev/null || true
        return 0
        ;;
    esac
  fi

  detected="$(detect_windows_ip || true)"
  suggestion=""
  [ -n "$detected" ] && suggestion="${detected}:7890"
  if [ -n "$suggestion" ]; then
    printf "       Proxy address as IP:PORT seen from WSL [%s]: " "$suggestion"
  else
    printf "       Proxy address as IP:PORT seen from WSL (e.g. 172.20.144.1:7890): "
  fi
  read -r addr || addr=""
  [ -z "$addr" ] && addr="$suggestion"
  if [ -z "$addr" ]; then
    log_warn "       No address entered - Windows proxy disabled."
    return 0
  fi
  case "$addr" in
    http://*|https://*|socks5://*|socks5h://*) : ;;
    *) addr="http://${addr}" ;;
  esac
  WIN_PROXY_URL="$addr"

  # Live test through the proxy (Groq endpoint - fast and region-free).
  code=""
  if command -v curl >/dev/null 2>&1; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -x "$WIN_PROXY_URL" "https://api.groq.com/openai/v1/models" 2>/dev/null || true)"
  fi
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    log_ok "       Proxy reachable - test call through it returned HTTP ${code}."
  else
    log_warn "       Test call through the proxy FAILED (code ${code:-none})."
    echo "       Check that the proxy app is running and allows LAN connections, and"
    echo "       that the IP is the WINDOWS host IP (in WSL: ip route show default)."
    case "$addr" in
      http://127.0.0.1*|https://127.0.0.1*|socks5://127.0.0.1*|socks5h://127.0.0.1*|127.0.0.1:*)
        echo "       NOTE: 127.0.0.1 inside WSL is the WSL VM itself, NOT Windows."
        echo "       Use the WINDOWS host IP (the default suggested above) instead."
        ;;
    esac
    echo "       SOCKS proxies are supported too: enter them as socks5://IP:PORT."
    echo "       (WSL accepts 127.0.0.1 only in mirrored networking mode - Win11)"
    printf "       Save it anyway? [y/N]: "
    read -r answer || answer=""
    case "$answer" in
      y|Y|yes|Yes|YES) : ;;
      *)
        WIN_PROXY_URL=""
        log_warn "       Windows proxy disabled."
        return 0
        ;;
    esac
  fi

  mkdir -p "$LITELLM_DIR"
  printf '%s\n' "$WIN_PROXY_URL" > "$WIN_PROXY_FILE"
  chmod 600 "$WIN_PROXY_FILE" 2>/dev/null || true
  log_ok "       Windows proxy enabled: ${WIN_PROXY_URL}"
  log_info "       Saved to ${WIN_PROXY_FILE} (reinstalls will offer to keep it)."
  return 0
}

collect_api_keys() {
  echo
  log_info "[4/9] API keys setup (5 providers)"
  if [ "${LITELLM_FORCE_REKEY:-0}" = "1" ]; then
    log_info "       Key refresh requested (Config Manager) - enter the new keys."
    echo "       Press ENTER to skip a provider you do not use."
    echo
    ask_all_keys
    verify_api_keys
    if offer_key_reentry; then
      echo "       OK - enter the keys again below."
      echo
      ask_all_keys
      verify_api_keys
    fi
    return 0
  fi
  configure_windows_proxy

  # A previous install? Offer to keep the already-configured keys.
  if read_existing_keys_from_container; then
    echo "       Existing API keys found (from the previous install):"
    echo "         Groq       : $(mask_key "$EXISTING_GROQ")"
    echo "         OpenRouter : $(mask_key "$EXISTING_OPENROUTER")"
    echo "         Google AI  : $(mask_key "$EXISTING_GEMINI")"
    echo "         Cerebras   : $(mask_key "$EXISTING_CEREBRAS")"
    echo "         Mistral    : $(mask_key "$EXISTING_MISTRAL")"
    local answer="" keep_answers=0
    while true; do
      printf "       Keep these keys? [Y/n]: "
      read -r answer || answer=""
      case "$answer" in
        ""|y|Y|yes|Yes|YES)
          GROQ_KEY="$EXISTING_GROQ"
          OPENROUTER_KEY="$EXISTING_OPENROUTER"
          GEMINI_KEY="$EXISTING_GEMINI"
          CEREBRAS_KEY="$EXISTING_CEREBRAS"
          MISTRAL_KEY="$EXISTING_MISTRAL"
          KEY_COUNT=0
          [ -n "$GROQ_KEY" ]       && KEY_COUNT=$((KEY_COUNT + 1)) || true
          [ -n "$OPENROUTER_KEY" ] && KEY_COUNT=$((KEY_COUNT + 1)) || true
          [ -n "$GEMINI_KEY" ]     && KEY_COUNT=$((KEY_COUNT + 1)) || true
          [ -n "$CEREBRAS_KEY" ]   && KEY_COUNT=$((KEY_COUNT + 1)) || true
          [ -n "$MISTRAL_KEY" ]    && KEY_COUNT=$((KEY_COUNT + 1)) || true
          echo
          log_ok "Keeping the existing ${KEY_COUNT} API key(s)."
          verify_api_keys
          if offer_key_reentry; then
            echo "       OK - enter the replacement keys below."
            echo
            ask_all_keys
            verify_api_keys
          fi
          return 0
          ;;
        n|N|no|No|NO)
          echo "       OK - enter the replacement keys below."
          echo
          break
          ;;
        *)
          keep_answers=$((keep_answers + 1))
          if [ "$keep_answers" -ge 5 ]; then
            log_warn "       Unrecognized input - keeping the existing keys."
            return 0
          fi
          echo "       Please answer y (keep) or n (replace)."
          ;;
      esac
    done
  fi

  echo "       Press ENTER to skip a provider you do not use."
  echo "       At least ONE key is required."
  echo
  ask_all_keys
  verify_api_keys
  if offer_key_reentry; then
    echo "       OK - enter the keys again below."
    echo
    ask_all_keys
    verify_api_keys
  fi
  return 0
}

ensure_db_password() {
  # Stable across reinstalls so the stored pgdata stays accessible.
  if [ -s "$DB_PASSWORD_FILE" ]; then
    DB_PASSWORD="$(tr -d '\n' < "$DB_PASSWORD_FILE")"
  else
    if command -v openssl >/dev/null 2>&1; then
      DB_PASSWORD="$(openssl rand -hex 16)"
    else
      DB_PASSWORD="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
    fi
    mkdir -p "$LITELLM_DIR"
    printf '%s\n' "$DB_PASSWORD" > "$DB_PASSWORD_FILE"
    chmod 600 "$DB_PASSWORD_FILE"
  fi
  return 0
}

generate_master_key() {
  # Keep the master key stable across reinstalls (dashboard login + every
  # client that stored it stay valid). Only generate one when none exists.
  local reused=0
  if [ -s "$LITELLM_KEYFILE" ]; then
    MASTER_KEY="$(tr -d '\n' < "$LITELLM_KEYFILE")"
    reused=1
  elif command -v openssl >/dev/null 2>&1; then
    MASTER_KEY="sk-$(openssl rand -hex 32)"
  else
    MASTER_KEY="sk-$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
  fi
  mkdir -p "$LITELLM_DIR"
  printf '%s\n' "$MASTER_KEY" > "$LITELLM_KEYFILE"
  chmod 600 "$LITELLM_KEYFILE"
  # dedicated dashboard login file (the UI password IS the master key)
  {
    echo "LiteLLM Admin Panel (UI)"
    echo "  URL      : http://127.0.0.1:${LITELLM_PORT}/ui"
    echo "  Username : admin"
    echo "  Password : ${MASTER_KEY}"
  } > "$LITELLM_CRED_FILE"
  chmod 600 "$LITELLM_CRED_FILE"
  if [ "$reused" -eq 1 ]; then
    log_ok "Master key reused (unchanged): ${LITELLM_KEYFILE}"
  else
    log_ok "LiteLLM master key generated and saved to: ${LITELLM_KEYFILE}"
  fi
  log_ok "Dashboard login saved to: ${LITELLM_CRED_FILE}"
}

#-------------------------------------------------------------------------------
# config.yaml (only providers whose keys were provided)
#-------------------------------------------------------------------------------
generate_litellm_config() {
  log_info "[5/9] Generating LiteLLM configuration: ${LITELLM_CONFIG}"
  mkdir -p "$LITELLM_DIR"

  {
    echo "model_list:"

    if [ -n "$GROQ_KEY" ]; then
      cat <<'EOF'
  # ---------------- Groq (fast inference) ----------------
  # NOTE: model_name MUST contain 'claude' - the Claude Desktop app
  #       model picker only keeps ids containing 'claude' or 'anthropic'.
  - model_name: claude-gpt-oss-120b
    litellm_params:
      model: groq/openai/gpt-oss-120b
      api_key: os.environ/GROQ_API_KEY
      api_base: https://api.groq.com/openai/v1
  - model_name: claude-gpt-oss-20b
    litellm_params:
      model: groq/openai/gpt-oss-20b
      api_key: os.environ/GROQ_API_KEY
      api_base: https://api.groq.com/openai/v1
EOF
    fi

    if [ -n "$OPENROUTER_KEY" ]; then
      cat <<'EOF'
  # ---------------- OpenRouter (free coding models) ----------------
  - model_name: claude-deepseek-v3.1
    litellm_params:
      model: openrouter/deepseek/deepseek-chat-v3.1:free
      api_key: os.environ/OPENROUTER_API_KEY
      api_base: https://openrouter.ai/api/v1
  - model_name: claude-deepseek-v3-0324
    litellm_params:
      model: openrouter/deepseek/deepseek-chat-v3-0324:free
      api_key: os.environ/OPENROUTER_API_KEY
      api_base: https://openrouter.ai/api/v1
EOF
    fi

    if [ -n "$GEMINI_KEY" ]; then
      cat <<'EOF'
  # ---------------- Google AI Studio (Gemini) ----------------
  - model_name: claude-gemini-2.0-flash
    litellm_params:
      model: gemini/gemini-2.0-flash
      api_key: os.environ/GEMINI_API_KEY
EOF
    fi

    if [ -n "$CEREBRAS_KEY" ]; then
      cat <<'EOF'
  # ---------------- Cerebras ----------------
  - model_name: claude-llama3.1-70b
    litellm_params:
      model: cerebras/llama3.1-70b
      api_key: os.environ/CEREBRAS_API_KEY
      api_base: https://api.cerebras.ai/v1
EOF
    fi

    if [ -n "$MISTRAL_KEY" ]; then
      cat <<'EOF'
  # ---------------- Mistral ----------------
  - model_name: claude-codestral
    litellm_params:
      model: mistral/codestral-latest
      api_key: os.environ/MISTRAL_API_KEY
      api_base: https://api.mistral.ai/v1
EOF
    fi

    # Canonical Anthropic-named aliases. The Claude Desktop config validator
    # only accepts Anthropic catalog names (e.g. claude-sonnet-4-5); these
    # route to the SAME free underlying models as the primary/fast pick.
    if [ -n "$GROQ_KEY$OPENROUTER_KEY$GEMINI_KEY$CEREBRAS_KEY$MISTRAL_KEY" ]; then
      local amain="" afast=""
      if   [ -n "$GROQ_KEY" ]; then
        amain="groq/openai/gpt-oss-120b|https://api.groq.com/openai/v1|GROQ_API_KEY"
        afast="groq/openai/gpt-oss-20b|https://api.groq.com/openai/v1|GROQ_API_KEY"
      elif [ -n "$OPENROUTER_KEY" ]; then
        amain="openrouter/deepseek/deepseek-chat-v3.1:free|https://openrouter.ai/api/v1|OPENROUTER_API_KEY"
        afast="openrouter/deepseek/deepseek-chat-v3-0324:free|https://openrouter.ai/api/v1|OPENROUTER_API_KEY"
      elif [ -n "$GEMINI_KEY" ]; then
        amain="gemini/gemini-2.0-flash||GEMINI_API_KEY"
        afast="gemini/gemini-2.0-flash||GEMINI_API_KEY"
      elif [ -n "$CEREBRAS_KEY" ]; then
        amain="cerebras/llama3.1-70b|https://api.cerebras.ai/v1|CEREBRAS_API_KEY"
        afast="cerebras/llama3.1-70b|https://api.cerebras.ai/v1|CEREBRAS_API_KEY"
      else
        amain="mistral/codestral-latest|https://api.mistral.ai/v1|MISTRAL_API_KEY"
        afast="$amain"
      fi
      local atarget="" abase="" akeyvar=""
      for apair in "$amain|sonnet" "$afast|haiku"; do
        atarget="$(printf '%s' "$apair" | cut -d'|' -f1)"
        abase="$(printf '%s' "$apair" | cut -d'|' -f2)"
        akeyvar="$(printf '%s' "$apair" | cut -d'|' -f3)"
        local amodel="${apair##*|}"
        if [ "$amodel" = "sonnet" ]; then aname="claude-sonnet-4-5"; else aname="claude-haiku-4-5"; fi
        echo "  - model_name: ${aname}"
        echo "    litellm_params:"
        echo "      model: ${atarget}"
        echo "      api_key: os.environ/${akeyvar}"
        [ -n "$abase" ] && echo "      api_base: ${abase}"
      done
    fi

    echo ""
    echo "litellm_settings:"
    echo "  drop_params: true        # silently drop unsupported provider params"
    echo ""
    echo "general_settings:"
    echo "  master_key: os.environ/LITELLM_MASTER_KEY"
    if [ "$UI_DB_ENABLED" = "1" ]; then
      echo "  database_url: os.environ/DATABASE_URL"
    fi
  } > "$LITELLM_CONFIG"

  log_ok "config.yaml generated (only providers with keys are enabled)."
}

#-------------------------------------------------------------------------------
# Container lifecycle
#-------------------------------------------------------------------------------
build_docker_env_args() {
  DOCKER_ENV_ARGS=(-e "LITELLM_MASTER_KEY=${MASTER_KEY}")
  # Admin panel (UI) login credentials: http://127.0.0.1:4000/ui
  DOCKER_ENV_ARGS+=(-e "UI_USERNAME=admin" -e "UI_PASSWORD=${MASTER_KEY}")
  if [ "$UI_DB_ENABLED" = "1" ]; then
    ensure_db_password
    DOCKER_ENV_ARGS+=(-e "DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@${DB_CONTAINER}:5432/${DB_NAME}")
  fi
  if [ -n "$GROQ_KEY" ];       then DOCKER_ENV_ARGS+=(-e "GROQ_API_KEY=${GROQ_KEY}"); fi
  if [ -n "$OPENROUTER_KEY" ]; then DOCKER_ENV_ARGS+=(-e "OPENROUTER_API_KEY=${OPENROUTER_KEY}"); fi
  if [ -n "$GEMINI_KEY" ];     then DOCKER_ENV_ARGS+=(-e "GEMINI_API_KEY=${GEMINI_KEY}"); fi
  if [ -n "$CEREBRAS_KEY" ];   then DOCKER_ENV_ARGS+=(-e "CEREBRAS_API_KEY=${CEREBRAS_KEY}"); fi
  if [ -n "$MISTRAL_KEY" ];    then DOCKER_ENV_ARGS+=(-e "MISTRAL_API_KEY=${MISTRAL_KEY}"); fi
  if [ -n "$WIN_PROXY_URL" ]; then
    DOCKER_ENV_ARGS+=(-e "HTTP_PROXY=${WIN_PROXY_URL}" \
                      -e "HTTPS_PROXY=${WIN_PROXY_URL}" \
                      -e "NO_PROXY=localhost,127.0.0.1,${DB_CONTAINER}")
  fi
  return 0
}

ensure_db_stack() {
  if [ "$UI_DB_ENABLED" != "1" ]; then
    log_info "       Admin UI database disabled (LITELLM_UI_DB=0)."
    return 0
  fi
  ensure_db_password
  $SUDO docker network inspect "$DB_NETWORK" >/dev/null 2>&1 || \
    $SUDO docker network create "$DB_NETWORK" >/dev/null
  if ! $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_CONTAINER"; then
    log_info "       Starting the Admin UI database (${DB_IMAGE})..."
    $SUDO docker run -d \
      --name "$DB_CONTAINER" \
      --restart unless-stopped \
      --network "$DB_NETWORK" \
      -e "POSTGRES_USER=${DB_USER}" \
      -e "POSTGRES_PASSWORD=${DB_PASSWORD}" \
      -e "POSTGRES_DB=${DB_NAME}" \
      -v "${LITELLM_DIR}/pgdata:/var/lib/postgresql/data" \
      "$DB_IMAGE" >/dev/null
    log_ok "       Database container '${DB_CONTAINER}' started (restart policy: unless-stopped)."
  else
    log_ok "       Database container '${DB_CONTAINER}' already present."
  fi
  log_info "       Waiting for the database to accept connections..."
  local i
  for i in $(seq 1 30); do
    if $SUDO docker exec "$DB_CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
      log_ok "       Database is ready."
      return 0
    fi
    sleep 2
  done
  log_warn "       Database not ready yet - LiteLLM will keep retrying in the background."
  return 0
}

remove_existing_container() {
  if $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    log_warn "       Found existing container '${CONTAINER_NAME}'. Removing it..."
    $SUDO docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  fi
  return 0
}

pull_liteLLM_image() {
  log_info "[6/9] Pulling prebuilt LiteLLM image (no build step): ${LITELLM_IMAGE}"
  log_info "       This may take several minutes on the first run..."

  # Is a usable image already stored locally (previous install)?
  local have_local=0
  if $SUDO docker image inspect "$LITELLM_IMAGE" >/dev/null 2>&1; then
    have_local=1
    log_ok "       Image already exists locally (from a previous install)."
  fi

  # Transient TLS handshake timeouts are common on filtered networks -> retry.
  local attempts="${LITELLM_PULL_RETRIES:-3}"
  case "$attempts" in ''|*[!0-9]*) attempts=3 ;; esac
  attempts="$((attempts < 1 ? 1 : attempts))"

  local i
  for i in $(seq 1 "$attempts"); do
    if [ "$i" -gt 1 ]; then
      log_warn "       Retry ${i}/${attempts} (transient TLS/network timeouts are common)..."
    fi
    if $SUDO docker pull "$LITELLM_IMAGE"; then
      log_ok "Image pulled successfully."
      return 0
    fi
    [ "$i" -lt "$attempts" ] && sleep 5
  done

  # Continue with the already-downloaded image instead of failing hard.
  if [ "$have_local" -eq 1 ]; then
    log_warn "Pull failed, but the image already exists locally - continuing with the local copy."
    log_warn "To update it later, fix the connection and run: ${SUDO} docker pull ${LITELLM_IMAGE}"
    return 0
  fi

  # Optional last resort: a ghcr pull-through mirror, e.g. ghcr.nju.edu.cn
  if [ -n "${LITELLM_GHCR_MIRROR:-}" ]; then
    local mirror_image="${LITELLM_GHCR_MIRROR%/}/berriai/litellm:main-latest"
    log_warn "       Trying the ghcr fallback mirror: ${mirror_image}"
    if $SUDO docker pull "$mirror_image" && $SUDO docker tag "$mirror_image" "$LITELLM_IMAGE"; then
      log_ok "Image pulled via the mirror and tagged as ${LITELLM_IMAGE}."
      return 0
    fi
  fi

  die "Image pull failed after ${attempts} attempt(s). Fixes, in order:
         1. Simply re-run the installer - TLS timeouts are often transient.
         2. Check your internet connection inside WSL:  curl -I https://ghcr.io/v2/
         3. Turn a VPN on (on the WINDOWS side) and re-run the installer.
         4. Use a ghcr mirror:   LITELLM_GHCR_MIRROR=ghcr.nju.edu.cn bash setup.sh
         5. Use a custom image:  LITELLM_IMAGE=<registry>/berriai/litellm:main-latest bash setup.sh"
}

start_litellm_container() {
  log_info "[7/9] Starting LiteLLM container on port ${LITELLM_PORT}..."
  ensure_db_stack
  remove_existing_container
  build_docker_env_args

  local net_args=()
  if [ "$UI_DB_ENABLED" = "1" ]; then
    net_args+=(--network "$DB_NETWORK")
  fi

  $SUDO docker run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    -p "${LITELLM_PORT}:4000" \
    -v "${LITELLM_CONFIG}:/app/config.yaml:ro" \
    "${net_args[@]}" \
    "${DOCKER_ENV_ARGS[@]}" \
    "$LITELLM_IMAGE" \
    --config /app/config.yaml \
    --port 4000 >/dev/null

  log_ok "Container '${CONTAINER_NAME}' started (restart policy: unless-stopped)."
}

wait_for_litellm() {
  # First boot with the database runs schema migrations - allow more time.
  local max_iters
  if [ -n "${LITELLM_HEALTH_WAIT_SEC:-}" ]; then
    max_iters=$(( (LITELLM_HEALTH_WAIT_SEC + 1) / 2 ))
  elif [ "$UI_DB_ENABLED" = "1" ]; then
    max_iters=60
  else
    max_iters=30
  fi
  log_info "       Waiting for LiteLLM to become healthy (up to $((max_iters * 2))s)..."
  local i http_code=""
  for i in $(seq 1 "$max_iters"); do
    http_code=""
    if command -v curl >/dev/null 2>&1; then
      http_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${LITELLM_PORT}/health/liveliness" 2>/dev/null || true)"
    elif command -v wget >/dev/null 2>&1; then
      if wget -q -O /dev/null "http://127.0.0.1:${LITELLM_PORT}/health/liveliness" 2>/dev/null; then
        http_code="200"
      fi
    else
      log_warn "       Neither curl nor wget found - skipping health check."
      return 0
    fi
    if [ "$http_code" = "200" ]; then
      log_ok "LiteLLM is healthy: http://127.0.0.1:${LITELLM_PORT}"
      return 0
    fi
    sleep 2
  done
  log_warn "Health check timed out. The proxy may still be booting."
  log_warn "Inspect logs with:  ${SUDO} docker logs -f ${CONTAINER_NAME}"
}

#-------------------------------------------------------------------------------
# Auto-start on WSL boot + management CLI (freeagents up/down/restart/uninstall)
#-------------------------------------------------------------------------------
write_boot_helper() {
  $SUDO mkdir -p "$(dirname "$BOOT_HELPER")"
  {
    echo '#!/usr/bin/env bash'
    echo '# Auto-generated by setup.sh - starts Docker and the litellm container at WSL boot.'
    echo 'LOG="${TMPDIR:-/tmp}/litellm-boot.log"'
    echo '{'
    echo '  if [ "$(id -u)" -eq 0 ]; then S=""; else S="sudo"; fi'
    echo '  $S service docker start >/dev/null 2>&1 || true'
    echo '  for i in $(seq 1 30); do $S docker info >/dev/null 2>&1 && break; sleep 1; done'
    echo '  if $S docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qx litellm; then'
    echo '    $S docker start litellm >/dev/null 2>&1 || true'
    echo '  fi'
    echo '} >>"$LOG" 2>&1'
  } | $SUDO tee "$BOOT_HELPER" >/dev/null
  $SUDO chmod 755 "$BOOT_HELPER"
}

write_management_cli() {
  $SUDO mkdir -p "$(dirname "$CLI_BIN")"
  cat <<'LITEOF' | $SUDO tee "$CLI_BIN" >/dev/null
#!/usr/bin/env bash
#===============================================================================
# freeagents - management CLI for the Free AI Agents local gateways (WSL2)
# Installed by the setup.sh setup script.
#
#   freeagents up       Start the gateway (and Docker daemon if needed)
#   freeagents down     Stop the gateway
#   freeagents restart  Restart the gateway and wait until healthy
#   litellm status      Show container state, health and config paths
#   litellm logs        Follow the proxy logs (Ctrl+C to exit)
#   freeagents uninstall  Remove everything this installer created
#   freeagents (no args)  Re-open the Free AI Agents manager menu
#===============================================================================
set -u

CONTAINER_NAME="litellm"
DB_CONTAINER="litellm-db"
DB_NETWORK="litellm-net"
PORT="4000"
LITELLM_DIR="${HOME}/.litellm"
KEYFILE="${LITELLM_DIR}/master_key.txt"
CONFIG_FILE="${LITELLM_DIR}/config.yaml"
WIN_PROXY_FILE="${LITELLM_DIR}/windows_proxy.txt"
DESKTOP_PROFILE_ID="00000000-0000-4000-8000-0000000a119e"
MANAGER_COPY="${HOME}/.free-ai-agents/setup.sh"
SECONDARY_SCRIPT="${HOME}/.free-ai-agents/OmniRoute.sh"
CLI_BIN="/usr/local/bin/freeagents"
BOOT_HELPER="/usr/local/bin/litellm-boot.sh"
SYSTEMD_UNIT="/etc/systemd/system/litellm.service"
WSL_CONF="/etc/wsl.conf"
BOOT_LINE="command = /usr/local/bin/litellm-boot.sh"

# Convert a WSL path (/mnt/c/...) back to its Windows form (C:\...)
wsl_to_win_path() {
  local p="${1#/mnt/}"
  local drive="${p%%/*}"
  local rest="${p#*/}"
  printf '%s:\\%s' "$(printf '%s' "$drive" | tr '[:lower:]' '[:upper:]')" "$(printf '%s' "$rest" | tr '/' '\\')"
}

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

log_info()  { echo "[INFO] $*"; }
log_ok()    { echo "[ OK ] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[FAIL] $*" >&2; }

daemon_up() { $SUDO docker info >/dev/null 2>&1; }

ensure_daemon() {
  if daemon_up; then return 0; fi
  log_info "Starting the Docker daemon..."
  $SUDO service docker start >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 20); do
    if daemon_up; then log_ok "Docker daemon is up."; return 0; fi
    sleep 1
  done
  log_error "Docker daemon did not start. Try: sudo service docker start"
  return 1
}

container_exists() { $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; }
is_running()       { [ "$($SUDO docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)" = "true" ]; }

health_code() {
  if command -v curl >/dev/null 2>&1; then
    curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${PORT}/health/liveliness" 2>/dev/null || true
  elif command -v wget >/dev/null 2>&1; then
    if wget -q -O /dev/null "http://127.0.0.1:${PORT}/health/liveliness" 2>/dev/null; then echo 200; else echo 000; fi
  else
    echo "n/a"
  fi
}

wait_healthy() {
  local i code
  for i in $(seq 1 15); do
    code="$(health_code)"
    if [ "$code" = "200" ]; then
      log_ok "LiteLLM is healthy: http://127.0.0.1:${PORT}"
      return 0
    fi
    sleep 2
  done
  log_warn "Proxy is up but the health check timed out. Logs: ${SUDO} docker logs -f ${CONTAINER_NAME}"
  return 0
}

win_home() {
  local ps=""
  if command -v powershell.exe >/dev/null 2>&1; then
    ps="powershell.exe"
  elif [ -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]; then
    ps="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  fi
  [ -n "$ps" ] || return 1
  local raw drive letter rest
  raw="$($ps -NoProfile -Command "[Environment]::GetFolderPath('UserProfile')" 2>/dev/null | tr -d '\r')" || return 1
  [ -n "$raw" ] || return 1
  drive="${raw%%:*}"
  letter="$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')"
  rest="${raw#*:}"
  rest="${rest//\\//}"
  printf '/mnt/%s%s' "$letter" "$rest"
}

cmd_credentials() {
  if [ ! -f "$KEYFILE" ]; then
    log_error "Master key file not found: ${KEYFILE}"
    return 1
  fi
  local key
  key="$(tr -d '\n' < "$KEYFILE")"
  echo "  LiteLLM Admin Panel (UI)"
  echo "  URL      : http://127.0.0.1:${PORT}/ui"
  echo "  Username : admin"
  echo "  Password : ${key}"
  echo "  (the dashboard password IS the master key)"
}

cmd_doctor() {
  # Deep diagnosis: stack status, per-provider connectivity/keys, and a real
  # chat completion through the local proxy for EVERY configured model.
  local timeout="${LITELLM_DOCTOR_TIMEOUT:-45}"
  case "$timeout" in ''|*[!0-9]*) timeout=45 ;; esac
  ensure_daemon || return 1

  echo "================================================="
  echo "                 LITELLM DOCTOR"
  echo "================================================="
  echo "[STACK]"
  if is_running; then echo "  proxy container : running"; else echo "  proxy container : STOPPED"; fi
  echo "  proxy health    : HTTP $(health_code)  (http://127.0.0.1:${PORT}/health/liveliness)"
  if $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_CONTAINER"; then
    echo "  ui database     : $($SUDO docker inspect -f '{{.State.Status}}' "$DB_CONTAINER" 2>/dev/null || echo unknown)"
  else
    echo "  ui database     : not installed (UI login disabled, chat still works)"
  fi
  local wp=""
  [ -s "$WIN_PROXY_FILE" ] && wp="$(tr -d '\n' < "$WIN_PROXY_FILE" 2>/dev/null || true)"
  if [ -n "$wp" ]; then
    echo "  windows proxy   : ${wp}  (provider traffic routed via Windows)"
  else
    echo "  windows proxy   : disabled"
  fi
  echo

  if [ -n "$wp" ]; then
    echo "[PROVIDER CONNECTIVITY + KEYS]   (via the Windows proxy)"
  else
    echo "[PROVIDER CONNECTIVITY + KEYS]   (direct, from inside WSL)"
  fi
  local envs key code
  envs="$($SUDO docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  local proxy_args=()
  [ -n "$wp" ] && proxy_args=(-x "$wp")
  _doc_provider() { # $1 name $2 envname $3 url $4 auth
    key="$(printf '%s\n' "$envs" | sed -n "s/^${2}=//p" | head -1)"
    if [ -z "$key" ]; then
      echo "  ${1}: no key configured"
      return 0
    fi
    if [ "$4" = "query" ]; then
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "${LITELLM_KEY_CHECK_TIMEOUT:-10}" ${proxy_args[@]+"${proxy_args[@]}"} "$3?key=$key" 2>/dev/null || true)"
    else
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "${LITELLM_KEY_CHECK_TIMEOUT:-10}" ${proxy_args[@]+"${proxy_args[@]}"} -H "Authorization: Bearer $key" "$3" 2>/dev/null || true)"
    fi
    case "$code" in
      200)      echo "  ${1}: reachable, key valid (HTTP 200)" ;;
      401|403)  echo "  ${1}: REJECTED (HTTP ${code}) - invalid key OR the provider blocks your region" ;;
      000|'')   echo "  ${1}: UNREACHABLE from this network (timeout/blocked)" ;;
      *)        echo "  ${1}: HTTP ${code}" ;;
    esac
    return 0
  }
  _doc_provider "Groq"       "GROQ_API_KEY"       "https://api.groq.com/openai/v1/models"                    bearer
  _doc_provider "OpenRouter" "OPENROUTER_API_KEY" "https://openrouter.ai/api/v1/key"                         bearer
  _doc_provider "Google AI"  "GEMINI_API_KEY"     "https://generativelanguage.googleapis.com/v1beta/models"  query
  _doc_provider "Cerebras"   "CEREBRAS_API_KEY"   "https://api.cerebras.ai/v1/models"                        bearer
  _doc_provider "Mistral"    "MISTRAL_API_KEY"    "https://api.mistral.ai/v1/models"                         bearer
  echo

  echo "[MODEL LIVE TESTS]   (real chat call via http://127.0.0.1:${PORT}/v1)"
  local mk models_json id start lat body code2 fails=0 total=0
  mk="$(tr -d '\n' < "$KEYFILE" 2>/dev/null)"
  if [ -z "$mk" ]; then
    echo "  master key file missing - cannot test models"
    return 1
  fi
  models_json="$(curl -s --max-time 10 -H "Authorization: Bearer $mk" "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null || true)"
  ids="$(printf '%s' "$models_json" | grep -o '"id":"[^"]*"' | sed 's/"id":"//; s/"$//')"
  if [ -z "$ids" ]; then
    echo "  could not read the model list from the proxy"
    return 1
  fi
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    total=$((total + 1))
    body="$(mktemp)"
    start="$(date +%s)"
    code2="$(curl -s -o "$body" -w '%{http_code}' --max-time "$timeout" \
      -X POST -H "Authorization: Bearer $mk" -H "Content-Type: application/json" \
      -d "{\"model\":\"$id\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":8}" \
      "http://127.0.0.1:${PORT}/v1/chat/completions" 2>/dev/null || true)"
    lat=$(( $(date +%s) - start ))
    if [ "$code2" = "200" ]; then
      echo "  OK   ${id} (${lat}s)"
    else
      fails=$((fails + 1))
      echo "  FAIL ${id} (HTTP ${code2:-none}): $(head -c 220 "$body" 2>/dev/null | tr '\n' ' ')"
    fi
    rm -f "$body"
  done <<EOFDOCTOR
$ids
EOFDOCTOR
  echo
  echo "[SUMMARY]"
  if [ "$fails" -eq 0 ]; then
    echo "  ALL ${total} MODEL TESTS PASSED"
  else
    echo "  ${fails}/${total} model test(s) FAILED"
    echo "  Hints:"
    echo "   - FAIL with 401/403 while [PROVIDER] above says 'reachable, key valid':"
    echo "     the provider blocks your region/IP (US providers block Iran)."
    echo "     Run a system-wide VPN on the WINDOWS side, then 'litellm restart'."
    echo "   - REJECTED in [PROVIDER] section => key wrong for that provider:"
    echo "     re-run the installer and answer 'n' at 'Keep these keys?'"
    echo "   - UNREACHABLE => your network cannot reach the provider at all (VPN needed)"
    echo "   - No VPN? Re-run the installer and enable the WINDOWS PROXY option"
    echo "     (Clash / v2rayN / Hiddify) - provider traffic then exits via Windows."
  fi
  echo "================================================="
  [ "$fails" -eq 0 ]
}

cmd_up() {
  ensure_daemon || return 1
  if ! container_exists; then
    log_error "Container '${CONTAINER_NAME}' does not exist. Run the installer first."
    return 1
  fi
  if is_running; then
    log_ok "Proxy is already running."
  else
    log_info "Starting '${CONTAINER_NAME}'..."
    $SUDO docker start "$CONTAINER_NAME" >/dev/null
    log_ok "Container started."
  fi
  wait_healthy
}

cmd_down() {
  if ! container_exists; then
    log_warn "No container named '${CONTAINER_NAME}' found."
    return 0
  fi
  if is_running; then
    $SUDO docker stop "$CONTAINER_NAME" >/dev/null
    log_ok "Proxy stopped."
  else
    log_ok "Proxy is already stopped."
  fi
}

cmd_restart() {
  ensure_daemon || return 1
  $SUDO docker restart "$CONTAINER_NAME" >/dev/null
  log_ok "Proxy restarted."
  wait_healthy
}

cmd_status() {
  ensure_daemon || return 1
  if ! container_exists; then
    log_warn "Container '${CONTAINER_NAME}' is not installed."
    return 1
  fi
  local state policy
  state="$($SUDO docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"
  policy="$($SUDO docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$CONTAINER_NAME" 2>/dev/null || echo unknown)"
  echo "  Container state : ${state}"
  echo "  Restart policy  : ${policy}"
  echo "  Health endpoint : $(health_code)  (http://127.0.0.1:${PORT}/health/liveliness)"
  echo "  OpenAI endpoint : http://127.0.0.1:${PORT}/v1"
  echo "  Admin panel     : http://127.0.0.1:${PORT}/ui  (user: admin, password: master key)"
  if $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_CONTAINER"; then
    local dbstate
    dbstate="$($SUDO docker inspect -f '{{.State.Status}}' "$DB_CONTAINER" 2>/dev/null || echo unknown)"
    echo "  Admin database  : ${DB_CONTAINER} (${dbstate})"
  else
    echo "  Admin database  : not installed (UI login requires it)"
  fi
  echo "  Config file     : ${CONFIG_FILE}$([ -f "$CONFIG_FILE" ] && echo ' (present)' || echo ' (missing)')"
  echo "  Master key file : ${KEYFILE}$([ -f "$KEYFILE" ] && echo ' (present)' || echo ' (missing)')"
  echo "  UI credentials  : ${LITELLM_DIR}/dashboard_credentials.txt$([ -f "${LITELLM_DIR}/dashboard_credentials.txt" ] && echo ' (present)' || echo ' (missing)')"
}

cmd_logs() {
  ensure_daemon || return 1
  $SUDO docker logs -f --tail 100 "$CONTAINER_NAME"
}

cmd_uninstall() {
  local assume_yes="${1:-}"
  if [ "$assume_yes" != "--yes" ] && [ "$assume_yes" != "-y" ]; then
    printf "This removes the proxy container, all configs and this CLI. Continue? [y/N]: "
    local answer=""
    read -r answer || answer=""
    case "$answer" in
      y|Y|yes|YES) ;;
      *) log_info "Aborted."; return 1 ;;
    esac
  fi

  if container_exists; then
    $SUDO docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    $SUDO docker rm "$CONTAINER_NAME"   >/dev/null 2>&1 || true
    log_ok "Container removed."
  else
    log_warn "No container named '${CONTAINER_NAME}' found."
  fi

  if $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_CONTAINER"; then
    $SUDO docker stop "$DB_CONTAINER" >/dev/null 2>&1 || true
    $SUDO docker rm "$DB_CONTAINER"   >/dev/null 2>&1 || true
    log_ok "Admin UI database container removed."
  fi
  $SUDO docker network rm "$DB_NETWORK" >/dev/null 2>&1 || true

  if [ -d "$LITELLM_DIR" ]; then
    rm -rf "$LITELLM_DIR"
    log_ok "Removed ${LITELLM_DIR}"
  fi

  local wh cc
  wh="$(win_home || true)"
  if [ -n "$wh" ] && [ -d "$wh" ]; then
    cc="${wh}/.claude/settings.json"
    if [ -f "$cc" ]; then
      rm -f "$cc"
      log_ok "Removed ${cc}"
    fi
    local newest_bak
    newest_bak="$(ls -1t "${wh}/.claude/settings.json.bak."* 2>/dev/null | head -1 || true)"
    if [ -n "$newest_bak" ] && [ -f "$newest_bak" ]; then
      cp "$newest_bak" "$cc"
      log_ok "Restored pre-install backup: ${newest_bak}"
    fi
    # Remove the Claude Desktop gateway policy (HKCU registry)
    local ps_bin="" reg_bak_win="" newest_reg_bak
    ps_bin="$(command -v powershell.exe 2>/dev/null || true)"
    if [ -z "$ps_bin" ] && [ -x /mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe ]; then
      ps_bin="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    fi
    if [ -n "$ps_bin" ]; then
      newest_reg_bak="$(ls -1t "${wh}/.claude/claude_desktop_policy.reg.bak."* 2>/dev/null | head -1 || true)"
      if [ -n "$newest_reg_bak" ] && [ -f "$newest_reg_bak" ]; then
        reg_bak_win="$(wsl_to_win_path "$newest_reg_bak")"
      fi
      "$ps_bin" -NoProfile -Command "Remove-ItemProperty -Path 'HKCU:\\SOFTWARE\\Policies\\Claude' -Name 'inferenceProvider' -ErrorAction SilentlyContinue; Remove-ItemProperty -Path 'HKCU:\\SOFTWARE\\Policies\\Claude' -Name 'inferenceGatewayBaseUrl' -ErrorAction SilentlyContinue; Remove-ItemProperty -Path 'HKCU:\\SOFTWARE\\Policies\\Claude' -Name 'inferenceCredentialKind' -ErrorAction SilentlyContinue; Remove-ItemProperty -Path 'HKCU:\\SOFTWARE\\Policies\\Claude' -Name 'inferenceGatewayAuthScheme' -ErrorAction SilentlyContinue; Remove-ItemProperty -Path 'HKCU:\\SOFTWARE\\Policies\\Claude' -Name 'inferenceGatewayApiKey' -ErrorAction SilentlyContinue" >/dev/null 2>&1 \
        && log_ok "Removed the legacy Claude Desktop registry policy" \
        || log_warn "Could not clean the legacy Claude Desktop policy (registry)"
          local la="" prof="" mta=""
          la="$("$ps_bin" -NoProfile -Command "[Environment]::GetFolderPath('LocalApplicationData')" 2>/dev/null | tr -d '\r' | head -n1 || true)"
          if [ -n "$la" ]; then
            local ld llr
            ld="${la%%:*}"; llr="$(printf '%s' "$ld" | tr '[:upper:]' '[:lower:]')"; la="${la#*:}"; la="${la//\\//}"
            la="/mnt/${llr}${la}"
            prof="${la}/Claude-3p/configLibrary/${DESKTOP_PROFILE_ID}.json"
            mta="${la}/Claude-3p/configLibrary/_meta.json"
            if [ -f "$prof" ]; then
              rm -f "$prof"
              log_ok "Removed the Claude Desktop profile: ${prof}"
            fi
            if [ -f "$mta" ] && command -v python3 >/dev/null 2>&1; then
              CLAUDE_META_FILE="$mta" CLAUDE_PROFILE_ID="$DESKTOP_PROFILE_ID" python3 <<'PYMETA' || true
    import json, os
    p = os.environ["CLAUDE_META_FILE"]; pid = os.environ["CLAUDE_PROFILE_ID"]
    try:
        meta = json.load(open(p))
    except Exception:
        raise SystemExit(0)
    entries = [e for e in (meta.get("entries") or [])
           if e.get("id") != pid and e.get("id") != "litellm-free-ai-agents"]
    meta["entries"] = entries
    if meta.get("appliedId") == pid:
        meta["appliedId"] = entries[0]["id"] if entries else None
    json.dump(meta, open(p, "w"), indent=2)
PYMETA
            fi
          fi
    fi
  fi

  if $SUDO test -f "$SYSTEMD_UNIT"; then
    $SUDO rm -f "$SYSTEMD_UNIT"
    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
    log_ok "Removed systemd service."
  fi
  if $SUDO test -f "$BOOT_HELPER"; then
    $SUDO rm -f "$BOOT_HELPER"
    log_ok "Removed boot helper."
  fi
  if $SUDO test -f "$WSL_CONF" && $SUDO grep -qF "$BOOT_LINE" "$WSL_CONF" 2>/dev/null; then
    $SUDO sed -i "\|^${BOOT_LINE}\$|d" "$WSL_CONF"
    log_ok "Removed boot entry from ${WSL_CONF}."
  fi
  if $SUDO test -f "$CLI_BIN"; then
    $SUDO rm -f "$CLI_BIN"
    log_ok "Management CLI removed."
  fi

  echo
  log_ok "UNINSTALL COMPLETED."
  echo "  Kept: Docker Engine, /etc/docker/daemon.json and the pulled images."
  return 0
}

run_secondary() { # $1 = action for the secondary gateway manager
  if [ -s "$SECONDARY_SCRIPT" ]; then
    echo "--- secondary gateway ---"
    bash "$SECONDARY_SCRIPT" "$1" || true
  fi
}

if [ $# -eq 0 ]; then
  if [ -f "$MANAGER_COPY" ]; then
    exec bash "$MANAGER_COPY"
  fi
  echo "Manager menu not found - re-run the setup.sh installer."
  exit 1
fi

case "${1:-}" in
  up)        shift; cmd_up "$@"; run_secondary --up ;;
  down)      shift; cmd_down "$@"; run_secondary --down ;;
  restart)   shift; cmd_restart "$@"; run_secondary --restart ;;
  status)    shift; cmd_status "$@"; run_secondary --status ;;
  credentials|ui) shift; cmd_credentials "$@" ;;
  doctor)    shift; cmd_doctor "$@"; exit $? ;;
  logs)      shift; cmd_logs "$@" ;;
  uninstall) shift; cmd_uninstall "${1:-}"; run_secondary --uninstall ;;
  help|-h|--help)
    echo "Usage: freeagents {up|down|restart|status|logs|uninstall}"
    echo "  up          start the gateway (and Docker if needed)"
    echo "  down        stop the gateway"
    echo "  restart     restart the gateway and wait until healthy"
    echo "  status      show container state, health and config paths"
    echo "  credentials show Admin Panel URL / username / password"
    echo "  doctor      deep diagnosis: providers + live test of EVERY model"
    echo "  logs        follow gateway logs (Ctrl+C to exit)"
    echo "  uninstall   remove everything this installer created"
    echo "  (no args)   open the Free AI Agents manager menu"
    ;;
  *) log_error "Unknown command: '${1}'. Try 'freeagents help'."; exit 1 ;;
esac
LITEOF
  $SUDO chmod 755 "$CLI_BIN"
}

# Auto-start mode: auto (default) | systemd | wslconf  (env: LITELLM_BOOT_MODE)
use_systemd() {
  case "${LITELLM_BOOT_MODE:-auto}" in
    systemd) return 0 ;;
    wslconf) return 1 ;;
    *) [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 && return 0 ;;
  esac
  return 1
}

configure_autostart_and_cli() {
  log_info "[8/9] Setting up auto-start on boot + management CLI..."
  write_boot_helper
  write_management_cli

  if use_systemd; then
    # real systemd available (wsl.conf [boot] systemd=true)
    $SUDO mkdir -p /etc/systemd/system
    printf '%s\n' \
      '[Unit]' \
      'Description=LiteLLM proxy container (Docker)' \
      'After=docker.service' \
      'Requires=docker.service' \
      '' \
      '[Service]' \
      'Type=oneshot' \
      'RemainAfterExit=yes' \
      'ExecStart=/usr/local/bin/litellm-boot.sh' \
      '' \
      '[Install]' \
      'WantedBy=multi-user.target' \
      | $SUDO tee "$SYSTEMD_UNIT" >/dev/null
    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
    $SUDO systemctl enable litellm.service >/dev/null 2>&1 || true
    AUTOSTART_MODE="systemd service: litellm.service (enabled)"
  else
    # no systemd -> WSL boot command (runs as root when the distro starts)
    if ! $SUDO test -f "$WSL_CONF"; then
      printf '' | $SUDO tee "$WSL_CONF" >/dev/null
    fi
    if $SUDO grep -qF "$BOOT_LINE" "$WSL_CONF" 2>/dev/null; then
      log_ok "       Boot entry already present in ${WSL_CONF}."
    elif $SUDO grep -qE '^[[:space:]]*command[[:space:]]*=' "$WSL_CONF" 2>/dev/null; then
      log_warn "       ${WSL_CONF} already defines a custom boot command - add this line under [boot] manually:"
      log_warn "         ${BOOT_LINE}"
    else
      if $SUDO grep -qE '^[[:space:]]*\[boot\]' "$WSL_CONF" 2>/dev/null; then
        $SUDO sed -i "/^[[:space:]]*\[boot\]/a ${BOOT_LINE}" "$WSL_CONF"
      else
        printf '\n[boot]\n%s\n' "$BOOT_LINE" | $SUDO tee -a "$WSL_CONF" >/dev/null
      fi
      log_ok "       Boot command added to ${WSL_CONF}."
    fi
    AUTOSTART_MODE="/etc/wsl.conf boot command (no systemd detected)"
  fi

  log_ok "Auto-start on WSL boot: ${AUTOSTART_MODE}"
  log_ok "Management CLI installed: ${CLI_BIN}  (try: freeagents status)"
}

#-------------------------------------------------------------------------------
# Claude Code configuration on the Windows side
#-------------------------------------------------------------------------------
configure_claude_windows() {
  log_info "[9/9] Configuring Claude Code on the Windows side..."

  local win_home cc_dir
  win_home="$(get_windows_home)" || \
    die "Could not detect the Windows user profile via PowerShell."

  if [ ! -d "$win_home" ]; then
    die "Converted Windows profile path does not exist in WSL: ${win_home}"
  fi
  log_ok "Windows user profile detected: ${win_home}"

  cc_dir="${win_home}/.claude"
  CLAUDE_SETTINGS="${cc_dir}/settings.json"
  mkdir -p "$cc_dir"

  # Preserve any existing user settings before overwriting
  if [ -f "$CLAUDE_SETTINGS" ]; then
    local backup="${CLAUDE_SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$CLAUDE_SETTINGS" "$backup"
    log_warn "Existing settings.json backed up to: ${backup}"
  fi

  # Default model: first available by provider priority; fast/background
  # model: Gemini Flash when available (cheap + fast), else the default.
  local main_model="" fast_model="" fast_candidate=""
  if [ -n "$GROQ_KEY" ]; then
    [ -z "$main_model" ] && main_model="claude-gpt-oss-120b"
    [ -z "$fast_candidate" ] && fast_candidate="claude-gpt-oss-20b"
  fi
  if [ -n "$OPENROUTER_KEY" ]; then
    [ -z "$main_model" ] && main_model="claude-deepseek-v3.1"
  fi
  if [ -n "$GEMINI_KEY" ]; then
    [ -z "$main_model" ] && main_model="claude-gemini-2.0-flash"
    fast_model="claude-gemini-2.0-flash"
  fi
  if [ -n "$CEREBRAS_KEY" ]; then
    [ -z "$main_model" ] && main_model="claude-llama3.1-70b"
  fi
  if [ -n "$MISTRAL_KEY" ]; then
    [ -z "$main_model" ] && main_model="claude-codestral"
  fi
  [ -z "$fast_model" ] && fast_model="${fast_candidate:-$main_model}"
  CLAUDE_MAIN_MODEL="$main_model"
  CLAUDE_FAST_MODEL="$fast_model"

  # Claude Code talks the Anthropic Messages API; LiteLLM serves it at
  # /v1/messages. BASE_URL must NOT carry a /v1 suffix. Gateway model
  # discovery makes the /model picker list every model from the proxy.
  cat > "$CLAUDE_SETTINGS" <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:${LITELLM_PORT}",
    "ANTHROPIC_AUTH_TOKEN": "${MASTER_KEY}",
    "ANTHROPIC_MODEL": "${main_model}",
    "ANTHROPIC_SMALL_FAST_MODEL": "${fast_model}",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "${main_model}",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "${main_model}",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "${fast_model}",
    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
EOF

  log_ok "Claude Code settings written: ${CLAUDE_SETTINGS}"
  log_ok "Default model: ${main_model} | background model: ${fast_model}"
}

configure_claude_desktop_windows() {
  # The Claude DESKTOP app stores its "Configurations" (third-party gateway
  # profiles) as JSON files under %LOCALAPPDATA%\Claude-3p\configLibrary -
  # the same place the app's own "Configure Third-Party Inference" window
  # and the OmniRoute installer write to. No registry, no admin rights.
  # Skip with LITELLM_DESKTOP_CONFIG=0.
  if [ "${LITELLM_DESKTOP_CONFIG:-1}" != "1" ]; then
    DESKTOP_POLICY_STATUS="off"
    log_info "       Claude Desktop auto-config disabled (LITELLM_DESKTOP_CONFIG=0)."
    return 0
  fi
  local ps=""
  ps="$(find_powershell 2>/dev/null || true)"
  if [ -z "$ps" ]; then
    DESKTOP_POLICY_STATUS="nops"
    log_warn "       powershell.exe not found - Claude Desktop app NOT auto-configured."
    log_warn "       Manual recipe: Developer Mode > Configure Third-Party Inference."
    return 0
  fi

  log_info "       Writing the LiteLLM profile into the Claude Desktop app..."

  local local_app="" root="" lib="" profile="" meta="" deskcfg=""
  local_app="$($ps -NoProfile -Command "[Environment]::GetFolderPath('LocalApplicationData')" 2>/dev/null | tr -d '\r' | head -n1 || true)"
  if [ -n "$local_app" ]; then
    local drive letter rest
    drive="${local_app%%:*}"
    letter="$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')"
    rest="${local_app#*:}"; rest="${rest//\\//}"
    local_app="/mnt/${letter}${rest}"
  else
    local wh=""
    wh="$(get_windows_home 2>/dev/null || true)"
    [ -n "$wh" ] && local_app="${wh}/AppData/Local"
  fi
  if [ -z "$local_app" ]; then
    DESKTOP_POLICY_STATUS="failed"
    log_warn "       Could not locate %LOCALAPPDATA% - Desktop profile not written."
    return 0
  fi
  root="${local_app}/Claude-3p"
  lib="${root}/configLibrary"
  profile="${lib}/${DESKTOP_PROFILE_ID}.json"
  meta="${lib}/_meta.json"
  deskcfg="${root}/claude_desktop_config.json"
  mkdir -p "$lib" 2>/dev/null || { DESKTOP_POLICY_STATUS="failed"; log_warn "       Cannot create ${lib}"; return 0; }

  # Purge profiles written by OLDER versions of this script (non-UUID
  # ids) so the app list does not fill with duplicate entries.
  if [ -f "${lib}/litellm-free-ai-agents.json" ]; then
    rm -f "${lib}/litellm-free-ai-agents.json"
    log_info "       Removed an outdated desktop profile (old id)."
  fi

  # Model names MUST be Anthropic catalog ids (the app validates them):
  # claude-sonnet-4-5 / claude-haiku-4-5. They are aliases inside the
  # gateway config and route to the SAME free underlying models.
  cat > "$profile" <<EOF
{
  "inferenceProvider": "gateway",
  "inferenceCredentialKind": "static",
  "inferenceGatewayBaseUrl": "http://127.0.0.1:${LITELLM_PORT}",
  "inferenceGatewayApiKey": "${MASTER_KEY}",
  "inferenceGatewayAuthScheme": "bearer",
  "modelDiscoveryEnabled": true,
  "chatTabEnabled": true,
  "disableEssentialTelemetry": true,
  "disableNonessentialTelemetry": true,
  "inferenceModels": [
    { "name": "claude-sonnet-4-5", "labelOverride": "FreeAgents/LiteLLM ${CLAUDE_MAIN_MODEL#claude-}", "isFamilyDefault": true },
    { "name": "claude-haiku-4-5", "labelOverride": "FreeAgents/LiteLLM ${CLAUDE_FAST_MODEL#claude-}" }
  ]
}
EOF
  chmod 600 "$profile" 2>/dev/null || true

  # Register the profile in _meta.json (never steals an OmniRoute-applied pick)
  if command -v python3 >/dev/null 2>&1; then
    CLAUDE_META_FILE="$meta" CLAUDE_PROFILE_ID="$DESKTOP_PROFILE_ID" python3 <<'PYMETA' || true
import json, os
p = os.environ["CLAUDE_META_FILE"]; pid = os.environ["CLAUDE_PROFILE_ID"]
meta = {"appliedId": pid, "entries": []}
if os.path.exists(p):
    try:
        meta = json.load(open(p))
    except Exception:
        meta = {"appliedId": pid, "entries": []}
entries = [e for e in (meta.get("entries") or [])
           if e.get("id") != pid and e.get("id") != "litellm-free-ai-agents"]
entries.append({"id": pid, "name": "Free Agents"})
meta["entries"] = entries
cur = meta.get("appliedId")
known = {e.get("id") for e in entries}
if cur not in known or cur == pid or not cur:
    meta["appliedId"] = pid
json.dump(meta, open(p, "w"), indent=2)
PYMETA
  else
    if [ ! -f "$meta" ]; then
      printf '{\n  "appliedId": "%s",\n  "entries": [{"id": "%s", "name": "Free Agents"}]\n}\n' "$DESKTOP_PROFILE_ID" "$DESKTOP_PROFILE_ID" > "$meta"
      chmod 600 "$meta" 2>/dev/null || true
    fi
  fi
  chmod 600 "$meta" 2>/dev/null || true

  # deploymentMode=3p so the app starts in gateway mode
  if [ -f "$deskcfg" ]; then
    if command -v python3 >/dev/null 2>&1 && python3 -c "import json;json.load(open('$deskcfg'))" 2>/dev/null; then
      CLAUDE_DESK_FILE="$deskcfg" python3 <<'PYDESK' || true
import json, os
p = os.environ["CLAUDE_DESK_FILE"]
d = json.load(open(p)); d["deploymentMode"] = "3p"
json.dump(d, open(p, "w"), indent=2)
PYDESK
    else
      log_warn "       claude_desktop_config.json is not valid JSON - leaving it untouched."
    fi
  else
    printf '{\n  "deploymentMode": "3p"\n}\n' > "$deskcfg" 2>/dev/null || true
    chmod 600 "$deskcfg" 2>/dev/null || true
  fi

  # Unified in-chat labels for the OTHER saved profile too (its own
  # installer labels models with its engine name).
  for f in "${lib}"/*.json; do
    [ -e "$f" ] || break
    [ "$(basename "$f")" = "$(basename "$profile")" ] && continue
    if grep -q '"labelOverride": "OmniRoute ' "$f" 2>/dev/null; then
      sed -i 's/"labelOverride": "OmniRoute /"labelOverride": "FreeAgents\/Omni /g' "$f" 2>/dev/null || true
      log_info "       Unified the model labels of the other saved profile."
    fi
  done

  DESKTOP_POLICY_STATUS="ok"
  log_ok "       Desktop profile written (configLibrary): ${profile}"
  return 0
}

#-------------------------------------------------------------------------------
# Full Install
#-------------------------------------------------------------------------------
full_install() {
  echo
  log_info "=== FULL INSTALL: starting ==="
  echo

  check_wsl_environment                       # step 1
  install_docker                              # step 2
  configure_docker_mirrors                    # step 3
  start_docker_daemon
  collect_api_keys                            # step 4
  generate_master_key
  generate_litellm_config                     # step 5
  pull_liteLLM_image                          # step 6
  start_litellm_container                     # step 7
  wait_for_litellm
  configure_autostart_and_cli                 # step 8 (autostart + litellm CLI)

  CLAUDE_SETTINGS=""
  configure_claude_windows                    # step 9
  configure_claude_desktop_windows            # step 9b (Claude Desktop app)

  # Persist a copy of this manager so `freeagents` (bare) re-opens the menu
  mkdir -p "$FREE_AGENTS_DIR" 2>/dev/null || true
  if [ -f "$SCRIPT_PATH" ]; then
    cp -f "$SCRIPT_PATH" "$MANAGER_COPY" 2>/dev/null || true
    chmod 755 "$MANAGER_COPY" 2>/dev/null || true
  fi

  print_install_success "$CLAUDE_SETTINGS"
}

print_install_success() {
  local oc_file="$1"
  echo
  echo -e "${C_GREEN}${C_BOLD}================================================================="
  echo "  INSTALLATION COMPLETED SUCCESSFULLY!"
  echo -e "=================================================================${C_NC}"
  echo
  echo "  LiteLLM endpoint (from Windows) : http://127.0.0.1:${LITELLM_PORT}/v1"
  echo
  echo -e "${C_BOLD}  ADMIN PANEL (UI) - open in the WINDOWS browser:${C_NC}"
  echo "    URL       : http://127.0.0.1:${LITELLM_PORT}/ui"
  echo "    Username  : admin"
  echo "    Password  : ${MASTER_KEY}"
  echo "    (the dashboard password IS the master key - no separate password exists)"
  echo "    saved to  : ${LITELLM_CRED_FILE}"
  echo
  echo "  Master key (also saved to)      : ${LITELLM_KEYFILE}"
  echo "  Master key                      : ${MASTER_KEY}"
  echo "  LiteLLM config file             : ${LITELLM_CONFIG}"
  echo "  Claude Code settings (Windows)  : ${oc_file}"
  echo "  Container name                  : ${CONTAINER_NAME}"
  echo "  Auto-start on WSL boot          : ${AUTOSTART_MODE}"
  echo "  Windows proxy routing           : ${WIN_PROXY_URL:-disabled}"
  if [ "$UI_DB_ENABLED" = "1" ]; then
    echo "  Admin UI database               : ${DB_CONTAINER} (postgres, restart: unless-stopped)"
  else
    echo "  Admin UI database               : disabled (UI login will NOT work; Claude Code chat is fine)"
  fi
  echo
  echo -e "${C_BOLD}  MANAGEMENT COMMANDS (any terminal):${C_NC}"
  echo "    freeagents up | down | restart | status | logs | uninstall"
  echo "    freeagents          (re-opens this menu)"
  echo
  echo -e "${C_BOLD}  USEFUL COMMANDS (run inside WSL):${C_NC}"
  echo "    Live logs        : ${SUDO} docker logs -f ${CONTAINER_NAME}"
  echo "    Restart proxy    : ${SUDO} docker restart ${CONTAINER_NAME}"
  echo "    Stop proxy       : ${SUDO} docker stop ${CONTAINER_NAME}"
  echo "    Start proxy      : ${SUDO} docker start ${CONTAINER_NAME}"
  echo "    Test endpoint    : curl -s http://127.0.0.1:${LITELLM_PORT}/v1/models \\"
  echo "                         -H \"Authorization: Bearer ${MASTER_KEY}\""
  local rerun="bash \"${SCRIPT_PATH}\""
  case "$SCRIPT_PATH" in
    /dev/fd/*|/dev/stdin|/dev/fd*)
      rerun='bash <(curl -fsSL https://raw.githubusercontent.com/im-JvD/FreeAI-Agents/main/setup.sh)' ;;
  esac
  echo "    Re-run this tool : ${rerun}"
  echo
  echo -e "${C_BOLD}  NEXT STEPS (on WINDOWS):${C_NC}"
  echo "    1. Install Claude Code (once):"
  echo "       irm https://claude.ai/install.ps1 | iex"
  echo "       (or: npm install -g @anthropic-ai/claude-code)"
  echo "    2. Open a NEW terminal, cd into any project folder."
  echo "    3. Run: claude"
  echo "    4. Type /model to pick any proxy model (gateway discovery is on;"
  echo "       needs Claude Code v2.1.129+). Default model preconfigured."
  echo ""
  echo -e "${C_BOLD}  CLAUDE DESKTOP APP (Cowork / Code inside the desktop app):${C_NC}"
  case "$DESKTOP_POLICY_STATUS" in
    ok)
      echo "    ALREADY CONFIGURED automatically (registry policy:"
      echo "    HKCU\\SOFTWARE\\Policies\\Claude). Just (re)start the app -"
      echo "    the claude-* gateway models appear in Cowork's model picker."
      ;;
    failed)
      echo "    AUTO-CONFIG FAILED - Windows denied the registry write (see WARN above)."
      echo "    30-second manual setup inside the app:"
      echo "      Help > Troubleshooting > Enable Developer Mode, then"
      echo "      Developer > Configure Third-Party Inference > New configuration"
      echo "      Name: LiteLLM | Gateway base URL: http://127.0.0.1:${LITELLM_PORT}"
      echo "      Gateway API key: the Master Key above | Auth scheme: bearer | Apply"
      ;;
    off)
      echo "    NOT auto-configured (LITELLM_DESKTOP_CONFIG=0). Manual setup:"
      echo "      Developer Mode > Configure Third-Party Inference: gateway,"
      echo "      http://127.0.0.1:${LITELLM_PORT}, Master Key, bearer."
      ;;
    *)
      echo "    Could not auto-configure (powershell.exe not found). Manual setup:"
      echo "      Developer Mode > Configure Third-Party Inference: gateway,"
      echo "      http://127.0.0.1:${LITELLM_PORT}, Master Key, bearer."
      ;;
  esac
  echo
  echo "  NOTE: If you ever run 'wsl --shutdown', start Docker again with:"
  echo "        sudo service docker start   (auto if systemd is enabled)"
  echo
  log_ok "Done. Happy coding!"
}

#-------------------------------------------------------------------------------
# Full Uninstall
#-------------------------------------------------------------------------------
full_uninstall() {
  echo
  log_info "=== FULL UNINSTALL: starting ==="
  echo

  # 1) Remove the LiteLLM container
  if command -v docker >/dev/null 2>&1 && \
     $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    log_info "Stopping and removing container '${CONTAINER_NAME}'..."
    $SUDO docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    $SUDO docker rm "$CONTAINER_NAME"   >/dev/null 2>&1 || true
    log_ok "Container removed."
  else
    log_warn "No container named '${CONTAINER_NAME}' found - nothing to remove."
  fi

  # 1b) Remove the Admin UI database container + docker network
  if command -v docker >/dev/null 2>&1; then
    if $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_CONTAINER"; then
      $SUDO docker stop "$DB_CONTAINER" >/dev/null 2>&1 || true
      $SUDO docker rm "$DB_CONTAINER"   >/dev/null 2>&1 || true
      log_ok "Removed Admin UI database container: ${DB_CONTAINER}"
    fi
    $SUDO docker network rm "$DB_NETWORK" >/dev/null 2>&1 || true
  fi

  # 2) Remove the LiteLLM config folder in Linux
  if [ -d "$LITELLM_DIR" ]; then
    rm -rf "$LITELLM_DIR"
    log_ok "Removed LiteLLM config folder: ${LITELLM_DIR}"
  else
    log_warn "LiteLLM config folder not found: ${LITELLM_DIR}"
  fi

  # 3) Remove Claude Code settings on the Windows side (restore backup if any)
  if find_powershell >/dev/null 2>&1; then
    local win_home cc_file
    win_home="$(get_windows_home)" || win_home=""
    if [ -n "$win_home" ] && [ -d "$win_home" ]; then
      cc_file="${win_home}/.claude/settings.json"
      if [ -f "$cc_file" ]; then
        rm -f "$cc_file"
        log_ok "Removed Claude Code settings: ${cc_file}"
      else
        log_warn "Claude Code settings not found: ${cc_file}"
      fi
      local newest_bak
      newest_bak="$(ls -1t "${win_home}/.claude/settings.json.bak."* 2>/dev/null | head -1 || true)"
      if [ -n "$newest_bak" ] && [ -f "$newest_bak" ]; then
        cp "$newest_bak" "$cc_file"
        log_ok "Restored pre-install backup: ${newest_bak}"
      fi
    else
      log_warn "Could not resolve the Windows profile. Delete this file manually:"
      log_warn "  %USERPROFILE%\\.claude\\settings.json"
    fi
  else
    log_warn "powershell.exe not found. Delete this file manually:"
    log_warn "  %USERPROFILE%\\.claude\\settings.json"
  fi

  # 3b) Remove the Claude Desktop gateway policy (HKCU registry) and restore
  #     the pre-install backup of that policy key if one exists
  local ps_bin="" reg_bak_win="" win_home2="" newest_reg_bak
  ps_bin="$(find_powershell 2>/dev/null || true)"
  if [ -n "$ps_bin" ]; then
    win_home2="$(get_windows_home 2>/dev/null || true)"
    if [ -n "$win_home2" ] && [ -d "$win_home2" ]; then
      newest_reg_bak="$(ls -1t "${win_home2}/.claude/claude_desktop_policy.reg.bak."* 2>/dev/null | head -1 || true)"
      if [ -n "$newest_reg_bak" ] && [ -f "$newest_reg_bak" ]; then
        reg_bak_win="$(wsl_to_win_path "$newest_reg_bak")"
      fi
    fi
    "$ps_bin" -NoProfile -Command "Remove-ItemProperty -Path 'HKCU:\\SOFTWARE\\Policies\\Claude' -Name 'inferenceProvider' -ErrorAction SilentlyContinue; Remove-ItemProperty -Path 'HKCU:\\SOFTWARE\\Policies\\Claude' -Name 'inferenceGatewayBaseUrl' -ErrorAction SilentlyContinue; Remove-ItemProperty -Path 'HKCU:\\SOFTWARE\\Policies\\Claude' -Name 'inferenceCredentialKind' -ErrorAction SilentlyContinue; Remove-ItemProperty -Path 'HKCU:\\SOFTWARE\\Policies\\Claude' -Name 'inferenceGatewayAuthScheme' -ErrorAction SilentlyContinue; Remove-ItemProperty -Path 'HKCU:\\SOFTWARE\\Policies\\Claude' -Name 'inferenceGatewayApiKey' -ErrorAction SilentlyContinue" >/dev/null 2>&1 \
      && log_ok "Removed the legacy Claude Desktop registry policy" \
      || log_warn "Could not clean the legacy Claude Desktop policy (registry)"
          local la="" prof="" mta=""
          la="$("$ps_bin" -NoProfile -Command "[Environment]::GetFolderPath('LocalApplicationData')" 2>/dev/null | tr -d '\r' | head -n1 || true)"
          if [ -n "$la" ]; then
            local ld llr
            ld="${la%%:*}"; llr="$(printf '%s' "$ld" | tr '[:upper:]' '[:lower:]')"; la="${la#*:}"; la="${la//\\//}"
            la="/mnt/${llr}${la}"
            prof="${la}/Claude-3p/configLibrary/${DESKTOP_PROFILE_ID}.json"
            mta="${la}/Claude-3p/configLibrary/_meta.json"
            if [ -f "$prof" ]; then
              rm -f "$prof"
              log_ok "Removed the Claude Desktop profile: ${prof}"
            fi
            if [ -f "$mta" ] && command -v python3 >/dev/null 2>&1; then
              CLAUDE_META_FILE="$mta" CLAUDE_PROFILE_ID="$DESKTOP_PROFILE_ID" python3 <<'PYMETA' || true
    import json, os
    p = os.environ["CLAUDE_META_FILE"]; pid = os.environ["CLAUDE_PROFILE_ID"]
    try:
        meta = json.load(open(p))
    except Exception:
        raise SystemExit(0)
    entries = [e for e in (meta.get("entries") or []) if e.get("id") != pid]
    meta["entries"] = entries
    if meta.get("appliedId") == pid:
        meta["appliedId"] = entries[0]["id"] if entries else None
    json.dump(meta, open(p, "w"), indent=2)
PYMETA
            fi
          fi
  fi

  # 4) Remove boot persistence (systemd service / wsl.conf boot entry / helper)
  if $SUDO test -f "$SYSTEMD_UNIT"; then
    $SUDO rm -f "$SYSTEMD_UNIT"
    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
    log_ok "Removed systemd service: ${SYSTEMD_UNIT}"
  fi
  if $SUDO test -f "$BOOT_HELPER"; then
    $SUDO rm -f "$BOOT_HELPER"
    log_ok "Removed boot helper: ${BOOT_HELPER}"
  fi
  if $SUDO test -f "$WSL_CONF" && $SUDO grep -qF "$BOOT_LINE" "$WSL_CONF" 2>/dev/null; then
    $SUDO sed -i "\|^${BOOT_LINE}\$|d" "$WSL_CONF"
    log_ok "Removed boot entry from ${WSL_CONF}"
  fi

  # 5) Remove the management CLI
  if $SUDO test -f "$CLI_BIN"; then
    $SUDO rm -f "$CLI_BIN"
    log_ok "Removed management CLI: ${CLI_BIN}"
  fi

  echo
  echo -e "${C_GREEN}${C_BOLD}================================================================="
  echo "  UNINSTALL COMPLETED SUCCESSFULLY!"
  echo -e "=================================================================${C_NC}"
  echo
  echo "  Removed:"
  echo "    - Docker container : ${CONTAINER_NAME}"
  echo "    - UI database      : ${DB_CONTAINER} (postgres) + network ${DB_NETWORK}"
  echo "    - Linux folder     : ${LITELLM_DIR}  (config.yaml + master key)"
  echo "    - Windows file     : ~/.claude/settings.json"
  echo "    - Boot persistence : systemd service / wsl.conf boot entry / helper"
  echo "    - Management CLI   : ${CLI_BIN}"
  echo
  echo "  Kept (on purpose):"
  echo "    - Docker Engine itself and /etc/docker/daemon.json (mirrors)"
  echo
  log_ok "Done."
}

#-------------------------------------------------------------------------------
# OmniRoute engine (downloaded installer, cached under ~/.free-ai-agents)
#-------------------------------------------------------------------------------
ensure_omni_script() {
  if [ -s "$OMNI_SCRIPT" ] && bash -n "$OMNI_SCRIPT" 2>/dev/null; then
    return 0
  fi
  mkdir -p "$FREE_AGENTS_DIR" 2>/dev/null || true
  local url tmp="${OMNI_SCRIPT}.dl" ok=1
  for url in "${OMNI_RAW_URLS[@]}"; do
    log_info "       Downloading the OmniRoute installer..."
    if curl -fsSL --max-time 120 --retry 2 "$url" -o "$tmp" 2>/dev/null \
       && bash -n "$tmp" 2>/dev/null; then
      ok=0
      break
    fi
  done
  if [ "$ok" -ne 0 ]; then
    rm -f "$tmp" 2>/dev/null || true
    log_warn "       Could not download the OmniRoute installer (network?)."
    return 1
  fi
  mv "$tmp" "$OMNI_SCRIPT"
  chmod +x "$OMNI_SCRIPT" 2>/dev/null || true
  log_ok "       OmniRoute installer ready: ${OMNI_SCRIPT}"
  return 0
}

omni_installed() { [ -s "$OMNI_SCRIPT" ]; }

omni_delegate() { # $@ = args for the secondary gateway manager
  omni_installed || { log_warn "Secondary gateway: not installed (item 1 installs it)."; return 0; }
  log_info "--- secondary gateway ---"
  bash "$OMNI_SCRIPT" "$@"
}

omni_quiet() { # <label> <args...> - run the secondary manager WITHOUT its logs
  local label="$1"; shift
  local logdir="${FREE_AGENTS_DIR}/logs"
  mkdir -p "$logdir" 2>/dev/null || true
  local lg="${logdir}/secondary-$(printf '%s' "$1" | tr -cd 'a-z').log"
  # FORCE_NO_TTY + </dev/null: the installer must NEVER sit on an
  # invisible interactive prompt (it would look like a hang).
  if OMNIRoute_FORCE_NO_TTY=1 bash "$OMNI_SCRIPT" "$@" >"$lg" 2>&1 </dev/null; then
    log_ok "${label} - done.  (details: ${lg})"
  else
    log_warn "${label} - FAILED. Last lines:"
    tail -n 15 "$lg" 2>/dev/null || true
    log_warn "Full log: ${lg}"
  fi
}

omni_install_flow() {
  # Install the secondary gateway REUSING the keys and the Windows proxy
  # setting that were (or will be) collected exactly ONCE by this manager.
  ensure_omni_script || return 1
  log_info "=== SECONDARY ENGINE: installing with the SAME keys & proxy ==="

  # Seed its saved-keys file so its installer does NOT ask again.
  if [ -n "${GROQ_KEY:-}${OPENROUTER_KEY:-}${GEMINI_KEY:-}${CEREBRAS_KEY:-}${MISTRAL_KEY:-}" ]; then
    {
      echo "# Provider API keys (managed by setup.sh)"
      [ -n "${GROQ_KEY:-}" ]       && printf 'GROQ_KEY=%q\n'       "$GROQ_KEY"
      [ -n "${OPENROUTER_KEY:-}" ] && printf 'OPENROUTER_KEY=%q\n' "$OPENROUTER_KEY"
      [ -n "${GEMINI_KEY:-}" ]     && printf 'GEMINI_KEY=%q\n'     "$GEMINI_KEY"
      [ -n "${CEREBRAS_KEY:-}" ]   && printf 'CEREBRAS_KEY=%q\n'   "$CEREBRAS_KEY"
      [ -n "${MISTRAL_KEY:-}" ]    && printf 'MISTRAL_KEY=%q\n'    "$MISTRAL_KEY"
    } > "$SECONDARY_KEYS_FILE"
    chmod 600 "$SECONDARY_KEYS_FILE" 2>/dev/null || true
    log_ok "Provider tokens handed over: ${SECONDARY_KEYS_FILE}"
  fi

  local use_proxy=0
  [ -n "$WIN_PROXY_URL" ] && use_proxy=1
  local ilog="${FREE_AGENTS_DIR}/logs/secondary-install.log"
  mkdir -p "${FREE_AGENTS_DIR}/logs" 2>/dev/null || true
  log_info "Installing the secondary gateway (this can take a few minutes)..."
  echo "    Watch live progress in a second terminal:  tail -f ${ilog}"
  local rc=0 opid="" hpid=""
  OMNIRoute_GROQ_KEY="${GROQ_KEY:-}" \
  OMNIRoute_OPENROUTER_KEY="${OPENROUTER_KEY:-}" \
  OMNIRoute_GEMINI_KEY="${GEMINI_KEY:-}" \
  OMNIRoute_CEREBRAS_KEY="${CEREBRAS_KEY:-}" \
  OMNIRoute_MISTRAL_KEY="${MISTRAL_KEY:-}" \
  OMNIRoute_FORCE_NO_TTY=1 \
  OMNIRoute_USE_PROXY="$use_proxy" \
  OMNIRoute_PROXY_URL="${WIN_PROXY_URL}" \
    timeout 1800 bash "$OMNI_SCRIPT" --install >"$ilog" 2>&1 </dev/null &
  opid=$!
  # heartbeat: one dot every 3s so the wait is visibly alive
  { while kill -0 "$opid" 2>/dev/null; do printf '.'; sleep 3; done; } &
  hpid=$!
  if wait "$opid"; then rc=0; else rc=$?; fi
  kill "$hpid" 2>/dev/null || true
  wait "$hpid" 2>/dev/null || true
  printf '\n'
  if [ "$rc" -eq 0 ]; then
    log_ok "Secondary gateway installed and activated."
  elif [ "$rc" -eq 124 ]; then
    log_warn "Secondary gateway installer TIMED OUT (30 min). Last lines:"
    tail -n 15 "$ilog" 2>/dev/null || true
    log_warn "Full log: ${ilog}"
    return 1
  else
    log_warn "Secondary gateway installer FAILED. Last lines:"
    tail -n 15 "$ilog" 2>/dev/null || true
    log_warn "Full log: ${ilog}"
    return 1
  fi
  echo -e "${C_BOLD}  SECONDARY GATEWAY REPORT:${C_NC}"
  echo "    Dashboard : http://127.0.0.1:20128"
  local pw=""
  if [ -f "${HOME}/omniroute-data/.env" ]; then
    pw="$(grep -E '^INITIAL_PASSWORD=' "${HOME}/omniroute-data/.env" 2>/dev/null | cut -d= -f2- || true)"
  fi
  if [ -n "$pw" ]; then
    echo "    Password  : ${pw}   (username: admin)"
  else
    echo "    Password  : see ${HOME}/omniroute-data/.env (INITIAL_PASSWORD)"
  fi
  echo "    Data dir  : ${HOME}/omniroute-data"
  return 0
}

#-------------------------------------------------------------------------------
# UPDATE: re-download this script from the repo, then full reinstall
#-------------------------------------------------------------------------------
cmd_update() {
  printf "   Re-download the script AND run the full reinstall? Keys and the"
  printf "   Windows proxy setting are KEPT. Continue? [y/N]: "
  local answer=""
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|Yes|YES) : ;;
    *) log_info "Update cancelled."; return 0 ;;
  esac
  log_info "=== UPDATE: downloading the latest ${FREE_AGENTS_VERSION:-} script from the repo ==="
  mkdir -p "$FREE_AGENTS_DIR" 2>/dev/null || true
  local url tmp="${FREE_AGENTS_DIR}/setup.sh.new" ok=1
  for url in "${SELF_RAW_URLS[@]}"; do
    if curl -fsSL --max-time 120 --retry 2 "$url" -o "$tmp" 2>/dev/null; then
      ok=0
      break
    fi
  done
  if [ "$ok" -ne 0 ]; then
    log_warn "Update FAILED - could not download the script (network)."
    log_warn "Keeping the current version."
    return 1
  fi
  if ! bash -n "$tmp" 2>/dev/null; then
    log_warn "Downloaded script failed the syntax check - keeping the current version."
    rm -f "$tmp"
    return 1
  fi
  if cmp -s "$tmp" "${SCRIPT_PATH}" 2>/dev/null; then
    log_ok "Script is already up to date."
    rm -f "$tmp"
  else
    mv "$tmp" "${SCRIPT_PATH}"
    chmod +x "${SCRIPT_PATH}" 2>/dev/null || true
    log_ok "Script updated: ${SCRIPT_PATH}"
  fi
  log_info "=== Re-running the FULL INSTALL (keys & proxy are KEPT) ==="
  full_install
}

#-------------------------------------------------------------------------------
# CONFIG MANAGER: proxy on/off + key editing + Claude re-config
#-------------------------------------------------------------------------------
apply_proxy_to_litellm() {
  # Recreate the primary gateway container with the CURRENT proxy setting
  # (WIN_PROXY_URL), keeping every stored provider key.
  if ! main_container_exists; then
    log_warn "Primary gateway is not installed (item 1 installs it)."
    return 1
  fi
  GROQ_KEY=""; OPENROUTER_KEY=""; GEMINI_KEY=""; CEREBRAS_KEY=""; MISTRAL_KEY=""
  if read_existing_keys_from_container; then
    GROQ_KEY="$EXISTING_GROQ"; OPENROUTER_KEY="$EXISTING_OPENROUTER"
    GEMINI_KEY="$EXISTING_GEMINI"; CEREBRAS_KEY="$EXISTING_CEREBRAS"
    MISTRAL_KEY="$EXISTING_MISTRAL"
  fi
  [ -s "$LITELLM_KEYFILE" ] && MASTER_KEY="$(tr -d '\n' < "$LITELLM_KEYFILE")"
  build_docker_env_args
  remove_existing_container
  start_litellm_container
  wait_for_litellm
  log_ok "Primary gateway recreated. Proxy is now: ${WIN_PROXY_URL:-OFF (direct)}"
  return 0
}

configure_windows_proxy_force() {
  # Ask for a Windows proxy address unconditionally (Config Manager ON).
  local detected="" addr="" code=""
  detected="$(detect_windows_ip || true)"
  local suggestion=""
  [ -n "$detected" ] && suggestion="${detected}:7890"
  if [ -n "$suggestion" ]; then
    printf "       Proxy address as IP:PORT seen from WSL [%s]: " "$suggestion"
  else
    printf "       Proxy address as IP:PORT seen from WSL (e.g. 172.20.144.1:7890): "
  fi
  read -r addr || addr=""
  [ -z "$addr" ] && addr="$suggestion"
  [ -z "$addr" ] && { log_warn "No address entered."; return 0; }
  case "$addr" in
    http://*|https://*|socks5://*|socks5h://*) : ;;
    *) addr="http://${addr}" ;;
  esac
  code=""
  if command -v curl >/dev/null 2>&1; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -x "$addr" "https://api.groq.com/openai/v1/models" 2>/dev/null || true)"
  fi
  if [ -n "$code" ] && [ "$code" != "000" ]; then
    log_ok "       Proxy reachable - test call returned HTTP ${code}."
  else
    log_warn "       Test call through the proxy FAILED (code ${code:-none})."
    printf "       Save it anyway? [y/N]: "
    local a2=""
    read -r a2 || a2=""
    case "$a2" in
      y|Y|yes|Yes|YES) : ;;
      *) log_warn "Proxy not saved."; return 0 ;;
    esac
  fi
  WIN_PROXY_URL="$addr"
  mkdir -p "$LITELLM_DIR"
  printf '%s\n' "$WIN_PROXY_URL" > "$WIN_PROXY_FILE"
  chmod 600 "$WIN_PROXY_FILE" 2>/dev/null || true
}

switch_desktop_profile() {
  # Point the Claude Desktop app at a different saved configuration
  # (the UI can refuse to Apply; this edits _meta.json directly).
  local ps=""
  ps="$(find_powershell 2>/dev/null || true)"
  if [ -z "$ps" ]; then
    log_warn "powershell.exe not found - cannot locate the desktop profile library."
    return 1
  fi
  local local_app=""
  local_app="$($ps -NoProfile -Command "[Environment]::GetFolderPath('LocalApplicationData')" 2>/dev/null | tr -d '\r' | head -n1 || true)"
  if [ -n "$local_app" ]; then
    local drive letter rest
    drive="${local_app%%:*}"
    letter="$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')"
    rest="${local_app#*:}"; rest="${rest//\\//}"
    local_app="/mnt/${letter}${rest}"
  fi
  local meta="${local_app}/Claude-3p/configLibrary/_meta.json"
  if [ ! -f "$meta" ]; then
    log_warn "No desktop profile library found at ${local_app}/Claude-3p/configLibrary"
    return 1
  fi
  CLAUDE_META_FILE="$meta" CLAUDE_PROFILE_ID="$DESKTOP_PROFILE_ID" python3 <<'PYSW' || true
import json, os, sys
p = os.environ["CLAUDE_META_FILE"]; mine = os.environ["CLAUDE_PROFILE_ID"]
try:
    m = json.load(open(p))
except Exception:
    print("meta file is not valid JSON"); sys.exit(1)
es = m.get("entries") or []
others = [e.get("id") for e in es if e.get("id") and e.get("id") != mine]
if not others:
    print("no other saved desktop profile found"); sys.exit(1)
m["appliedId"] = others[0]
json.dump(m, open(p, "w"), indent=2)
print("switched-applied-id")
PYSW
  log_ok "Active desktop profile switched to the other saved configuration."
  log_warn "Fully QUIT the Claude Desktop app (tray icon -> Quit), then start it again."
  return 0
}

config_manager() {
  while true; do
    echo
    echo -e "${C_CYAN}${C_BOLD}  --- CONFIG MANAGER ---${C_NC}"
    echo -e "   ${C_GREEN}1${C_NC} - Gateway proxy ${C_YELLOW}ON${C_NC}   (route ALL engine traffic via your Windows proxy)"
    echo -e "   ${C_GREEN}2${C_NC} - Gateway proxy ${C_YELLOW}OFF${C_NC}  (direct connections)"
    echo -e "   ${C_GREEN}3${C_NC} - Re-enter provider tokens (applied to BOTH engines)"
    echo -e "   ${C_GREEN}4${C_NC} - Re-apply Claude configs (CLI settings.json + desktop profile)"
    echo -e "   ${C_GREEN}5${C_NC} - Switch the ACTIVE desktop profile (Free Agents / other)"
    echo -e "   ${C_GREEN}0${C_NC} - Back"
    local c=""
    read -r -p "   Config choice: " c || c="0"
    echo
    case "$c" in
      1)
        configure_windows_proxy_force
        if [ -n "$WIN_PROXY_URL" ]; then
          apply_proxy_to_litellm
          if omni_installed; then
            OMNIRoute_USE_PROXY=1 OMNIRoute_PROXY_URL="$WIN_PROXY_URL" \
              omni_quiet "Secondary gateway: proxy ON" --proxy on
          fi
        fi
        ;;
      2)
        rm -f "$WIN_PROXY_FILE" 2>/dev/null || true
        WIN_PROXY_URL=""
        log_ok "Windows proxy disabled (direct connections)."
        apply_proxy_to_litellm
        if omni_installed; then
          OMNIRoute_USE_PROXY=0 omni_quiet "Secondary gateway: proxy OFF" --proxy off
        fi
        ;;
      3)
        log_info "Re-entering provider tokens (proxy setting is KEPT)..."
        LITELLM_FORCE_REKEY=1 full_install
        if omni_installed; then
          log_info "Applying the same tokens to the secondary gateway..."
          omni_install_flow
        fi
        ;;
      4)
        CLAUDE_SETTINGS=""
        configure_claude_windows
        configure_claude_desktop_windows
        ;;
      5)
        switch_desktop_profile
        ;;
      0|q|Q) return 0 ;;
      *) log_warn "Invalid choice: '${c}'." ;;
    esac
  done
}

#-------------------------------------------------------------------------------
# Interactive menu (Free AI Agents)
#-------------------------------------------------------------------------------
show_menu() {
  echo
  echo -e "${C_BLUE}${C_BOLD}================================================================="
  echo -e "=================================================================${C_NC}"
  echo -e "            ${C_GREEN}${C_BOLD}Free AI Agents${C_NC}${C_GREEN}  |  Local AI Gateway Manager${C_NC}"
  echo -e "            ${C_YELLOW}BOT Version [ ${FREE_AGENTS_VERSION} ]${C_NC}"
  echo -e "${C_BLUE}${C_BOLD}================================================================="
  echo -e "=================================================================${C_NC}"
  echo
  echo -e "   ${C_GREEN}1${C_NC} - ${C_YELLOW}Install${C_NC}  ( LiteLLM / OmniRoute / Both )"
  echo -e "   ${C_GREEN}2${C_NC} - Start / Restart"
  echo -e "   ${C_GREEN}3${C_NC} - Stop"
  echo -e "   ${C_GREEN}4${C_NC} - ${C_YELLOW}Update${C_NC} ( re-download script + full reinstall, keeps keys & proxy )"
  echo -e "   ${C_GREEN}5${C_NC} - Show Status"
  echo -e "   ${C_GREEN}6${C_NC} - ${C_RED}Remove${C_NC} ( Full wipe )"
  echo -e "   ${C_GREEN}7${C_NC} - Show Live Logs"
  echo -e "   ${C_GREEN}8${C_NC} - ${C_CYAN}Config Manager${C_NC} ( proxy on/off - edit tokens - re-apply Claude config )"
  echo -e "   ${C_GREEN}0${C_NC} - ${C_BOLD}Exit${C_NC} ( CTRL + C )"
  echo
}

choose_and_install() {
  echo
  echo -e "${C_BOLD}   Which engine(s) do you want to install?${C_NC}"
  echo -e "     ${C_GREEN}1${C_NC} - ${C_BOLD}LiteLLM${C_NC} proxy   (Docker, port ${LITELLM_PORT})   [default]"
  echo -e "     ${C_GREEN}2${C_NC} - ${C_BOLD}OmniRoute${C_NC}        (Docker/Node, port 20128)"
  echo -e "     ${C_GREEN}3${C_NC} - ${C_BOLD}Both${C_NC}"
  local c=""
  read -r -p "   Engine choice [1/2/3]: " c || c="1"
  echo
  case "$c" in
    2)
      omni_install_flow
      ;;
    3)
      full_install
      log_ok "LiteLLM engine ready - installing OmniRoute next..."
      omni_install_flow
      ;;
    *)
      full_install
      ;;
  esac
}

main_container_exists() {
  $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"
}

main_container_running() {
  $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"
}

eng_start() {
  log_info "=== START / RESTART ==="
  if main_container_exists; then
    if main_container_running; then
      $SUDO docker restart "$CONTAINER_NAME" >/dev/null
    else
      $SUDO docker start "$CONTAINER_NAME" >/dev/null
    fi
    wait_for_litellm
    log_ok "Primary gateway is up: http://127.0.0.1:${LITELLM_PORT}"
  else
    log_warn "Primary gateway is not installed (item 1 installs it)."
  fi
  if omni_installed; then
    omni_quiet "Secondary gateway: restart" --restart
  fi
}

eng_stop() {
  log_info "=== STOP ==="
  if main_container_exists; then
    $SUDO docker stop "$CONTAINER_NAME" >/dev/null
    log_ok "Primary gateway stopped."
  else
    log_warn "Primary gateway is not installed."
  fi
  if omni_installed; then
    omni_quiet "Secondary gateway: stop" --down
  fi
}

eng_status() {
  echo
  log_info "=== PRIMARY GATEWAY (port ${LITELLM_PORT}) ==="
  if main_container_exists; then
    if main_container_running; then
      echo "  container : running"
    else
      echo "  container : STOPPED"
    fi
    local hc=""
    hc="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${LITELLM_PORT}/health/liveliness" 2>/dev/null || true)"
    echo "  health    : HTTP ${hc:-none}  (http://127.0.0.1:${LITELLM_PORT})"
    echo "  dashboard : http://127.0.0.1:${LITELLM_PORT}/ui"
    echo "  config    : ${LITELLM_CONFIG}"
    echo "  try       : freeagents restart | freeagents logs | freeagents doctor"
  else
    echo "  not installed"
  fi
  echo
  log_info "=== SECONDARY GATEWAY (port 20128) ==="
  if omni_installed; then
    local sc=""
    sc="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:20128/" 2>/dev/null || true)"
    if [ -n "$sc" ] && [ "$sc" != "000" ]; then
      echo "  status    : responding (HTTP ${sc})"
    else
      echo "  status    : installed, NOT responding (menu item 2 starts it)"
    fi
    echo "  dashboard : http://127.0.0.1:20128"
  else
    echo "  not installed"
  fi
}

eng_remove() {
  log_info "=== REMOVE (FULL WIPE) ==="
  full_uninstall
  if omni_installed; then
    omni_quiet "Secondary gateway: remove" --uninstall --yes
  fi
}

eng_logs() {
  local c=""
  if omni_installed; then
    echo -e "   Logs for:  ${C_GREEN}1${C_NC} - Primary gateway   ${C_GREEN}2${C_NC} - Secondary gateway"
    read -r -p "   Choice [1/2]: " c || c="1"
  fi
  case "$c" in
    2) omni_delegate --logs ;;
    *)
      echo "Following the primary gateway logs (Ctrl+C to exit)..."
      $SUDO docker logs -f --tail 100 "$CONTAINER_NAME"
      ;;
  esac
}

menu_loop() {
  local CHOICE=""
  while true; do
    show_menu
    read -r -p "   Enter your choice: " CHOICE || { echo; log_info "Bye!"; exit 0; }
    echo
    case "$CHOICE" in
      1) choose_and_install ;;
      2) eng_start ;;
      3) eng_stop ;;
      4) cmd_update ;;
      5) eng_status ;;
      6) eng_remove ;;
      7) eng_logs ;;
      8) config_manager ;;
      0|q|Q) log_info "Bye!"; exit 0 ;;
      *) log_warn "Invalid choice: '${CHOICE}'. Pick 0-8." ;;
    esac
  done
}

main() {
  menu_loop
}

main "$@"
