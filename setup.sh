#!/usr/bin/env bash
#===============================================================================
#
#   Free AI Agents  |  Unified Local AI Gateway Installer & Manager
#   for WSL2 Ubuntu  -  LiteLLM + OmniRoute  ->  Claude Code / Claude Desktop
#
#   This is the SINGLE unified installer that replaces the two older
#   per-gateway scripts (the LiteLLM-only and the OmniRoute-only installers).
#   It installs, configures, wires and manages BOTH gateways, and exposes
#   exactly one management command:  freeagents
#
#   Engines
#     - LiteLLM   : Docker container, port 4000, Admin UI, Postgres UI DB
#     - OmniRoute  : official npm package, port 20128 (dashboard + OpenAI API)
#
#   What it does
#     - installs Docker from the Ubuntu apt repo (docker.io) with Iranian
#       registry mirrors for sanctioned networks
#     - collects provider API keys ONCE and applies them to BOTH gateways
#     - exposes ONE branded model per gateway to Claude:
#         LiteLLM  -> model id "claude-freeagents"   label "FreeAgents/LiteLLM"
#         OmniRoute-> model id "claude-freeagents"   label "FreeAgents/Omni"
#       (LiteLLM: a single model group with every provider as a deployment +
#        router retries/failover; OmniRoute: a single routing combo)
#     - writes the Claude Code settings (deep merge, unrelated keys preserved)
#       and the Claude Desktop third-party-inference profiles
#     - auto-start on WSL boot (systemd unit, else /etc/wsl.conf boot command)
#     - management:  freeagents up|down|restart|status|logs|doctor|credentials|
#                    update|uninstall   +  bare "freeagents" opens the menu
#
#   Usage (run WITHOUT sudo - the script escalates where needed):
#     bash setup.sh
#
#   Self-update source: THIS repository only (im-JvD/FreeAI-Agents).
#
#===============================================================================
#-----------------------------------------------------------------------------
# CRLF self-heal: if this file was saved with Windows line endings (CRLF),
# bash fails with "set: pipefail: invalid option name".
# The guard below is a deliberate SINGLE-line simple command (CRLF-safe):
# it detects CR bytes in this file and re-executes a stripped copy through
# process substitution.
#-----------------------------------------------------------------------------
[ -f "$0" ] && grep -q $'\r' "$0" && exec bash <(tr -d '\r' < "$0") "$@" # CR-safe

set -euo pipefail

#-------------------------------------------------------------------------------
# Constants
#-------------------------------------------------------------------------------
FREE_AGENTS_VERSION="0.0.4"
REPO="im-JvD/FreeAI-Agents"

# THE single model id handed to Claude. It must start with "claude" so that
# Claude Code's gateway model discovery shows it in the /model picker.
MODEL_ID="claude-freeagents"
# Human readable brands (Claude Desktop labelOverride).
LABEL_LITELLM="FreeAgents/LiteLLM"
LABEL_OMNI="FreeAgents/Omni"
# Claude Desktop validates inferenceModels names against the Anthropic catalog
# in some builds, so the LiteLLM gateway also answers to this catalog id
# (model_group_alias, hidden from /v1/models).
CATALOG_MODEL_ID="claude-sonnet-4-5"
# Auto-compact threshold handed to Claude Code. The smallest context window we
# route to is 128k, so this keeps every request inside every deployment.
AUTO_COMPACT_WINDOW="${FREEAGENTS_COMPACT_WINDOW:-120000}"

STATE_DIR="${HOME}/.free-ai-agents"
LOGS_DIR="${STATE_DIR}/logs"
MANAGER_COPY="${STATE_DIR}/setup.sh"
LIVE_TEST_FILE="${STATE_DIR}/live_test.sh"
ACTIVE_GATEWAY_FILE="${STATE_DIR}/active_gateway"
KEYS_FILE="${STATE_DIR}/provider_keys.env"
WIN_PROXY_FILE="${STATE_DIR}/windows_proxy.txt"
LEGACY_DIRS=("${HOME}/.omniroute-manager" "${HOME}/omniroute" "${HOME}/omniroute-data")

# ---- LiteLLM engine ---------------------------------------------------------
CONTAINER_NAME="litellm"
LITELLM_IMAGE="${LITELLM_IMAGE:-ghcr.io/berriai/litellm:main-latest}"
LITELLM_PORT="${LITELLM_PORT:-4000}"
LITELLM_DIR="${HOME}/.litellm"
LITELLM_CONFIG="${LITELLM_DIR}/config.yaml"
LITELLM_KEYFILE="${LITELLM_DIR}/master_key.txt"
LITELLM_CRED_FILE="${LITELLM_DIR}/dashboard_credentials.txt"
DB_CONTAINER="litellm-db"
DB_NETWORK="litellm-net"
DB_IMAGE="${LITELLM_DB_IMAGE:-postgres:16-alpine}"
DB_USER="litellm"
DB_NAME="litellm"
DB_PASSWORD_FILE="${LITELLM_DIR}/db_password.txt"
UI_DB_ENABLED="${LITELLM_UI_DB:-1}"

# ---- OmniRoute engine -------------------------------------------------------
OMNI_PORT="${OMNIROUTE_PORT:-20128}"
OMNI_DATA_DIR="${OMNIROUTE_DATA_DIR:-${HOME}/.omniroute}"
OMNI_ENV_FILE="${OMNI_DATA_DIR}/.env"
OMNI_LOG_FILE="${LOGS_DIR}/omniroute.log"
OMNI_PID_FILE="${STATE_DIR}/omniroute.pid"
OMNI_LAUNCHER="${STATE_DIR}/omniroute-run.sh"
OMNI_NPM_PACKAGE="${OMNIROUTE_NPM_PACKAGE:-omniroute}"
OMNI_CONN_NAME="freeagents-install"     # managed provider connection name
OMNI_KEY_LABEL="freeagents-claude"      # managed client API key label
OMNI_CLIENT_KEY_FILE="${STATE_DIR}/omniroute_claude.key"
OMNI_MASTER_KEY_FILE="${STATE_DIR}/omniroute_master.key"
OMNI_MIN_NODE_MAJOR=20

# ---- system integration -----------------------------------------------------
CLI_BIN="/usr/local/bin/freeagents"
BOOT_HELPER="/usr/local/bin/freeagents-boot.sh"
SYSTEMD_UNIT_OMNI="/etc/systemd/system/omniroute.service"
SYSTEMD_UNIT_LITELLM="/etc/systemd/system/litellm.service"
WSL_CONF="/etc/wsl.conf"
BOOT_LINE="command = /usr/local/bin/freeagents-boot.sh"
LEGACY_CLI_BINS=("/usr/local/bin/litellm" "/usr/local/bin/omni" "/usr/local/bin/litellm-boot.sh")
DAEMON_JSON="/etc/docker/daemon.json"

# Claude Desktop third-party-inference profile ids (must be UUIDs)
DESKTOP_PROFILE_ID_LITELLM="00000000-0000-4000-8000-0000000a119e"
DESKTOP_PROFILE_ID_OMNI="00000000-0000-4000-8000-0000000a110e"

# Self-update / manager re-download sources - THIS repository only.
SELF_RAW_URLS=(
  "https://raw.githubusercontent.com/${REPO}/main/setup.sh"
  "https://cdn.jsdelivr.net/gh/${REPO}@main/setup.sh"
)

# Iranian Docker Hub mirrors (403 / rate-limit workaround)
REGISTRY_MIRRORS=(
  "https://docker.arvancloud.ir"
  "https://docker.hub.iran.liara.run"
  "https://docker.iranserver.com"
)

# NPM registry fallbacks (npmjs.org can be slow/blocked in Iran)
NPM_REGISTRIES=(
  ""
  "https://registry.npmmirror.com"
)

AUTOSTART_MODE=""
WIN_PROXY_URL=""
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

#-------------------------------------------------------------------------------
# Provider registry
#
#   id | label | env var | key prefix | api_base | verify url | auth | tier |
#   models ("litellm_model:context_window:max_output_tokens" separated by ,)
#
#   tier: primary = asked in the standard key flow
#         extra   = offered behind the optional "more free providers" question
#   api_base may be empty (provider default). auth: bearer | query (Google).
#-------------------------------------------------------------------------------
PROVIDER_SPECS=(
  "groq|Groq|GROQ_API_KEY|gsk_|https://api.groq.com/openai/v1|https://api.groq.com/openai/v1/models|bearer|primary|groq/openai/gpt-oss-120b:131072:32768,groq/openai/gpt-oss-20b:131072:32768"
  "openrouter|OpenRouter|OPENROUTER_API_KEY|sk-or-|https://openrouter.ai/api/v1|https://openrouter.ai/api/v1/key|bearer|primary|openrouter/deepseek/deepseek-chat-v3.1:free:163840:32768,openrouter/deepseek/deepseek-chat-v3-0324:free:163840:32768,openrouter/qwen/qwen3-coder:free:262144:32768"
  "gemini|Google AI Studio|GEMINI_API_KEY|AIza||https://generativelanguage.googleapis.com/v1beta/models|query|primary|gemini/gemini-2.0-flash:1048576:8192,gemini/gemini-2.5-flash:1048576:65536"
  "cerebras|Cerebras|CEREBRAS_API_KEY|csk-|https://api.cerebras.ai/v1|https://api.cerebras.ai/v1/models|bearer|primary|cerebras/llama3.1-70b:131072:8192,cerebras/qwen-3-32b:131072:16384"
  "mistral|Mistral|MISTRAL_API_KEY||https://api.mistral.ai/v1|https://api.mistral.ai/v1/models|bearer|primary|mistral/codestral-latest:262144:32768,mistral/devstral-latest:262144:32768"
  "github|GitHub Models|GITHUB_API_KEY||https://models.inference.ai.azure.com|https://models.inference.ai.azure.com/models|bearer|extra|github/gpt-4o-mini:131072:16384,github/Llama-3.3-70B-Instruct:131072:8192"
  "sambanova|SambaNova|SAMBANOVA_API_KEY||https://api.sambanova.ai/v1|https://api.sambanova.ai/v1/models|bearer|extra|sambanova/Meta-Llama-3.3-70B-Instruct:131072:8192,sambanova/DeepSeek-R1-Distill-Llama-70B:131072:8192"
  "nvidia_nim|NVIDIA NIM|NVIDIA_NIM_API_KEY|nvapi-|https://integrate.api.nvidia.com/v1|https://integrate.api.nvidia.com/v1/models|bearer|extra|nvidia_nim/meta/llama-3.3-70b-instruct:131072:8192,nvidia_nim/deepseek-ai/deepseek-r1:131072:8192"
  "together_ai|Together AI|TOGETHERAI_API_KEY||https://api.together.xyz/v1|https://api.together.xyz/v1/models|bearer|extra|together_ai/meta-llama/Llama-3.3-70B-Instruct-Turbo:131072:8192"
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
  log_warn "Running as root. Config will be created under /root/.free-ai-agents"
else
  if ! command -v sudo >/dev/null 2>&1; then
    die "'sudo' is not installed and you are not root. Install sudo first:  apt-get install -y sudo"
  fi
  SUDO="sudo"
  $SUDO -n true 2>/dev/null || $SUDO true 2>/dev/null || \
    die "Sudo authentication failed. Please configure sudo for this user."
fi

#-------------------------------------------------------------------------------
# Small utilities
#-------------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

is_number() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

ensure_state_dirs() {
  mkdir -p "$STATE_DIR" "$LOGS_DIR" 2>/dev/null || true
}

# read a single-line secret file safely
read_secret() { [ -s "$1" ] && tr -d '\n' < "$1" || true; }

# atomic write: write to a temp file next to the target, then mv into place
get_env_line() { # $1 file $2 key
  [ -s "$1" ] || return 1
  awk -v key="$2" 'index($0, key "=") == 1 { sub("^" key "=", ""); print; exit }' "$1"
}

# first $2 characters of $1 on a single line (no pipes: SIGPIPE would abort
# the script under `set -o pipefail`)
snippet() { # $1 text  $2 max chars (default 160)
  local text="${1:-}" limit="${2:-160}"
  text="${text//$'\n'/ }"
  text="${text//$'\r'/}"
  printf '%s' "${text:0:limit}"
}

mask_key() {
  local k="${1:-}"
  if [ -z "$k" ]; then echo "<skipped>"; return; fi
  if [ "${#k}" -ge 12 ]; then
    echo "${k:0:4}****${k: -4}"
  else
    echo "****"
  fi
}

#-------------------------------------------------------------------------------
# Provider registry accessors
#-------------------------------------------------------------------------------
spec_field() { # $1 spec  $2 index(1-based)
  printf '%s' "$1" | cut -d'|' -f"$2"
}

provider_spec_by_id() { # $1 provider id -> prints spec
  local s
  for s in "${PROVIDER_SPECS[@]}"; do
    [ "$(spec_field "$s" 1)" = "$1" ] && { printf '%s' "$s"; return 0; }
  done
  return 1
}

providers_in_tier() { # $1 tier
  local s
  for s in "${PROVIDER_SPECS[@]}"; do
    [ "$(spec_field "$s" 8)" = "$1" ] && printf '%s\n' "$(spec_field "$s" 1)"
  done
}

all_provider_ids() {
  local s
  for s in "${PROVIDER_SPECS[@]}"; do printf '%s\n' "$(spec_field "$s" 1)"; done
}

provider_label()  { provider_spec_by_id "$1" | cut -d'|' -f2; }
provider_env()    { provider_spec_by_id "$1" | cut -d'|' -f3; }
provider_prefix() { provider_spec_by_id "$1" | cut -d'|' -f4; }
provider_base()   { provider_spec_by_id "$1" | cut -d'|' -f5; }
provider_verify() { provider_spec_by_id "$1" | cut -d'|' -f6; }
provider_auth()   { provider_spec_by_id "$1" | cut -d'|' -f7; }
provider_models() { provider_spec_by_id "$1" | cut -d'|' -f9; }

provider_key() { # $1 provider id -> key value from the collected globals
  local v
  case "$1" in
    groq)       v="${KEY_GROQ:-}" ;;
    openrouter) v="${KEY_OPENROUTER:-}" ;;
    gemini)     v="${KEY_GEMINI:-}" ;;
    cerebras)   v="${KEY_CEREBRAS:-}" ;;
    mistral)    v="${KEY_MISTRAL:-}" ;;
    github)     v="${KEY_GITHUB:-}" ;;
    sambanova)  v="${KEY_SAMBANOVA:-}" ;;
    nvidia_nim) v="${KEY_NVIDIA_NIM:-}" ;;
    together_ai) v="${KEY_TOGETHER_AI:-}" ;;
    *)          v="" ;;
  esac
  printf '%s' "$v"
}

provider_set_key() { # $1 provider id  $2 value
  case "$1" in
    groq)        KEY_GROQ="$2" ;;
    openrouter)  KEY_OPENROUTER="$2" ;;
    gemini)      KEY_GEMINI="$2" ;;
    cerebras)    KEY_CEREBRAS="$2" ;;
    mistral)     KEY_MISTRAL="$2" ;;
    github)      KEY_GITHUB="$2" ;;
    sambanova)   KEY_SAMBANOVA="$2" ;;
    nvidia_nim)  KEY_NVIDIA_NIM="$2" ;;
    together_ai) KEY_TOGETHER_AI="$2" ;;
    *) return 1 ;;
  esac
  return 0
}

# All configured providers, one id per line
configured_providers() {
  local p
  for p in $(all_provider_ids); do
    [ -n "$(provider_key "$p")" ] && printf '%s\n' "$p"
  done
}

configured_provider_count() {
  local n=0
  for p in $(all_provider_ids); do
    [ -n "$(provider_key "$p")" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# Persist / restore the provider keys so re-runs keep working even when the
# engines are not reachable (the single source of truth is KEYS_FILE).
save_provider_keys() {
  ensure_state_dirs
  local p
  : > "${KEYS_FILE}.tmp"
  chmod 600 "${KEYS_FILE}.tmp" 2>/dev/null || true
  for p in $(all_provider_ids); do
    local k; k="$(provider_key "$p")"
    [ -n "$k" ] && printf '%s=%s\n' "$(provider_env "$p")" "$k" >> "${KEYS_FILE}.tmp"
  done
  mv -f "${KEYS_FILE}.tmp" "$KEYS_FILE"
  chmod 600 "$KEYS_FILE" 2>/dev/null || true
}

load_provider_keys() {
  [ -s "$KEYS_FILE" ] || return 1
  local p found=0
  for p in $(all_provider_ids); do
    local v
    v="$(get_env_line "$KEYS_FILE" "$(provider_env "$p")" || true)"
    if [ -n "$v" ]; then provider_set_key "$p" "$v"; found=1; fi
  done
  [ "$found" -eq 1 ]
}

#-------------------------------------------------------------------------------
# Environment / Windows integration detection
#-------------------------------------------------------------------------------
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

windows_integration_available() {
  [ "${FREEAGENTS_SKIP_WINDOWS:-0}" = "1" ] && return 1
  find_powershell >/dev/null 2>&1
}

# Get the real Windows user profile path (safe with spaces in the username)
# and convert it to its WSL mount point:  C:\Users\John Doe -> /mnt/c/Users/John Doe
get_windows_home() {
  local ps raw drive letter rest
  ps="$(find_powershell)" || return 1
  raw="$($ps -NoProfile -Command "[Environment]::GetFolderPath('UserProfile')" 2>/dev/null | tr -d '\r')"
  [ -n "$raw" ] || return 1
  drive="${raw%%:*}"
  letter="$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')"
  rest="${raw#*:}"
  rest="${rest//\\//}"
  printf '/mnt/%s%s' "$letter" "$rest"
}

# LocalApplicationData (%LOCALAPPDATA%) as a WSL path
get_windows_localappdata() {
  local ps raw drive letter rest
  ps="$(find_powershell)" || return 1
  raw="$($ps -NoProfile -Command "[Environment]::GetFolderPath('LocalApplicationData')" 2>/dev/null | tr -d '\r' | head -n1)"
  [ -n "$raw" ] || return 1
  drive="${raw%%:*}"
  letter="$(printf '%s' "$drive" | tr '[:upper:]' '[:lower:]')"
  rest="${raw#*:}"
  rest="${rest//\\//}"
  printf '/mnt/%s%s' "$letter" "$rest"
}

check_environment() {
  log_info "[1/9] Checking the environment..."
  if ! grep -qi "microsoft" /proc/version 2>/dev/null; then
    log_warn "This does not look like a WSL kernel (/proc/version)."
    log_warn "Continuing anyway - the Windows integration may fail."
  fi
  if windows_integration_available; then
    log_ok "Windows integration available (powershell.exe found)."
  elif [ "${FREEAGENTS_SKIP_WINDOWS:-0}" = "1" ]; then
    log_warn "Windows integration disabled on purpose (FREEAGENTS_SKIP_WINDOWS=1)."
    log_warn "Claude Code / Claude Desktop will NOT be configured automatically."
  else
    log_warn "powershell.exe was not found - the Windows side cannot be configured."
    log_warn "The gateways will still be installed; set up Claude manually later, or"
    log_warn "enable WSL interop and re-run."
  fi
}

#-------------------------------------------------------------------------------
# Docker (apt repo, NOT get.docker.com) + Iranian mirrors
#-------------------------------------------------------------------------------
install_docker() {
  log_info "[2/9] Installing Docker Engine (docker.io from the Ubuntu apt repository)..."
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

  if [ -f "$DAEMON_JSON" ] || $SUDO test -f "$DAEMON_JSON" 2>/dev/null; then
    local backup
    backup="${DAEMON_JSON}.bak.$(date +%Y%m%d%H%M%S)"
    $SUDO cp "$DAEMON_JSON" "$backup"
    log_warn "Existing daemon.json backed up to: ${backup}"
  fi

  local mirrors_json="" m
  for m in "${REGISTRY_MIRRORS[@]}"; do
    [ -n "$mirrors_json" ] && mirrors_json+=",\n    "
    mirrors_json+="\"${m}\""
  done

  printf '{\n  "registry-mirrors": [\n    %b\n  ]\n}\n' "$mirrors_json" \
    | $SUDO tee "$DAEMON_JSON" >/dev/null

  log_ok "Registry mirrors written:"
  for m in "${REGISTRY_MIRRORS[@]}"; do echo "       - ${m}"; done

  # If a Windows proxy is configured, also configure Docker daemon to use it
  # for pulling from ghcr.io (which is often blocked/TLS-timeout in Iran).
  # This is done via systemd drop-in if systemd is available.
  if [ -n "${WIN_PROXY_URL:-}" ] && [ -d /run/systemd/system ] && have systemctl; then
    local proxy_dir="/etc/systemd/system/docker.service.d"
    $SUDO mkdir -p "$proxy_dir"
    local proxy_conf="${proxy_dir}/http-proxy.conf"
    # Backup existing proxy conf if any
    if $SUDO test -f "$proxy_conf" 2>/dev/null; then
      $SUDO cp "$proxy_conf" "${proxy_conf}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    fi
    printf '[Service]\nEnvironment="HTTP_PROXY=%s"\nEnvironment="HTTPS_PROXY=%s"\nEnvironment="http_proxy=%s"\nEnvironment="https_proxy=%s"\nEnvironment="NO_PROXY=localhost,127.0.0.1,::1"\nEnvironment="no_proxy=localhost,127.0.0.1,::1"\n'       "$WIN_PROXY_URL" "$WIN_PROXY_URL" "$WIN_PROXY_URL" "$WIN_PROXY_URL"       | $SUDO tee "$proxy_conf" >/dev/null
    log_ok "Docker daemon proxy configured: ${WIN_PROXY_URL} (systemd drop-in)"
    $SUDO systemctl daemon-reload 2>/dev/null || true
  fi
}

start_docker_daemon() {
  log_info "       Starting/restarting the Docker daemon..."
  $SUDO service docker restart >/dev/null 2>&1 || $SUDO service docker start >/dev/null 2>&1 || true
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
# Windows proxy (optional): route provider traffic through a Windows-side proxy
#-------------------------------------------------------------------------------
detect_windows_ip() {
  local gw=""
  gw="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
  case "$gw" in
    ""|127.*|0.0.0.0|::1)
      gw="$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
      case "$gw" in
        ""|127.*|0.0.0.0|::1) return 1 ;;
      esac
      ;;
  esac
  printf '%s\n' "$gw"
  return 0
}

# Load the stored proxy URL (used by re-key / re-apply paths - important:
# the old scripts lost the proxy setting when re-entering tokens).
load_windows_proxy() {
  WIN_PROXY_URL="$(read_secret "$WIN_PROXY_FILE")"
  return 0
}

normalize_proxy_url() {
  local addr="$1"
  case "$addr" in
    http://*|https://*|socks5://*|socks5h://*) printf '%s' "$addr" ;;
    *) printf 'http://%s' "$addr" ;;
  esac
}

test_proxy() { # $1 = proxy url -> prints http code
  local code=""
  if have curl; then
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -x "$1" \
      "https://api.groq.com/openai/v1/models" 2>/dev/null || true)"
  fi
  printf '%s' "${code:-000}"
}

configure_windows_proxy() {
  WIN_PROXY_URL=""
  local previous="" answer="" detected="" suggestion="" addr="" code=""
  previous="$(read_secret "$WIN_PROXY_FILE")"

  # Re-entering tokens must not silently drop or re-ask about the proxy.
  if [ "${FREEAGENTS_PROXY_MODE:-}" = "keep" ]; then
    WIN_PROXY_URL="$previous"
    if [ -n "$WIN_PROXY_URL" ]; then
      log_ok "       Windows proxy kept: ${WIN_PROXY_URL}"
    else
      log_info "       Windows proxy: disabled (direct connections)."
    fi
    return 0
  fi

  echo
  log_info "       --- Windows proxy routing (optional) ---"
  echo "       If a proxy app runs on Windows (Clash / v2rayN / Hiddify / Nekoray),"
  echo "       the gateways can route ALL provider traffic through it - this fixes"
  echo "       region blocks (Google / Cerebras / ...) without a system-wide VPN."
  if [ -n "$previous" ]; then
    printf "       Keep the Windows proxy setting? (%s) [Y/n]: " "$previous"
    read -r answer || answer=""
    case "$answer" in
      n|N|no|No|NO) echo "       OK - enter the new proxy details below." ;;
      *) WIN_PROXY_URL="$previous"; log_ok "       Windows proxy kept: ${WIN_PROXY_URL}"; return 0 ;;
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
  addr="$(normalize_proxy_url "$addr")"
  WIN_PROXY_URL="$addr"

  code="$(test_proxy "$addr")"
  if [ "$code" != "000" ]; then
    log_ok "       Proxy reachable - test call through it returned HTTP ${code}."
  else
    log_warn "       Test call through the proxy FAILED (code ${code:-none})."
    echo "       Check that the proxy app is running and allows LAN connections, and"
    echo "       that the IP is the WINDOWS host IP (in WSL: ip route show default)."
    case "$addr" in
      http://127.0.0.1*|https://127.0.0.1*|socks5://127.0.0.1*|socks5h://127.0.0.1*)
        echo "       NOTE: 127.0.0.1 inside WSL is the WSL VM itself, NOT Windows."
        echo "       Use the WINDOWS host IP (the default suggested above) instead."
        ;;
    esac
    echo "       SOCKS proxies are supported too: enter them as socks5://IP:PORT."
    printf "       Save it anyway? [y/N]: "
    read -r answer || answer=""
    case "$answer" in
      y|Y|yes|Yes|YES) : ;;
      *) WIN_PROXY_URL=""; log_warn "       Windows proxy disabled."; return 0 ;;
    esac
  fi

  ensure_state_dirs
  printf '%s\n' "$WIN_PROXY_URL" > "$WIN_PROXY_FILE"
  chmod 600 "$WIN_PROXY_FILE" 2>/dev/null || true
  log_ok "       Windows proxy enabled: ${WIN_PROXY_URL}"
  log_info "       Saved to ${WIN_PROXY_FILE} (reinstalls will offer to keep it)."
  return 0
}

#-------------------------------------------------------------------------------
# API keys: collect (file -> container/env -> prompt) + live verification
#-------------------------------------------------------------------------------
warn_key_prefix() {
  local val="$1" prefix="$2" name="$3"
  [ -n "$val" ] || return 0
  [ -n "$prefix" ] || return 0
  case "$val" in
    "$prefix"*) return 0 ;;
    *) log_warn "       NOTE: this value does not look like a ${name} key (expected prefix '${prefix}') - double-check it." ;;
  esac
}

# Read provider keys that a previous install stored in the LiteLLM container env
read_keys_from_container() {
  have docker || return 1
  local envs p found=0
  envs="$($SUDO docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)"
  [ -n "$envs" ] || return 1
  for p in $(all_provider_ids); do
    local ev v
    ev="$(provider_env "$p")"
    v="$(printf '%s\n' "$envs" | awk -v key="$ev" 'index($0, key "=") == 1 { sub("^" key "=", ""); print; exit }')"
    if [ -n "$v" ]; then provider_set_key "$p" "$v"; found=1; fi
  done
  [ "$found" -eq 1 ]
}

print_provider_summary() {
  local p k
  echo "       Provider keys:"
  for p in $(all_provider_ids); do
    k="$(provider_key "$p")"
    [ -n "$k" ] || continue
    printf '         %-12s : %s\n' "$(provider_label "$p")" "$(mask_key "$k")"
  done
}

ask_keys_tier() { # $1 = primary|extra ; sets KEY_* globals; returns 1 if none
  local tier="$1" p label prefix val count=0
  local ids; ids="$(providers_in_tier "$tier")"
  [ -n "$ids" ] || return 1
  for p in $ids; do
    label="$(provider_label "$p")"
    prefix="$(provider_prefix "$p")"
    if [ -n "$prefix" ]; then
      printf "       %-16s (%s...): " "$label" "$prefix"
    else
      printf "       %-16s (key)    : " "$label"
    fi
    val=""
    read -r val || val=""
    val="${val//[[:space:]]/}"
    warn_key_prefix "$val" "$prefix" "$label"
    if [ -n "$val" ]; then
      provider_set_key "$p" "$val"
      count=$((count + 1))
    fi
  done
  printf '       ---\n'
  [ "$count" -gt 0 ]
}

verify_keys() {
  # Live-check every provided key against its provider endpoint. Non-fatal:
  # unreachable providers are skipped (blocked networks); rejected keys (401/403)
  # are collected in VERIFY_FAILED.
  VERIFY_FAILED=""
  [ "${FREEAGENTS_KEY_CHECK:-1}" = "1" ] || return 0
  have curl || return 0
  VERIFY_FAILED_COUNT=0
  local p key url auth code timeout proxy_args=()
  timeout="${FREEAGENTS_KEY_CHECK_TIMEOUT:-10}"
  is_number "$timeout" || timeout=10
  [ -n "$WIN_PROXY_URL" ] && proxy_args=(-x "$WIN_PROXY_URL")

  echo
  log_info "       Verifying the provider keys (live)..."
  for p in $(configured_providers); do
    key="$(provider_key "$p")"
    url="$(provider_verify "$p")"
    auth="$(provider_auth "$p")"
    [ -n "$url" ] || continue
    if [ "$auth" = "query" ]; then
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$timeout" ${proxy_args[@]+"${proxy_args[@]}"} "$url?key=$key" 2>/dev/null || true)"
    else
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "$timeout" ${proxy_args[@]+"${proxy_args[@]}"} -H "Authorization: Bearer $key" "$url" 2>/dev/null || true)"
    fi
    case "$code" in
      200|201|204)
        log_ok "         $(provider_label "$p"): valid (HTTP ${code})"
        ;;
      401|403)
        log_warn "         $(provider_label "$p"): REJECTED (HTTP ${code}) - wrong/unknown key for this provider"
        VERIFY_FAILED="${VERIFY_FAILED}${p} "
        VERIFY_FAILED_COUNT=$((VERIFY_FAILED_COUNT + 1))
        ;;
      000|'')
        log_warn "         $(provider_label "$p"): could not verify (network unreachable/blocked) - continuing"
        ;;
      *)
        log_warn "         $(provider_label "$p"): HTTP ${code} - continuing"
        VERIFY_FAILED="${VERIFY_FAILED}${p} "
        VERIFY_FAILED_COUNT=$((VERIFY_FAILED_COUNT + 1))
        ;;
    esac
  done
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

collect_keys() {
  echo
  log_info "[4/9] API keys setup (${#PROVIDER_SPECS[@]} supported providers)"
  load_windows_proxy
  configure_windows_proxy

  local answer="" attempts=0

  # 1) keys from a previous install (local state file first, then container env)
  #    (skipped by the "re-enter provider tokens" flow, where ENTER = skip)
  if [ "${FREEAGENTS_FRESH_KEYS:-0}" != "1" ] && { load_provider_keys || read_keys_from_container; }; then
    echo "       Existing provider keys found (from the previous install):"
    print_provider_summary
    while true; do
      printf "       Keep these keys? [Y/n]: "
      read -r answer || answer=""
      case "$answer" in
        ""|y|Y|yes|Yes|YES)
          save_provider_keys
          log_ok "Keeping the existing $(configured_provider_count) provider key(s)."
          verify_keys
          if offer_key_reentry; then
            ask_keys_tier primary || true
            save_provider_keys
            verify_keys
          fi
          return 0
          ;;
        n|N|no|No|NO)
          echo "       OK - enter the replacement keys below."
          echo
          break
          ;;
        *)
          attempts=$((attempts + 1))
          [ "$attempts" -ge 5 ] && { log_warn "Unrecognized input - keeping the existing keys."; return 0; }
          echo "       Please answer y (keep) or n (replace)."
          ;;
      esac
    done
  fi

  # 2) fresh collection
  echo "       Press ENTER to skip a provider you do not use."
  echo "       At least ONE key is required."
  echo
  answer=""
  local tries=0
  while true; do
    tries=$((tries + 1))
    ask_keys_tier primary || true
    if [ "$(configured_provider_count)" -ge 1 ]; then break; fi
    if [ "$tries" -ge 3 ]; then
      die "At least ONE API key is required. Exiting after ${tries} attempts."
    fi
    log_error "At least ONE API key is required. Let's try again."
    echo
  done
  save_provider_keys
  log_ok "Collected $(configured_provider_count) provider key(s)."
  print_provider_summary

  # 3) optional extra free providers
  printf "       Add more free providers (GitHub Models, SambaNova, NVIDIA NIM, Together AI)? [y/N]: "
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|Yes|YES)
      echo "       Press ENTER to skip any provider you do not use."
      ask_keys_tier extra || true
      save_provider_keys
      ;;
  esac

  verify_keys
  if offer_key_reentry; then
    echo "       OK - enter the keys again below."
    echo
    ask_keys_tier primary || true
    save_provider_keys
    verify_keys
  fi
  return 0
}

#===============================================================================
# LiteLLM engine
#   - one generated config.yaml (single model group, every provider as a
#     deployment, router retries/failover, optional Admin UI database)
#   - Docker container "litellm" on port 4000, restart=unless-stopped
#===============================================================================
ensure_db_password() {
  if [ -s "$DB_PASSWORD_FILE" ]; then
    DB_PASSWORD="$(read_secret "$DB_PASSWORD_FILE")"
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
  local reused=0
  if [ -s "$LITELLM_KEYFILE" ]; then
    MASTER_KEY="$(read_secret "$LITELLM_KEYFILE")"
    reused=1
  elif command -v openssl >/dev/null 2>&1; then
    MASTER_KEY="sk-$(openssl rand -hex 32)"
  else
    MASTER_KEY="sk-$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')"
  fi
  mkdir -p "$LITELLM_DIR"
  printf '%s\n' "$MASTER_KEY" > "$LITELLM_KEYFILE"
  chmod 600 "$LITELLM_KEYFILE"
  {
    echo "LiteLLM Admin Panel (UI)"
    echo "  URL      : http://127.0.0.1:${LITELLM_PORT}/ui"
    echo "  Username : admin"
    echo "  Password : ${MASTER_KEY}"
    echo ""
    echo "Claude / API clients"
    echo "  Base URL : http://127.0.0.1:${LITELLM_PORT}"
    echo "  Model id : ${MODEL_ID}"
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
# config.yaml: ONE model (claude-freeagents) backed by every configured provider
#-------------------------------------------------------------------------------
generate_litellm_config() {
  log_info "[5/9] Generating the LiteLLM configuration: ${LITELLM_CONFIG}"
  mkdir -p "$LITELLM_DIR"

  local p models spec mname ctx maxout api_base env_name dep_index=0
  {
    echo "# Free AI Agents - generated by setup.sh v${FREE_AGENTS_VERSION}"
    echo "# Single model group '${MODEL_ID}' with every configured provider as a"
    echo "# deployment: LiteLLM load-balances and retries across them."
    echo "model_list:"

    for p in $(configured_providers); do
      env_name="$(provider_env "$p")"
      api_base="$(provider_base "$p")"
      models="$(provider_models "$p")"
      echo "  # ---------------- $(provider_label "$p") ----------------"
      local IFS=','
      for spec in $models; do
        unset IFS
        mname="${spec%%:*}"
        local rest="${spec#*:}"
        ctx="${rest%%:*}"
        maxout="${rest#*:}"
        is_number "$ctx" || ctx=131072
        is_number "$maxout" || maxout=8192
        dep_index=$((dep_index + 1))
        echo "  - model_name: ${MODEL_ID}"
        echo "    litellm_params:"
        echo "      model: ${mname}"
        echo "      api_key: os.environ/${env_name}"
        [ -n "$api_base" ] && echo "      api_base: ${api_base}"
        echo "      drop_params: true"
        echo "    model_info:"
        echo "      id: fa-${p}-${dep_index}"
        echo "      mode: chat"
        echo "      context_window: ${ctx}"
        echo "      max_input_tokens: ${ctx}"
        echo "      max_output_tokens: ${maxout}"
      done
    done

    echo ""
    echo "# Router behaviour: if one provider fails or is rate-limited, the next"
    echo "# deployment in the '${MODEL_ID}' group is tried automatically."
    echo "router_settings:"
    echo "  routing_strategy: simple-shuffle"
    echo "  num_retries: 3"
    echo "  retry_after: 1"
    echo "  allowed_fails: 3"
    echo "  cooldown_time: 30"
    echo "  timeout: 600"
    echo "  enable_pre_call_checks: true"
    echo "  # Claude Desktop validates model names against the Anthropic catalog in"
    echo "  # some builds. This alias routes that catalog id to the SAME single group"
    echo "  # while 'hidden' keeps /v1/models clean (only ${MODEL_ID} is advertised)."
    echo "  model_group_alias:"
    echo "    ${CATALOG_MODEL_ID}:"
    echo "      model: ${MODEL_ID}"
    echo "      hidden: true"
    echo ""
    echo "litellm_settings:"
    echo "  drop_params: true          # silently drop unsupported provider params"
    echo "  request_timeout: 600"
    echo "  num_retries: 2"
    echo "  json_logs: false"
    echo ""
    echo "general_settings:"
    echo "  master_key: os.environ/LITELLM_MASTER_KEY"
    # clients (Claude Code/Desktop) talk to LiteLLM directly on localhost
    echo "  trusted_proxy_ranges: []"
    if [ "$UI_DB_ENABLED" = "1" ]; then
      echo "  database_url: os.environ/DATABASE_URL"
    fi
  } > "$LITELLM_CONFIG"
  chmod 644 "$LITELLM_CONFIG" 2>/dev/null || true

  log_ok "config.yaml generated (${dep_index} deployment(s) behind '${MODEL_ID}')."
}

#-------------------------------------------------------------------------------
# Container lifecycle
#-------------------------------------------------------------------------------
build_docker_env_args() {
  DOCKER_ENV_ARGS=(-e "LITELLM_MASTER_KEY=${MASTER_KEY}")
  DOCKER_ENV_ARGS+=(-e "UI_USERNAME=admin" -e "UI_PASSWORD=${MASTER_KEY}")
  if [ "$UI_DB_ENABLED" = "1" ]; then
    ensure_db_password
    DOCKER_ENV_ARGS+=(-e "DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@${DB_CONTAINER}:5432/${DB_NAME}")
  fi
  local p k env_name
  for p in $(configured_providers); do
    k="$(provider_key "$p")"
    env_name="$(provider_env "$p")"
    DOCKER_ENV_ARGS+=(-e "${env_name}=${k}")
  done
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
    log_ok "       Database container '${DB_CONTAINER}' started."
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

pull_litellm_image() {
  log_info "[6/9] Pulling prebuilt LiteLLM image (no build step): ${LITELLM_IMAGE}"
  log_info "       This may take several minutes on the first run..."
  local have_local=0
  if $SUDO docker image inspect "$LITELLM_IMAGE" >/dev/null 2>&1; then
    have_local=1
    log_ok "       Image already exists locally (from a previous install)."
  fi
  # Default retries increased to 5 for Iranian networks (TLS handshake timeout is common)
  local attempts="${LITELLM_PULL_RETRIES:-5}"
  is_number "$attempts" || attempts=5
  attempts=$((attempts < 1 ? 1 : attempts))

  local i
  for i in $(seq 1 "$attempts"); do
    [ "$i" -gt 1 ] && log_warn "       Retry ${i}/${attempts} (transient TLS/network timeouts are common)..."
    if $SUDO docker pull "$LITELLM_IMAGE"; then
      log_ok "Image pulled successfully."
      return 0
    fi
    # Exponential backoff: 5s, 10s, 15s...
    if [ "$i" -lt "$attempts" ]; then
      local wait=$((i * 5))
      log_info "       Waiting ${wait}s before retry..."
      sleep "$wait"
    fi
  done

  if [ "$have_local" -eq 1 ]; then
    log_warn "Pull failed, but the image already exists locally - continuing with the local copy."
    return 0
  fi

  # If Windows proxy is configured, try pulling with proxy env vars (helps when
  # docker daemon proxy drop-in was just created or for non-systemd setups)
  if [ -n "${WIN_PROXY_URL:-}" ]; then
    log_warn "       Trying docker pull with Windows proxy: ${WIN_PROXY_URL}"
    if HTTP_PROXY="$WIN_PROXY_URL" HTTPS_PROXY="$WIN_PROXY_URL" http_proxy="$WIN_PROXY_URL" https_proxy="$WIN_PROXY_URL"        $SUDO -E docker pull "$LITELLM_IMAGE"; then
      log_ok "Image pulled successfully via Windows proxy."
      return 0
    fi
  fi

  # Automatic fallback mirrors (no env var required) - crucial for Iran
  # ghcr.io is often blocked or TLS-timeout; these mirrors cache the same image
  local mirrors=()
  if [ -n "${LITELLM_GHCR_MIRROR:-}" ]; then
    mirrors+=("${LITELLM_GHCR_MIRROR%/}")
  fi
  # Hardcoded known-good mirrors (tried in order)
  mirrors+=("ghcr.nju.edu.cn" "ghcr.m.daocloud.io" "ghcr.mirror.kubesphere.com")

  local m mirror_image
  for m in "${mirrors[@]}"; do
    # Skip empty and duplicate of primary registry
    [ -z "$m" ] && continue
    case "$m" in
      ghcr.io) continue ;;
    esac
    mirror_image="${m}/berriai/litellm:main-latest"
    log_warn "       Trying ghcr fallback mirror: ${mirror_image}"
    if $SUDO docker pull "$mirror_image"; then
      $SUDO docker tag "$mirror_image" "$LITELLM_IMAGE" 2>/dev/null || true
      log_ok "Image pulled via mirror ${m} and tagged as ${LITELLM_IMAGE}."
      return 0
    fi
    # Also try with proxy if available
    if [ -n "${WIN_PROXY_URL:-}" ]; then
      log_warn "       Trying mirror ${mirror_image} via proxy..."
      if HTTP_PROXY="$WIN_PROXY_URL" HTTPS_PROXY="$WIN_PROXY_URL" http_proxy="$WIN_PROXY_URL" https_proxy="$WIN_PROXY_URL"          $SUDO -E docker pull "$mirror_image"; then
        $SUDO docker tag "$mirror_image" "$LITELLM_IMAGE" 2>/dev/null || true
        log_ok "Image pulled via mirror ${m} + proxy and tagged as ${LITELLM_IMAGE}."
        return 0
      fi
    fi
  done

  # Last resort: try docker.io (some builds are also pushed there)
  local docker_io_image="docker.io/berriai/litellm:main-latest"
  log_warn "       Trying Docker Hub fallback: ${docker_io_image}"
  if $SUDO docker pull "$docker_io_image"; then
    $SUDO docker tag "$docker_io_image" "$LITELLM_IMAGE" 2>/dev/null || true
    log_ok "Image pulled via Docker Hub and tagged as ${LITELLM_IMAGE}."
    return 0
  fi

  die "Image pull failed after ${attempts} attempt(s) + mirrors. Fixes, in order:
         1. Simply re-run the installer - TLS timeouts are often transient.
         2. Check your internet connection inside WSL:  curl -I https://ghcr.io/v2/
            Also try:  curl -I https://ghcr.nju.edu.cn/v2/  (mirror)
         3. Turn a VPN on (on the WINDOWS side) and re-run the installer.
            If you already have Clash/v2rayN/Hiddify with Allow LAN, enable
            Windows proxy in the installer (question at step 4/9) and re-run.
         4. Use a ghcr mirror explicitly:   LITELLM_GHCR_MIRROR=ghcr.nju.edu.cn bash setup.sh
            Other mirrors to try: ghcr.m.daocloud.io, ghcr.mirror.kubesphere.com
         5. Manual pull with proxy (if you have proxy on Windows):
            export HTTP_PROXY=http://<WINDOWS_IP>:7890 HTTPS_PROXY=http://<WINDOWS_IP>:7890
            sudo -E docker pull ghcr.io/berriai/litellm:main-latest
            Then re-run: bash setup.sh (it will reuse local image)
         6. Use a custom image:  LITELLM_IMAGE=<registry>/berriai/litellm:main-latest bash setup.sh
         7. If you have the image tarball, load it:  docker load -i litellm.tar"
}


start_litellm_container() {
  log_info "Starting the LiteLLM container on port ${LITELLM_PORT}..."
  ensure_db_stack
  remove_existing_container
  build_docker_env_args

  local net_args=()
  [ "$UI_DB_ENABLED" = "1" ] && net_args+=(--network "$DB_NETWORK")

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

litellm_health_code() {
  if have curl; then
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
      "http://127.0.0.1:${LITELLM_PORT}/health/liveliness" 2>/dev/null || true
  elif have wget; then
    if wget -q -O /dev/null "http://127.0.0.1:${LITELLM_PORT}/health/liveliness" 2>/dev/null; then
      echo 200
    else
      echo 000
    fi
  else
    echo "n/a"
  fi
}

wait_for_litellm() {
  local wait_sec="${LITELLM_HEALTH_WAIT_SEC:-}"
  local max_iters
  if [ -n "$wait_sec" ]; then
    is_number "$wait_sec" || wait_sec=""
  fi
  if [ -n "$wait_sec" ]; then
    max_iters=$(( (wait_sec + 1) / 2 ))
  elif [ "$UI_DB_ENABLED" = "1" ]; then
    max_iters=60
  else
    max_iters=30
  fi
  log_info "       Waiting for LiteLLM to become healthy (up to $((max_iters * 2))s)..."
  local i code
  for i in $(seq 1 "$max_iters"); do
    code="$(litellm_health_code)"
    if [ "$code" = "200" ]; then
      log_ok "LiteLLM is healthy: http://127.0.0.1:${LITELLM_PORT}"
      return 0
    fi
    if [ "$code" = "n/a" ]; then
      log_warn "       Neither curl nor wget found - skipping the health check."
      return 0
    fi
    sleep 2
  done
  log_warn "Health check timed out. The proxy may still be booting."
  log_warn "Inspect logs with:  ${SUDO} docker logs -f ${CONTAINER_NAME}"
  return 0
}

litellm_container_exists() { $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; }
litellm_container_running() { $SUDO docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; }
litellm_installed() { [ -f "$LITELLM_CONFIG" ] || litellm_container_exists; }

#===============================================================================
# OmniRoute engine (official npm distribution - no third-party forks)
#   - Node.js >= 20 (installed from NodeSource when missing/too old)
#   - npm install -g omniroute   (npmjs.org, npmmirror fallback)
#   - managed .env (secrets preserved + length-checked), launcher + service
#   - configuration through the official REST API (docs/openapi.yaml):
#       POST /api/auth/login          -> management session cookie (auth_token)
#       POST /api/providers           -> upsert of a managed connection
#       POST /api/keys                -> client API key for Claude (name field)
#       GET  /api/models/catalog      -> live model ids per provider
#       POST|PUT /api/combos          -> the single branded routing combo
#   - ONE branded model id (claude-freeagents) backed by every provider
#===============================================================================
omni_base_url() { printf 'http://127.0.0.1:%s' "$OMNI_PORT"; }

#-------------------------------------------------------------------------------
# Node.js / npm
#-------------------------------------------------------------------------------
node_major() {
  have node || { printf ''; return 1; }
  node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1
}

ensure_node_runtime() {
  local major
  major="$(node_major || true)"
  if is_number "$major" && [ "$major" -ge "$OMNI_MIN_NODE_MAJOR" ]; then
    log_ok "       Node.js $(node -v) is new enough."
  else
    log_info "       Installing Node.js ${OMNI_MIN_NODE_MAJOR}+ (required by OmniRoute)..."
    export DEBIAN_FRONTEND=noninteractive
    if have apt-get; then
      $SUDO apt-get install -y ca-certificates curl gnupg >/dev/null 2>&1 || true
      if have curl && curl -fsSL --max-time 60 \
           "https://deb.nodesource.com/setup_${OMNI_MIN_NODE_MAJOR}.x" -o /tmp/nodesource_setup.sh 2>/dev/null \
         && $SUDO bash /tmp/nodesource_setup.sh >/dev/null 2>&1; then
        $SUDO apt-get install -y nodejs >/dev/null 2>&1 || true
      fi
      rm -f /tmp/nodesource_setup.sh 2>/dev/null || true
    fi
    major="$(node_major || true)"
    if ! is_number "$major" || [ "$major" -lt "$OMNI_MIN_NODE_MAJOR" ]; then
      # last resort: Ubuntu's own package (may be older than 20)
      if have apt-get && ! have node; then
        $SUDO apt-get install -y nodejs npm >/dev/null 2>&1 || true
      fi
      major="$(node_major || true)"
    fi
    if ! is_number "$major" || [ "$major" -lt "$OMNI_MIN_NODE_MAJOR" ]; then
      die "Node.js ${OMNI_MIN_NODE_MAJOR}+ is required but not available (found: $(node -v 2>/dev/null || echo none)).
         Install it manually and re-run:
           curl -fsSL https://deb.nodesource.com/setup_${OMNI_MIN_NODE_MAJOR}.x | sudo -E bash -
           sudo apt-get install -y nodejs"
    fi
    log_ok "       Node.js $(node -v) installed."
  fi
  have npm || die "npm was not found next to Node.js. Install the 'npm' package and re-run."
  return 0
}

npm_install_omniroute() {
  if have omniroute && [ "${OMNIROUTE_FORCE_NPM_INSTALL:-0}" != "1" ]; then
    log_ok "       OmniRoute CLI already installed ($(command -v omniroute))."
    return 0
  fi
  local reg out args=()
  for reg in "${NPM_REGISTRIES[@]}"; do
    args=()
    if [ -n "$reg" ]; then
      args+=(--registry "$reg")
      log_info "       npm install -g ${OMNI_NPM_PACKAGE} (registry: ${reg})..."
    else
      log_info "       npm install -g ${OMNI_NPM_PACKAGE} (default registry)..."
    fi
    out="$($SUDO npm install -g "${args[@]}" "$OMNI_NPM_PACKAGE" 2>&1)" && {
      log_ok "       OmniRoute installed: $(command -v omniroute)"
      return 0
    }
    log_warn "       npm install failed on '${reg:-default}': $(printf '%s' "$out" | tail -3 | tr '\n' ' ')"
  done
  die "Could not install the OmniRoute npm package (${OMNI_NPM_PACKAGE}).
         Check the network/npm registry and re-run, or install it manually:
           npm install -g ${OMNI_NPM_PACKAGE}"
}

#-------------------------------------------------------------------------------
# Managed .env (secrets preserved across re-runs, weak values regenerated)
#   OmniRoute validates this file at startup and refuses to boot when a secret
#   is missing or too short: API_KEY_SECRET >= 16 chars (required) and
#   JWT_SECRET >= 32 chars when it is set.
#-------------------------------------------------------------------------------
omni_strong_secret() { # $1 = current value, $2 = minimum length -> prints a value
  local current="${1:-}" min="${2:-16}" value=""
  if [ -n "$current" ] && [ "${#current}" -ge "$min" ]; then
    printf '%s' "$current"
    return 0
  fi
  if command -v openssl >/dev/null 2>&1; then
    value="$(openssl rand -base64 48 2>/dev/null | tr -d '\n ')"
  fi
  if [ -z "$value" ]; then
    value="$(od -An -N48 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
  fi
  [ -n "$value" ] || value="$(date +%s%N)-${RANDOM}-${RANDOM}-omniroute-fallback-secret-value"
  if [ -n "$current" ] && [ "${#current}" -lt "$min" ]; then
    log_warn "       A stored OmniRoute secret was too short and has been regenerated." >&2
  fi
  printf '%s' "$value"
}

write_omni_env() {
  log_info "       Writing the OmniRoute environment file: ${OMNI_ENV_FILE}"
  mkdir -p "$OMNI_DATA_DIR"
  local jwt="" akey="" pass=""
  if [ -s "$OMNI_ENV_FILE" ]; then
    jwt="$(get_env_line "$OMNI_ENV_FILE" JWT_SECRET || true)"
    akey="$(get_env_line "$OMNI_ENV_FILE" API_KEY_SECRET || true)"
    pass="$(get_env_line "$OMNI_ENV_FILE" INITIAL_PASSWORD || true)"
  fi
  jwt="$(omni_strong_secret "$jwt" 32)"
  akey="$(omni_strong_secret "$akey" 16)"
  [ -n "$pass" ] && [ "${#pass}" -ge 8 ] || pass="$(omni_strong_secret "" 16)"

  {
    echo "# Free AI Agents - managed OmniRoute environment (regenerated on install)."
    echo "# Secrets are preserved across re-runs so dashboard logins and stored"
    echo "# provider keys keep working. OmniRoute refuses to boot when they are"
    echo "# missing or shorter than its minimums (JWT>=32, API_KEY_SECRET>=16)."
    echo "JWT_SECRET=${jwt}"
    echo "API_KEY_SECRET=${akey}"
    echo "INITIAL_PASSWORD=${pass}"
    echo "PORT=${OMNI_PORT}"
    echo "API_HOST=127.0.0.1"
    echo "DATA_DIR=${OMNI_DATA_DIR}"
    # /v1 requests must carry an API key (we provision a managed client key).
    echo "REQUIRE_API_KEY=true"
    if [ -n "$WIN_PROXY_URL" ]; then
      echo "HTTP_PROXY=${WIN_PROXY_URL}"
      echo "HTTPS_PROXY=${WIN_PROXY_URL}"
      echo "ALL_PROXY=${WIN_PROXY_URL}"
      echo "NO_PROXY=localhost,127.0.0.1,::1"
    fi
    # Gemini accepts an env key as a headless escape hatch; a dashboard
    # connection always wins when both exist.
    if [ -n "${KEY_GEMINI:-}" ]; then
      echo "GEMINI_API_KEY=${KEY_GEMINI}"
      echo "GOOGLE_API_KEY=${KEY_GEMINI}"
    fi
  } > "${OMNI_ENV_FILE}.tmp"
  chmod 600 "${OMNI_ENV_FILE}.tmp"
  mv -f "${OMNI_ENV_FILE}.tmp" "$OMNI_ENV_FILE"
  OMNI_INITIAL_PASSWORD="$pass"
  log_ok "       Environment written (mode 600; only claude-freeagents is advertised"
  log_ok "       to Claude Code model discovery - the claude/* alias mirror stays off)."
}

write_omni_launcher() {
  ensure_state_dirs
  local omni_bin
  omni_bin="$(command -v omniroute 2>/dev/null || true)"
  [ -n "$omni_bin" ] || omni_bin="/usr/local/bin/omniroute"
  {
    echo '#!/usr/bin/env bash'
    echo '# Auto-generated by setup.sh - OmniRoute launcher (official npm package).'
    echo 'set -u'
    echo 'export PATH="/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin:${PATH}"'
    echo '[ -f "${HOME}/.profile" ] && . "${HOME}/.profile" 2>/dev/null || true'
    echo 'set -a'
    echo ". \"${OMNI_ENV_FILE}\""
    echo 'set +a'
    echo "export DATA_DIR=\"${OMNI_DATA_DIR}\""
    echo "export OMNI_ENV_FILE=\"${OMNI_ENV_FILE}\""
    echo "export PORT=\"${OMNI_PORT}\""
    echo "exec ${omni_bin} serve >> \"${OMNI_LOG_FILE}\" 2>&1"
  } > "${OMNI_LAUNCHER}.tmp"
  chmod 700 "${OMNI_LAUNCHER}.tmp"
  mv -f "${OMNI_LAUNCHER}.tmp" "$OMNI_LAUNCHER"
}

use_systemd() {
  case "${FREEAGENTS_BOOT_MODE:-auto}" in
    systemd) return 0 ;;
    wslconf) return 1 ;;
    *) [ -d /run/systemd/system ] && have systemctl && return 0 ;;
  esac
  return 1
}

write_omni_systemd_unit() {
  printf '%s\n' \
    '[Unit]' \
    'Description=OmniRoute gateway (Free AI Agents)' \
    'After=network-online.target' \
    'Wants=network-online.target' \
    '' \
    '[Service]' \
    'Type=simple' \
    "User=$(id -un)" \
    "ExecStart=${OMNI_LAUNCHER}" \
    'Restart=on-failure' \
    'RestartSec=5' \
    '' \
    '[Install]' \
    'WantedBy=multi-user.target' \
    | $SUDO tee "$SYSTEMD_UNIT_OMNI" >/dev/null
  chmod 700 "$OMNI_LAUNCHER" 2>/dev/null || true
  $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
  $SUDO systemctl enable omniroute.service >/dev/null 2>&1 || true
}

omni_pid_alive() {
  local pid=""
  pid="$(read_secret "$OMNI_PID_FILE")"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

omni_process_running() {
  if have pgrep && pgrep -f "omniroute serve" >/dev/null 2>&1; then return 0; fi
  omni_pid_alive
}

start_omni_service() {
  write_omni_launcher
  if use_systemd; then
    write_omni_systemd_unit
    $SUDO systemctl restart omniroute.service >/dev/null 2>&1 || \
      $SUDO systemctl start omniroute.service >/dev/null 2>&1 || true
    sleep 2
    if omni_process_running; then
      log_ok "       OmniRoute started (systemd: omniroute.service)."
      return 0
    fi
    log_warn "       systemd could not start OmniRoute - falling back to a background process."
  fi
  if omni_process_running; then
    log_ok "       OmniRoute is already running."
    return 0
  fi
  ensure_state_dirs
  : >> "$OMNI_LOG_FILE" 2>/dev/null || true
  nohup "$OMNI_LAUNCHER" >/dev/null 2>&1 &
  echo $! > "$OMNI_PID_FILE"
  chmod 600 "$OMNI_PID_FILE" 2>/dev/null || true
  log_ok "       OmniRoute started in the background (log: ${OMNI_LOG_FILE})."
  return 0
}

stop_omni_service() {
  local stopped=0
  if use_systemd && [ -f "$SYSTEMD_UNIT_OMNI" ]; then
    if $SUDO systemctl stop omniroute.service >/dev/null 2>&1; then stopped=1; fi
  fi
  local pid=""
  pid="$(read_secret "$OMNI_PID_FILE")"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
    stopped=1
  fi
  if have pkill; then
    pkill -f "omniroute serve" >/dev/null 2>&1 && stopped=1 || true
  fi
  rm -f "$OMNI_PID_FILE" 2>/dev/null || true
  if [ "$stopped" -eq 1 ]; then log_ok "       OmniRoute stopped."; else log_info "       OmniRoute was not running."; fi
  return 0
}

omni_health_code() {
  if have curl; then
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$(omni_base_url)/healthz" 2>/dev/null || true
  else
    echo "n/a"
  fi
}

wait_for_omni() {
  local max_iters="${OMNIROUTE_HEALTH_WAIT_SEC:-120}"
  is_number "$max_iters" || max_iters=120
  max_iters=$(( (max_iters + 1) / 2 ))
  log_info "       Waiting for OmniRoute to become healthy (up to $((max_iters * 2))s)..."
  local i code
  for i in $(seq 1 "$max_iters"); do
    code="$(omni_health_code)"
    if [ "$code" = "200" ] || [ "$code" = "204" ]; then
      log_ok "OmniRoute is healthy: $(omni_base_url)"
      return 0
    fi
    sleep 2
  done
  log_warn "OmniRoute health check timed out ($(omni_base_url)/healthz)."
  if [ -f "$OMNI_LOG_FILE" ]; then
    log_warn "Last log lines (${OMNI_LOG_FILE}):"
    tail -n 5 "$OMNI_LOG_FILE" | sed 's/^/         /' || true
  fi
  return 0
}

omni_installed() { [ -f "$OMNI_ENV_FILE" ] || have omniroute; }

#-------------------------------------------------------------------------------
# Management API helpers
#   the login cookie (auth_token) authorises every /api/* management route
#-------------------------------------------------------------------------------
OMNI_JAR=""
OMNI_JSON=""
OMNI_HTTP=""

omni_api() { # $1 method $2 path [$3 json body]
  local method="$1" path="$2" body="${3:-}" out
  local -a args=(-sS --max-time 60 -o - -w '\n%{http_code}')
  # read AND write the session cookie jar (login stores auth_token here)
  [ -n "$OMNI_JAR" ] && args+=(-b "$OMNI_JAR" -c "$OMNI_JAR")
  if [ -n "$body" ]; then
    args+=(-X "$method" -H 'Content-Type: application/json' --data-binary "$body")
  else
    args+=(-X "$method")
  fi
  out="$(curl "${args[@]}" "$(omni_base_url)${path}" 2>/dev/null || true)"
  OMNI_HTTP="$(printf '%s' "$out" | tail -n1)"
  OMNI_JSON="$(printf '%s' "$out" | sed '$d')"
  case "$OMNI_HTTP" in 2*) return 0 ;; *) return 1 ;; esac
}

# Evaluate a small python expression over the last JSON response.
# Namespace: d (raw), conns, combos, keys, items, a0, a1
#   omni_json_get "$json" "next((c['id'] for c in conns if c['name']==a0), '')" "NAME"
OMNI_JSON_EVAL_PY="$(cat <<'PYEOF'
import json, os, sys

raw = sys.stdin.read()
expr = os.environ.get("OMNI_EXPR") or ""
a0 = os.environ.get("OMNI_A0") or ""
a1 = os.environ.get("OMNI_A1") or ""
if not expr:
    raise SystemExit(0)

try:
    d = json.loads(raw)
except Exception:
    raise SystemExit(0)


def as_list(*keys):
    if isinstance(d, list):
        return d
    if isinstance(d, dict):
        for key in keys:
            value = d.get(key)
            if isinstance(value, list):
                return value
    return []


ns = {
    "d": d,
    "a0": a0,
    "a1": a1,
    "args": [a0, a1],
    "conns": as_list("connections", "providers"),
    "combos": as_list("combos"),
    "keys": as_list("keys", "api_keys"),
    "items": d if isinstance(d, list) else [],
}
safe_builtins = {
    "next": next, "str": str, "int": int, "len": len, "any": any, "all": all,
    "sorted": sorted, "isinstance": isinstance, "list": list, "set": set,
    "min": min, "max": max, "float": float, "bool": bool, "enumerate": enumerate,
}
# A single (globals) namespace: names must stay visible inside generator
# expressions and comprehensions of the evaluated snippet.
scope = dict(ns)
scope["__builtins__"] = safe_builtins
try:
    value = eval(expr, scope)  # noqa: S307 - fixed local source
except Exception:
    value = ""
print("" if value is None else value)
PYEOF
)"

omni_json_get() { # $1 json  $2 python expression  [$3 arg0] [$4 arg1]
  local json="${1:-}"
  [ -n "$json" ] || return 0
  printf '%s' "$json" | OMNI_EXPR="${2:-}" OMNI_A0="${3:-}" OMNI_A1="${4:-}" \
    python3 -c "$OMNI_JSON_EVAL_PY" 2>/dev/null || true
}

omni_login() {
  local body
  rm -f "$OMNI_JAR" 2>/dev/null || true
  OMNI_JAR="$(mktemp /tmp/fa-omni-jar.XXXXXX)"
  chmod 600 "$OMNI_JAR" 2>/dev/null || true
  body="$(python3 -c 'import json,sys; print(json.dumps({"password": sys.argv[1]}))' "$OMNI_INITIAL_PASSWORD")"
  if omni_api POST /api/auth/login "$body"; then
    log_ok "       Dashboard login OK (session cookie stored)."
    return 0
  fi
  rm -f "$OMNI_JAR" 2>/dev/null || true
  OMNI_JAR=""
  log_warn "       Dashboard login failed (HTTP ${OMNI_HTTP:-none}). Provider keys and the"
  log_warn "       model combo must be added manually in the dashboard: $(omni_base_url)"
  return 1
}

# LiteLLM provider id -> OmniRoute provider id ('' = not a native OmniRoute
# API-key provider, e.g. GitHub Models; it can be added from the dashboard).
omni_provider_id() {
  case "${1:-}" in
    groq|openrouter|gemini|cerebras|mistral|sambanova) printf '%s' "$1" ;;
    nvidia_nim)  printf 'nvidia' ;;
    together_ai) printf 'together' ;;
    *) printf '' ;;
  esac
}

# POST /api/providers is an UPSERT keyed on (provider, name): re-running the
# installer updates the managed connection instead of duplicating it.
omni_upsert_provider() { # $1 provider id  $2 api key
  local provider="$1" key="$2" target body
  target="$(omni_provider_id "$provider")"
  if [ -z "$target" ]; then
    log_warn "       $(provider_label "$provider"): not available as an OmniRoute API-key"
    log_warn "         provider - skipping it for OmniRoute (add it in the dashboard if needed)."
    return 1
  fi
  body="$(python3 -c 'import json,sys; print(json.dumps({"provider": sys.argv[1], "name": sys.argv[2], "apiKey": sys.argv[3], "isActive": True}))' \
    "$target" "$OMNI_CONN_NAME" "$key")"
  if omni_api POST /api/providers "$body"; then
    log_ok "       $(provider_label "$provider"): connection '${OMNI_CONN_NAME}' saved."
    return 0
  fi
  log_warn "       $(provider_label "$provider"): saving the connection failed (HTTP ${OMNI_HTTP:-none}): $(snippet "$OMNI_JSON")"
  return 1
}

# Remove connections/combos created by the two older per-gateway scripts so
# they cannot shadow the managed ones.
omni_cleanup_legacy() {
  local ids id
  if omni_api GET /api/providers; then
    ids="$(omni_json_get "$OMNI_JSON" "\"\n\".join(str(c.get('id')) for c in conns if str(c.get('name','')) in ('ws-install','omniroute-install','litellm-install'))")"
    for id in $ids; do
      [ -n "$id" ] || continue
      if omni_api DELETE "/api/providers/${id}"; then
        log_info "       Removed a leftover provider connection from the previous installer."
      fi
    done
  fi
  if omni_api GET /api/combos; then
    ids="$(omni_json_get "$OMNI_JSON" "\"\n\".join(str(c.get('id')) for c in combos if str(c.get('name','')) in ('ws-claude','freeagents'))")"
    for id in $ids; do
      [ -n "$id" ] || continue
      if omni_api DELETE "/api/combos/${id}"; then
        log_info "       Removed a leftover routing combo from the previous installer."
      fi
    done
  fi
  return 0
}

# Managed connections that are no longer part of the current key set are
# removed, so re-entering tokens really replaces the old provider set (only
# connections created by THIS installer are touched).
omni_prune_connections() { # $1 comma-separated list of provider ids to keep
  local keep="$1" ids id
  omni_api GET /api/providers || return 0
  ids="$(omni_json_get "$OMNI_JSON" \
    "\"\\n\".join(str(c.get('id')) for c in conns if str(c.get('name','')) == a0 and str(c.get('provider','')) not in a1.split(','))" \
    "$OMNI_CONN_NAME" "$keep")"
  for id in $ids; do
    [ -n "$id" ] || continue
    if omni_api DELETE "/api/providers/${id}"; then
      log_info "       Removed a managed connection that is no longer configured."
    fi
  done
  return 0
}

# The managed client API key. POST is NOT idempotent (a second POST with the
# same name creates another key), so duplicates are pruned and the stored value
# is reused whenever possible.
omni_ensure_client_key() {
  OMNI_CLIENT_KEY="$(read_secret "$OMNI_CLIENT_KEY_FILE")"
  local ids=""
  if omni_api GET /api/keys; then
    ids="$(omni_json_get "$OMNI_JSON" \
      "\"\n\".join(str(k.get('id')) for k in sorted(keys, key=lambda x: str(x.get('createdAt') or '')) if str(k.get('name','')) == a0)" \
      "$OMNI_KEY_LABEL")"
  else
    log_warn "       Could not list the existing API keys (HTTP ${OMNI_HTTP:-none})."
  fi

  if [ -n "$OMNI_CLIENT_KEY" ] && [ -n "$ids" ]; then
    # keep the newest managed key, drop any duplicates created by older runs
    local -a list=()
    local id keep
    mapfile -t list <<< "$ids"
    keep="${list[$((${#list[@]} - 1))]}"
    for id in "${list[@]}"; do
      [ "$id" = "$keep" ] && continue
      omni_api DELETE "/api/keys/${id}" >/dev/null 2>&1 || true
      log_info "       Removed a duplicate managed API key."
    done
    log_ok "       Reusing the stored managed API key."
    return 0
  fi

  if [ -z "$OMNI_CLIENT_KEY" ]; then
    # no usable local value: drop every managed key and create a fresh one
    local id
    for id in $ids; do
      omni_api DELETE "/api/keys/${id}" >/dev/null 2>&1 || true
    done
  fi

  local body
  body="$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "label": sys.argv[1]}))' "$OMNI_KEY_LABEL")"
  if omni_api POST /api/keys "$body"; then
    OMNI_CLIENT_KEY="$(omni_json_get "$OMNI_JSON" "d.get('key') or (d.get('data') or {}).get('key') or ''")"
  fi
  if [ -z "$OMNI_CLIENT_KEY" ]; then
    OMNI_CLIENT_KEY="$(read_secret "$OMNI_MASTER_KEY_FILE")"
    if [ -n "$OMNI_CLIENT_KEY" ]; then
      log_warn "       Could not create a client key - falling back to the master key."
    else
      log_warn "       No client key available; create one in the dashboard: $(omni_base_url)"
    fi
    return 0
  fi
  ensure_state_dirs
  printf '%s\n' "$OMNI_CLIENT_KEY" > "${OMNI_CLIENT_KEY_FILE}.tmp"
  chmod 600 "${OMNI_CLIENT_KEY_FILE}.tmp"
  mv -f "${OMNI_CLIENT_KEY_FILE}.tmp" "$OMNI_CLIENT_KEY_FILE"
  log_ok "       Managed client API key created (${OMNI_CLIENT_KEY_FILE})."
  return 0
}

# Live model ids for the configured providers, straight from the official
# catalog endpoint: only chat models that support tool calling are used, and
# coding-friendly families are ranked first.
omni_catalog_refs() {
  local p target tmp="" provs=()
  for p in $(configured_providers); do
    target="$(omni_provider_id "$p")"
    [ -n "$target" ] && provs+=("$target")
  done
  [ "${#provs[@]}" -gt 0 ] || return 1
  omni_api GET /api/models/catalog || return 1
  [ -n "$OMNI_JSON" ] || return 1
  tmp="$(mktemp /tmp/fa-omni-catalog.XXXXXX.json)"
  printf '%s' "$OMNI_JSON" > "$tmp"
  OMNIROUTE_MODELS_PER_PROVIDER="${OMNIROUTE_MODELS_PER_PROVIDER:-3}" \
    python3 - "$tmp" "${provs[@]}" <<'PYEOF'
import json, os, sys

path, wanted = sys.argv[1], sys.argv[2:]
try:
    catalog = (json.load(open(path, encoding="utf-8")) or {}).get("catalog") or {}
except Exception:
    raise SystemExit(0)

def _int(value, default):
    try:
        return int(value)
    except Exception:
        return default

limit = max(1, _int(os.environ.get("OMNIROUTE_MODELS_PER_PROVIDER"), 3))
PREFER = ("coder", "devstral", "gpt-oss", "qwen3", "deepseek", "glm", "llama-3.3",
          "mistral", "gemini-", "minimax", "kimi")
SKIP = ("embed", "whisper", "tts", "audio", "image", "rerank", "moderation",
        "vision-encoder", "guard")

def rank(model_id):
    low = model_id.lower()
    if any(token in low for token in SKIP):
        return 99
    for index, token in enumerate(PREFER):
        if token in low:
            return index
    return len(PREFER)

refs = []
for provider in wanted:
    entry = catalog.get(provider) or {}
    models = [m for m in (entry.get("models") or [])
              if str(m.get("type")) == "chat" and (m.get("capabilities") or {}).get("tool_calling")]
    models.sort(key=lambda m: rank(str(m.get("id") or "")))
    for model in models[:limit]:
        model_id = str(model.get("id") or "")
        if model_id:
            refs.append(model_id)

for ref in refs[:24]:
    print(ref)
PYEOF
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

# The ONE model Claude sees from OmniRoute: a combo named $MODEL_ID.
omni_ensure_combo() {
  local line refs_json body id="" strategy="${OMNIROUTE_COMBO_STRATEGY:-auto}"
  local -a refs=()
  while IFS= read -r line; do
    [ -n "$line" ] && refs+=("$line")
  done < <(omni_catalog_refs)
  if [ "${#refs[@]}" -eq 0 ]; then
    log_warn "       Could not read the OmniRoute model catalog - the existing combo is kept."
    return 1
  fi
  refs_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${refs[@]}")"
  body="$(python3 -c 'import json,sys; print(json.dumps({"name": sys.argv[1], "models": json.loads(sys.argv[2]), "strategy": sys.argv[3]}))' \
    "$MODEL_ID" "$refs_json" "$strategy")"

  omni_api GET /api/combos || true
  id="$(omni_json_get "$OMNI_JSON" "next((str(c.get('id')) for c in combos if str(c.get('name')) == a0), '')" "$MODEL_ID")"
  if [ -n "$id" ]; then
    if omni_api PUT "/api/combos/${id}" "$body"; then
      log_ok "       Routing combo '${MODEL_ID}' updated (${#refs[@]} model refs, strategy ${strategy})."
      return 0
    fi
    log_warn "       Combo update failed (HTTP ${OMNI_HTTP:-none}): $(snippet "$OMNI_JSON")"
    return 1
  fi
  if omni_api POST /api/combos "$body"; then
    log_ok "       Routing combo '${MODEL_ID}' created (${#refs[@]} model refs, strategy ${strategy})."
    return 0
  fi
  log_warn "       Combo creation failed (HTTP ${OMNI_HTTP:-none}): $(snippet "$OMNI_JSON")"
  return 1
}

#-------------------------------------------------------------------------------
# Full OmniRoute configuration flow
#-------------------------------------------------------------------------------
configure_omniroute() {
  log_info "Configuring OmniRoute (connections, client key, single model combo)..."

  ensure_state_dirs
  if [ ! -s "$OMNI_MASTER_KEY_FILE" ]; then
    omni_strong_secret "" 24 > "${OMNI_MASTER_KEY_FILE}.tmp"
    chmod 600 "${OMNI_MASTER_KEY_FILE}.tmp"
    mv -f "${OMNI_MASTER_KEY_FILE}.tmp" "$OMNI_MASTER_KEY_FILE"
  fi
  OMNI_MASTER_KEY="$(read_secret "$OMNI_MASTER_KEY_FILE")"

  if ! omni_login; then
    OMNI_CLIENT_KEY="$OMNI_MASTER_KEY"
    return 0
  fi

  omni_cleanup_legacy

  local p k configured=0 skipped=0
  for p in $(configured_providers); do
    k="$(provider_key "$p")"
    if omni_upsert_provider "$p" "$k"; then
      configured=$((configured + 1))
    else
      skipped=$((skipped + 1))
    fi
  done
  log_ok "       Provider connections: ${configured} saved, ${skipped} skipped."
  local keep="" pp kk
  for pp in $(configured_providers); do
    kk="$(omni_provider_id "$pp")"
    [ -n "$kk" ] && keep="${keep:+${keep},}${kk}"
  done
  [ -n "$keep" ] && omni_prune_connections "$keep"

  omni_ensure_client_key
  omni_ensure_combo || true

  rm -f "$OMNI_JAR" 2>/dev/null || true
  OMNI_JAR=""
  return 0
}

# Verify the OmniRoute surface that Claude Code actually uses.
omni_verify() {
  local token="${OMNI_CLIENT_KEY:-${OMNI_MASTER_KEY:-}}"
  have curl || return 0

  local code found
  code="$(curl -s -o /tmp/fa-omni-models.$$ -w '%{http_code}' --max-time 15 \
    -H "Authorization: Bearer ${token}" "$(omni_base_url)/v1/models" 2>/dev/null || true)"
  if [ "$code" = "200" ]; then
    found="$(grep -c "\"${MODEL_ID}\"" /tmp/fa-omni-models.$$ 2>/dev/null || true)"
    if [ "${found:-0}" -ge 1 ]; then
      log_ok "       /v1/models lists '${MODEL_ID}' (the only claude* id Claude Code shows)."
    else
      log_warn "       /v1/models answered 200 but '${MODEL_ID}' was not listed - check the combo."
    fi
  else
    log_warn "       /v1/models answered ${code:-none} (check the log: ${OMNI_LOG_FILE})."
  fi
  rm -f /tmp/fa-omni-models.$$ 2>/dev/null || true

  local code2
  code2="$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 \
    -H "Authorization: Bearer ${token}" -H 'anthropic-version: 2023-06-01' \
    -H 'Content-Type: application/json' \
    -X POST "$(omni_base_url)/v1/messages" \
    -d "{\"model\":\"${MODEL_ID}\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" 2>/dev/null || true)"
  case "$code2" in
    200) log_ok "       Anthropic endpoint /v1/messages answered 200 for ${MODEL_ID}." ;;
    000|'') log_warn "       /v1/messages could not be reached (network/block)." ;;
    *) log_warn "       /v1/messages answered HTTP ${code2} (a provider-side error is normal here"
       log_warn "       when the live provider call is blocked; routing itself is configured)." ;;
  esac
  return 0
}

#===============================================================================
# Claude integration
#   - Claude Code: %USERPROFILE%\.claude\settings.json  (deep merge, env block)
#   - Claude Desktop: %LOCALAPPDATA%\Claude-3p\configLibrary\<uuid>.json
#       one profile per gateway, labeled FreeAgents/LiteLLM or FreeAgents/Omni
#===============================================================================
active_gateway() {
  local g=""
  g="$(read_secret "$ACTIVE_GATEWAY_FILE")"
  case "$g" in litellm|omniroute) printf '%s' "$g" ;; *) printf 'litellm' ;; esac
}

set_active_gateway() { # $1 litellm|omniroute
  ensure_state_dirs
  printf '%s\n' "$1" > "${ACTIVE_GATEWAY_FILE}.tmp"
  mv -f "${ACTIVE_GATEWAY_FILE}.tmp" "$ACTIVE_GATEWAY_FILE"
  log_ok "Active gateway for Claude: $1"
}

gateway_port() { case "$1" in omniroute) printf '%s' "$OMNI_PORT" ;; *) printf '%s' "$LITELLM_PORT" ;; esac; }
gateway_label() { case "$1" in omniroute) printf '%s' "$LABEL_OMNI" ;; *) printf '%s' "$LABEL_LITELLM" ;; esac; }

# The key Claude must present to the active gateway
gateway_claude_token() { # $1 gateway
  case "$1" in
    omniroute)
      local k; k="$(read_secret "$OMNI_CLIENT_KEY_FILE")"
      [ -n "$k" ] || k="$(read_secret "$OMNI_MASTER_KEY_FILE")"
      printf '%s' "$k"
      ;;
    *)
      read_secret "$LITELLM_KEYFILE"
      ;;
  esac
}

merge_claude_settings() { # $1 target path $2 base_url $3 token $4 model_id
  local target="$1" base="$2" token="$3" model="$4" dir
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  if have python3; then
    FA_SETTINGS="$target" FA_BASE="$base" FA_TOKEN="$token" FA_MODEL="$model" FA_COMPACT="$AUTO_COMPACT_WINDOW" python3 - <<'PYEOF'
import json, os, sys

path = os.environ["FA_SETTINGS"]
base = os.environ["FA_BASE"]
token = os.environ["FA_TOKEN"]
model = os.environ["FA_MODEL"]
compact = os.environ.get("FA_COMPACT") or ""

data = {}
if os.path.exists(path):
    raw = open(path, encoding="utf-8").read().strip()
    if raw:
        try:
            data = json.loads(raw)
        except Exception:
            # keep the broken file - the caller already made a timestamped backup
            data = {}
if not isinstance(data, dict):
    data = {}

env = data.get("env")
if not isinstance(env, dict):
    env = {}

env["ANTHROPIC_BASE_URL"] = base
env["ANTHROPIC_AUTH_TOKEN"] = token
env.pop("ANTHROPIC_API_KEY", None)          # bearer token only: no double credential
env["ANTHROPIC_MODEL"] = model
env["ANTHROPIC_DEFAULT_OPUS_MODEL"] = model
env["ANTHROPIC_DEFAULT_SONNET_MODEL"] = model
env["ANTHROPIC_DEFAULT_HAIKU_MODEL"] = model
env["ANTHROPIC_SMALL_FAST_MODEL"] = model
env["CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"] = "1"
env["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
env["CLAUDE_CODE_ATTRIBUTION_HEADER"] = "0"
if compact:
    # The gateway can route to providers with a smaller window than the default
    # 200k assumption, so tell Claude Code when to auto-compact.
    env["CLAUDE_CODE_AUTO_COMPACT_WINDOW"] = compact

data["env"] = env
data["model"] = model
if "hasCompletedOnboarding" not in data:
    data["hasCompletedOnboarding"] = True
data.setdefault("$schema", "https://json.schemastore.org/claude-code-settings.json")

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, ensure_ascii=False)
    fh.write("\n")
os.replace(tmp, path)
print("merged")
PYEOF
    chmod 600 "$target" 2>/dev/null || true
    return 0
  fi
  # No python3: never clobber an existing file, write only when it is absent.
  if [ -s "$target" ]; then
    log_warn "       python3 is not available - leaving the existing ${target} untouched."
    return 1
  fi
  cat > "$target" <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "${base}",
    "ANTHROPIC_AUTH_TOKEN": "${token}",
    "ANTHROPIC_MODEL": "${model}",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "${model}",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "${model}",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "${model}",
    "ANTHROPIC_SMALL_FAST_MODEL": "${model}",
    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "CLAUDE_CODE_AUTO_COMPACT_WINDOW": "${AUTO_COMPACT_WINDOW}"
  }
}
EOF
  chmod 600 "$target" 2>/dev/null || true
  return 0
}

configure_claude_code() {
  local gw="$1"
  if ! windows_integration_available; then
    log_warn "       Claude Code settings skipped (no Windows integration)."
    return 0
  fi
  local win_home target token port base
  win_home="$(get_windows_home)" || { log_warn "       Could not resolve the Windows profile."; return 0; }
  [ -d "$win_home" ] || { log_warn "       Windows profile path does not exist: ${win_home}"; return 0; }
  target="${win_home}/.claude/settings.json"
  port="$(gateway_port "$gw")"
  base="http://127.0.0.1:${port}"
  token="$(gateway_claude_token "$gw")"
  if [ -z "$token" ]; then
    log_warn "       No API token for '${gw}' yet - Claude Code settings not written."
    return 0
  fi
  mkdir -p "$(dirname "$target")"
  if [ -f "$target" ]; then
    cp "$target" "${target}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
  fi
  if merge_claude_settings "$target" "$base" "$token" "$MODEL_ID"; then
    log_ok "       Claude Code settings written: ${target}"
    log_ok "       Gateway: ${base}  |  model: ${MODEL_ID}  ($(gateway_label "$gw"))"
  fi
}

write_desktop_profile() { # $1 gateway
  local gw="$1" root lib profile meta deskcfg pid label token port base
  windows_integration_available || { log_warn "       Claude Desktop profile skipped (no Windows integration)."; return 0; }
  local local_app
  local_app="$(get_windows_localappdata 2>/dev/null || true)"
  if [ -z "$local_app" ]; then
    local wh; wh="$(get_windows_home 2>/dev/null || true)"
    [ -n "$wh" ] && local_app="${wh}/AppData/Local"
  fi
  [ -n "$local_app" ] || { log_warn "       Could not locate %LOCALAPPDATA%."; return 0; }

  case "$gw" in
    omniroute) pid="$DESKTOP_PROFILE_ID_OMNI"    ;;
    *)         pid="$DESKTOP_PROFILE_ID_LITELLM" ;;
  esac
  label="$(gateway_label "$gw")"
  port="$(gateway_port "$gw")"
  base="http://127.0.0.1:${port}"
  token="$(gateway_claude_token "$gw")"
  if [ -z "$token" ]; then
    log_warn "       No API token for '${gw}' yet - desktop profile not written."
    return 0
  fi
  root="${local_app}/Claude-3p"
  lib="${root}/configLibrary"
  profile="${lib}/${pid}.json"
  meta="${lib}/_meta.json"
  deskcfg="${root}/claude_desktop_config.json"
  mkdir -p "$lib" 2>/dev/null || { log_warn "       Cannot create ${lib}"; return 0; }

  FA_DESK_PROFILE="$profile" FA_BASE="$base" FA_TOKEN="$token" FA_LABEL="$label" FA_MODEL="$MODEL_ID" \
  FA_CATALOG="$CATALOG_MODEL_ID" python3 - <<'PYEOF'
import json, os
profile = os.environ["FA_DESK_PROFILE"]
base = os.environ["FA_BASE"]
token = os.environ["FA_TOKEN"]
label = os.environ["FA_LABEL"]
model = os.environ["FA_MODEL"]
catalog = os.environ["FA_CATALOG"]

models = [{"name": catalog, "labelOverride": label, "isFamilyDefault": True}]
if model != catalog:
    models.append({"name": model, "labelOverride": label + " (auto)"})

data = {
    "inferenceProvider": "gateway",
    "inferenceCredentialKind": "static",
    "inferenceGatewayBaseUrl": base,
    "inferenceGatewayApiKey": token,
    "inferenceGatewayAuthScheme": "bearer",
    "modelDiscoveryEnabled": True,
    "chatTabEnabled": True,
    "disableEssentialTelemetry": True,
    "disableNonessentialTelemetry": True,
    "inferenceModels": models,
}
tmp = profile + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
os.replace(tmp, profile)
PYEOF
  chmod 600 "$profile" 2>/dev/null || true

  FA_META="$meta" FA_PID="$pid" FA_NAME="Free Agents" python3 - <<'PYEOF'
import json, os
path = os.environ["FA_META"]
pid = os.environ["FA_PID"]
name = os.environ["FA_NAME"]
meta = {"appliedId": pid, "entries": []}
if os.path.exists(path):
    try:
        meta = json.load(open(path, encoding="utf-8"))
    except Exception:
        meta = {"appliedId": pid, "entries": []}
entries = [e for e in (meta.get("entries") or []) if e.get("id") != pid]
entries.append({"id": pid, "name": name})
meta["entries"] = entries
known = {e.get("id") for e in entries}
cur = meta.get("appliedId")
if cur not in known or not cur:
    meta["appliedId"] = pid
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(meta, fh, indent=2)
    fh.write("\n")
os.replace(tmp, path)
PYEOF
  chmod 600 "$meta" 2>/dev/null || true

  if [ -f "$deskcfg" ] && python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$deskcfg" 2>/dev/null; then
    FA_DESKCFG="$deskcfg" python3 - <<'PYEOF'
import json, os
path = os.environ["FA_DESKCFG"]
data = json.load(open(path, encoding="utf-8"))
data["deploymentMode"] = "3p"
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
os.replace(tmp, path)
PYEOF
  else
    printf '{\n  "deploymentMode": "3p"\n}\n' > "$deskcfg" 2>/dev/null || true
  fi
  chmod 600 "$deskcfg" 2>/dev/null || true
  log_ok "       Claude Desktop profile written: ${profile} (label: ${label})"
}

configure_claude_all() { # $1 gateway (active) - writes code settings + both profiles
  local gw="$1"
  configure_claude_code "$gw"
  local e
  for e in litellm omniroute; do
    local installed=0
    [ "$e" = "litellm" ] && litellm_installed && installed=1
    [ "$e" = "omniroute" ] && omni_installed && installed=1
    [ "$installed" -eq 1 ] && write_desktop_profile "$e"
  done
  return 0
}

#-------------------------------------------------------------------------------
# Auto-start on WSL boot (systemd units or a single /etc/wsl.conf boot command)
#-------------------------------------------------------------------------------
write_boot_helper() {
  $SUDO mkdir -p "$(dirname "$BOOT_HELPER")" 2>/dev/null || true
  {
    echo '#!/usr/bin/env bash'
    echo '# Auto-generated by setup.sh - starts Docker and both gateways at WSL boot.'
    echo 'LOG="${TMPDIR:-/tmp}/freeagents-boot.log"'
    echo '{'
    echo '  if [ "$(id -u)" -eq 0 ]; then S=""; else S="sudo"; fi'
    echo '  $S service docker start >/dev/null 2>&1 || true'
    echo '  for i in $(seq 1 30); do $S docker info >/dev/null 2>&1 && break; sleep 1; done'
    echo '  if $S docker ps -a --format "{{.Names}}" 2>/dev/null | grep -qx litellm; then'
    echo '    $S docker start litellm >/dev/null 2>&1 || true'
    echo '  fi'
    echo '  if command -v omniroute >/dev/null 2>&1; then'
    echo "    if [ -f \"${OMNI_LAUNCHER}\" ]; then"
    echo "      pgrep -f 'omniroute serve' >/dev/null 2>&1 || nohup \"${OMNI_LAUNCHER}\" >/dev/null 2>&1 &"
    echo '    fi'
    echo '  fi'
    echo '} >>"$LOG" 2>&1'
  } | $SUDO tee "${BOOT_HELPER}.tmp" >/dev/null
  $SUDO mv -f "${BOOT_HELPER}.tmp" "$BOOT_HELPER"
  $SUDO chmod 755 "$BOOT_HELPER"
}

write_litellm_systemd_unit() {
  $SUDO mkdir -p "$(dirname "$SYSTEMD_UNIT_LITELLM")" 2>/dev/null || true
  printf '%s\n' \
    '[Unit]' \
    'Description=LiteLLM proxy container (Free AI Agents)' \
    'After=docker.service' \
    'Requires=docker.service' \
    '' \
    '[Service]' \
    'Type=oneshot' \
    'RemainAfterExit=yes' \
    "ExecStart=${BOOT_HELPER}" \
    '' \
    '[Install]' \
    'WantedBy=multi-user.target' \
    | $SUDO tee "$SYSTEMD_UNIT_LITELLM" >/dev/null
}

configure_autostart() { # $1 gateway that needs the boot path
  log_info "Setting up auto-start on boot..."
  write_boot_helper
  if use_systemd; then
    $SUDO mkdir -p /etc/systemd/system
    if litellm_installed; then
      write_litellm_systemd_unit
      $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
      $SUDO systemctl enable litellm.service >/dev/null 2>&1 || true
    fi
    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
    AUTOSTART_MODE="systemd units (freeagents boot helper / omniroute.service)"
    log_ok "Auto-start on WSL boot: ${AUTOSTART_MODE}"
    return 0
  fi
  # No systemd: a single boot command starts everything
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
  log_ok "Auto-start on WSL boot: ${AUTOSTART_MODE}"
}

#-------------------------------------------------------------------------------
# Manager copy + unified CLI (freeagents)
#-------------------------------------------------------------------------------
refresh_manager_copy() {
  ensure_state_dirs
  if [ -f "$SCRIPT_PATH" ] && [ ! -c "$SCRIPT_PATH" ]; then
    cp -f "$SCRIPT_PATH" "${MANAGER_COPY}.tmp" 2>/dev/null && \
      mv -f "${MANAGER_COPY}.tmp" "$MANAGER_COPY" 2>/dev/null && \
      chmod 755 "$MANAGER_COPY" 2>/dev/null && \
      log_ok "       Manager copy stored: ${MANAGER_COPY}" && return 0
  fi
  # running from a pipe / process substitution: download instead
  if download_manager_copy; then
    log_ok "       Manager copy downloaded: ${MANAGER_COPY}"
    return 0
  fi
  log_warn "       Could not store the manager copy - 'freeagents' will re-download it on demand."
  return 1
}

download_manager_copy() { # $1 optional target
  local target="${1:-$MANAGER_COPY}" url tmp="${MANAGER_COPY}.dl"
  have curl || return 1
  ensure_state_dirs
  for url in "${SELF_RAW_URLS[@]}"; do
    if curl -fsSL --max-time 120 --retry 2 "$url" -o "$tmp" 2>/dev/null &&
       grep -q 'FREE_AGENTS_VERSION=' "$tmp" 2>/dev/null && bash -n "$tmp" 2>/dev/null; then
      chmod 755 "$tmp" 2>/dev/null || true
      mv -f "$tmp" "$target"
      return 0
    fi
  done
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

write_management_cli() {
  $SUDO mkdir -p "$(dirname "$CLI_BIN")" 2>/dev/null || true
  cat <<'LITEOF' | $SUDO tee "${CLI_BIN}.tmp" >/dev/null
#!/usr/bin/env bash
#===============================================================================
# freeagents - single management command for the Free AI Agents gateways
# (LiteLLM + OmniRoute). Installed by setup.sh.
#
#   freeagents                 open the interactive manager menu
#   freeagents up|down|restart start/stop/restart BOTH gateways
#   freeagents status          state + health of BOTH gateways
#   freeagents doctor [engine] deep diagnosis (providers + live model test)
#   freeagents logs [engine]   follow logs (engine: litellm|omniroute)
#   freeagents credentials     dashboard URLs / logins / API keys
#   freeagents update          re-download from the repo + reinstall
#   freeagents uninstall       remove everything this installer created
#===============================================================================
set -u

MANAGER_COPY="${HOME}/.free-ai-agents/setup.sh"
REPO_SLUG="im-JvD/FreeAI-Agents"
SELF_URLS=(
  "https://raw.githubusercontent.com/${REPO_SLUG}/main/setup.sh"
  "https://cdn.jsdelivr.net/gh/${REPO_SLUG}@main/setup.sh"
)

manager_usable() {
  [ -s "$MANAGER_COPY" ] || return 1
  grep -q 'FREE_AGENTS_VERSION=' "$MANAGER_COPY" 2>/dev/null || return 1
  bash -n "$MANAGER_COPY" 2>/dev/null || return 1
  return 0
}

fetch_manager() {
  local url tmp="${MANAGER_COPY}.dl"
  mkdir -p "$(dirname "$MANAGER_COPY")" 2>/dev/null || true
  for url in "${SELF_URLS[@]}"; do
    if curl -fsSL --max-time 120 --retry 2 "$url" -o "$tmp" 2>/dev/null &&
       grep -q 'FREE_AGENTS_VERSION=' "$tmp" 2>/dev/null && bash -n "$tmp" 2>/dev/null; then
      chmod 755 "$tmp" 2>/dev/null || true
      mv -f "$tmp" "$MANAGER_COPY"
      return 0
    fi
  done
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

if ! manager_usable; then
  echo "[INFO] Fetching the Free AI Agents manager from ${REPO_SLUG} ..."
  if ! fetch_manager; then
    echo "[FAIL] Could not download the manager from:" >&2
    printf '       %s\n' "${SELF_URLS[@]}" >&2
    echo "       Run the installer again when the network is available:" >&2
    echo "       bash <(curl -fsSL ${SELF_URLS[0]})" >&2
    exit 1
  fi
fi

if [ "$#" -eq 0 ]; then
  exec bash "$MANAGER_COPY"
fi

case "$1" in
  help|-h|--help)
    sed -n '3,16p' "$MANAGER_COPY" 2>/dev/null | sed 's/^# \{0,1\}//' || true
    cat <<'USAGE'
Usage: freeagents [command]

  (no args)            open the interactive manager menu
  up                   start BOTH gateways (Docker daemon if needed)
  down                 stop BOTH gateways
  restart              restart BOTH gateways and wait until healthy
  status               state, health, ports and files of BOTH gateways
  doctor [engine]      deep diagnosis (engine: litellm|omniroute, default both)
  logs [engine]        follow logs (engine: litellm|omniroute, default litellm)
  credentials          dashboard URLs, logins and Claude tokens
  update               re-download from the repo + full reinstall (keys kept)
  uninstall [--yes]    remove everything this installer created
USAGE
    exit 0
    ;;
esac

exec bash "$MANAGER_COPY" "$@"
LITEOF
  $SUDO mv -f "${CLI_BIN}.tmp" "$CLI_BIN"
  $SUDO chmod 755 "$CLI_BIN"
  # legacy single-gateway CLIs must NOT exist anymore (requirement: no
  # 'omni up/down' and no 'litellm up/down' commands)
  local b
  for b in "${LEGACY_CLI_BINS[@]}"; do
    if $SUDO test -f "$b"; then
      $SUDO rm -f "$b" && log_info "       Removed legacy command: ${b}"
    fi
  done
  log_ok "Management CLI installed: ${CLI_BIN}"
}

write_live_test() {
  ensure_state_dirs
  # Try to copy from the cloned repo first (when running from a local checkout)
  local src=""
  for cand in \
    "${SCRIPT_PATH%/*}/freeagents/live_test.sh" \
    "${SCRIPT_PATH%/*}/tests/e2e_live_upstream.sh" \
    "${HOME}/FreeAI-Agents/freeagents/live_test.sh" \
    "./freeagents/live_test.sh"; do
    if [ -f "$cand" ]; then src="$cand"; break; fi
  done
  if [ -n "$src" ]; then
    cp -f "$src" "${LIVE_TEST_FILE}.tmp" 2>/dev/null && \
      mv -f "${LIVE_TEST_FILE}.tmp" "$LIVE_TEST_FILE" 2>/dev/null && \
      chmod 755 "$LIVE_TEST_FILE" 2>/dev/null && \
      { log_ok "       Live test installed: ${LIVE_TEST_FILE}"; return 0; }
  fi
  # Fallback: embedded version (works even when running via curl pipe)
  cat > "${LIVE_TEST_FILE}.tmp" <<'LIVE_EOF'
#!/usr/bin/env bash
#===============================================================================
# freeagents/live_test.sh - LIVE upstream validation (installed to STATE_DIR)
# This file is auto-generated by setup.sh and removed on uninstall.
# Source: freeagents/live_test.sh in the repo (or embedded fallback).
#===============================================================================
set -u
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || echo "$HOME")"
SCRIPT_FILE="${ROOT_DIR}/setup.sh"
if [ ! -f "$SCRIPT_FILE" ]; then SCRIPT_FILE="${HOME}/.free-ai-agents/setup.sh"; fi
RESULTS_DIR="${HOME}/.free-ai-agents/logs"
LOG_FILE="${RESULTS_DIR}/live_test.log"
SUMMARY_FILE="${HOME}/.free-ai-agents/logs/summary.txt"
WORK="$(mktemp -d /tmp/freeagents-live.XXXXXX)"
ENGINE="${E2E_ENGINE:-both}"
MODEL_ID="claude-freeagents"
CATALOG_ID="claude-sonnet-4-5"
LITELLM_PORT="${LITELLM_PORT:-4000}"
OMNI_PORT="${OMNIROUTE_PORT:-20128}"
FAILURES=0
WARN=0
cleanup() { rm -rf "$WORK"; return 0; }
trap cleanup EXIT INT TERM
mkdir -p "$RESULTS_DIR"
: > "$LOG_FILE"
log()  { echo "[LIVE-E2E] $*" | tee -a "$LOG_FILE"; }
fail() { echo "[LIVE-E2E] FAIL - $*" | tee -a "$LOG_FILE"; FAILURES=$((FAILURES+1)); }
ok()   { echo "[LIVE-E2E] ok  - $*" | tee -a "$LOG_FILE"; }
warn() { echo "[LIVE-E2E] WARN - $*" | tee -a "$LOG_FILE"; WARN=$((WARN+1)); }
mask_key() { local k="$1" l; l=${#k}; if [ "$l" -le 8 ]; then printf '****'; else printf '%s****%s' "${k:0:4}" "${k:l-4:4}"; fi; }
log "==============================================================="
log "LIVE upstream E2E (engine: ${ENGINE}, model: ${MODEL_ID})"
log "==============================================================="
LIB="${WORK}/setup_lib.sh"
if [ -f "$SCRIPT_FILE" ]; then sed '$ d' "$SCRIPT_FILE" > "$LIB" 2>/dev/null || true; else : > "$LIB"; fi
KEY_GROQ=""; KEY_OPENROUTER=""; KEY_GEMINI=""; KEY_CEREBRAS=""; KEY_MISTRAL=""
KEY_GITHUB=""; KEY_SAMBANOVA=""; KEY_NVIDIA_NIM=""; KEY_TOGETHER_AI=""
set +eu
# shellcheck source=/dev/null
[ -f "$LIB" ] && source "$LIB" 2>/dev/null || true
set -u; set +e
if ! command -v curl >/dev/null 2>&1; then log "SKIP - curl not found"; exit 0; fi
if ! command -v python3 >/dev/null 2>&1; then log "SKIP - python3 not found"; exit 0; fi
for kf in "${HOME}/.free-ai-agents/provider_keys.env"; do
  if [ -f "$kf" ]; then
    log "    loading keys from ${kf}"
    set +eu; set -a; . "$kf" 2>/dev/null || true; set +a; set -u; set +e
  fi
done
set +eu
for env_name in GROQ_API_KEY OPENROUTER_API_KEY GEMINI_API_KEY CEREBRAS_API_KEY MISTRAL_API_KEY GITHUB_API_KEY SAMBANOVA_API_KEY NVIDIA_NIM_API_KEY TOGETHERAI_API_KEY; do
  v="$(printenv "$env_name" 2>/dev/null || true)"
  if [ -n "$v" ]; then
    case "$env_name" in
      GROQ_API_KEY) KEY_GROQ="$v" ;;
      OPENROUTER_API_KEY) KEY_OPENROUTER="$v" ;;
      GEMINI_API_KEY) KEY_GEMINI="$v" ;;
      CEREBRAS_API_KEY) KEY_CEREBRAS="$v" ;;
      MISTRAL_API_KEY) KEY_MISTRAL="$v" ;;
      GITHUB_API_KEY) KEY_GITHUB="$v" ;;
      SAMBANOVA_API_KEY) KEY_SAMBANOVA="$v" ;;
      NVIDIA_NIM_API_KEY) KEY_NVIDIA_NIM="$v" ;;
      TOGETHERAI_API_KEY) KEY_TOGETHER_AI="$v" ;;
    esac
  fi
done
set -u; set +e
set +eu
if declare -f configured_providers >/dev/null 2>&1; then
  CONFIGURED="$(configured_providers 2>/dev/null | tr '\n' ' ' || true)"
  CONFIGURED_COUNT="$(configured_provider_count 2>/dev/null || echo 0)"
else
  CONFIGURED=""; CONFIGURED_COUNT=0
fi
set -u; set +e
if [ "${CONFIGURED_COUNT:-0}" -eq 0 ]; then
  log "SKIP - no real provider keys found (checked ~/.free-ai-agents/provider_keys.env + env vars)."
  log "     Install first with real keys: bash setup.sh  (choose Both)"
  exit 0
fi
log "    configured providers (${CONFIGURED_COUNT}): ${CONFIGURED}"
if ! grep -qi "microsoft" /proc/version 2>/dev/null; then warn "not running inside WSL - Windows checks skipped"; fi
if ! curl -s --max-time 10 -o /dev/null https://api.groq.com 2>/dev/null; then warn "internet seems blocked"; fi
if [ "$ENGINE" = "litellm" ] || [ "$ENGINE" = "both" ]; then
  log "[1] LiteLLM live validation"
  if ! command -v docker >/dev/null 2>&1; then fail "docker not found"; else
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "litellm" && ok "container 'litellm' running" || fail "container 'litellm' not running"
  fi
  MASTER_KEY="$(cat "${HOME}/.litellm/master_key.txt" 2>/dev/null | tr -d '\n' || true)"
  [ -n "$MASTER_KEY" ] && ok "master key present ($(mask_key "$MASTER_KEY"))" || fail "master key missing"
  CONFIG="${HOME}/.litellm/config.yaml"
  if [ -f "$CONFIG" ]; then
    DEPLOYS="$(grep -c "model_name: ${MODEL_ID}" "$CONFIG" || true)"
    ok "config.yaml has ${DEPLOYS} deployment(s) behind '${MODEL_ID}'"
  else
    fail "config.yaml not found"
  fi
  HEALTH="000"
  if [ -n "$MASTER_KEY" ]; then
    for _ in $(seq 1 8); do
      HEALTH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${LITELLM_PORT}/health/liveliness" 2>/dev/null || true)"
      [ "$HEALTH" = "200" ] && break; sleep 1
    done
    [ "$HEALTH" = "200" ] && ok "GET /health/liveliness -> 200" || fail "health -> ${HEALTH:-none}"
  fi
  if [ -n "$MASTER_KEY" ]; then
    MODELS="$(curl -s --max-time 10 -H "Authorization: Bearer ${MASTER_KEY}" "http://127.0.0.1:${LITELLM_PORT}/v1/models" | python3 -c 'import json,sys; print(",".join(sorted(m["id"] for m in json.load(sys.stdin).get("data",[]))))' 2>/dev/null || true)"
    [ "$MODELS" = "$MODEL_ID" ] && ok "GET /v1/models -> exactly ['${MODEL_ID}']" || fail "GET /v1/models returned '${MODELS}'"
    log "    live chat test via ${MODEL_ID} (real upstream)..."
    CHAT_BODY="${WORK}/litellm_chat.json"
    CHAT_CODE="$(curl -s -o "$CHAT_BODY" -w '%{http_code}' --max-time 60 -H "Authorization: Bearer ${MASTER_KEY}" -H 'content-type: application/json' -d "{\"model\":\"${MODEL_ID}\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}]}" "http://127.0.0.1:${LITELLM_PORT}/v1/chat/completions" 2>/dev/null || true)"
    [ "$CHAT_CODE" = "200" ] && ok "POST /v1/chat/completions ${MODEL_ID} -> 200 (real upstream works!)" || fail "POST /v1/chat/completions -> ${CHAT_CODE}"
  fi
  if command -v freeagents >/dev/null 2>&1; then
    freeagents doctor litellm >> "$LOG_FILE" 2>&1 && ok "freeagents doctor litellm -> OK" || warn "doctor litellm reported failures"
  fi
fi
if [ "$ENGINE" = "omniroute" ] || [ "$ENGINE" = "both" ]; then
  log "[2] OmniRoute live validation"
  [ -f "${HOME}/.omniroute/.env" ] && ok "~/.omniroute/.env exists" || fail "~/.omniroute/.env not found"
  OMNI_HEALTH="000"
  if [ -f "${HOME}/.omniroute/.env" ]; then
    for _ in $(seq 1 8); do
      OMNI_HEALTH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${OMNI_PORT}/healthz" 2>/dev/null || true)"
      [ "$OMNI_HEALTH" = "200" ] && break; sleep 1
    done
    [ "$OMNI_HEALTH" = "200" ] && ok "GET /healthz -> 200" || fail "GET /healthz -> ${OMNI_HEALTH:-none}"
  fi
  if [ "$OMNI_HEALTH" = "200" ]; then
    OMNI_PASS="$(grep "^INITIAL_PASSWORD=" "${HOME}/.omniroute/.env" 2>/dev/null | cut -d= -f2- | head -1)"
    JAR="${WORK}/omni_jar.txt"
    LOGIN_CODE="$(curl -s -c "$JAR" -o "${WORK}/omni_login.json" -w '%{http_code}' --max-time 20 -H 'content-type: application/json' -d "{\"password\":\"${OMNI_PASS}\"}" "http://127.0.0.1:${OMNI_PORT}/api/auth/login" 2>/dev/null || true)"
    [ "$LOGIN_CODE" = "200" ] || [ "$LOGIN_CODE" = "201" ] && ok "dashboard login -> ${LOGIN_CODE}" || fail "dashboard login failed ${LOGIN_CODE}"
    if [ "$LOGIN_CODE" = "200" ] || [ "$LOGIN_CODE" = "201" ]; then
      COMBO_JSON="${WORK}/omni_combos.json"
      curl -s --max-time 20 -b "$JAR" "http://127.0.0.1:${OMNI_PORT}/api/combos" -o "$COMBO_JSON" 2>/dev/null || true
      COMBOS="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d=d if isinstance(d,list) else d.get("combos",[]); print(",".join(str(c.get("name")) for c in d if isinstance(c,dict)))' "$COMBO_JSON" 2>/dev/null || true)"
      echo ",$COMBOS," | grep -q ",${MODEL_ID}," && ok "combo '${MODEL_ID}' exists" || fail "combo '${MODEL_ID}' not found"
      OMNI_TOKEN="$(cat "${HOME}/.free-ai-agents/omniroute_claude.key" 2>/dev/null | tr -d '\n' || cat "${HOME}/.free-ai-agents/omniroute_master.key" 2>/dev/null | tr -d '\n' || true)"
      if [ -n "$OMNI_TOKEN" ]; then
        OMSG_BODY="${WORK}/omni_msg.json"
        OMSG_CODE="$(curl -s -o "$OMSG_BODY" -w '%{http_code}' --max-time 60 -H "Authorization: Bearer ${OMNI_TOKEN}" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -d "{\"model\":\"${MODEL_ID}\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}]}" "http://127.0.0.1:${OMNI_PORT}/v1/messages" 2>/dev/null || true)"
        [ "$OMSG_CODE" = "200" ] && ok "POST /v1/messages ${MODEL_ID} via OmniRoute -> 200" || fail "POST /v1/messages -> ${OMSG_CODE}"
      fi
    fi
  fi
  if command -v freeagents >/dev/null 2>&1; then
    freeagents doctor omniroute >> "$LOG_FILE" 2>&1 && ok "freeagents doctor omniroute -> OK" || warn "doctor omniroute reported failures"
  fi
fi
log "[3] integration checks"
if command -v freeagents >/dev/null 2>&1; then
  freeagents status >> "$LOG_FILE" 2>&1 && ok "freeagents status -> OK" || fail "freeagents status failed"
fi
log "==============================================================="
log "Providers tested: ${CONFIGURED_COUNT} (${CONFIGURED})"
log "Failures: ${FAILURES}, Warnings: ${WARN}"
if [ "$FAILURES" -eq 0 ]; then log "LIVE RESULT: PASS"; exit 0; else log "LIVE RESULT: FAIL (${FAILURES})"; exit 1; fi
LIVE_EOF
  mv -f "${LIVE_TEST_FILE}.tmp" "$LIVE_TEST_FILE" 2>/dev/null || true
  chmod 755 "$LIVE_TEST_FILE" 2>/dev/null || true
  log_ok "       Live test installed: ${LIVE_TEST_FILE}"
  return 0
}

#===============================================================================
# Engine lifecycle helpers used by the menu / CLI
#===============================================================================
start_litellm_engine() {
  if ! litellm_installed; then
    log_warn "LiteLLM: not installed (menu item 1 installs it)."
    return 1
  fi
  if have docker; then
    if ! $SUDO docker info >/dev/null 2>&1; then
      log_info "LiteLLM: starting the Docker daemon..."
      $SUDO service docker start >/dev/null 2>&1 || true
      local i
      for i in $(seq 1 20); do $SUDO docker info >/dev/null 2>&1 && break; sleep 1; done
    fi
  fi
  if litellm_container_running; then
    log_ok "LiteLLM: already running."
  else
    $SUDO docker start "$CONTAINER_NAME" >/dev/null 2>&1 || { log_error "LiteLLM: docker start failed."; return 1; }
    log_ok "LiteLLM: container started."
  fi
  wait_for_litellm
  return 0
}

stop_litellm_engine() {
  litellm_installed || { log_info "LiteLLM: not installed."; return 0; }
  if litellm_container_running; then
    $SUDO docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    log_ok "LiteLLM: stopped."
  else
    log_info "LiteLLM: already stopped."
  fi
  return 0
}

restart_litellm_engine() {
  litellm_installed || { log_warn "LiteLLM: not installed."; return 1; }
  $SUDO docker restart "$CONTAINER_NAME" >/dev/null 2>&1 || true
  log_ok "LiteLLM: restarted."
  wait_for_litellm
  return 0
}

start_omni_engine() {
  omni_installed || { log_warn "OmniRoute: not installed (menu item 1 installs it)."; return 1; }
  start_omni_service
  wait_for_omni
  return 0
}

stop_omni_engine() {
  omni_installed || { log_info "OmniRoute: not installed."; return 0; }
  stop_omni_service
  return 0
}

restart_omni_engine() {
  omni_installed || { log_warn "OmniRoute: not installed."; return 1; }
  stop_omni_service >/dev/null 2>&1 || true
  start_omni_service
  wait_for_omni
  return 0
}

#-------------------------------------------------------------------------------
# INSTALL - LiteLLM
#-------------------------------------------------------------------------------
install_litellm() {
  log_info "=== LiteLLM: installing ==="
  install_docker
  configure_docker_mirrors
  start_docker_daemon
  generate_master_key
  generate_litellm_config
  pull_litellm_image
  start_litellm_container
  wait_for_litellm
  log_ok "LiteLLM engine ready on http://127.0.0.1:${LITELLM_PORT}"
  return 0
}

#-------------------------------------------------------------------------------
# INSTALL - OmniRoute
#-------------------------------------------------------------------------------
install_omniroute() {
  log_info "=== OmniRoute: installing (official npm package) ==="
  ensure_node_runtime
  npm_install_omniroute
  write_omni_env
  start_omni_service
  wait_for_omni
  configure_omniroute
  omni_verify || true
  log_ok "OmniRoute engine ready on http://127.0.0.1:${OMNI_PORT}"
  return 0
}

#-------------------------------------------------------------------------------
# INSTALL - orchestrator (keys + proxy are collected exactly ONCE)
#-------------------------------------------------------------------------------
full_install() { # $1 = litellm | omniroute | both
  local engine="${1:-both}"
  echo
  log_info "=== FREE AI AGENTS INSTALL (${engine}) ==="
  echo

  check_environment
  collect_keys

  case "$engine" in
    litellm)   install_litellm ;;
    omniroute) install_omniroute ;;
    both)
      install_litellm
      install_omniroute
      ;;
  esac

  # the active gateway decides where Claude points by default
  case "$engine" in
    omniroute) set_active_gateway omniroute >/dev/null ;;
    litellm)   set_active_gateway litellm >/dev/null ;;
    both)      set_active_gateway litellm >/dev/null ;;
  esac

  configure_autostart "$engine"
  configure_claude_all "$(active_gateway)"
  refresh_manager_copy || true
  write_management_cli
  write_live_test || true
  save_provider_keys

  print_install_success "$engine"
}

print_install_success() {
  local engine="$1" gw
  gw="$(active_gateway)"
  echo
  echo -e "${C_GREEN}${C_BOLD}================================================================="
  echo "  INSTALLATION COMPLETED SUCCESSFULLY!"
  echo -e "=================================================================${C_NC}"
  echo
  echo "  Engines installed : ${engine}"
  echo "  Active gateway    : ${gw}  ($(gateway_label "$gw"))"
  echo "  Model for Claude  : ${MODEL_ID}"
  echo
  if litellm_installed; then
    echo -e "${C_BOLD}  LiteLLM${C_NC}"
    echo "    Endpoint    : http://127.0.0.1:${LITELLM_PORT}/v1"
    echo "    Admin panel : http://127.0.0.1:${LITELLM_PORT}/ui  (user: admin)"
    echo "    Master key  : ${LITELLM_KEYFILE}   (also the dashboard password)"
    echo "    Config      : ${LITELLM_CONFIG}"
  fi
  if omni_installed; then
    echo -e "${C_BOLD}  OmniRoute${C_NC}"
    echo "    Endpoint    : http://127.0.0.1:${OMNI_PORT}/v1"
    echo "    Dashboard   : http://127.0.0.1:${OMNI_PORT}"
    echo "    Dashboard   : password stored in ${OMNI_ENV_FILE} (INITIAL_PASSWORD)"
    echo "    Claude key  : ${OMNI_CLIENT_KEY_FILE}"
  fi
  echo
  echo "  Claude Code settings : %USERPROFILE%\\.claude\\settings.json"
  echo "  Auto-start on boot   : ${AUTOSTART_MODE}"
  echo "  Windows proxy        : ${WIN_PROXY_URL:-disabled}"
  echo
  echo -e "${C_BOLD}  MANAGEMENT${C_NC}"
  echo "    freeagents                 open this menu"
  echo "    freeagents status          both gateways"
  echo "    freeagents doctor          deep diagnosis (both)"
  echo "    freeagents logs omniroute  live logs of the second engine"
  echo "    ${LIVE_TEST_FILE}     live upstream test (real keys, both gateways)"
  echo
  echo -e "${C_BOLD}  NEXT STEPS (on WINDOWS)${C_NC}"
  echo "    1. Install Claude Code (once):  irm https://claude.ai/install.ps1 | iex"
  echo "    2. Open a NEW terminal and run: claude"
  echo "    3. Pick the model with /model - it is listed as '${MODEL_ID}'"
  echo "       (Claude Desktop shows it as '$(gateway_label "$gw")')."
  echo
  log_ok "Done. Happy coding!"
}

#-------------------------------------------------------------------------------
# STATUS / DOCTOR / LOGS / CREDENTIALS - every command serves BOTH gateways
#-------------------------------------------------------------------------------
show_status() {
  local gw; gw="$(active_gateway)"
  echo
  log_info "=== LITELLM (port ${LITELLM_PORT}) ==="
  if litellm_installed; then
    echo "  container : $(litellm_container_running && echo running || echo STOPPED)"
    echo "  health    : HTTP $(litellm_health_code)"
    echo "  dashboard : http://127.0.0.1:${LITELLM_PORT}/ui"
    echo "  model id  : ${MODEL_ID}"
    echo "  config    : ${LITELLM_CONFIG}"
  else
    echo "  not installed"
  fi

  echo
  log_info "=== OMNIROUTE (port ${OMNI_PORT}) ==="
  if omni_installed; then
    echo "  service   : $(omni_process_running && echo running || echo STOPPED)"
    echo "  health    : HTTP $(omni_health_code)   (/healthz)"
    echo "  dashboard : $(omni_base_url)"
    echo "  model id  : ${MODEL_ID}"
    echo "  data dir  : ${OMNI_DATA_DIR}"
  else
    echo "  not installed"
  fi

  echo
  if [ "$gw" = "omniroute" ]; then
    log_info "=== CLAUDE (active gateway: OmniRoute) ==="
  else
    log_info "=== CLAUDE (active gateway: LiteLLM) ==="
  fi
  echo "  model id  : ${MODEL_ID}"
  echo "  base URL  : http://127.0.0.1:$(gateway_port "$gw")"
  echo "  switch    : menu item 8 -> 5, or: freeagents (menu) -> Config Manager"
  return 0
}

doctor_engine() { # $1 = litellm|omniroute
  local engine="$1"
  echo
  echo "================================================="
  echo "                 ${engine^^} DOCTOR"
  echo "================================================="

  if [ "$engine" = "litellm" ]; then
    if ! litellm_installed; then echo "  not installed"; return 0; fi
    echo "[STACK]"
    echo "  container     : $(litellm_container_running && echo running || echo STOPPED)"
    echo "  health        : HTTP $(litellm_health_code)"
    if $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_CONTAINER"; then
      echo "  ui database   : $($SUDO docker inspect -f '{{.State.Status}}' "$DB_CONTAINER" 2>/dev/null || echo unknown)"
    else
      echo "  ui database   : not installed (UI login unavailable, chat still works)"
    fi
    echo "  windows proxy : ${WIN_PROXY_URL:-disabled}"
    echo
    echo "[PROVIDER KEYS]"
    local p k
    for p in $(all_provider_ids); do
      k="$(provider_key "$p")"
      if [ -n "$k" ]; then
        printf '  %-16s: %s\n' "$(provider_label "$p")" "$(mask_key "$k")"
      fi
    done
    [ "$(configured_provider_count)" -ge 1 ] || echo "  no keys configured"
    echo
    echo "[MODEL LIVE TEST]  POST /v1/chat/completions via ${MODEL_ID}"
    local mk code body
    mk="$(read_secret "$LITELLM_KEYFILE")"
    if [ -z "$mk" ]; then echo "  master key missing"; return 1; fi
    body="$(mktemp)"
    code="$(curl -s -o "$body" -w '%{http_code}' --max-time "${FREEAGENTS_DOCTOR_TIMEOUT:-60}" \
      -X POST -H "Authorization: Bearer ${mk}" -H 'Content-Type: application/json' \
      -d "{\"model\":\"${MODEL_ID}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":8}" \
      "http://127.0.0.1:${LITELLM_PORT}/v1/chat/completions" 2>/dev/null || true)"
    if [ "$code" = "200" ]; then
      echo "  OK   ${MODEL_ID}"
    else
      echo "  FAIL ${MODEL_ID} (HTTP ${code:-none}): $(head -c 200 "$body" 2>/dev/null | tr '\n' ' ')"
      echo "  Hints:"
      echo "   - 401/403 from a provider: the network is geo-blocked - enable the Windows"
      echo "     proxy (menu 8 -> 1) or a VPN, then 'freeagents restart'."
      echo "   - 'Invalid model name': the config lost the model group - re-run install."
    fi
    rm -f "$body" 2>/dev/null || true
    return 0
  fi

  if ! omni_installed; then echo "  not installed"; return 0; fi
  echo "[STACK]"
  echo "  service       : $(omni_process_running && echo running || echo STOPPED)"
  echo "  health        : HTTP $(omni_health_code)   ($(omni_base_url)/healthz)"
  echo "  data dir      : ${OMNI_DATA_DIR}"
  echo "  log file      : ${OMNI_LOG_FILE}"
  echo "  node          : $(node -v 2>/dev/null || echo missing)"
  echo "  windows proxy : ${WIN_PROXY_URL:-disabled}"
  echo
  echo "[MODEL LIVE TEST]  POST /v1/messages via ${MODEL_ID}"
  local token code2 body2
  token="$(read_secret "$OMNI_CLIENT_KEY_FILE")"
  [ -n "$token" ] || token="$(read_secret "$OMNI_MASTER_KEY_FILE")"
  if [ -z "$token" ]; then echo "  no API key available"; return 1; fi
  body2="$(mktemp)"
  code2="$(curl -s -o "$body2" -w '%{http_code}' --max-time "${FREEAGENTS_DOCTOR_TIMEOUT:-60}" \
    -H "Authorization: Bearer ${token}" -H 'anthropic-version: 2023-06-01' \
    -H 'Content-Type: application/json' \
    -X POST "$(omni_base_url)/v1/messages" \
    -d "{\"model\":\"${MODEL_ID}\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}" 2>/dev/null || true)"
  if [ "$code2" = "200" ]; then
    echo "  OK   ${MODEL_ID}"
  else
    echo "  FAIL ${MODEL_ID} (HTTP ${code2:-none}): $(head -c 200 "$body2" 2>/dev/null | tr '\n' ' ')"
    echo "  Hints:"
    echo "   - Add/enable providers in the dashboard: $(omni_base_url)"
    echo "   - enable the Windows proxy (menu 8 -> 1) if providers are geo-blocked"
  fi
  rm -f "$body2" 2>/dev/null || true
  return 0
}

cmd_doctor() { # $1 optional engine
  load_windows_proxy
  load_provider_keys || true
  case "${1:-all}" in
    litellm)   doctor_engine litellm ;;
    omniroute|omni) doctor_engine omniroute ;;
    *) doctor_engine litellm; doctor_engine omniroute ;;
  esac
  return 0
}

cmd_status() { load_windows_proxy; load_provider_keys || true; show_status; }

cmd_credentials() {
  echo
  if litellm_installed; then
    local mk; mk="$(read_secret "$LITELLM_KEYFILE")"
    echo "  LiteLLM"
    echo "    Dashboard : http://127.0.0.1:${LITELLM_PORT}/ui   (user: admin)"
    echo "    Password  : ${mk}"
    echo "    API key   : ${mk}"
    echo "    Model id  : ${MODEL_ID}"
  else
    echo "  LiteLLM: not installed"
  fi
  echo
  if omni_installed; then
    local pass ck
    pass="$(get_env_line "$OMNI_ENV_FILE" INITIAL_PASSWORD || true)"
    ck="$(read_secret "$OMNI_CLIENT_KEY_FILE")"
    [ -n "$ck" ] || ck="$(read_secret "$OMNI_MASTER_KEY_FILE")"
    echo "  OmniRoute"
    echo "    Dashboard : $(omni_base_url)   (user: admin)"
    echo "    Password  : ${pass:-see ${OMNI_ENV_FILE}}"
    echo "    API key   : ${ck}"
    echo "    Model id  : ${MODEL_ID}"
  else
    echo "  OmniRoute: not installed"
  fi
  echo
  echo "  Claude uses the ACTIVE gateway: $(active_gateway) (switch: menu 8 -> 5)"
}

cmd_up()      { load_windows_proxy; load_provider_keys || true; log_info "=== START ==="; start_litellm_engine || true; start_omni_engine || true; }
cmd_down()    { log_info "=== STOP ==="; stop_litellm_engine || true; stop_omni_engine || true; }
cmd_restart() { load_windows_proxy; load_provider_keys || true; log_info "=== RESTART ==="; restart_litellm_engine || true; restart_omni_engine || true; }

cmd_logs() { # $1 optional engine
  case "${1:-litellm}" in
    omniroute|omni)
      if omni_installed; then
        echo "Following the OmniRoute log (Ctrl+C to exit)..."
        [ -f "$OMNI_LOG_FILE" ] && tail -f "$OMNI_LOG_FILE" || { echo "no log yet: ${OMNI_LOG_FILE}"; }
      else
        log_warn "OmniRoute: not installed."
      fi
      ;;
    *)
      if litellm_installed; then
        echo "Following the LiteLLM container log (Ctrl+C to exit)..."
        $SUDO docker logs -f --tail 100 "$CONTAINER_NAME"
      else
        log_warn "LiteLLM: not installed."
      fi
      ;;
  esac
  return 0
}

#===============================================================================
# Re-apply changes to the running engines (used by the Config Manager)
#===============================================================================
rebuild_litellm() {
  litellm_installed || { log_warn "LiteLLM: not installed."; return 1; }
  [ -s "$LITELLM_KEYFILE" ] && MASTER_KEY="$(read_secret "$LITELLM_KEYFILE")"
  generate_litellm_config
  build_docker_env_args
  remove_existing_container
  start_litellm_container
  wait_for_litellm
  log_ok "LiteLLM: container rebuilt with the current keys/proxy."
  return 0
}

apply_omni_config() {
  omni_installed || { log_warn "OmniRoute: not installed."; return 1; }
  write_omni_env
  # restart FIRST so the fresh .env (port, proxy, ...) is live, then apply the
  # managed configuration to that instance
  if omni_process_running; then
    restart_omni_engine >/dev/null 2>&1 || true
  fi
  configure_omniroute
  log_ok "OmniRoute: configuration applied."
  return 0
}

set_proxy_on() {
  configure_windows_proxy
  [ -n "$WIN_PROXY_URL" ] || return 1
  rebuild_litellm || true
  apply_omni_config || true
  return 0
}

set_proxy_off() {
  rm -f "$WIN_PROXY_FILE" 2>/dev/null || true
  WIN_PROXY_URL=""
  log_ok "Windows proxy disabled (direct connections)."
  rebuild_litellm || true
  apply_omni_config || true
  return 0
}

rekey_flow() {
  log_info "Re-entering provider keys (the Windows proxy setting is KEPT)..."
  FREEAGENTS_PROXY_MODE="keep"
  FREEAGENTS_FRESH_KEYS="1"   # ENTER really skips here (no stored value reload)
  KEY_GROQ=""; KEY_OPENROUTER=""; KEY_GEMINI=""; KEY_CEREBRAS=""; KEY_MISTRAL=""
  KEY_GITHUB=""; KEY_SAMBANOVA=""; KEY_NVIDIA_NIM=""; KEY_TOGETHER_AI=""
  collect_keys
  FREEAGENTS_FRESH_KEYS="0"
  rebuild_litellm || true
  apply_omni_config || true
  return 0
}

switch_active_gateway() {
  local cur other
  cur="$(active_gateway)"
  if [ "$cur" = "litellm" ]; then other="omniroute"; else other="litellm"; fi
  local other_ok=0
  [ "$other" = "litellm" ] && litellm_installed && other_ok=1
  [ "$other" = "omniroute" ] && omni_installed && other_ok=1
  if [ "$other_ok" -ne 1 ]; then
    log_warn "The other gateway (${other}) is not installed - nothing to switch to."
    return 1
  fi
  set_active_gateway "$other"
  configure_claude_all "$other"
  local pid
  if [ "$other" = "omniroute" ]; then pid="$DESKTOP_PROFILE_ID_OMNI"; else pid="$DESKTOP_PROFILE_ID_LITELLM"; fi
  local local_app meta
  local_app="$(get_windows_localappdata 2>/dev/null || true)"
  meta="${local_app}/Claude-3p/configLibrary/_meta.json"
  if [ -f "$meta" ] && have python3; then
    FA_META="$meta" FA_PID="$pid" python3 - <<'PYEOF'
import json, os
path = os.environ["FA_META"]; pid = os.environ["FA_PID"]
try:
    meta = json.load(open(path, encoding="utf-8"))
except Exception:
    raise SystemExit(0)
entries = meta.get("entries") or []
if any(e.get("id") == pid for e in entries):
    meta["appliedId"] = pid
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2)
        fh.write("\n")
PYEOF
  fi
  log_warn "Fully quit and restart the Claude apps so they pick up the new gateway."
  return 0
}

config_manager() {
  while true; do
    echo
    echo -e "${C_CYAN}${C_BOLD}  --- CONFIG MANAGER ---${C_NC}"
    echo -e "   ${C_GREEN}1${C_NC} - Windows proxy ${C_YELLOW}ON${C_NC}   (route ALL gateway traffic via your proxy)"
    echo -e "   ${C_GREEN}2${C_NC} - Windows proxy ${C_YELLOW}OFF${C_NC}  (direct connections)"
    echo -e "   ${C_GREEN}3${C_NC} - Re-enter provider tokens (applied to BOTH gateways)"
    echo -e "   ${C_GREEN}4${C_NC} - Re-apply Claude configs (settings.json + desktop profiles)"
    echo -e "   ${C_GREEN}5${C_NC} - Switch the ACTIVE gateway / desktop profile"
    echo -e "   ${C_GREEN}0${C_NC} - Back"
    local c=""
    read -r -p "   Config choice: " c || c="0"
    echo
    case "$c" in
      1) set_proxy_on ;;
      2) set_proxy_off ;;
      3) rekey_flow ;;
      4) configure_claude_all "$(active_gateway)" ;;
      5) switch_active_gateway ;;
      0|q|Q) return 0 ;;
      *) log_warn "Invalid choice: '${c}'." ;;
    esac
  done
}

#===============================================================================
# UPDATE: re-download from THIS repository, then reinstall (keys kept)
#===============================================================================
cmd_update() {
  printf "   Re-download the manager from %s and reinstall? Keys and the\n" "$REPO"
  printf "   Windows proxy setting are KEPT. Continue? [y/N]: "
  local answer=""
  read -r answer || answer=""
  case "$answer" in
    y|Y|yes|Yes|YES) : ;;
    *) log_info "Update cancelled."; return 0 ;;
  esac
  log_info "=== UPDATE: downloading the latest script from ${REPO} ==="
  local tmp="${STATE_DIR}/setup.sh.new" ok=1 url
  ensure_state_dirs
  for url in "${SELF_RAW_URLS[@]}"; do
    if curl -fsSL --max-time 120 --retry 2 "$url" -o "$tmp" 2>/dev/null; then ok=0; break; fi
  done
  if [ "$ok" -ne 0 ]; then
    log_warn "Update FAILED - could not download the script (network)."
    return 1
  fi
  if ! bash -n "$tmp" 2>/dev/null; then
    log_warn "Downloaded script failed the syntax check - keeping the current version."
    rm -f "$tmp"
    return 1
  fi
  if cmp -s "$tmp" "$SCRIPT_PATH" 2>/dev/null; then
    log_ok "Script is already up to date."
    rm -f "$tmp"
  else
    mv "$tmp" "$SCRIPT_PATH"
    chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    log_ok "Script updated: ${SCRIPT_PATH}"
  fi
  cp -f "$SCRIPT_PATH" "$MANAGER_COPY" 2>/dev/null || true
  chmod 755 "$MANAGER_COPY" 2>/dev/null || true

  load_provider_keys || true
  load_windows_proxy
  log_info "=== Re-running the installation (keys & proxy are KEPT) ==="
  local engine="both"
  [ "$(configured_provider_count)" -ge 1 ] || log_warn "No stored provider keys - the installer will ask again."
  if ! litellm_installed && omni_installed; then engine="omniroute"; fi
  if litellm_installed && ! omni_installed; then engine="litellm"; fi
  full_install "$engine"
}

#===============================================================================
# REMOVE - full wipe of everything this installer created (BOTH gateways)
#===============================================================================
full_uninstall() { # $1 optional --yes
  local assume_yes="${1:-}"
  if [ "$assume_yes" != "--yes" ] && [ "$assume_yes" != "-y" ]; then
    printf "   This removes BOTH gateways, all configs, the Claude wiring and\n"
    printf "   the freeagents command. Continue? [y/N]: "
    local answer=""
    read -r answer || answer=""
    case "$answer" in
      y|Y|yes|YES) : ;;
      *) log_info "Aborted."; return 1 ;;
    esac
  fi
  echo
  log_info "=== FULL UNINSTALL ==="

  # 1) LiteLLM
  if have docker; then
    if $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
      $SUDO docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
      $SUDO docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
      log_ok "LiteLLM container removed."
    fi
    if $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$DB_CONTAINER"; then
      $SUDO docker stop "$DB_CONTAINER" >/dev/null 2>&1 || true
      $SUDO docker rm "$DB_CONTAINER" >/dev/null 2>&1 || true
      log_ok "LiteLLM database container removed."
    fi
    $SUDO docker network rm "$DB_NETWORK" >/dev/null 2>&1 || true
    # leftovers from the legacy OmniRoute installer (Docker mode)
    if $SUDO docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "omniroute-app"; then
      $SUDO docker stop omniroute-app >/dev/null 2>&1 || true
      $SUDO docker rm omniroute-app >/dev/null 2>&1 || true
      log_ok "Removed the legacy OmniRoute container."
    fi
  fi

  # 2) OmniRoute (npm mode)
  stop_omni_service >/dev/null 2>&1 || true
  if have pm2; then
    pm2 delete omniroute >/dev/null 2>&1 && log_ok "Removed the legacy pm2 process." || true
    pm2 save >/dev/null 2>&1 || true
  fi
  if [ -f "$SYSTEMD_UNIT_OMNI" ]; then
    $SUDO systemctl disable omniroute.service >/dev/null 2>&1 || true
    $SUDO rm -f "$SYSTEMD_UNIT_OMNI"
    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
    log_ok "Removed the OmniRoute systemd unit."
  fi
  if [ "${FREEAGENTS_KEEP_NPM:-0}" = "1" ]; then
    log_info "Keeping the omniroute npm package (FREEAGENTS_KEEP_NPM=1)."
  elif have npm && have omniroute; then
    $SUDO npm uninstall -g "$OMNI_NPM_PACKAGE" >/dev/null 2>&1 && log_ok "Removed the omniroute npm package." || \
      log_warn "Could not remove the omniroute npm package (remove it manually if you want)."
  fi

  # 3) LiteLLM config + our state
  if [ -d "$LITELLM_DIR" ]; then
    rm -rf "$LITELLM_DIR" && log_ok "Removed ${LITELLM_DIR}"
  fi
  if [ -d "$OMNI_DATA_DIR" ]; then
    rm -rf "$OMNI_DATA_DIR" && log_ok "Removed ${OMNI_DATA_DIR}"
  fi
  local d
  for d in "${LEGACY_DIRS[@]}"; do
    [ -d "$d" ] || continue
    case "$d" in
      "$OMNI_DATA_DIR") continue ;;
    esac
    rm -rf "$d" 2>/dev/null && log_info "Removed legacy dir ${d}" || true
  done

  # 4) Claude wiring on the Windows side
  if windows_integration_available; then
    local wh cc newest
    wh="$(get_windows_home 2>/dev/null || true)"
    if [ -n "$wh" ] && [ -d "$wh" ]; then
      cc="${wh}/.claude/settings.json"
      if [ -f "$cc" ]; then
        if have python3; then
          FA_SETTINGS="$cc" python3 - <<'PYEOF' || rm -f "$cc"
import json, os
path = os.environ["FA_SETTINGS"]
try:
    data = json.load(open(path, encoding="utf-8"))
except Exception:
    data = {}
env = data.get("env")
changed = False
if isinstance(env, dict):
    for key in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL",
                "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_SMALL_FAST_MODEL",
                "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
                "CLAUDE_CODE_AUTO_COMPACT_WINDOW",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"):
        if key in env:
            env.pop(key, None)
            changed = True
if not env:
    data.pop("env", None)
else:
    data["env"] = env
if changed:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    print("clean")
PYEOF
        fi
        log_ok "Removed the gateway settings from Claude Code settings.json"
      fi
      newest="$(ls -1t "${wh}/.claude/settings.json.bak."* 2>/dev/null | head -1 || true)"
      if [ -n "$newest" ] && [ -f "$newest" ]; then
        cp "$newest" "$cc" && log_ok "Restored pre-install backup: ${newest}"
      fi
    fi
    local la lib
    la="$(get_windows_localappdata 2>/dev/null || true)"
    if [ -n "$la" ]; then
      lib="${la}/Claude-3p/configLibrary"
      local id
      for id in "$DESKTOP_PROFILE_ID_LITELLM" "$DESKTOP_PROFILE_ID_OMNI"; do
        if [ -f "${lib}/${id}.json" ]; then
          rm -f "${lib}/${id}.json" && log_ok "Removed desktop profile ${id}"
        fi
      done
      if [ -f "${lib}/_meta.json" ] && have python3; then
        FA_META="${lib}/_meta.json" FA_ID1="$DESKTOP_PROFILE_ID_LITELLM" FA_ID2="$DESKTOP_PROFILE_ID_OMNI" python3 - <<'PYEOF' || true
import json, os
path = os.environ["FA_META"]
ids = {os.environ["FA_ID1"], os.environ["FA_ID2"]}
try:
    meta = json.load(open(path, encoding="utf-8"))
except Exception:
    raise SystemExit(0)
entries = [e for e in (meta.get("entries") or []) if e.get("id") not in ids]
meta["entries"] = entries
if meta.get("appliedId") in ids:
    meta["appliedId"] = entries[0]["id"] if entries else None
with open(path, "w", encoding="utf-8") as fh:
    json.dump(meta, fh, indent=2)
    fh.write("\n")
PYEOF
      fi
    fi
  fi

  # 5) boot persistence + CLI + state
  if [ -f "$SYSTEMD_UNIT_LITELLM" ]; then
    $SUDO systemctl disable litellm.service >/dev/null 2>&1 || true
    $SUDO rm -f "$SYSTEMD_UNIT_LITELLM"
    $SUDO systemctl daemon-reload >/dev/null 2>&1 || true
    log_ok "Removed the litellm systemd unit."
  fi
  if $SUDO test -f "$BOOT_HELPER"; then
    $SUDO rm -f "$BOOT_HELPER" && log_ok "Removed the boot helper."
  fi
  if $SUDO test -f "$WSL_CONF" && $SUDO grep -qF "$BOOT_LINE" "$WSL_CONF" 2>/dev/null; then
    $SUDO sed -i "\|^${BOOT_LINE}\$|d" "$WSL_CONF"
    log_ok "Removed the boot entry from ${WSL_CONF}."
  fi
  local b
  for b in "${LEGACY_CLI_BINS[@]}" "$CLI_BIN"; do
    $SUDO test -f "$b" && { $SUDO rm -f "$b"; log_ok "Removed ${b}"; }
  done
  if [ -d "$STATE_DIR" ]; then
    rm -rf "$STATE_DIR" && log_ok "Removed ${STATE_DIR}"
  fi

  echo
  echo -e "${C_GREEN}${C_BOLD}================================================================="
  echo "  UNINSTALL COMPLETED SUCCESSFULLY!"
  echo -e "=================================================================${C_NC}"
  echo "  Removed: LiteLLM container + DB, OmniRoute service/package, both"
  echo "  gateway configs, the Claude wiring, boot persistence and freeagents."
  echo "  Kept: Docker itself, /etc/docker/daemon.json and pulled images."
  echo
  log_ok "Done."
  return 0
}

#===============================================================================
# Interactive menu
#===============================================================================
show_menu() {
  echo
  echo -e "${C_BLUE}${C_BOLD}================================================================="
  echo -e "=================================================================${C_NC}"
  echo -e "            ${C_GREEN}${C_BOLD}Free AI Agents${C_NC}${C_GREEN}  |  Local AI Gateway Manager${C_NC}"
  echo -e "            ${C_YELLOW}Script Version [ ${FREE_AGENTS_VERSION} ]${C_NC}   LiteLLM + OmniRoute"
  echo -e "${C_BLUE}${C_BOLD}================================================================="
  echo -e "=================================================================${C_NC}"
  echo
  echo -e "   ${C_GREEN}1${C_NC} - ${C_YELLOW}Install${C_NC}  ( LiteLLM / OmniRoute / Both )"
  echo -e "   ${C_GREEN}2${C_NC} - Start / Restart  ( both gateways )"
  echo -e "   ${C_GREEN}3${C_NC} - Stop             ( both gateways )"
  echo -e "   ${C_GREEN}4${C_NC} - ${C_YELLOW}Update${C_NC} ( re-download from the repo + reinstall, keeps keys )"
  echo -e "   ${C_GREEN}5${C_NC} - Show Status      ( both gateways )"
  echo -e "   ${C_GREEN}6${C_NC} - ${C_RED}Remove${C_NC} ( full wipe, both gateways )"
  echo -e "   ${C_GREEN}7${C_NC} - Show Live Logs   ( LiteLLM / OmniRoute )"
  echo -e "   ${C_GREEN}8${C_NC} - ${C_CYAN}Doctor${C_NC} ( deep diagnosis, both gateways )"
  echo -e "   ${C_GREEN}9${C_NC} - ${C_CYAN}Config Manager${C_NC} ( proxy - tokens - Claude config - active gateway )"
  echo -e "   ${C_GREEN}0${C_NC} - ${C_BOLD}Exit${C_NC} ( CTRL + C )"
  echo
}

choose_and_install() {
  echo
  echo -e "${C_BOLD}   Which gateway(s) do you want to install?${C_NC}"
  echo -e "     ${C_GREEN}1${C_NC} - ${C_BOLD}LiteLLM${C_NC}   (Docker, port ${LITELLM_PORT})          [default]"
  echo -e "     ${C_GREEN}2${C_NC} - ${C_BOLD}OmniRoute${C_NC} (npm package, port ${OMNI_PORT})"
  echo -e "     ${C_GREEN}3${C_NC} - ${C_BOLD}Both${C_NC}"
  local c=""
  read -r -p "   Gateway choice [1/2/3]: " c || c="1"
  echo
  case "$c" in
    2) full_install omniroute ;;
    3) full_install both ;;
    *) full_install litellm ;;
  esac
}

choose_logs() {
  local c=""
  if litellm_installed && omni_installed; then
    echo -e "   Logs for:  ${C_GREEN}1${C_NC} - LiteLLM   ${C_GREEN}2${C_NC} - OmniRoute"
    read -r -p "   Choice [1/2]: " c || c="1"
  elif omni_installed; then
    c="2"
  else
    c="1"
  fi
  case "$c" in
    2) cmd_logs omniroute ;;
    *) cmd_logs litellm ;;
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
      2) cmd_restart ;;
      3) cmd_down ;;
      4) cmd_update ;;
      5) cmd_status ;;
      6) full_uninstall ;;
      7) choose_logs ;;
      8) cmd_doctor all ;;
      9) config_manager ;;
      0|q|Q) log_info "Bye!"; exit 0 ;;
      "") log_warn "Please enter a number between 0 and 9." ;;
      *) log_warn "Invalid choice: '${CHOICE}'. Pick 0-9." ;;
    esac
  done
}

#===============================================================================
# Entry point (also the target of the generated 'freeagents' CLI)
#===============================================================================
main() {
  ensure_state_dirs
  if [ "$#" -eq 0 ]; then
    menu_loop
    return 0
  fi
  case "$1" in
    up)          shift; cmd_up "$@" ;;
    down)        shift; cmd_down "$@" ;;
    restart)     shift; cmd_restart "$@" ;;
    status)      shift; cmd_status "$@" ;;
    logs)        shift; cmd_logs "$@" ;;
    doctor)      shift; cmd_doctor "${1:-all}" ;;
    credentials|keys) cmd_credentials ;;
    update)      shift; cmd_update "$@" ;;
    uninstall|remove) shift; full_uninstall "${1:-}" ;;
    install)     shift; full_install "${1:-both}" ;;
    menu)        menu_loop ;;
    version|-v|--version) echo "Free AI Agents ${FREE_AGENTS_VERSION}" ;;
    help|-h|--help)
      cat <<'USAGE'
Usage: freeagents [command]

  (no args)            open the interactive manager menu
  up                   start BOTH gateways (Docker daemon if needed)
  down                 stop BOTH gateways
  restart              restart BOTH gateways and wait until healthy
  status               state, health, ports and files of BOTH gateways
  doctor [engine]      deep diagnosis (engine: litellm|omniroute, default both)
  logs [engine]        follow logs (engine: litellm|omniroute, default litellm)
  credentials          dashboard URLs, logins and Claude tokens
  update               re-download from the repo + full reinstall (keys kept)
  uninstall [--yes]    remove everything this installer created
  install [engine]     install litellm | omniroute | both (non-interactive)

Env knobs: FREEAGENTS_SKIP_WINDOWS=1, FREEAGENTS_KEY_CHECK=0,
           FREEAGENTS_KEEP_NPM=1, FREEAGENTS_BOOT_MODE=systemd|wslconf|auto
USAGE
      ;;
    *) log_error "Unknown command: '$1'. Try 'freeagents help'."; exit 1 ;;
  esac
}

main "$@"
