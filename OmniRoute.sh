#!/usr/bin/env bash
# =============================================================================
#  omniroute-manager.sh
#  Production installer / uninstaller for OmniRoute + Claude (Code + Desktop)
#
#  Target environment:
#    - Windows 10/11 + WSL2 (Ubuntu 22.04+)
#    - Iran / sanctioned networks: get.docker.com and registry-1.docker.io
#      return 403. This script NEVER calls get.docker.com. It installs Docker
#      from the Ubuntu apt repos and pulls images via GHCR first (GitHub is
#      reachable in Iran), falling back to Docker Hub through Iranian
#      registry mirrors (ArvanCloud / Liara / IranServer), then a source
#      build, then a pure-Node (non-Docker) mode.
#    - 8 GB RAM / 4-core machines: swap is provisioned if missing, Docker
#      builds get hard memory caps, and the pre-built image is preferred so
#      a build is only the fallback.
#    - Non-TTY friendly (MobaXterm, Windows Terminal, cron, CI): every
#      prompt has a timeout and a safe default; batch modes via flags.
#
#  Usage:
#    bash omniroute-manager.sh                # interactive menu (TTY only)
#    bash omniroute-manager.sh --install      # non-interactive install
#    bash omniroute-manager.sh --uninstall    # non-interactive uninstall
#                                             # (add --yes to confirm,
#                                             #  --remove-docker to also
#                                             #  purge Docker itself)
#    bash omniroute-manager.sh --help
#
#  API keys (all optional, at least one required) can be supplied:
#    - interactively (ENTER skips a provider), or
#    - via env vars in a non-TTY environment:
#        OMNIRoute_GROQ_KEY OMNIRoute_OPENROUTER_KEY OMNIRoute_GEMINI_KEY
#        OMNIRoute_CEREBRAS_KEY OMNIRoute_MISTRAL_KEY
#
#  Overridable settings (env vars):
#    OMNIRoute_PORT            dashboard+OpenAI-compatible port (default 20128)
#    OMNIRoute_API_PORT        secondary API port (default 20129)
#    OMNIRoute_BIND_HOST       host bind for the published ports (127.0.0.1)
#    OMNIRoute_SRC_DIR         source clone dir (default ~/omniroute)
#    OMNIRoute_DATA_DIR        persistent data dir (default ~/omniroute-data)
#    OMNIRoute_LOG             log file (default ~/omniroute-install.log)
#    OMNIRoute_MASTER_KEY_FILE master API key store (default ~/omniroute-master.key)
#    OMNIRoute_KEYS_FILE       provider key store  (default ~/omniroute-keys.env)
#    OMNIRoute_CONTAINER       container name (default omniroute-app)
#    OMNIRoute_IMAGE           local image name (default omniroute-image)
#    OMNIRoute_IMAGE_TAG       pre-built tag to pull (default 3.8.50)
#    OMNIRoute_IMAGE_TAG_PIN   version the running service must report (3.8.50)
#    OMNIRoute_NPM_REGISTRY    npm registry for non-Docker mode (default:
#                              npmjs.org, auto-fallback registry.npmmirror.com)
#    OMNIRoute_CLAUDE_DIR      Claude Code settings dir (default: Windows
#                              %USERPROFILE%\.claude, via PowerShell)
#    OMNIRoute_PROXY_URL       optional outbound proxy (http:// or socks5://)
#    OMNIRoute_USE_PROXY       1/on to force the Windows system proxy (or
#                              OMNIRoute_PROXY_URL) for every provider call;
#                              0/off to force a direct connection. Unset:
#                              ask y/n only when an active Windows proxy is
#                              detected. Later: omni proxy on|off|status
#    OMNIRoute_SKIP_DIRECT_PROBE  set 1 to skip direct upstream key probes
#    OMNIRoute_SKIP_SWAP       set 1 to skip swap provisioning
#    OMNIRoute_ASSUME_DEPS=1   skip apt package installation (air-gapped)
#
#  What this script manages (uninstall removes exactly these):
#    - container  omniroute-app            (Docker mode)
#    - image      omniroute-image:latest   (local tag of the pinned pull)
#    - pm2 proc   omniroute                (Node mode)
#    - $SRC_DIR   source clone             (build / Node-from-source mode)
#    - $DATA_DIR  SQLite data + logs
#    - $KEYS_FILE, $MASTER_KEY_FILE, $DATA_DIR/.env
#    - Windows   <userprofile>\.claude\settings.json (Claude Code gateway env;
#                unrelated settings keys are preserved)
#    - Windows   Claude Desktop 3P profile under %LOCALAPPDATA%\Claude-3p
#
#  Pinned to OmniRoute image tag 3.8.50 (published). release/v3.8.51 has no
#  image tag as of 2026-09; source fallback clones tag v3.8.50 so a local
#  build matches the image. Claude pairing was checked against the v3.8.51
#  source contracts (they match 3.8.50 for the routes this script calls):
#    - Claude Code talks the Anthropic Messages API. ANTHROPIC_BASE_URL is
#      the gateway ROOT (http://127.0.0.1:20128) with NO /v1 suffix. Claude
#      Code appends /v1/messages itself (OmniRoute CLAUDE-CODE-CONFIGURATION
#      and https://code.claude.com/docs/en/llm-gateway-connect).
#    - Credential: ANTHROPIC_AUTH_TOKEN is sent as Authorization: Bearer.
#      ANTHROPIC_API_KEY would be x-api-key; this script sets only the
#      bearer token so the two cannot disagree.
#    - Claude Desktop does NOT read settings.json. It uses third-party
#      inference (Help -> Troubleshooting -> Enable Developer Mode, then
#      Developer -> Configure Third-Party Inference). This script writes the
#      3P profile under %LOCALAPPDATA%\Claude-3p (deploymentMode=3p,
#      inferenceProvider=gateway, bearer, base URL without /v1). HTTP is
#      allowed only on loopback, so the URL is http://127.0.0.1:20128.
#    - /healthz is the lightweight liveness endpoint.
#    - OMNIROUTE_API_KEY in the container env is a passthrough master key.
#      The Claude client uses a real api-manager key from POST /api/keys.
#    - Provider keys are stored in the encrypted DB. POST /api/providers/bulk
#      renames on collision ("<name> <n>", issue #2587) and is NOT idempotent.
#      This script updates the single connection named ws-install via
#      POST /api/providers (upsert-by-exact-name) or PUT /api/providers/:id.
#    - Official images: ghcr.io/diegosouzapw/omniroute and
#      diegosouzapw/omniroute. The -web (Chromium) variant is NOT used.
#
#  NOTE: output is intentionally ASCII-only English (terminal safety).
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Constants and overridable settings
# ---------------------------------------------------------------------------
readonly SCRIPT_VERSION="2.1.0"
readonly OMNIRoute_UPSTREAM_REPO="https://github.com/diegosouzapw/OmniRoute.git"
readonly OMNIRoute_UPSTREAM_BRANCH="v3.8.50"

OMNIRoute_PORT="${OMNIRoute_PORT:-20128}"
OMNIRoute_API_PORT="${OMNIRoute_API_PORT:-20129}"
OMNIRoute_BIND_HOST="${OMNIRoute_BIND_HOST:-127.0.0.1}"
SRC_DIR="${OMNIRoute_SRC_DIR:-$HOME/omniroute}"
DATA_DIR="${OMNIRoute_DATA_DIR:-$HOME/omniroute-data}"
LOG_FILE="${OMNIRoute_LOG:-$HOME/omniroute-install.log}"
MASTER_KEY_FILE="${OMNIRoute_MASTER_KEY_FILE:-$HOME/omniroute-master.key}"
KEYS_FILE="${OMNIRoute_KEYS_FILE:-$HOME/omniroute-keys.env}"
CONTAINER_NAME="${OMNIRoute_CONTAINER:-omniroute-app}"
IMAGE_NAME="${OMNIRoute_IMAGE:-omniroute-image}"
IMAGE_TAG="${OMNIRoute_IMAGE_TAG:-3.8.50}"
IMAGE_TAG_PIN="${OMNIRoute_IMAGE_TAG_PIN:-3.8.50}"
IMAGE_GHCR="${OMNIRoute_IMAGE_GHCR:-ghcr.io/diegosouzapw/omniroute}"
IMAGE_HUB="${OMNIRoute_IMAGE_HUB:-diegosouzapw/omniroute}"
NPM_REGISTRY="${OMNIRoute_NPM_REGISTRY:-}"
DAEMON_JSON="${OMNIRoute_DAEMON_JSON:-/etc/docker/daemon.json}"
MNT_ROOT="${OMNIRoute_MNT_ROOT:-/mnt}"
NODE_MODE_PID_FILE="$HOME/.omniroute-node.pid"
CLIENT_KEY_FILE="${OMNIRoute_CLIENT_KEY_FILE:-$HOME/omniroute-claude.key}"
CLIENT_KEY_NAME="ws-claude"
CONN_NAME="ws-install"
# Fixed Claude Desktop 3P profile id so re-runs update one profile.
DESKTOP_PROFILE_ID="00000000-0000-4000-8000-0000000a110e"

# A registry that is blocked but looks alive can make `docker pull` hang
# for a very long time with zero output. Every pull therefore gets a hard
# timeout plus periodic heartbeat logs; OMNIRoute_PULL_TIMEOUT seconds.
PULL_TIMEOUT="${OMNIRoute_PULL_TIMEOUT:-900}"
# OMNIRoute_SKIP_PROBE=1 disables the pre-pull reachability probe (tests).
SKIP_PROBE="${OMNIRoute_SKIP_PROBE:-0}"

BASE_URL="http://127.0.0.1:${OMNIRoute_PORT}"

# Provider ids as known by OmniRoute (src/shared/constants/providers).
readonly PROVIDERS=(groq openrouter gemini cerebras mistral)

# Current free-tier models preferred for Claude Code (2026-09 catalog).
# The first id that exists in the live /v1/models catalog becomes
# ANTHROPIC_MODEL. Order = preference.
readonly PREFERRED_MODELS=(
  "devstral-latest"                        # Mistral free tier (code agent)
  "qwen/qwen3.8-27b"                       # Groq free tier (fast)
  "openai/gpt-oss-120b"                    # Groq free tier
  "gemini-2.5-flash"                       # Google AI free tier
  "codestral-latest"                       # Mistral free tier (alias->2508)
  "deepseek/deepseek-chat-v3-0324:free"    # OpenRouter free tier
  "zai-glm-4.7"                            # Cerebras (free trial quota)
  "llama-3.3-70b"                          # Cerebras
)

# Registry mirrors for sanctioned networks (per /etc/docker/daemon.json).
readonly MIRROR_LIST=(
  "https://docker.arvancloud.ir"
  "https://docker.hub.iran.liara.run"
  "https://docker.iranserver.com"
)

TMP_FILES=()
MODE=""            # install | uninstall
ASSUME_YES=0
REMOVE_DOCKER=0
RUN_MODE=""        # docker | node (resolved during install)

MANAGER_SELF_DIR="$HOME/.omniroute-manager"
MANAGER_URL_DEFAULT="https://raw.githubusercontent.com/im-JvD/OmniRoute-OpenCode/main/OmniRoute.sh"
MANAGER_URL_FALLBACK="https://cdn.jsdelivr.net/gh/im-JvD/OmniRoute-OpenCode@main/OmniRoute.sh"

MANAGER_LOCAL=""
resolve_manager_path() {
  local candidate="${SCRIPT_PATH:-}"
  if [ -n "$candidate" ] && [ -f "$candidate" ] && [ -r "$candidate" ]; then
    MANAGER_LOCAL="$candidate"
    return 0
  fi
  local urls=()
  [ -n "${OMNIRoute_MANAGER_URL:-}" ] && urls+=("$OMNIRoute_MANAGER_URL")
  urls+=("$MANAGER_URL_DEFAULT" "$MANAGER_URL_FALLBACK")
  mkdir -p "$MANAGER_SELF_DIR"
  local url dest
  dest="$MANAGER_SELF_DIR/OmniRoute.sh"
  for url in "${urls[@]}"; do
    if curl -fsSL --max-time 60 "$url" -o "${dest}.new" 2>>"$LOG_FILE"; then
      mv "${dest}.new" "$dest"
      chmod 700 "$dest"
      MANAGER_LOCAL="$dest"
      log "Piped install: saved a local copy of the manager: $dest (from $url)"
      return 0
    fi
    rm -f "${dest}.new" 2>/dev/null || true
  done
  MANAGER_LOCAL=""
  warn "Piped install: could not save a local copy of the manager (all downloads failed)."
  warn "For re-runs, keep a copy: curl -fsSL $MANAGER_URL_DEFAULT -o OmniRoute.sh && bash OmniRoute.sh"
  return 0
}

# ---------------------------------------------------------------------------
# 1. Logging (all output: ASCII English, mirrored to $LOG_FILE)
# ---------------------------------------------------------------------------
_log_init() {
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
}

_log() {
  local level="$1"; shift
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
  echo "$line"
  echo "$line" >>"$LOG_FILE" 2>/dev/null || true
}

log()  { _log INFO  "$@"; }
warn() { _log WARN  "$@"; }
err()  { _log ERROR "$@"; }
die()  { err "$@"; exit 1; }

# Run a long command, teeing its output to console + log.
run_logged() {
  log "CMD: $*"
  local rc=0
  set +e
  "$@" 2>&1 | tee -a "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  set -e
  [ "$rc" -eq 0 ] || return "$rc"
}

# Run a long command silently (output only to log).
run_quiet() {
  log "CMD: $*"
  local rc=0
  set +e
  "$@" >>"$LOG_FILE" 2>&1
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || return "$rc"
}

# ---------------------------------------------------------------------------
# 2. Error handling and cleanup
# ---------------------------------------------------------------------------
on_error() {
  local exit_code=$? line_no=$1
  err "Failed (exit $exit_code) near line $line_no."
  err "Last lines of the log:"
  tail -n 15 "$LOG_FILE" 2>/dev/null | sed 's/^/    /' || true
  err "Full log: $LOG_FILE"
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

cleanup_tmp() {
  local f
  for f in "${TMP_FILES[@]:-}"; do
    [ -n "$f" ] && rm -f "$f" 2>/dev/null || true
  done
}
trap cleanup_tmp EXIT
trap 'err "Interrupted by user."; exit 130' INT
trap 'err "Terminated."; exit 143' TERM

make_tmp() {
  local f
  f="$(mktemp "${TMPDIR:-/tmp}/omniroute-mgr.XXXXXX")"
  TMP_FILES+=("$f")
  echo "$f"
}

# ---------------------------------------------------------------------------
# 3. Small utilities
# ---------------------------------------------------------------------------
# Interactive-terminal detection. True when stdin is a TTY (the normal
# case), OR when the script is piped in (curl ... | bash) but a
# controlling terminal still exists for the user to type into. In the
# piped case stdin carries the script's own bytes, so prompts must read
# from /dev/tty instead of stdin.
# OMNIRoute_FORCE_NO_TTY=1 forces the non-TTY path (used by the test
# harness to simulate a terminal-less session deterministically).
is_tty() {
  [ -n "${OMNIRoute_FORCE_NO_TTY:-}" ] && return 1
  [ -t 0 ] && return 0
  [ -r /dev/tty ] && [ -w /dev/tty ]
}

# DC: run docker, escalating to sudo ONLY when the current user genuinely
# lacks socket access. A freshly installed WSL user joins the docker group
# only after re-login, so during THIS session the first docker call usually
# gets "permission denied ... docker.sock" and must be retried with sudo.
# We try the bare command first (covers root, docker-group members, and any
# rootless/mock daemon), and only escalate on a clear permission error - we
# never re-run a command that already succeeded or failed for another reason.
in_docker_group() { id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; }
DC() {
  if [ "$(id -u)" -eq 0 ] || in_docker_group; then
    docker "$@"
    return $?
  fi
  local errfile rc=0
  errfile="$(make_tmp)"
  docker "$@" 2>"$errfile" || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$errfile"
    return 0
  fi
  if [ -n "$SUDO" ] && grep -qiE "permission denied|operation not permitted|cannot connect|docker.sock" "$errfile" 2>/dev/null; then
    rm -f "$errfile"
    $SUDO docker "$@"
    return $?
  fi
  cat "$errfile" >&2 2>/dev/null || true
  rm -f "$errfile"
  return "$rc"
}

# SUDO="" when already root, else "sudo" (required for docker/swap/apt).
resolve_sudo() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
  elif command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    SUDO=""
  fi
}

# systemd is only "active" when PID 1 is systemd (WSL2 can have the
# /run/systemd/system stub present while systemd is NOT running, e.g. Docker
# containers and plain WSL2). Never trust the directory alone.
systemd_active() {
  [ -d /run/systemd/system ] || return 1
  command -v systemctl >/dev/null 2>&1 || return 1
  [ "$(cat /proc/1/comm 2>/dev/null || echo none)" = "systemd" ]
}

# Start a service with systemctl when systemd is actually running (WSL2 with
# systemd enabled), otherwise the SysV `service` wrapper (plain WSL2).
svc_start() {
  local svc="$1"
  if systemd_active; then
    if run_logged systemctl start "$svc"; then
      return 0
    fi
    warn "systemctl start $svc failed - falling back to 'service'."
  fi
  if command -v service >/dev/null 2>&1; then
    run_logged service "$svc" start
  else
    die "Neither working systemctl nor service command available. Start '$svc' manually."
  fi
}

svc_active() {
  local svc="$1"
  if systemd_active; then
    systemctl is-active "$svc" >/dev/null 2>&1
  elif command -v service >/dev/null 2>&1; then
    service "$svc" status >/dev/null 2>&1
  else
    return 1
  fi
}

# Prompt with a timeout + default. The answer is returned in $REPLY_LINE
# (NOT via stdout - this function is safe to call from command substitution
# and from subshells). Non-TTY stdin: uses the env var $3 when set, else the
# default. NEVER blocks a non-TTY session: no read without a TTY.
# Piped script (curl ... | bash): the answer is read from /dev/tty, since
# stdin holds the script itself.
prompt_line() {
  local prompt="$1" default="${2:-}" var_name="${3:-}"
  local reply=""
  if is_tty; then
    if [ -t 0 ]; then
      # shellcheck disable=SC2162
      read -r -t 180 -p "$prompt [${default}]: " reply || reply="${default}"
    else
      # Piped in (curl ... | bash): take the answer from the controlling
      # terminal; read -p writes the prompt to stderr (the terminal).
      read -r -t 180 -p "$prompt [${default}]: " reply </dev/tty || reply="${default}"
    fi
    # Ctrl-D / timeout leaves reply empty -> default.
  elif [ -n "$var_name" ] && [ -n "${!var_name:-}" ]; then
    reply="${!var_name}"
    _log INFO "Non-TTY stdin: using env var ${var_name} for '$prompt'"
  else
    reply="$default"
    _log INFO "Non-TTY stdin: using default '${default}' for '$prompt'"
  fi
  REPLY_LINE="${reply:-$default}"
  [ -z "$REPLY_LINE" ] && REPLY_LINE="$default"
  return 0
}

prompt_yes_no() {
  local prompt="$1" default="$2"
  prompt_line "$prompt" "$default" ""
  case "$REPLY_LINE" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# Strip CR/LF, surrounding quotes, and every whitespace character. API keys
# never contain spaces; a paste from a terminal often does. Warns (does not
# reject) on a surprising prefix or a leftover non-printable character.
# Result is printed on stdout. Empty input prints nothing.
sanitize_key() {
  local raw="$1" k q1 qn
  # Whitespace first, then one surrounding quote layer, then whitespace again
  # so a paste like:   "gsk_xxx"   becomes gsk_xxx.
  k="${raw//[[:space:]]/}"
  if [ "${#k}" -ge 2 ]; then
    q1="${k:0:1}"
    qn="${k: -1}"
    if [ "$q1" = "$qn" ] && { [ "$q1" = '"' ] || [ "$q1" = "'" ]; }; then
      k="${k:1:${#k}-2}"
    fi
  fi
  k="${k//[[:space:]]/}"
  printf '%s' "$k"
}

warn_key_shape() {
  local provider="$1" key="$2"
  [ -n "$key" ] || return 0
  case "$provider" in
    groq)        [[ "$key" == gsk_* ]] || warn "Groq key does not start with gsk_ (still registering)." ;;
    openrouter)  [[ "$key" == sk-or-* ]] || warn "OpenRouter key does not start with sk-or- (still registering)." ;;
    gemini)
      # AI Studio keys are AIza...; newer Google keys may start with AQ.
      [[ "$key" == AIza* || "$key" == AQ.* ]] || warn "Gemini key does not start with AIza or AQ. (still registering)."
      ;;
    cerebras)    [[ "$key" == csk-* ]] || warn "Cerebras key does not start with csk- (still registering)." ;;
    mistral)
      case "$key" in
        gsk_*|sk-or-*|AIza*|AQ.*|csk-*)
          warn "Mistral key looks like another provider's key (prefix). Still registering."
          ;;
      esac
      ;;
  esac
  if printf '%s' "$key" | LC_ALL=C grep -q '[^[:print:]]'; then
    warn "$provider key still contains a non-printable character after sanitize."
  fi
}

# Write a JSON body with jq (never string-interpolate secrets into JSON).
write_json() {
  local dest="$1"
  shift
  jq -n "$@" >"$dest"
}

# ---------------------------------------------------------------------------
# 4. Environment detection
# ---------------------------------------------------------------------------
detect_environment() {
  log "=== Environment ==="
  log "OS: $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo unknown)"
  log "User: $(whoami) (uid $(id -u)), HOME=$HOME"
  log "RAM: $(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 )) MB, CPUs: $(nproc)"
  TOTAL_RAM_MB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  if grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
    IS_WSL=1
    log "Runtime: WSL2 detected ($(cat /proc/version | tr ' ' '\n' | grep -i 'microsoft' | head -n1))"
  else
    IS_WSL=0
    warn "Not running under WSL2. Continuing (Linux host). Windows Claude"
    warn "settings detection will fall back to the WSL home directory."
  fi
  if systemd_active; then
    log "Init: systemd active (systemctl available)"
  else
    log "Init: no running systemd (WSL default) - will use 'service'"
  fi
  resolve_sudo
  [ -n "$SUDO" ] && log "Privilege helper: sudo" || log "Privilege helper: none (root)"
  log "================================="
}

require_tools() {
  local missing=()
  local t
  for t in git curl jq openssl awk; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    if [ "${OMNIRoute_ASSUME_DEPS:-0}" = "1" ]; then
      die "Missing required tools: ${missing[*]} (and OMNIRoute_ASSUME_DEPS=1 set)."
    fi
    log "Installing missing tools: ${missing[*]}"
    if [ -n "$SUDO" ] || [ "$(id -u)" -eq 0 ]; then
      $SUDO apt-get update -y >>"$LOG_FILE" 2>&1 || warn "apt-get update failed - trying cached package lists"
      DEBIAN_FRONTEND=noninteractive run_logged \
        $SUDO apt-get install -y --no-install-recommends git curl jq openssl ca-certificates
    else
      die "Missing tools: ${missing[*]}. Install them with apt and re-run."
    fi
  else
    log "All required base tools present."
  fi
}

# Provision a swapfile when the machine has little RAM and no swap at all.
# WSL2 has no swap by default; an 8 GB box building OmniRoute will OOM
# without one. Only runs when swap is 0 and RAM < 12 GB.
ensure_swap() {
  [ "${OMNIRoute_SKIP_SWAP:-0}" = "1" ] && { log "Swap provisioning skipped (OMNIRoute_SKIP_SWAP=1)."; return 0; }
  [ "$(id -u)" -eq 0 ] || [ -n "$SUDO" ] || { warn "Not root and no sudo: cannot provision swap."; return 0; }
  local swap_kb
  swap_kb="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
  if [ "$swap_kb" -gt 0 ]; then
    log "Swap already present: $(( swap_kb / 1024 )) MB. Skipping."
    return 0
  fi
  if [ "$TOTAL_RAM_MB" -ge 12288 ]; then
    log "RAM >= 12 GB - skipping swap provisioning."
    return 0
  fi
  log "No swap detected on a $(( TOTAL_RAM_MB / 1024 )) GB host - creating a 4 GB swapfile"
  log "(required to survive the OmniRoute build without OOM)."
  local swapfile="/swapfile.omniroute"
  if $SUDO fallocate -l 4G "$swapfile" 2>>"$LOG_FILE" || $SUDO dd if=/dev/zero of="$swapfile" bs=1M count=4096 status=none 2>>"$LOG_FILE"; then
    $SUDO chmod 600 "$swapfile"
    $SUDO mkswap "$swapfile" >>"$LOG_FILE" 2>&1
    $SUDO swapon "$swapfile" 2>>"$LOG_FILE" && \
      log "Swap enabled: $swapfile (4 GB). Note: this is a host resource - the uninstaller does not remove it."
  else
    warn "Could not create swapfile (disk full or unsupported FS). Builds may OOM."
  fi
}

# ---------------------------------------------------------------------------
# 5. Docker installation (sanction-safe) + registry mirrors
# ---------------------------------------------------------------------------
install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed: $(docker --version 2>/dev/null | head -n1)"
    return 0
  fi
  log "Docker not found. Installing docker.io from Ubuntu repositories."
  warn "Intentionally NOT using https://get.docker.com (403 in Iran)."
  if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
    die "Docker is not installed and sudo is unavailable. Run this script with sudo access."
  fi
  DEBIAN_FRONTEND=noninteractive run_logged \
    $SUDO apt-get install -y --no-install-recommends docker.io
  log "Adding current user to the docker group (takes effect on next login;"
  log "this run continues via sudo)."
  $SUDO usermod -aG docker "$(whoami)" 2>>"$LOG_FILE" || true
}

configure_docker_mirrors() {
  log "Configuring $DAEMON_JSON (Iranian registry mirrors + BuildKit)."
  local daemon_json="$DAEMON_JSON"
  $SUDO mkdir -p "$(dirname "$daemon_json")"

  local mirrors_json existing_json
  mirrors_json="$(printf '%s\n' "${MIRROR_LIST[@]}" | jq -R . | jq -s .)"
  existing_json="{}"
  if [ -f "$daemon_json" ]; then
    if jq . "$daemon_json" >/dev/null 2>&1; then
      existing_json="$(cat "$daemon_json")"
    else
      local backup="${daemon_json}.bak-$(date +%Y%m%d%H%M%S)"
      warn "Existing daemon.json is not valid JSON - backing up to $backup"
      $SUDO cp "$daemon_json" "$backup"
      existing_json="{}"
    fi
  fi

  # Merge: keep existing settings, override mirrors + ensure buildkit feature.
  local new_json tmp
  new_json="$(jq -n \
    --argjson existing "$existing_json" \
    --argjson mirrors "$mirrors_json" \
    '($existing * {"registry-mirrors": $mirrors, "features": ((($existing.features // {}) * {"buildkit": true}))})')"

  # Write as the current user, then move into place (root moves files, it
  # does not need to write file contents - some sandboxes deny that).
  tmp="$(make_tmp)"
  printf '%s\n' "$new_json" >"$tmp"
  chmod 644 "$tmp"
  $SUDO mv -f "$tmp" "$daemon_json"
  $SUDO chown root:root "$daemon_json" 2>/dev/null || true
  $SUDO chmod 644 "$daemon_json" 2>/dev/null || true
  log "daemon.json updated:"
  $SUDO cat "$daemon_json" | sed 's/^/    /'

  restart_docker_daemon
}

# Restart the Docker daemon (mirrors only apply after a restart).
restart_docker_daemon() {
  log "Restarting Docker daemon to apply registry mirrors."
  if systemd_active; then
    if run_logged $SUDO systemctl restart docker; then
      return 0
    fi
    warn "systemctl restart docker failed - falling back to 'service'."
  fi
  if command -v service >/dev/null 2>&1; then
    if run_logged $SUDO service docker restart; then
      return 0
    fi
    warn "service restart failed - stopping then starting."
  fi
  $SUDO service docker stop >>"$LOG_FILE" 2>&1 || true
  svc_start docker
}

ensure_docker_running() {
  if run_quiet DC info; then
    log "Docker daemon is running."
    return 0
  fi
  log "Docker daemon not running - starting it."
  svc_start docker
  local i
  for i in $(seq 1 20); do
    if run_quiet DC info; then
      log "Docker daemon is up."
      return 0
    fi
    sleep 2
  done
  die "Docker daemon failed to start. Check: $SUDO journalctl -u docker OR: $SUDO service docker status"
}

# ---------------------------------------------------------------------------
# 6. API key collection (5 optional providers, >=1 required)
# ---------------------------------------------------------------------------
# Load saved keys from $KEYS_FILE into the KEY_* globals used by later steps.
apply_saved_keys() {
  # shellcheck disable=SC1090
  . "$KEYS_FILE"
  KEY_GROQ="$(sanitize_key "${GROQ_KEY:-}")"
  KEY_OPENROUTER="$(sanitize_key "${OPENROUTER_KEY:-}")"
  KEY_GEMINI="$(sanitize_key "${GEMINI_KEY:-}")"
  KEY_CEREBRAS="$(sanitize_key "${CEREBRAS_KEY:-}")"
  KEY_MISTRAL="$(sanitize_key "${MISTRAL_KEY:-}")"
}

# An env key that disagrees with the saved file wins, and the file is rewritten
# so the next DB upsert stores the key the operator just supplied.
overlay_env_keys() {
  local changed=0 envk name var envvar
  for name in GROQ OPENROUTER GEMINI CEREBRAS MISTRAL; do
    envvar="OMNIRoute_${name}_KEY"
    envk="$(sanitize_key "${!envvar:-}")"
    var="KEY_${name}"
    [ -n "$envk" ] || continue
    if [ "$envk" != "${!var:-}" ]; then
      log "Updating $(printf '%s' "$name" | tr '[:upper:]' '[:lower:]') key from environment (stored key disagreed)."
      printf -v "$var" '%s' "$envk"
      changed=1
    fi
  done
  [ "$changed" -eq 1 ] || return 0
  local tmp
  tmp="$(make_tmp)"
  {
    echo "# Provider API keys for OmniRoute (managed by omniroute-manager.sh)"
    printf 'GROQ_KEY=%q\n' "${KEY_GROQ:-}"
    printf 'OPENROUTER_KEY=%q\n' "${KEY_OPENROUTER:-}"
    printf 'GEMINI_KEY=%q\n' "${KEY_GEMINI:-}"
    printf 'CEREBRAS_KEY=%q\n' "${KEY_CEREBRAS:-}"
    printf 'MISTRAL_KEY=%q\n' "${KEY_MISTRAL:-}"
  } >"$tmp"
  mv "$tmp" "$KEYS_FILE"
  chmod 600 "$KEYS_FILE"
  log "Rewrote $KEYS_FILE with environment overrides."
}

collect_keys() {
  log "=== API keys (press ENTER to skip a provider) ==="
  local groq_key="" openrouter_key="" gemini_key="" cerebras_key="" mistral_key=""

  if [ -f "$KEYS_FILE" ]; then
    if is_tty; then
      if prompt_yes_no "Saved keys found in $KEYS_FILE. Reuse them? (recommended on re-runs)" "y"; then
        apply_saved_keys
        overlay_env_keys
        log "Reusing saved keys."
        return 0
      fi
      log "Fresh entry requested - previous saved values will be replaced."
    else
      log "Non-TTY: reusing saved keys from $KEYS_FILE."
      apply_saved_keys
      overlay_env_keys
      return 0
    fi
  fi

  prompt_line "  Groq key (gsk_...) - console.groq.com" "" "OMNIRoute_GROQ_KEY"; groq_key="$(sanitize_key "$REPLY_LINE")"
  prompt_line "  OpenRouter key (sk-or-...) - openrouter.ai" "" "OMNIRoute_OPENROUTER_KEY"; openrouter_key="$(sanitize_key "$REPLY_LINE")"
  prompt_line "  Google AI key (AIza... or AQ....) - aistudio.google.com" "" "OMNIRoute_GEMINI_KEY"; gemini_key="$(sanitize_key "$REPLY_LINE")"
  prompt_line "  Cerebras key (csk-...) - cloud.cerebras.ai" "" "OMNIRoute_CEREBRAS_KEY"; cerebras_key="$(sanitize_key "$REPLY_LINE")"
  prompt_line "  Mistral key - console.mistral.ai" "" "OMNIRoute_MISTRAL_KEY"; mistral_key="$(sanitize_key "$REPLY_LINE")"

  local count=0
  [ -n "$groq_key" ] && count=$((count+1))
  [ -n "$openrouter_key" ] && count=$((count+1))
  [ -n "$gemini_key" ] && count=$((count+1))
  [ -n "$cerebras_key" ] && count=$((count+1))
  [ -n "$mistral_key" ] && count=$((count+1))

  if [ "$count" -lt 1 ]; then
    die "At least ONE provider API key is required. Re-run and provide at least one (env vars work in non-TTY mode: OMNIRoute_GROQ_KEY etc.)."
  fi

  warn_key_shape groq "$groq_key"
  warn_key_shape openrouter "$openrouter_key"
  warn_key_shape gemini "$gemini_key"
  warn_key_shape cerebras "$cerebras_key"
  warn_key_shape mistral "$mistral_key"

  local tmp
  tmp="$(make_tmp)"
  {
    echo "# Provider API keys for OmniRoute (managed by omniroute-manager.sh)"
    # %q keeps the file sourceable even if a key contains shell metacharacters.
    printf 'GROQ_KEY=%q\n' "$groq_key"
    printf 'OPENROUTER_KEY=%q\n' "$openrouter_key"
    printf 'GEMINI_KEY=%q\n' "$gemini_key"
    printf 'CEREBRAS_KEY=%q\n' "$cerebras_key"
    printf 'MISTRAL_KEY=%q\n' "$mistral_key"
  } >"$tmp"
  mv "$tmp" "$KEYS_FILE"
  chmod 600 "$KEYS_FILE"
  log "Saved $count provider key(s) to $KEYS_FILE (mode 600)."

  # Expose to later steps.
  KEY_GROQ="$groq_key"; KEY_OPENROUTER="$openrouter_key"
  KEY_GEMINI="$gemini_key"; KEY_CEREBRAS="$cerebras_key"; KEY_MISTRAL="$mistral_key"
  log "================================================="
}

# ---------------------------------------------------------------------------
# 7. OmniRoute image acquisition: pre-built (GHCR -> Hub) -> build -> node
# ---------------------------------------------------------------------------
# A registry answering 200/401 to its /v2/ endpoint is reachable (401 =
# "unauthorized, present a token" = the server IS responding). Anything
# else (000, timeout, TLS failure) = network-level block.
registry_reachable() {
  local url="$1" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null)" || code=000
  case "$code" in
    200|401) return 0 ;;
    *) return 1 ;;
  esac
}

image_pull_attempt() {
  local ref="$1"

  # GHCR refs cannot use the daemon.json mirrors (mirrors only cover
  # Docker Hub), so probe first: in many sanctioned networks github.com is
  # open while ghcr.io is blocked/throttled, and a blind pull would sit
  # there looking dead. Docker Hub refs are always attempted, because the
  # daemon transparently falls back to the configured mirrors.
  case "$ref" in
    ghcr.io/*)
      if [ "$SKIP_PROBE" != "1" ]; then
        if registry_reachable "https://ghcr.io/v2/"; then
          log "ghcr.io is reachable - attempting pull."
        else
          warn "ghcr.io not reachable from this network (probe failed)."
          warn "Skipping $ref - there is no mirror fallback for GHCR."
          return 1
        fi
      fi
      ;;
  esac

  log "Trying to pull pre-built image: $ref (timeout: ${PULL_TIMEOUT}s)"
  local out rc=0 waited=0
  out="$(make_tmp)"
  ( DC pull "$ref" >"$out" 2>&1 ) &
  local pull_pid=$!

  # Heartbeat + hard timeout: a slow-but-alive pull must never look hung.
  while kill -0 "$pull_pid" 2>/dev/null; do
    if [ "$waited" -ge "$PULL_TIMEOUT" ]; then
      log "Pull timed out after ${PULL_TIMEOUT}s - cancelling (daemon aborts the transfer)."
      kill "$pull_pid" 2>/dev/null || true
      break
    fi
    sleep 5
    waited=$((waited+5))
    if [ $((waited % 30)) -eq 0 ]; then
      log "Pull of $ref still in progress (${waited}s elapsed) - still waiting..."
    fi
  done
  wait "$pull_pid" 2>/dev/null || rc=$?
  # Surface the docker client output (progress lines / error) in the log.
  [ -s "$out" ] && cat "$out" >>"$LOG_FILE" 2>/dev/null || true

  if [ "$rc" -eq 0 ]; then
    run_quiet DC tag "$ref" "${IMAGE_NAME}:latest"
    log "Pulled and tagged as ${IMAGE_NAME}:latest"
    PREBUILT_REF="$ref"
    return 0
  fi
  warn "Pull failed for $ref (rc=$rc) - timeout, sanctions 403, or registry error."
  warn "For Docker Hub refs the daemon transparently uses the mirrors from daemon.json."
  return 1
}

acquire_image_docker() {
  log "=== Acquiring OmniRoute image (pre-built first: no local build) ==="
  local refs=(
    "${IMAGE_GHCR}:${IMAGE_TAG}"
    "${IMAGE_HUB}:${IMAGE_TAG}"
    "${IMAGE_GHCR}:${IMAGE_TAG_PIN}"
    "${IMAGE_HUB}:${IMAGE_TAG_PIN}"
  )
  local r
  for r in "${refs[@]}"; do
    if image_pull_attempt "$r"; then
      RUN_MODE="docker"
      return 0
    fi
  done
  warn "All pre-built image pulls failed. Falling back to a local Docker build."
  return 1
}

clone_source() {
  if [ -d "$SRC_DIR/.git" ]; then
    log "Source already cloned at $SRC_DIR - reusing (shallow)."
    return 0
  fi
  log "Cloning ${OMNIRoute_UPSTREAM_REPO} (branch ${OMNIRoute_UPSTREAM_BRANCH}, --depth 1)."
  warn "The repo is large (~1 GB). A shallow clone avoids the full history."
  rm -rf "$SRC_DIR"
  # GIT_TERMINAL_PROMPT=0: never hang waiting for credentials in non-TTY mode.
  run_logged env GIT_TERMINAL_PROMPT=0 GIT_LFS_SKIP_SMUDGE=1 git clone \
    --depth 1 --branch "$OMNIRoute_UPSTREAM_BRANCH" \
    "$OMNIRoute_UPSTREAM_REPO" "$SRC_DIR"
}

free_disk_mb() {
  # $1 = a path that may not exist yet (the clone target); walk up to the
  # nearest existing ancestor before asking df.
  local target="${1:-$SRC_DIR}"
  while [ ! -d "$target" ] && [ "$target" != "/" ]; do
    target="$(dirname "$target")"
  done
  df -BM --output=avail "$target" 2>/dev/null | tail -n1 | tr -dc '0-9' || echo 0
}

build_image_docker() {
  local avail_mb
  avail_mb="$(free_disk_mb)"
  if [ "$avail_mb" -lt 12000 ]; then
    die "Not enough disk for a build (~12 GB free needed, $avail_mb MB free at $SRC_DIR)."
  fi
  clone_source

  # Resource caps tuned for 8 GB / 4-core WSL2 hosts. The OmniRoute Dockerfile
  # (v3.8.51) documents the OOM behaviour: Next.js workers each inherit
  # NODE_OPTIONS; CIRCLE_NODE_TOTAL caps worker count. Defaults below match the
  # Dockerfile's own conservative defaults (6144 MB heap is too much for an
  # 8 GB host once the Docker daemon is subtracted).
  local mem_limit swap_limit heap_mb workers
  if [ "$TOTAL_RAM_MB" -ge 16384 ]; then
    mem_limit="8g"; swap_limit="12g"; heap_mb=6144; workers=4
  else
    mem_limit="6g"; swap_limit="8g"; heap_mb=4096; workers=2
  fi
  local build_cmd=(DC)
  if run_quiet DC buildx version; then
    build_cmd+=(buildx build)
  else
    build_cmd+=(build)
    warn "docker buildx not available - using classic builder with DOCKER_BUILDKIT=1"
  fi

  log "Build resource caps: --memory=$mem_limit --memory-swap=$swap_limit"
  log "Build args: OMNIROUTE_BUILD_MEMORY_MB=$heap_mb OMNIROUTE_BUILD_WORKERS=$workers"
  log "           OMNIROUTE_USE_TURBOPACK=0 (webpack - the Docker default)"
  log "Builder: DOCKER_BUILDKIT=1 ${build_cmd[*]} (the Dockerfile requires BuildKit: --mount=type=cache)"

  run_quiet DC builder prune -af || true

  local rc=0
  set +e
  (
    cd "$SRC_DIR"
    DOCKER_BUILDKIT=1 "${build_cmd[@]}" \
      --pull \
      --memory "$mem_limit" \
      --memory-swap "$swap_limit" \
      --build-arg "OMNIROUTE_BUILD_MEMORY_MB=$heap_mb" \
      --build-arg "OMNIROUTE_BUILD_WORKERS=$workers" \
      --build-arg "OMNIROUTE_USE_TURBOPACK=0" \
      -t "${IMAGE_NAME}:latest" . 2>&1 | tee -a "$LOG_FILE"
  )
  rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    if grep -qiE "OOM|out of memory|Cannot allocate memory|Killed" "$LOG_FILE" 2>/dev/null; then
      warn "Build appears to have been OOM-killed."
    fi
    # NOT a hard stop: the caller (acquire_runtime) falls back to Node mode,
    # per the resource-constrained-host design. See $LOG_FILE for details.
    err "Docker build failed (exit $rc). See $LOG_FILE."
    return 1
  fi
  RUN_MODE="docker"
  log "Image built: ${IMAGE_NAME}:latest"
}

ensure_node_runtime() {
  local need=22
  if command -v node >/dev/null 2>&1; then
    local major
    major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
    if [ "$major" -ge "$need" ]; then
      log "Node $(node --version) present (>= $need required)."
      return 0
    fi
    warn "Node $(node --version) is older than required ($need.x)."
  fi
  log "Installing Node.js 22 from NodeSource (nodesource.com)."
  if [ "$(id -u)" -ne 0 ] && [ -z "$SUDO" ]; then
    die "Need root or sudo to install Node.js $need."
  fi
  if curl -fsSL https://deb.nodesource.com/setup_22.x | $SUDO -E bash - >>"$LOG_FILE" 2>&1; then
    DEBIAN_FRONTEND=noninteractive run_logged $SUDO apt-get install -y --no-install-recommends nodejs
  else
    die "NodeSource setup failed (network blocked?). Install Node.js >= 22 manually and re-run."
  fi
}

npm_install_global() {
  # Two-registry fallback: npmjs.org is frequently unreachable from Iran;
  # registry.npmmirror.com (Alibaba mirror) usually is.
  local registry="${NPM_REGISTRY:-https://registry.npmjs.org}"
  log "npm install -g omniroute (registry: $registry)"
  if run_quiet npm install -g --no-audit --no-fund --registry "$registry" omniroute; then
    return 0
  fi
  if [ "$registry" != "https://registry.npmmirror.com" ]; then
    warn "npmjs.org failed - retrying via https://registry.npmmirror.com"
    if run_quiet npm install -g --no-audit --no-fund --registry "https://registry.npmmirror.com" omniroute; then
      return 0
    fi
  fi
  return 1
}

acquire_image_node() {
  log "=== Non-Docker mode: running OmniRoute directly with Node + pm2 ==="
  ensure_node_runtime
  if ! npm_install_global; then
    warn "npm package install failed - building from source instead."
    clone_source
    ( cd "$SRC_DIR" && run_logged npm ci --no-audit --no-fund )
    ( cd "$SRC_DIR" && run_logged npm run build )
  fi
  if ! command -v pm2 >/dev/null 2>&1; then
    log "Installing pm2 (auto-restart supervisor, the systemd replacement)."
    if ! npm_install_global_p2; then
      warn "pm2 install failed - falling back to a nohup process (no auto-restart)."
      PM2_AVAILABLE=0
    fi
  fi
  PM2_AVAILABLE=1
  RUN_MODE="node"
}

npm_install_global_p2() {
  local registry="${NPM_REGISTRY:-https://registry.npmjs.org}"
  run_quiet npm install -g --no-audit --no-fund --registry "$registry" pm2 ||
  run_quiet npm install -g --no-audit --no-fund --registry "https://registry.npmmirror.com" pm2
}

acquire_runtime() {
  if [ "${OMNIRoute_NO_DOCKER_BUILD:-0}" = "1" ] || ! command -v docker >/dev/null 2>&1; then
    if [ "${OMNIRoute_NO_DOCKER_BUILD:-0}" = "1" ]; then
      log "OMNIRoute_NO_DOCKER_BUILD=1 - using Node mode directly."
    else
      log "Docker unavailable - using Node mode."
    fi
    acquire_image_node
    return 0
  fi
  install_docker_if_missing
  ensure_docker_running
  configure_docker_mirrors
  ensure_docker_running
  if acquire_image_docker; then
    return 0
  fi
  if [ "${OMNIRoute_NO_DOCKER_BUILD:-0}" = "1" ]; then
    warn "Forcing Node mode (OMNIRoute_NO_DOCKER_BUILD=1)."
    acquire_image_node
    return 0
  fi
  if build_image_docker; then
    return 0
  fi
  warn "Docker build failed - final fallback: Node mode."
  acquire_image_node
}

# ---------------------------------------------------------------------------
# 8. Runtime configuration (.env) + master key
# ---------------------------------------------------------------------------
generate_master_key() {
  if [ -f "$MASTER_KEY_FILE" ] && grep -q "^sk-omni-" "$MASTER_KEY_FILE" 2>/dev/null; then
    MASTER_KEY="$(head -n1 "$MASTER_KEY_FILE" | tr -d '[:space:]')"
    log "Reusing existing master key from $MASTER_KEY_FILE"
  else
    MASTER_KEY="sk-omni-$(openssl rand -hex 16)"
    printf '%s\n' "$MASTER_KEY" >"$MASTER_KEY_FILE"
    chmod 600 "$MASTER_KEY_FILE"
    log "Generated new master key, stored in $MASTER_KEY_FILE (mode 600)."
  fi
}

write_env_file() {
  # The env file lives next to the data dir so it works for BOTH Docker
  # (--env-file) and Node mode (sourced by the launcher).
  local env_file="$DATA_DIR/.env"
  mkdir -p "$DATA_DIR"

  local jwt_secret api_key_secret initial_password
  if [ -f "$env_file" ]; then
    # Idempotent re-run: preserve secrets so dashboard login + API key
    # encryption keep working.
    jwt_secret="$(grep -E '^JWT_SECRET=' "$env_file" | cut -d= -f2- || true)"
    api_key_secret="$(grep -E '^API_KEY_SECRET=' "$env_file" | cut -d= -f2- || true)"
    initial_password="$(grep -E '^INITIAL_PASSWORD=' "$env_file" | cut -d= -f2- || true)"
    log "Reusing existing secrets from $env_file"
  fi
  [ -n "${jwt_secret:-}" ] || jwt_secret="$(openssl rand -base64 48 | tr -d '\n')"
  [ -n "${api_key_secret:-}" ] || api_key_secret="$(openssl rand -hex 32)"
  [ -n "${initial_password:-}" ] || initial_password="$(openssl rand -hex 12)"

  local tmp
  tmp="$(make_tmp)"
  {
    echo "# Managed by omniroute-manager.sh - regenerated on every install."
    echo "# Secrets (JWT/API_KEY/INITIAL_PASSWORD) are preserved across re-runs."
    echo "JWT_SECRET=$jwt_secret"
    echo "API_KEY_SECRET=$api_key_secret"
    echo "INITIAL_PASSWORD=$initial_password"
    echo "# Passthrough master key for /v1/* (kept; Claude uses the api-manager key)."
    echo "OMNIROUTE_API_KEY=$MASTER_KEY"
    echo "# Surface non-Claude models in Claude Code's /model picker as claude/<id>."
    echo "EXPOSE_CC_DISCOVERY_ALIASES=true"
    echo "REQUIRE_API_KEY=true"
    echo "PORT=$OMNIRoute_PORT"
    echo "DASHBOARD_PORT=$OMNIRoute_PORT"
    echo "API_PORT=$OMNIRoute_API_PORT"
    echo "API_HOST=127.0.0.1"
    echo "DATA_DIR=/app/data"
    echo "OMNIROUTE_MITM_STUB=1"
    # Runtime heap: the image default (1024 MB) is fine; raise for fusion panels.
    echo "OMNIROUTE_MEMORY_MB=1024"
    if [ "${PROXY_ENABLED:-0}" = "1" ] && [ -n "${RESOLVED_PROXY_URL:-}" ]; then
      echo "HTTP_PROXY=$RESOLVED_PROXY_URL"
      echo "HTTPS_PROXY=$RESOLVED_PROXY_URL"
      echo "ALL_PROXY=$RESOLVED_PROXY_URL"
      echo "NO_PROXY=localhost,127.0.0.1,::1"
    fi
    # Headless escape hatch that IS honoured for Gemini (src/lib/providers/gemini.ts):
    # dashboard-created connections always win when both exist.
    if [ -n "${KEY_GEMINI:-}" ]; then
      echo "GEMINI_API_KEY=$KEY_GEMINI"
      echo "GOOGLE_API_KEY=$KEY_GEMINI"
    fi
    # NOTE: groq/openrouter/cerebras/mistral keys are NOT env vars in OmniRoute;
    # they are registered into the encrypted provider DB via the management API
    # (see register_provider_keys).
  } >"$tmp"
  mv "$tmp" "$env_file"
  chmod 600 "$env_file"
  ENV_FILE="$env_file"
  INITIAL_PASSWORD_SET="$initial_password"
  log "Wrote $env_file (mode 600)."
}

# ---------------------------------------------------------------------------
# 9. Start the service (Docker container or Node+pm2), idempotent
# ---------------------------------------------------------------------------
container_env_hash() {
  sha256sum "$ENV_FILE" 2>/dev/null | awk '{print $1}' || echo none
}

start_container() {
  local env_hash
  env_hash="$(container_env_hash)"

  if DC ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    local existing_hash
    existing_hash="$(DC inspect --format '{{index .Config.Labels "omniroute.env-hash"}}' "$CONTAINER_NAME" 2>/dev/null || echo missing)"
    if [ "$existing_hash" = "$env_hash" ]; then
      log "Container $CONTAINER_NAME already running with current config - leaving it up."
      DC start "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
      return 0
    fi
    log "Container $CONTAINER_NAME exists with an older config - recreating it."
    DC stop "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
    DC rm "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
  elif DC ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
    DC rm "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
  fi

  log "Starting container $CONTAINER_NAME (restart policy: unless-stopped)."
  # Windows proxies listen on the host's 127.0.0.1. Inside the container that
  # address is the container itself, so publish the host gateway when needed.
  local add_host=""
  if [ "${PROXY_NEEDS_HOST_GATEWAY:-0}" != "1" ] && grep -q 'host\.docker\.internal' "$ENV_FILE" 2>/dev/null; then
    PROXY_NEEDS_HOST_GATEWAY=1
  fi
  if [ "${PROXY_NEEDS_HOST_GATEWAY:-0}" = "1" ]; then
    add_host="--add-host=host.docker.internal:host-gateway"
  fi
  # shellcheck disable=SC2086
  run_logged DC run -d \
    --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --label "omniroute.env-hash=$env_hash" \
    $add_host \
    -p "${OMNIRoute_BIND_HOST}:${OMNIRoute_PORT}:${OMNIRoute_PORT}" \
    -p "${OMNIRoute_BIND_HOST}:${OMNIRoute_API_PORT}:${OMNIRoute_API_PORT}" \
    -v "${DATA_DIR}:/app/data" \
    --env-file "$ENV_FILE" \
    -e DATA_DIR=/app/data \
    "${IMAGE_NAME}:latest"
  # Mode marker: lets the quick commands (omni up/down/...) tell which
  # runtime manages OmniRoute on later invocations.
  echo "docker" >"$DATA_DIR/mode"
}

write_node_launcher() {
  # Deterministic launcher for Node mode: loads the managed .env and runs
  # `omniroute serve` with DATA_DIR pointing at the HOST data dir (the Docker
  # image uses /app/data instead). Used by both pm2 and the nohup fallback.
  local launcher="$HOME/omniroute-run.sh"
  local tmp
  tmp="$(make_tmp)"
  cat >"$tmp" <<LAUNCHER
#!/usr/bin/env bash
# Managed by omniroute-manager.sh (Node-mode launcher).
# Pick up the user's PATH (npm global bin etc.) - matters when started
# by a systemd unit at boot.
if [ -f "$HOME/.profile" ]; then . "$HOME/.profile" 2>/dev/null || true; fi
set -a
. "$ENV_FILE"
set +a
# Node mode runs on the host: DATA_DIR is the host directory, not /app/data.
export DATA_DIR="$DATA_DIR"
export PORT="$OMNIRoute_PORT"
exec omniroute serve
LAUNCHER
  mv "$tmp" "$launcher"
  chmod 700 "$launcher"
  NODE_LAUNCHER="$launcher"
  log "Wrote Node-mode launcher: $launcher"
}

start_node_process() {
  if [ -f "$NODE_MODE_PID_FILE" ]; then
    local pid
    pid="$(cat "$NODE_MODE_PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      log "Node OmniRoute already running (pid $pid) - leaving it up."
      return 0
    fi
    rm -f "$NODE_MODE_PID_FILE"
  fi
  write_node_launcher
  if [ "${PM2_AVAILABLE:-1}" = "1" ] && command -v pm2 >/dev/null 2>&1; then
    # pm2 acts as the systemd replacement: auto-restart on crash, and (after
    # 'pm2 startup') on boot. --interpreter bash runs the launcher wrapper.
    if ! run_logged pm2 start "$NODE_LAUNCHER" --name omniroute --interpreter bash --time; then
      die "pm2 failed to start omniroute."
    fi
    pm2 save >>"$LOG_FILE" 2>&1 || true
    pm2 startup systemd -u "$(whoami)" --hp "$HOME" >>"$LOG_FILE" 2>&1 \
      && log "pm2 autostart configured (if a sudo command was printed, run it once)." \
      || warn "pm2 startup not configured - OmniRoute will NOT auto-start after reboot."
  else
    log "Starting OmniRoute with nohup (no auto-restart available)."
    (
      nohup "$NODE_LAUNCHER" >>"$DATA_DIR/omniroute-node.log" 2>&1 &
      echo $! >"$NODE_MODE_PID_FILE"
    )
  fi
  # Mode marker (see start_container).
  echo "node" >"$DATA_DIR/mode"
}

# ---------------------------------------------------------------------------
# 10. Wait for health, then register provider keys via the management API
# ---------------------------------------------------------------------------
wait_for_health() {
  log "Waiting for $BASE_URL/healthz ..."
  local i attempt=0 max=60
  for i in $(seq 1 "$max"); do
    if curl -fsS --max-time 5 "$BASE_URL/healthz" >/dev/null 2>&1; then
      log "Health OK after attempt $i."
      return 0
    fi
    sleep 1
    attempt=$i
    if [ $(( i % 6 )) -eq 0 ]; then
      log "Still waiting... (attempt $i of $max). First boot can take 1-2 minutes."
      if [ "$RUN_MODE" = "docker" ]; then
        DC logs --tail 5 "$CONTAINER_NAME" 2>&1 | sed 's/^/    | /' | tee -a "$LOG_FILE" || true
      fi
    fi
  done
  if [ "$RUN_MODE" = "docker" ]; then
    warn "Last container log lines:"
    DC logs --tail 30 "$CONTAINER_NAME" 2>&1 | sed 's/^/    | /' | tee -a "$LOG_FILE" || true
  fi
  die "Service did not become healthy within ${max} attempts. Check $LOG_FILE."
}

dashboard_login() {
  log "Logging into the dashboard management API (loopback)."
  local jar body_file body rc=0
  jar="$(make_tmp)"
  body_file="$(make_tmp)"
  jq -n --arg password "$INITIAL_PASSWORD_SET" '{password:$password}' >"$body_file"
  set +e
  body="$(curl -fsS --max-time 15 -c "$jar" \
    -X POST "$BASE_URL/api/auth/login" \
    -H 'Content-Type: application/json' \
    --data-binary @"$body_file")"
  rc=$?
  set -e
  if [ $rc -ne 0 ] || ! grep -q "auth_token" "$jar" 2>/dev/null; then
    warn "Login failed (rc=$rc, response: ${body:-<empty>})."
    warn "Provider keys could not be registered via the API. You can add them later in the"
    warn "dashboard: http://127.0.0.1:${OMNIRoute_PORT} (password: $INITIAL_PASSWORD_SET)"
    return 1
  fi
  log "Dashboard login OK (auth_token cookie obtained)."
  COOKIE_JAR="$jar"
  return 0
}

mgmt_curl() {
  # mgmt_curl METHOD URL [body-file]
  local method="$1" url="$2" body="${3:-}"
  local out rc=0
  out="$(make_tmp)"
  set +e
  if [ -n "$body" ]; then
    curl -sS --max-time 30 -b "$COOKIE_JAR" -o "$out" -w '%{http_code}' \
      -X "$method" "$url" -H 'Content-Type: application/json' --data-binary @"$body" >"${out}.code"
  else
    curl -sS --max-time 30 -b "$COOKIE_JAR" -o "$out" -w '%{http_code}' \
      -X "$method" "$url" >"${out}.code"
  fi
  rc=$?
  set -e
  MGMT_BODY="$out"
  MGMT_CODE="$(cat "${out}.code" 2>/dev/null || echo 000)"
  [ "$rc" -eq 0 ] || MGMT_CODE="000"
  return 0
}

# POST /api/providers upserts by exact name. POST /api/providers/bulk does the
# opposite (#2587): a colliding name is renamed to "<name> <n>" and inserted.
# Re-runs must update the one managed connection and delete numbered copies.
upsert_provider_connection() {
  local provider="$1" key="$2"
  local list_file body_file id=""
  list_file="$(make_tmp)"
  mgmt_curl GET "$BASE_URL/api/providers"
  cp "$MGMT_BODY" "$list_file" 2>/dev/null || printf '%s\n' '{}' >"$list_file"

  # Managed names this installer owns: "ws-install" and "ws-install <n>".
  # User-named connections are left alone.
  local ids_file
  ids_file="$(make_tmp)"
  jq -r --arg p "$provider" --arg n "$CONN_NAME" '
      (.connections // [])
      | map(select(.provider == $p and (.name|type=="string")
                   and (.name == $n or (.name | test("^" + $n + " [0-9]+$")))))
      | sort_by(if .name == $n then 0 else 1 end, .name)
      | .[].id
    ' "$list_file" >"$ids_file" 2>/dev/null || true

  local keeper="" extra
  keeper="$(head -n1 "$ids_file" 2>/dev/null || true)"
  if [ -n "$keeper" ]; then
    body_file="$(make_tmp)"
    jq -n --arg name "$CONN_NAME" --arg apiKey "$key" \
      '{name:$name, apiKey:$apiKey, isActive:true}' >"$body_file"
    mgmt_curl PUT "$BASE_URL/api/providers/$keeper" "$body_file"
    if [ "$MGMT_CODE" != "200" ]; then
      warn "  -> $provider update failed (HTTP $MGMT_CODE)."
      return 1
    fi
    while IFS= read -r extra; do
      [ -n "$extra" ] || continue
      [ "$extra" = "$keeper" ] && continue
      log "  -> removing duplicate managed connection $extra"
      mgmt_curl DELETE "$BASE_URL/api/providers/$extra"
    done < <(tail -n +2 "$ids_file" 2>/dev/null || true)
    CONN_ID="$keeper"
    return 0
  fi

  body_file="$(make_tmp)"
  jq -n --arg provider "$provider" --arg name "$CONN_NAME" --arg apiKey "$key" \
    '{provider:$provider, name:$name, apiKey:$apiKey, priority:1}' >"$body_file"
  mgmt_curl POST "$BASE_URL/api/providers" "$body_file"
  if [ "$MGMT_CODE" != "200" ] && [ "$MGMT_CODE" != "201" ]; then
    warn "  -> $provider create failed (HTTP $MGMT_CODE)."
    return 1
  fi
  id="$(jq -r '.connection.id // .id // empty' "$MGMT_BODY" 2>/dev/null || true)"
  [ -n "$id" ] || { warn "  -> $provider create returned no id."; return 1; }
  # v3.8.51 creates single connections inactive until a test passes. Force
  # active so a geo-blocked probe cannot hide the provider from /v1/models.
  body_file="$(make_tmp)"
  jq -n '{isActive:true}' >"$body_file"
  mgmt_curl PUT "$BASE_URL/api/providers/$id" "$body_file"
  CONN_ID="$id"
  return 0
}

# Classify a provider as OK / BAD-KEY / UNREACHABLE.
# Direct probe (real installs) distinguishes a 403 geo-block from a bad key.
# OmniRoute's own test often labels 403 as "Upstream auth", which is misleading.
probe_provider() {
  local provider="$1" key="$2" conn_id="$3"
  local direct="skip" code="000" state="UNREACHABLE"

  if [ "${OMNIRoute_SKIP_DIRECT_PROBE:-0}" != "1" ]; then
    local url="" hdr=()
    case "$provider" in
      groq) url="https://api.groq.com/openai/v1/models" ;;
      openrouter) url="https://openrouter.ai/api/v1/models" ;;
      mistral) url="https://api.mistral.ai/v1/models" ;;
      cerebras) url="https://api.cerebras.ai/v1/models" ;;
      gemini) url="https://generativelanguage.googleapis.com/v1beta/models?key=${key}" ;;
    esac
    if [ -n "$url" ]; then
      set +e
      if [ "$provider" = "gemini" ]; then
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>>"$LOG_FILE")"
      else
        code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
          -H "Authorization: Bearer ${key}" "$url" 2>>"$LOG_FILE")"
      fi
      set -e
      [ -n "$code" ] || code="000"
      direct="$code"
    fi
  fi

  local test_body valid="false" status_code=""
  test_body="$(make_tmp)"
  jq -n '{}' >"$test_body"
  mgmt_curl POST "$BASE_URL/api/providers/${conn_id}/test" "$test_body"
  valid="$(jq -r '.valid // false' "$MGMT_BODY" 2>/dev/null || echo false)"
  status_code="$(jq -r '.statusCode // empty' "$MGMT_BODY" 2>/dev/null || true)"

  if [ "$direct" != "skip" ]; then
    case "$direct" in
      200|201) state="OK" ;;
      401) state="BAD-KEY" ;;
      400) state="BAD-KEY" ;;
      403|000|408|429) state="UNREACHABLE" ;;
      *)
        if [ "$valid" = "true" ]; then state="OK"; else state="UNREACHABLE"; fi
        ;;
    esac
  else
    if [ "$valid" = "true" ]; then
      state="OK"
    elif [ "$status_code" = "401" ] || [ "$status_code" = "400" ]; then
      state="BAD-KEY"
    else
      state="UNREACHABLE"
    fi
  fi

  # A failed probe must not auto-disable the connection. Re-assert isActive.
  local enable_body
  enable_body="$(make_tmp)"
  jq -n '{isActive:true}' >"$enable_body"
  mgmt_curl PUT "$BASE_URL/api/providers/${conn_id}" "$enable_body" || true

  PROBE_STATE="$state"
  log "  -> $provider probe: $state (direct=${direct}, testStatusCode=${status_code:-none}, valid=${valid})"
}

register_provider_keys() {
  local -a pairs=()
  [ -n "${KEY_GROQ:-}" ]       && pairs+=("groq|$KEY_GROQ")
  [ -n "${KEY_OPENROUTER:-}" ] && pairs+=("openrouter|$KEY_OPENROUTER")
  [ -n "${KEY_GEMINI:-}" ]     && pairs+=("gemini|$KEY_GEMINI")
  [ -n "${KEY_CEREBRAS:-}" ]   && pairs+=("cerebras|$KEY_CEREBRAS")
  [ -n "${KEY_MISTRAL:-}" ]    && pairs+=("mistral|$KEY_MISTRAL")

  PROVIDER_STATUS_GROQ="-"
  PROVIDER_STATUS_OPENROUTER="-"
  PROVIDER_STATUS_GEMINI="-"
  PROVIDER_STATUS_CEREBRAS="-"
  PROVIDER_STATUS_MISTRAL="-"
  REGISTERED_OK=""; REGISTERED_FAIL=""
  HEALTHY_PROVIDERS=0
  UNREACHABLE_PROVIDERS=0

  if ! dashboard_login; then
    local q
    for q in "${pairs[@]}"; do
      REGISTERED_FAIL="$REGISTERED_FAIL ${q%%|*}"
      case "${q%%|*}" in
        groq) PROVIDER_STATUS_GROQ="FAILED" ;;
        openrouter) PROVIDER_STATUS_OPENROUTER="FAILED" ;;
        gemini) PROVIDER_STATUS_GEMINI="FAILED" ;;
        cerebras) PROVIDER_STATUS_CEREBRAS="FAILED" ;;
        mistral) PROVIDER_STATUS_MISTRAL="FAILED" ;;
      esac
    done
    return 0
  fi

  local pair p k
  for pair in "${pairs[@]}"; do
    p="${pair%%|*}"; k="${pair#*|}"
    log "Registering provider connection: $p (idempotent, name=$CONN_NAME)"
    if ! upsert_provider_connection "$p" "$k"; then
      REGISTERED_FAIL="$REGISTERED_FAIL $p"
      case "$p" in
        groq) PROVIDER_STATUS_GROQ="FAILED" ;;
        openrouter) PROVIDER_STATUS_OPENROUTER="FAILED" ;;
        gemini) PROVIDER_STATUS_GEMINI="FAILED" ;;
        cerebras) PROVIDER_STATUS_CEREBRAS="FAILED" ;;
        mistral) PROVIDER_STATUS_MISTRAL="FAILED" ;;
      esac
      continue
    fi
    probe_provider "$p" "$k" "$CONN_ID"
    case "$p" in
      groq) PROVIDER_STATUS_GROQ="$PROBE_STATE" ;;
      openrouter) PROVIDER_STATUS_OPENROUTER="$PROBE_STATE" ;;
      gemini) PROVIDER_STATUS_GEMINI="$PROBE_STATE" ;;
      cerebras) PROVIDER_STATUS_CEREBRAS="$PROBE_STATE" ;;
      mistral) PROVIDER_STATUS_MISTRAL="$PROBE_STATE" ;;
    esac
    case "$PROBE_STATE" in
      OK)
        REGISTERED_OK="$REGISTERED_OK $p"
        HEALTHY_PROVIDERS=$((HEALTHY_PROVIDERS + 1))
        ;;
      UNREACHABLE)
        REGISTERED_FAIL="$REGISTERED_FAIL $p"
        UNREACHABLE_PROVIDERS=$((UNREACHABLE_PROVIDERS + 1))
        ;;
      *)
        REGISTERED_FAIL="$REGISTERED_FAIL $p"
        ;;
    esac
  done
  if [ "$UNREACHABLE_PROVIDERS" -gt 0 ]; then
    warn "One or more providers are UNREACHABLE. HTTP 403 from Groq, Gemini or"
    warn "OpenRouter is often a geo-block, not a bad key. Set OMNIRoute_PROXY_URL"
    warn "to http://host:port or socks5://host:port and re-run, or: omni proxy on."
    warn "Per-provider: OMNIRoute_PROXY_GROQ, _OPENROUTER, _GEMINI, _CEREBRAS, _MISTRAL."
  fi
  if [ "$HEALTHY_PROVIDERS" -eq 0 ]; then
    warn "No provider probe returned OK. The gateway is still installed; fix keys or proxy and re-run."
  fi
  fetch_service_version || true
  ensure_client_key || true
  apply_outbound_proxy || true
}

fetch_service_version() {
  SERVICE_VERSION="unknown"
  mgmt_curl GET "$BASE_URL/api/system/version"
  if [ "$MGMT_CODE" = "200" ]; then
    SERVICE_VERSION="$(jq -r '.current // "unknown"' "$MGMT_BODY" 2>/dev/null || echo unknown)"
  fi
  log "Running OmniRoute version: $SERVICE_VERSION (image pin: ${IMAGE_TAG_PIN})"
  if [ "$SERVICE_VERSION" != "unknown" ] && [ "$SERVICE_VERSION" != "$IMAGE_TAG_PIN" ]; then
    warn "Running version $SERVICE_VERSION does not match pinned image tag $IMAGE_TAG_PIN."
  fi
}

ensure_client_key() {
  # Real api-manager key (POST /api/keys). The env OMNIROUTE_API_KEY passthrough
  # is kept until the operator says otherwise; Claude is pointed at this key.
  CLIENT_KEY=""
  local existing_id="" body_file
  mgmt_curl GET "$BASE_URL/api/keys"
  if [ -f "$CLIENT_KEY_FILE" ]; then
    CLIENT_KEY="$(head -n1 "$CLIENT_KEY_FILE" | tr -d '[:space:]')"
  fi
  existing_id="$(jq -r --arg n "$CLIENT_KEY_NAME" '(.keys // []) | map(select(.name==$n)) | .[0].id // empty' "$MGMT_BODY" 2>/dev/null || true)"
  if [ -n "$existing_id" ] && [ -n "$CLIENT_KEY" ]; then
    log "Reusing api-manager key '$CLIENT_KEY_NAME' from $CLIENT_KEY_FILE"
    return 0
  fi
  if [ -n "$existing_id" ] && [ -z "$CLIENT_KEY" ]; then
    log "api-manager has '$CLIENT_KEY_NAME' but the local copy is missing - rotating it."
    mgmt_curl DELETE "$BASE_URL/api/keys/$existing_id" || true
  fi
  body_file="$(make_tmp)"
  jq -n --arg name "$CLIENT_KEY_NAME" '{name:$name}' >"$body_file"
  mgmt_curl POST "$BASE_URL/api/keys" "$body_file"
  if [ "$MGMT_CODE" != "200" ] && [ "$MGMT_CODE" != "201" ]; then
    warn "POST /api/keys failed (HTTP $MGMT_CODE). Claude will fall back to the master key."
    CLIENT_KEY="$MASTER_KEY"
    return 0
  fi
  CLIENT_KEY="$(jq -r '.key // empty' "$MGMT_BODY" 2>/dev/null || true)"
  if [ -z "$CLIENT_KEY" ]; then
    warn "POST /api/keys returned no key. Claude will fall back to the master key."
    CLIENT_KEY="$MASTER_KEY"
    return 0
  fi
  printf '%s\n' "$CLIENT_KEY" >"$CLIENT_KEY_FILE"
  chmod 600 "$CLIENT_KEY_FILE"
  log "Created api-manager key '$CLIENT_KEY_NAME' in $CLIENT_KEY_FILE (mode 600)."
}

parse_proxy_url() {
  # Sets PROXY_TYPE PROXY_HOST PROXY_PORT PROXY_USER PROXY_PASS. Returns 1 if unparsable.
  local url="$1" rest scheme auth hostport
  PROXY_TYPE=""; PROXY_HOST=""; PROXY_PORT=""; PROXY_USER=""; PROXY_PASS=""
  case "$url" in
    http://*|https://*|socks5://*) ;;
    *) return 1 ;;
  esac
  scheme="${url%%://*}"
  rest="${url#*://}"
  case "$scheme" in
    http|https|socks5) PROXY_TYPE="$scheme" ;;
    *) return 1 ;;
  esac
  if [[ "$rest" == *"@"* ]]; then
    auth="${rest%%@*}"
    hostport="${rest#*@}"
    PROXY_USER="${auth%%:*}"
    PROXY_PASS="${auth#*:}"
    [ "$PROXY_PASS" = "$auth" ] && PROXY_PASS=""
  else
    hostport="$rest"
  fi
  hostport="${hostport%%/*}"
  PROXY_HOST="${hostport%%:*}"
  PROXY_PORT="${hostport##*:}"
  [ -n "$PROXY_HOST" ] && [ -n "$PROXY_PORT" ] && [[ "$PROXY_PORT" =~ ^[0-9]+$ ]]
}

# Read the Windows user proxy (Internet Settings). Prints nothing and returns
# 1 when proxy is off, missing, or only a PAC script.
detect_windows_proxy() {
  WINDOWS_PROXY_RAW=""
  command -v powershell.exe >/dev/null 2>&1 || return 1
  local raw enable server pac hostport
  raw="$(powershell.exe -NoProfile -Command "Get-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings' | Select-Object ProxyEnable,ProxyServer,AutoConfigURL | Format-List" 2>/dev/null | tr -d '\r' || true)"
  enable="$(printf '%s\n' "$raw" | sed -n 's/^ProxyEnable[[:space:]]*[:=][[:space:]]*//p' | head -n1 | tr -d '[:space:]')"
  server="$(printf '%s\n' "$raw" | sed -n 's/^ProxyServer[[:space:]]*[:=][[:space:]]*//p' | head -n1 | sed 's/[[:space:]]*$//')"
  pac="$(printf '%s\n' "$raw" | sed -n 's/^AutoConfigURL[[:space:]]*[:=][[:space:]]*//p' | head -n1 | sed 's/[[:space:]]*$//')"
  case "$enable" in
    1|true|True) ;;
    *)
      if [ -n "$pac" ]; then
        warn "Windows proxy is a PAC script ($pac). This installer cannot evaluate PAC."
        warn "Set OMNIRoute_PROXY_URL=http://host:port if you still want a proxy."
      fi
      return 1
      ;;
  esac
  [ -n "$server" ] || return 1
  hostport="$server"
  if [[ "$server" == *"="* ]]; then
    hostport="$(printf '%s' "$server" | tr ';' '\n' | sed -n 's/^https=//p' | head -n1)"
    [ -n "$hostport" ] || hostport="$(printf '%s' "$server" | tr ';' '\n' | sed -n 's/^http=//p' | head -n1)"
    [ -n "$hostport" ] || hostport="$(printf '%s' "$server" | tr ';' '\n' | sed -n 's/^socks=//p' | head -n1)"
  fi
  [ -n "$hostport" ] || return 1
  case "$hostport" in
    http://*|https://*|socks5://*) WINDOWS_PROXY_RAW="$hostport" ;;
    *) WINDOWS_PROXY_RAW="http://${hostport}" ;;
  esac
  return 0
}

# A Windows proxy on 127.0.0.1 is the Windows host, not the container.
# Docker: host.docker.internal + --add-host=host-gateway.
# Node: the WSL nameserver, which is the Windows host IP.
containerize_proxy_url() {
  local url="$1"
  parse_proxy_url "$url" || return 1
  local host="$PROXY_HOST" type="$PROXY_TYPE" port="$PROXY_PORT" user="$PROXY_USER" pass="$PROXY_PASS"
  case "$host" in
    127.0.0.1|localhost|::1)
      if [ "${RUN_MODE:-docker}" = "docker" ]; then
        host="host.docker.internal"
        PROXY_NEEDS_HOST_GATEWAY=1
        # stderr: this function's stdout is the rewritten URL.
        log "Loopback proxy rewritten to host.docker.internal so the container can reach Windows." >&2
      else
        local winip
        winip="$(awk '/^nameserver / && $2 != "127.0.0.1" {print $2; exit}' /etc/resolv.conf 2>/dev/null || true)"
        if [ -n "$winip" ]; then
          host="$winip"
          log "Loopback proxy rewritten to WSL host IP $winip." >&2
        fi
      fi
      ;;
  esac
  if [ -n "$user" ]; then
    printf '%s://%s:%s@%s:%s' "$type" "$user" "$pass" "$host" "$port"
  else
    printf '%s://%s:%s' "$type" "$host" "$port"
  fi
}

save_proxy_choice() {
  mkdir -p "$DATA_DIR"
  {
    echo "PROXY_CHOICE=${PROXY_ENABLED}"
    printf 'PROXY_CHOICE_URL=%q\n' "${PROXY_SOURCE_URL:-}"
    printf 'RESOLVED_PROXY_URL=%q\n' "${RESOLVED_PROXY_URL:-}"
  } >"$DATA_DIR/proxy.choice"
  chmod 600 "$DATA_DIR/proxy.choice"
}

# Sets PROXY_ENABLED (0/1), RESOLVED_PROXY_URL, PROXY_NEEDS_HOST_GATEWAY.
# Precedence: OMNIRoute_USE_PROXY=0, explicit OMNIRoute_PROXY_URL,
# OMNIRoute_USE_PROXY=1, interactive y/n when a Windows proxy is active,
# saved choice, otherwise off.
resolve_proxy_choice() {
  PROXY_ENABLED=0
  RESOLVED_PROXY_URL=""
  PROXY_SOURCE_URL=""
  PROXY_NEEDS_HOST_GATEWAY=0
  local choice="off" url="" detected=""
  detect_windows_proxy && detected="$WINDOWS_PROXY_RAW" || true

  case "${OMNIRoute_USE_PROXY:-}" in
    0|off|n|N|false|no) choice="off" ;;
    1|on|y|Y|true|yes)
      choice="on"
      url="${OMNIRoute_PROXY_URL:-$detected}"
      ;;
    *)
      if [ -n "${OMNIRoute_PROXY_URL:-}" ]; then
        choice="on"
        url="$OMNIRoute_PROXY_URL"
      elif is_tty && [ -n "$detected" ]; then
        log "Active Windows proxy: $detected"
        log "Yes routes every OmniRoute provider call through it."
        log "This does not download Claude Desktop's own binary; that download"
        log "follows the Windows system proxy to downloads.claude.ai."
        if prompt_yes_no "Use the active Windows proxy for OmniRoute?" "y"; then
          choice="on"
          url="$detected"
        else
          choice="off"
          log "Windows proxy declined. OmniRoute will connect directly."
        fi
      elif [ -f "$DATA_DIR/proxy.choice" ]; then
        # shellcheck disable=SC1090
        . "$DATA_DIR/proxy.choice"
        if [ "${PROXY_CHOICE:-0}" = "1" ] && [ -n "${PROXY_CHOICE_URL:-}" ]; then
          choice="on"
          url="$PROXY_CHOICE_URL"
          log "Reusing saved proxy choice: on"
        else
          choice="off"
          log "Reusing saved proxy choice: off"
        fi
      else
        choice="off"
      fi
      ;;
  esac

  if [ "$choice" = "on" ]; then
    if [ -z "$url" ]; then
      warn "Proxy requested, but no Windows proxy is active and OMNIRoute_PROXY_URL is empty."
      warn "Leaving proxy off. Turn it on later with: omni proxy on"
      choice="off"
    else
      PROXY_SOURCE_URL="$url"
      RESOLVED_PROXY_URL="$(containerize_proxy_url "$url")" || {
        warn "Could not parse proxy URL '$url'. Leaving proxy off."
        choice="off"
        RESOLVED_PROXY_URL=""
      }
      # containerize runs in a subshell, so the host-gateway flag must be
      # recovered here from the rewritten URL.
      case "$RESOLVED_PROXY_URL" in
        *host.docker.internal*) PROXY_NEEDS_HOST_GATEWAY=1 ;;
      esac
    fi
  fi
  if [ "$choice" = "on" ] && [ "${RUN_MODE:-docker}" = "docker" ]; then
    local p var_name p_url
    for p in groq openrouter gemini cerebras mistral; do
      var_name="OMNIRoute_PROXY_$(printf '%s' "$p" | tr '[:lower:]' '[:upper:]')"
      p_url="${!var_name:-}"
      case "$p_url" in
        *127.0.0.1*|*localhost*|*'[::1]'*) PROXY_NEEDS_HOST_GATEWAY=1 ;;
      esac
    done
  fi
  if [ "$choice" = "on" ]; then
    PROXY_ENABLED=1
    OMNIRoute_PROXY_URL="$RESOLVED_PROXY_URL"
    log "Proxy ENABLED. All OmniRoute provider traffic -> $RESOLVED_PROXY_URL"
  else
    PROXY_ENABLED=0
    RESOLVED_PROXY_URL=""
    PROXY_SOURCE_URL=""
    # An explicit off must not let a leftover URL turn the proxy back on.
    if [ "${OMNIRoute_USE_PROXY:-}" = "0" ] || [ "${OMNIRoute_USE_PROXY:-}" = "off" ]; then
      OMNIRoute_PROXY_URL=""
    fi
    log "Proxy DISABLED. OmniRoute provider traffic goes direct."
  fi
  save_proxy_choice
}

patch_env_proxy_lines() {
  local env_file="${ENV_FILE:-$DATA_DIR/.env}" tmp
  [ -f "$env_file" ] || return 0
  tmp="$(make_tmp)"
  grep -Ev '^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)=' "$env_file" >"$tmp" || true
  if [ "${PROXY_ENABLED:-0}" = "1" ] && [ -n "${RESOLVED_PROXY_URL:-}" ]; then
    printf 'HTTP_PROXY=%s\nHTTPS_PROXY=%s\nALL_PROXY=%s\nNO_PROXY=localhost,127.0.0.1,::1\n' \
      "$RESOLVED_PROXY_URL" "$RESOLVED_PROXY_URL" "$RESOLVED_PROXY_URL" >>"$tmp"
  fi
  mv "$tmp" "$env_file"
  chmod 600 "$env_file"
  ENV_FILE="$env_file"
}

apply_outbound_proxy() {
  # PUT /api/settings/proxy { global, providers }. Off clears the global level
  # with DELETE ?level=global so a later "proxy off" actually stops routing.
  local body_file p var_name p_url rewritten
  if [ "${PROXY_ENABLED:-0}" != "1" ]; then
    log "Clearing OmniRoute global proxy (direct provider access)."
    mgmt_curl DELETE "$BASE_URL/api/settings/proxy?level=global"
    if [ "$MGMT_CODE" = "200" ] || [ "$MGMT_CODE" = "404" ]; then
      log "Global proxy cleared via DELETE /api/settings/proxy?level=global."
    else
      warn "Could not clear proxy (HTTP $MGMT_CODE). Turn it off in the dashboard: Settings -> Proxy."
    fi
    return 0
  fi

  local url="${OMNIRoute_PROXY_URL:-${RESOLVED_PROXY_URL:-}}"
  local global_json="null" providers_json="{}" frag
  if [ -n "$url" ]; then
    if parse_proxy_url "$url"; then
      log "Global outbound proxy -> $PROXY_TYPE://$PROXY_HOST:$PROXY_PORT"
      global_json="$(jq -n --arg type "$PROXY_TYPE" --arg host "$PROXY_HOST" \
        --argjson port "$PROXY_PORT" --arg username "$PROXY_USER" --arg password "$PROXY_PASS" \
        '{type:$type, host:$host, port:$port, username:$username, password:$password}')"
    else
      warn "Ignoring invalid proxy URL (want http://host:port or socks5://host:port)."
    fi
  fi
  for p in groq openrouter gemini cerebras mistral; do
    var_name="OMNIRoute_PROXY_$(printf '%s' "$p" | tr '[:lower:]' '[:upper:]')"
    p_url="${!var_name:-}"
    [ -n "$p_url" ] || continue
    rewritten="$(containerize_proxy_url "$p_url" 2>/dev/null || true)"
    [ -n "$rewritten" ] && p_url="$rewritten"
    if ! parse_proxy_url "$p_url"; then
      warn "Ignoring invalid $var_name (want http://host:port or socks5://host:port)."
      continue
    fi
    log "Per-provider proxy for $p -> $PROXY_TYPE://$PROXY_HOST:$PROXY_PORT"
    frag="$(jq -n --arg p "$p" --arg type "$PROXY_TYPE" --arg host "$PROXY_HOST" \
      --argjson port "$PROXY_PORT" --arg username "$PROXY_USER" --arg password "$PROXY_PASS" \
      '{($p): {type:$type, host:$host, port:$port, username:$username, password:$password}}')"
    providers_json="$(jq -n --argjson base "$providers_json" --argjson extra "$frag" '$base + $extra')"
  done
  if [ "$global_json" = "null" ] && [ "$providers_json" = "{}" ]; then
    warn "Proxy is enabled but no usable URL was parsed."
    return 0
  fi
  body_file="$(make_tmp)"
  jq -n --argjson global "$global_json" --argjson providers "$providers_json" '
      (if $global == null then {} else {global:$global} end)
      + (if $providers == {} then {} else {providers:$providers} end)
    ' >"$body_file"
  mgmt_curl PUT "$BASE_URL/api/settings/proxy" "$body_file"
  if [ "$MGMT_CODE" = "200" ]; then
    log "Outbound proxy applied via PUT /api/settings/proxy."
  else
    warn "Could not apply proxy (HTTP $MGMT_CODE). Set it in the dashboard: Settings -> Proxy."
  fi
}

# ---------------------------------------------------------------------------
# 11. Claude Code + Claude Desktop configuration (Windows path with spaces)
# ---------------------------------------------------------------------------
# Claude Code (official):
#   %USERPROFILE%\.claude\settings.json  env.ANTHROPIC_BASE_URL = gateway ROOT
#   (no /v1). ANTHROPIC_AUTH_TOKEN is sent as Authorization: Bearer.
# Claude Desktop (official):
#   does NOT read settings.json. Third-party inference profile under
#   %LOCALAPPDATA%\Claude-3p . HTTP is legal only on loopback.
win_to_unix() {
  local raw="$1" win_dir=""
  raw="$(printf '%s' "$raw" | tr -d '\r')"
  [ -n "$raw" ] || return 1
  if [[ "$raw" == /* ]]; then
    printf '%s' "$raw"
    return 0
  fi
  if command -v wslpath >/dev/null 2>&1; then
    win_dir="$(wslpath -u "$raw" 2>/dev/null | tr -d '\r' || true)"
    [ -n "$win_dir" ] && printf '%s' "$win_dir" && return 0
  fi
  return 1
}

ps_folder() {
  local kind="$1" raw=""
  command -v powershell.exe >/dev/null 2>&1 || return 1
  raw="$(powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('${kind}')" 2>/dev/null | tr -d '\r' | head -n1 || true)"
  win_to_unix "$raw"
}

detect_claude_dirs() {
  CLAUDE_CODE_DIR=""
  CLAUDE_DESKTOP_DIR=""
  local win_profile="" local_app=""
  if [ -n "${OMNIRoute_CLAUDE_DIR:-}" ]; then
    CLAUDE_CODE_DIR="$OMNIRoute_CLAUDE_DIR"
    log "Claude Code dir override: $CLAUDE_CODE_DIR"
  fi
  win_profile="$(ps_folder UserProfile || true)"
  local_app="$(ps_folder LocalApplicationData || true)"
  if [ -z "$CLAUDE_CODE_DIR" ] && [ -n "$win_profile" ]; then
    CLAUDE_CODE_DIR="$win_profile/.claude"
  fi
  if [ -n "$local_app" ]; then
    CLAUDE_DESKTOP_DIR="$local_app/Claude-3p"
  elif [ -n "$win_profile" ]; then
    CLAUDE_DESKTOP_DIR="$win_profile/AppData/Local/Claude-3p"
  fi
  if [ -z "$CLAUDE_CODE_DIR" ]; then
    local d
    for d in "$MNT_ROOT"/c/Users/*/; do
      d="${d%/}"
      [ -d "$d" ] || continue
      CLAUDE_CODE_DIR="$d/.claude"
      CLAUDE_DESKTOP_DIR="$d/AppData/Local/Claude-3p"
      log "Claude dirs (fallback $MNT_ROOT/c scan): $CLAUDE_CODE_DIR"
      break
    done
  fi
  if [ -z "$CLAUDE_CODE_DIR" ]; then
    CLAUDE_CODE_DIR="$HOME/.claude"
    warn "Windows user dir not detected - writing the WSL-side Claude Code config: $CLAUDE_CODE_DIR"
  else
    log "Claude Code settings dir: $CLAUDE_CODE_DIR"
  fi
  [ -n "$CLAUDE_DESKTOP_DIR" ] && log "Claude Desktop 3P dir: $CLAUDE_DESKTOP_DIR"
  # WSL-side copy so `claude` inside WSL hits the same gateway.
  CLAUDE_WSL_DIR="$HOME/.claude"
}

fetch_catalog() {
  local out
  out="$(make_tmp)"
  local token="${CLIENT_KEY:-$MASTER_KEY}"
  if curl -fsS --max-time 30 -H "Authorization: Bearer $token" \
      "$BASE_URL/v1/models" >"$out" 2>>"$LOG_FILE" \
    && jq -e '(.data? // .) | type == "array"' "$out" >/dev/null 2>&1; then
    CATALOG_FILE="$out"
    MODEL_COUNT="$(jq '(.data? // .) | length' "$out")"
    return 0
  fi
  # Fall back to the passthrough master key if the client key is not live yet.
  if [ "$token" != "$MASTER_KEY" ] && curl -fsS --max-time 30 \
      -H "Authorization: Bearer $MASTER_KEY" \
      "$BASE_URL/v1/models" >"$out" 2>>"$LOG_FILE" \
    && jq -e '(.data? // .) | type == "array"' "$out" >/dev/null 2>&1; then
    CATALOG_FILE="$out"
    MODEL_COUNT="$(jq '(.data? // .) | length' "$out")"
    return 0
  fi
  warn "Could not fetch /v1/models - Claude will be pinned to a built-in model id."
  CATALOG_FILE=""
  MODEL_COUNT=0
  return 1
}

choose_claude_model() {
  CLAUDE_MODEL=""
  CLAUDE_CONTEXT="200000"
  local m
  for m in "${PREFERRED_MODELS[@]}"; do
    if [ -n "${CATALOG_FILE:-}" ] && jq -e --arg m "$m" '((.data? // .) | map(.id) | index($m)) != null' "$CATALOG_FILE" >/dev/null 2>&1; then
      CLAUDE_MODEL="$m"
      break
    fi
  done
  if [ -z "$CLAUDE_MODEL" ] && [ -n "${CATALOG_FILE:-}" ]; then
    CLAUDE_MODEL="$(jq -r '((.data? // .) | map(.id) | .[0]) // empty' "$CATALOG_FILE")"
  fi
  [ -n "$CLAUDE_MODEL" ] || CLAUDE_MODEL="${PREFERRED_MODELS[0]}"
  if [ -n "${CATALOG_FILE:-}" ]; then
    local ctx
    ctx="$(jq -r --arg m "$CLAUDE_MODEL" '((.data? // .) | map(select(.id==$m)) | .[0].context_length // .[0].max_context_window_tokens // 200000)' "$CATALOG_FILE" 2>/dev/null || echo 200000)"
    case "$ctx" in
      ''|null|*[!0-9]*) ctx="200000" ;;
    esac
    [ "$ctx" -gt 0 ] 2>/dev/null || ctx="200000"
    CLAUDE_CONTEXT="$ctx"
  fi
  # Compact a bit before the real window. Claude Code assumes 200K for ids
  # it does not recognise, which fires compaction too early on larger models.
  if [ "$CLAUDE_CONTEXT" -gt 16000 ]; then
    CLAUDE_COMPACT="$((CLAUDE_CONTEXT - 8192))"
  else
    CLAUDE_COMPACT="$CLAUDE_CONTEXT"
  fi
  log "Claude model: $CLAUDE_MODEL (context=$CLAUDE_CONTEXT, compact=$CLAUDE_COMPACT)"
}

write_claude_settings() {
  # $1 = settings.json path. Merges env gateway keys; preserves unrelated keys.
  local config_path="$1"
  local dir base_file tmp token
  dir="$(dirname "$config_path")"
  mkdir -p "$dir"
  base_file="$(make_tmp)"
  tmp="$(make_tmp)"
  token="${CLIENT_KEY:-$MASTER_KEY}"
  if [ -f "$config_path" ] && jq -e . "$config_path" >/dev/null 2>&1; then
    jq . "$config_path" >"$base_file"
  else
    if [ -f "$config_path" ]; then
      local bak="${config_path}.bak-$(date +%Y%m%d%H%M%S)"
      warn "Existing $config_path is not valid JSON - backing up to $bak"
      cp "$config_path" "$bak" 2>/dev/null || true
    fi
    printf '{}\n' >"$base_file"
  fi
  # Gateway root, no /v1, no trailing slash. Bearer token only.
  jq --arg baseURL "$BASE_URL" \
     --arg token "$token" \
     --arg model "$CLAUDE_MODEL" \
     --arg compact "$CLAUDE_COMPACT" \
     '
      .env = (.env // {})
      | .env.ANTHROPIC_BASE_URL = $baseURL
      | .env.ANTHROPIC_AUTH_TOKEN = $token
      | del(.env.ANTHROPIC_API_KEY)
      | .env.ANTHROPIC_MODEL = $model
      | .env.ANTHROPIC_DEFAULT_OPUS_MODEL = $model
      | .env.ANTHROPIC_DEFAULT_SONNET_MODEL = $model
      | .env.ANTHROPIC_DEFAULT_HAIKU_MODEL = $model
      | .env.ANTHROPIC_SMALL_FAST_MODEL = $model
      | .env.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY = "1"
      | .env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC = "1"
      | .env.CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING = "1"
      | .env.CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS = "1"
      | .env.CLAUDE_CODE_SKIP_FAST_MODE_NETWORK_ERRORS = "1"
      | .env.CLAUDE_CODE_ATTRIBUTION_HEADER = "0"
      | .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW = $compact
      | .model = $model
      | .hasCompletedOnboarding = true
      | .omnirouteManaged = true
      | if has("$schema") then . else . + {"$schema": "https://json.schemastore.org/claude-code-settings.json"} end
     ' "$base_file" >"$tmp"
  jq -e . "$tmp" >/dev/null || die "Internal error: generated Claude settings are invalid."
  mv "$tmp" "$config_path"
  chmod 600 "$config_path"
  log "Wrote Claude Code settings: $config_path"
}

write_desktop_profile() {
  local root="$1"
  [ -n "$root" ] || return 0
  local lib="$root/configLibrary"
  local profile="$lib/${DESKTOP_PROFILE_ID}.json"
  local meta="$lib/_meta.json"
  local desktop_cfg="$root/claude_desktop_config.json"
  local tmp token alias
  mkdir -p "$lib"
  token="${CLIENT_KEY:-$MASTER_KEY}"
  # Discovery aliases are claude/<id>. Desktop's picker prefers claude* names.
  case "$CLAUDE_MODEL" in
    claude/*|anthropic/*) alias="$CLAUDE_MODEL" ;;
    *) alias="claude/$CLAUDE_MODEL" ;;
  esac
  tmp="$(make_tmp)"
  jq -n --arg base "$BASE_URL" --arg key "$token" --arg model "$CLAUDE_MODEL" --arg alias "$alias" '
    {
      inferenceProvider: "gateway",
      inferenceCredentialKind: "static",
      inferenceGatewayBaseUrl: $base,
      inferenceGatewayApiKey: $key,
      inferenceGatewayAuthScheme: "bearer",
      modelDiscoveryEnabled: true,
      chatTabEnabled: true,
      disableEssentialTelemetry: true,
      disableNonessentialTelemetry: true,
      inferenceModels: [
        {name: $alias, labelOverride: ("OmniRoute " + $model), isFamilyDefault: true},
        {name: $model, labelOverride: $model}
      ]
    }' >"$tmp"
  mv "$tmp" "$profile"
  chmod 600 "$profile"
  if [ -f "$meta" ] && jq -e . "$meta" >/dev/null 2>&1; then
    tmp="$(make_tmp)"
    jq --arg id "$DESKTOP_PROFILE_ID" '
        .entries = ((.entries // []) | map(select(.id != $id)))
        | .entries += [{id:$id, name:"OmniRoute"}]
        | .appliedId = $id
      ' "$meta" >"$tmp"
    mv "$tmp" "$meta"
  else
    jq -n --arg id "$DESKTOP_PROFILE_ID" '{appliedId:$id, entries:[{id:$id, name:"OmniRoute"}]}' >"$meta"
  fi
  chmod 600 "$meta"
  if [ -f "$desktop_cfg" ] && jq -e . "$desktop_cfg" >/dev/null 2>&1; then
    tmp="$(make_tmp)"
    jq '.deploymentMode = "3p" | .omnirouteManaged = true' "$desktop_cfg" >"$tmp"
    mv "$tmp" "$desktop_cfg"
  else
    if [ -f "$desktop_cfg" ]; then
      warn "Existing $desktop_cfg is not valid JSON - leaving it and writing deploymentMode beside the profile."
    else
      jq -n '{deploymentMode:"3p", omnirouteManaged:true}' >"$desktop_cfg"
    fi
  fi
  chmod 600 "$desktop_cfg" 2>/dev/null || true
  log "Wrote Claude Desktop 3P profile: $profile"
  CLAUDE_DESKTOP_PROFILE="$profile"
}

write_vscode_claude_env() {
  # The VS Code extension does not read ~/.claude/settings.json for its login
  # check. Only update an existing user settings.json (do not create one).
  local roaming="" settings="" tmp token
  roaming="$(ps_folder ApplicationData || true)"
  [ -n "$roaming" ] || return 0
  settings="$roaming/Code/User/settings.json"
  [ -f "$settings" ] || return 0
  if ! jq -e . "$settings" >/dev/null 2>&1; then
    warn "VS Code settings exist but are not plain JSON. Not rewriting: $settings"
    warn "Add claudeCode.environmentVariables yourself; settings.json env is not enough for the extension."
    return 0
  fi
  token="${CLIENT_KEY:-$MASTER_KEY}"
  tmp="$(make_tmp)"
  jq --arg base "$BASE_URL" --arg token "$token" --arg model "${CLAUDE_MODEL:-}" '
      .["claudeCode.environmentVariables"] = (
        (.["claudeCode.environmentVariables"] // [])
        | map(select(.name as $n |
            ["ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN","ANTHROPIC_API_KEY","ANTHROPIC_MODEL",
             "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
             "CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING","CLAUDE_CODE_ATTRIBUTION_HEADER"]
            | index($n) | not))
        + [
            {name:"ANTHROPIC_BASE_URL", value:$base},
            {name:"ANTHROPIC_AUTH_TOKEN", value:$token},
            {name:"ANTHROPIC_MODEL", value:$model},
            {name:"CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY", value:"1"},
            {name:"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", value:"1"},
            {name:"CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING", value:"1"},
            {name:"CLAUDE_CODE_ATTRIBUTION_HEADER", value:"0"}
          ]
      )
    ' "$settings" >"$tmp"
  jq -e . "$tmp" >/dev/null || { warn "Could not update VS Code settings."; return 0; }
  mv "$tmp" "$settings"
  log "Updated VS Code Claude extension env: $settings"
}

strip_vscode_claude_env() {
  local roaming="" settings="" tmp
  roaming="$(ps_folder ApplicationData || true)"
  [ -n "$roaming" ] || return 0
  settings="$roaming/Code/User/settings.json"
  [ -f "$settings" ] || return 0
  jq -e . "$settings" >/dev/null 2>&1 || return 0
  tmp="$(make_tmp)"
  jq '
      if .["claudeCode.environmentVariables"] then
        .["claudeCode.environmentVariables"] |= map(select(.name as $n |
          ["ANTHROPIC_BASE_URL","ANTHROPIC_AUTH_TOKEN","ANTHROPIC_API_KEY","ANTHROPIC_MODEL",
           "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
           "CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING","CLAUDE_CODE_ATTRIBUTION_HEADER"]
          | index($n) | not))
        | if (.["claudeCode.environmentVariables"] | length) == 0 then del(.["claudeCode.environmentVariables"]) else . end
      else . end
    ' "$settings" >"$tmp" && mv "$tmp" "$settings"
  log "Stripped OmniRoute env from VS Code settings: $settings"
}

build_claude_config() {
  choose_claude_model
  local token="${CLIENT_KEY:-$MASTER_KEY}"
  [ -n "$token" ] || die "No Claude credential available."
  write_claude_settings "$CLAUDE_CODE_DIR/settings.json"
  CLAUDE_SETTINGS_PATH="$CLAUDE_CODE_DIR/settings.json"
  # Also the WSL home, unless that is already the same directory.
  if [ "$CLAUDE_WSL_DIR" != "$CLAUDE_CODE_DIR" ]; then
    write_claude_settings "$CLAUDE_WSL_DIR/settings.json"
  fi
  write_desktop_profile "$CLAUDE_DESKTOP_DIR"
  write_vscode_claude_env || true
  # MSIX / Store install uses a different Roaming root when that package exists.
  local msix
  if [ -n "${CLAUDE_DESKTOP_DIR:-}" ]; then
    local parent
    parent="$(dirname "$(dirname "$CLAUDE_DESKTOP_DIR")")"
    for msix in "$parent"/Packages/Claude_*/LocalCache/Roaming/Claude-3p; do
      [ -d "$(dirname "$msix")" ] || continue
      [ -d "$msix" ] || mkdir -p "$msix" 2>/dev/null || continue
      write_desktop_profile "$msix"
    done
  fi
}

strip_claude_settings() {
  local config_path="$1"
  [ -f "$config_path" ] || return 0
  if ! jq -e . "$config_path" >/dev/null 2>&1; then
    return 0
  fi
  if ! jq -e '.omnirouteManaged == true' "$config_path" >/dev/null 2>&1; then
    log "Leaving unmanaged Claude settings in place: $config_path"
    return 0
  fi
  local tmp others
  tmp="$(make_tmp)"
  jq '
      del(.env.ANTHROPIC_BASE_URL, .env.ANTHROPIC_AUTH_TOKEN, .env.ANTHROPIC_MODEL,
          .env.ANTHROPIC_DEFAULT_OPUS_MODEL, .env.ANTHROPIC_DEFAULT_SONNET_MODEL,
          .env.ANTHROPIC_DEFAULT_HAIKU_MODEL, .env.ANTHROPIC_SMALL_FAST_MODEL,
          .env.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY,
          .env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC,
          .env.CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING,
          .env.CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS,
          .env.CLAUDE_CODE_SKIP_FAST_MODE_NETWORK_ERRORS,
          .env.CLAUDE_CODE_ATTRIBUTION_HEADER,
          .env.CLAUDE_CODE_AUTO_COMPACT_WINDOW,
          .omnirouteManaged, .hasCompletedOnboarding, .model)
      | if (.env | length) == 0 then del(.env) else . end
    ' "$config_path" >"$tmp"
  others="$(jq 'keys | map(select(. != "$schema")) | length' "$tmp")"
  if [ "$others" = "0" ]; then
    rm -f "$config_path"
    log "Removed Claude Code settings: $config_path"
  else
    mv "$tmp" "$config_path"
    log "Stripped OmniRoute keys from $config_path (other settings kept)."
  fi
}

remove_claude_config() {
  detect_claude_dirs || true
  strip_claude_settings "${CLAUDE_CODE_DIR:-}/settings.json"
  strip_claude_settings "${CLAUDE_WSL_DIR:-$HOME/.claude}/settings.json"
  local root
  for root in "${CLAUDE_DESKTOP_DIR:-}"; do
    [ -n "$root" ] || continue
    rm -f "$root/configLibrary/${DESKTOP_PROFILE_ID}.json"
    if [ -f "$root/configLibrary/_meta.json" ] && jq -e . "$root/configLibrary/_meta.json" >/dev/null 2>&1; then
      local tmp
      tmp="$(make_tmp)"
      jq --arg id "$DESKTOP_PROFILE_ID" '
          .entries = ((.entries // []) | map(select(.id != $id)))
          | if .appliedId == $id then .appliedId = (.entries[0].id // null) else . end
        ' "$root/configLibrary/_meta.json" >"$tmp" && mv "$tmp" "$root/configLibrary/_meta.json"
    fi
    if [ -f "$root/claude_desktop_config.json" ] && jq -e '.omnirouteManaged == true' "$root/claude_desktop_config.json" >/dev/null 2>&1; then
      local tmp2 others
      tmp2="$(make_tmp)"
      jq 'del(.deploymentMode, .omnirouteManaged)' "$root/claude_desktop_config.json" >"$tmp2"
      others="$(jq 'keys | length' "$tmp2")"
      if [ "$others" = "0" ]; then
        rm -f "$root/claude_desktop_config.json"
      else
        mv "$tmp2" "$root/claude_desktop_config.json"
      fi
    fi
    log "Removed Claude Desktop OmniRoute profile under $root"
  done
  rm -f "$CLIENT_KEY_FILE"
  strip_vscode_claude_env || true
}

# ---------------------------------------------------------------------------
# 12. Post-install verification (6 automated tests)
# ---------------------------------------------------------------------------
TEST_RESULTS=()
TEST_PASSED=0

report_test() {
  local n="$1" name="$2" ok="$3" detail="${4:-}"
  if [ "$ok" = "0" ]; then
    TEST_RESULTS+=("PASS  $n) $name")
    TEST_PASSED=$((TEST_PASSED + 1))
  else
    TEST_RESULTS+=("FAIL  $n) $name${detail:+ - $detail}")
  fi
  if [ "$ok" = "0" ]; then
    _log PASS "$name"
  else
    _log FAIL "$name${detail:+ - $detail}"
  fi
}

run_verification() {
  log "=== Post-install verification ==="

  # 1) Docker daemon running (or Node runtime in Node mode)
  if [ "$RUN_MODE" = "docker" ]; then
    if run_quiet DC info >/dev/null 2>&1; then
      report_test 1 "Docker daemon is running" 0
    else
      report_test 1 "Docker daemon is running" 1 "docker info failed"
    fi
  else
    if command -v node >/dev/null 2>&1 && command -v omniroute >/dev/null 2>&1; then
      report_test 1 "Node runtime + omniroute CLI available" 0
    else
      report_test 1 "Node runtime + omniroute CLI available" 1 "node or omniroute missing"
    fi
  fi

  # 2) Container/process up
  if [ "$RUN_MODE" = "docker" ]; then
    if DC ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
      report_test 2 "Container $CONTAINER_NAME is up" 0
    else
      report_test 2 "Container $CONTAINER_NAME is up" 1 "not in docker ps"
    fi
  else
    local pid=""
    [ -f "$NODE_MODE_PID_FILE" ] && pid="$(cat "$NODE_MODE_PID_FILE" 2>/dev/null || true)"
    if [ "${PM2_AVAILABLE:-1}" = "1" ] && command -v pm2 >/dev/null 2>&1; then
      pm2 jlist 2>/dev/null | jq -e '.[] | select(.name=="omniroute" and .pm2_env.status=="online")' >/dev/null 2>&1 \
        && report_test 2 "pm2 process omniroute is online" 0 \
        || report_test 2 "pm2 process omniroute is online" 1 "pm2 status"
    elif [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      report_test 2 "Node process (pid $pid) is running" 0
    else
      report_test 2 "Node process is running" 1 "pid not alive"
    fi
  fi

  # 3) Health endpoint (10 attempts x 3s as specified; service already waited
  #    on during startup, so this is a fast re-check)
  local ok=1 i
  for i in $(seq 1 10); do
    if curl -fsS --max-time 5 "$BASE_URL/healthz" >/dev/null 2>&1; then ok=0; break; fi
    sleep 3
  done
  report_test 3 "Health endpoint $BASE_URL/healthz responds" "$ok" "no 2xx after 10 attempts"

  # 4) Models endpoint returns JSON (authenticated with the master key)
  local models_body="" rc=0
  set +e
  models_body="$(curl -fsS --max-time 30 -H "Authorization: Bearer $MASTER_KEY" "$BASE_URL/v1/models")"
  rc=$?
  set -e
  if [ $rc -eq 0 ] && printf '%s' "$models_body" | jq -e '(.data? // .) | type == "array"' >/dev/null 2>&1; then
    local n
    n="$(printf '%s' "$models_body" | jq '(.data? // .) | length')"
    report_test 4 "/v1/models returns JSON" 0 "$n models"
  else
    report_test 4 "/v1/models returns JSON" 1 "rc=$rc (wrong key or service issue)"
  fi

  # 5) Anthropic Messages API - the call Claude Code actually makes.
  #    Success body starts with {"id":"msg_ . Credential is the api-manager
  #    key (Bearer), not a second ANTHROPIC_API_KEY.
  local test_model token rc2=0 body2="" body_file
  test_model="${CLAUDE_MODEL:-}"
  if [ -z "$test_model" ] && [ -n "${CLAUDE_SETTINGS_PATH:-}" ] && [ -f "$CLAUDE_SETTINGS_PATH" ]; then
    test_model="$(jq -r '.env.ANTHROPIC_MODEL // .model // empty' "$CLAUDE_SETTINGS_PATH" 2>/dev/null || true)"
  fi
  [ -n "$test_model" ] || test_model="${PREFERRED_MODELS[0]}"
  token="${CLIENT_KEY:-$MASTER_KEY}"
  body_file="$(make_tmp)"
  jq -n --arg model "$test_model" \
    '{model:$model, max_tokens:32, messages:[{role:"user", content:"Hello"}]}' >"$body_file"
  set +e
  body2="$(curl -fsS --max-time 90 \
    -H "Authorization: Bearer $token" \
    -H 'anthropic-version: 2023-06-01' \
    -H 'Content-Type: application/json' \
    -X POST "$BASE_URL/v1/messages" \
    --data-binary @"$body_file")"
  rc2=$?
  set -e
  if [ $rc2 -eq 0 ] && printf '%s' "$body2" | jq -e '.id | startswith("msg_")' >/dev/null 2>&1; then
    report_test 5 "POST /v1/messages via $test_model" 0
  else
    report_test 5 "POST /v1/messages via $test_model" 1 "rc=$rc2 ${body2:0:200}"
  fi

  # 6) Claude Code settings (gateway root, bearer token, discovery) and the
  #    Desktop 3P profile. Folded into one check so the summary stays 6/6.
  local settings_ok=1 desktop_ok=1
  if [ -n "${CLAUDE_SETTINGS_PATH:-}" ] && [ -f "$CLAUDE_SETTINGS_PATH" ] \
     && jq -e --arg base "$BASE_URL" '
          .env.ANTHROPIC_BASE_URL == $base
          and (.env.ANTHROPIC_BASE_URL | test("/v1$") | not)
          and (.env.ANTHROPIC_AUTH_TOKEN | type == "string" and length > 0)
          and (.env | has("ANTHROPIC_API_KEY") | not)
          and .env.CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY == "1"
          and .env.CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC == "1"
          and .env.CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING == "1"
          and .env.CLAUDE_CODE_ATTRIBUTION_HEADER == "0"
        ' "$CLAUDE_SETTINGS_PATH" >/dev/null 2>&1; then
    settings_ok=0
  fi
  if [ -z "${CLAUDE_DESKTOP_DIR:-}" ]; then
    desktop_ok=0
  elif [ -n "${CLAUDE_DESKTOP_PROFILE:-}" ] && [ -f "$CLAUDE_DESKTOP_PROFILE" ] \
     && jq -e --arg base "$BASE_URL" '
          .inferenceProvider == "gateway"
          and .inferenceGatewayAuthScheme == "bearer"
          and .inferenceCredentialKind == "static"
          and .inferenceGatewayBaseUrl == $base
          and (.inferenceGatewayBaseUrl | test("/v1$") | not)
          and (.inferenceGatewayApiKey | type == "string" and length > 0)
        ' "$CLAUDE_DESKTOP_PROFILE" >/dev/null 2>&1; then
    desktop_ok=0
  fi
  if [ "$settings_ok" -eq 0 ] && [ "$desktop_ok" -eq 0 ]; then
    report_test 6 "Claude Code settings + Desktop 3P profile" 0
  else
    report_test 6 "Claude Code settings + Desktop 3P profile" 1 "settings_ok=$settings_ok desktop_ok=$desktop_ok"
  fi

  log "Verification: $TEST_PASSED/6 tests passed."
}

# ---------------------------------------------------------------------------
# 13. Final banner
# ---------------------------------------------------------------------------
provider_key_set() {
  case "$1" in
    groq) [ -n "${KEY_GROQ:-}" ] ;;
    openrouter) [ -n "${KEY_OPENROUTER:-}" ] ;;
    gemini) [ -n "${KEY_GEMINI:-}" ] ;;
    cerebras) [ -n "${KEY_CEREBRAS:-}" ] ;;
    mistral) [ -n "${KEY_MISTRAL:-}" ] ;;
  esac
}

provider_status_line() {
  local out="" p var state
  for p in groq openrouter gemini cerebras mistral; do
    var="PROVIDER_STATUS_$(printf '%s' "$p" | tr '[:lower:]' '[:upper:]')"
    state="${!var:-}"
    if [ -z "$state" ] || [ "$state" = "-" ]; then
      if provider_key_set "$p"; then state="PENDING"; else state="-"; fi
    fi
    out+="$p=$state | "
  done
  echo "${out% | }"
}

print_success_banner() {
  local status_line headline note=""
  status_line="$(provider_status_line)"
  headline="[OK] Installation Successful"
  local health_failed=0
  local line
  for line in "${TEST_RESULTS[@]:-}"; do
    case "$line" in
      "FAIL  3)"*) health_failed=1 ;;
    esac
  done
  if [ "$health_failed" -eq 1 ]; then
    headline="[FAIL] Service did not become healthy"
    note="  The gateway did not answer /healthz. See the log before using Claude."
  elif [ "${HEALTHY_PROVIDERS:-0}" -eq 0 ]; then
    headline="[WARN] Service is up, but no provider probe returned OK"
    note="  No upstream returned OK. A key may be bad, or the provider network is"
    note+=$'\n'"  blocked (common in Iran: HTTP 403 is UNREACHABLE, not a bad key)."
    note+=$'\n'"  Set OMNIRoute_PROXY_URL=http://host:port or socks5://host:port and"
    note+=$'\n'"  re-run, or: omni proxy on. Applied with PUT /api/settings/proxy."
    note+=$'\n'"  Per-provider: OMNIRoute_PROXY_GROQ _OPENROUTER _GEMINI _CEREBRAS _MISTRAL."
    note+=$'\n'"  Dashboard fallback: Settings -> Proxy. Install still exits 0."
  elif [ "${UNREACHABLE_PROVIDERS:-0}" -gt 0 ]; then
    headline="[WARN] Installation finished with unreachable providers"
    note="  Some providers are UNREACHABLE (often a geo-block, not a bad key)."
    note+=$'\n'"  OMNIRoute_PROXY_URL=http://host:port or socks5://host:port is applied"
    note+=$'\n'"  via PUT /api/settings/proxy. omni proxy off clears it. Overrides use the same"
    note+=$'\n'"  URL shape: OMNIRoute_PROXY_GROQ and the matching suffix for the others."
  fi
  local svc_cmds="docker logs -f $CONTAINER_NAME"
  local svc_cmd2="docker restart $CONTAINER_NAME"
  [ "$RUN_MODE" = "node" ] && { svc_cmds="pm2 logs omniroute"; svc_cmd2="pm2 restart omniroute"; }

  local rerun_line
  if [ -n "${MANAGER_LOCAL:-}" ]; then
    rerun_line="bash \"${MANAGER_LOCAL}\"  # Re-run manager (this file)"
  else
    rerun_line="curl -fsSL ${MANAGER_URL_DEFAULT} -o OmniRoute.sh && bash OmniRoute.sh  # re-download + run"
  fi

  cat <<EOF
============================================================
  ${headline}
============================================================
  Service URL:  ${BASE_URL}   (gateway root - Claude appends /v1/messages)
  Dashboard:    ${BASE_URL}   (password: ${INITIAL_PASSWORD_SET})
  API Key:      ${MASTER_KEY}
  Claude token: ${CLIENT_KEY_FILE:-not written}   (api-manager key, not printed)
  OmniRoute:    ${SERVICE_VERSION:-unknown}  (image pin ${IMAGE_TAG_PIN})
  Claude Code:  ${CLAUDE_SETTINGS_PATH:-not written}
  Desktop 3P:   ${CLAUDE_DESKTOP_PROFILE:-not written}
  Log File:     ${LOG_FILE}

  Available Models: ${MODEL_COUNT:-0}
  Provider Status:  ${status_line}
  Proxy:            $([ "${PROXY_ENABLED:-0}" = "1" ] && printf '%s' "${RESOLVED_PROXY_URL}" || printf '%s' "off (omni proxy on|off)")

  Next Steps:
  1. Quit and restart Claude Code, and fully quit Claude Desktop
  2. Claude Code reads %USERPROFILE%\\.claude\\settings.json (env wins over the shell)
  3. Claude Desktop does not read that file. If the 3P profile was not
     picked up: Help -> Troubleshooting -> Enable Developer Mode, then
     Developer -> Configure Third-Party Inference
     (gateway, bearer, base ${BASE_URL} with no /v1, HTTP loopback only)
  4. VS Code: claudeCode.environmentVariables in user settings. The
     extension does not treat ~/.claude/settings.json as a login.
  5. Pick the pinned model (${CLAUDE_MODEL:-auto}) and start coding

${note}
  Quick Commands (installed as 'omni'):
    omni status    # state + health
    omni up        # start the service
    omni down      # stop the service
    omni restart   # restart the service
    omni logs      # last 50 log lines (omni logs f = follow)
    omni proxy on|off|status
    omni uninstall # full removal

  Useful Commands:
    ${svc_cmds}     # View logs
    ${svc_cmd2}     # Restart service
    ${rerun_line}

  Notes:
  - Windows apps reach this WSL2 gateway at ${BASE_URL} via localhost
    forwarding. Do not point Claude at a WSL eth0 address.
  - Provider rows marked BAD-KEY or UNREACHABLE can be fixed in the
    dashboard (Settings -> Providers) or by re-running with a proxy.
  - Restart Claude after every settings write. Env is read once at startup.
============================================================
EOF
}

# ---------------------------------------------------------------------------
# 13b. Quick management (omni up / down / restart / status / logs)
# ---------------------------------------------------------------------------
manage_service() {
  local op="$1" logs_arg="${2:-}"
  log "########## OmniRoute manage: $op (manager v${SCRIPT_VERSION}) ##########"
  detect_environment
  resolve_sudo

  # Detect the managed runtime: mode marker first, then live detection.
  local mode_file="$DATA_DIR/mode" mode=""
  if [ -f "$mode_file" ]; then
    mode="$(tr -d '[:space:]' <"$mode_file" 2>/dev/null || true)"
  fi
  if [ -z "$mode" ] && command -v docker >/dev/null 2>&1; then
    if DC ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
      mode="docker"
    fi
  fi
  if [ -z "$mode" ] && [ -f "$HOME/omniroute-run.sh" ]; then
    mode="node"
  fi
  [ -n "$mode" ] || die "No OmniRoute installation found (marker $mode_file missing). Run the install first."
  log "Detected mode: $mode"

  local container_up=0
  if [ "$mode" = "docker" ]; then
    if DC ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
      container_up=1
    fi
  fi

  case "$mode:$op" in
    docker:up)
      if [ "$container_up" = "1" ]; then
        log "Container $CONTAINER_NAME is already up."
      else
        DC start "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || die "docker start failed (see $LOG_FILE)."
        log "Container $CONTAINER_NAME started."
      fi
      ;;
    docker:down)
      DC stop "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || warn "Container was not running."
      log "Container stopped (image kept; 'omni up' starts it again)."
      ;;
    docker:restart)
      DC restart "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || die "docker restart failed (see $LOG_FILE)."
      log "Container restarted."
      ;;
    docker:status)
      echo "OmniRoute mode:   docker (container $CONTAINER_NAME: $([ "$container_up" = "1" ] && echo running || echo stopped))"
      echo "Service URL:      $BASE_URL/v1"
      if curl -fsS --max-time 5 "$BASE_URL/healthz" >/dev/null 2>&1; then
        echo "Health:           OK"
      else
        echo "Health:           NOT reachable at $BASE_URL/healthz"
      fi
      ;;
    docker:logs)
      if [ "$logs_arg" = "f" ] || [ "$logs_arg" = "--follow" ]; then
        exec DC logs -f "$CONTAINER_NAME"
      fi
      DC logs --tail "${logs_arg:-50}" "$CONTAINER_NAME" 2>&1 | tail -n "${logs_arg:-50}"
      ;;
    node:up)
      if command -v pm2 >/dev/null 2>&1; then
        if pm2 jlist 2>/dev/null | jq -e '.[] | select(.name=="omniroute" and .pm2_env.status=="online")' >/dev/null 2>&1; then
          log "omniroute is already online in pm2."
        else
          pm2 start omniroute >>"$LOG_FILE" 2>&1 \
            || pm2 start "$HOME/omniroute-run.sh" --name omniroute --interpreter bash --time >>"$LOG_FILE" 2>&1 \
            || die "pm2 start failed (see $LOG_FILE)."
          log "omniroute started via pm2."
        fi
      else
        nohup "$HOME/omniroute-run.sh" >>"$DATA_DIR/omniroute-node.log" 2>&1 &
        echo $! >"$NODE_MODE_PID_FILE"
        log "omniroute started via nohup (pid $(cat "$NODE_MODE_PID_FILE"))."
      fi
      ;;
    node:down)
      if command -v pm2 >/dev/null 2>&1; then
        pm2 stop omniroute >>"$LOG_FILE" 2>&1 || true
      fi
      if [ -f "$NODE_MODE_PID_FILE" ]; then
        kill "$(cat "$NODE_MODE_PID_FILE" 2>/dev/null)" 2>/dev/null || true
      fi
      log "omniroute stopped."
      ;;
    node:restart)
      if command -v pm2 >/dev/null 2>&1; then
        pm2 restart omniroute >>"$LOG_FILE" 2>&1 || die "pm2 restart failed (see $LOG_FILE)."
        log "omniroute restarted via pm2."
      else
        manage_service "down"
        manage_service "up"
      fi
      ;;
    node:status)
      local st="stopped"
      if command -v pm2 >/dev/null 2>&1 && \
         pm2 jlist 2>/dev/null | jq -e '.[] | select(.name=="omniroute" and .pm2_env.status=="online")' >/dev/null 2>&1; then
        st="online (pm2)"
      fi
      echo "OmniRoute mode:   node ($st)"
      echo "Service URL:      $BASE_URL/v1"
      if curl -fsS --max-time 5 "$BASE_URL/healthz" >/dev/null 2>&1; then
        echo "Health:           OK"
      else
        echo "Health:           NOT reachable at $BASE_URL/healthz"
      fi
      ;;
    node:logs)
      if command -v pm2 >/dev/null 2>&1; then
        if [ "$logs_arg" = "f" ] || [ "$logs_arg" = "--follow" ]; then
          exec pm2 logs omniroute
        fi
        pm2 logs omniroute --nostream --lines "${logs_arg:-50}" 2>/dev/null \
          || tail -n "${logs_arg:-50}" "$DATA_DIR/omniroute-node.log"
      else
        tail -n "${logs_arg:-50}" "$DATA_DIR/omniroute-node.log"
      fi
      ;;
    *)
      die "Unknown manage operation: $op"
      ;;
  esac
  log "########## OmniRoute manage: $op finished ##########"
}

# ---------------------------------------------------------------------------
# 13c. Boot autostart (systemd)
# ---------------------------------------------------------------------------
configure_autostart() {
  if ! systemd_active; then
    warn "systemd is not active - skipping boot autostart."
    warn "The service will not start when WSL reboots. Enable systemd in"
    warn "/etc/wsl.conf ([boot] systemd=true) and re-run the install."
    return 0
  fi
  if [ "$RUN_MODE" = "docker" ]; then
    # Containers run with --restart unless-stopped; enabling the docker
    # service brings the daemon (and thus the container) up on WSL boot.
    if $SUDO systemctl enable docker >>"$LOG_FILE" 2>&1; then
      log "Docker service enabled at boot (container auto-starts with it)."
    else
      warn "Could not enable docker.service - start Docker manually after WSL reboot."
    fi
  else
    local unit_dir="$HOME/.config/systemd/user"
    local unit_file="$unit_dir/omniroute.service"
    mkdir -p "$unit_dir"
    cat >"$unit_file" <<UNIT
[Unit]
Description=OmniRoute (Node mode)
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=%h/omniroute-run.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT
    if systemctl --user daemon-reload >>"$LOG_FILE" 2>&1 \
       && systemctl --user enable omniroute.service >>"$LOG_FILE" 2>&1; then
      log "systemd user unit 'omniroute' enabled (Node-mode boot autostart)."
      if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
        if $SUDO loginctl enable-linger "$USER" >>"$LOG_FILE" 2>&1; then
          log "Login linger enabled - the unit starts at boot without a login."
        else
          warn "Run once for boot autostart: sudo loginctl enable-linger $USER"
        fi
      fi
    else
      warn "Could not enable the systemd user unit. Start manually: bash $HOME/omniroute-run.sh"
    fi
  fi
}

remove_autostart() {
  local unit_file="$HOME/.config/systemd/user/omniroute.service"
  if [ -f "$unit_file" ]; then
    systemctl --user disable omniroute.service >/dev/null 2>&1 || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    rm -f "$unit_file"
    log "Removed systemd user unit: omniroute.service"
  fi
  # docker.service stays enabled (it is a system service, not ours).
}

# ---------------------------------------------------------------------------
# 13d. Quick management command (omni)
# ---------------------------------------------------------------------------
OMNI_CMD_PATH=""
install_omni_shim() {
  local target="/usr/local/bin/omni"
  local tmp
  tmp="$(make_tmp)"
  if [ -n "${MANAGER_LOCAL:-}" ]; then
    cat >"$tmp" <<SHIM
#!/usr/bin/env bash
# OmniRoute quick management (generated by OmniRoute.sh v${SCRIPT_VERSION}).
MANAGER="${MANAGER_LOCAL}"
cmd="\${1:-status}"
[ "\$#" -gt 0 ] && shift
case "\$cmd" in
  up|start)       exec bash "\$MANAGER" --up "\$@" ;;
  down|stop)      exec bash "\$MANAGER" --down "\$@" ;;
  restart)        exec bash "\$MANAGER" --restart "\$@" ;;
  status)         exec bash "\$MANAGER" --status "\$@" ;;
  logs)           exec bash "\$MANAGER" --logs "\$@" ;;
  install)        exec bash "\$MANAGER" --install "\$@" ;;
  uninstall)      exec bash "\$MANAGER" --uninstall "\$@" ;;
  proxy)          exec bash "\$MANAGER" --proxy "\$@" ;;
  help|--help|-h) echo "Usage: omni {up|down|restart|status|logs [N|f]|proxy on|off|status|install|uninstall}" ;;
  *) echo "Unknown command: \$cmd (try: omni help)" >&2; exit 2 ;;
esac
SHIM
  else
    cat >"$tmp" <<SHIM
#!/usr/bin/env bash
echo "The OmniRoute manager has no local copy (piped install, re-download failed)."
echo "Keep a copy, then re-run the install:"
echo "  curl -fsSL ${MANAGER_URL_DEFAULT} -o OmniRoute.sh && bash OmniRoute.sh --install"
echo "  (or: git clone --depth 1 https://github.com/im-JvD/OmniRoute-OpenCode && bash OmniRoute-OpenCode/OmniRoute.sh --install)"
exit 3
SHIM
  fi
  chmod 755 "$tmp"
  if [ "$(id -u)" -eq 0 ]; then
    mv "$tmp" "$target"
  elif $SUDO mv "$tmp" "$target" 2>/dev/null && $SUDO chmod 755 "$target" 2>/dev/null; then
    :
  else
    target="$HOME/.local/bin/omni"
    mkdir -p "$(dirname "$target")"
    mv "$tmp" "$target"
    warn "$target installed. Make sure ~/.local/bin is in your PATH, e.g.:"
    warn '  export PATH="$HOME/.local/bin:$PATH"'
  fi
  OMNI_CMD_PATH="$target"
  log "Quick management command installed: $target  (omni up | down | restart | status | logs | uninstall)"
}

remove_omni_shim() {
  local p
  for p in /usr/local/bin/omni "$HOME/.local/bin/omni"; do
    if [ -e "$p" ] || [ -L "$p" ]; then
      if $SUDO rm -f "$p" 2>/dev/null || rm -f "$p" 2>/dev/null; then
        log "Removed quick command: $p"
      fi
    fi
  done
  if [ -f "$MANAGER_SELF_DIR/OmniRoute.sh" ]; then
    rm -f "$MANAGER_SELF_DIR/OmniRoute.sh" 2>/dev/null || true
    rmdir "$MANAGER_SELF_DIR" 2>/dev/null || true
    log "Removed saved manager copy: $MANAGER_SELF_DIR/OmniRoute.sh"
  fi
}

# ---------------------------------------------------------------------------
# 14. Install orchestrator
# ---------------------------------------------------------------------------
do_install() {
  log "########## OmniRoute install started (manager v${SCRIPT_VERSION}) ##########"
  detect_environment
  require_tools
  resolve_manager_path
  ensure_swap
  collect_keys
  acquire_runtime
  resolve_proxy_choice
  generate_master_key
  write_env_file
  if [ "$RUN_MODE" = "docker" ]; then
    start_container
  else
    start_node_process
  fi
  wait_for_health
  register_provider_keys
  detect_claude_dirs
  # Advisory: a missing catalog pins a built-in model id. The function
  # returns 1 in that case; do not let set -e abort a healthy gateway.
  fetch_catalog || true
  build_claude_config
  run_verification
  configure_autostart
  install_omni_shim
  print_success_banner
  log "########## OmniRoute install finished ##########"
}

# ---------------------------------------------------------------------------
# 15. Uninstall
# ---------------------------------------------------------------------------
confirm_uninstall() {
  if [ "$ASSUME_YES" -eq 1 ]; then
    log "Uninstall confirmed via --yes."
    return 0
  fi
  if is_tty; then
    prompt_yes_no "This removes the OmniRoute container, image, source, data and the" \
      "managed Claude Code / Desktop gateway settings. Continue?" "n" || die "Aborted by user."
    return 0
  fi
  die "Non-interactive uninstall requires --yes (and optionally --remove-docker). Aborted."
}

do_uninstall() {
  log "########## OmniRoute uninstall started ##########"
  _log_init
  confirm_uninstall
  resolve_sudo

  # 1) Stop + remove container (Docker mode).
  if command -v docker >/dev/null 2>&1; then
    if DC ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER_NAME"; then
      log "Stopping container $CONTAINER_NAME."
      DC stop "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
      DC rm "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || true
      log "Container removed."
    else
      log "Container $CONTAINER_NAME not present."
    fi
    # 2) Remove image(s) created/kept by this manager (local tag + any
    #    pre-built references still in the store).
    local img
    local img_refs=("${IMAGE_NAME}:latest" "${PREBUILT_REF:-}" \
      "${IMAGE_GHCR}:${IMAGE_TAG}" "${IMAGE_HUB}:${IMAGE_TAG}" \
      "${IMAGE_GHCR}:${IMAGE_TAG_PIN}" "${IMAGE_HUB}:${IMAGE_TAG_PIN}")
    for img in "${img_refs[@]}"; do
      [ -n "$img" ] || continue
      if DC images -q "$img" 2>/dev/null | grep -q .; then
        log "Removing image $img."
        DC rmi "$img" >>"$LOG_FILE" 2>&1 || warn "Could not remove image $img (in use?)"
      fi
    done
  else
    log "Docker CLI not present - nothing to remove."
  fi

  # 3) Node mode: kill pm2 process / pidfile process.
  if command -v pm2 >/dev/null 2>&1; then
    if pm2 jlist 2>/dev/null | jq -e '.[] | select(.name=="omniroute")' >/dev/null 2>&1; then
      log "Deleting pm2 process 'omniroute'."
      pm2 delete omniroute >>"$LOG_FILE" 2>&1 || true
      pm2 save >>"$LOG_FILE" 2>&1 || true
    fi
  fi
  if [ -f "$NODE_MODE_PID_FILE" ]; then
    local pid
    pid="$(cat "$NODE_MODE_PID_FILE" 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$NODE_MODE_PID_FILE"
    log "Node-mode process stopped."
  fi
  if [ -f "$HOME/omniroute-run.sh" ]; then
    rm -f "$HOME/omniroute-run.sh"
    log "Removed Node-mode launcher: $HOME/omniroute-run.sh"
  fi
  # 3b) Autostart + quick command.
  remove_autostart
  remove_omni_shim

  # 4) Source + data + secrets.
  log "Removing source: $SRC_DIR"
  rm -rf "$SRC_DIR" 2>/dev/null || true
  log "Removing data: $DATA_DIR"
  rm -rf "$DATA_DIR" 2>/dev/null || true
  log "Removing key stores: $KEYS_FILE, $MASTER_KEY_FILE"
  rm -f "$KEYS_FILE" "$MASTER_KEY_FILE" 2>/dev/null || true

  # 5) Claude Code settings + the Desktop profile this installer owns.
  #    Unrelated keys and other 3P profile ids are left in place.
  if [ "$ASSUME_YES" -eq 1 ] || is_tty; then
    remove_claude_config || warn "Could not fully remove Claude gateway settings."
  else
    warn "Non-interactive uninstall without --yes: leaving Claude settings in place."
  fi

  # 6) Optional: remove Docker itself.
  if [ "$REMOVE_DOCKER" -eq 1 ]; then
    if command -v docker >/dev/null 2>&1; then
      warn "Removing Docker (docker.io) as requested via --remove-docker."
      $SUDO systemctl stop docker 2>/dev/null || service docker stop 2>/dev/null || true
      DEBIAN_FRONTEND=noninteractive run_logged $SUDO apt-get remove -y docker.io 2>/dev/null ||
      DEBIAN_FRONTEND=noninteractive run_logged $SUDO apt-get remove -y docker.io containerd runc
      $SUDO rm -rf /var/lib/docker /etc/docker 2>/dev/null || true
      log "Docker removed."
    fi
  fi

  log "Uninstall complete. Log: $LOG_FILE"
  log "########## OmniRoute uninstall finished ##########"
}

# ---------------------------------------------------------------------------
# 15b. Proxy on / off / status (after install)
# ---------------------------------------------------------------------------
do_proxy() {
  local action="${PROXY_ACTION:-status}"
  log "########## OmniRoute proxy: $action ##########"
  detect_environment
  ENV_FILE="$DATA_DIR/.env"
  [ -f "$ENV_FILE" ] || die "No OmniRoute install found at $DATA_DIR. Run --install first."
  if [ -f "$DATA_DIR/mode" ]; then
    RUN_MODE="$(tr -d '[:space:]' <"$DATA_DIR/mode")"
  else
    RUN_MODE="docker"
  fi
  case "$action" in
    status)
      if [ -f "$DATA_DIR/proxy.choice" ]; then
        # shellcheck disable=SC1090
        . "$DATA_DIR/proxy.choice"
      fi
      if [ "${PROXY_CHOICE:-0}" = "1" ]; then
        echo "Proxy: ON  ${RESOLVED_PROXY_URL:-unknown}"
      else
        echo "Proxy: OFF (direct)"
      fi
      echo "Change it with: omni proxy on    or    omni proxy off"
      return 0
      ;;
    on) OMNIRoute_USE_PROXY=1 ;;
    off)
      OMNIRoute_USE_PROXY=0
      OMNIRoute_PROXY_URL=""
      ;;
    *) die "Usage: omni proxy on|off|status" ;;
  esac
  resolve_proxy_choice
  patch_env_proxy_lines
  if [ "$RUN_MODE" = "docker" ]; then
    start_container
  fi
  wait_for_health
  INITIAL_PASSWORD_SET="$(grep -E '^INITIAL_PASSWORD=' "$ENV_FILE" | cut -d= -f2- || true)"
  if dashboard_login; then
    apply_outbound_proxy || true
  else
    warn "Proxy choice was saved, but the dashboard API could not be updated."
  fi
  if [ "${PROXY_ENABLED:-0}" = "1" ]; then
    echo "Proxy: ON  $RESOLVED_PROXY_URL"
  else
    echo "Proxy: OFF (direct)"
  fi
}

# ---------------------------------------------------------------------------
# 16. Menu + entry point
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
OmniRoute + Claude manager (v2.1.0)

Usage:
  bash OmniRoute.sh               interactive menu (TTY required)
  bash OmniRoute.sh --install     run the full install
  bash OmniRoute.sh --uninstall   run the full uninstall
      --yes                               assume confirmation for uninstall
      --remove-docker                     also remove Docker itself (uninstall)
  bash OmniRoute.sh --up|--down|--restart|--status|--logs [N|f]
                                      quick management (also: omni up|...)
  bash OmniRoute.sh --proxy on|off|status
                                      enable, disable, or show the outbound proxy
      --help                              this text

Environment overrides: OMNIRoute_PORT, OMNIRoute_API_PORT, OMNIRoute_BIND_HOST,
  OMNIRoute_SRC_DIR, OMNIRoute_DATA_DIR, OMNIRoute_LOG, OMNIRoute_CONTAINER,
  OMNIRoute_IMAGE_TAG, OMNIRoute_IMAGE_TAG_PIN, OMNIRoute_NPM_REGISTRY,
  OMNIRoute_CLAUDE_DIR, OMNIRoute_PROXY_URL, OMNIRoute_USE_PROXY,
  OMNIRoute_SKIP_DIRECT_PROBE,
  OMNIRoute_GROQ_KEY, OMNIRoute_OPENROUTER_KEY,
  OMNIRoute_GEMINI_KEY, OMNIRoute_CEREBRAS_KEY, OMNIRoute_MISTRAL_KEY,
  OMNIRoute_ASSUME_DEPS, OMNIRoute_SKIP_SWAP, OMNIRoute_NO_DOCKER_BUILD.
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --install) MODE="install" ;;
      --uninstall) MODE="uninstall" ;;
      --up|--start) MODE="up" ;;
      --down|--stop) MODE="down" ;;
      --restart) MODE="restart" ;;
      --status) MODE="status" ;;
      --logs)
        MODE="logs"
        if [ -n "${2:-}" ] && [ "${2:0:1}" != "-" ]; then
          LOGS_OPT="$2"
          shift
        fi
        ;;
      --yes|-y) ASSUME_YES=1 ;;
      --remove-docker) REMOVE_DOCKER=1 ;;
      --proxy)
        MODE="proxy"
        PROXY_ACTION="${2:-status}"
        case "$PROXY_ACTION" in
          on|off|status) shift ;;
          *) die "Usage: --proxy on|off|status" ;;
        esac
        ;;
      --help|-h) usage; exit 0 ;;
      *) die "Unknown argument: $1 (see --help)" ;;
    esac
    shift
  done
}

main_menu() {
  cat <<EOF
============================================================
  OmniRoute + Claude Manager (v${SCRIPT_VERSION})
============================================================
  1) Full Install
  2) Full Uninstall
============================================================
EOF
  local choice
  prompt_line "Choose an option" "" ""
  choice="$REPLY_LINE"
  case "$choice" in
    1) MODE="install" ;;
    2) MODE="uninstall" ;;
    *) die "No option selected - exiting." ;;
  esac
}

main() {
  _log_init
  SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
  parse_args "$@"
  if [ -z "$MODE" ]; then
    if is_tty; then
      main_menu
    else
      err "No action selected. Non-TTY sessions must pass --install or --uninstall."
      usage
      exit 2
    fi
  fi
  case "$MODE" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    proxy) do_proxy ;;
    up|down|restart|status|logs) manage_service "$MODE" "${LOGS_OPT:-}" ;;
  esac
}

main "$@"