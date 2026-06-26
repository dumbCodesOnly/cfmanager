#!/bin/bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║           CF-MANAGER v3.0 — Cloudflare CLI Dashboard            ║
# ║        Designed for Termux | github-sync | multi-account        ║
# ╚══════════════════════════════════════════════════════════════════╝
#
# Features: Workers · KV · D1 · R2 · Durable Objects · GitHub Sync
#           Rollback · Encrypted token storage · Multi-account
#
# Install deps (Termux):
#   pkg install curl jq openssl git nano
#
# Usage: bash cf-manager.sh

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CONSTANTS & CONFIG
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
VERSION="3.0.0"
CF_API="https://api.cloudflare.com/client/v4"
CONFIG_DIR="$HOME/script/cfmanager/.cfmanager"
ACCOUNTS_ENC="$CONFIG_DIR/accounts.enc"
MASTER_HASH="$CONFIG_DIR/.mhash"
SALT_FILE="$CONFIG_DIR/.salt"
SESSION_FILE="$CONFIG_DIR/.session"
CURRENT_ACCOUNT="$CONFIG_DIR/.current_account"
LOG_FILE="$CONFIG_DIR/cfmanager.log"
WORKERS_DIR="$CONFIG_DIR/workers"
REPOS_DIR="$CONFIG_DIR/repos"
BACKUPS_DIR="$CONFIG_DIR/backups"
DEPLOY_HOOKS="$CONFIG_DIR/hooks"
CFWORKER_DIR="$CONFIG_DIR/workers"
NA_LAST_SRC_FILE="$CONFIG_DIR/.na_last_src"
CACHE_DIR="$CONFIG_DIR/cache"
CACHE_TTL=60   # seconds before a cache entry is considered stale
# MASTER_HASH / SALT_FILE / SESSION_FILE are only referenced by
# maybe_migrate_legacy_vault() to detect and clean up an old
# master-password vault from previous versions.

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# COLORS & UI SYMBOLS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
R='\033[0;31m'    # Red
G='\033[0;32m'    # Green
Y='\033[1;33m'    # Yellow
B='\033[0;34m'    # Blue
C='\033[0;36m'    # Cyan
M='\033[0;35m'    # Magenta
W='\033[1;37m'    # White bold
O='\033[0;33m'    # Orange
DM='\033[2m'      # Dim
BLD='\033[1m'     # Bold
NC='\033[0m'      # Reset
BG_B='\033[44m'   # Blue background
BG_G='\033[42m'   # Green background

SYM_OK="${G}✓${NC}"
SYM_ERR="${R}✗${NC}"
SYM_WARN="${Y}⚠${NC}"
SYM_INFO="${C}ℹ${NC}"
SYM_ARR="${B}▶${NC}"
SYM_DOT="${W}•${NC}"
SYM_STAR="${Y}★${NC}"
SYM_GEAR="${C}⚙${NC}"
SYM_CLOUD="${B}☁${NC}"

# Runtime globals
CF_TOKEN=""
CF_ACCOUNT_ID=""
CF_ZONE_ID=""
ACTIVE_ACCOUNT_NAME=""

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# UTILITY FUNCTIONS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}

die() {
  echo -e "${R}${BLD}FATAL:${NC} $*" >&2
  log "FATAL: $*"
  exit 1
}

info()    { echo -e "${SYM_INFO} $*"; }
success() { echo -e "${SYM_OK} $*"; }
warn()    { echo -e "${SYM_WARN} $*"; }
error()   { echo -e "${SYM_ERR} ${R}$*${NC}"; log "ERROR: $*"; }

press_enter() {
  echo -e "\n${DM}Press Enter to continue...${NC}"
  read -r
}

# Generate a random worker name in Cloudflare dashboard style: adjective-noun-NNN
gen_worker_name() {
  local -a _ADJS=(
    aged ancient autumn billowing bitter black blue bold broken calm
    cold crimson damp dark dawn divine dry empty falling fancy
    flat floral fragrant frosty gentle hidden holy icy jolly late
    lingering little lively long lucky misty morning muddy mute
    nameless noisy odd old orange patient plain polished proud
    purple quiet rapid red restless rough rustic shrill silent
    small snowy solitary sparkling spring still summer sweet
    twilight wandering weathered white wild winter wispy young
  )
  local -a _NOUNS=(
    bird breeze brook bush butterfly cherry cloud dawn dew dream
    dust feather field fire firefly flower fog forest frog gale
    glitter grass haze hill lake leaf meadow moon morning mountain
    night paper pine pond rain resonance river sea shadow shape
    silence sky smoke snow snowflake sound star sun sunset surf
    thunder tree truth union violet voice water waterfall wave
    wildflower wind winter wood
  )
  local adj noun suffix
  adj="${_ADJS[$((RANDOM % ${#_ADJS[@]}))]}" 
  noun="${_NOUNS[$((RANDOM % ${#_NOUNS[@]}))]}" 
  suffix=$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c4)
  if [[ -z "$suffix" ]]; then
    local chars='abcdefghijklmnopqrstuvwxyz0123456789'
    suffix=""
    for _ in 1 2 3 4; do
      suffix+="${chars:$((RANDOM % ${#chars})):1}"
    done
  fi
  echo "${adj}-${noun}-${suffix}"
}

# Prompt for a worker name with a generated suggestion.
# Stores the result in the nameref variable.  Never returns empty.
#   prompt_worker_name result_var
prompt_worker_name() {
  local -n _pwn_result="$1"
  local random_name
  random_name=$(gen_worker_name)
  echo -e "${DM}Suggested name: ${C}${random_name}${NC}"
  echo -ne "${W}Worker name${NC} ${DM}[Enter for '${random_name}']:${NC} "
  read -r _pwn_result
  if [[ -z "$_pwn_result" ]]; then
    _pwn_result="$random_name"
  fi
  return 0
}

# Write the standard CF-Manager worker template to FILEPATH, substituting
# WORKER_NAME for the given name.  Used by create_worker and new_to_all.
#   write_worker_template filepath worker_name
write_worker_template() {
  local filepath="$1" worker_name="$2"
  cat > "$filepath" <<'WORKERTEMPLATE'
// CF-Manager generated worker
export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const { method } = request;

    // Router
    if (url.pathname === '/') {
      return new Response(JSON.stringify({
        status: 'ok',
        worker: 'WORKER_NAME',
        timestamp: new Date().toISOString(),
      }), {
        headers: { 'Content-Type': 'application/json' },
      });
    }

    return new Response('Not Found', { status: 404 });
  },
};
WORKERTEMPLATE
  sed -i "s/WORKER_NAME/${worker_name}/" "$filepath"
}

# Write the minimal fallback template used by edit_worker when the live
# source cannot be fetched.  Interpolates worker_name into the response text.
#   write_fallback_template filepath worker_name
write_fallback_template() {
  local filepath="$1" worker_name="$2"
  cat > "$filepath" <<WORKERTEMPLATE
// Could not fetch source for: ${worker_name}
// Edit this template and deploy to overwrite
export default {
  async fetch(request, env, ctx) {
    return new Response('Hello from ${worker_name}!', {
      headers: { 'Content-Type': 'text/plain' },
    });
  },
};
WORKERTEMPLATE
}

# Read JS code from stdin until a line containing only "EOF", write to FILEPATH.
# Prints the save path on success.
#   paste_code_to_file filepath
paste_code_to_file() {
  local filepath="$1"
  echo -e "${DM}Paste JS code. End with a line containing only EOF:${NC}"
  local _code=""
  while IFS= read -r _line; do
    [[ "$_line" == "EOF" ]] && break
    _code+="$_line"$'\n'
  done
  printf '%s' "$_code" > "$filepath"
}

# Pick a .js or .gs file from $CFWORKER_DIR interactively.
# Prints the chosen path to stdout; returns 1 on cancel/empty.

pick_cfworker_file() {
  if [[ ! -d "$CFWORKER_DIR" ]]; then
    warn "Directory not found: $CFWORKER_DIR" >&2
    warn "Create it or place .js/.gs files there first." >&2
    return 1
  fi
  local -a files
  mapfile -t files < <(find "$CFWORKER_DIR" -maxdepth 1 \( -name "*.js" -o -name "*.gs" \) -type f 2>/dev/null | sort)
  if [[ ${#files[@]} -eq 0 ]]; then
    warn "No .js or .gs files found in $CFWORKER_DIR" >&2
    return 1
  fi
  echo -e "${W}Files in ${C}${CFWORKER_DIR}${W}:${NC}\n" >&2
  for i in "${!files[@]}"; do
    local fname size
    fname=$(basename "${files[$i]}")
    size=$(wc -c < "${files[$i]}" 2>/dev/null || echo "?")
    printf "  ${C}%d${NC}. %-40s ${DM}%s bytes${NC}\n" "$((i+1))" "$fname" "$size" >&2
  done
  echo -ne "\n${W}Select file (0=cancel):${NC} " >&2
  local sel
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return 1
  local idx=$((sel-1))
  if [[ $idx -lt 0 || $idx -ge ${#files[@]} ]]; then
    error "Invalid selection." >&2
    return 1
  fi
  printf '%s' "${files[$idx]}"
}

confirm() {
  local msg="${1:-Are you sure?}"
  echo -ne "${Y}${msg} [y/N]:${NC} "
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || die "Required command not found: $cmd\n  Install with: pkg install $cmd"
  done
}

check_deps() {
  local missing=()
  for cmd in curl jq openssl git; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${R}Missing dependencies:${NC} ${missing[*]}"
    echo -e "${Y}Install with:${NC} pkg install ${missing[*]}"
    exit 1
  fi
}

divider() {
  local char="${1:-─}"
  local cols
  cols=$(tput cols 2>/dev/null || echo 60)
  printf "${DM}%${cols}s${NC}\n" | tr ' ' "$char"
}

header() {
  local title="$1"
  local cols
  cols=$(tput cols 2>/dev/null || echo 60)
  clear
  echo -e "${BLD}${C}"
  divider "═"
  printf "%*s\n" $(( (${#title} + cols) / 2 )) "$title"
  divider "═"
  echo -e "${NC}"
  if [[ -n "$ACTIVE_ACCOUNT_NAME" ]]; then
    echo -e "  ${SYM_CLOUD} Account: ${BLD}${G}${ACTIVE_ACCOUNT_NAME}${NC}  ${DM}| CF-Manager v${VERSION}${NC}"
    divider
    echo ""
  fi
}

spinner() {
  local pid=$1
  local msg="${2:-Working...}"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local i=0
  tput civis 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r${C}${frames[$i]}${NC} %s" "$msg"
    i=$(( (i+1) % ${#frames[@]} ))
    sleep 0.1
  done
  printf "\r%${#msg}s\r" " "
  tput cnorm 2>/dev/null || true
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SAFE ARITHMETIC HELPERS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# WHY THESE EXIST:
# The script runs under `set -e` (errexit).  The bash arithmetic
# compound command  (( expr ))  exits with status 1 whenever the
# expression evaluates to zero — which is the normal "falsy" result
# for a post-increment on a zero-valued counter:
#
#   local ok=0
#   ((ok++))   # post-increment returns OLD value (0) → exit 1 → script dies
#
# This silently kills the script after the first successful iteration
# of any batch loop.  The helpers below use the `var=$(( ))` expansion
# form, which is always a string assignment and never triggers errexit,
# making them safe to call in any context.
#
# Usage:
#   inc var_name          # var_name += 1
#   dec var_name          # var_name -= 1  (never goes below 0)

inc() {
  # Increment a named variable by 1, safe under set -e.
  local -n _inc_ref="$1"
  _inc_ref=$(( _inc_ref + 1 ))
}

dec() {
  # Decrement a named variable by 1, clamped at 0, safe under set -e.
  local -n _dec_ref="$1"
  _dec_ref=$(( _dec_ref > 0 ? _dec_ref - 1 : 0 ))
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SHARED HELPER FUNCTIONS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# cf_curl_delete ENDPOINT
# Run a curl DELETE with http_code capture; echoes raw response JSON.
# Returns 0 always — callers check cf_check on the returned JSON.
cf_curl_delete() {
  local endpoint="$1"
  local token="${CF_TOKEN//[[:space:]]/}"
  local account_id="${CF_ACCOUNT_ID//[[:space:]]/}"
  local tmpfile
  tmpfile=$(mktemp)
  local http_code
  http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" \
    -X DELETE "${CF_API}${endpoint}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" 2>/dev/null)
  local resp
  resp=$(cat "$tmpfile" 2>/dev/null || echo "")
  rm -f "$tmpfile"
  # Surface http_code in the fake error JSON so callers can log it
  if ! cf_check "$resp" && [[ -z "$resp" ]]; then
    resp="{\"success\":false,\"errors\":[{\"message\":\"HTTP ${http_code}\"}]}"
  fi
  printf '%s' "$resp"
}

# cf_curl_post_raw ENDPOINT DATA
# Same pattern as cf_curl_delete but for POST; returns resp + http_code.
# Prints JSON response to stdout. Sets _CF_LAST_HTTP_CODE in caller's scope
# via a side-channel file (avoids subshell limitation).
cf_curl_post_raw() {
  local endpoint="$1" data="$2"
  local token="${CF_TOKEN//[[:space:]]/}"
  local account_id="${CF_ACCOUNT_ID//[[:space:]]/}"
  local tmpfile
  tmpfile=$(mktemp)
  local http_code
  http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" \
    -X POST "${CF_API}${endpoint}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    --data "$data" 2>/dev/null)
  local resp
  resp=$(cat "$tmpfile" 2>/dev/null || echo "")
  rm -f "$tmpfile"
  [[ -z "$resp" ]] && resp="{\"success\":false,\"errors\":[{\"message\":\"HTTP ${http_code}\"}]}"
  printf '%s' "$resp"
}

# select_from_list PROMPT ITEM...
# Prints a numbered list of items to stderr, reads a selection, echoes
# the chosen item to stdout. Returns 1 on cancel/invalid.
select_from_list() {
  local prompt="$1"; shift
  local -a items=("$@")
  if [[ ${#items[@]} -eq 0 ]]; then
    warn "No items to select from." >&2
    return 1
  fi
  echo -e "${W}${prompt}:${NC}\n" >&2
  for i in "${!items[@]}"; do
    printf "  ${C}%d${NC}. %s\n" "$((i+1))" "${items[$i]}" >&2
  done
  echo -ne "\n${W}Choice (0=cancel):${NC} " >&2
  local sel
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return 1
  local idx=$((sel-1))
  if [[ $idx -lt 0 || $idx -ge ${#items[@]} ]]; then
    error "Invalid selection." >&2
    return 1
  fi
  printf '%s' "${items[$idx]}"
}

# prompt_binding_name VAR_NAME_REF
# Prompt the user for a valid identifier to use as a worker binding name.
# Stores result in the nameref variable; returns 1 on cancel/invalid.
prompt_binding_name() {
  local -n _pbn_result="$1"
  local hint="${2:-}"
  [[ -n "$hint" ]] && echo -e "${DM}${hint}${NC}"
  read -rp "$(echo -e "${W}Binding name:${NC} ")" _pbn_result
  [[ -z "$_pbn_result" ]] && info "Cancelled." && return 1
  if ! [[ "$_pbn_result" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    error "Invalid name. Letters, numbers, underscores only (must start with a letter or _)."
    return 1
  fi
}

# binding_dedup_replace BINDINGS_VAR BINDING_NAME
# If a binding named BINDING_NAME already exists in the JSON array stored in
# BINDINGS_VAR, offer to replace it. Updates BINDINGS_VAR in place (nameref).
# Returns 1 if the user declines to replace.
binding_dedup_replace() {
  local -n _bdr_bindings="$1"
  local bname="$2"
  if echo "$_bdr_bindings" | jq -e --arg n "$bname" '.[] | select(.name==$n)' &>/dev/null; then
    warn "Binding '${bname}' already exists."
    confirm "Replace it?" || return 1
    _bdr_bindings=$(echo "$_bdr_bindings" | jq --arg n "$bname" '[.[] | select(.name != $n)]')
  fi
}

# split_pipe VARREF_LEFT VARREF_RIGHT VALUE
# Split "left|right" into two variables.  Works around the common
#   local foo="${picked%%|*}"; local bar="${picked#*|}"
# pattern that's duplicated a dozen times.
split_pipe() {
  local -n _sp_left="$1"
  local -n _sp_right="$2"
  local value="$3"
  _sp_left="${value%%|*}"
  _sp_right="${value#*|}"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# ACCOUNTS STORAGE (plaintext — master password removed)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# This is a personal/local tool, so the master-password vault has been
# removed. $ACCOUNTS_ENC now stores plain JSON (still mode 600, readable
# only by you). decrypt_data() and verify_master_password() are kept only
# so maybe_migrate_legacy_vault() can read an old encrypted vault once and
# convert it; nothing new is ever encrypted with them.

decrypt_data() {
  local data="$1"
  local pass="$2"
  echo "$data" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass pass:"$pass" -base64 2>/dev/null
}

verify_master_password() {
  local pass="$1"
  local salt stored_hash input_hash
  salt=$(cat "$SALT_FILE" 2>/dev/null) || return 1
  stored_hash=$(cat "$MASTER_HASH" 2>/dev/null) || return 1
  input_hash=$(echo -n "${salt}${pass}" | openssl dgst -sha256 | awk '{print $2}')
  [[ "$input_hash" == "$stored_hash" ]]
}

# One-time migration: if $ACCOUNTS_ENC is still an old openssl-encrypted
# blob (from a previous version that used a master password), decrypt it
# once and rewrite it as plain JSON. Then remove the now-unused master
# password files. Safe to call on every startup — it's a no-op once the
# file is already plain JSON or doesn't exist yet.
maybe_migrate_legacy_vault() {
  [[ -f "$ACCOUNTS_ENC" ]] || return 0

  # Already plain JSON? Nothing to migrate.
  if jq -e . "$ACCOUNTS_ENC" &>/dev/null; then
    return 0
  fi

  echo -e "\n${Y}${BLD}One-time migration:${NC} removing master-password encryption from stored accounts.${NC}"

  if [[ ! -f "$MASTER_HASH" || ! -f "$SALT_FILE" ]]; then
    die "Found an encrypted accounts file ($ACCOUNTS_ENC) but no master-password record to decrypt it with. Migration aborted — nothing was changed."
  fi

  local data="" old_pass attempts=3
  while [[ $attempts -gt 0 ]]; do
    read -rsp "$(echo -e "${W}Enter your existing master password to migrate stored accounts:${NC} ")" old_pass; echo
    if verify_master_password "$old_pass"; then
      data=$(decrypt_data "$(cat "$ACCOUNTS_ENC")" "$old_pass")
      break
    fi
    dec attempts
    error "Wrong password. $attempts attempt(s) remaining."
  done

  if [[ -z "$data" ]]; then
    die "Could not decrypt existing accounts — migration aborted. Vault left untouched."
  fi

  echo "$data" > "$ACCOUNTS_ENC"
  chmod 600 "$ACCOUNTS_ENC"
  rm -f "$MASTER_HASH" "$SALT_FILE" "${SESSION_FILE}.ts"
  success "Accounts migrated to plain storage. Master password removed."
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# ACCOUNTS MANAGEMENT
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

load_accounts_data() {
  [[ -f "$ACCOUNTS_ENC" ]] || { echo "{}"; return; }
  local data
  data=$(cat "$ACCOUNTS_ENC" 2>/dev/null)
  [[ -z "$data" ]] && echo "{}" || echo "$data"
}

save_accounts_data() {
  local data="$1"
  echo "$data" > "$ACCOUNTS_ENC"
  chmod 600 "$ACCOUNTS_ENC"
}

list_accounts() {
  local data
  data=$(load_accounts_data)
  echo "$data" | jq -r 'keys[]' 2>/dev/null
}

get_account_field() {
  local name="$1" field="$2"
  local data
  data=$(load_accounts_data)
  echo "$data" | jq -r --arg n "$name" --arg f "$field" '.[$n][$f] // ""'
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# OAUTH2 + PKCE LOGIN (same flow as `wrangler login`)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CF_OAUTH_CLIENT_ID="54d11594-84e4-41aa-b438-e81b8fa78ee7"
CF_OAUTH_AUTH_URL="https://dash.cloudflare.com/oauth2/auth"
CF_OAUTH_TOKEN_URL="https://dash.cloudflare.com/oauth2/token"
CF_OAUTH_CALLBACK_PORT="8976"
CF_OAUTH_CALLBACK_URI="http://localhost:${CF_OAUTH_CALLBACK_PORT}/oauth/callback"
CF_OAUTH_SCOPES="account:read user:read workers:write workers_kv:write workers_routes:write workers_scripts:write workers_tail:read d1:write pages:write pages:read zone:read ssl_certs:write ai:write queues:write pipelines:write secrets_store:write offline_access"

# Generate a URL-safe base64 random string suitable for use as a PKCE verifier.
# RFC 7636 §4.1 restricts verifiers to [A-Za-z0-9\-._~], length 43–128.
# Strategy: generate more bytes than needed, keep only the unreserved-safe
# subset via tr, then trim to the requested length.  Using tr '+/' '-_' before
# stripping '=' keeps the base64url alphabet intact and avoids the mid-character
# truncation that can occur when piping raw base64 directly into head -c.
_oauth_random() {
  local length="${1:-43}"
  local result=""
  # Loop until we have enough characters (very rarely needs more than one pass)
  while [[ ${#result} -lt $length ]]; do
    result+=$(openssl rand -base64 $(( length * 2 )) \
      | tr '+/' '-_' \
      | tr -d '=' \
      | tr -d '\n')
  done
  printf '%s' "${result:0:$length}"
}

# SHA-256 the verifier, base64url-encode it (PKCE S256 challenge)
_pkce_challenge() {
  local verifier="$1"
  printf '%s' "$verifier" \
    | openssl dgst -sha256 -binary \
    | openssl base64 \
    | tr '+/' '-_' \
    | tr -d '='
}


# Spin up a one-shot HTTP listener on $CF_OAUTH_CALLBACK_PORT.
# Blocks until Cloudflare redirects back, then returns "code\nstate\n".
# Prefers Python (reliable query-string parsing); falls back to nc.
_wait_for_oauth_callback() {
  local tmpfile
  tmpfile=$(mktemp)

  if command -v python3 &>/dev/null; then
    # Python's HTTPServer: parses the callback URL properly and validates cleanly
    python3 - "$CF_OAUTH_CALLBACK_PORT" "$tmpfile" <<'PYEOF'
import sys, http.server, urllib.parse, threading

port    = int(sys.argv[1])
outfile = sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass   # silence access log in terminal
    def do_GET(self):
        params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        code  = params.get('code',  [''])[0]
        state = params.get('state', [''])[0]
        with open(outfile, 'w') as f:
            f.write(code + '\n' + state + '\n')
        body = (
            b'<html><body style="font-family:sans-serif;text-align:center;padding:3em">'
            b'<h2>&#10003; Logged in!</h2>'
            b'<p>You can close this tab and return to Termux.</p>'
            b'</body></html>'
        )
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        # Shut down after the first successful request
        threading.Thread(target=self.server.shutdown, daemon=True).start()

with http.server.HTTPServer(('localhost', port), Handler) as srv:
    srv.serve_forever()
PYEOF

    local code state_recv
    code=$(sed -n '1p' "$tmpfile" 2>/dev/null)
    state_recv=$(sed -n '2p' "$tmpfile" 2>/dev/null)
    rm -f "$tmpfile"
    printf '%s\n%s\n' "$code" "$state_recv"

  else
    # Fallback: nc (less reliable on Termux busybox builds — no PCRE grep, -q flag varies)
    warn "python3 not found — falling back to nc for OAuth callback"
    (
      printf 'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\n\r\n<!doctype html><html><head><meta charset=utf-8><title>CF-Manager</title></head><body style="font-family:sans-serif;text-align:center;padding:3em"><h2>&#10003; Logged in!</h2><p>You can close this tab and return to the terminal.</p></body></html>\r\n'
    ) | nc -l -p "$CF_OAUTH_CALLBACK_PORT" -q 2 > "$tmpfile" 2>/dev/null \
    || nc -l "$CF_OAUTH_CALLBACK_PORT" > "$tmpfile" 2>/dev/null \
    || { rm -f "$tmpfile"; return 1; }

    local code_raw
    code_raw=$(grep -m1 '^GET' "$tmpfile" \
      | grep -oP '(?<=code=)[^&\s ]+' 2>/dev/null \
      || sed -n 's/.*GET \/oauth\/callback?.*code=\([^& ]*\).*/\1/p' "$tmpfile" | head -1)
    rm -f "$tmpfile"
    # nc path: no state available, emit empty second line so caller format stays consistent
    printf '%s\n\n' "$code_raw"
  fi
}

# Exchange the authorization code for an access token.
# Uses curl -s (no -f) so that HTTP 4xx/5xx error bodies are captured.
# Sends a browser-like User-Agent and Origin header to avoid Cloudflare's
# edge bot-detection challenge, which blocks plain curl requests to
# dash.cloudflare.com/oauth2/token with a JS challenge page.
_exchange_oauth_code() {
  local code="$1" verifier="$2"
  local resp http_code tmpfile
  tmpfile=$(mktemp)
  http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" \
    -X POST "$CF_OAUTH_TOKEN_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -H "Accept: application/json" \
    -H "Origin: https://dash.cloudflare.com" \
    -H "Referer: https://dash.cloudflare.com/" \
    -H "User-Agent: Mozilla/5.0 (Linux; Android 10; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36" \
    --data-urlencode "grant_type=authorization_code" \
    --data-urlencode "code=$code" \
    --data-urlencode "redirect_uri=$CF_OAUTH_CALLBACK_URI" \
    --data-urlencode "client_id=$CF_OAUTH_CLIENT_ID" \
    --data-urlencode "code_verifier=$verifier" \
    2>/dev/null)
  local curl_exit=$?
  resp=$(cat "$tmpfile" 2>/dev/null || echo "")
  rm -f "$tmpfile"
  # Detect Cloudflare bot-challenge page (HTML instead of JSON)
  if echo "$resp" | grep -q "Just a moment\|cf_chl_opt\|challenge-platform"; then
    echo "{\"error\":\"cf_bot_challenge\",\"error_description\":\"Cloudflare bot challenge blocked the token request. Try adding a small delay before retrying, or run from a different network.\"}"
    return
  fi
  # Surface network-level failures as a parseable JSON error
  if [[ $curl_exit -ne 0 || -z "$resp" ]]; then
    echo "{\"error\":\"network_error\",\"error_description\":\"curl failed (HTTP ${http_code}, exit ${curl_exit})\"}"
    return
  fi
  echo "$resp"
}

# Full OAuth2 + PKCE flow. Prints the access_token to stdout.
cf_oauth_login() {
  # 1. Generate PKCE verifier + challenge
  local verifier state
  verifier=$(_oauth_random 43)
  state=$(_oauth_random 32)
  local challenge
  challenge=$(_pkce_challenge "$verifier")

  # 2. Pre-compute the URL-encoded redirect URI (must NOT go to stdout — token=$(cf_oauth_login) captures all stdout)
  local encoded_redirect
  encoded_redirect=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$CF_OAUTH_CALLBACK_URI" 2>/dev/null \
    || echo "$CF_OAUTH_CALLBACK_URI" | sed 's|:|%3A|g;s|/|%2F|g')

  # 3. Build the authorization URL (no subshells printing to stdout here)
  # prompt=login forces Cloudflare to show the login/account-picker even if
  # the browser already has an active dash.cloudflare.com session.
  local auth_url
  auth_url="${CF_OAUTH_AUTH_URL}?response_type=code"
  auth_url+="&client_id=${CF_OAUTH_CLIENT_ID}"
  auth_url+="&redirect_uri=${encoded_redirect}"
  auth_url+="&scope=${CF_OAUTH_SCOPES// /+}"
  auth_url+="&state=${state}"
  auth_url+="&code_challenge=${challenge}"
  auth_url+="&code_challenge_method=S256"
  auth_url+="&prompt=login"

  # All display output goes to stderr so token=$(cf_oauth_login) captures
  # only the bare access_token on stdout — nothing else.

  # ── Step A: open auth URL; detect termux-open-url crashes via stderr ─────────
  # prompt=login in the URL already forces Cloudflare to show a fresh login form
  # regardless of any existing browser session, so no separate logout tab needed.
  # The browser will open exactly 2 things: the auth page, then the callback tab.
  local _can_open=false
  local _open_err
  if command -v termux-open-url &>/dev/null; then
    _open_err=$(termux-open-url "$auth_url" 2>&1 >/dev/null)
    [[ "$_open_err" != *"Exception"* && "$_open_err" != *"Error"* ]] && _can_open=true
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$auth_url" &>/dev/null & _can_open=true
  elif command -v open &>/dev/null; then
    open "$auth_url" 2>/dev/null && _can_open=true
  fi

  if [[ "$_can_open" == true ]]; then
    echo -e "\n${C}${BLD}Browser opened — sign in with the account you want to add.${NC}" >&2
    echo -e "${DM}(After you approve, return to Termux — it will continue automatically.)${NC}\n" >&2

    local _cb_tmpfile
    _cb_tmpfile=$(mktemp)
    _wait_for_oauth_callback > "$_cb_tmpfile" &
    local _cb_pid=$!

    echo -ne "${C}Waiting for browser callback on port ${CF_OAUTH_CALLBACK_PORT}...${NC}" >&2
    wait "$_cb_pid" 2>/dev/null || true

  else
    # ── Manual fallback (termux-open-url crashed or unavailable) ──────────────
    echo -e "\n${R}${BLD}Cannot open browser automatically (termux-open-url failed).${NC}" >&2
    echo -e "${W}Open this URL manually in your browser:${NC}\n" >&2
    echo -e "${C}${auth_url}${NC}\n" >&2
    echo -e "${DM}Sign in, approve access, then the browser will show a 'Logged in!' page.${NC}" >&2
    echo -e "${DM}Return to Termux — it will continue automatically.${NC}\n" >&2

    local _cb_tmpfile
    _cb_tmpfile=$(mktemp)
    _wait_for_oauth_callback > "$_cb_tmpfile" &
    local _cb_pid=$!
    sleep 0.8

    echo -ne "${C}Waiting for browser callback on port ${CF_OAUTH_CALLBACK_PORT}...${NC}" >&2
    wait "$_cb_pid" 2>/dev/null || true
  fi

  local callback_result code state_recv
  callback_result=$(cat "$_cb_tmpfile" 2>/dev/null || true)
  rm -f "$_cb_tmpfile"
  code=$(printf '%s' "$callback_result" | sed -n '1p')
  state_recv=$(printf '%s' "$callback_result" | sed -n '2p')

  if [[ -z "$code" ]]; then
    echo -e " ${SYM_ERR}" >&2
    error "Did not receive OAuth callback. Login timed out or was cancelled." >&2
    return 1
  fi

  # Validate state to guard against CSRF
  if [[ -n "$state_recv" && "$state_recv" != "$state" ]]; then
    echo -e " ${SYM_ERR}" >&2
    error "OAuth state mismatch — possible CSRF attack. Login aborted." >&2
    return 1
  fi

  echo -e " ${SYM_OK}" >&2

  echo -ne "${C}Exchanging code for access token...${NC}" >&2
  local token_resp
  token_resp=$(_exchange_oauth_code "$code" "$verifier")

  local access_token
  access_token=$(echo "$token_resp" | jq -r '.access_token // empty' 2>/dev/null)

  if [[ -z "$access_token" ]]; then
    echo -e " ${SYM_ERR}" >&2
    local err
    err=$(echo "$token_resp" | jq -r '.error_description // .error // "unknown"' 2>/dev/null)
    error "Token exchange failed: $err" >&2
    # Log the raw response to help diagnose the issue (e.g. invalid_grant, redirect_uri_mismatch)
    log "OAuth token exchange failed. Raw response: $token_resp"
    error "See log for details: $LOG_FILE" >&2
    return 1
  fi
  echo -e " ${SYM_OK}" >&2

  # stdout carries only the bare token — this is what token=$(cf_oauth_login) captures
  printf '%s' "$access_token"
}

# Revoke the OAuth token for a given account via Cloudflare's revoke endpoint,
# then clear it from the encrypted store so the browser session is also invalidated.
cf_oauth_logout() {
  local account_name="$1"
  local token
  token=$(get_account_field "$account_name" "token")

  if [[ -z "$token" ]]; then
    warn "No token found for '${account_name}'."
    return 1
  fi

  echo -ne "${C}Revoking token for '${account_name}'...${NC}"

  # POST to Cloudflare's OAuth revocation endpoint
  local resp http_code tmpfile
  tmpfile=$(mktemp)
  http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" \
    -X POST "https://dash.cloudflare.com/oauth2/revoke" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "token=$token" \
    --data-urlencode "client_id=${CF_OAUTH_CLIENT_ID}" \
    2>/dev/null)
  resp=$(cat "$tmpfile" 2>/dev/null || true)
  rm -f "$tmpfile"

  # Cloudflare returns 200 on success; 400 if already revoked/invalid — both are fine
  if [[ "$http_code" == "200" || "$http_code" == "400" ]]; then
    echo -e " ${SYM_OK}"
    success "Token revoked on Cloudflare's side."
  else
    echo -e " ${SYM_WARN}"
    warn "Cloudflare returned HTTP ${http_code} — token may already be expired."
    warn "Proceeding to clear local credentials anyway."
  fi

  # Wipe the token from the local encrypted store (replace with empty string)
  local data
  data=$(load_accounts_data)
  data=$(echo "$data" | jq --arg n "$account_name" '.[$n].token = ""')
  save_accounts_data "$data"

  # If this was the active account, clear the runtime globals so nothing can
  # accidentally reuse the old token within this session.
  if [[ "$ACTIVE_ACCOUNT_NAME" == "$account_name" ]]; then
    CF_TOKEN=""
    CF_ACCOUNT_ID=""
    CF_ZONE_ID=""
    ACTIVE_ACCOUNT_NAME=""
    rm -f "$CURRENT_ACCOUNT"
  fi

  echo ""
  info "The browser session for this account is now invalidated."
  info "To use this account again, choose ${C}Add account${NC} (or ${C}Re-login${NC}) to re-authorise."
  log "OAuth token revoked and cleared: $account_name"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PERMANENT API TOKEN CREATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Use a short-lived OAuth access token to mint a permanent Cloudflare
# API token scoped to all the permissions CF-Manager needs.
# Prints the new permanent token to stdout; all other output goes to stderr.
# Returns 1 on failure.
cf_create_permanent_token() {
  local oauth_token="$1"
  local account_id="$2"
  local token_name="${3:-cfmanager-$(date +%Y%m%d)}"

  # Build the permissions payload. Each entry is a {effect, resources, permission_groups} object.
  # We request both account-level and zone-level permission groups that CF-Manager uses.
  local payload
  payload=$(jq -n \
    --arg name "$token_name" \
    --arg acct_id "$account_id" \
    '{
      name: $name,
      policies: [
        {
          effect: "allow",
          resources: { ("com.cloudflare.api.account." + $acct_id): "*" },
          permission_groups: [
            { id: "c8fed203ed3043cba015a93ad1616f1f", name: "Account Settings Read" },
            { id: "82e64a83756745bbbb1c9c2701bf816b", name: "Workers Scripts Write" },
            { id: "1b36e80ca2d74f19bb9bcd0ffdcc4df0", name: "Workers KV Storage Write" },
            { id: "3030687196b94b638145a3953da2b699", name: "Workers Routes Write" },
            { id: "da92ae9bdfd2430ea5fc5ac34d56d81e", name: "Workers Tail Read" },
            { id: "4755a26eedb94da69e1066d98aa820be", name: "D1 Write" },
            { id: "9cf5ef6e99554810b1e24f34b3b58ebb", name: "Pages Write" },
            { id: "f7f0eda5697f475c90846e879bab8666", name: "R2 Storage Write" },
            { id: "6a67612cda854ce7bbc5c4aae62ffebc", name: "Queues Write" },
            { id: "e086da7e2179491d91ee5f35b3ca210a", name: "AI Gateway Write" },
            { id: "b415b70a4fd1412886f0ea6382e18279", name: "Durable Objects Write" }
          ]
        },
        {
          effect: "allow",
          resources: { "com.cloudflare.api.account.zone.*": "*" },
          permission_groups: [
            { id: "e17beae8b8cb423197993878a8e96bf4", name: "Zone Read" },
            { id: "02b8e4a5-7c80-4c14-9c83-3de5f96d80b3", name: "SSL and Certificates Write" }
          ]
        }
      ],
      not_before: null,
      expires_on: null
    }')

  echo -ne "${C}Creating permanent API token...${NC}" >&2

  local tmpfile http_code resp
  tmpfile=$(mktemp)
  http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" \
    -X POST "${CF_API}/user/tokens" \
    -H "Authorization: Bearer ${oauth_token}" \
    -H "Content-Type: application/json" \
    --data "$payload" 2>/dev/null)
  resp=$(cat "$tmpfile" 2>/dev/null || echo "")
  rm -f "$tmpfile"

  local new_token
  new_token=$(echo "$resp" | jq -r '.result.value // empty' 2>/dev/null)

  if [[ -z "$new_token" ]]; then
    echo -e " ${SYM_WARN}" >&2
    local api_err
    api_err=$(echo "$resp" | jq -r '.errors[0].message // "unknown error"' 2>/dev/null)
    warn "Could not create permanent token: ${api_err}" >&2
    warn "Falling back to OAuth access token (expires ~1 day)." >&2
    log "Permanent token creation failed (HTTP ${http_code}): $api_err. Raw: $resp"
    return 1
  fi

  echo -e " ${SYM_OK}" >&2
  log "Permanent API token created: $token_name"
  # stdout = bare token value only
  printf '%s' "$new_token"
}

# Open a URL with whatever browser opener is available.
# Returns 0 if a browser was launched, 1 if none was found (caller should
# then print the URL for the user to open manually).
_open_browser_url() {
  local url="$1"
  if command -v termux-open-url &>/dev/null; then
    local _err
    _err=$(termux-open-url "$url" 2>&1 >/dev/null)
    [[ "$_err" != *"Exception"* && "$_err" != *"Error"* ]] && return 0
    return 1
  elif command -v xdg-open &>/dev/null; then
    xdg-open "$url" &>/dev/null &
    return 0
  elif command -v open &>/dev/null; then
    open "$url" 2>/dev/null && return 0
    return 1
  fi
  return 1
}

# ── Manual permanent-token fallback ─────────────────────────────────────
#
# WHY THIS EXISTS:
# cf_create_permanent_token() above calls POST /user/tokens using the
# wrangler-style OAuth access token from cf_oauth_login(). On many accounts
# Cloudflare rejects that call with:
#
#     {"code":9109,"message":"Unauthorized to access requested resource"}
#
# This is NOT a missing-scope bug in this script. POST /user/tokens requires
# the "API Tokens Write" permission group, and Cloudflare does not expose any
# OAuth scope (for this or any third-party client_id) that grants that
# permission group — by design, an OAuth-issued credential is not allowed to
# mint other API tokens. Adding more entries to CF_OAUTH_SCOPES cannot fix
# this; there is no scope for it.
#
# The supported workaround is the dashboard's "API token template URL"
# feature: we build a pre-filled token-creation link (permissions already
# selected) and send the user there for one manual click of "Create Token",
# then read the resulting permanent token back in.
#
# Prints the pasted+verified token to stdout. All other output -> stderr.
# Returns 1 if the user cancels.
cf_manual_token_setup() {
  local account_id="$1"
  local token_label="${2:-cfmanager-$(date +%Y%m%d)}"

  # Permission set mirrors the permission_groups requested in
  # cf_create_permanent_token(), expressed as dashboard template keys.
  local perms
  perms=$(jq -nc '[
    {"key":"account_settings","type":"read"},
    {"key":"workers_scripts","type":"edit"},
    {"key":"workers_kv_storage","type":"edit"},
    {"key":"workers_routes","type":"edit"},
    {"key":"d1","type":"edit"},
    {"key":"page","type":"edit"},
    {"key":"workers_r2","type":"edit"},
    {"key":"queues","type":"edit"},
    {"key":"logs","type":"read"},
    {"key":"zone","type":"read"},
    {"key":"ssl_and_certificates","type":"edit"}
  ]')

  local encoded_perms encoded_name
  encoded_perms=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$perms" 2>/dev/null) \
    || encoded_perms=$(printf '%s' "$perms" | jq -sRr '@uri')
  encoded_name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$token_label" 2>/dev/null) \
    || encoded_name="$token_label"

  local template_url
  template_url="https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=${encoded_perms}&accountId=${account_id}&zoneId=all&name=${encoded_name}"

  echo -e "\n${Y}${BLD}Cloudflare blocks OAuth logins from minting API tokens (error 9109).${NC}" >&2
  echo -e "${DM}This is a Cloudflare-side restriction — no OAuth scope can bypass it.${NC}" >&2
  echo -e "${DM}Opening a pre-filled token-creation page instead.${NC}\n" >&2
  echo -e "  ${W}1.${NC} Review the permissions (already filled in for you)" >&2
  echo -e "  ${W}2.${NC} Click ${BLD}Continue to summary${NC}, then ${BLD}Create Token${NC}" >&2
  echo -e "  ${W}3.${NC} Copy the token shown (it's only displayed once) and paste it below\n" >&2

  if ! _open_browser_url "$template_url"; then
    echo -e "${W}Open this URL manually in your browser:${NC}" >&2
    echo -e "${C}${template_url}${NC}\n" >&2
  fi

  local pasted
  echo -ne "${W}Paste the new API token (blank to cancel):${NC} " >&2
  read -rs pasted
  echo "" >&2
  pasted=$(printf '%s' "$pasted" | tr -d '[:space:]')
  if [[ -z "$pasted" ]]; then
    error "No token entered." >&2
    return 1
  fi

  echo -ne "${C}Verifying token...${NC}" >&2
  local verify_resp
  verify_resp=$(curl -sf "${CF_API}/user/tokens/verify" \
    -H "Authorization: Bearer ${pasted}" \
    -H "Content-Type: application/json" 2>/dev/null || echo '{"success":false}')
  if echo "$verify_resp" | jq -e '.result.status == "active"' &>/dev/null; then
    echo -e " ${SYM_OK}" >&2
  else
    echo -e " ${SYM_WARN}" >&2
    warn "Could not verify token — saving anyway." >&2
  fi

  log "Permanent API token added manually via dashboard template: $token_label"
  printf '%s' "$pasted"
}

# Mint a fresh permanent token for an already-stored account.
# Re-uses a brief OAuth re-login so the OAuth credential itself is never persisted.
refresh_permanent_token() {
  header "Refresh Permanent Token"
  local accounts
  mapfile -t accounts < <(list_accounts)
  [[ ${#accounts[@]} -eq 0 ]] && warn "No accounts stored." && press_enter && return

  echo -e "${W}Select account to refresh token for:${NC}\n"
  local current
  current=$(cat "$CURRENT_ACCOUNT" 2>/dev/null || echo "")
  for i in "${!accounts[@]}"; do
    local marker=""
    [[ "${accounts[$i]}" == "$current" ]] && marker=" ${G}← active${NC}"
    echo -e "  ${C}$((i+1))${NC}. ${accounts[$i]}${marker}"
  done
  echo -ne "\n${W}Select account (0=cancel):${NC} "
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return
  local idx=$((sel-1))
  [[ $idx -lt 0 || $idx -ge ${#accounts[@]} ]] && error "Invalid selection." && press_enter && return

  local name="${accounts[$idx]}"
  local acct_id
  acct_id=$(get_account_field "$name" "account_id")

  # NOTE: the old flow re-ran cf_oauth_login() purely to feed an OAuth token
  # into cf_create_permanent_token() (POST /user/tokens), which Cloudflare
  # always rejects with error 9109 for OAuth credentials. Both steps are
  # skipped now — we go straight to the manual template-URL flow, which
  # doesn't need an OAuth token at all.
  echo -e "\n${C}Opening Cloudflare's token creation page...${NC}\n"

  local new_token
  local token_label="cfmanager-${name}-$(date +%Y%m%d%H%M)"
  new_token=$(cf_manual_token_setup "$acct_id" "$token_label") || {
    error "Permanent token refresh failed."
    press_enter; return
  }

  # Verify the new token works before saving
  echo -ne "${C}Verifying new token...${NC}"
  local verify_resp
  verify_resp=$(curl -sf "${CF_API}/user/tokens/verify" \
    -H "Authorization: Bearer ${new_token}" \
    -H "Content-Type: application/json" 2>/dev/null || echo '{"success":false}')
  if echo "$verify_resp" | jq -e '.result.status == "active"' &>/dev/null; then
    echo -e " ${SYM_OK}"
  else
    echo -e " ${SYM_WARN}"
    warn "Token verification inconclusive — saving anyway."
  fi

  # Persist the new permanent token
  local data
  data=$(load_accounts_data)
  data=$(echo "$data" | jq \
    --arg n "$name" \
    --arg t "$new_token" \
    --arg label "$token_label" \
    '.[$n].token = $t | .[$n].token_type = "permanent" | .[$n].token_label = $label | .[$n].token_refreshed = (now|todate)')
  save_accounts_data "$data"

  # Update runtime if this is the active account
  if [[ "$ACTIVE_ACCOUNT_NAME" == "$name" ]]; then
    CF_TOKEN="$new_token"
  fi

  echo ""
  success "Permanent token refreshed and saved for '${BLD}${name}${NC}'."
  log "Permanent token refreshed for account: $name (label: $token_label)"
  press_enter
}

# Prompt the user to pick an account and run cf_oauth_logout on it.
logout_account() {
  header "Logout / Revoke Token"
  local accounts
  mapfile -t accounts < <(list_accounts)
  [[ ${#accounts[@]} -eq 0 ]] && warn "No accounts stored." && press_enter && return

  echo -e "${W}Select account to log out from Cloudflare:${NC}\n"
  local current
  current=$(cat "$CURRENT_ACCOUNT" 2>/dev/null || echo "")
  for i in "${!accounts[@]}"; do
    local marker=""
    local tok_status=""
    [[ "${accounts[$i]}" == "$current" ]] && marker=" ${G}← active${NC}"
    local tok
    tok=$(get_account_field "${accounts[$i]}" "token")
    [[ -z "$tok" ]] && tok_status=" ${R}(no token)${NC}"
    echo -e "  ${C}$((i+1))${NC}. ${accounts[$i]}${marker}${tok_status}"
  done

  echo -ne "\n${W}Select account to logout (0=cancel):${NC} "
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return
  local idx=$((sel-1))
  [[ $idx -lt 0 || $idx -ge ${#accounts[@]} ]] && error "Invalid selection." && press_enter && return

  local name="${accounts[$idx]}"
  echo ""
  echo -e "${Y}This will revoke the OAuth token on Cloudflare's servers${NC}"
  echo -e "${DM}and clear it locally. You will need to re-login to use this account.${NC}"
  echo -e "${DM}Note: this does NOT delete the account entry — only the token.${NC}\n"
  confirm "Logout '${name}'?" || return

  cf_oauth_logout "$name"
  press_enter
}

add_account() {
  header "Add Cloudflare Account"

  echo -e "${C}${BLD}This will open the Cloudflare login page in your browser.${NC}"
  echo -e "${DM}No manual copy-pasting required — everything is fetched automatically.${NC}\n"

  # ── Step 1: OAuth login ────────────────────────────────────────────
  local token
  token=$(cf_oauth_login) || { press_enter; return; }
  token=$(printf '%s' "$token" | tr -d '[:space:]')
  if [[ ${#token} -lt 20 || "$token" != cfoat_* && "$token" != v1.0-* && ${#token} -lt 40 ]]; then
    error "Token looks invalid (${#token} chars, value: '${token}')."
    press_enter; return
  fi

  # ── Step 2: Fetch user email ───────────────────────────────────────
  echo -ne "${C}Fetching account details...${NC}"
  local user_resp
  user_resp=$(curl -sf "$CF_API/user" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" 2>/dev/null || echo '{"success":false}')
  local email
  email=$(echo "$user_resp" | jq -r '.result.email // ""')

  # ── Step 3: Fetch accounts ─────────────────────────────────────────
  # Strategy (mirrors BPB-Wizard's cloudflare-go SDK approach):
  #   1. /accounts        — works with OAuth tokens; returns {id,name} directly
  #   2. /memberships     — fallback, no status filter (avoids dropping personal
  #                         accounts whose status isn't "accepted"); normalised
  #                         to the same {id,name} shape as /accounts
  local accts_resp account_count
  accts_resp=$(curl -sf "$CF_API/accounts?per_page=50" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" 2>/dev/null || echo '{"success":false}')
  account_count=$(echo "$accts_resp" | jq '.result | length' 2>/dev/null || echo 0)

  if [[ "$account_count" -eq 0 || $(echo "$accts_resp" | jq -r '.success') != "true" ]]; then
    info "  /accounts returned nothing — trying /memberships..."
    local mem_resp
    mem_resp=$(curl -sf "$CF_API/memberships?per_page=50" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" 2>/dev/null || echo '{"success":false}')
    # Normalise memberships shape → {result:[{id,name}]} to match /accounts
    accts_resp=$(echo "$mem_resp" | jq '{success:.success, result:[.result[]?.account // empty]}')
    account_count=$(echo "$accts_resp" | jq '.result | length' 2>/dev/null || echo 0)
  fi
  echo -e " ${SYM_OK}"

  if [[ "$account_count" -eq 0 || $(echo "$accts_resp" | jq -r '.success') != "true" ]]; then
    local api_err
    api_err=$(echo "$accts_resp" | jq -r '.errors[0].message // "no accounts found"' 2>/dev/null)
    error "Could not fetch accounts: $api_err"
    press_enter; return
  fi

  # Both /accounts and the normalised /memberships response now use .id / .name
  local account_id account_name
  if [[ "$account_count" -gt 1 ]]; then
    echo -e "\n${W}Multiple Cloudflare accounts found:${NC}"
    local i=0
    while IFS= read -r line; do
      i=$((i+1))
      local aname aid
      aname=$(echo "$line" | jq -r '.name')
      aid=$(echo "$line"   | jq -r '.id')
      echo -e "  ${C}${i}${NC}. ${aname}  ${DM}(${aid})${NC}"
    done < <(echo "$accts_resp" | jq -c '.result[]')

    echo -ne "\n${W}Select account [1-${i}]:${NC} "
    read -r sel
    local idx=$((sel-1))
    account_id=$(echo "$accts_resp"   | jq -r ".result[${idx}].id"   | tr -d '[:space:]')
    account_name=$(echo "$accts_resp" | jq -r ".result[${idx}].name" | tr -d '\n')
  else
    account_id=$(echo "$accts_resp"   | jq -r '.result[0].id'   | tr -d '[:space:]')
    account_name=$(echo "$accts_resp" | jq -r '.result[0].name' | tr -d '\n')
    echo -e "${SYM_INFO} Account: ${BLD}${account_name}${NC}  ${DM}(${account_id})${NC}"
  fi

  # ── Step 4: Choose a nickname ──────────────────────────────────────
  local default_name
  default_name=$(echo "$account_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
  echo -ne "\n${W}Account nickname${NC} ${DM}[${default_name}]:${NC} "
  read -r name
  [[ -z "$name" ]] && name="$default_name"

  # ── Step 5: Optional zone ID ───────────────────────────────────────
  local zone_id=""
  echo -ne "${W}Default Zone ID${NC} ${DM}(optional, Enter to skip):${NC} "
  read -r zone_id

  # ── Step 6: Mint a permanent API token using the OAuth credential ──
  # The OAuth access token is short-lived (~24 h). We use it here as a
  # bootstrap to call POST /user/tokens and create a permanent token with
  # all the scopes CF-Manager needs. The OAuth token itself is NOT saved.
  #
  # NOTE: cf_create_permanent_token() (the automatic POST /user/tokens call)
  # is skipped here — Cloudflare rejects it for OAuth credentials with
  # error 9109 "Unauthorized to access requested resource" (see comment on
  # cf_manual_token_setup below for why). We go straight to the manual
  # template-URL flow instead of wasting a guaranteed-to-fail API call.
  local token_label="cfmanager-${name}-$(date +%Y%m%d%H%M)"
  local stored_token token_type
  local manual_token
  manual_token=$(cf_manual_token_setup "$account_id" "$token_label") && {
    stored_token="$manual_token"
    token_type="permanent"
    info "Permanent token stored — no expiry. Revoke at: https://dash.cloudflare.com/profile/api-tokens"
  } || {
    stored_token="$token"
    token_type="oauth_access"
    warn "Stored OAuth access token instead (expires ~24 h). Use ${C}Settings → Refresh Token${NC} later."
  }

  # ── Step 7: Persist ────────────────────────────────────────────────
  local data new_entry
  data=$(load_accounts_data)
  new_entry=$(echo "$data" | jq \
    --arg n  "$name"          --arg t "$stored_token" \
    --arg a  "$account_id"    --arg e "$email" \
    --arg z  "$zone_id"       --arg an "$account_name" \
    --arg tt "$token_type"    --arg tl "$token_label" \
    '.[$n] = {token:$t, token_type:$tt, token_label:$tl,
              account_id:$a, email:$e, zone_id:$z,
              cf_account_name:$an, created:(now|todate)}')
  save_accounts_data "$new_entry"

  echo ""
  success "Account '${BLD}${name}${NC}' saved."
  echo -e "  ${DM}Email:      ${email}${NC}"
  echo -e "  ${DM}Account:    ${account_name}${NC}"
  echo -e "  ${DM}Account ID: ${account_id}${NC}"
  echo -e "  ${DM}Token type: ${token_type}${NC}"
  log "Account added via OAuth: $name ($account_id) | token_type=$token_type"
  press_enter
}

remove_account() {
  header "Remove Account"
  local accounts
  mapfile -t accounts < <(list_accounts)
  [[ ${#accounts[@]} -eq 0 ]] && warn "No accounts stored." && press_enter && return
  echo -e "${W}Accounts:${NC}"
  for i in "${!accounts[@]}"; do
    echo -e "  ${C}$((i+1))${NC}. ${accounts[$i]}"
  done
  echo -ne "\n${W}Select account to remove (0=cancel):${NC} "
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return
  local idx=$((sel-1))
  [[ $idx -lt 0 || $idx -ge ${#accounts[@]} ]] && error "Invalid selection." && press_enter && return
  local name="${accounts[$idx]}"
  confirm "Remove account '${name}'?" || return
  local data
  data=$(load_accounts_data)
  data=$(echo "$data" | jq --arg n "$name" 'del(.[$n])')
  save_accounts_data "$data"
  [[ "$(cat "$CURRENT_ACCOUNT" 2>/dev/null)" == "$name" ]] && rm -f "$CURRENT_ACCOUNT"
  success "Account '$name' removed."
  log "Account removed: $name"
  press_enter
}

switch_account() {
  header "Switch Account"
  local accounts
  mapfile -t accounts < <(list_accounts)
  [[ ${#accounts[@]} -eq 0 ]] && warn "No accounts. Add one first." && press_enter && return
  echo -e "${W}Available accounts:${NC}\n"
  local current
  current=$(cat "$CURRENT_ACCOUNT" 2>/dev/null || echo "")
  for i in "${!accounts[@]}"; do
    local marker=""
    [[ "${accounts[$i]}" == "$current" ]] && marker=" ${G}← active${NC}"
    echo -e "  ${C}$((i+1))${NC}. ${accounts[$i]}${marker}"
  done
  echo -ne "\n${W}Select account (0=cancel):${NC} "
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return
  local idx=$((sel-1))
  [[ $idx -lt 0 || $idx -ge ${#accounts[@]} ]] && error "Invalid." && press_enter && return
  local name="${accounts[$idx]}"
  echo "$name" > "$CURRENT_ACCOUNT"
  load_active_account
  success "Switched to '${BLD}$name${NC}'."
  press_enter
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TOKEN HEALTH CHECK
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Silently verify the active token against /user/tokens/verify.
# Returns 0 if valid, 1 if expired/invalid (and prints a warning).
check_token_health() {
  [[ -z "$CF_TOKEN" ]] && return 1
  local resp
  resp=$(curl -sf "${CF_API}/user/tokens/verify"     -H "Authorization: Bearer ${CF_TOKEN//[[:space:]]/}"     -H "Content-Type: application/json" 2>/dev/null || echo '{"success":false}')
  if echo "$resp" | jq -e '.result.status == "active"' &>/dev/null; then
    return 0
  else
    local status
    status=$(echo "$resp" | jq -r '.result.status // "unknown"' 2>/dev/null)
    warn "Token for '${ACTIVE_ACCOUNT_NAME}' appears ${R}${status}${NC}."
    warn "Re-add the account via ${C}Settings → Add account${NC} to refresh it."
    return 1
  fi
}

load_active_account() {
  local name
  name=$(cat "$CURRENT_ACCOUNT" 2>/dev/null | tr -d '[:space:]' || echo "")
  [[ -z "$name" ]] && return
  CF_TOKEN=$(get_account_field "$name" "token" | tr -d '\n\r\t ')
  CF_ACCOUNT_ID=$(get_account_field "$name" "account_id" | tr -d '\n\r\t ')
  CF_ZONE_ID=$(get_account_field "$name" "zone_id" | tr -d '\n\r\t ')
  ACTIVE_ACCOUNT_NAME="$name"
  # Verify token health in the background so startup is instant.
  # Any warning prints asynchronously before the first menu prompt.
  ( check_token_health || true ) &
}

require_account() {
  [[ -z "$CF_TOKEN" ]] && error "No active account. Please switch/add account first." && press_enter && return 1
  return 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CLOUDFLARE API HELPERS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

cf_get() {
  local endpoint="$1"
  local token="${CF_TOKEN//[[:space:]]/}"
  local tmpfile
  tmpfile=$(mktemp)
  local resp http_code
  http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" -X GET "${CF_API}${endpoint}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" 2>/dev/null)
  local curl_exit=$?
  resp=$(cat "$tmpfile" 2>/dev/null || echo "")
  rm -f "$tmpfile"
  if [[ $curl_exit -ne 0 || -z "$resp" ]]; then
    echo "{\"success\":false,\"errors\":[{\"message\":\"Network error (HTTP ${http_code}, exit ${curl_exit}) — check internet connection\"}]}"
    return
  fi
  echo "$resp"
}

# Same as cf_get, but takes an explicit bearer token instead of using the
# global $CF_TOKEN. This lets callers issue authenticated GETs for OTHER
# accounts (e.g. inside a background subshell) without mutating global
# session state — the basis for our multi-account concurrent fetches.
#   cf_get_with_token TOKEN ENDPOINT
cf_get_with_token() {
  local token="${1//[[:space:]]/}"
  local endpoint="$2"
  local tmpfile
  tmpfile=$(mktemp)
  local resp http_code
  http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" -X GET "${CF_API}${endpoint}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" 2>/dev/null)
  local curl_exit=$?
  resp=$(cat "$tmpfile" 2>/dev/null || echo "")
  rm -f "$tmpfile"
  if [[ $curl_exit -ne 0 || -z "$resp" ]]; then
    echo "{\"success\":false,\"errors\":[{\"message\":\"Network error (HTTP ${http_code}, exit ${curl_exit}) — check internet connection\"}]}"
    return
  fi
  echo "$resp"
}

# Fetch the same API endpoint for every stored account CONCURRENTLY.
# Writes the raw JSON response for each account to "$outdir/<account>.json".
# Accounts missing a token/account_id get a synthetic error JSON so callers
# can still iterate uniformly. Blocks until every request finishes.
#   fetch_all_accounts OUTDIR ENDPOINT_SUFFIX
# ENDPOINT_SUFFIX is appended to "/accounts/<account_id>", e.g. "/workers/scripts"
fetch_all_accounts() {
  local outdir="$1" endpoint_suffix="$2"
  local -a accounts
  mapfile -t accounts < <(list_accounts)
  local acct
  for acct in "${accounts[@]}"; do
    (
      local token acct_id
      token=$(get_account_field "$acct" "token" | tr -d '[:space:]')
      acct_id=$(get_account_field "$acct" "account_id" | tr -d '[:space:]')
      if [[ -z "$token" || -z "$acct_id" ]]; then
        printf '%s' '{"success":false,"errors":[{"message":"No token or account ID configured"}]}' > "$outdir/${acct}.json"
        exit 0
      fi
      cf_get_with_token "$token" "/accounts/${acct_id}${endpoint_suffix}" > "$outdir/${acct}.json"
    ) &
  done
  wait
}

cf_post() {
  local endpoint="$1"
  local data="$2"
  local tmpfile; tmpfile=$(mktemp)
  local http_code curl_exit
  http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" -X POST "${CF_API}${endpoint}" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$data" 2>/dev/null)
  curl_exit=$?
  local resp; resp=$(cat "$tmpfile" 2>/dev/null || echo "")
  rm -f "$tmpfile"
  if [[ $curl_exit -ne 0 || -z "$resp" ]]; then
    echo "{\"success\":false,\"errors\":[{\"message\":\"Network error (HTTP ${http_code}, exit ${curl_exit})\"}]}"
    return
  fi
  echo "$resp"
}

cf_put() {
  local endpoint="$1"
  local data="$2"
  local tmpfile; tmpfile=$(mktemp)
  local http_code curl_exit
  http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" -X PUT "${CF_API}${endpoint}" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" \
    --data "$data" 2>/dev/null)
  curl_exit=$?
  local resp; resp=$(cat "$tmpfile" 2>/dev/null || echo "")
  rm -f "$tmpfile"
  if [[ $curl_exit -ne 0 || -z "$resp" ]]; then
    echo "{\"success\":false,\"errors\":[{\"message\":\"Network error (HTTP ${http_code}, exit ${curl_exit})\"}]}"
    return
  fi
  echo "$resp"
}

cf_delete() {
  local endpoint="$1"
  local tmpfile; tmpfile=$(mktemp)
  local http_code curl_exit
  http_code=$(curl -s -o "$tmpfile" -w "%{http_code}" -X DELETE "${CF_API}${endpoint}" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    -H "Content-Type: application/json" 2>/dev/null)
  curl_exit=$?
  local resp; resp=$(cat "$tmpfile" 2>/dev/null || echo "")
  rm -f "$tmpfile"
  if [[ $curl_exit -ne 0 || -z "$resp" ]]; then
    echo "{\"success\":false,\"errors\":[{\"message\":\"Network error (HTTP ${http_code}, exit ${curl_exit})\"}]}"
    return
  fi
  echo "$resp"
}

cf_post_multipart() {
  local endpoint="$1"
  shift
  curl -sf -X POST "${CF_API}${endpoint}" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    "$@" 2>/dev/null \
    || echo '{"success":false,"errors":[{"message":"Request failed"}]}'
}

cf_check() {
  local resp="$1"
  echo "$resp" | jq -e '.success == true' &>/dev/null
}

cf_errors() {
  local resp="$1"
  echo "$resp" | jq -r '.errors[]?.message // "Unknown error"' 2>/dev/null
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# WORKERS MANAGEMENT
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

list_workers() {
  header "Workers"
  require_account || return
  # Diagnostic: confirm token and account ID are loaded
  if [[ -z "$CF_ACCOUNT_ID" ]]; then
    error "Account ID is empty — try Settings → Switch account to reload."
    press_enter; return
  fi
  echo -e "${DM}  Account ID: ${CF_ACCOUNT_ID}${NC}"
  echo -e "${DM}  Token set:  $([ -n "$CF_TOKEN" ] && echo "yes (${#CF_TOKEN} chars)" || echo "NO")${NC}\n"
  echo -e "${C}Fetching workers...${NC}\n"
  local resp
  resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/workers/scripts")
  # DEBUG: show raw response
  echo -e "${DM}Raw API response:${NC}"
  echo "$resp" | head -5
  echo ""
  if ! cf_check "$resp"; then
    local errmsg
    errmsg=$(cf_errors "$resp")
    error "$errmsg"
    # Detect expired/invalid token
    if echo "$errmsg" | grep -qi "unknown user\|invalid token\|token expired\|10000\|authentication\|authorization"; then
      warn "Your session token may have expired. Re-add this account via Settings → Add account."
    fi
    press_enter; return
  fi
  local count
  count=$(echo "$resp" | jq '.result | length')
  if [[ "$count" -eq 0 ]]; then
    info "No workers found in this account."
    press_enter; return
  fi
  echo -e "${W}Found ${C}${count}${W} worker(s):${NC}\n"
  echo "$resp" | jq -r '.result[] | "  \(.id)  \(if .modified_on then "  last modified: "+(.modified_on[:10]) else "" end)"' 2>/dev/null
  echo ""
  press_enter
}

# List workers across EVERY stored account at once, fetching them all
# concurrently (one background request per account) instead of one at a
# time — much faster when you have several Cloudflare accounts.
list_workers_all() {
  header "Workers — All Accounts"

  local -a accounts
  mapfile -t accounts < <(list_accounts)
  if [[ ${#accounts[@]} -eq 0 ]]; then
    warn "No accounts stored."
    press_enter; return
  fi

  echo -e "${C}Fetching workers from ${#accounts[@]} account(s) concurrently...${NC}\n"

  local tmpdir
  tmpdir=$(mktemp -d)
  fetch_all_accounts "$tmpdir" "/workers/scripts"

  local total=0 acct resp count
  for acct in "${accounts[@]}"; do
    echo -e "${BLD}${C}━━━  Account: ${G}${acct}${C}  ━━━${NC}"
    resp=$(cat "$tmpdir/${acct}.json" 2>/dev/null || echo '{}')
    if ! cf_check "$resp"; then
      warn "  Could not fetch workers: $(cf_errors "$resp")"
      echo ""
      continue
    fi
    # Populate persistent cache as a side-effect of the listing
    cache_put "$acct" "workers" "$resp"
    count=$(echo "$resp" | jq '.result | length' 2>/dev/null || echo 0)
    if [[ "$count" -eq 0 ]]; then
      echo -e "  ${DM}(no workers)${NC}\n"
      continue
    fi
    total=$((total + count))
    echo "$resp" | jq -r '.result[] | "  \(.id)\(if .modified_on then "    last modified: "+(.modified_on[:10]) else "" end)"' 2>/dev/null
    echo ""
  done
  rm -rf "$tmpdir"

  echo -e "${W}Total workers across ${#accounts[@]} account(s): ${C}${total}${NC}"
  press_enter
}

view_worker_code() {
  header "View Worker Code"
  require_account || return
  local name
  name=$(select_worker "Select worker to view") || { press_enter; return; }
  echo ""
  local resp
  resp=$(curl -s -X GET "${CF_API}/accounts/${CF_ACCOUNT_ID//[[:space:]]/}/workers/scripts/${name}" \
    -H "Authorization: Bearer ${CF_TOKEN//[[:space:]]/}" 2>/dev/null || echo "")
  [[ -z "$resp" ]] && error "Could not fetch worker '$name'." && press_enter && return
  mkdir -p "$WORKERS_DIR"
  local file="$WORKERS_DIR/${name}.js"
  echo "$resp" > "$file"
  echo -e "${G}Worker code saved to:${NC} $file\n"
  divider
  head -60 "$file"
  divider
  echo -e "\n${DM}Full file: $file${NC}"
  press_enter
}

edit_worker() {
  header "Edit Worker"
  require_account || return
  local name
  name=$(select_worker "Select worker to edit") || { press_enter; return; }
  echo ""
  mkdir -p "$WORKERS_DIR"
  local file="$WORKERS_DIR/${name}.js"
  if [[ ! -f "$file" ]]; then
    echo -e "${Y}Fetching current code from Cloudflare...${NC}"
    local tmpfile="${TMPDIR:-$CONFIG_DIR}/dl_resp"
    local http_code
    http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" \
      -X GET "${CF_API}/accounts/${CF_ACCOUNT_ID//[[:space:]]/}/workers/scripts/${name}" \
      -H "Authorization: Bearer ${CF_TOKEN//[[:space:]]/}" 2>/dev/null)
    if [[ "$http_code" == "200" ]]; then
      # DEBUG: show first 3 lines to diagnose response format
      echo -e "${DM}Download response preview:${NC}"
      head -3 "$tmpfile"
      echo ""
      local first_byte
      first_byte=$(head -c1 "$tmpfile" 2>/dev/null)
      if [[ "$first_byte" == "{" ]]; then
        # Got JSON — likely an error or the API returned metadata instead of source
        local api_err
        api_err=$(cat "$tmpfile" | jq -r '.errors[0].message // "unexpected JSON response"' 2>/dev/null)
        rm -f "$tmpfile"
        error "Could not download worker source: $api_err"
        error "Creating local template instead — deploy will overwrite the live worker."
        write_fallback_template "$file" "$name"
      elif [[ "$first_byte" == "-" ]]; then
        # Multipart response — extract the first JS part
        grep -v '^--\|^Content-\|^$' "$tmpfile" > "$file" 2>/dev/null
        rm -f "$tmpfile"
        success "Downloaded (extracted from multipart) to $file"
      else
        # Plain JS
        cp "$tmpfile" "$file"
        rm -f "$tmpfile"
        success "Downloaded to $file"
      fi
    else
      rm -f "$tmpfile"
      warn "Could not fetch worker (HTTP ${http_code}) — creating local template."
      write_fallback_template "$file" "$name"
    fi
  fi
  local editor="${EDITOR:-nano}"
  command -v nano &>/dev/null && editor="nano"
  command -v vi &>/dev/null && editor="${EDITOR:-vi}"
  echo -e "${C}Opening with ${editor}...${NC}"
  sleep 0.5
  "$editor" "$file"
  echo -e "\n${W}Deploy changes now?${NC}"
  select choice in "Deploy to Cloudflare" "Save locally only" "Discard changes"; do
    case $REPLY in
      1) deploy_worker_file "$name" "$file"; break ;;
      2) success "Changes saved locally at $file"; break ;;
      3) rm -f "$file"; info "Discarded."; break ;;
    esac
  done
  press_enter
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# POST-DEPLOY BINDINGS WIZARD
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Called after a successful deploy. Offers to set up KV, D1, R2,
# env vars, and secrets for the newly deployed worker.
# Skipped automatically when running non-interactively (--auto-deploy).
post_deploy_bindings_prompt() {
  local worker="$1"
  # Non-interactive guard: skip if stdin is not a terminal
  [[ ! -t 0 ]] && return 0

  echo ""
  echo -e "${BLD}${C}━━━  Post-Deploy Bindings Wizard  ━━━${NC}"
  echo -e "${DM}Worker '${BLD}${worker}${DM}' was deployed. Would you like to configure bindings now?${NC}"
  echo -ne "${W}Set up bindings? [y/N]:${NC} "
  local ans
  read -r ans
  [[ ! "$ans" =~ ^[Yy]$ ]] && return 0

  while true; do
    echo ""
    echo -e "${BLD}${W}Bindings for '${C}${worker}${W}':${NC}"
    echo -e "  ${C}kv${NC}. ${B}Add KV namespace binding${NC}"
    echo -e "  ${C}d1${NC}. ${M}Add D1 database binding${NC}"
    echo -e "  ${C}r2${NC}. ${G}Add R2 bucket binding${NC}"
    echo -e "  ${C}dq${NC}. ${Y}Add Queue binding${NC}"
    echo -e "  ${C}do${NC}. ${M}Add Durable Object binding${NC}"
    echo -e "  ${C}ev${NC}. ${C}Add plain env variable${NC}"
    echo -e "  ${C}sc${NC}. ${Y}Add secret${NC}"
    echo -e "  ${C}ls${NC}. ${DM}List current bindings${NC}"
    echo -e "  ${C}done${NC}. Finish"
    echo -ne "\n${W}Choice:${NC} "
    local choice
    read -r choice
    case "$choice" in
      kv)
        _post_deploy_add_kv "$worker"
        ;;
      d1)
        _post_deploy_add_d1 "$worker"
        ;;
      r2)
        _post_deploy_add_r2 "$worker"
        ;;
      dq)
        _post_deploy_add_queue "$worker"
        ;;
      do)
        _post_deploy_add_do "$worker"
        ;;
      ev)
        _post_deploy_add_env "$worker"
        ;;
      sc)
        _post_deploy_add_secret "$worker"
        ;;
      ls)
        echo ""
        local bindings
        bindings=$(_env_get_bindings "$worker") || continue
        echo -e "${BLD}${W}Current bindings for '${C}${worker}${W}':${NC}\n"
        local total
        total=$(echo "$bindings" | jq 'length')
        if [[ "$total" -eq 0 ]]; then
          echo -e "  ${DM}(none yet)${NC}"
        else
          echo "$bindings" | jq -r '.[] | "  [\(.type)] \(.name)"' 2>/dev/null \
            | while IFS= read -r line; do echo -e "  ${C}${line#  }${NC}"; done
        fi
        echo ""
        ;;
      done|d|"")
        echo -e "\n${G}Bindings configured. All done!${NC}"
        break
        ;;
      *)
        warn "Invalid option."
        ;;
    esac
  done
}

# post_deploy_bindings_auto WORKER PREFETCHED_BINDINGS_JSON
# Re-applies bindings that were snapshotted BEFORE the deploy so the
# deploy PUT cannot wipe them before we read them.
# secret_text bindings are preserved; _env_put_bindings strips ones with
# no text value so live secrets on the server are left untouched.
post_deploy_bindings_auto() {
  local worker="$1"
  local bindings="${2:-}"

  # Fall back to a live fetch if caller didn't prefetch (shouldn't happen)
  if [[ -z "$bindings" || "$bindings" == "[]" ]]; then
    bindings=$(_env_get_bindings "$worker" 2>/dev/null) || bindings="[]"
  fi

  local count
  count=$(printf '%s' "$bindings" | jq 'length' 2>/dev/null || echo 0)
  if [[ "$count" -eq 0 ]]; then
    info "No existing bindings to restore."
    return 0
  fi
  echo -e "${C}Re-applying ${count} existing binding(s)...${NC}"
  if _env_put_bindings "$worker" "$bindings"; then
    success "Bindings restored automatically."
    log "Auto-rebind: worker=$worker count=$count"
  else
    warn "Auto-rebind failed — run the bindings wizard manually if needed."
  fi
}

# Called after a successful deploy. Offers to view/toggle the worker's
# workers.dev domain. Skipped automatically when running non-interactively
# (--auto-deploy).
post_deploy_subdomain_prompt() {
  local worker="$1"
  # Non-interactive guard: skip if stdin is not a terminal
  [[ ! -t 0 ]] && return 0

  echo ""
  echo -ne "${W}Manage workers.dev domain for '${C}${worker}${W}'? [y/N]:${NC} "
  local ans
  read -r ans
  [[ ! "$ans" =~ ^[Yy]$ ]] && return 0

  echo ""
  _toggle_workers_dev_domain "$worker"
}

# ── Inline helpers called by the wizard ──────────────────────────

_post_deploy_add_kv() {
  local worker="$1"
  local picked
  picked=$(select_kv_namespace "Select KV namespace to bind" "$worker") || return
  local ns_id ns_title
  split_pipe ns_id ns_title "$picked"
  echo ""
  local binding_name
  prompt_binding_name binding_name "Binding name = variable name in worker code (e.g. MY_KV → env.MY_KV.get(key))" || return
  local bindings
  bindings=$(_env_get_bindings "$worker") || return
  binding_dedup_replace bindings "$binding_name" || return
  local updated
  updated=$(echo "$bindings" | jq \
    --arg n "$binding_name" --arg id "$ns_id" \
    '. + [{type:"kv_namespace", name:$n, namespace_id:$id}]')
  if _env_put_bindings "$worker" "$updated"; then
    success "KV '${ns_title}' bound as ${C}env.${binding_name}${NC}"
    log "Post-deploy KV binding: worker=$worker name=$binding_name ns=$ns_id"
  fi
}

_post_deploy_add_d1() {
  local worker="$1"
  local picked
  picked=$(select_d1_database "Select D1 database to bind" "$worker") || return
  local db_uuid db_name
  split_pipe db_uuid db_name "$picked"
  echo ""
  local binding_name
  prompt_binding_name binding_name "Binding name = variable name in worker code (e.g. MY_DB → env.MY_DB.prepare(sql))" || return
  local bindings
  bindings=$(_env_get_bindings "$worker") || return
  binding_dedup_replace bindings "$binding_name" || return
  local updated
  updated=$(echo "$bindings" | jq \
    --arg n "$binding_name" --arg id "$db_uuid" --arg dbn "$db_name" \
    '. + [{type:"d1", name:$n, id:$id, database_name:$dbn}]')
  if _env_put_bindings "$worker" "$updated"; then
    success "D1 '${db_name}' bound as ${C}env.${binding_name}${NC}"
    log "Post-deploy D1 binding: worker=$worker name=$binding_name db=$db_uuid"
  fi
}

_post_deploy_add_r2() {
  local worker="$1"
  local bucket
  bucket=$(select_r2_bucket "Select R2 bucket to bind" "$worker") || return
  echo ""
  local binding_name
  prompt_binding_name binding_name "Binding name = variable name in worker code (e.g. MY_BUCKET → env.MY_BUCKET.put(key,val))" || return
  local bindings
  bindings=$(_env_get_bindings "$worker") || return
  binding_dedup_replace bindings "$binding_name" || return
  local updated
  updated=$(echo "$bindings" | jq \
    --arg n "$binding_name" --arg bn "$bucket" \
    '. + [{type:"r2_bucket", name:$n, bucket_name:$bn}]')
  if _env_put_bindings "$worker" "$updated"; then
    success "R2 bucket '${bucket}' bound as ${C}env.${binding_name}${NC}"
    log "Post-deploy R2 binding: worker=$worker name=$binding_name bucket=$bucket"
  fi
}

_post_deploy_add_queue() {
  local worker="$1"
  # Fetch available queues from the API
  local resp
  if ! resp=$(cache_get "$ACTIVE_ACCOUNT_NAME" "queues" 2>/dev/null); then
    resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/queues")
    if cf_check "$resp"; then
      cache_put "$ACTIVE_ACCOUNT_NAME" "queues" "$resp"
    fi
  fi
  if ! cf_check "$resp"; then
    error "Could not fetch queues: $(cf_errors "$resp")"
    return
  fi
  local count
  count=$(echo "$resp" | jq '.result | length')
  local -a q_ids q_names
  mapfile -t q_ids   < <(echo "$resp" | jq -r '.result[].queue_id')
  mapfile -t q_names < <(echo "$resp" | jq -r '.result[].queue_name')
  echo -e "\n${W}Available Queues:${NC}\n"
  echo -e "  ${G}n${NC}. ${BLD}+ Create new Queue${NC} ${DM}(suggested: ${worker})${NC}"
  if [[ "$count" -eq 0 ]]; then
    echo -e "  ${DM}(no existing queues)${NC}"
  fi
  for i in "${!q_ids[@]}"; do
    printf "  ${C}%d${NC}. %-35s ${DM}%s${NC}\n" "$((i+1))" "${q_names[$i]}" "${q_ids[$i]}"
  done
  echo -ne "\n${W}Choice (0=cancel, n=new):${NC} "
  local sel
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return
  local queue_name
  if [[ "$sel" == "n" || "$sel" == "N" ]]; then
    read -rp "$(echo -e "${W}New queue name${NC} ${DM}[${worker}]:${NC} ")" queue_name
    [[ -z "$queue_name" ]] && queue_name="$worker"
    echo -ne "${C}Creating queue '${queue_name}'...${NC}"
    local create_resp
    create_resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/queues" "{\"queue_name\":\"$queue_name\"}")
    if ! cf_check "$create_resp"; then
      echo -e " ${SYM_ERR}"
      error "$(cf_errors "$create_resp")"
      return
    fi
    echo -e " ${SYM_OK}"
    log "Queue created (inline): $queue_name"
    cache_invalidate "$ACTIVE_ACCOUNT_NAME" "queues"
  else
    local idx=$((sel-1))
    if [[ $idx -lt 0 || $idx -ge ${#q_ids[@]} ]]; then
      error "Invalid selection." && return
    fi
    queue_name="${q_names[$idx]}"
  fi

  echo ""
  echo -e "${DM}Binding name = variable in worker code (e.g. MY_QUEUE → env.MY_QUEUE.send(msg))${NC}"
  local binding_name
  prompt_binding_name binding_name || return
  local bindings
  bindings=$(_env_get_bindings "$worker") || return
  binding_dedup_replace bindings "$binding_name" || return
  local updated
  updated=$(echo "$bindings" | jq \
    --arg n "$binding_name" --arg qn "$queue_name" \
    '. + [{type:"queue", name:$n, queue_name:$qn}]')
  if _env_put_bindings "$worker" "$updated"; then
    success "Queue '${queue_name}' bound as ${C}env.${binding_name}${NC}"
    log "Post-deploy Queue binding: worker=$worker name=$binding_name queue=$queue_name"
  fi
}

_post_deploy_add_do() {
  local worker="$1"
  local resp
  if ! resp=$(cache_get "$ACTIVE_ACCOUNT_NAME" "do" 2>/dev/null); then
    resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/workers/durable_objects/namespaces")
    if cf_check "$resp"; then
      cache_put "$ACTIVE_ACCOUNT_NAME" "do" "$resp"
    fi
  fi
  if ! cf_check "$resp"; then
    error "Could not fetch Durable Object namespaces: $(cf_errors "$resp")"
    return
  fi
  local count
  count=$(echo "$resp" | jq '.result | length')
  local -a do_ids do_names do_classes do_scripts
  mapfile -t do_ids     < <(echo "$resp" | jq -r '.result[].id')
  mapfile -t do_names   < <(echo "$resp" | jq -r '.result[].name')
  mapfile -t do_classes < <(echo "$resp" | jq -r '.result[].class // ""')
  mapfile -t do_scripts < <(echo "$resp" | jq -r '.result[].script // ""')
  echo -e "\n${W}Durable Object Namespaces:${NC}\n"
  echo -e "  ${G}n${NC}. ${BLD}+ Create new Durable Object namespace${NC} ${DM}(suggested: ${worker})${NC}"
  if [[ "$count" -eq 0 ]]; then
    echo -e "  ${DM}(none found)${NC}"
  fi
  for i in "${!do_ids[@]}"; do
    printf "  ${C}%d${NC}. %-30s ${DM}class: %s  script: %s${NC}\n" \
      "$((i+1))" "${do_names[$i]}" "${do_classes[$i]}" "${do_scripts[$i]}"
  done
  echo -ne "\n${W}Choice (0=cancel, n=new):${NC} "
  local sel
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return
  local do_ns_id do_class do_script
  if [[ "$sel" == "n" || "$sel" == "N" ]]; then
    local do_name
    read -rp "$(echo -e "${W}New namespace name${NC} ${DM}[${worker}]:${NC} ")" do_name
    [[ -z "$do_name" ]] && do_name="$worker"
    read -rp "$(echo -e "${W}Class name in script:${NC} ")" do_class
    [[ -z "$do_class" ]] && info "Cancelled." && return
    do_script="$worker"
    echo -ne "${C}Creating Durable Object namespace '${do_name}'...${NC}"
    local create_resp
    create_resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/workers/durable_objects/namespaces" \
      "{\"name\":\"$do_name\",\"script\":\"$do_script\",\"class\":\"$do_class\"}")
    if ! cf_check "$create_resp"; then
      echo -e " ${SYM_ERR}"
      error "$(cf_errors "$create_resp")"
      return
    fi
    echo -e " ${SYM_OK}"
    do_ns_id=$(echo "$create_resp" | jq -r '.result.id')
    log "Durable Object namespace created (inline): $do_name ($do_ns_id)"
    cache_invalidate "$ACTIVE_ACCOUNT_NAME" "do"
  else
    local idx=$((sel-1))
    if [[ $idx -lt 0 || $idx -ge ${#do_ids[@]} ]]; then
      error "Invalid selection." && return
    fi
    do_ns_id="${do_ids[$idx]}"
    do_class="${do_classes[$idx]}"
    do_script="${do_scripts[$idx]}"
  fi

  echo ""
  echo -e "${DM}Binding name = variable in worker code (e.g. MY_DO → env.MY_DO.get(id))${NC}"
  local binding_name
  prompt_binding_name binding_name || return
  local bindings
  bindings=$(_env_get_bindings "$worker") || return
  binding_dedup_replace bindings "$binding_name" || return
  local updated
  updated=$(echo "$bindings" | jq \
    --arg n "$binding_name" --arg id "$do_ns_id" \
    --arg cls "$do_class" --arg scr "$do_script" \
    '. + [{type:"durable_object_namespace", name:$n, namespace_id:$id, class_name:$cls, script_name:$scr}]')
  if _env_put_bindings "$worker" "$updated"; then
    success "Durable Object namespace bound as ${C}env.${binding_name}${NC}"
    log "Post-deploy DO binding: worker=$worker name=$binding_name ns=$do_ns_id"
  fi
}

_post_deploy_add_env() {
  local worker="$1"
  local var_name var_val
  read -rp "$(echo -e "${W}Variable name:${NC} ")" var_name
  [[ -z "$var_name" ]] && info "Cancelled." && return
  if ! [[ "$var_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    error "Invalid name. Letters, numbers, underscores only."
    return
  fi
  read -rp "$(echo -e "${W}Value:${NC} ")" var_val
  [[ -z "$var_val" ]] && info "Cancelled." && return
  local bindings
  bindings=$(_env_get_bindings "$worker") || return
  if echo "$bindings" | jq -e --arg n "$var_name" '.[] | select(.name==$n)' &>/dev/null; then
    warn "Binding '${var_name}' already exists."
    confirm "Replace it?" || return
    bindings=$(echo "$bindings" | jq --arg n "$var_name" '[.[] | select(.name != $n)]')
  fi
  local updated
  updated=$(echo "$bindings" | jq \
    --arg n "$var_name" --arg v "$var_val" \
    '. + [{type:"plain_text", name:$n, text:$v}]')
  if _env_put_bindings "$worker" "$updated"; then
    success "Variable '${BLD}${var_name}${NC}' set."
    log "Post-deploy env var: worker=$worker name=$var_name"
  fi
}

_post_deploy_add_secret() {
  local worker="$1"
  local secret_name secret_val
  read -rp "$(echo -e "${W}Secret name:${NC} ")" secret_name
  [[ -z "$secret_name" ]] && info "Cancelled." && return
  read -rsp "$(echo -e "${W}Secret value (hidden):${NC} ")" secret_val; echo
  [[ -z "$secret_val" ]] && info "Cancelled." && return
  local bindings
  bindings=$(_env_get_bindings "$worker") || return
  local updated
  updated=$(echo "$bindings" | jq --arg k "$secret_name" '[.[] | select(.name != $k)]')
  updated=$(echo "$updated" | jq \
    --arg k "$secret_name" --arg v "$secret_val" \
    '. + [{type:"secret_text", name:$k, text:$v}]')
  if _env_put_bindings "$worker" "$updated"; then
    success "Secret '${BLD}${secret_name}${NC}' saved."
    log "Post-deploy secret: worker=$worker name=$secret_name"
  fi
}

# _deploy_worker_core NAME FILE SILENT [BIND_MODE]
# Core deploy logic shared by deploy_worker_file (interactive) and
# _deploy_worker_file_silent (batch).  SILENT=true skips the post-deploy
# prompts and uses a compact one-line status instead of a progress bar.
# BIND_MODE="_auto" re-applies existing bindings silently instead of
# launching the interactive wizard.
# Returns 0 on success, 1 on failure.
_deploy_worker_core() {
  local name="$1"
  local file="$2"
  local silent="${3:-false}"
  local bind_mode="${4:-}"
  local prefetched_bindings="${5:-}"

  [[ ! -f "$file" ]] && error "File not found: $file" && return 1

  local token="${CF_TOKEN//[[:space:]]/}"
  local account_id="${CF_ACCOUNT_ID//[[:space:]]/}"

  # module_name must match between metadata main_module and the curl form field name.
  # Use the actual source file's basename so worker.js or any picked file works correctly.
  local module_name
  module_name=$(basename "$file")
  local metadata
  metadata=$(jq -n \
    --arg main "$module_name" \
    --arg compat "$(date -u +%Y-%m-%d)" \
    '{main_module: $main, compatibility_date: $compat, compatibility_flags: []}')

  local tmpfile
  tmpfile=$(mktemp)

  if [[ "$silent" == "true" ]]; then
    # Batch mode: plain curl, no progress display
    local http_code
    http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" \
      -X PUT "${CF_API}/accounts/${account_id}/workers/scripts/${name}" \
      -H "Authorization: Bearer ${token}" \
      -F "metadata=${metadata};type=application/json" \
      -F "${module_name}=@${file};type=application/javascript+module" 2>/dev/null)
    local curl_exit=$?
    local resp
    resp=$(cat "$tmpfile" 2>/dev/null || echo "")
    rm -f "$tmpfile"
    if [[ $curl_exit -ne 0 || -z "$resp" ]]; then
      error "Deploy failed (HTTP ${http_code}, curl exit ${curl_exit})"
      return 1
    fi
    if cf_check "$resp"; then
      backup_worker "$name" "$file"
      cache_invalidate "$ACTIVE_ACCOUNT_NAME" "workers"
      cache_invalidate "$ACTIVE_ACCOUNT_NAME" "bindings/${name}"
      return 0
    else
      echo "$resp" | jq -r '.errors[]? | "  [\(.code)] \(.message)"' 2>/dev/null
      return 1
    fi

  else
    # Interactive mode: animated progress bar while curl uploads
    local file_bytes
    file_bytes=$(wc -c < "$file" 2>/dev/null || echo 0)
    local file_kb=$(( file_bytes / 1024 ))
    echo -e "\n${C}Deploying worker '${BLD}${name}${NC}${C}'  ${DM}(${file_kb} KB)${NC}"

    # Bar configuration
    local bar_width=28
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local stages=(
      "Connecting...       "
      "Uploading script... "
      "Processing...       "
      "Finalising...       "
    )
    # Approximate time budget per stage (tenths of a second).
    # Stages 0-1 are upload-bound; 2-3 are server-side.
    local -a budgets=(5 30 10 5)

    # Run curl in the background, writing http_code to a side file
    local code_file
    code_file=$(mktemp)
    (
      curl -s -w "%{http_code}" -o "$tmpfile" \
        -X PUT "${CF_API}/accounts/${account_id}/workers/scripts/${name}" \
        -H "Authorization: Bearer ${token}" \
        -F "metadata=${metadata};type=application/json" \
        -F "${module_name}=@${file};type=application/javascript+module" 2>/dev/null \
        > "$code_file"
    ) &
    local curl_pid=$!

    # Animate while curl runs
    local spin_i=0 stage=0 stage_tick=0 filled=0
    tput civis 2>/dev/null || true
    while kill -0 "$curl_pid" 2>/dev/null; do
      # Advance stage on budget expiry
      if [[ $stage_tick -ge ${budgets[$stage]:-10} && $stage -lt 3 ]]; then
        stage=$(( stage + 1 ))
        stage_tick=0
        filled=$(( bar_width * stage / 4 ))
      fi
      stage_tick=$(( stage_tick + 1 ))

      local bar=""
      local f
      for (( f=0; f<bar_width; f++ )); do
        if [[ $f -lt $filled ]]; then
          bar+="█"
        elif [[ $f -eq $filled ]]; then
          bar+="${frames[$spin_i]}"
        else
          bar+="░"
        fi
      done
      spin_i=$(( (spin_i + 1) % ${#frames[@]} ))

      printf "\r  ${C}[%s]${NC}  %s" "$bar" "${stages[$stage]}"
      sleep 0.1
    done
    wait "$curl_pid" 2>/dev/null
    local curl_exit=$?

    tput cnorm 2>/dev/null || true
    printf "\r%80s\r" " "   # clear the progress line

    local http_code
    http_code=$(cat "$code_file" 2>/dev/null || echo "000")
    rm -f "$code_file"
    local resp
    resp=$(cat "$tmpfile" 2>/dev/null || echo "")
    rm -f "$tmpfile"

    if [[ $curl_exit -ne 0 || -z "$resp" ]]; then
      error "Deployment failed: curl error (HTTP ${http_code}, exit ${curl_exit})"
      return 1
    fi
    if cf_check "$resp"; then
      success "Worker '${BLD}${name}${NC}' deployed!"
      log "Worker deployed: $name from $file"
      backup_worker "$name" "$file"
      cache_invalidate "$ACTIVE_ACCOUNT_NAME" "workers"
      cache_invalidate "$ACTIVE_ACCOUNT_NAME" "bindings/${name}"
      if [[ "$bind_mode" == "_auto" ]]; then
        post_deploy_bindings_auto "$name" "$prefetched_bindings"
      else
        post_deploy_bindings_prompt "$name"
      fi
      post_deploy_subdomain_prompt "$name"
    else
      error "Deployment failed (HTTP ${http_code}):"
      echo "$resp" | jq -r '.errors[]? | "  [\(.code)] \(.message)"' 2>/dev/null \
        || echo "  $resp" | head -3
      return 1
    fi
  fi
}

# Public-facing wrappers
deploy_worker_file()         { _deploy_worker_core "$1" "$2" false; }
_deploy_worker_file_silent() { _deploy_worker_core "$1" "$2" true;  }

deploy_worker() {
  header "Deploy Worker"
  require_account || return

  # ── Step 1: Worker name ────────────────────────────────────────────
  local name
  name=$(select_worker "Select existing worker (or 0 to create new)") || {
    echo ""
    prompt_worker_name name
  }
  echo ""

  # ── Step 2: Binding mode ───────────────────────────────────────────
  # Auto = re-apply existing bindings silently after deploy (no wizard).
  # Manual = run the interactive post-deploy bindings wizard as usual.
  # Bindings are snapshotted NOW (before deploy) so the deploy PUT
  # cannot wipe them before we have a chance to read them.
  local binding_mode="auto"
  echo -ne "${W}Binding mode${NC} ${DM}[Enter=auto, m=manual]:${NC} "
  local bm_choice
  read -r bm_choice
  [[ "$bm_choice" == "m" || "$bm_choice" == "M" ]] && binding_mode="manual"
  echo ""

  local prefetched_bindings=""
  if [[ "$binding_mode" == "auto" ]]; then
    echo -e "${DM}Snapshotting current bindings...${NC}"
    prefetched_bindings=$(_env_get_bindings "$name" 2>/dev/null) || prefetched_bindings="[]"
    local _pbc
    _pbc=$(printf '%s' "$prefetched_bindings" | jq 'length' 2>/dev/null || echo 0)
    echo -e "${DM}  ${_pbc} binding(s) captured.${NC}"
    echo ""
  fi

  # ── Step 3: Source file ────────────────────────────────────────────
  echo -e "${W}Source:${NC}"
  echo -e "  ${C}1${NC}. Pick from ${CFWORKER_DIR}"
  echo -e "  ${C}2${NC}. Workers directory ($WORKERS_DIR/${name}.js)"
  echo -e "  ${C}3${NC}. Manual file path"
  echo -e "  ${C}4${NC}. Paste code inline"
  echo -ne "${W}Choice [1-4]:${NC} "
  local src_choice
  read -r src_choice

  local file
  case "$src_choice" in
    1)
      file=$(pick_cfworker_file) || { press_enter; return; }
      ;;
    2)
      file="$WORKERS_DIR/${name}.js"
      [[ ! -f "$file" ]] && error "Not found: $file" && press_enter && return
      ;;
    3)
      read -rp "$(echo -e "${W}File path:${NC} ")" file
      [[ ! -f "$file" ]] && error "File not found." && press_enter && return
      ;;
    4)
      file="$WORKERS_DIR/${name}_inline.js"
      mkdir -p "$WORKERS_DIR"
      paste_code_to_file "$file"
      ;;
    *)
      warn "Invalid choice." && press_enter && return
      ;;
  esac

  if [[ "$binding_mode" == "auto" ]]; then
    _deploy_worker_core "$name" "$file" false "_auto" "$prefetched_bindings"
  else
    deploy_worker_file "$name" "$file"
  fi
  press_enter
}

create_worker() {
  header "Create New Worker"
  require_account || return

  # ── Step 1: Worker name ────────────────────────────────────────────
  local name
  prompt_worker_name name

  # ── Step 2: Source file ────────────────────────────────────────────
  echo ""
  echo -e "${W}Worker source:${NC}"
  echo -e "  ${C}1${NC}. Pick from ${CFWORKER_DIR}"
  echo -e "  ${C}2${NC}. Use generated template"
  echo -ne "${W}Choice [1/2]:${NC} "
  local src_choice
  read -r src_choice

  mkdir -p "$WORKERS_DIR"
  local file="$WORKERS_DIR/${name}.js"

  if [[ "$src_choice" == "1" ]]; then
    local picked
    picked=$(pick_cfworker_file) || { press_enter; return; }
    cp "$picked" "$file"
    success "Copied $(basename "$picked") → $file"
  else
    # Generate template
    write_worker_template "$file" "$name"
    success "Template created at $file"
    confirm "Open in editor now?" && "${EDITOR:-nano}" "$file"
  fi

  confirm "Deploy to Cloudflare?" && { deploy_worker_file "$name" "$file"; _worker_cache_clear; }
  press_enter
}

rollback_worker() {
  header "Rollback Worker"
  require_account || return
  local name
  name=$(select_worker "Select worker to roll back") || { press_enter; return; }
  echo ""

  local backup_dir="$BACKUPS_DIR/workers/$name"
  if [[ ! -d "$backup_dir" ]] || [[ -z "$(ls -A "$backup_dir" 2>/dev/null)" ]]; then
    warn "No local backups found for '$name'."
    info "Checking Cloudflare deployments..."
    local resp
    resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${name}/deployments")
    if cf_check "$resp"; then
      echo -e "\n${W}Recent deployments:${NC}"
      echo "$resp" | jq -r '.result.deployments[]? | "  \(.id)  \(.created_on[:19])"' 2>/dev/null | head -10
      echo -ne "\n${W}Enter deployment ID to roll back to:${NC} "
      read -r dep_id
      [[ -z "$dep_id" ]] && return
      local rollback_resp
      rollback_resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${name}/deployments" \
        "{\"id\":\"$dep_id\"}")
      if cf_check "$rollback_resp"; then
        success "Rolled back to deployment $dep_id"
        log "Rollback: $name -> $dep_id"
      else
        error "$(cf_errors "$rollback_resp")"
      fi
    else
      error "Could not fetch deployments."
    fi
    press_enter; return
  fi

  echo -e "\n${W}Local backups for '${name}':${NC}\n"
  local -a backups
  mapfile -t backups < <(ls -t "$backup_dir" 2>/dev/null)
  for i in "${!backups[@]}"; do
    echo -e "  ${C}$((i+1))${NC}. ${backups[$i]}"
  done
  echo -ne "\n${W}Select backup to restore (0=cancel):${NC} "
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return
  local idx=$((sel-1))
  [[ $idx -lt 0 || $idx -ge ${#backups[@]} ]] && error "Invalid." && press_enter && return
  local backup_file="$backup_dir/${backups[$idx]}"
  confirm "Roll back '${name}' to '${backups[$idx]}'?" || return
  deploy_worker_file "$name" "$backup_file"
  press_enter
}

backup_worker() {
  local name="$1"
  local file="$2"
  local backup_dir="$BACKUPS_DIR/workers/$name"
  mkdir -p "$backup_dir"
  local ts
  ts=$(date '+%Y%m%d_%H%M%S')
  cp "$file" "$backup_dir/${ts}.js"
  local count
  count=$(ls "$backup_dir" | wc -l)
  if [[ $count -gt 10 ]]; then
    ls -t "$backup_dir" | tail -n +11 | xargs -I{} rm "$backup_dir/{}" 2>/dev/null || true
  fi
}

tail_worker_logs() {
  header "Worker Logs (Real-time)"
  require_account || return
  local name
  name=$(select_worker "Select worker to tail") || { press_enter; return; }
  echo ""

  local token="$CF_TOKEN"
  local account_id="$CF_ACCOUNT_ID"

  # ── Step 1: Create a tail session (POST /tails) ──────────────────
  local tail_resp tail_id ws_url
  tail_resp=$(curl -sf -X POST \
    "https://api.cloudflare.com/client/v4/accounts/${account_id}/workers/scripts/${name}/tails" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d '{}' 2>/dev/null) || {
      error "Failed to create tail session. Check your token and worker name."
      press_enter
      return
    }

  tail_id=$(echo "$tail_resp" | jq -r '.result.id // empty')
  ws_url=$(echo  "$tail_resp" | jq -r '.result.url // empty')

  if [[ -z "$tail_id" || -z "$ws_url" ]]; then
    error "API did not return a tail session."
    echo "$tail_resp" | jq . 2>/dev/null
    press_enter
    return
  fi

  # ── Cleanup helper: DELETE the tail session on exit ───────────────
  _cleanup_tail() {
    curl -sf -X DELETE \
      "https://api.cloudflare.com/client/v4/accounts/${account_id}/workers/scripts/${name}/tails/${tail_id}" \
      -H "Authorization: Bearer ${token}" &>/dev/null || true
  }
  trap '_cleanup_tail' RETURN INT TERM

  # ── Step 2: Stream the WebSocket ─────────────────────────────────
  if ! command -v websocat &>/dev/null; then
    warn "websocat is required to stream logs but was not found."
    info "Install it in Termux with:  pkg install websocat"
    echo ""
    info "Tail WebSocket URL (connect manually if needed):"
    echo -e "  ${DM}${ws_url}${NC}"
    press_enter
    return
  fi

  echo -e "${Y}Streaming logs for ${W}${name}${Y}... press Ctrl+C to stop${NC}\n"

  # Cloudflare's tail WebSocket requires the "tunnel" subprotocol header.
  # We also disable pipefail locally so a websocat disconnect doesn't kill
  # the whole script, and we let stderr through so errors are visible.
  local _ws_exit=0
  set +o pipefail
  websocat --no-close -t \
    --header "Sec-WebSocket-Protocol: tunnel" \
    "$ws_url" 2>&1 | while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      # If websocat printed an error line (not JSON), show it in red
      if ! echo "$line" | jq -e . &>/dev/null; then
        echo -e "${R}[websocat] ${line}${NC}"
        continue
      fi
      echo "$line" | jq -r '
        if .outcome then
          ( ( .eventTimestamp // 0 ) / 1000 | strftime("%H:%M:%S") ) as $ts |
          ( .outcome | ascii_upcase )                                  as $oc |
          ( .event.request.url // "" )                                 as $url |
          ( [ .logs[]? | .message[]? | tostring ] | join(" ") )        as $logs |
          ( [ .exceptions[]? | "\(.name): \(.message)" ] | join(" ") ) as $excs |
          "\($ts) \($oc) \($url)" +
          ( if $logs != "" then "\n         LOG: \($logs)" else "" end ) +
          ( if $excs != "" then "\n         EXC: \($excs)" else "" end )
        else
          ( . | tostring )
        end' 2>/dev/null || echo "$line"
    done
  _ws_exit=$?
  set -o pipefail

  if [[ $_ws_exit -ne 0 ]]; then
    echo ""
    warn "Log stream ended (exit code: ${_ws_exit})."
  fi

  trap - RETURN INT TERM
  _cleanup_tail
  press_enter
}

worker_routes() {
  header "Worker Routes"
  require_account || return
  [[ -z "$CF_ZONE_ID" ]] && read -rp "$(echo -e "${W}Zone ID:${NC} ")" CF_ZONE_ID
  local resp
  resp=$(cf_get "/zones/${CF_ZONE_ID}/workers/routes")
  if cf_check "$resp"; then
    echo -e "${W}Routes:${NC}\n"
    echo "$resp" | jq -r '.result[]? | "  Pattern: \(.pattern)\n  Worker:  \(.script // "(none)")\n  ID:      \(.id)\n"' 2>/dev/null
  else
    error "$(cf_errors "$resp")"
  fi
  press_enter
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# WORKER CRON TRIGGERS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Replace the full set of cron schedules for a worker.
# Cloudflare's schedules endpoint is a full replace (PUT), so callers
# pass the complete desired list of cron expressions.
#   _cron_push worker [cron1 cron2 ...]
_cron_push() {
  local worker="$1"; shift
  local payload
  if [[ $# -eq 0 ]]; then
    payload="[]"
  else
    payload=$(printf '%s\n' "$@" | jq -R -s 'split("\n") | map(select(length > 0)) | map({cron: .})')
  fi
  local resp
  resp=$(cf_put "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${worker}/schedules" "$payload")
  if cf_check "$resp"; then
    success "Cron triggers updated."
    return 0
  else
    error "$(cf_errors "$resp")"
    return 1
  fi
}

# _cron_prompt_time HH_VAR MM_VAR
# Prompts for a HH:MM (24h) time and stores the numeric parts (no leading
# zero ambiguity) into the two namerefs. Returns 1 on invalid input.
_cron_prompt_time() {
  local -n _ct_h="$1" _ct_m="$2"
  echo -ne "${W}Time (HH:MM, 24h, ${BLD}UTC${NC}${W}):${NC} " >&2
  local t; read -r t
  if [[ "$t" =~ ^([0-9]{1,2}):([0-9]{1,2})$ ]]; then
    local h=$((10#${BASH_REMATCH[1]})) m=$((10#${BASH_REMATCH[2]}))
    if (( h >= 0 && h <= 23 && m >= 0 && m <= 59 )); then
      _ct_h="$h"; _ct_m="$m"
      return 0
    fi
  fi
  error "Invalid time — expected HH:MM (e.g. 14:30)." >&2
  return 1
}

# _cron_prompt_dow DOW_VAR
_cron_prompt_dow() {
  local -n _cd_d="$1"
  echo -e "${DM}0=Sun 1=Mon 2=Tue 3=Wed 4=Thu 5=Fri 6=Sat${NC}" >&2
  echo -ne "${W}Day of week (0-6):${NC} " >&2
  local d; read -r d
  [[ "$d" =~ ^[0-6]$ ]] || { error "Invalid day — expected 0-6." >&2; return 1; }
  _cd_d="$d"
}

# Interactive cron expression builder so users don't have to hand-write
# "*/5 * * * *" syntax. Prompts go to stderr; the resulting cron expression
# (or empty) is printed to stdout. Returns 1 if cancelled/invalid.
_cron_builder() {
  echo -e "\n${W}Build a schedule:${NC}" >&2
  echo -e "  ${C}1${NC}. Every N minutes" >&2
  echo -e "  ${C}2${NC}. Every N hours" >&2
  echo -e "  ${C}3${NC}. Daily at a specific time" >&2
  echo -e "  ${C}4${NC}. Weekly on a specific day" >&2
  echo -e "  ${C}5${NC}. Monthly on a specific day" >&2
  echo -e "  ${C}6${NC}. ${DM}Custom (raw cron expression)${NC}" >&2
  echo -ne "\n${W}Choice (0=cancel):${NC} " >&2
  local choice; read -r choice

  local n hh mm dow dom cron=""
  case "$choice" in
    1)
      echo -ne "${W}Every how many minutes (1-59):${NC} " >&2
      read -r n
      [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 59 )) || { error "Invalid value — expected 1-59." >&2; return 1; }
      cron="*/${n} * * * *"
      ;;
    2)
      echo -ne "${W}Every how many hours (1-23):${NC} " >&2
      read -r n
      [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 23 )) || { error "Invalid value — expected 1-23." >&2; return 1; }
      cron="0 */${n} * * *"
      ;;
    3)
      _cron_prompt_time hh mm || return 1
      cron="${mm} ${hh} * * *"
      ;;
    4)
      _cron_prompt_time hh mm || return 1
      _cron_prompt_dow dow || return 1
      cron="${mm} ${hh} * * ${dow}"
      ;;
    5)
      _cron_prompt_time hh mm || return 1
      echo -ne "${W}Day of month (1-31):${NC} " >&2
      read -r dom
      [[ "$dom" =~ ^[0-9]+$ ]] && (( dom >= 1 && dom <= 31 )) || { error "Invalid value — expected 1-31." >&2; return 1; }
      cron="${mm} ${hh} ${dom} * *"
      ;;
    6)
      echo -e "${DM}Format: minute hour day-of-month month day-of-week${NC}" >&2
      echo -ne "${W}Cron expression:${NC} " >&2
      read -r cron
      [[ -z "$cron" ]] && return 1
      local -a _fields
      read -ra _fields <<< "$cron"
      if [[ ${#_fields[@]} -ne 5 ]]; then
        error "Invalid cron expression — expected 5 space-separated fields (minute hour dom month dow), got ${#_fields[@]}." >&2
        return 1
      fi
      ;;
    0|"") return 1 ;;
    *) error "Invalid choice." >&2; return 1 ;;
  esac

  echo -e "${DM}→ Generated: ${C}${cron}${NC} ${DM}(${NC}$(_cron_describe "$cron")${DM})${NC}" >&2
  printf '%s' "$cron"
}

# Translate a cron expression into a short human-readable description.
# Cloudflare evaluates Worker cron triggers in UTC. Falls back to
# "custom schedule" for expressions this doesn't recognize.
_cron_describe() {
  local cron="$1"
  local -a f
  read -ra f <<< "$cron"
  [[ ${#f[@]} -ne 5 ]] && { echo "custom schedule"; return; }
  local min="${f[0]}" hr="${f[1]}" dom="${f[2]}" mon="${f[3]}" dow="${f[4]}"

  # */N * * * *  → every N minutes
  if [[ "$min" =~ ^\*/([0-9]+)$ && "$hr" == "*" && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
    echo "every ${BASH_REMATCH[1]} minutes"
    return
  fi
  # 0 */N * * *  → every N hours
  if [[ "$min" == "0" && "$hr" =~ ^\*/([0-9]+)$ && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
    echo "every ${BASH_REMATCH[1]} hours"
    return
  fi
  # M H * * *  → daily at H:M UTC
  if [[ "$min" =~ ^[0-9]+$ && "$hr" =~ ^[0-9]+$ && "$dom" == "*" && "$mon" == "*" && "$dow" == "*" ]]; then
    printf "daily at %02d:%02d UTC" "$hr" "$min"
    return
  fi
  # M H * * D  → weekly on day D at H:M UTC
  if [[ "$min" =~ ^[0-9]+$ && "$hr" =~ ^[0-9]+$ && "$dom" == "*" && "$mon" == "*" && "$dow" =~ ^[0-6]$ ]]; then
    local -a days=(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)
    printf "weekly on %s at %02d:%02d UTC" "${days[$dow]}" "$hr" "$min"
    return
  fi
  # M H D * *  → monthly on day D at H:M UTC
  if [[ "$min" =~ ^[0-9]+$ && "$hr" =~ ^[0-9]+$ && "$dom" =~ ^[0-9]+$ && "$mon" == "*" && "$dow" == "*" ]]; then
    printf "monthly on day %d at %02d:%02d UTC" "$dom" "$hr" "$min"
    return
  fi
  echo "custom schedule"
}

worker_cron_menu() {
  while true; do
    header "Cron Triggers"
    require_account || return
    echo -e "  ${C}w${NC}.  Manage a worker's triggers"
    echo -e "  ${C}l${NC}.  List all triggers ${DM}(every account)${NC}"
    echo -e "  ${C}ca${NC}. ${M}Add to All${NC}   ${DM}multi-account: add one trigger${NC}"
    echo -e "  ${C}cr${NC}. ${M}Remove All${NC}   ${DM}multi-account: clear all triggers${NC}"
    echo -e "  ${C}b${NC}.  ${DM}Back${NC}"
    echo -ne "\n${W}Choice:${NC} "
    local choice
    read -r choice
    case "$choice" in
      w)  _worker_cron_manage_one ;;
      l)  cron_list_all ;;
      ca) cron_add_all ;;
      cr) cron_remove_all ;;
      b)  return ;;
      *)  warn "Invalid option." ;;
    esac
  done
}

_worker_cron_manage_one() {
  header "Worker Cron Triggers"
  require_account || return
  local worker
  worker=$(select_worker "Select worker to manage cron triggers") || { press_enter; return; }

  while true; do
    header "Cron Triggers — ${worker}"
    local resp
    resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${worker}/schedules")
    local -a crons=()
    if cf_check "$resp"; then
      mapfile -t crons < <(echo "$resp" | jq -r '.result.schedules[]?.cron // empty')
    else
      warn "Could not fetch schedules: $(cf_errors "$resp")"
    fi

    if [[ ${#crons[@]} -eq 0 ]]; then
      echo -e "  ${DM}(no cron triggers configured)${NC}"
    else
      echo -e "${W}Current cron triggers:${NC} ${DM}(times are UTC)${NC}\n"
      for i in "${!crons[@]}"; do
        printf "  ${C}%d${NC}. %-20s ${DM}(%s)${NC}\n" "$((i+1))" "${crons[$i]}" "$(_cron_describe "${crons[$i]}")"
      done
    fi
    echo ""
    echo -e "  ${C}a${NC}. Add cron trigger"
    echo -e "  ${C}e${NC}. Edit cron trigger"
    echo -e "  ${C}d${NC}. ${R}Remove cron trigger${NC}"
    echo -e "  ${C}c${NC}. ${R}Clear all${NC}"
    echo -e "  ${C}b${NC}. ${DM}Back${NC}"
    echo -ne "\n${W}Choice:${NC} "
    local choice
    read -r choice
    case "$choice" in
      a)
        local new_cron
        new_cron=$(_cron_builder) || { continue; }
        [[ -z "$new_cron" ]] && continue
        crons+=("$new_cron")
        _cron_push "$worker" "${crons[@]}"
        press_enter
        ;;
      e)
        if [[ ${#crons[@]} -eq 0 ]]; then
          warn "No cron triggers to edit."
          press_enter
          continue
        fi
        local sel
        read -rp "$(echo -e "${W}Edit which # (0=cancel):${NC} ")" sel
        [[ "$sel" == "0" || -z "$sel" ]] && continue
        local idx=$((sel-1))
        if [[ $idx -lt 0 || $idx -ge ${#crons[@]} ]]; then
          error "Invalid selection."
          press_enter
          continue
        fi
        echo -e "${DM}Current: ${crons[$idx]}  (${C}$(_cron_describe "${crons[$idx]}")${DM})${NC}"
        local new_cron
        new_cron=$(_cron_builder) || { continue; }
        [[ -z "$new_cron" ]] && continue
        crons[$idx]="$new_cron"
        _cron_push "$worker" "${crons[@]}"
        press_enter
        ;;
      d)
        if [[ ${#crons[@]} -eq 0 ]]; then
          warn "No cron triggers to remove."
          press_enter
          continue
        fi
        local sel
        read -rp "$(echo -e "${W}Remove which # (0=cancel):${NC} ")" sel
        [[ "$sel" == "0" || -z "$sel" ]] && continue
        local idx=$((sel-1))
        if [[ $idx -lt 0 || $idx -ge ${#crons[@]} ]]; then
          error "Invalid selection."
          press_enter
          continue
        fi
        unset 'crons[idx]'
        _cron_push "$worker" "${crons[@]}"
        press_enter
        ;;
      c)
        if [[ ${#crons[@]} -eq 0 ]]; then
          warn "No cron triggers to clear."
          press_enter
          continue
        fi
        if confirm "Remove ALL ${#crons[@]} cron trigger(s) for ${worker}?"; then
          _cron_push "$worker"
          press_enter
        fi
        ;;
      b) return ;;
      *) warn "Invalid option." ;;
    esac
  done
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# CRON TRIGGERS — MULTI-ACCOUNT (add to / clear from many workers at once)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# List every worker's cron schedules across every stored account.
cron_list_all() {
  header "Cron Triggers — All Accounts"
  echo -e "${DM}(times are UTC)${NC}\n"

  local -a all_accounts
  mapfile -t all_accounts < <(list_accounts)
  if [[ ${#all_accounts[@]} -eq 0 ]]; then
    warn "No accounts stored."
    press_enter; return
  fi

  for acct in "${all_accounts[@]}"; do
    echo -e "${BLD}${C}━━━  Account: ${G}${acct}${C}  ━━━${NC}"
    _switch_account_context "$acct"

    if [[ -z "$CF_TOKEN" ]]; then
      warn "No token for '${acct}' — skipping."
      _restore_account_context; echo ""; continue
    fi

    local resp
    resp=$(cf_get "/accounts/${CF_ACCOUNT_ID//[[:space:]]/}/workers/scripts" 2>/dev/null)
    if ! cf_check "$resp"; then
      warn "Could not fetch workers for '${acct}': $(cf_errors "$resp")"
      _restore_account_context; echo ""; continue
    fi

    local -a wnames
    mapfile -t wnames < <(echo "$resp" | jq -r '.result[].id' 2>/dev/null)
    if [[ ${#wnames[@]} -eq 0 ]]; then
      echo -e "  ${DM}No workers found.${NC}\n"
      _restore_account_context; continue
    fi

    local found_any=false
    local _cron_tmp
    _cron_tmp=$(mktemp -d)
    # Fetch each worker's schedules concurrently instead of one request at a time.
    for i in "${!wnames[@]}"; do
      ( cf_get "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${wnames[$i]}/schedules" 2>/dev/null > "$_cron_tmp/$i.json" ) &
    done
    wait
    for i in "${!wnames[@]}"; do
      local w="${wnames[$i]}"
      local sresp
      sresp=$(cat "$_cron_tmp/$i.json" 2>/dev/null || echo '{}')
      local -a crons=()
      cf_check "$sresp" && mapfile -t crons < <(echo "$sresp" | jq -r '.result.schedules[]?.cron // empty')
      if [[ ${#crons[@]} -gt 0 ]]; then
        found_any=true
        echo -e "  ${C}${w}${NC}"
        for c in "${crons[@]}"; do
          printf "    ${Y}•${NC} %-20s ${DM}(%s)${NC}\n" "$c" "$(_cron_describe "$c")"
        done
      fi
    done
    rm -rf "$_cron_tmp"
    [[ "$found_any" == false ]] && echo -e "  ${DM}(no cron triggers configured)${NC}"
    echo ""
    _restore_account_context
  done

  press_enter
}

cron_add_all() {
  header "Cron Add — Multi-Account"
  info "Pick the workers that should get a new cron trigger.\n"

  local -a targets=()
  _select_workers_across_accounts targets "check" || { press_enter; return; }
  if [[ ${#targets[@]} -eq 0 ]]; then
    warn "No workers selected. Aborting."
    press_enter; return
  fi

  local new_cron
  new_cron=$(_cron_builder) || { press_enter; return; }
  [[ -z "$new_cron" ]] && { warn "Cancelled."; press_enter; return; }

  echo -e "\n${BLD}${C}━━━  Plan  ━━━${NC}\n"
  for t in "${targets[@]}"; do
    printf "  ${G}+${NC}  ${BLD}%-20s${NC}  worker: ${C}%-30s${NC}  cron: ${Y}%s${NC}\n" "${t%%::*}" "${t#*::}" "$new_cron"
  done
  echo ""
  confirm "Add this cron trigger to ${#targets[@]} worker(s)?" || { info "Aborted."; press_enter; return; }

  echo ""
  local ok=0 fail=0 skip=0
  for t in "${targets[@]}"; do
    local t_acct="${t%%::*}" t_worker="${t#*::}"
    _switch_account_context "$t_acct"

    local resp
    resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${t_worker}/schedules")
    local -a crons=()
    cf_check "$resp" && mapfile -t crons < <(echo "$resp" | jq -r '.result.schedules[]?.cron // empty')

    echo -e "${BLD}${C}[ ${t_acct} / ${t_worker} ]${NC}"

    local already=false c
    for c in "${crons[@]}"; do
      [[ "$c" == "$new_cron" ]] && already=true && break
    done

    if $already; then
      info "Already has this trigger — skipping."
      ((skip++))
      _restore_account_context
      continue
    fi

    crons+=("$new_cron")
    if _cron_push "$t_worker" "${crons[@]}"; then
      ((ok++))
    else
      ((fail++))
    fi
    _restore_account_context
  done

  echo ""
  info "Done. ${G}${ok} added${NC}, ${Y}${skip} already present${NC}, ${R}${fail} failed${NC}."
  press_enter
}

cron_remove_all() {
  header "Cron Remove — Multi-Account"
  warn "This clears ${R}${BLD}ALL${NC} cron triggers from each selected worker."
  echo -e "${DM}(Cloudflare's API replaces the whole schedule list — there is no${NC}"
  echo -e "${DM} per-account 'remove one cron from many workers' since each worker${NC}"
  echo -e "${DM} can have a different set. To remove a single trigger, use the${NC}"
  echo -e "${DM} per-worker Cron Triggers menu.)${NC}\n"

  local -a targets=()
  _select_workers_across_accounts targets "cross" || { press_enter; return; }
  if [[ ${#targets[@]} -eq 0 ]]; then
    warn "No workers selected. Aborting."
    press_enter; return
  fi

  echo -e "\n${BLD}${R}━━━  Plan  ━━━${NC}\n"
  for t in "${targets[@]}"; do
    printf "  ${R}✗${NC}  ${BLD}%-20s${NC}  worker: ${C}%s${NC}\n" "${t%%::*}" "${t#*::}"
  done
  echo ""
  confirm "Clear ALL cron triggers for these ${#targets[@]} worker(s)?" || { info "Aborted."; press_enter; return; }

  echo ""
  local ok=0 fail=0
  for t in "${targets[@]}"; do
    local t_acct="${t%%::*}" t_worker="${t#*::}"
    _switch_account_context "$t_acct"

    echo -e "${BLD}${C}[ ${t_acct} / ${t_worker} ]${NC}"
    if _cron_push "$t_worker"; then
      ((ok++))
    else
      ((fail++))
    fi
    _restore_account_context
  done

  echo ""
  info "Done. ${G}${ok} succeeded${NC}, ${R}${fail} failed${NC}."
  press_enter
}
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PERSISTENT CACHE LAYER
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# Layout:  $CACHE_DIR/<account_name>/workers.json
#                                   bindings/<worker>.json
#                                   kv.json
#                                   d1.json
#                                   r2.json
#                                   queues.json
#                                   do.json
#
# All files store raw CF API JSON exactly as returned by cf_get.
# Freshness is checked via file mtime vs CACHE_TTL.
# Writes are invalidated proactively on mutating operations so stale
# data is never served; TTL is just a safety net for orphaned entries.
#
# Concurrent helpers (fetch_all_accounts, cf_get_with_token) are used
# for all warm-up sweeps so we fan out N accounts × M workers in
# parallel rather than serialising.

# _cache_path ACCOUNT RESOURCE
# Resolves the on-disk path for a cache entry.  RESOURCE examples:
#   "workers"              → workers.json
#   "bindings/my-worker"  → bindings/my-worker.json
_cache_path() {
  local account="$1" resource="$2"
  local safe_account
  safe_account=$(printf '%s' "$account" | tr '/' '_' | tr ' ' '_')
  echo "${CACHE_DIR}/${safe_account}/${resource}.json"
}

# cache_is_fresh ACCOUNT RESOURCE [TTL]
# Returns 0 if the file exists and is younger than TTL seconds.
cache_is_fresh() {
  local account="$1" resource="$2" ttl="${3:-$CACHE_TTL}"
  local path
  path=$(_cache_path "$account" "$resource")
  [[ -f "$path" ]] || return 1
  local mtime now age
  mtime=$(stat -c '%Y' "$path" 2>/dev/null || stat -f '%m' "$path" 2>/dev/null || echo 0)
  now=$(date +%s)
  age=$(( now - mtime ))
  [[ $age -lt $ttl ]]
}

# cache_get ACCOUNT RESOURCE [TTL]
# Prints cached JSON if fresh, returns 1 on miss/stale.
cache_get() {
  local account="$1" resource="$2" ttl="${3:-$CACHE_TTL}"
  cache_is_fresh "$account" "$resource" "$ttl" || return 1
  local path
  path=$(_cache_path "$account" "$resource")
  cat "$path" 2>/dev/null || return 1
}

# cache_put ACCOUNT RESOURCE JSON
# Writes JSON to the cache file, creating directories as needed.
cache_put() {
  local account="$1" resource="$2" json="$3"
  local path
  path=$(_cache_path "$account" "$resource")
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  printf '%s' "$json" > "$path" 2>/dev/null || true
}

# cache_invalidate [ACCOUNT] [RESOURCE]
# With no args: wipe the entire cache.
# With account only: wipe that account's whole subtree.
# With account + resource: delete one file.
cache_invalidate() {
  local account="${1:-}" resource="${2:-}"
  if [[ -z "$account" ]]; then
    rm -rf "${CACHE_DIR:?}" 2>/dev/null || true
    return
  fi
  local safe_account
  safe_account=$(printf '%s' "$account" | tr '/' '_' | tr ' ' '_')
  if [[ -z "$resource" ]]; then
    rm -rf "${CACHE_DIR}/${safe_account}" 2>/dev/null || true
  else
    local path
    path=$(_cache_path "$account" "$resource")
    rm -f "$path" 2>/dev/null || true
  fi
}

# cache_warm_all
# Fan out concurrent requests to populate workers, bindings, kv, d1,
# r2, queues, and do cache for every stored account.
# Wave 1: worker lists (one request per account)
# Wave 2: per-worker bindings (one request per worker per account)
# Wave 3: resource lists — kv, d1, r2, queues, do (5 concurrent per account)
cache_warm_all() {
  local -a all_accounts
  mapfile -t all_accounts < <(list_accounts)
  [[ ${#all_accounts[@]} -eq 0 ]] && return

  echo -e "${C}Warming cache for ${#all_accounts[@]} account(s)...${NC}"

  # ── Wave 1: worker lists (one request per account, concurrent) ─────
  local w1_tmp
  w1_tmp=$(mktemp -d)
  fetch_all_accounts "$w1_tmp" "/workers/scripts"

  local acct
  for acct in "${all_accounts[@]}"; do
    local resp
    resp=$(cat "$w1_tmp/${acct}.json" 2>/dev/null || echo '{}')
    if cf_check "$resp" 2>/dev/null; then
      cache_put "$acct" "workers" "$resp"
    fi
  done
  rm -rf "$w1_tmp"

  # ── Wave 2: bindings for every worker on every account (all concurrent)
  # Fire one background subshell per (account, worker) pair.
  local pids=()
  local b_tmp
  b_tmp=$(mktemp -d)

  for acct in "${all_accounts[@]}"; do
    local workers_json
    workers_json=$(cache_get "$acct" "workers" 86400 2>/dev/null) || continue
    local -a wnames
    mapfile -t wnames < <(printf '%s' "$workers_json" | jq -r '.result[].id' 2>/dev/null)

    local token acct_id
    token=$(get_account_field "$acct" "token" | tr -d '[:space:]')
    acct_id=$(get_account_field "$acct" "account_id" | tr -d '[:space:]')
    [[ -z "$token" || -z "$acct_id" ]] && continue

    local wname
    for wname in "${wnames[@]}"; do
      (
        local out_file="${b_tmp}/${acct}__${wname}.json"
        cf_get_with_token "$token" \
          "/accounts/${acct_id}/workers/scripts/${wname}/settings" \
          > "$out_file" 2>/dev/null
      ) &
      pids+=($!)
    done
  done

  # Wait for all binding fetches
  local pid
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Write results into cache
  for acct in "${all_accounts[@]}"; do
    local workers_json
    workers_json=$(cache_get "$acct" "workers" 86400 2>/dev/null) || continue
    local -a wnames
    mapfile -t wnames < <(printf '%s' "$workers_json" | jq -r '.result[].id' 2>/dev/null)
    local wname
    for wname in "${wnames[@]}"; do
      local out_file="${b_tmp}/${acct}__${wname}.json"
      [[ -f "$out_file" ]] || continue
      local resp
      resp=$(cat "$out_file")
      if cf_check "$resp" 2>/dev/null; then
        cache_put "$acct" "bindings/${wname}" "$resp"
      fi
    done
  done
  rm -rf "$b_tmp"

  # ── Wave 3: resource lists — kv, d1, r2, queues, do ────────────────
  # Fire all 5 endpoints per account concurrently, then store results.
  local r3_tmp
  r3_tmp=$(mktemp -d)

  for acct in "${all_accounts[@]}"; do
    local token acct_id
    token=$(get_account_field "$acct" "token" | tr -d '[:space:]')
    acct_id=$(get_account_field "$acct" "account_id" | tr -d '[:space:]')
    [[ -z "$token" || -z "$acct_id" ]] && continue

    cf_get_with_token "$token" \
      "/accounts/${acct_id}/storage/kv/namespaces?per_page=100" \
      > "${r3_tmp}/${acct}__kv.json"     2>/dev/null &
    cf_get_with_token "$token" \
      "/accounts/${acct_id}/d1/database?per_page=100" \
      > "${r3_tmp}/${acct}__d1.json"     2>/dev/null &
    cf_get_with_token "$token" \
      "/accounts/${acct_id}/r2/buckets" \
      > "${r3_tmp}/${acct}__r2.json"     2>/dev/null &
    cf_get_with_token "$token" \
      "/accounts/${acct_id}/queues" \
      > "${r3_tmp}/${acct}__queues.json" 2>/dev/null &
    cf_get_with_token "$token" \
      "/accounts/${acct_id}/workers/durable_objects/namespaces" \
      > "${r3_tmp}/${acct}__do.json"     2>/dev/null &
  done
  wait

  for acct in "${all_accounts[@]}"; do
    local resource resp
    for resource in kv d1 r2 queues do; do
      local out_file="${r3_tmp}/${acct}__${resource}.json"
      [[ -f "$out_file" ]] || continue
      resp=$(cat "$out_file")
      if cf_check "$resp" 2>/dev/null; then
        cache_put "$acct" "$resource" "$resp"
      fi
    done
  done
  rm -rf "$r3_tmp"

  success "Cache warm-up complete."
}

# cache_status
# Print a human-readable summary of what's currently cached.
cache_status() {
  header "Cache Status"
  if [[ ! -d "$CACHE_DIR" ]]; then
    info "Cache directory does not exist yet (never warmed)."
    press_enter; return
  fi

  local -a all_accounts
  mapfile -t all_accounts < <(list_accounts)
  local total_files=0

  for acct in "${all_accounts[@]}"; do
    local safe_acct
    safe_acct=$(printf '%s' "$acct" | tr '/' '_' | tr ' ' '_')
    local acct_dir="${CACHE_DIR}/${safe_acct}"

    echo -e "${BLD}${C}${acct}${NC}"

    # Workers file
    local wpath="${acct_dir}/workers.json"
    if [[ -f "$wpath" ]]; then
      local wcount age mtime now
      wcount=$(jq '.result | length' "$wpath" 2>/dev/null || echo "?")
      mtime=$(stat -c '%Y' "$wpath" 2>/dev/null || stat -f '%m' "$wpath" 2>/dev/null || echo 0)
      now=$(date +%s)
      age=$(( now - mtime ))
      local age_str fresh_flag
      if   [[ $age -lt 60   ]]; then age_str="${age}s ago";        fresh_flag="${G}fresh${NC}"
      elif [[ $age -lt 3600 ]]; then age_str="$(( age/60 ))m ago"; fresh_flag="${G}fresh${NC}"
      else                             age_str="$(( age/3600 ))h ago"; fresh_flag="${Y}stale${NC}"
      fi
      [[ $age -ge $CACHE_TTL ]] && fresh_flag="${Y}stale${NC}"
      printf "  workers: ${W}%d${NC} entries  ${DM}%s${NC}  [%b]\n" "$wcount" "$age_str" "$fresh_flag"
      inc total_files
    else
      echo -e "  workers: ${DM}(not cached)${NC}"
    fi

    # Binding files
    local bdir="${acct_dir}/bindings"
    if [[ -d "$bdir" ]]; then
      local bcount
      bcount=$(find "$bdir" -name '*.json' 2>/dev/null | wc -l)
      printf "  bindings: ${W}%d${NC} worker(s) cached\n" "$bcount"
      total_files=$(( total_files + bcount ))
    else
      echo -e "  bindings: ${DM}(not cached)${NC}"
    fi
    echo ""
  done

  echo -e "${DM}Total cache files: ${total_files}${NC}"
  echo -e "${DM}Cache directory:   ${CACHE_DIR}${NC}"
  echo -e "${DM}TTL:               ${CACHE_TTL}s${NC}"
  press_enter
}

# Backwards-compat stubs — the old in-memory session cache
# is superseded by the persistent layer above.  These are kept
# so any call sites that were already using them still compile.
_WORKER_CACHE_DATA=""
_WORKER_CACHE_ACCOUNT=""
_worker_cache_get() { return 1; }
_worker_cache_set() { :; }
_worker_cache_clear() {
  # Invalidate the persistent cache for the active account's workers list
  # (the fine-grained invalidation is done by callers, but we keep the
  # old clear as a hook for legacy call sites).
  [[ -n "$ACTIVE_ACCOUNT_NAME" ]] && cache_invalidate "$ACTIVE_ACCOUNT_NAME" "workers" || true
}

# Fetch worker list and let user pick one. Prints selected name to stdout.
# Returns 1 if cancelled or no workers found.
select_worker() {
  local prompt="${1:-Select worker}"
  local resp
  # Try persistent cache first; fall back to live API on miss/stale
  if ! resp=$(cache_get "$ACTIVE_ACCOUNT_NAME" "workers" 2>/dev/null); then
    resp=$(cf_get "/accounts/${CF_ACCOUNT_ID//[[:space:]]/}/workers/scripts")
    cf_check "$resp" && cache_put "$ACTIVE_ACCOUNT_NAME" "workers" "$resp"
  fi
  if ! cf_check "$resp"; then
    error "$(cf_errors "$resp")"
    return 1
  fi
  local count
  count=$(echo "$resp" | jq '.result | length')
  if [[ "$count" -eq 0 ]]; then
    warn "No workers found in this account."
    return 1
  fi
  local -a names
  mapfile -t names < <(echo "$resp" | jq -r '.result[].id')
  echo -e "${W}${prompt}:${NC}\n" >&2
  for i in "${!names[@]}"; do
    local modified
    modified=$(echo "$resp" | jq -r ".result[$i].modified_on[:10] // \"\"")
    printf "  ${C}%d${NC}. %-40s ${DM}%s${NC}\n" "$((i+1))" "${names[$i]}" "$modified" >&2
  done
  echo -ne "\n${W}Choice (0=cancel):${NC} " >&2
  local sel
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return 1
  local idx=$((sel-1))
  if [[ $idx -lt 0 || $idx -ge ${#names[@]} ]]; then
    error "Invalid selection." >&2
    return 1
  fi
  printf '%s' "${names[$idx]}"
}

delete_worker() {
  header "Delete Worker"
  require_account || return
  local name
  name=$(select_worker "Select worker to delete") || { press_enter; return; }
  echo ""
  warn "This will permanently delete '${BLD}${name}${NC}' from Cloudflare."
  confirm "Are you sure?" || return
  local resp
  resp=$(cf_curl_delete "/accounts/${CF_ACCOUNT_ID//[[:space:]]/}/workers/scripts/${name}")
  if [[ "$(echo "$resp" | jq -r '.success')" == "true" ]] || cf_check "$resp"; then
    success "Worker '${BLD}${name}${NC}' deleted."
    rm -f "$WORKERS_DIR/${name}.js"
    cache_invalidate "$ACTIVE_ACCOUNT_NAME" "workers"
    cache_invalidate "$ACTIVE_ACCOUNT_NAME" "bindings/${name}"
    _worker_cache_clear
    log "Worker deleted: $name"
  else
    error "Delete failed: $(cf_errors "$resp")"
    echo "$resp" | jq -r '.errors[]? | "  [\(.code)] \(.message)"' 2>/dev/null
  fi
  press_enter
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# WORKER ENVIRONMENT VARIABLES & SECRETS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Fetch the current bindings for a worker script and print them as JSON.
# Returns the full bindings array from the script settings endpoint.
_env_get_bindings() {
  local name="$1"
  local resp
  # Try cache first; fall back to live API on miss/stale
  if ! resp=$(cache_get "$ACTIVE_ACCOUNT_NAME" "bindings/${name}" 2>/dev/null); then
    resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${name}/settings")
    if cf_check "$resp"; then
      cache_put "$ACTIVE_ACCOUNT_NAME" "bindings/${name}" "$resp"
    fi
  fi
  if ! cf_check "$resp"; then
    error "Could not fetch settings for '${name}': $(cf_errors "$resp")"
    return 1
  fi
  echo "$resp" | jq '.result.bindings // []'
}

# Fetch the full raw settings object (not just bindings) for a worker.
_env_get_settings_raw() {
  local name="$1"
  local resp
  # Try cache first
  if ! resp=$(cache_get "$ACTIVE_ACCOUNT_NAME" "bindings/${name}" 2>/dev/null); then
    resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${name}/settings")
    if cf_check "$resp"; then
      cache_put "$ACTIVE_ACCOUNT_NAME" "bindings/${name}" "$resp"
    fi
  fi
  cf_check "$resp" || return 1
  echo "$resp" | jq '.result // {}'
}

# PUT the full bindings array back to the script settings endpoint.
# $1 = worker name   $2 = JSON array of bindings
#
# ROOT CAUSE OF REBIND FAILURES:
# The GET /settings response returns D1 bindings with the UUID in a field
# called "id".  When we jq-update that field and PATCH it back, the payload
# is structurally correct BUT the /settings PATCH endpoint silently ignores
# the bindings array entirely for D1 — it only accepts non-resource settings
# (logpush, tags, compatibility_date, etc.).  Bindings can only be durably
# changed by re-uploading the worker script via PUT /workers/scripts/{name}
# with a multipart body that includes both the script and a metadata JSON part.
#
# However, re-uploading the full script is complex and risky (we'd need to
# fetch the current compiled script bytes).  The practical alternative that
# actually works for binding-only changes is to PUT to the script endpoint
# with ONLY a metadata part (no script part) — Cloudflare accepts this and
# updates only the metadata/bindings without touching the script code.
#
# Binding normalisation:
# The official multipart upload metadata format (per CF docs) requires D1
# bindings as: {"type":"d1","name":"<VAR>","id":"<UUID>"}
# The GET response may return them with "database_id" instead of "id".
# We normalise to "id" before sending.
# secret_text bindings are stripped when their value is redacted (null/absent)
# so we don't accidentally clear existing secrets.
_env_put_bindings() {
  local name="$1"
  local bindings_json="$2"

  # Fetch current settings for compatibility_date and other metadata fields.
  local current_settings
  current_settings=$(_env_get_settings_raw "$name") || {
    error "Could not fetch current settings for '${name}' — cannot safely update bindings"
    return 1
  }

  local compat_date compat_flags
  compat_date=$(printf '%s' "$current_settings" | jq -r '.compatibility_date // ""')
  compat_flags=$(printf '%s' "$current_settings" | jq -c '.compatibility_flags // []')

  # Normalise bindings for the upload metadata format:
  #  • D1: rename database_id → id (GET uses database_id; PUT expects id)
  #  • strip secret_text with no text value (would clear the secret)
  #  • strip any other fields the PUT API doesn't accept (e.g. database_name)
  local normalised_bindings
  normalised_bindings=$(printf '%s' "$bindings_json" | jq -c '
    map(
      if .type == "d1" then
        { type: "d1",
          name: .name,
          id: (.id // .database_id) }
      elif .type == "kv_namespace" then
        { type: "kv_namespace",
          name: .name,
          namespace_id: .namespace_id }
      elif .type == "r2_bucket" then
        { type: "r2_bucket",
          name: .name,
          bucket_name: .bucket_name }
      elif .type == "secret_text" then
        if (.text != null and .text != "") then . else empty end
      else . end
    )')

  # Build the metadata JSON for the multipart upload.
  local metadata
  metadata=$(jq -n \
    --argjson bindings "$normalised_bindings" \
    --arg     compat   "$compat_date" \
    --argjson flags    "$compat_flags" \
    '{
       bindings: $bindings,
       compatibility_date: $compat,
       compatibility_flags: $flags
     }')

  log "put_bindings: sending metadata for ${name}: ${metadata}"

  local token="${CF_TOKEN//[[:space:]]/}"
  local account_id="${CF_ACCOUNT_ID//[[:space:]]/}"
  local tmpfile
  tmpfile=$(mktemp)
  local http_code
  # Use the script settings PATCH endpoint with the metadata as the "settings"
  # form field — this is the supported way to update bindings without
  # re-uploading the script body.
  http_code=$(curl -s -w "%{http_code}" -o "$tmpfile" \
    -X PATCH "${CF_API}/accounts/${account_id}/workers/scripts/${name}/settings" \
    -H "Authorization: Bearer ${token}" \
    -F "settings=$(printf '%s' "$metadata")" \
    2>/dev/null)
  local resp
  resp=$(cat "$tmpfile" 2>/dev/null || echo "")
  rm -f "$tmpfile"
  if cf_check "$resp"; then
    log "put_bindings: PATCH OK for ${name} (HTTP ${http_code})"
    cache_invalidate "$ACTIVE_ACCOUNT_NAME" "bindings/${name}"
    return 0
  else
    error "Failed to update bindings (HTTP ${http_code}): $(cf_errors "$resp")"
    log "put_bindings FAILED for ${name}: HTTP=${http_code} err=$(cf_errors "$resp")"
    log "put_bindings FAILED response: ${resp}"
    log "put_bindings FAILED metadata sent: ${metadata}"
    return 1
  fi
}

# List all plain-text env vars (type=plain_text) and secrets (type=secret_text)
# for a worker, grouped and colour-coded.
env_list() {
  header "Environment Variables & Secrets"
  require_account || return
  local name
  name=$(select_worker "Select worker") || { press_enter; return; }
  echo ""

  local bindings
  bindings=$(_env_get_bindings "$name") || { press_enter; return; }

  local plain_count secret_count
  plain_count=$(echo "$bindings"  | jq '[.[] | select(.type=="plain_text")] | length')
  secret_count=$(echo "$bindings" | jq '[.[] | select(.type=="secret_text")] | length')

  echo -e "${BLD}${W}Worker:${NC} ${C}${name}${NC}\n"

  echo -e "${BLD}${G}Plain-text variables${NC} ${DM}(${plain_count})${NC}"
  if [[ "$plain_count" -gt 0 ]]; then
    echo "$bindings" | jq -r '.[] | select(.type=="plain_text") | "  \(.name) = \(.text)"' \
      | while IFS= read -r line; do echo -e "  ${C}${line#  }${NC}"; done
  else
    echo -e "  ${DM}(none)${NC}"
  fi

  echo ""
  echo -e "${BLD}${Y}Secrets${NC} ${DM}(${secret_count}) — values are never shown${NC}"
  if [[ "$secret_count" -gt 0 ]]; then
    echo "$bindings" | jq -r '.[] | select(.type=="secret_text") | "  \(.name)"' \
      | while IFS= read -r line; do echo -e "  ${Y}${line#  }${NC}  ${DM}[encrypted]${NC}"; done
  else
    echo -e "  ${DM}(none)${NC}"
  fi

  local other_count
  other_count=$(echo "$bindings" | jq '[.[] | select(.type!="plain_text" and .type!="secret_text")] | length')
  if [[ "$other_count" -gt 0 ]]; then
    echo ""
    echo -e "${BLD}${M}Other bindings${NC} ${DM}(${other_count} — KV, R2, D1, etc.)${NC}"
    echo "$bindings" | jq -r '.[] | select(.type!="plain_text" and .type!="secret_text") | "  [\(.type)] \(.name)"' \
      | while IFS= read -r line; do echo -e "  ${M}${line#  }${NC}"; done
  fi

  press_enter
}

# Add a new plain-text environment variable to a worker.
env_add() {
  header "Add Environment Variable"
  require_account || return
  local name
  name=$(select_worker "Select worker") || { press_enter; return; }
  echo ""

  local bindings
  bindings=$(_env_get_bindings "$name") || { press_enter; return; }

  local var_name var_value
  read -rp "$(echo -e "${W}Variable name:${NC} ")" var_name
  [[ -z "$var_name" ]] && info "Cancelled." && press_enter && return

  # Check for duplicate
  if echo "$bindings" | jq -e --arg k "$var_name" '.[] | select(.name==$k)' &>/dev/null; then
    warn "A binding named '${var_name}' already exists. Use 'Change' to update it."
    press_enter; return
  fi

  read -rp "$(echo -e "${W}Value:${NC} ")" var_value

  local updated
  updated=$(echo "$bindings" | jq \
    --arg k "$var_name" --arg v "$var_value" \
    '. + [{type:"plain_text", name:$k, text:$v}]')

  if _env_put_bindings "$name" "$updated"; then
    success "Variable '${BLD}${var_name}${NC}' added to '${name}'."
    log "Env var added: $name :: $var_name"
  fi
  press_enter
}

# Change the value of an existing plain-text variable.
env_change() {
  header "Change Environment Variable"
  require_account || return
  local name
  name=$(select_worker "Select worker") || { press_enter; return; }
  echo ""

  local bindings
  bindings=$(_env_get_bindings "$name") || { press_enter; return; }

  # Show only plain_text vars to choose from
  local plain_vars=()
  mapfile -t plain_vars < <(echo "$bindings" | jq -r '.[] | select(.type=="plain_text") | .name')
  if [[ ${#plain_vars[@]} -eq 0 ]]; then
    warn "No plain-text variables found for '${name}'."
    info "Use 'Add secret' to add a secret, or 'Add variable' for a plain var."
    press_enter; return
  fi

  echo -e "${W}Plain-text variables:${NC}\n"
  for i in "${!plain_vars[@]}"; do
    local cur_val
    cur_val=$(echo "$bindings" | jq -r --arg k "${plain_vars[$i]}" '.[] | select(.name==$k) | .text')
    printf "  ${C}%d${NC}. %-30s ${DM}= %s${NC}\n" "$((i+1))" "${plain_vars[$i]}" "$cur_val"
  done
  echo -ne "\n${W}Select variable to change (0=cancel):${NC} "
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return
  local idx=$((sel-1))
  [[ $idx -lt 0 || $idx -ge ${#plain_vars[@]} ]] && error "Invalid." && press_enter && return

  local var_name="${plain_vars[$idx]}"
  local old_val
  old_val=$(echo "$bindings" | jq -r --arg k "$var_name" '.[] | select(.name==$k) | .text')
  echo -e "\n  Current value: ${DM}${old_val}${NC}"
  read -rp "$(echo -e "${W}New value:${NC} ")" new_val
  [[ -z "$new_val" ]] && info "Cancelled." && press_enter && return

  local updated
  updated=$(echo "$bindings" | jq \
    --arg k "$var_name" --arg v "$new_val" \
    'map(if .name==$k and .type=="plain_text" then .text=$v else . end)')

  if _env_put_bindings "$name" "$updated"; then
    success "Variable '${BLD}${var_name}${NC}' updated."
    log "Env var changed: $name :: $var_name"
  fi
  press_enter
}

# Remove a plain-text variable or a secret by name.
env_delete() {
  header "Remove Variable / Secret"
  require_account || return
  local name
  name=$(select_worker "Select worker") || { press_enter; return; }
  echo ""

  local bindings
  bindings=$(_env_get_bindings "$name") || { press_enter; return; }

  # Build list of deletable bindings (plain_text + secret_text)
  local del_vars=()
  mapfile -t del_vars < <(echo "$bindings" | \
    jq -r '.[] | select(.type=="plain_text" or .type=="secret_text") | "\(.type):\(.name)"')

  if [[ ${#del_vars[@]} -eq 0 ]]; then
    warn "No variables or secrets to remove for '${name}'."
    press_enter; return
  fi

  echo -e "${W}Variables & Secrets:${NC}\n"
  for i in "${!del_vars[@]}"; do
    local type_tag="${del_vars[$i]%%:*}"
    local var_nm="${del_vars[$i]#*:}"
    local colour="${C}"
    [[ "$type_tag" == "secret_text" ]] && colour="${Y}"
    printf "  ${colour}%d${NC}. %-30s ${DM}[%s]${NC}\n" "$((i+1))" "$var_nm" "$type_tag"
  done
  echo -ne "\n${W}Select entry to remove (0=cancel):${NC} "
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return
  local idx=$((sel-1))
  [[ $idx -lt 0 || $idx -ge ${#del_vars[@]} ]] && error "Invalid." && press_enter && return

  local entry="${del_vars[$idx]}"
  local del_type="${entry%%:*}"
  local del_name="${entry#*:}"

  warn "This will remove '${BLD}${del_name}${NC}' (${del_type}) from '${name}'."
  confirm "Continue?" || return

  local updated
  updated=$(echo "$bindings" | jq \
    --arg k "$del_name" --arg t "$del_type" \
    '[.[] | select(not (.name==$k and .type==$t))]')

  if _env_put_bindings "$name" "$updated"; then
    success "Removed '${BLD}${del_name}${NC}' from '${name}'."
    log "Env entry removed: $name :: $del_name ($del_type)"
  fi
  press_enter
}

# Add or overwrite a secret (secret_text binding).
# Secrets are encrypted at rest; their values are never returned by the API.
env_add_secret() {
  header "Add / Update Secret"
  require_account || return
  local name
  name=$(select_worker "Select worker") || { press_enter; return; }
  echo ""

  local bindings
  bindings=$(_env_get_bindings "$name") || { press_enter; return; }

  local secret_name secret_val
  read -rp "$(echo -e "${W}Secret name:${NC} ")" secret_name
  [[ -z "$secret_name" ]] && info "Cancelled." && press_enter && return
  read -rsp "$(echo -e "${W}Secret value (hidden):${NC} ")" secret_val; echo
  [[ -z "$secret_val" ]] && info "Cancelled." && press_enter && return

  # Remove any existing entry with the same name (replace semantics)
  local updated
  updated=$(echo "$bindings" | jq --arg k "$secret_name" \
    '[.[] | select(.name != $k)]')
  updated=$(echo "$updated" | jq \
    --arg k "$secret_name" --arg v "$secret_val" \
    '. + [{type:"secret_text", name:$k, text:$v}]')

  if _env_put_bindings "$name" "$updated"; then
    success "Secret '${BLD}${secret_name}${NC}' saved to '${name}'."
    log "Secret set: $name :: $secret_name"
  fi
  press_enter
}

# Rename an existing plain-text variable (name only; value stays the same).
env_rename() {
  header "Rename Variable"
  require_account || return
  local name
  name=$(select_worker "Select worker") || { press_enter; return; }
  echo ""

  local bindings
  bindings=$(_env_get_bindings "$name") || { press_enter; return; }

  local plain_vars=()
  mapfile -t plain_vars < <(echo "$bindings" | jq -r '.[] | select(.type=="plain_text") | .name')
  if [[ ${#plain_vars[@]} -eq 0 ]]; then
    warn "No plain-text variables to rename for '${name}'."
    press_enter; return
  fi

  echo -e "${W}Plain-text variables:${NC}\n"
  for i in "${!plain_vars[@]}"; do
    printf "  ${C}%d${NC}. %s\n" "$((i+1))" "${plain_vars[$i]}"
  done
  echo -ne "\n${W}Select variable to rename (0=cancel):${NC} "
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return
  local idx=$((sel-1))
  [[ $idx -lt 0 || $idx -ge ${#plain_vars[@]} ]] && error "Invalid." && press_enter && return

  local old_name="${plain_vars[$idx]}"
  read -rp "$(echo -e "${W}New name for '${old_name}':${NC} ")" new_name
  [[ -z "$new_name" ]] && info "Cancelled." && press_enter && return

  if echo "$bindings" | jq -e --arg k "$new_name" '.[] | select(.name==$k)' &>/dev/null; then
    error "A binding named '${new_name}' already exists."
    press_enter; return
  fi

  local updated
  updated=$(echo "$bindings" | jq \
    --arg old "$old_name" --arg new "$new_name" \
    'map(if .name==$old and .type=="plain_text" then .name=$new else . end)')

  if _env_put_bindings "$name" "$updated"; then
    success "Renamed '${BLD}${old_name}${NC}' → '${BLD}${new_name}${NC}'."
    log "Env var renamed: $name :: $old_name -> $new_name"
  fi
  press_enter
}

# Bulk-import variables from a .env file (KEY=VALUE lines; # comments ignored).
env_import_dotenv() {
  header "Import from .env File"
  require_account || return
  local name
  name=$(select_worker "Select worker") || { press_enter; return; }
  echo ""

  read -rp "$(echo -e "${W}Path to .env file:${NC} ")" env_file
  [[ -z "$env_file" ]] && return
  [[ ! -f "$env_file" ]] && error "File not found: $env_file" && press_enter && return

  local bindings
  bindings=$(_env_get_bindings "$name") || { press_enter; return; }

  local added=0 skipped=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    # Strip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// /}" ]] && continue
    local key val
    key="${line%%=*}"
    val="${line#*=}"
    # Strip surrounding quotes from value
    val=$(echo "$val" | sed "s/^['\"]//;s/['\"]$//")
    [[ -z "$key" ]] && continue

    # Check duplicate
    if echo "$bindings" | jq -e --arg k "$key" '.[] | select(.name==$k)' &>/dev/null; then
      echo -e "  ${Y}skip${NC}  ${key}  ${DM}(already exists)${NC}"
      inc skipped
      continue
    fi

    bindings=$(echo "$bindings" | jq \
      --arg k "$key" --arg v "$val" \
      '. + [{type:"plain_text", name:$k, text:$v}]')
    echo -e "  ${G}add${NC}   ${key}"
    inc added
  done < "$env_file"

  echo ""
  if [[ $added -gt 0 ]]; then
    if _env_put_bindings "$name" "$bindings"; then
      success "Imported ${added} variable(s) to '${name}' (${skipped} skipped)."
      log "Env import: $name — $added added, $skipped skipped from $env_file"
    fi
  else
    info "Nothing new to import (${skipped} already existed)."
  fi
  press_enter
}

# Export all plain-text variables to a .env file.
env_export_dotenv() {
  header "Export Variables to .env"
  require_account || return
  local name
  name=$(select_worker "Select worker") || { press_enter; return; }
  echo ""

  local bindings
  bindings=$(_env_get_bindings "$name") || { press_enter; return; }

  local plain_count
  plain_count=$(echo "$bindings" | jq '[.[] | select(.type=="plain_text")] | length')
  if [[ "$plain_count" -eq 0 ]]; then
    warn "No plain-text variables to export."
    press_enter; return
  fi

  local out_file="$CONFIG_DIR/${name}.env"
  {
    echo "# CF-Manager export — worker: $name"
    echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "$bindings" | jq -r '.[] | select(.type=="plain_text") | "\(.name)=\(.text)"'
  } > "$out_file"
  success "Exported ${plain_count} variable(s) to:"
  echo -e "  ${DM}${out_file}${NC}"
  echo -e "\n  ${Y}Note:${NC} Secrets are intentionally excluded from exports."
  press_enter
}

worker_envs_menu() {
  while true; do
    header "Environment Variables & Secrets"
    echo -e "  ${C}l${NC}.  List vars & secrets"
    echo -e "  ${C}a${NC}.  Add plain variable"
    echo -e "  ${C}c${NC}.  Change variable value"
    echo -e "  ${C}rn${NC}. Rename variable"
    echo -e "  ${C}as${NC}. Add / update secret"
    echo -e "  ${C}d${NC}.  ${R}Remove variable / secret${NC}"
    echo -e "  ${C}im${NC}. Import from .env file"
    echo -e "  ${C}ex${NC}. Export to .env file"
    echo -e "  ${C}b${NC}.  ${DM}Back${NC}"
    echo -ne "\n${W}Choice:${NC} "
    read -r choice
    case "$choice" in
      l)  env_list ;;
      a)  env_add ;;
      c)  env_change ;;
      rn) env_rename ;;
      as) env_add_secret ;;
      d)  env_delete ;;
      im) env_import_dotenv ;;
      ex) env_export_dotenv ;;
      b)  return ;;
      *)  warn "Invalid option." ;;
    esac
  done
}

worker_subdomain() {
  header "Worker Domain (workers.dev)"
  require_account || return
  local name
  name=$(select_worker "Select worker") || { press_enter; return; }
  echo ""
  _toggle_workers_dev_domain "$name"
  press_enter
}

# Core logic: show current workers.dev domain status for $1 and offer to
# toggle it. Used by the Workers menu ("sd") and by the post-deploy prompt.
_toggle_workers_dev_domain() {
  local name="$1"

  # ── Fetch current subdomain enabled state ──────────────────────────
  echo -e "${C}Fetching domain settings for '${BLD}${name}${NC}${C}'...${NC}"
  local resp
  resp=$(cf_get "/accounts/${CF_ACCOUNT_ID//[[:space:]]/}/workers/scripts/${name}/subdomain")
  local enabled="unknown"
  if cf_check "$resp"; then
    enabled=$(echo "$resp" | jq -r '.result.enabled // false')
  fi

  # ── Also check if account subdomain is configured ──────────────────
  local sub_resp sub_name
  sub_resp=$(cf_get "/accounts/${CF_ACCOUNT_ID//[[:space:]]/}/workers/subdomain")
  sub_name=$(echo "$sub_resp" | jq -r '.result.subdomain // ""' 2>/dev/null)

  echo -e "\n${BLD}${W}Worker:${NC}  ${C}${name}${NC}"
  if [[ -n "$sub_name" ]]; then
    echo -e "${BLD}${W}Domain:${NC}  ${C}${name}.${sub_name}.workers.dev${NC}"
  else
    echo -e "${BLD}${W}Domain:${NC}  ${DM}(account subdomain not set up)${NC}"
  fi
  if [[ "$enabled" == "true" ]]; then
    echo -e "${BLD}${W}Status:${NC}  ${G}● Enabled${NC}\n"
    echo -e "  ${C}1${NC}. ${R}Disable workers.dev domain${NC}"
  else
    echo -e "${BLD}${W}Status:${NC}  ${R}○ Disabled${NC}\n"
    echo -e "  ${C}1${NC}. ${G}Enable workers.dev domain${NC}"
  fi
  echo -e "  ${C}0${NC}. Cancel"
  echo -ne "\n${W}Choice:${NC} "
  local choice
  read -r choice
  [[ "$choice" != "1" ]] && return

  local new_state
  if [[ "$enabled" == "true" ]]; then
    new_state="false"
  else
    new_state="true"
  fi

  local put_resp
  put_resp=$(cf_curl_post_raw \
    "/accounts/${CF_ACCOUNT_ID//[[:space:]]/}/workers/scripts/${name}/subdomain" \
    "{\"enabled\":${new_state}}")

  if cf_check "$put_resp"; then
    if [[ "$new_state" == "true" ]]; then
      success "workers.dev domain ${G}enabled${NC} for '${BLD}${name}${NC}'."
      [[ -n "$sub_name" ]] && info "URL: ${C}https://${name}.${sub_name}.workers.dev${NC}"
    else
      success "workers.dev domain ${R}disabled${NC} for '${BLD}${name}${NC}'."
    fi
    log "Worker subdomain set to ${new_state}: ${name}"
  else
    error "Failed: $(cf_errors "$put_resp")"
  fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# WORKER RESOURCE BINDINGS  (KV · D1 · R2)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# List all resource bindings (KV, D1, R2) for a worker, grouped by type.
bindings_list() {
  header "Resource Bindings"
  require_account || return
  local worker
  worker=$(select_worker "Select worker") || { press_enter; return; }
  echo ""

  local bindings
  bindings=$(_env_get_bindings "$worker") || { press_enter; return; }

  local kv_count d1_count r2_count
  kv_count=$(echo "$bindings" | jq '[.[] | select(.type=="kv_namespace")] | length')
  d1_count=$(echo "$bindings" | jq '[.[] | select(.type=="d1")] | length')
  r2_count=$(echo "$bindings" | jq '[.[] | select(.type=="r2_bucket")] | length')

  echo -e "${BLD}${W}Worker:${NC} ${C}${worker}${NC}\n"

  echo -e "${BLD}${B}KV Namespace bindings${NC} ${DM}(${kv_count})${NC}"
  if [[ "$kv_count" -gt 0 ]]; then
    echo "$bindings" | jq -r '.[] | select(.type=="kv_namespace") |
      "  \(.name)  →  \(.namespace_id)"' \
      | while IFS= read -r line; do echo -e "  ${B}${line#  }${NC}"; done
  else
    echo -e "  ${DM}(none)${NC}"
  fi

  echo ""
  echo -e "${BLD}${M}D1 Database bindings${NC} ${DM}(${d1_count})${NC}"
  if [[ "$d1_count" -gt 0 ]]; then
    echo "$bindings" | jq -r '.[] | select(.type=="d1") |
      "  \(.name)  →  \(.id)  [\(.database_name // "")]"' \
      | while IFS= read -r line; do echo -e "  ${M}${line#  }${NC}"; done
  else
    echo -e "  ${DM}(none)${NC}"
  fi

  echo ""
  echo -e "${BLD}${G}R2 Bucket bindings${NC} ${DM}(${r2_count})${NC}"
  if [[ "$r2_count" -gt 0 ]]; then
    echo "$bindings" | jq -r '.[] | select(.type=="r2_bucket") |
      "  \(.name)  →  \(.bucket_name)"' \
      | while IFS= read -r line; do echo -e "  ${G}${line#  }${NC}"; done
  else
    echo -e "  ${DM}(none)${NC}"
  fi

  press_enter
}

# Bind a KV namespace to a worker.
# The binding name is the variable name used in worker code (env.MY_KV).
binding_add_kv() {
  header "Bind KV Namespace → Worker"
  require_account || return

  local worker
  worker=$(select_worker "Select worker") || { press_enter; return; }
  echo ""

  local picked
  picked=$(select_kv_namespace "Select KV namespace to bind") || { press_enter; return; }
  local ns_id ns_title
  split_pipe ns_id ns_title "$picked"

  echo ""
  echo -e "${DM}The binding name is how you access this KV in your worker code:${NC}"
  echo -e "${DM}  e.g. name 'MY_KV'  →  env.MY_KV.get(key)${NC}\n"
  local binding_name
  prompt_binding_name binding_name || { press_enter; return; }

  local bindings
  bindings=$(_env_get_bindings "$worker") || { press_enter; return; }
  binding_dedup_replace bindings "$binding_name" || { press_enter; return; }

  local updated
  updated=$(echo "$bindings" | jq \
    --arg n  "$binding_name" \
    --arg id "$ns_id" \
    '. + [{type:"kv_namespace", name:$n, namespace_id:$id}]')

  if _env_put_bindings "$worker" "$updated"; then
    success "KV namespace '${BLD}${ns_title}${NC}' bound to worker '${BLD}${worker}${NC}' as ${C}env.${binding_name}${NC}"
    log "KV binding added: worker=$worker name=$binding_name ns=$ns_id"
  fi
  press_enter
}

# Bind a D1 database to a worker.
binding_add_d1() {
  header "Bind D1 Database → Worker"
  require_account || return

  local worker
  worker=$(select_worker "Select worker") || { press_enter; return; }
  echo ""

  local picked
  picked=$(select_d1_database "Select D1 database to bind") || { press_enter; return; }
  local db_uuid db_name
  split_pipe db_uuid db_name "$picked"

  echo ""
  echo -e "${DM}The binding name is how you access this DB in your worker code:${NC}"
  echo -e "${DM}  e.g. name 'MY_DB'  →  env.MY_DB.prepare(sql)${NC}\n"
  local binding_name
  prompt_binding_name binding_name || { press_enter; return; }

  local bindings
  bindings=$(_env_get_bindings "$worker") || { press_enter; return; }
  binding_dedup_replace bindings "$binding_name" || { press_enter; return; }

  local updated
  updated=$(echo "$bindings" | jq \
    --arg n    "$binding_name" \
    --arg id   "$db_uuid" \
    --arg dbn  "$db_name" \
    '. + [{type:"d1", name:$n, id:$id, database_name:$dbn}]')

  if _env_put_bindings "$worker" "$updated"; then
    success "D1 database '${BLD}${db_name}${NC}' bound to worker '${BLD}${worker}${NC}' as ${C}env.${binding_name}${NC}"
    log "D1 binding added: worker=$worker name=$binding_name db=$db_uuid"
  fi
  press_enter
}

# Bind an R2 bucket to a worker.
binding_add_r2() {
  header "Bind R2 Bucket → Worker"
  require_account || return

  local worker
  worker=$(select_worker "Select worker") || { press_enter; return; }
  echo ""

  local bucket
  bucket=$(select_r2_bucket "Select R2 bucket to bind") || { press_enter; return; }

  echo ""
  echo -e "${DM}The binding name is how you access this bucket in your worker code:${NC}"
  echo -e "${DM}  e.g. name 'MY_BUCKET'  →  env.MY_BUCKET.put(key, value)${NC}\n"
  local binding_name
  prompt_binding_name binding_name || { press_enter; return; }

  local bindings
  bindings=$(_env_get_bindings "$worker") || { press_enter; return; }
  binding_dedup_replace bindings "$binding_name" || { press_enter; return; }

  local updated
  updated=$(echo "$bindings" | jq \
    --arg n  "$binding_name" \
    --arg bn "$bucket" \
    '. + [{type:"r2_bucket", name:$n, bucket_name:$bn}]')

  if _env_put_bindings "$worker" "$updated"; then
    success "R2 bucket '${BLD}${bucket}${NC}' bound to worker '${BLD}${worker}${NC}' as ${C}env.${binding_name}${NC}"
    log "R2 binding added: worker=$worker name=$binding_name bucket=$bucket"
  fi
  press_enter
}

# Remove any resource binding (KV, D1, R2) from a worker by binding name.
binding_remove() {
  header "Remove Resource Binding"
  require_account || return

  local worker
  worker=$(select_worker "Select worker") || { press_enter; return; }
  echo ""

  local bindings
  bindings=$(_env_get_bindings "$worker") || { press_enter; return; }

  # Collect only resource bindings (not plain_text / secret_text)
  local -a res_bindings
  mapfile -t res_bindings < <(echo "$bindings" | \
    jq -r '.[] | select(.type=="kv_namespace" or .type=="d1" or .type=="r2_bucket") |
    "\(.type):\(.name)"')

  if [[ ${#res_bindings[@]} -eq 0 ]]; then
    warn "No resource bindings found for '${worker}'."
    press_enter; return
  fi

  echo -e "${W}Resource bindings on '${worker}':${NC}\n"
  for i in "${!res_bindings[@]}"; do
    local btype bname detail colour
    btype="${res_bindings[$i]%%:*}"
    bname="${res_bindings[$i]#*:}"
    case "$btype" in
      kv_namespace)
        colour="${B}"; detail=$(echo "$bindings" | jq -r --arg n "$bname" '.[] | select(.name==$n) | .namespace_id') ;;
      d1)
        colour="${M}"; detail=$(echo "$bindings" | jq -r --arg n "$bname" '.[] | select(.name==$n) | .database_name // .id') ;;
      r2_bucket)
        colour="${G}"; detail=$(echo "$bindings" | jq -r --arg n "$bname" '.[] | select(.name==$n) | .bucket_name') ;;
      *) colour="${W}"; detail="" ;;
    esac
    printf "  ${colour}%d${NC}. %-25s ${DM}[%s]  %s${NC}\n" \
      "$((i+1))" "$bname" "$btype" "$detail"
  done

  echo -ne "\n${W}Select binding to remove (0=cancel):${NC} "
  local sel
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return
  local idx=$((sel-1))
  [[ $idx -lt 0 || $idx -ge ${#res_bindings[@]} ]] && error "Invalid." && press_enter && return

  local entry="${res_bindings[$idx]}"
  local del_type="${entry%%:*}"
  local del_name="${entry#*:}"

  warn "Removing binding '${BLD}${del_name}${NC}' [${del_type}] from '${worker}'."
  confirm "Continue?" || return

  local updated
  updated=$(echo "$bindings" | jq \
    --arg n "$del_name" --arg t "$del_type" \
    '[.[] | select(not (.name==$n and .type==$t))]')

  if _env_put_bindings "$worker" "$updated"; then
    success "Binding '${BLD}${del_name}${NC}' removed from '${worker}'."
    log "Resource binding removed: worker=$worker name=$del_name type=$del_type"
  fi
  press_enter
}

worker_bindings_menu() {
  while true; do
    header "Resource Bindings  (KV · D1 · R2)"
    echo -e "  ${C}l${NC}.  List all bindings"
    echo -e "  ${C}kv${NC}. ${B}Bind KV namespace${NC}"
    echo -e "  ${C}d1${NC}. ${M}Bind D1 database${NC}"
    echo -e "  ${C}r2${NC}. ${G}Bind R2 bucket${NC}"
    echo -e "  ${C}rm${NC}. ${R}Remove binding${NC}"
    echo -e "  ${C}b${NC}.  ${DM}Back${NC}"
    echo -ne "\n${W}Choice:${NC} "
    read -r choice
    case "$choice" in
      l)  bindings_list ;;
      kv) binding_add_kv ;;
      d1) binding_add_d1 ;;
      r2) binding_add_r2 ;;
      rm) binding_remove ;;
      b)  return ;;
      *)  warn "Invalid option." ;;
    esac
  done
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SYNC RESOURCES TO WORKER NAME
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# Finds all D1/KV/R2 resources currently bound to a worker that have
# a name that doesn't match the worker name, and renames them to match
# (e.g. worker 'fiery-mountain-rd6a', D1 named 'alpha' → renamed to
# 'fiery-mountain-rd6a', then rebound).
#
# Non-interactive API helpers used by sync (and reusable elsewhere).
# Each prints its result to stdout, returns 0 on success / 1 on error.

# url_encode KEY
# Percent-encode a string for use in a URL path segment.
# Passes the value via argv so shell-special characters in the key are safe.
url_encode() {
  python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" \
    2>/dev/null || printf '%s' "$1" | sed 's/ /%20/g'
}

# _d1_snapshot LABEL DB_UUID
# Prints a table-by-table row-count summary and appends to log.
_d1_snapshot() {
  local label="$1" db_uuid="$2"
  local tables_resp tname count_resp count
  local -a table_names
  tables_resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database/${db_uuid}/query" \
    '{"sql":"SELECT name FROM sqlite_master WHERE type='"'"'table'"'"' AND name NOT LIKE '"'"'sqlite_%'"'"' AND name NOT LIKE '"'"'_cf_%'"'"' ORDER BY name"}')
  mapfile -t table_names < <(echo "$tables_resp" \
    | jq -r '.result[0].results[]?.name // empty' 2>/dev/null)
  echo -e "    ${DM}── ${label} snapshot (${db_uuid}) ──${NC}" >&2
  log "D1 snapshot [${label}] db=${db_uuid}"
  if [[ ${#table_names[@]} -eq 0 ]]; then
    echo -e "    ${DM}(no user tables)${NC}" >&2
    log "  (no user tables)"
    return
  fi
  for tname in "${table_names[@]}"; do
    count_resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database/${db_uuid}/query" \
      "$(jq -n --arg t "$tname" '{sql:("SELECT COUNT(*) AS n FROM \"" + $t + "\"")}')")
    count=$(echo "$count_resp" | jq -r '.result[0].results[0].n // "?"' 2>/dev/null)
    printf "    ${DM}%-40s %s row(s)${NC}\n" "$tname" "$count" >&2
    log "  table=${tname} rows=${count}"
  done
}

# _api_d1_create NAME  →  stdout: new UUID
# Creates a D1 database and echoes its UUID. Returns 1 on API error.
# Idempotent: reuses an existing DB with the same name (safe after partial sync).
_api_d1_create() {
  local name="$1"
  local list_resp existing_uuid
  list_resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/d1/database")
  existing_uuid=$(echo "$list_resp" | jq -r --arg n "$name" \
    '.result[]? | select(.name==$n) | .uuid' 2>/dev/null | head -1)
  if [[ -n "$existing_uuid" ]]; then
    warn "D1 '${name}' already exists — reusing UUID ${existing_uuid}" >&2
    echo "$existing_uuid"
    return 0
  fi
  local resp
  resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database" \
    "$(jq -n --arg n "$name" '{name:$n}')")
  cf_check "$resp" || { error "D1 create '${name}': $(cf_errors "$resp")"; return 1; }
  echo "$resp" | jq -r '.result.uuid'
}

# _api_d1_copy SRC_UUID DST_UUID
# Copies all schema objects and data from one D1 database to another.
# Prints progress. Returns 0 even if individual inserts soft-fail (logged).
_api_d1_copy() {
  local src="$1" dst="$2"

  # Fetch all schema objects in dependency order (tables before indexes/triggers/views).
  #
  # BUG FIXED: the previous code used three separate `mapfile` calls to populate
  # s_types[], s_names[], and s_sqls[] by piping the same jq output line-by-line.
  # CREATE TABLE sql from sqlite_master is almost always multi-line, so mapfile
  # split each DDL statement across multiple array slots.  This caused s_sqls[N]
  # to be completely misaligned with s_types[N]/s_names[N]: fragments of one
  # CREATE TABLE were sent as individual queries, producing syntax errors, and
  # the indexes/triggers that followed were mapped to the wrong SQL entirely.
  # Fix: extract each row as a single compact JSON object (one line per object)
  # so mapfile stays aligned, then pull the fields out per-element in the loop.
  local schema_resp
  schema_resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database/${src}/query" \
    '{"sql":"SELECT type, name, sql FROM sqlite_master WHERE sql IS NOT NULL AND type IN ('"'"'table'"'"','"'"'index'"'"') AND name NOT LIKE '"'"'sqlite_%'"'"' AND name NOT LIKE '"'"'_cf_%'"'"' ORDER BY CASE type WHEN '"'"'table'"'"' THEN 0 ELSE 1 END, name"}')

  local -a schema_rows
  mapfile -t schema_rows < <(echo "$schema_resp" \
    | jq -c '.result[0].results[]? | {type,name,sql}' 2>/dev/null)

  # Replay schema DDL one statement at a time via /query (each is a single DDL statement).
  # BUG FIXED: sqlite_master sql values may or may not carry a trailing semicolon.
  # Strip any trailing ';' first, then append exactly one — prevents ';;' syntax errors
  # that caused the destination schema to fail silently (errors were swallowed by &>/dev/null).
  # Errors are now surfaced so schema failures are visible rather than producing an empty DB.
  for row in "${schema_rows[@]}"; do
    local row_type row_name ddl
    row_type=$(printf '%s' "$row" | jq -r '.type // empty')
    row_name=$(printf '%s' "$row" | jq -r '.name // "?"')
    [[ "$row_type" == "table" || "$row_type" == "index" ]] || continue
    [[ "$row_name" == _cf_* ]] && continue
    ddl=$(printf '%s' "$row" | jq -r '.sql // empty')
    [[ -z "$ddl" ]] && continue
    local clean_ddl="${ddl%%;}"
    clean_ddl="${clean_ddl%" "}"
    local schema_resp_dst
    schema_resp_dst=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database/${dst}/query" \
      "$(jq -n --arg s "${clean_ddl};" '{sql:$s}')" 2>/dev/null) || true
    if ! cf_check "$schema_resp_dst" 2>/dev/null; then
      warn "_api_d1_copy: schema DDL failed on dst (${row_type} '${row_name}') — $(cf_errors \"$schema_resp_dst\" 2>/dev/null)" >&2
    fi
  done

  # Build the list of table names to copy data for.
  local -a table_names
  mapfile -t table_names < <(printf '%s\n' "${schema_rows[@]}" \
    | jq -r 'select(.type=="table") | .name' 2>/dev/null)

  # Copy row data for each table, paged 500 rows at a time.
  local t_rows=0
  for tn in "${table_names[@]}"; do
    local off=0
    while true; do
      local rr rrows rc
      rr=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database/${src}/query" \
        "$(jq -n --arg s "SELECT * FROM \"${tn}\" LIMIT 500 OFFSET ${off}" '{sql:$s}')")

      # BUG FIXED: the previous '.result[]?.results // []' expression used the
      # array-iterator '.[]' which, if more than one result object were present,
      # would concatenate their rows — duplicating data.  Use '[0]' to always
      # take exactly the first (and only expected) result set.
      rrows=$(printf '%s' "$rr" | jq '.result[0].results // []')
      rc=$(printf '%s' "$rrows" | jq 'length')
      [[ "$rc" -eq 0 ]] && break

      # Build an array of {sql:"INSERT ..."} objects for the D1 /batch endpoint.
      # /query only accepts one statement per request; /batch accepts an array
      # and executes them all in a single transaction.
      # BUG FIXED (round 2): The D1 *REST* API has no /batch endpoint — that method
      # only exists on the Workers Binding API (inside a Worker script).  Posting to
      # /batch over HTTP returns {"success":false,"errors":["Route not found"]}.
      # The correct endpoint is /query, called once per row with a params array.
      #
      # BUG FIXED (round 3): The previous fix built insert_sql (column list +
      # placeholders) in two separate jq calls on $rrows, then built the params array
      # in a third jq call on each individual $row_json.  Separate jq invocations on
      # different inputs have no guaranteed key-order alignment, so the column list and
      # the params array could silently disagree.  Worse, if $rrows turned out not to
      # be a plain JSON array (e.g. a bare object or empty string from a failed cf_post),
      # `$.[0] | keys_unsorted` returned null → insert_cols was empty → the SQL became
      # `INSERT INTO "t" () VALUES ()` → "near ')': syntax error at offset N".
      #
      # Fix: derive the column list, placeholder string, AND params array together in
      # a single jq call per row, using keys_unsorted on the row itself so the column
      # order and the params order are provably identical.  Log the generated SQL and
      # params on failure so future errors are immediately diagnosable.

      local row_idx=0 page_ok=0
      while IFS= read -r row_json; do
        # Build sql + params in one jq call so column order == params order, guaranteed.
        local row_payload
        row_payload=$(printf '%s' "$row_json" | jq -c --arg t "$tn" '
          . as $row |
          (keys_unsorted) as $cols |
          {
            sql: (
              "INSERT INTO \"" + $t + "\" (" +
              ($cols | map("\"" + . + "\"") | join(", ")) +
              ") VALUES (" + ($cols | map("?") | join(", ")) + ");"
            ),
            params: [
              $cols[] | $row[.] |
              if type == "boolean" then (if . then 1 else 0 end) else . end
            ]
          }' 2>/dev/null)

        if [[ -z "$row_payload" ]]; then
          warn "_api_d1_copy: jq failed to build payload for table '${tn}' row ${row_idx} — skipping" >&2
          log "D1 copy: jq payload empty table=${tn} row=${row_idx} row_json=${row_json}"
          row_idx=$((row_idx + 1))
          continue
        fi

        log "D1 copy: table=${tn} offset=${off} row=${row_idx} payload=${row_payload}"
        local row_resp _err
        row_resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database/${dst}/query" \
          "$row_payload")
        if cf_check "$row_resp" 2>/dev/null; then
          page_ok=$((page_ok + 1))
        else
          _err=$(cf_errors "$row_resp" 2>/dev/null)
          warn "_api_d1_copy: INSERT failed for table '${tn}' row $((off + row_idx)) — ${_err}" >&2
          log "D1 copy INSERT FAILED: table=${tn} row=$((off+row_idx)) err=${_err}"
          log "D1 copy INSERT FAILED payload: ${row_payload}"
          log "D1 copy INSERT FAILED response: ${row_resp}"
        fi
        row_idx=$((row_idx + 1))
      done < <(printf '%s' "$rrows" | jq -c 'if type=="array" then .[] else empty end' 2>/dev/null)

      t_rows=$((t_rows + page_ok))
      if [[ $page_ok -lt rc ]]; then
        warn "_api_d1_copy: table '${tn}' offset ${off}: ${page_ok}/${rc} rows inserted" >&2
      fi

      [[ "$rc" -lt 500 ]] && break
      off=$((off + 500))
    done
  done
  echo "$t_rows"   # caller reads confirmed-inserted row count from stdout
}

# _api_kv_create TITLE  →  stdout: new namespace ID
_api_kv_create() {
  local title="$1"
  local resp
  resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces" \
    "$(jq -n --arg t "$title" '{title:$t}')")
  cf_check "$resp" || { error "KV create '${title}': $(cf_errors "$resp")"; return 1; }
  echo "$resp" | jq -r '.result.id'
}

# _api_kv_copy SRC_NSID DST_NSID
# Copies all keys+values between two KV namespaces. Returns count copied.
_api_kv_copy() {
  local src="$1" dst="$2"
  local kr
  kr=$(cf_get "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${src}/keys?limit=1000")
  local -a knames
  mapfile -t knames < <(echo "$kr" | jq -r '.result[]?.name // empty')
  local kcopied=0
  for kname in "${knames[@]}"; do
    local enc_k kval_tmp
    enc_k=$(url_encode "$kname")
    kval_tmp=$(mktemp)
    # Stream via temp file — $() would strip trailing newlines and corrupt binary
    curl -s -o "$kval_tmp" \
      "${CF_API}/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${src}/values/${enc_k}" \
      -H "Authorization: Bearer ${CF_TOKEN}" 2>/dev/null
    curl -s -X PUT \
      "${CF_API}/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${dst}/values/${enc_k}" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      --data-binary "@${kval_tmp}" &>/dev/null || true
    rm -f "$kval_tmp"
    inc kcopied
  done
  echo "$kcopied"
}

# _api_r2_create NAME  →  stdout: (nothing — R2 create returns no useful ID)
_api_r2_create() {
  local name="$1"
  local resp
  resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/r2/buckets" \
    "$(jq -n --arg n "$name" '{name:$n}')")
  cf_check "$resp" || { error "R2 create '${name}': $(cf_errors "$resp")"; return 1; }
}

# _api_r2_copy SRC_BUCKET DST_BUCKET
# Copies all objects between two R2 buckets. Returns count copied.
_api_r2_copy() {
  local src="$1" dst="$2"
  local lr
  lr=$(cf_get "/accounts/${CF_ACCOUNT_ID}/r2/buckets/${src}/objects?limit=1000")
  local -a okeys
  mapfile -t okeys < <(echo "$lr" | jq -r '.result.objects[]?.key // empty' 2>/dev/null)
  local ocopied=0
  for okey in "${okeys[@]}"; do
    local enc_k tmpf
    enc_k=$(url_encode "$okey")
    tmpf=$(mktemp)
    curl -s -o "$tmpf" \
      "${CF_API}/accounts/${CF_ACCOUNT_ID}/r2/buckets/${src}/objects/${enc_k}" \
      -H "Authorization: Bearer ${CF_TOKEN}" 2>/dev/null
    curl -s -X PUT \
      "${CF_API}/accounts/${CF_ACCOUNT_ID}/r2/buckets/${dst}/objects/${enc_k}" \
      -H "Authorization: Bearer ${CF_TOKEN}" --data-binary "@$tmpf" &>/dev/null || true
    rm -f "$tmpf"
    inc ocopied
  done
  echo "$ocopied"
}

# _sync_worker_resources WORKER [BINDINGS_JSON]
# Non-interactive core sync: finds all D1/KV/R2 resources bound to WORKER
# whose name doesn't match the worker name, then copy-rename-rebind-delete
# each one. Prints progress. Returns 0 if nothing to do or all synced,
# 1 if any resource failed. Populates caller-readable globals:
#   _SYNC_SYNCED  — count of resources successfully synced
#   _SYNC_FAILED  — count of resources that failed
#   _SYNC_SKIPPED — count of workers that had nothing to sync
_SYNC_SYNCED=0 _SYNC_FAILED=0 _SYNC_SKIPPED=0
_sync_worker_resources() {
  local worker="$1"
  local bindings="${2:-}"

  # Fetch bindings if not supplied by caller
  if [[ -z "$bindings" ]]; then
    bindings=$(_env_get_bindings "$worker") || {
      error "Could not fetch bindings for '${worker}'"
      inc _SYNC_FAILED
      return 1
    }
  fi

  # ── Build mismatch list ────────────────────────────────────────────
  local -a mismatch_lines=()

  # BUG FIXED: The CF Workers settings API does NOT return 'database_name' on D1 binding
  # objects — it only returns 'id' (the UUID).  Relying on '.database_name' always yielded
  # null, so the old name displayed as 'null' and the mismatch filter compared null != worker
  # (always true), meaning every D1 binding triggered a sync regardless of whether it was
  # already correctly named.  Fix: look up the real DB name with a GET /d1/database/{uuid}
  # call for each bound D1, then compare that resolved name against the worker name.
  while IFS= read -r d1_line; do
    [[ -z "$d1_line" ]] && continue
    local d1_bname="${d1_line%%|*}"
    local d1_uuid="${d1_line#*|}"
    local d1_info_resp d1_real_name
    d1_info_resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/d1/database/${d1_uuid}" 2>/dev/null)
    d1_real_name=$(echo "$d1_info_resp" | jq -r '.result.name // "(unnamed)"' 2>/dev/null)
    [[ "$d1_real_name" != "$worker" ]] && \
      mismatch_lines+=("d1:${d1_bname}|${d1_uuid}|${d1_real_name}")
  done < <(echo "$bindings" | jq -r \
    '.[] | select(.type=="d1") | "\(.name)|\(.id)"' 2>/dev/null)

  while IFS= read -r nsid; do
    [[ -z "$nsid" ]] && continue
    local ns_resp ns_title bname
    bname=$(echo "$bindings" | jq -r --arg id "$nsid" \
      '.[] | select(.type=="kv_namespace" and .namespace_id==$id) | .name')
    ns_resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${nsid}" 2>/dev/null)
    ns_title=$(echo "$ns_resp" | jq -r '.result.title // ""' 2>/dev/null)
    [[ -n "$ns_title" && "$ns_title" != "$worker" ]] && \
      mismatch_lines+=("kv:${bname}|${nsid}|${ns_title}")
  done < <(echo "$bindings" | jq -r '.[] | select(.type=="kv_namespace") | .namespace_id')

  while IFS= read -r line; do
    [[ -n "$line" ]] && mismatch_lines+=("r2:${line}")
  done < <(echo "$bindings" | jq -r --arg w "$worker" \
    '.[] | select(.type=="r2_bucket" and .bucket_name != $w) |
     "\(.name)|\(.bucket_name)"' 2>/dev/null)

  if [[ ${#mismatch_lines[@]} -eq 0 ]]; then
    inc _SYNC_SKIPPED
    return 0
  fi

  # ── Execute sync for each mismatch ────────────────────────────────
  local synced=0 failed=0

  for entry in "${mismatch_lines[@]}"; do
    local rtype="${entry%%:*}"
    local rest="${entry#*:}"

    case "$rtype" in
      # ── D1 ────────────────────────────────────────────────────────
      d1)
        local binding_varname="${rest%%|*}"; rest="${rest#*|}"
        local old_uuid="${rest%%|*}"; local old_db_name="${rest#*|}"

        echo -e "\n  ${M}D1:${NC} '${old_db_name}' → '${worker}'"
        echo -ne "    ${C}Creating...${NC}"
        local new_uuid
        new_uuid=$(_api_d1_create "$worker") || { echo -e " ${SYM_ERR}"; inc failed; continue; }
        echo -e " ${SYM_OK}"

        echo -e "    ${C}Copying data...${NC}"
        _d1_snapshot "BEFORE (src: ${old_db_name})" "$old_uuid"
        local t_rows
        t_rows=$(_api_d1_copy "$old_uuid" "$new_uuid")
        echo -e "    ${SYM_OK} ~${t_rows} row(s) copied."
        _d1_snapshot "AFTER  (dst: ${worker})" "$new_uuid"

        bindings=$(echo "$bindings" | jq \
          --arg bn "$binding_varname" --arg nid "$new_uuid" --arg nn "$worker" \
          'map(if .type=="d1" and .name==$bn then .id=$nid | .database_name=$nn else . end)')

        if _env_put_bindings "$worker" "$bindings"; then
          # Verify the binding actually stuck
          local verify_resp verify_id
          verify_resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${worker}/settings" 2>/dev/null)
          verify_id=$(printf '%s' "$verify_resp" | jq -r \
            --arg bn "$binding_varname" \
            '.result.bindings[]? | select(.type=="d1" and .name==$bn) | (.id // .database_id)' 2>/dev/null)
          if [[ "$verify_id" == "$new_uuid" ]]; then
            echo -e "    ${SYM_OK} Rebound '${binding_varname}' → D1 '${worker}' ${DM}(verified)${NC}"
          else
            warn "    Rebound reported OK but verify shows id='${verify_id}' (expected '${new_uuid}')"
            warn "    Bind manually: worker=${worker}  binding=${binding_varname}  D1 UUID=${new_uuid}"
            log "put_bindings verify mismatch: worker=${worker} binding=${binding_varname} expected=${new_uuid} got=${verify_id}"
          fi
        else
          warn "    Rebind failed — bind manually: worker=${worker}  binding=${binding_varname}  D1 UUID=${new_uuid}"
          log "sync: rebind failed worker=${worker} binding=${binding_varname} new_uuid=${new_uuid}"
        fi

        echo -ne "    ${C}Deleting old D1 '${old_db_name}'...${NC}"
        local dr
        dr=$(cf_delete "/accounts/${CF_ACCOUNT_ID}/d1/database/${old_uuid}")
        cf_check "$dr" && echo -e " ${SYM_OK}" || echo -e " ${SYM_WARN} (delete failed — clean up manually)"
        log "sync: D1 $old_db_name ($old_uuid) -> $worker ($new_uuid) for worker $worker"
        inc synced
        ;;

      # ── KV ────────────────────────────────────────────────────────
      kv)
        local binding_varname="${rest%%|*}"; rest="${rest#*|}"
        local old_nsid="${rest%%|*}"; local old_title="${rest#*|}"

        echo -e "\n  ${B}KV:${NC} '${old_title}' → '${worker}'"
        echo -ne "    ${C}Creating...${NC}"
        local new_nsid
        new_nsid=$(_api_kv_create "$worker") || { echo -e " ${SYM_ERR}"; inc failed; continue; }
        echo -e " ${SYM_OK}"

        echo -e "    ${C}Copying keys...${NC}"
        local kcopied
        kcopied=$(_api_kv_copy "$old_nsid" "$new_nsid")
        echo -e "    ${SYM_OK} ${kcopied} key(s) copied."

        bindings=$(echo "$bindings" | jq \
          --arg bn "$binding_varname" --arg nid "$new_nsid" \
          'map(if .type=="kv_namespace" and .name==$bn then .namespace_id=$nid else . end)')
        if _env_put_bindings "$worker" "$bindings"; then
          echo -e "    ${SYM_OK} Rebound '${binding_varname}' → KV '${worker}'"
        else
          warn "    Rebind failed."; inc failed; continue
        fi

        echo -ne "    ${C}Deleting old KV '${old_title}'...${NC}"
        local dr
        dr=$(cf_curl_delete "/accounts/${CF_ACCOUNT_ID//[[:space:]]/}/storage/kv/namespaces/${old_nsid}")
        cf_check "$dr" && echo -e " ${SYM_OK}" || echo -e " ${SYM_WARN} (delete failed — clean up manually)"
        log "sync: KV $old_title ($old_nsid) -> $worker ($new_nsid) for worker $worker"
        inc synced
        ;;

      # ── R2 ────────────────────────────────────────────────────────
      r2)
        local binding_varname="${rest%%|*}"; local old_bucket="${rest#*|}"

        echo -e "\n  ${G}R2:${NC} '${old_bucket}' → '${worker}'"
        echo -ne "    ${C}Creating...${NC}"
        _api_r2_create "$worker" || { echo -e " ${SYM_ERR}"; inc failed; continue; }
        echo -e " ${SYM_OK}"

        echo -e "    ${C}Copying objects...${NC}"
        local ocopied
        ocopied=$(_api_r2_copy "$old_bucket" "$worker")
        echo -e "    ${SYM_OK} ${ocopied} object(s) copied."

        bindings=$(echo "$bindings" | jq \
          --arg bn "$binding_varname" --arg nb "$worker" \
          'map(if .type=="r2_bucket" and .name==$bn then .bucket_name=$nb else . end)')
        if _env_put_bindings "$worker" "$bindings"; then
          echo -e "    ${SYM_OK} Rebound '${binding_varname}' → R2 '${worker}'"
        else
          warn "    Rebind failed."; inc failed; continue
        fi

        echo -ne "    ${C}Deleting old R2 '${old_bucket}'...${NC}"
        local dr
        dr=$(cf_delete "/accounts/${CF_ACCOUNT_ID}/r2/buckets/${old_bucket}")
        cf_check "$dr" && echo -e " ${SYM_OK}" || echo -e " ${SYM_WARN} (delete failed — clean up manually)"
        log "sync: R2 $old_bucket -> $worker for worker $worker"
        inc synced
        ;;
    esac
  done

  _SYNC_SYNCED=$(( _SYNC_SYNCED + synced ))
  _SYNC_FAILED=$(( _SYNC_FAILED + failed ))
  [[ $failed -gt 0 ]] && return 1
  return 0
}

# Interactive wrapper — prompts for a single worker, shows plan, confirms.
sync_resources_to_worker() {
  header "Sync Resource Names → Worker Name"
  require_account || return

  local worker
  worker=$(select_worker "Select worker to sync resources for") || { press_enter; return; }
  echo ""

  local bindings
  bindings=$(_env_get_bindings "$worker") || { press_enter; return; }

  # Build mismatch preview (same logic as _sync_worker_resources)
  # BUG FIXED: same database_name issue as _sync_worker_resources — resolve real name via API.
  local -a preview_lines=()
  while IFS= read -r d1_line; do
    [[ -z "$d1_line" ]] && continue
    local d1_bname="${d1_line%%|*}"
    local d1_uuid="${d1_line#*|}"
    local d1_info_resp d1_real_name
    d1_info_resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/d1/database/${d1_uuid}" 2>/dev/null)
    d1_real_name=$(echo "$d1_info_resp" | jq -r '.result.name // "(unnamed)"' 2>/dev/null)
    [[ "$d1_real_name" != "$worker" ]] && \
      preview_lines+=("d1:${d1_bname}|${d1_uuid}|${d1_real_name}")
  done < <(echo "$bindings" | jq -r \
    '.[] | select(.type=="d1") | "\(.name)|\(.id)"' 2>/dev/null)
  while IFS= read -r nsid; do
    [[ -z "$nsid" ]] && continue
    local ns_resp ns_title bname
    bname=$(echo "$bindings" | jq -r --arg id "$nsid" \
      '.[] | select(.type=="kv_namespace" and .namespace_id==$id) | .name')
    ns_resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${nsid}" 2>/dev/null)
    ns_title=$(echo "$ns_resp" | jq -r '.result.title // ""' 2>/dev/null)
    [[ -n "$ns_title" && "$ns_title" != "$worker" ]] && \
      preview_lines+=("kv:${bname}|${nsid}|${ns_title}")
  done < <(echo "$bindings" | jq -r '.[] | select(.type=="kv_namespace") | .namespace_id')
  while IFS= read -r line; do
    [[ -n "$line" ]] && preview_lines+=("r2:${line}")
  done < <(echo "$bindings" | jq -r --arg w "$worker" \
    '.[] | select(.type=="r2_bucket" and .bucket_name != $w) |
     "\(.name)|\(.bucket_name)"' 2>/dev/null)

  if [[ ${#preview_lines[@]} -eq 0 ]]; then
    success "All bound resources already match the worker name '${worker}'."
    press_enter; return
  fi

  echo -e "${BLD}${W}Resources that will be renamed → '${C}${worker}${W}':${NC}\n"
  for line in "${preview_lines[@]}"; do
    local rtype="${line%%:*}" rest="${line#*:}"
    case "$rtype" in
      d1) local bn="${rest%%|*}"; rest="${rest#*|}"; local old_n="${rest#*|}"
          printf "  ${M}D1${NC}   binding %-20s  '%s'  →  '%s'\n" "$bn" "$old_n" "$worker" ;;
      kv) local bn="${rest%%|*}"; rest="${rest#*|}"; local old_t="${rest#*|}"
          printf "  ${B}KV${NC}   binding %-20s  '%s'  →  '%s'\n" "$bn" "$old_t" "$worker" ;;
      r2) local bn="${rest%%|*}"; local old_b="${rest#*|}"
          printf "  ${G}R2${NC}   binding %-20s  '%s'  →  '%s'\n" "$bn" "$old_b" "$worker" ;;
    esac
  done
  echo ""
  warn "Each resource will be copied to a new '${worker}'-named resource, rebound, then the old one deleted."
  confirm "Proceed with sync?" || { press_enter; return; }

  # Reset globals so this single-worker run has clean counts
  _SYNC_SYNCED=0 _SYNC_FAILED=0 _SYNC_SKIPPED=0
  _sync_worker_resources "$worker" "$bindings"

  echo ""
  [[ $_SYNC_SYNCED -gt 0 ]] && success "${_SYNC_SYNCED} resource(s) synced to name '${BLD}${worker}${NC}'."
  [[ $_SYNC_FAILED -gt 0 ]] && warn "${_SYNC_FAILED} resource(s) failed — check output above."
  press_enter
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SYNC ALL  — sync resource names for every worker across all accounts
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# Flow (mirrors pa/na):
#   1. Iterate every stored account
#   2. For each account: fetch all workers; let user toggle-select which
#      ones to include (a=all, numbers, Enter=confirm — same UX as pa)
#   3. Show full plan (which workers have mismatches), confirm once
#   4. Execute: call _sync_worker_resources per selected worker
#   5. Summary table

sync_all() {
  header "Sync All — Multi-Account Resource Name Sync"

  # ── Step 1: collect targets (account::worker) ─────────────────────
  local -a targets=()
  _select_workers_across_accounts targets "check" || { press_enter; return; }

  if [[ ${#targets[@]} -eq 0 ]]; then
    warn "No workers selected. Aborting."
    press_enter; return
  fi

  # ── Step 2: scan for mismatches + show plan ───────────────────────
  echo -e "${BLD}${W}Scanning for mismatched resource names...${NC}\n"

  # plan_info: parallel array with human-readable mismatch summary per target
  local -a plan_info=()
  local total_mismatches=0

  for t in "${targets[@]}"; do
    local t_acct="${t%%::*}" t_worker="${t#*::}"
    _switch_account_context "$t_acct"

    local t_bindings
    t_bindings=$(_env_get_bindings "$t_worker" 2>/dev/null) || t_bindings="[]"

    # Count mismatches for the plan display
    # BUG FIXED: database_name is not returned by the Workers settings API for D1 bindings.
    # Resolve each D1's real name via GET /d1/database/{uuid} before counting mismatches.
    local d1_mm=0
    while IFS= read -r d1_scan_line; do
      [[ -z "$d1_scan_line" ]] && continue
      local d1_scan_uuid="${d1_scan_line#*|}"
      local d1_scan_resp d1_scan_name
      d1_scan_resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/d1/database/${d1_scan_uuid}" 2>/dev/null)
      d1_scan_name=$(echo "$d1_scan_resp" | jq -r '.result.name // ""' 2>/dev/null)
      [[ -n "$d1_scan_name" && "$d1_scan_name" != "$t_worker" ]] && d1_mm=$((d1_mm + 1))
    done < <(echo "$t_bindings" | jq -r '.[] | select(.type=="d1") | "\(.name)|\(.id)"' 2>/dev/null)

    local kv_mm r2_mm
    r2_mm=$(echo "$t_bindings" | jq --arg w "$t_worker" \
      '[.[] | select(.type=="r2_bucket" and .bucket_name != $w)] | length' 2>/dev/null || echo 0)
    # KV: need to check actual namespace title via API
    local kv_mm=0
    while IFS= read -r nsid; do
      [[ -z "$nsid" ]] && continue
      local ns_resp ns_title
      ns_resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${nsid}" 2>/dev/null)
      ns_title=$(echo "$ns_resp" | jq -r '.result.title // ""' 2>/dev/null)
      [[ -n "$ns_title" && "$ns_title" != "$t_worker" ]] && kv_mm=$((kv_mm + 1))
    done < <(echo "$t_bindings" | jq -r '.[] | select(.type=="kv_namespace") | .namespace_id' 2>/dev/null)

    local mm_total=$(( d1_mm + kv_mm + r2_mm ))
    total_mismatches=$(( total_mismatches + mm_total ))

    local mm_detail=""
    [[ $d1_mm -gt 0 ]] && mm_detail+="${M}D1:${d1_mm}${NC} "
    [[ $kv_mm -gt 0 ]] && mm_detail+="${B}KV:${kv_mm}${NC} "
    [[ $r2_mm -gt 0 ]] && mm_detail+="${G}R2:${r2_mm}${NC}"
    [[ -z "$mm_detail" ]] && mm_detail="${DM}already in sync${NC}"

    printf "  ${C}%-20s${NC}  ${W}%s${NC}  %b\n" "$t_acct" "$t_worker" "$mm_detail"

    # Stash bindings alongside the target so we don't re-fetch during execution
    plan_info+=("${t}::BINDINGS::${t_bindings}")
    _restore_account_context
  done

  echo ""
  if [[ $total_mismatches -eq 0 ]]; then
    success "All selected workers already have matching resource names. Nothing to do."
    press_enter; return
  fi

  warn "Resources will be copied to new '${BLD}<worker-name>${NC}'-named resources, rebound, then old ones deleted."
  confirm "Proceed with sync for ${#targets[@]} worker(s)?" || { press_enter; return; }

  # ── Step 3: execute ───────────────────────────────────────────────
  echo ""
  _SYNC_SYNCED=0 _SYNC_FAILED=0 _SYNC_SKIPPED=0
  local -a summary=()

  for entry in "${plan_info[@]}"; do
    local t_acct t_worker t_bindings_raw
    t_acct="${entry%%::*}"; local _tmp="${entry#*::}"
    t_worker="${_tmp%%::BINDINGS::*}"
    t_bindings_raw="${entry##*::BINDINGS::}"

    echo -e "\n${BLD}${C}[ ${t_acct} / ${t_worker} ]${NC}"
    _switch_account_context "$t_acct"

    _sync_worker_resources "$t_worker" "$t_bindings_raw"
    local rc=$?

    if [[ $rc -eq 0 && $_SYNC_SKIPPED -gt 0 ]]; then
      summary+=("${DM}SKIP${NC}  ${t_acct} / ${t_worker}  (already in sync)")
    elif [[ $rc -eq 0 ]]; then
      summary+=("${G}OK${NC}    ${t_acct} / ${t_worker}")
    else
      summary+=("${R}FAIL${NC}  ${t_acct} / ${t_worker}  (${_SYNC_FAILED} resource(s) failed)")
    fi

    _restore_account_context
  done

  # ── Step 4: summary ───────────────────────────────────────────────
  echo -e "\n${BLD}${W}━━━  Sync All — Summary  ━━━${NC}\n"
  for line in "${summary[@]}"; do
    echo -e "  ${line}"
  done
  echo ""
  echo -e "  ${G}${_SYNC_SYNCED} resource(s) synced${NC}  " \
       "${R}${_SYNC_FAILED} failed${NC}  " \
       "${DM}${_SYNC_SKIPPED} worker(s) already in sync${NC}"
  echo ""
  log "sync_all complete: synced=${_SYNC_SYNCED} failed=${_SYNC_FAILED} skipped=${_SYNC_SKIPPED}"
  press_enter
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# TOP-LEVEL BINDINGS MENU
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

bindings_menu() {
  while true; do
    header "Bindings  (KV · D1 · R2 · DO)"
    echo -e "  ${C}l${NC}.   List bindings for a worker"
    echo -e "  ${C}kv${NC}.  ${B}Bind KV namespace → worker${NC}"
    echo -e "  ${C}d1${NC}.  ${M}Bind D1 database → worker${NC}"
    echo -e "  ${C}r2${NC}.  ${G}Bind R2 bucket → worker${NC}"
    echo -e "  ${C}rm${NC}.  ${R}Remove binding${NC}"
    echo ""
    echo -e "  ${C}sy${NC}.  ${Y}Sync resource names → worker${NC}   ${DM}rename mismatched resources for one worker${NC}"
    echo -e "  ${C}sa${NC}.  ${Y}Sync all  ← across all accounts${NC}  ${DM}batch sync every worker on every account${NC}"
    echo -e "  ${C}b${NC}.   ${DM}Back${NC}"
    echo -ne "\n${W}Choice:${NC} "
    read -r choice
    case "$choice" in
      l)  bindings_list ;;
      kv) binding_add_kv ;;
      d1) binding_add_d1 ;;
      r2) binding_add_r2 ;;
      rm) binding_remove ;;
      sy) sync_resources_to_worker ;;
      sa) sync_all ;;
      b)  return ;;
      *)  warn "Invalid option." ;;
    esac
  done
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# PUSH TO ALL  — deploy one .js to selected workers across accounts
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Temporarily switch the active account globals to a named account.
# Call _restore_account_context when done.
_SAVED_TOKEN="" _SAVED_ACCOUNT_ID="" _SAVED_ZONE_ID="" _SAVED_ACCOUNT_NAME=""
_switch_account_context() {
  local name="$1"
  _SAVED_TOKEN="$CF_TOKEN"
  _SAVED_ACCOUNT_ID="$CF_ACCOUNT_ID"
  _SAVED_ZONE_ID="$CF_ZONE_ID"
  _SAVED_ACCOUNT_NAME="$ACTIVE_ACCOUNT_NAME"
  CF_TOKEN=$(get_account_field "$name" "token" | tr -d '[:space:]')
  CF_ACCOUNT_ID=$(get_account_field "$name" "account_id" | tr -d '[:space:]')
  CF_ZONE_ID=$(get_account_field "$name" "zone_id" | tr -d '[:space:]')
  ACTIVE_ACCOUNT_NAME="$name"
}

_restore_account_context() {
  CF_TOKEN="$_SAVED_TOKEN"
  CF_ACCOUNT_ID="$_SAVED_ACCOUNT_ID"
  CF_ZONE_ID="$_SAVED_ZONE_ID"
  ACTIVE_ACCOUNT_NAME="$_SAVED_ACCOUNT_NAME"
}

# _select_workers_across_accounts TARGETS_ARRAY_REF [MARKER_STYLE]
#
# Iterates every stored account, fetches its workers, and shows an interactive
# toggle-select list.  Appends chosen "account_name::worker_name" strings to the
# nameref array passed as the first argument.
#
# MARKER_STYLE controls the selected/unselected symbols:
#   "check"  (default) — [✓] green  /  [ ] red    (deploy / sync contexts)
#   "cross"             — [✗] red    /  [ ] dim    (delete context)
#
# Returns 1 if no accounts are stored; otherwise always returns 0 (callers
# check whether the array is still empty).
_select_workers_across_accounts() {
  local -n _swa_targets="$1"
  local marker_style="${2:-check}"

  local -a all_accounts
  mapfile -t all_accounts < <(list_accounts)
  if [[ ${#all_accounts[@]} -eq 0 ]]; then
    warn "No accounts stored."
    return 1
  fi

  # Pre-fetch every account's worker list concurrently so the interactive
  # selection below isn't stuck waiting on a fresh request per account.
  local _swa_tmp
  _swa_tmp=$(mktemp -d)
  echo -e "${C}Fetching workers from ${#all_accounts[@]} account(s) concurrently...${NC}\n"
  fetch_all_accounts "$_swa_tmp" "/workers/scripts"

  for acct in "${all_accounts[@]}"; do
    echo -e "${BLD}${C}━━━  Account: ${G}${acct}${C}  ━━━${NC}"
    _switch_account_context "$acct"

    if [[ -z "$CF_TOKEN" ]]; then
      warn "No token for '${acct}' — skipping."
      _restore_account_context; echo ""; continue
    fi

    local resp
    resp=$(cat "$_swa_tmp/${acct}.json" 2>/dev/null || echo '{}')
    if ! cf_check "$resp"; then
      warn "Could not fetch workers for '${acct}': $(cf_errors "$resp")"
      _restore_account_context; echo ""; continue
    fi

    local -a wnames
    mapfile -t wnames < <(echo "$resp" | jq -r '.result[].id' 2>/dev/null)
    if [[ ${#wnames[@]} -eq 0 ]]; then
      echo -e "  ${DM}No workers found — skipping.${NC}\n"
      _restore_account_context; continue
    fi

    local -a selected=()
    for _ in "${wnames[@]}"; do selected+=(false); done

    local hint="Space-separate numbers to toggle, 'a' for all, Enter to confirm"
    [[ "$marker_style" == "cross" ]] && \
      hint="Toggle workers to delete. Space-separate numbers, 'a'=all, Enter=done"

    while true; do
      echo -e "\n${DM}${hint}:${NC}"
      for i in "${!wnames[@]}"; do
        local mark
        if [[ "${selected[$i]}" == "true" ]]; then
          [[ "$marker_style" == "cross" ]] && mark="${R}[✗]${NC}" || mark="${G}[✓]${NC}"
        else
          [[ "$marker_style" == "cross" ]] && mark="${DM}[ ]${NC}" || mark="${R}[ ]${NC}"
        fi
        printf "  %b %-2s. %s\n" "$mark" "$((i+1))" "${wnames[$i]}"
      done
      echo -ne "\n${W}Toggle (e.g. 1 3) / a=all / Enter=done:${NC} "
      local input; read -r input
      [[ -z "$input" ]] && break
      if [[ "$input" == "a" || "$input" == "A" ]]; then
        for i in "${!wnames[@]}"; do selected[$i]=true; done; continue
      fi
      for token_num in $input; do
        if [[ "$token_num" =~ ^[0-9]+$ ]]; then
          local idx=$((token_num - 1))
          if [[ $idx -ge 0 && $idx -lt ${#wnames[@]} ]]; then
            [[ "${selected[$idx]}" == "true" ]] && selected[$idx]=false || selected[$idx]=true
          fi
        fi
      done
    done

    for i in "${!wnames[@]}"; do
      [[ "${selected[$i]}" == "true" ]] && _swa_targets+=("${acct}::${wnames[$i]}")
    done

    _restore_account_context; echo ""
  done
  rm -rf "$_swa_tmp"
}

push_to_all() {
  header "Push to All — Multi-Account Deploy"

  # ── Step 1: pick source file ──────────────────────────────────────
  echo -e "${W}Worker source file:${NC}"
  echo -e "  ${C}1${NC}. Pick from ${CFWORKER_DIR}"
  echo -e "  ${C}2${NC}. Manual file path"
  echo -ne "${W}Choice [1/2]:${NC} "
  local src_choice
  read -r src_choice
  local src_file
  case "$src_choice" in
    1)
      src_file=$(pick_cfworker_file) || { press_enter; return; }
      ;;
    2)
      read -rp "$(echo -e "${W}File path:${NC} ")" src_file
      [[ ! -f "$src_file" ]] && error "File not found." && press_enter && return
      ;;
    *)
      warn "Invalid choice." && press_enter && return
      ;;
  esac
  echo -e "\n${SYM_OK} Source: ${C}${src_file}${NC}\n"

  # ── Step 2: D1 binding config ─────────────────────────────────────
  echo -e "${W}D1 auto-bind settings:${NC}"
  echo -e "${DM}Each worker gets a new D1 database named after it, bound under a variable name.${NC}\n"
  local binding_name
  echo -ne "${W}Binding variable name${NC} ${DM}[DB]:${NC} "
  read -r binding_name
  [[ -z "$binding_name" ]] && binding_name="DB"
  if ! [[ "$binding_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    error "Invalid binding name. Letters, numbers, underscores only."
    press_enter; return
  fi
  echo ""

  # ── Step 3: multi-account, multi-worker selection ─────────────────
  # targets is an array of "account_name::worker_name" strings
  local -a targets=()
  _select_workers_across_accounts targets "check" || { press_enter; return; }

  # ── Step 4: confirm before doing anything ─────────────────────────
  if [[ ${#targets[@]} -eq 0 ]]; then
    warn "No workers selected. Aborting."
    press_enter; return
  fi

  echo -e "${BLD}${W}Deploy plan:${NC}\n"
  for t in "${targets[@]}"; do
    local t_acct="${t%%::*}"
    local t_worker="${t#*::}"
    printf "  ${C}%-20s${NC} → worker ${BLD}%s${NC}  ${DM}(new D1: %s, binding: %s)${NC}\n" \
      "$t_acct" "$t_worker" "$t_worker" "$binding_name"
  done
  echo ""
  confirm "Deploy to ${#targets[@]} worker(s)?" || { press_enter; return; }

  # ── Step 5: execute ───────────────────────────────────────────────
  echo ""
  local ok=0 fail=0
  local -a summary=()

  for t in "${targets[@]}"; do
    local t_acct="${t%%::*}"
    local t_worker="${t#*::}"

    echo -e "\n${BLD}${C}[ ${t_acct} / ${t_worker} ]${NC}"
    _switch_account_context "$t_acct"

    # 5a. Deploy
    echo -ne "  ${C}Deploying...${NC}"
    if ! _deploy_worker_file_silent "$t_worker" "$src_file"; then
      echo -e "  ${SYM_ERR} Deploy failed"
      summary+=("${R}FAIL${NC}  ${t_acct} / ${t_worker}  (deploy error)")
      inc fail
      _restore_account_context
      continue
    fi
    echo -e "  ${SYM_OK} Deployed"
    log "push_to_all: deployed $t_worker on $t_acct from $src_file"

    # 5b. Create D1 database named after the worker
    echo -ne "  ${C}Creating D1 '${t_worker}'...${NC}"
    local d1_resp
    d1_resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database" \
      "$(jq -n --arg n "$t_worker" '{name:$n}')")
    local db_id=""
    if cf_check "$d1_resp"; then
      db_id=$(echo "$d1_resp" | jq -r '.result.uuid')
      echo -e "  ${SYM_OK} Created  ${DM}(${db_id})${NC}"
      log "push_to_all: D1 created $t_worker ($db_id) on $t_acct"
    else
      # DB might already exist — try to look it up
      local existing
      existing=$(cf_get "/accounts/${CF_ACCOUNT_ID}/d1/database?per_page=100")
      db_id=$(echo "$existing" | jq -r --arg n "$t_worker" \
        '.result[]? | select(.name==$n) | .uuid' 2>/dev/null | head -1)
      if [[ -n "$db_id" ]]; then
        echo -e "  ${SYM_WARN} Already exists  ${DM}(${db_id})${NC}"
        log "push_to_all: D1 already existed $t_worker ($db_id) on $t_acct"
      else
        echo -e "  ${SYM_ERR} Failed: $(cf_errors "$d1_resp")"
        summary+=("${Y}WARN${NC}  ${t_acct} / ${t_worker}  (deployed, D1 create failed)")
        inc ok
        _restore_account_context
        continue
      fi
    fi

    # 5c. Bind D1 to the worker
    echo -ne "  ${C}Binding D1 as '${binding_name}'...${NC}"
    local bindings
    bindings=$(_env_get_bindings "$t_worker" 2>/dev/null) || bindings="[]"
    # Remove any existing binding with the same name first
    bindings=$(echo "$bindings" | jq --arg n "$binding_name" '[.[] | select(.name != $n)]')
    local updated
    updated=$(echo "$bindings" | jq \
      --arg n  "$binding_name" \
      --arg id "$db_id" \
      --arg dbn "$t_worker" \
      '. + [{type:"d1", name:$n, id:$id, database_name:$dbn}]')
    if _env_put_bindings "$t_worker" "$updated"; then
      echo -e "  ${SYM_OK} Bound as ${C}env.${binding_name}${NC}"
      log "push_to_all: D1 bound $t_worker.$binding_name=$db_id on $t_acct"
      summary+=("${G}OK${NC}    ${t_acct} / ${t_worker}  → env.${binding_name} = ${t_worker}")
      inc ok
    else
      echo -e "  ${SYM_ERR} Bind failed"
      summary+=("${Y}WARN${NC}  ${t_acct} / ${t_worker}  (deployed + D1 created, bind failed)")
      inc ok
    fi

    _restore_account_context
  done

  # ── Step 6: summary ───────────────────────────────────────────────
  echo -e "\n${BLD}${W}━━━  Push to All — Summary  ━━━${NC}\n"
  for line in "${summary[@]}"; do
    echo -e "  ${line}"
  done
  echo ""
  echo -e "  ${G}${ok} succeeded${NC}  ${R}${fail} failed${NC}  out of ${#targets[@]} total"
  echo ""
  log "push_to_all complete: $ok ok, $fail fail, file=$src_file binding=$binding_name"
  press_enter
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# NEW TO ALL  — create + deploy a worker on every account, with the
#               full interactive wizard (source, bindings, subdomain)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# Flow:
#   1. Ask for worker name once (same name reused on every account)
#   2. Ask for source once (file/template/inline — same code everywhere)
#   3. Optional: open editor before deploying anywhere
#   4. Show deploy plan and confirm
#   5. For each account:
#        a. Deploy the worker script
#        b. Run the full post-deploy bindings wizard  (KV/D1/R2/Queue/DO/env/secret)
#        c. Offer workers.dev domain toggle
#   6. Summary

new_to_all() {
  header "New to All — Multi-Account Create & Deploy"

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # MODE A — Naming strategy
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  echo -e "${BLD}${W}Naming strategy:${NC}"
  echo -e "  ${C}1${NC}. ${W}Same name${NC} on every account  ${DM}(e.g. 'my-api' everywhere)${NC}"
  echo -e "  ${C}2${NC}. ${W}Random name${NC} per account      ${DM}(each gets a unique generated name)${NC}"
  echo -e "  ${C}3${NC}. ${W}Prefix + random${NC} per account  ${DM}(e.g. 'myapp-rq7r' — identifiable but unique)${NC}"
  echo -ne "${W}Choice [1/2/3]:${NC} "
  local name_mode
  read -r name_mode
  [[ -z "$name_mode" ]] && name_mode="1"

  # For mode 1: ask for the shared name once up front
  # For mode 2: names are generated per-account in the execution loop
  # For mode 3: ask for prefix once, suffix generated per-account
  local shared_name="" name_prefix=""
  if [[ "$name_mode" == "1" ]]; then
    prompt_worker_name shared_name
  elif [[ "$name_mode" == "3" ]]; then
    echo -ne "${W}Prefix${NC} ${DM}(e.g. 'myapp'):${NC} "
    read -r name_prefix
    if [[ -z "$name_prefix" ]]; then
      error "Prefix cannot be empty."
      press_enter; return
    fi
    if ! [[ "$name_prefix" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
      error "Prefix must be lowercase alphanumeric + hyphens."
      press_enter; return
    fi
    echo -e "${DM}Example: ${C}${name_prefix}-$(gen_worker_name | cut -d- -f3)${NC}"
  fi
  echo ""

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # MODE B — Binding strategy
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  echo -e "${BLD}${W}Binding strategy:${NC}"
  echo -e "  ${C}1${NC}. ${W}Auto${NC} — create D1 + KV + R2 named after the worker, bind automatically"
  echo -e "       ${DM}+ enable workers.dev domain on each account without prompting${NC}"
  echo -e "  ${C}2${NC}. ${W}Manual${NC} — full per-account wizard  ${DM}(current behaviour)${NC}"
  echo -ne "${W}Choice [1/2]:${NC} "
  local bind_mode
  read -r bind_mode
  [[ -z "$bind_mode" ]] && bind_mode="2"
  echo ""

  # For auto mode: ask binding variable names once
  local auto_d1_var="" auto_kv_var="" auto_r2_var=""
  local auto_d1_existing="" auto_kv_existing="" auto_r2_existing=""
  local auto_d1=false auto_kv=false auto_r2=false auto_domain=false
  if [[ "$bind_mode" == "1" ]]; then
    echo -e "${DM}Which resources should be auto-created and bound? (leave blank to skip)${NC}\n"

    # D1
    echo -ne "${M}D1 binding variable name${NC} ${DM}[DB] (blank=skip):${NC} "
    read -r auto_d1_var
    if [[ -n "$auto_d1_var" ]]; then
      auto_d1=true
    else
      echo -ne "${M}Use default 'DB'? [y/N]:${NC} "
      local _d1_def; read -r _d1_def
      if [[ "$_d1_def" =~ ^[Yy]$ ]]; then
        auto_d1_var="DB"; auto_d1=true
      fi
    fi
    if [[ "$auto_d1" == "true" ]]; then
      echo -ne "${M}  Reuse an existing D1 by name instead of creating new? [y/N]:${NC} "
      local _d1_reuse; read -r _d1_reuse
      if [[ "$_d1_reuse" =~ ^[Yy]$ ]]; then
        echo -ne "${M}  Existing D1 name:${NC} "
        read -r auto_d1_existing
        [[ -z "$auto_d1_existing" ]] && { warn "No name entered, will create new."; auto_d1_existing=""; }
      fi
    fi

    # KV
    echo -ne "${B}KV binding variable name${NC} ${DM}[KV] (blank=skip):${NC} "
    read -r auto_kv_var
    if [[ -n "$auto_kv_var" ]]; then
      auto_kv=true
    else
      echo -ne "${B}Use default 'KV'? [y/N]:${NC} "
      local _kv_def; read -r _kv_def
      if [[ "$_kv_def" =~ ^[Yy]$ ]]; then
        auto_kv_var="KV"; auto_kv=true
      fi
    fi
    if [[ "$auto_kv" == "true" ]]; then
      echo -ne "${B}  Reuse an existing KV namespace by title instead of creating new? [y/N]:${NC} "
      local _kv_reuse; read -r _kv_reuse
      if [[ "$_kv_reuse" =~ ^[Yy]$ ]]; then
        echo -ne "${B}  Existing KV title:${NC} "
        read -r auto_kv_existing
        [[ -z "$auto_kv_existing" ]] && { warn "No name entered, will create new."; auto_kv_existing=""; }
      fi
    fi

    # R2
    echo -ne "${G}R2 binding variable name${NC} ${DM}[BUCKET] (blank=skip):${NC} "
    read -r auto_r2_var
    if [[ -n "$auto_r2_var" ]]; then
      auto_r2=true
    else
      echo -ne "${G}Use default 'BUCKET'? [y/N]:${NC} "
      local _r2_def; read -r _r2_def
      if [[ "$_r2_def" =~ ^[Yy]$ ]]; then
        auto_r2_var="BUCKET"; auto_r2=true
      fi
    fi
    if [[ "$auto_r2" == "true" ]]; then
      echo -ne "${G}  Reuse an existing R2 bucket by name instead of creating new? [y/N]:${NC} "
      local _r2_reuse; read -r _r2_reuse
      if [[ "$_r2_reuse" =~ ^[Yy]$ ]]; then
        echo -ne "${G}  Existing R2 bucket name:${NC} "
        read -r auto_r2_existing
        [[ -z "$auto_r2_existing" ]] && { warn "No name entered, will create new."; auto_r2_existing=""; }
      fi
    fi

    echo -ne "${C}Enable workers.dev domain automatically? [y/N]:${NC} "
    local _dom_ans; read -r _dom_ans
    [[ "$_dom_ans" =~ ^[Yy]$ ]] && auto_domain=true

    # Validate any variable names that were entered
    local _vname
    for _vname in "$auto_d1_var" "$auto_kv_var" "$auto_r2_var"; do
      [[ -z "$_vname" ]] && continue
      if ! [[ "$_vname" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        error "Invalid binding name '${_vname}'. Letters, numbers, underscores only."
        press_enter; return
      fi
    done
    echo ""
  fi

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Source file (chosen once, same code deployed everywhere)
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Use shared_name as a placeholder filename; for random-name mode
  # we use a generic filename since the real names aren't known yet.
  local _fname_hint="${shared_name:-worker}"

  echo -e "${W}Worker source:${NC}"
  echo -e "  ${C}1${NC}. Pick from ${CFWORKER_DIR}"
  echo -e "  ${C}2${NC}. Manual file path"
  echo -e "  ${C}3${NC}. Paste code inline"
  echo -e "  ${C}4${NC}. Use generated template"
  local _last_src_label=""
  [[ -f "$NA_LAST_SRC_FILE" ]] && _last_src_label=$(cat "$NA_LAST_SRC_FILE" 2>/dev/null)
  if [[ -n "$_last_src_label" && -f "$_last_src_label" ]]; then
    echo -e "  ${C}5${NC}. Same as last time  ${DM}($(basename "$_last_src_label"))${NC}"
    echo -ne "${W}Choice [1-5]:${NC} "
  else
    echo -ne "${W}Choice [1-4]:${NC} "
  fi
  local src_choice
  read -r src_choice

  mkdir -p "$WORKERS_DIR"
  local src_file

  case "$src_choice" in
    1)
      src_file=$(pick_cfworker_file) || { press_enter; return; }
      ;;
    2)
      read -rp "$(echo -e "${W}File path:${NC} ")" src_file
      [[ ! -f "$src_file" ]] && error "File not found." && press_enter && return
      ;;
    3)
      src_file="$WORKERS_DIR/${_fname_hint}_inline.js"
      paste_code_to_file "$src_file"
      success "Saved to $src_file"
      ;;
    4)
      src_file="$WORKERS_DIR/${_fname_hint}.js"
      write_worker_template "$src_file" "$_fname_hint"
      success "Template created at $src_file"
      ;;
    5)
      if [[ -n "$_last_src_label" && -f "$_last_src_label" ]]; then
        src_file="$_last_src_label"
      else
        warn "No previous source on record." && press_enter && return
      fi
      ;;
    *)
      warn "Invalid choice." && press_enter && return
      ;;
  esac

  # Persist the chosen source file for next time
  echo "$src_file" > "$NA_LAST_SRC_FILE"

  echo -e "\n${SYM_OK} Source: ${C}${src_file}${NC}"

  # Optional pre-deploy editor pass
  echo ""
  confirm "Open in editor before deploying?" && "${EDITOR:-nano}" "$src_file"
  echo ""

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Enumerate accounts + build deploy plan preview
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  local -a all_accounts
  mapfile -t all_accounts < <(list_accounts)
  if [[ ${#all_accounts[@]} -eq 0 ]]; then
    warn "No accounts stored."
    press_enter; return
  fi

  local -a valid_accounts=()
  # For random-name mode, pre-generate one name per account so the plan
  # can show them before the user confirms.
  local -a acct_names=()

  for acct in "${all_accounts[@]}"; do
    _switch_account_context "$acct"
    if [[ -z "$CF_TOKEN" ]]; then
      printf "  ${R}✗${NC}  %-20s  ${DM}(no token — will skip)${NC}\n" "$acct"
      _restore_account_context
      continue
    fi
    valid_accounts+=("$acct")
    if [[ "$name_mode" == "2" ]]; then
      acct_names+=("$(gen_worker_name)")
    elif [[ "$name_mode" == "3" ]]; then
      local _sfx
      _sfx=$(gen_worker_name | awk -F- '{print $NF}')
      acct_names+=("${name_prefix}-${_sfx}")
    else
      acct_names+=("$shared_name")
    fi
    _restore_account_context
  done

  if [[ ${#valid_accounts[@]} -eq 0 ]]; then
    warn "No accounts have tokens. Nothing to do."
    press_enter; return
  fi

  # ── Account selection ──────────────────────────────────────────────
  echo -e "${BLD}${W}Select accounts to deploy to:${NC}"
  echo -e "  ${DM}Space-separated numbers, ranges (1-3), exclusions (!2), or Enter for all${NC}\n"
  for i in "${!valid_accounts[@]}"; do
    printf "  ${C}%2d${NC}. %s\n" "$((i+1))" "${valid_accounts[$i]}"
  done
  echo ""
  echo -ne "${W}Accounts [default: all]:${NC} "
  local _acct_sel
  read -r _acct_sel

  if [[ -n "$_acct_sel" ]]; then
    local -a _sel_accounts=()
    local -a _sel_names=()
    local _tok
    for _tok in $_acct_sel; do
      if [[ "$_tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        # Range like 1-3
        local _rlo="${BASH_REMATCH[1]}" _rhi="${BASH_REMATCH[2]}"
        if (( _rlo < 1 || _rhi > ${#valid_accounts[@]} || _rlo > _rhi )); then
          error "Invalid range '$_tok'. Aborting."
          press_enter; return
        fi
        local _ri
        for (( _ri=_rlo; _ri<=_rhi; _ri++ )); do
          local _ridx=$(( _ri - 1 ))
          _sel_accounts+=("${valid_accounts[$_ridx]}")
          _sel_names+=("${acct_names[$_ridx]}")
        done
      elif [[ "$_tok" =~ ^!([0-9]+)$ ]]; then
        # Exclude like !2 — add all except that index
        local _excl="${BASH_REMATCH[1]}"
        if (( _excl < 1 || _excl > ${#valid_accounts[@]} )); then
          error "Invalid exclusion '$_tok'. Aborting."
          press_enter; return
        fi
        local _ei
        for _ei in "${!valid_accounts[@]}"; do
          if (( _ei + 1 != _excl )); then
            _sel_accounts+=("${valid_accounts[$_ei]}")
            _sel_names+=("${acct_names[$_ei]}")
          fi
        done
      elif [[ "$_tok" =~ ^[0-9]+$ ]]; then
        if (( _tok < 1 || _tok > ${#valid_accounts[@]} )); then
          error "Invalid selection '$_tok'. Aborting."
          press_enter; return
        fi
        local _idx=$(( _tok - 1 ))
        _sel_accounts+=("${valid_accounts[$_idx]}")
        _sel_names+=("${acct_names[$_idx]}")
      else
        error "Invalid token '$_tok'. Use numbers, ranges (1-3), or exclusions (!2)."
        press_enter; return
      fi
    done
    if [[ ${#_sel_accounts[@]} -eq 0 ]]; then
      warn "No accounts selected. Aborting."
      press_enter; return
    fi
    valid_accounts=("${_sel_accounts[@]}")
    acct_names=("${_sel_names[@]}")
  fi
  echo ""

  # Print the full plan
  echo -e "${BLD}${W}Deploy plan:${NC}\n"
  for i in "${!valid_accounts[@]}"; do
    local _pa="${valid_accounts[$i]}"
    local _pn="${acct_names[$i]}"
    printf "  ${G}✓${NC}  ${C}%-20s${NC}  worker: ${BLD}%s${NC}\n" "$_pa" "$_pn"
    if [[ "$bind_mode" == "1" ]]; then
      [[ "$auto_d1" == "true" ]]     && printf "       ${M}D1:     %s  → env.%s${NC}\n" "$_pn" "$auto_d1_var"
      [[ "$auto_kv" == "true" ]]     && printf "       ${B}KV:     %s  → env.%s${NC}\n" "$_pn" "$auto_kv_var"
      [[ "$auto_r2" == "true" ]]     && printf "       ${G}R2:     %s  → env.%s${NC}\n" "$_pn" "$auto_r2_var"
      [[ "$auto_domain" == "true" ]] && printf "       ${C}workers.dev: enabled${NC}\n"
    else
      printf "       ${DM}bindings: manual wizard per account${NC}\n"
    fi
  done
  echo ""
  confirm "Proceed with ${#valid_accounts[@]} account(s)?" || { press_enter; return; }

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Execute
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  local ok=0 fail=0
  local -a summary=()

  for i in "${!valid_accounts[@]}"; do
    local acct="${valid_accounts[$i]}"
    local name="${acct_names[$i]}"

    echo -e "\n${BLD}${C}━━━  Account: ${G}${acct}${C}  ━━━${NC}"
    echo -e "${DM}Worker name: ${W}${name}${NC}\n"
    _switch_account_context "$acct"

    # ── Deploy ────────────────────────────────────────────────────
    echo -ne "${C}Deploying '${BLD}${name}${NC}${C}'...${NC}"
    local _token="${CF_TOKEN//[[:space:]]/}"
    local _acct_id="${CF_ACCOUNT_ID//[[:space:]]/}"
    local _mod
    _mod=$(basename "$src_file")
    local _meta
    _meta=$(jq -n \
      --arg main "$_mod" \
      --arg compat "$(date -u +%Y-%m-%d)" \
      '{main_module: $main, compatibility_date: $compat, compatibility_flags: []}')
    local _tmp
    _tmp=$(mktemp)
    local _http
    _http=$(curl -s -w "%{http_code}" -o "$_tmp" \
      -X PUT "${CF_API}/accounts/${_acct_id}/workers/scripts/${name}" \
      -H "Authorization: Bearer ${_token}" \
      -F "metadata=${_meta};type=application/json" \
      -F "${_mod}=@${src_file};type=application/javascript+module" 2>/dev/null)
    local _curl_exit=$?
    local _resp
    _resp=$(cat "$_tmp" 2>/dev/null || echo "")
    rm -f "$_tmp"

    local _deploy_ok=true
    if [[ $_curl_exit -ne 0 || -z "$_resp" ]]; then
      echo -e " ${SYM_ERR}"
      error "Deploy failed (HTTP ${_http}, curl exit ${_curl_exit})"
      summary+=("${R}FAIL${NC}  ${acct} / ${name}  (network error)||")
      inc fail
      _deploy_ok=false
    elif ! cf_check "$_resp"; then
      echo -e " ${SYM_ERR}"
      echo "$_resp" | jq -r '.errors[]? | "  [\(.code)] \(.message)"' 2>/dev/null
      summary+=("${R}FAIL${NC}  ${acct} / ${name}  (API error)||")
      inc fail
      _deploy_ok=false
    fi
    if [[ "$_deploy_ok" == "false" ]]; then
      _restore_account_context
      continue
    fi
    echo -e " ${SYM_OK}"
    log "new_to_all: deployed $name on $acct"
    backup_worker "$name" "$src_file"
    _worker_cache_clear

    # ── Bindings ──────────────────────────────────────────────────
    if [[ "$bind_mode" == "1" ]]; then
      # AUTO MODE: create each resource, bind it, no prompts

      if [[ "$auto_d1" == "true" ]]; then
        local _d1id=""
        if [[ -n "$auto_d1_existing" ]]; then
          # Reuse existing D1 — look it up by name
          echo -ne "  ${M}Looking up existing D1 '${auto_d1_existing}'...${NC}"
          local _d1ex_r
          _d1ex_r=$(cf_get "/accounts/${CF_ACCOUNT_ID}/d1/database?per_page=100")
          _d1id=$(echo "$_d1ex_r" | jq -r --arg n "$auto_d1_existing" \
            '.result[]? | select(.name==$n) | .uuid' 2>/dev/null | head -1)
          if [[ -n "$_d1id" ]]; then
            echo -e " ${SYM_OK}  ${DM}(${_d1id})${NC}"
          else
            echo -e " ${SYM_ERR} Not found"
            summary+=("${Y}WARN${NC}  ${acct} / ${name}  (D1 '${auto_d1_existing}' not found)")
          fi
        else
          echo -ne "  ${M}Creating D1 '${name}'...${NC}"
          local _d1r
          _d1r=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database" \
            "$(jq -n --arg n "$name" '{name:$n}')")
          if cf_check "$_d1r"; then
            _d1id=$(echo "$_d1r" | jq -r '.result.uuid')
            echo -e " ${SYM_OK}  ${DM}(${_d1id})${NC}"
            log "new_to_all: D1 created $name ($_d1id) on $acct"
          else
            # Already exists — look it up
            local _d1ex
            _d1ex=$(cf_get "/accounts/${CF_ACCOUNT_ID}/d1/database?per_page=100")
            _d1id=$(echo "$_d1ex" | jq -r --arg n "$name" \
              '.result[]? | select(.name==$n) | .uuid' 2>/dev/null | head -1)
            if [[ -n "$_d1id" ]]; then
              echo -e " ${SYM_WARN} Already exists  ${DM}(${_d1id})${NC}"
            else
              echo -e " ${SYM_ERR} $(cf_errors "$_d1r")"
              summary+=("${Y}WARN${NC}  ${acct} / ${name}  (D1 create failed)")
            fi
          fi
        fi
        if [[ -n "$_d1id" ]]; then
          echo -ne "  ${M}Binding D1 as '${auto_d1_var}'...${NC}"
          local _d1bindings
          _d1bindings=$(_env_get_bindings "$name" 2>/dev/null) || _d1bindings="[]"
          _d1bindings=$(echo "$_d1bindings" | jq --arg n "$auto_d1_var" '[.[] | select(.name != $n)]')
          local _d1updated
          _d1updated=$(echo "$_d1bindings" | jq \
            --arg n "$auto_d1_var" --arg id "$_d1id" --arg dbn "$name" \
            '. + [{type:"d1", name:$n, id:$id, database_name:$dbn}]')
          if _env_put_bindings "$name" "$_d1updated"; then
            echo -e " ${SYM_OK}"
            log "new_to_all: D1 bound $name.$auto_d1_var=$_d1id on $acct"
          else
            echo -e " ${SYM_ERR} bind failed"
          fi
        fi
      fi

      if [[ "$auto_kv" == "true" ]]; then
        local _kvid=""
        if [[ -n "$auto_kv_existing" ]]; then
          echo -ne "  ${B}Looking up existing KV '${auto_kv_existing}'...${NC}"
          local _kvex_r
          _kvex_r=$(cf_get "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces?per_page=100")
          _kvid=$(echo "$_kvex_r" | jq -r --arg t "$auto_kv_existing" \
            '.result[]? | select(.title==$t) | .id' 2>/dev/null | head -1)
          if [[ -n "$_kvid" ]]; then
            echo -e " ${SYM_OK}  ${DM}(${_kvid})${NC}"
          else
            echo -e " ${SYM_ERR} Not found"
            summary+=("${Y}WARN${NC}  ${acct} / ${name}  (KV '${auto_kv_existing}' not found)")
          fi
        else
          echo -ne "  ${B}Creating KV '${name}'...${NC}"
          local _kvr
          _kvr=$(cf_post "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces" \
            "$(jq -n --arg t "$name" '{title:$t}')")
          if cf_check "$_kvr"; then
            _kvid=$(echo "$_kvr" | jq -r '.result.id')
            echo -e " ${SYM_OK}  ${DM}(${_kvid})${NC}"
            log "new_to_all: KV created $name ($_kvid) on $acct"
          else
            local _kvex
            _kvex=$(cf_get "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces?per_page=100")
            _kvid=$(echo "$_kvex" | jq -r --arg t "$name" \
              '.result[]? | select(.title==$t) | .id' 2>/dev/null | head -1)
            if [[ -n "$_kvid" ]]; then
              echo -e " ${SYM_WARN} Already exists  ${DM}(${_kvid})${NC}"
            else
              echo -e " ${SYM_ERR} $(cf_errors "$_kvr")"
              summary+=("${Y}WARN${NC}  ${acct} / ${name}  (KV create failed)")
            fi
          fi
        fi
        if [[ -n "$_kvid" ]]; then
          echo -ne "  ${B}Binding KV as '${auto_kv_var}'...${NC}"
          local _kvbindings
          _kvbindings=$(_env_get_bindings "$name" 2>/dev/null) || _kvbindings="[]"
          _kvbindings=$(echo "$_kvbindings" | jq --arg n "$auto_kv_var" '[.[] | select(.name != $n)]')
          local _kvupdated
          _kvupdated=$(echo "$_kvbindings" | jq \
            --arg n "$auto_kv_var" --arg id "$_kvid" \
            '. + [{type:"kv_namespace", name:$n, namespace_id:$id}]')
          if _env_put_bindings "$name" "$_kvupdated"; then
            echo -e " ${SYM_OK}"
            log "new_to_all: KV bound $name.$auto_kv_var=$_kvid on $acct"
          else
            echo -e " ${SYM_ERR} bind failed"
          fi
        fi
      fi

      if [[ "$auto_r2" == "true" ]]; then
        local _r2name _r2ok=false
        if [[ -n "$auto_r2_existing" ]]; then
          _r2name="$auto_r2_existing"
          echo -e "  ${G}Reusing R2 bucket '${_r2name}'${NC}"
          _r2ok=true
        else
          # R2 bucket names must be lowercase alphanumeric + hyphens
          _r2name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
          echo -ne "  ${G}Creating R2 '${_r2name}'...${NC}"
          local _r2r
          _r2r=$(cf_post "/accounts/${CF_ACCOUNT_ID}/r2/buckets" \
            "$(jq -n --arg n "$_r2name" '{name:$n}')")
          if cf_check "$_r2r"; then
            echo -e " ${SYM_OK}"
            _r2ok=true
            log "new_to_all: R2 created $_r2name on $acct"
          else
            local _r2err
            _r2err=$(echo "$_r2r" | jq -r '.errors[0].code // ""')
            if [[ "$_r2err" == "10006" ]] || echo "$_r2r" | grep -qi 'already exist'; then
              echo -e " ${SYM_WARN} Already exists"
              _r2ok=true
            else
              echo -e " ${SYM_ERR} $(cf_errors "$_r2r")"
              summary+=("${Y}WARN${NC}  ${acct} / ${name}  (R2 create failed)")
            fi
          fi
        fi
        if [[ "$_r2ok" == "true" ]]; then
          echo -ne "  ${G}Binding R2 as '${auto_r2_var}'...${NC}"
          local _r2bindings
          _r2bindings=$(_env_get_bindings "$name" 2>/dev/null) || _r2bindings="[]"
          _r2bindings=$(echo "$_r2bindings" | jq --arg n "$auto_r2_var" '[.[] | select(.name != $n)]')
          local _r2updated
          _r2updated=$(echo "$_r2bindings" | jq \
            --arg n "$auto_r2_var" --arg bn "$_r2name" \
            '. + [{type:"r2_bucket", name:$n, bucket_name:$bn}]')
          if _env_put_bindings "$name" "$_r2updated"; then
            echo -e " ${SYM_OK}"
            log "new_to_all: R2 bound $name.$auto_r2_var=$_r2name on $acct"
          else
            echo -e " ${SYM_ERR} bind failed"
          fi
        fi
      fi

      if [[ "$auto_domain" == "true" ]]; then
        echo -ne "  ${C}Enabling workers.dev domain...${NC}"
        local _subr
        _subr=$(cf_curl_post_raw \
          "/accounts/${CF_ACCOUNT_ID//[[:space:]]/}/workers/scripts/${name}/subdomain" \
          '{"enabled":true}')
        if cf_check "$_subr"; then
          echo -e " ${SYM_OK}"
          log "new_to_all: workers.dev enabled for $name on $acct"
        else
          echo -e " ${SYM_WARN} $(cf_errors "$_subr")"
        fi
      fi

    else
      # MANUAL MODE: full per-account bindings wizard
      echo ""
      echo -e "${BLD}${C}Bindings for '${name}' @ ${G}${acct}${C}:${NC}"
      echo -e "${DM}KV / D1 / R2 / Queue / DO / env vars / secrets${NC}"
      echo -ne "${W}Set up bindings now? [y/N]:${NC} "
      local _bind_ans
      read -r _bind_ans
      if [[ "$_bind_ans" =~ ^[Yy]$ ]]; then
        while true; do
          echo ""
          echo -e "${BLD}${W}Bindings for '${C}${name}${W}' @ ${G}${acct}${W}:${NC}"
          echo -e "  ${C}kv${NC}. ${B}Add KV namespace binding${NC}"
          echo -e "  ${C}d1${NC}. ${M}Add D1 database binding${NC}"
          echo -e "  ${C}r2${NC}. ${G}Add R2 bucket binding${NC}"
          echo -e "  ${C}dq${NC}. ${Y}Add Queue binding${NC}"
          echo -e "  ${C}do${NC}. ${M}Add Durable Object binding${NC}"
          echo -e "  ${C}ev${NC}. ${C}Add plain env variable${NC}"
          echo -e "  ${C}sc${NC}. ${Y}Add secret${NC}"
          echo -e "  ${C}ls${NC}. ${DM}List current bindings${NC}"
          echo -e "  ${C}done${NC}. Next account →"
          echo -ne "\n${W}Choice:${NC} "
          local _bchoice
          read -r _bchoice
          case "$_bchoice" in
            kv)   _post_deploy_add_kv     "$name" ;;
            d1)   _post_deploy_add_d1     "$name" ;;
            r2)   _post_deploy_add_r2     "$name" ;;
            dq)   _post_deploy_add_queue  "$name" ;;
            do)   _post_deploy_add_do     "$name" ;;
            ev)   _post_deploy_add_env    "$name" ;;
            sc)   _post_deploy_add_secret "$name" ;;
            ls)
              echo ""
              local _blist
              _blist=$(_env_get_bindings "$name") || { warn "Could not fetch bindings."; continue; }
              local _btotal
              _btotal=$(echo "$_blist" | jq 'length')
              echo -e "${BLD}${W}Current bindings (${_btotal}):${NC}"
              if [[ "$_btotal" -eq 0 ]]; then
                echo -e "  ${DM}(none yet)${NC}"
              else
                echo "$_blist" | jq -r '.[] | "  [\(.type)] \(.name)"' 2>/dev/null \
                  | while IFS= read -r _bl; do echo -e "  ${C}${_bl#  }${NC}"; done
              fi
              echo ""
              ;;
            done|d|"")
              echo -e "${G}Bindings done for '${acct}'.${NC}"
              break
              ;;
            *) warn "Invalid option." ;;
          esac
        done
      fi

      # workers.dev toggle (manual mode only — auto mode already handled it above)
      echo ""
      echo -ne "${W}Enable workers.dev domain for '${C}${name}${W}'? [y/N]:${NC} "
      local _sub_ans
      read -r _sub_ans
      if [[ "$_sub_ans" =~ ^[Yy]$ ]]; then
        echo ""
        _toggle_workers_dev_domain "$name"
      fi
    fi

    # Capture workers.dev URL for the summary table
    local _wdev_url=""
    if [[ "$bind_mode" == "1" && "$auto_domain" == "true" ]] || \
       [[ "$bind_mode" == "2" ]]; then
      local _sub_info
      _sub_info=$(cf_get "/accounts/${CF_ACCOUNT_ID}/workers/subdomain" 2>/dev/null || true)
      local _subdomain
      _subdomain=$(echo "$_sub_info" | jq -r '.result.subdomain // ""' 2>/dev/null)
      [[ -n "$_subdomain" ]] && _wdev_url="https://${name}.${_subdomain}.workers.dev"
    fi
    summary+=("${G}OK${NC}    ${acct} / ${name}||${_wdev_url}")
    inc ok
    _restore_account_context
  done

  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  # Summary
  # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  echo -e "\n${BLD}${W}━━━  New to All — Summary  ━━━${NC}\n"
  printf "  %-6s  %-30s  %-26s  %s\n" "Status" "Account" "Worker" "workers.dev URL"
  printf "  %-6s  %-30s  %-26s  %s\n" "──────" "──────────────────────────────" "──────────────────────────" "───────────────────────────────────"
  for line in "${summary[@]}"; do
    local _s_status _s_rest _s_acct_name _s_url
    _s_status="${line%%  *}"
    _s_rest="${line#*  }"
    _s_acct_name="${_s_rest%%||*}"
    _s_url="${_s_rest##*||}"
    printf "  %-6b  %-56b  %s\n" "$_s_status" "$_s_acct_name" "$_s_url"
  done
  echo ""
  echo -e "  ${G}${ok} succeeded${NC}  ${R}${fail} failed${NC}  out of ${#valid_accounts[@]} total"
  echo ""
  log "new_to_all complete: ok=$ok fail=$fail name_mode=$name_mode bind_mode=$bind_mode"
  press_enter
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# DELETE ALL  — wipe workers + their bound resources across accounts
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# Flow mirrors push_to_all:
#   1. Iterate every stored account
#   2. For each account: fetch workers + their bindings, let the user
#      toggle-select which workers to nuke (same UX as push_to_all)
#   3. Show a full delete plan with every resource that will be erased
#   4. Single CAPITAL-YES confirmation gate before anything is touched
#   5. Execute: for every selected worker —
#        a. Read its current bindings from the API
#        b. Delete each bound D1 database (by UUID from the binding)
#        c. Delete each bound KV namespace (by namespace_id)
#        d. Delete each bound R2 bucket (by bucket_name)
#        e. Delete the worker script itself
#   6. Print a per-resource summary with ok/fail counts
#
# Resources NOT auto-deleted (intentionally):
#   • Durable Object namespaces  — DO namespaces are shared across
#     workers and cannot be safely deleted if other scripts reference
#     them; the user must handle those manually.
#   • plain_text / secret_text bindings — these are just env vars
#     embedded in the worker script, not standalone CF resources.

delete_all() {
  header "Delete All — Multi-Account Wipe"

  warn "This will ${R}${BLD}permanently delete${NC} selected workers and their"
  warn "bound D1 databases, KV namespaces, and R2 buckets."
  echo -e "${DM}Durable Object namespaces are excluded (shared resources — delete manually).${NC}\n"

  # ── Step 1: collect targets across all accounts ───────────────────
  # Each entry: "account_name::worker_name"
  local -a targets=()
  _select_workers_across_accounts targets "cross" || { press_enter; return; }

  # ── Step 2: nothing selected ──────────────────────────────────────
  if [[ ${#targets[@]} -eq 0 ]]; then
    warn "No workers selected. Aborting."
    press_enter; return
  fi

  # ── Step 3: build delete plan (fetch bindings per worker) ─────────
  echo -e "\n${BLD}${R}━━━  Delete Plan  ━━━${NC}\n"

  # Parallel arrays for the execution phase — avoids re-fetching bindings
  # plan_entry format:  "acct::worker::d1:uuid:name,...::kv:id:title,...::r2:name,..."
  # We store the serialised binding lists as colon/comma strings so we can
  # pass them through a plain bash array without associative-array gymnastics.
  local -a plan_entries=()

  for t in "${targets[@]}"; do
    local t_acct="${t%%::*}"
    local t_worker="${t#*::}"
    printf "  ${R}✗${NC}  ${BLD}%-20s${NC}  worker: ${C}%s${NC}\n" "$t_acct" "$t_worker"

    _switch_account_context "$t_acct"

    # Fetch bindings for this worker
    local braw
    braw=$(_env_get_bindings "$t_worker" 2>/dev/null) || braw="[]"

    # Collect D1 bindings  →  "uuid:dbname" pairs joined by commas
    local d1_list kv_list r2_list
    d1_list=$(echo "$braw" | jq -r \
      '[.[] | select(.type=="d1") | "\(.id):\(.database_name // .id)"] | join(",")' \
      2>/dev/null || echo "")
    kv_list=$(echo "$braw" | jq -r \
      '[.[] | select(.type=="kv_namespace") | "\(.namespace_id):\(.name)"] | join(",")' \
      2>/dev/null || echo "")
    r2_list=$(echo "$braw" | jq -r \
      '[.[] | select(.type=="r2_bucket") | "\(.bucket_name):\(.name)"] | join(",")' \
      2>/dev/null || echo "")

    # Print bound resources in the plan
    if [[ -n "$d1_list" ]]; then
      IFS=',' read -ra _d1s <<< "$d1_list"
      for _d1 in "${_d1s[@]}"; do
        local _d1_name="${_d1#*:}"
        printf "       ${M}D1 database:   %s${NC}\n" "$_d1_name"
      done
    fi
    if [[ -n "$kv_list" ]]; then
      IFS=',' read -ra _kvs <<< "$kv_list"
      for _kv in "${_kvs[@]}"; do
        local _kv_title="${_kv#*:}"
        printf "       ${B}KV namespace:  %s${NC}\n" "$_kv_title"
      done
    fi
    if [[ -n "$r2_list" ]]; then
      IFS=',' read -ra _r2s <<< "$r2_list"
      for _r2 in "${_r2s[@]}"; do
        local _r2_bucket="${_r2%%:*}"
        printf "       ${G}R2 bucket:     %s${NC}\n" "$_r2_bucket"
      done
    fi
    if [[ -z "$d1_list" && -z "$kv_list" && -z "$r2_list" ]]; then
      printf "       ${DM}(no bound D1/KV/R2 resources)${NC}\n"
    fi
    echo ""

    plan_entries+=("${t_acct}::${t_worker}::${d1_list}::${kv_list}::${r2_list}")
    _restore_account_context
  done

  # ── Step 4: hard confirmation gate ────────────────────────────────
  echo -e "${R}${BLD}This action is IRREVERSIBLE. All listed resources will be permanently erased.${NC}"
  echo -ne "${Y}${BLD}Type YES in capitals to confirm, anything else to abort:${NC} "
  local gate
  read -r gate
  if [[ "$gate" != "YES" ]]; then
    info "Aborted — nothing was deleted."
    press_enter; return
  fi

  # ── Step 5: execute ───────────────────────────────────────────────
  echo ""
  local ok=0 fail=0
  local -a summary=()

  for entry in "${plan_entries[@]}"; do
    # Parse the packed entry string
    local e_acct e_worker e_d1 e_kv e_r2
    e_acct="${entry%%::*}";   entry="${entry#*::}"
    e_worker="${entry%%::*}"; entry="${entry#*::}"
    e_d1="${entry%%::*}";     entry="${entry#*::}"
    e_kv="${entry%%::*}";     entry="${entry#*::}"
    e_r2="$entry"

    echo -e "\n${BLD}${C}[ ${e_acct} / ${e_worker} ]${NC}"
    _switch_account_context "$e_acct"

    local worker_ok=true

    # 5a. Delete D1 databases
    if [[ -n "$e_d1" ]]; then
      IFS=',' read -ra _d1_pairs <<< "$e_d1"
      for _pair in "${_d1_pairs[@]}"; do
        local _d1_uuid="${_pair%%:*}"
        local _d1_name="${_pair#*:}"
        echo -ne "  ${M}Deleting D1 '${_d1_name}'...${NC}"
        local _d1_resp
        _d1_resp=$(cf_delete "/accounts/${CF_ACCOUNT_ID}/d1/database/${_d1_uuid}")
        if cf_check "$_d1_resp"; then
          echo -e " ${SYM_OK}"
          log "delete_all: D1 deleted $_d1_name ($_d1_uuid) on $e_acct"
          summary+=("${G}OK${NC}    D1 '${_d1_name}' on ${e_acct}")
        else
          echo -e " ${SYM_ERR} $(cf_errors "$_d1_resp")"
          log "delete_all: D1 delete FAILED $_d1_name on $e_acct: $(cf_errors "$_d1_resp")"
          summary+=("${R}FAIL${NC}  D1 '${_d1_name}' on ${e_acct}: $(cf_errors "$_d1_resp")")
          worker_ok=false
        fi
      done
    fi

    # 5b. Delete KV namespaces
    if [[ -n "$e_kv" ]]; then
      IFS=',' read -ra _kv_pairs <<< "$e_kv"
      for _pair in "${_kv_pairs[@]}"; do
        local _kv_id="${_pair%%:*}"
        local _kv_title="${_pair#*:}"
        echo -ne "  ${B}Deleting KV '${_kv_title}'...${NC}"
        local _kv_resp
        _kv_resp=$(cf_curl_delete "/accounts/${CF_ACCOUNT_ID//[[:space:]]/}/storage/kv/namespaces/${_kv_id}")
        if cf_check "$_kv_resp"; then
          echo -e " ${SYM_OK}"
          log "delete_all: KV deleted $_kv_title ($_kv_id) on $e_acct"
          summary+=("${G}OK${NC}    KV '${_kv_title}' on ${e_acct}")
        else
          echo -e " ${SYM_ERR} $(cf_errors "$_kv_resp")"
          log "delete_all: KV delete FAILED $_kv_title on $e_acct: $(cf_errors "$_kv_resp")"
          summary+=("${R}FAIL${NC}  KV '${_kv_title}' on ${e_acct}: $(cf_errors "$_kv_resp")")
          worker_ok=false
        fi
      done
    fi

    # 5c. Delete R2 buckets
    if [[ -n "$e_r2" ]]; then
      IFS=',' read -ra _r2_pairs <<< "$e_r2"
      for _pair in "${_r2_pairs[@]}"; do
        local _r2_bucket="${_pair%%:*}"
        local _r2_binding="${_pair#*:}"
        echo -ne "  ${G}Deleting R2 '${_r2_bucket}'...${NC}"
        local _r2_resp
        _r2_resp=$(cf_delete "/accounts/${CF_ACCOUNT_ID}/r2/buckets/${_r2_bucket}")
        if cf_check "$_r2_resp"; then
          echo -e " ${SYM_OK}"
          log "delete_all: R2 deleted $_r2_bucket on $e_acct"
          summary+=("${G}OK${NC}    R2 '${_r2_bucket}' on ${e_acct}")
        else
          echo -e " ${SYM_ERR} $(cf_errors "$_r2_resp")"
          log "delete_all: R2 delete FAILED $_r2_bucket on $e_acct: $(cf_errors "$_r2_resp")"
          summary+=("${R}FAIL${NC}  R2 '${_r2_bucket}' on ${e_acct}: $(cf_errors "$_r2_resp")")
          worker_ok=false
        fi
      done
    fi

    # 5d. Delete the worker script itself (last — resources first)
    echo -ne "  ${C}Deleting worker '${e_worker}'...${NC}"
    local _w_resp
    _w_resp=$(cf_curl_delete "/accounts/${CF_ACCOUNT_ID//[[:space:]]/}/workers/scripts/${e_worker}")
    if cf_check "$_w_resp"; then
      echo -e " ${SYM_OK}"
      rm -f "$WORKERS_DIR/${e_worker}.js"
      _worker_cache_clear
      log "delete_all: worker deleted $e_worker on $e_acct"
      if [[ "$worker_ok" == "true" ]]; then
        summary+=("${G}OK${NC}    Worker '${e_worker}' on ${e_acct}")
        inc ok
      else
        summary+=("${Y}WARN${NC}  Worker '${e_worker}' on ${e_acct} deleted, but some resources failed")
        inc ok
      fi
    else
      echo -e " ${SYM_ERR} $(cf_errors "$_w_resp")"
      log "delete_all: worker delete FAILED $e_worker on $e_acct: $(cf_errors "$_w_resp")"
      summary+=("${R}FAIL${NC}  Worker '${e_worker}' on ${e_acct}: $(cf_errors "$_w_resp")")
      inc fail
    fi

    _restore_account_context
  done

  # ── Step 6: summary ───────────────────────────────────────────────
  echo -e "\n${BLD}${R}━━━  Delete All — Summary  ━━━${NC}\n"
  for line in "${summary[@]}"; do
    echo -e "  ${line}"
  done
  echo ""
  echo -e "  ${G}${ok} worker(s) deleted${NC}  ${R}${fail} failed${NC}  out of ${#plan_entries[@]} total"
  echo ""
  log "delete_all complete: $ok ok, $fail fail"
  press_enter
}

workers_menu() {
  while true; do
    header "Workers"
    echo -e "  ${C}l${NC}.  List workers"
    echo -e "  ${C}ll${NC}. List workers ${DM}(all accounts)${NC}"
    echo -e "  ${C}n${NC}.  New worker"
    echo -e "  ${C}e${NC}.  Edit worker"
    echo -e "  ${C}p${NC}.  Deploy worker"
    echo -e "  ${C}pa${NC}. ${M}Push to All${NC}  ${DM}multi-account deploy + D1 bind${NC}"
    echo -e "  ${C}na${NC}. ${M}New to All${NC}   ${DM}multi-account create + full wizard${NC}"
    echo -e "  ${C}da${NC}. ${R}Delete All${NC}   ${DM}multi-account wipe workers + resources${NC}"
    echo -e "  ${C}v${NC}.  View worker code"
    echo -e "  ${C}r${NC}.  Rollback deployment"
    echo -e "  ${C}t${NC}.  Tail logs (live)"
    echo -e "  ${C}rt${NC}. Manage routes"
    echo -e "  ${C}sd${NC}. ${G}Toggle workers.dev domain${NC}"
    echo -e "  ${C}x${NC}.  ${G}Env vars & secrets${NC}"
    echo -e "  ${C}d${NC}.  ${R}Delete worker${NC}"
    echo -e "  ${C}b${NC}.  ${DM}Back${NC}"
    echo -ne "\n${W}Choice:${NC} "
    read -r choice
    case "$choice" in
      l)  list_workers ;;
      ll) list_workers_all ;;
      n)  create_worker ;;
      e)  edit_worker ;;
      p)  deploy_worker ;;
      pa) push_to_all ;;
      na) new_to_all ;;
      da) delete_all ;;
      v)  view_worker_code ;;
      r)  rollback_worker ;;
      t)  tail_worker_logs ;;
      rt) worker_routes ;;
      sd) worker_subdomain ;;
      x)  worker_envs_menu ;;
      d)  delete_worker ;;
      b)  return ;;
      *)  warn "Invalid option." ;;
    esac
  done
}

kv_menu() {
  while true; do
    header "KV Namespaces"
    echo -e "  ${C}l${NC}.  List namespaces"
    echo -e "  ${C}n${NC}.  New namespace"
    echo -e "  ${C}rn${NC}. ${Y}Rename namespace${NC}  ${DM}create+copy+rebind+delete${NC}"
    echo -e "  ${C}dn${NC}. ${R}Delete namespace${NC}"
    echo -e "  ${C}k${NC}.  List keys"
    echo -e "  ${C}g${NC}.  Get value"
    echo -e "  ${C}s${NC}.  Set value"
    echo -e "  ${C}d${NC}.  Delete key"
    echo -e "  ${C}bd${NC}. ${R}Bulk delete keys${NC}"
    echo -e "  ${C}b${NC}.  ${DM}Back${NC}"
    echo -ne "\n${W}Choice:${NC} "
    read -r choice
    case "$choice" in
      l)  kv_list_namespaces ;;
      n)  kv_create_namespace ;;
      rn) kv_rename_namespace ;;
      dn) kv_delete_namespace ;;
      k)  kv_list_keys ;;
      g)  kv_get_value ;;
      s)  kv_set_value ;;
      d)  kv_delete_key ;;
      bd) kv_bulk_delete ;;
      b)  return ;;
      *)  warn "Invalid." ;;
    esac
  done
}

d1_menu() {
  while true; do
    header "D1 Databases"
    echo -e "  ${C}l${NC}.  List databases"
    echo -e "  ${C}n${NC}.  New database"
    echo -e "  ${C}rn${NC}. ${Y}Rename database${NC}  ${DM}create+copy+rebind+delete${NC}"
    echo -e "  ${C}q${NC}.  Execute SQL query"
    echo -e "  ${C}t${NC}.  List tables"
    echo -e "  ${C}ex${NC}. Export to .sql"
    echo -e "  ${C}im${NC}. Import from .sql"
    echo -e "  ${C}d${NC}.  ${R}Delete database${NC}"
    echo -e "  ${C}b${NC}.  ${DM}Back${NC}"
    echo -ne "\n${W}Choice:${NC} "
    read -r choice
    case "$choice" in
      l)  d1_list ;;
      n)  d1_create ;;
      rn) d1_rename ;;
      q)  d1_query ;;
      t)  d1_tables ;;
      ex) d1_export ;;
      im) d1_import ;;
      d)  d1_delete ;;
      b)  return ;;
      *)  warn "Invalid." ;;
    esac
  done
}

r2_menu() {
  while true; do
    header "R2 Buckets"
    echo -e "  ${C}l${NC}.  List buckets"
    echo -e "  ${C}n${NC}.  New bucket"
    echo -e "  ${C}rn${NC}. ${Y}Rename bucket${NC}  ${DM}create+copy+rebind+delete${NC}"
    echo -e "  ${C}o${NC}.  List objects"
    echo -e "  ${C}u${NC}.  Upload object"
    echo -e "  ${C}dl${NC}. Download object"
    echo -e "  ${C}do${NC}. ${R}Delete object${NC}"
    echo -e "  ${C}db${NC}. ${R}Delete bucket${NC}"
    echo -e "  ${C}b${NC}.  ${DM}Back${NC}"
    echo -ne "\n${W}Choice:${NC} "
    read -r choice
    case "$choice" in
      l)  r2_list_buckets ;;
      n)  r2_create_bucket ;;
      rn) r2_rename_bucket ;;
      o)  r2_list_objects ;;
      u)  r2_upload_object ;;
      dl) r2_download_object ;;
      do) r2_delete_object ;;
      db) r2_delete_bucket ;;
      b)  return ;;
      *)  warn "Invalid." ;;
    esac
  done
}

do_menu() {
  while true; do
    header "Durable Objects"
    echo -e "  ${C}l${NC}. List namespaces"
    echo -e "  ${C}i${NC}. List instances"
    echo -e "  ${C}n${NC}. New namespace"
    echo -e "  ${C}b${NC}. ${DM}Back${NC}"
    echo -ne "\n${W}Choice:${NC} "
    read -r choice
    case "$choice" in
      l) do_list_namespaces ;;
      i) do_list_objects ;;
      n) do_create_namespace ;;
      b) return ;;
      *) warn "Invalid." ;;
    esac
  done
}

gh_menu() {
  while true; do
    header "GitHub Integration"
    echo -e "  ${C}c${NC}. Clone / update repo"
    echo -e "  ${C}lk${NC}. Link repo to worker"
    echo -e "  ${C}l${NC}. List linked repos"
    echo -e "  ${C}p${NC}. Pull latest & deploy"
    echo -e "  ${C}g${NC}. View git log"
    echo -e "  ${C}b${NC}. ${DM}Back${NC}"
    echo -ne "\n${W}Choice:${NC} "
    read -r choice
    case "$choice" in
      c)  gh_clone_repo ;;
      lk) gh_link_worker ;;
      l)  gh_list_linked ;;
      p)  gh_pull_and_deploy ;;
      g)  gh_view_log ;;
      b)  return ;;
      *)  warn "Invalid." ;;
    esac
  done
}

settings_menu() {
  while true; do
    header "Settings"
    echo -e "  ${C}sw${NC}. Switch account"
    echo -e "  ${C}a${NC}. Add / Re-login account"
    echo -e "  ${C}rt${NC}. ${G}Refresh Token${NC} (mint new permanent token)"
    echo -e "  ${C}lo${NC}. ${R}Logout${NC} (revoke token on Cloudflare)"
    echo -e "  ${C}r${NC}. Remove account"
    echo -e "  ${C}l${NC}. List accounts"
    echo -e "  ${C}lg${NC}. View log"
    echo -e "  ${C}z${NC}. Set default Zone ID"
    echo -e "  ${C}cs${NC}. ${C}Cache status${NC}"
    echo -e "  ${C}cw${NC}. ${C}Warm cache${NC}     ${DM}(re-fetch all workers + bindings)${NC}"
    echo -e "  ${C}cx${NC}. ${R}Clear cache${NC}     ${DM}(force fresh API calls next time)${NC}"
    echo -e "  ${C}b${NC}. ${DM}Back${NC}"
    echo -ne "\n${W}Choice:${NC} "
    read -r choice
    case "$choice" in
      sw) switch_account; load_active_account ;;
      a)  add_account ;;
      rt) refresh_permanent_token ;;
      lo) logout_account ;;
      r)  remove_account ;;
      l)
        header "All Accounts"
        local current
        current=$(cat "$CURRENT_ACCOUNT" 2>/dev/null || echo "")
        while IFS= read -r acct; do
          local marker=""
          [[ "$acct" == "$current" ]] && marker=" ${G}← active${NC}"
          local email
          email=$(get_account_field "$acct" "email")
          echo -e "  ${C}${acct}${NC}${marker}  ${DM}${email}${NC}"
        done < <(list_accounts)
        press_enter
        ;;
      lg)
        header "Recent Log"
        tail -30 "$LOG_FILE" 2>/dev/null || warn "No log entries yet."
        press_enter
        ;;
      z)
        require_account || continue
        read -rp "$(echo -e "${W}Default Zone ID for '${ACTIVE_ACCOUNT_NAME}':${NC} ")" zid
        [[ -z "$zid" ]] && continue
        CF_ZONE_ID="$zid"
        local data
        data=$(load_accounts_data)
        data=$(echo "$data" | jq --arg n "$ACTIVE_ACCOUNT_NAME" --arg z "$zid" '.[$n].zone_id = $z')
        save_accounts_data "$data"
        success "Zone ID saved."
        press_enter
        ;;
      cs) cache_status ;;
      cw)
        header "Warm Cache"
        cache_warm_all
        press_enter
        ;;
      cx)
        header "Clear Cache"
        warn "This will delete all cached API responses."
        confirm "Clear entire cache?" || { press_enter; continue; }
        cache_invalidate
        success "Cache cleared. Next API call will fetch live data."
        press_enter
        ;;
      b) return ;;
      *) warn "Invalid." ;;
    esac
  done
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# KV NAMESPACES
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Create a new KV namespace inline (used by select_kv_namespace's "new" option).
# Prints "id|title" to stdout on success, returns 1 on cancel/failure.
_create_kv_namespace_inline() {
  local default_name="${1:-}"
  local name
  if [[ -n "$default_name" ]]; then
    read -rp "$(echo -e "${W}New KV namespace title${NC} ${DM}[${default_name}]:${NC} ")" name >&2
    [[ -z "$name" ]] && name="$default_name"
  else
    read -rp "$(echo -e "${W}New KV namespace title:${NC} ")" name >&2
    [[ -z "$name" ]] && { info "Cancelled." >&2; return 1; }
  fi
  echo -ne "${C}Creating KV namespace '${name}'...${NC}" >&2
  local resp
  resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces" "{\"title\":\"$name\"}")
  if ! cf_check "$resp"; then
    echo -e " ${SYM_ERR}" >&2
    error "$(cf_errors "$resp")" >&2
    return 1
  fi
  echo -e " ${SYM_OK}" >&2
  local ns_id
  ns_id=$(echo "$resp" | jq -r '.result.id')
  log "KV namespace created (inline): $name ($ns_id)"
  cache_invalidate "$ACTIVE_ACCOUNT_NAME" "kv"
  printf '%s|%s' "$ns_id" "$name"
}

# Interactive KV namespace picker — prints "id|title" to stdout, returns 1 on cancel.
# Args: prompt  [default_name]  [allow_create=true]
# Pass allow_create=false for destructive contexts (delete) to hide the "new" option.
select_kv_namespace() {
  local prompt="${1:-Select namespace}"
  local default_name="${2:-}"
  local allow_create="${3:-true}"
  local resp
  if ! resp=$(cache_get "$ACTIVE_ACCOUNT_NAME" "kv" 2>/dev/null); then
    resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces?per_page=100")
    if cf_check "$resp"; then
      cache_put "$ACTIVE_ACCOUNT_NAME" "kv" "$resp"
    fi
  fi
  if ! cf_check "$resp"; then
    error "$(cf_errors "$resp")" >&2
    return 1
  fi
  local count
  count=$(echo "$resp" | jq '.result | length')
  local -a ids titles
  mapfile -t ids    < <(echo "$resp" | jq -r '.result[].id')
  mapfile -t titles < <(echo "$resp" | jq -r '.result[].title')
  echo -e "${W}${prompt}:${NC}\n" >&2
  if [[ "$allow_create" == "true" ]]; then
    if [[ -n "$default_name" ]]; then
      echo -e "  ${G}n${NC}. ${BLD}+ Create new KV namespace${NC} ${DM}(suggested: ${default_name})${NC}" >&2
    else
      echo -e "  ${G}n${NC}. ${BLD}+ Create new KV namespace${NC}" >&2
    fi
  fi
  if [[ "$count" -eq 0 ]]; then
    echo -e "  ${DM}(no existing namespaces)${NC}" >&2
  fi
  for i in "${!ids[@]}"; do
    printf "  ${C}%d${NC}. %-35s ${DM}%s${NC}\n" "$((i+1))" "${titles[$i]}" "${ids[$i]}" >&2
  done
  local cancel_hint="0=cancel"
  [[ "$allow_create" == "true" ]] && cancel_hint="0=cancel, n=new"
  echo -ne "\n${W}Choice (${cancel_hint}):${NC} " >&2
  local sel
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return 1
  if [[ "$allow_create" == "true" && ( "$sel" == "n" || "$sel" == "N" ) ]]; then
    _create_kv_namespace_inline "$default_name"
    return $?
  fi
  local idx=$((sel-1))
  if [[ $idx -lt 0 || $idx -ge ${#ids[@]} ]]; then
    error "Invalid selection." >&2
    return 1
  fi
  printf '%s|%s' "${ids[$idx]}" "${titles[$idx]}"
}

kv_list_namespaces() {
  header "KV Namespaces"
  require_account || return
  local resp
  resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces?per_page=100")
  if cf_check "$resp"; then
    local count
    count=$(echo "$resp" | jq '.result | length')
    echo -e "${W}${count} namespace(s):${NC}\n"
    echo "$resp" | jq -r '.result[]? | "  \(.title)\n    ID: \(.id)\n"' 2>/dev/null
  else
    error "$(cf_errors "$resp")"
  fi
  press_enter
}

kv_create_namespace() {
  header "Create KV Namespace"
  require_account || return
  local name
  read -rp "$(echo -e "${W}Namespace title:${NC} ")" name
  [[ -z "$name" ]] && return
  local resp
  resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces" \
    "{\"title\":\"$name\"}")
  if cf_check "$resp"; then
    local ns_id
    ns_id=$(echo "$resp" | jq -r '.result.id')
    success "Created namespace '${name}'"
    echo -e "  ${DM}ID: ${ns_id}${NC}"
    log "KV namespace created: $name ($ns_id)"
  else
    error "$(cf_errors "$resp")"
  fi
  press_enter
}

kv_delete_namespace() {
  header "Delete KV Namespace"
  require_account || return
  local picked
  picked=$(select_kv_namespace "Select namespace to delete" "" false) || { press_enter; return; }
  local ns_id ns_title
  split_pipe ns_id ns_title "$picked"
  echo ""
  warn "This will permanently delete namespace '${BLD}${ns_title}${NC}' and ${R}ALL its keys${NC}."
  echo -e "  ${DM}ID: ${ns_id}${NC}\n"
  confirm "Are you sure?" || return
  local resp
  resp=$(cf_curl_delete "/accounts/${CF_ACCOUNT_ID//[[:space:]]/}/storage/kv/namespaces/${ns_id}")
  if cf_check "$resp"; then
    success "Namespace '${BLD}${ns_title}${NC}' deleted."
    log "KV namespace deleted: $ns_title ($ns_id)"
  else
    error "Delete failed: $(cf_errors "$resp")"
  fi
  press_enter
}

kv_list_keys() {
  header "KV — List Keys"
  require_account || return
  local ns_id
  read -rp "$(echo -e "${W}Namespace ID:${NC} ")" ns_id
  [[ -z "$ns_id" ]] && return
  local prefix=""
  read -rp "$(echo -e "${W}Key prefix filter (optional):${NC} ")" prefix
  local endpoint="/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${ns_id}/keys?limit=100"
  [[ -n "$prefix" ]] && endpoint+="&prefix=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$prefix'))" 2>/dev/null || echo "$prefix")"
  local resp
  resp=$(cf_get "$endpoint")
  if cf_check "$resp"; then
    echo "$resp" | jq -r '.result[]? | "  \(.name)\t\(if .expiration then "(expires: "+(.expiration|todate)+")" else "" end)"' 2>/dev/null
  else
    error "$(cf_errors "$resp")"
  fi
  press_enter
}

kv_get_value() {
  header "KV — Get Value"
  require_account || return
  local ns_id key
  read -rp "$(echo -e "${W}Namespace ID:${NC} ")" ns_id
  read -rp "$(echo -e "${W}Key:${NC} ")" key
  [[ -z "$ns_id" || -z "$key" ]] && return
  local encoded_key
  encoded_key=$(printf '%s' "$key" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))" 2>/dev/null || echo "$key")
  local resp
  resp=$(curl -sf "${CF_API}/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${ns_id}/values/${encoded_key}" \
    -H "Authorization: Bearer ${CF_TOKEN}" 2>/dev/null)
  echo -e "\n${W}Value:${NC}"
  echo "$resp" | jq . 2>/dev/null || echo "$resp"
  press_enter
}

kv_set_value() {
  header "KV — Set Value"
  require_account || return
  local ns_id key value expiry
  read -rp "$(echo -e "${W}Namespace ID:${NC} ")" ns_id
  read -rp "$(echo -e "${W}Key:${NC} ")" key
  read -rp "$(echo -e "${W}Value:${NC} ")" value
  read -rp "$(echo -e "${W}TTL seconds (optional):${NC} ")" expiry
  [[ -z "$ns_id" || -z "$key" ]] && return
  local encoded_key
  encoded_key=$(printf '%s' "$key" | python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))" 2>/dev/null || echo "$key")
  local resp
  if [[ -n "$expiry" ]]; then
    resp=$(curl -sf -X PUT "${CF_API}/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${ns_id}/values/${encoded_key}?expiration_ttl=${expiry}" \
      -H "Authorization: Bearer ${CF_TOKEN}" --data "$value" 2>/dev/null || echo '{"success":false}')
  else
    resp=$(curl -sf -X PUT "${CF_API}/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${ns_id}/values/${encoded_key}" \
      -H "Authorization: Bearer ${CF_TOKEN}" --data "$value" 2>/dev/null || echo '{"success":false}')
  fi
  cf_check "$resp" && success "Key set." || error "$(cf_errors "$resp")"
  press_enter
}

kv_delete_key() {
  header "KV — Delete Key"
  require_account || return
  local ns_id key
  read -rp "$(echo -e "${W}Namespace ID:${NC} ")" ns_id
  read -rp "$(echo -e "${W}Key:${NC} ")" key
  [[ -z "$ns_id" || -z "$key" ]] && return
  confirm "Delete key '$key'?" || return
  local resp
  resp=$(cf_delete "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${ns_id}/values/${key}")
  cf_check "$resp" && success "Deleted." || error "$(cf_errors "$resp")"
  press_enter
}



kv_bulk_delete() {
  header "KV — Bulk Delete Keys"
  require_account || return
  local ns_id prefix
  read -rp "$(echo -e "${W}Namespace ID:${NC} ")" ns_id
  [[ -z "$ns_id" ]] && return
  read -rp "$(echo -e "${W}Key prefix to delete (leave blank = ALL keys):${NC} ")" prefix

  echo -e "${C}Fetching keys...${NC}"
  local endpoint="/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${ns_id}/keys?limit=1000"
  [[ -n "$prefix" ]] && endpoint+="&prefix=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$prefix'))" 2>/dev/null || echo "$prefix")"
  local resp
  resp=$(cf_get "$endpoint")
  if ! cf_check "$resp"; then
    error "$(cf_errors "$resp")"
    press_enter; return
  fi

  local keys_json
  keys_json=$(echo "$resp" | jq '[.result[]?.name]')
  local count
  count=$(echo "$keys_json" | jq 'length')
  [[ "$count" -eq 0 ]] && info "No keys found matching that prefix." && press_enter && return

  echo -e "
${W}Found ${R}${count}${W} key(s) to delete:${NC}"
  echo "$keys_json" | jq -r '.[:10][] | "  \(.)"' 2>/dev/null
  [[ "$count" -gt 10 ]] && echo -e "  ${DM}... and $((count - 10)) more${NC}"

  warn "This will permanently delete all ${count} key(s) from the namespace."
  confirm "Proceed with bulk delete?" || return

  # Cloudflare bulk delete accepts up to 10,000 keys per request as a JSON array
  local delete_payload
  delete_payload=$(echo "$keys_json" | jq '[.[] | {name: .}]')
  local del_resp
  del_resp=$(cf_curl_post_raw \
    "/accounts/${CF_ACCOUNT_ID//[[:space:]]/}/storage/kv/namespaces/${ns_id}/bulk/delete" \
    "$delete_payload")
  if cf_check "$del_resp"; then
    success "Deleted ${count} key(s) from namespace."
    log "KV bulk delete: ns=$ns_id prefix='$prefix' count=$count"
  else
    error "Bulk delete failed: $(cf_errors "$del_resp")"
  fi
  press_enter
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# D1 DATABASES
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Create a new D1 database inline (used by select_d1_database's "new" option).
# Prints "uuid|name" to stdout on success, returns 1 on cancel/failure.
_create_d1_database_inline() {
  local default_name="${1:-}"
  local name
  if [[ -n "$default_name" ]]; then
    read -rp "$(echo -e "${W}New D1 database name${NC} ${DM}[${default_name}]:${NC} ")" name >&2
    [[ -z "$name" ]] && name="$default_name"
  else
    read -rp "$(echo -e "${W}New D1 database name:${NC} ")" name >&2
    [[ -z "$name" ]] && { info "Cancelled." >&2; return 1; }
  fi
  echo -ne "${C}Creating D1 database '${name}'...${NC}" >&2
  local resp
  resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database" "{\"name\":\"$name\"}")
  if ! cf_check "$resp"; then
    echo -e " ${SYM_ERR}" >&2
    error "$(cf_errors "$resp")" >&2
    return 1
  fi
  echo -e " ${SYM_OK}" >&2
  local db_id
  db_id=$(echo "$resp" | jq -r '.result.uuid')
  log "D1 database created (inline): $name ($db_id)"
  cache_invalidate "$ACTIVE_ACCOUNT_NAME" "d1"
  printf '%s|%s' "$db_id" "$name"
}

# Interactive D1 database picker — prints "uuid|name" to stdout, returns 1 on cancel.
# Args: prompt  [default_name]  [allow_create=true]
# Pass allow_create=false for destructive contexts (delete, export, import) to hide "new".
select_d1_database() {
  local prompt="${1:-Select D1 database}"
  local default_name="${2:-}"
  local allow_create="${3:-true}"
  local resp
  if ! resp=$(cache_get "$ACTIVE_ACCOUNT_NAME" "d1" 2>/dev/null); then
    resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/d1/database?per_page=100")
    if cf_check "$resp"; then
      cache_put "$ACTIVE_ACCOUNT_NAME" "d1" "$resp"
    fi
  fi
  if ! cf_check "$resp"; then
    error "$(cf_errors "$resp")" >&2
    return 1
  fi
  local count
  count=$(echo "$resp" | jq '.result | length')
  local -a uuids names
  mapfile -t uuids < <(echo "$resp" | jq -r '.result[].uuid')
  mapfile -t names < <(echo "$resp" | jq -r '.result[].name')
  echo -e "${W}${prompt}:${NC}\n" >&2
  if [[ "$allow_create" == "true" ]]; then
    if [[ -n "$default_name" ]]; then
      echo -e "  ${G}n${NC}. ${BLD}+ Create new D1 database${NC} ${DM}(suggested: ${default_name})${NC}" >&2
    else
      echo -e "  ${G}n${NC}. ${BLD}+ Create new D1 database${NC}" >&2
    fi
  fi
  if [[ "$count" -eq 0 ]]; then
    echo -e "  ${DM}(no existing databases)${NC}" >&2
  fi
  for i in "${!uuids[@]}"; do
    local size
    size=$(echo "$resp" | jq -r ".result[$i].file_size // 0")
    size=$(( size / 1024 ))
    printf "  ${C}%d${NC}. %-35s ${DM}%s  %s KB${NC}\n" \
      "$((i+1))" "${names[$i]}" "${uuids[$i]}" "$size" >&2
  done
  local cancel_hint="0=cancel"
  [[ "$allow_create" == "true" ]] && cancel_hint="0=cancel, n=new"
  echo -ne "\n${W}Choice (${cancel_hint}):${NC} " >&2
  local sel
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return 1
  if [[ "$allow_create" == "true" && ( "$sel" == "n" || "$sel" == "N" ) ]]; then
    _create_d1_database_inline "$default_name"
    return $?
  fi
  local idx=$((sel-1))
  if [[ $idx -lt 0 || $idx -ge ${#uuids[@]} ]]; then
    error "Invalid selection." >&2
    return 1
  fi
  printf '%s|%s' "${uuids[$idx]}" "${names[$idx]}"
}

# Create a new R2 bucket inline (used by select_r2_bucket's "new" option).
# Prints the new bucket name to stdout on success, returns 1 on cancel/failure.
_create_r2_bucket_inline() {
  local default_name="${1:-}"
  local name location
  if [[ -n "$default_name" ]]; then
    read -rp "$(echo -e "${W}New R2 bucket name${NC} ${DM}[${default_name}]:${NC} ")" name >&2
    [[ -z "$name" ]] && name="$default_name"
  else
    read -rp "$(echo -e "${W}New R2 bucket name:${NC} ")" name >&2
    [[ -z "$name" ]] && { info "Cancelled." >&2; return 1; }
  fi
  echo -e "${W}Location hint (optional):${NC} WNAM ENAM WEUR EEUR APAC" >&2
  read -rp "$(echo -e "${W}Location (blank=auto):${NC} ")" location >&2
  local payload="{\"name\":\"$name\"}"
  [[ -n "$location" ]] && payload="{\"name\":\"$name\",\"locationHint\":\"$location\"}"
  echo -ne "${C}Creating R2 bucket '${name}'...${NC}" >&2
  local resp
  resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/r2/buckets" "$payload")
  if ! cf_check "$resp"; then
    echo -e " ${SYM_ERR}" >&2
    error "$(cf_errors "$resp")" >&2
    return 1
  fi
  echo -e " ${SYM_OK}" >&2
  log "R2 bucket created (inline): $name"
  cache_invalidate "$ACTIVE_ACCOUNT_NAME" "r2"
  printf '%s' "$name"
}

# Interactive R2 bucket picker — prints bucket name to stdout, returns 1 on cancel.
# Args: prompt  [default_name]  [allow_create=true]
# Pass allow_create=false for destructive contexts (delete object/bucket) to hide "new".
select_r2_bucket() {
  local prompt="${1:-Select R2 bucket}"
  local default_name="${2:-}"
  local allow_create="${3:-true}"
  local resp
  if ! resp=$(cache_get "$ACTIVE_ACCOUNT_NAME" "r2" 2>/dev/null); then
    resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/r2/buckets")
    if cf_check "$resp"; then
      cache_put "$ACTIVE_ACCOUNT_NAME" "r2" "$resp"
    fi
  fi
  if ! cf_check "$resp"; then
    error "$(cf_errors "$resp")" >&2
    return 1
  fi
  local count
  count=$(echo "$resp" | jq '.result.buckets | length')
  local -a buckets locations
  mapfile -t buckets   < <(echo "$resp" | jq -r '.result.buckets[].name')
  mapfile -t locations < <(echo "$resp" | jq -r '.result.buckets[].location // "auto"')
  echo -e "${W}${prompt}:${NC}\n" >&2
  if [[ "$allow_create" == "true" ]]; then
    if [[ -n "$default_name" ]]; then
      echo -e "  ${G}n${NC}. ${BLD}+ Create new R2 bucket${NC} ${DM}(suggested: ${default_name})${NC}" >&2
    else
      echo -e "  ${G}n${NC}. ${BLD}+ Create new R2 bucket${NC}" >&2
    fi
  fi
  if [[ "$count" -eq 0 ]]; then
    echo -e "  ${DM}(no existing buckets)${NC}" >&2
  fi
  for i in "${!buckets[@]}"; do
    printf "  ${C}%d${NC}. %-35s ${DM}%s${NC}\n" \
      "$((i+1))" "${buckets[$i]}" "${locations[$i]}" >&2
  done
  local cancel_hint="0=cancel"
  [[ "$allow_create" == "true" ]] && cancel_hint="0=cancel, n=new"
  echo -ne "\n${W}Choice (${cancel_hint}):${NC} " >&2
  local sel
  read -r sel
  [[ "$sel" == "0" || -z "$sel" ]] && return 1
  if [[ "$allow_create" == "true" && ( "$sel" == "n" || "$sel" == "N" ) ]]; then
    _create_r2_bucket_inline "$default_name"
    return $?
  fi
  local idx=$((sel-1))
  if [[ $idx -lt 0 || $idx -ge ${#buckets[@]} ]]; then
    error "Invalid selection." >&2
    return 1
  fi
  printf '%s' "${buckets[$idx]}"
}

d1_list() {
  header "D1 Databases"
  require_account || return
  local resp
  resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/d1/database")
  if cf_check "$resp"; then
    echo -e "${W}Databases:${NC}\n"
    echo "$resp" | jq -r '.result[]? | "  \(.name)\n    ID:      \(.uuid)\n    Created: \(.created_at[:10])\n    Size:    \(if .file_size then (.file_size/1024|tostring)+" KB" else "?" end)\n"' 2>/dev/null
  else
    error "$(cf_errors "$resp")"
  fi
  press_enter
}

d1_create() {
  header "Create D1 Database"
  require_account || return
  local name
  read -rp "$(echo -e "${W}Database name:${NC} ")" name
  [[ -z "$name" ]] && return
  local resp
  resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database" "{\"name\":\"$name\"}")
  if cf_check "$resp"; then
    local db_id
    db_id=$(echo "$resp" | jq -r '.result.uuid')
    success "Created D1 database '${name}'"
    echo -e "  ${DM}UUID: ${db_id}${NC}"
    log "D1 database created: $name ($db_id)"
  else
    error "$(cf_errors "$resp")"
  fi
  press_enter
}

d1_query() {
  header "D1 — Execute SQL"
  require_account || return
  local picked
  picked=$(select_d1_database "Select database" "" false) || { press_enter; return; }
  local db_id db_label
  split_pipe db_id db_label "$picked"
  echo -e "\n${SYM_INFO} Database: ${C}${db_label}${NC}  ${DM}${db_id}${NC}\n"
  echo -e "${DM}Enter SQL (single statement). Type 'MULTILINE' for multi-line input:${NC}"
  read -rp "$(echo -e "${W}SQL:${NC} ")" sql
  if [[ "$sql" == "MULTILINE" ]]; then
    echo -e "${DM}Enter SQL, end with a line containing only ';${NC}"
    sql=""
    while IFS= read -r line; do
      [[ "$line" == ";" ]] && break
      sql+="$line "$'\n'
    done
  fi
  [[ -z "$sql" ]] && return
  local payload
  payload=$(jq -n --arg s "$sql" '{"sql":$s}')
  local resp
  resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database/${db_id}/query" "$payload")
  if cf_check "$resp"; then
    echo -e "\n${W}Results:${NC}"
    echo "$resp" | jq '.result[]?.results // []' 2>/dev/null
    local rows
    rows=$(echo "$resp" | jq '[.result[]?.meta?.rows_read // 0] | add' 2>/dev/null || echo "?")
    echo -e "\n${DM}Rows read: ${rows}${NC}"
  else
    error "$(cf_errors "$resp")"
  fi
  press_enter
}

d1_tables() {
  header "D1 — List Tables"
  require_account || return
  local picked
  picked=$(select_d1_database "Select database" "" false) || { press_enter; return; }
  local db_id db_label
  split_pipe db_id db_label "$picked"
  echo -e "\n${SYM_INFO} Database: ${C}${db_label}${NC}\n"
  local resp
  resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database/${db_id}/query" \
    '{"sql":"SELECT name, sql FROM sqlite_master WHERE type='"'"'table'"'"' ORDER BY name"}')
  if cf_check "$resp"; then
    echo -e "\n${W}Tables:${NC}"
    echo "$resp" | jq -r '.result[]?.results[]? | "  \(.name)"' 2>/dev/null
  else
    error "$(cf_errors "$resp")"
  fi
  press_enter
}

d1_delete() {
  header "Delete D1 Database"
  require_account || return
  local picked
  picked=$(select_d1_database "Select database to delete" "" false) || { press_enter; return; }
  local db_id db_label
  split_pipe db_id db_label "$picked"
  echo ""
  warn "This will permanently delete database '${BLD}${db_label}${NC}' and all its data."
  echo -e "  ${DM}UUID: ${db_id}${NC}\n"
  confirm "Are you sure?" || return
  local resp
  resp=$(cf_delete "/accounts/${CF_ACCOUNT_ID}/d1/database/${db_id}")
  cf_check "$resp" && success "Database deleted." || error "$(cf_errors "$resp")"
  press_enter
}



# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# RESOURCE RENAMING  (KV · D1 · R2)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# Cloudflare does not provide a single "rename" API for these resources.
# The approach for each:
#   KV  — create new namespace with new title; bulk-copy keys; update all
#          worker bindings that referenced the old namespace_id; delete old.
#   D1  — CF does not expose a rename endpoint; we create a new DB, replay
#          the full SQL dump (schema + data) into it, update all worker
#          bindings, then delete the old DB.
#   R2  — create new bucket; copy objects one by one (download+upload via
#          Cloudflare API); update all worker bindings; delete old bucket.
#
# All three update every worker's bindings if the old resource is found.

# ── Shared binding-update helper ─────────────────────────────────────
#
# rebind_workers_for_resource MATCH_JQ UPDATE_JQ
#
# Iterates every worker in the active account.  For each worker whose
# bindings satisfy MATCH_JQ (a jq boolean expression that receives the
# bindings array), applies UPDATE_JQ (a jq `map(...)` expression) and
# PUTs the result back via _env_put_bindings.
#
# Both jq expressions are evaluated with the current bindings array as
# input.  Callers pass --arg / --argjson values through the environment
# using the JQ_ARGS array:
#
#   JQ_ARGS=(--arg old "$old_id" --arg new "$new_id")
#   rebind_workers_for_resource \
#     '.[] | select(.type=="kv_namespace" and .namespace_id==$old)' \
#     'map(if .type=="kv_namespace" and .namespace_id==$old then .namespace_id=$new else . end)'
#
# Prints a summary line and returns 0 always (individual failures are
# already logged by _env_put_bindings).
rebind_workers_for_resource() {
  local match_jq="$1"
  local update_jq="$2"
  # JQ_ARGS must be set by the caller as an array, e.g.:
  #   local -a JQ_ARGS=(--arg old "$old_id" --arg new "$new_id")

  echo -e "${C}Updating worker bindings...${NC}"
  local workers_resp
  workers_resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/workers/scripts")
  local -a worker_ids
  mapfile -t worker_ids < <(echo "$workers_resp" | jq -r '.result[].id' 2>/dev/null)
  local bound_count=0
  for wid in "${worker_ids[@]}"; do
    local wbindings
    wbindings=$(_env_get_bindings "$wid" 2>/dev/null) || continue
    if echo "$wbindings" | jq -e "${JQ_ARGS[@]}" "$match_jq" &>/dev/null; then
      local wb_updated
      wb_updated=$(echo "$wbindings" | jq "${JQ_ARGS[@]}" "$update_jq")
      _env_put_bindings "$wid" "$wb_updated" && inc bound_count
    fi
  done
  [[ $bound_count -gt 0 ]] && echo -e "  ${SYM_OK} ${bound_count} worker binding(s) updated."
  return 0
}

# ── KV rename ────────────────────────────────────────────────────────

kv_rename_namespace() {
  header "Rename KV Namespace"
  require_account || return

  local picked
  picked=$(select_kv_namespace "Select KV namespace to rename") || { press_enter; return; }
  local old_id old_title
  split_pipe old_id old_title "$picked"

  echo ""
  echo -e "${SYM_INFO} Current title: ${C}${old_title}${NC}  ${DM}(${old_id})${NC}\n"
  read -rp "$(echo -e "${W}New title:${NC} ")" new_title
  [[ -z "$new_title" ]] && info "Cancelled." && press_enter && return

  # 1. Create new namespace with the new title
  echo -ne "${C}Creating new KV namespace '${new_title}'...${NC}"
  local create_resp
  create_resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces" \
    "$(jq -n --arg t "$new_title" '{title:$t}')")
  if ! cf_check "$create_resp"; then
    echo -e " ${SYM_ERR}"
    error "$(cf_errors "$create_resp")"
    press_enter; return
  fi
  echo -e " ${SYM_OK}"
  local new_id
  new_id=$(echo "$create_resp" | jq -r '.result.id')

  # 2. Copy all keys from old → new (list + get + put)
  echo -e "${C}Copying keys...${NC}"
  local keys_resp
  keys_resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${old_id}/keys?limit=1000")
  local key_count=0
  if cf_check "$keys_resp"; then
    local -a key_names
    mapfile -t key_names < <(echo "$keys_resp" | jq -r '.result[]?.name // empty')
    key_count=${#key_names[@]}
    for key in "${key_names[@]}"; do
      local val_resp
      val_resp=$(curl -s \
        "${CF_API}/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${old_id}/values/$(python3 -c "import urllib.parse; print(urllib.parse.quote('$key'))" 2>/dev/null || echo "$key")" \
        -H "Authorization: Bearer ${CF_TOKEN}" 2>/dev/null)
      curl -s -X PUT \
        "${CF_API}/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces/${new_id}/values/$(python3 -c "import urllib.parse; print(urllib.parse.quote('$key'))" 2>/dev/null || echo "$key")" \
        -H "Authorization: Bearer ${CF_TOKEN}" \
        --data-raw "$val_resp" &>/dev/null || true
    done
  fi
  echo -e "  ${SYM_OK} ${key_count} key(s) copied."

  # 3. Update all worker bindings that reference old_id
  local -a JQ_ARGS=(--arg old "$old_id" --arg new "$new_id")
  rebind_workers_for_resource \
    '.[] | select(.type=="kv_namespace" and .namespace_id==$old)' \
    'map(if .type=="kv_namespace" and .namespace_id==$old then .namespace_id=$new else . end)'

  # 4. Delete old namespace
  echo -ne "${C}Deleting old namespace '${old_title}'...${NC}"
  local del_resp
  del_resp=$(cf_curl_delete "/accounts/${CF_ACCOUNT_ID//[[:space:]]/}/storage/kv/namespaces/${old_id}")
  if cf_check "$del_resp"; then
    echo -e " ${SYM_OK}"
    success "KV namespace renamed: '${BLD}${old_title}${NC}' → '${BLD}${new_title}${NC}'"
    log "KV namespace renamed: $old_title ($old_id) -> $new_title ($new_id)"
  else
    echo -e " ${SYM_WARN}"
    warn "New namespace '${new_title}' created and keys copied, but old namespace delete failed: $(cf_errors "$del_resp")"
  fi
  press_enter
}

# ── D1 rename ────────────────────────────────────────────────────────

d1_rename() {
  header "Rename D1 Database"
  require_account || return

  local picked
  picked=$(select_d1_database "Select D1 database to rename" "" false) || { press_enter; return; }
  local old_uuid old_name
  split_pipe old_uuid old_name "$picked"

  echo ""
  echo -e "${SYM_INFO} Current name: ${C}${old_name}${NC}  ${DM}(${old_uuid})${NC}\n"
  read -rp "$(echo -e "${W}New name:${NC} ")" new_name
  [[ -z "$new_name" ]] && info "Cancelled." && press_enter && return

  warn "D1 rename: a new database will be created and all data copied over."
  warn "The old database will be deleted after a successful copy."
  confirm "Continue?" || { press_enter; return; }

  # 1. Create new DB
  echo -ne "${C}Creating new D1 database '${new_name}'...${NC}"
  local create_resp
  create_resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database" \
    "$(jq -n --arg n "$new_name" '{name:$n}')")
  if ! cf_check "$create_resp"; then
    echo -e " ${SYM_ERR}"
    error "$(cf_errors "$create_resp")"
    press_enter; return
  fi
  echo -e " ${SYM_OK}"
  local new_uuid
  new_uuid=$(echo "$create_resp" | jq -r '.result.uuid')

  # 2. Copy schema + data using the shared _api_d1_copy helper (already handles
  #    _cf_* table exclusion, parameterised INSERTs, and per-row /query calls).
  echo -e "${C}Copying data...${NC}"
  _d1_snapshot "BEFORE (src: ${old_name})" "$old_uuid"
  local total_rows
  total_rows=$(_api_d1_copy "$old_uuid" "$new_uuid")
  echo -e "  ${SYM_OK} ~${total_rows} row(s) copied."
  _d1_snapshot "AFTER  (dst: ${new_name})" "$new_uuid"

  # 3. Update all worker bindings referencing old_uuid
  # Match on either .id or .database_id — the GET response field name varies
  local -a JQ_ARGS=(--arg old_id "$old_uuid" --arg new_id "$new_uuid" --arg new_n "$new_name")
  rebind_workers_for_resource \
    '.[] | select(.type=="d1" and ((.id // .database_id) == $old_id))' \
    'map(if .type=="d1" and ((.id // .database_id) == $old_id)
         then .id=$new_id | .database_name=$new_n
         else . end)'

  # 4. Delete old DB
  echo -ne "${C}Deleting old database '${old_name}'...${NC}"
  local del_resp
  del_resp=$(cf_delete "/accounts/${CF_ACCOUNT_ID}/d1/database/${old_uuid}")
  if cf_check "$del_resp"; then
    echo -e " ${SYM_OK}"
    success "D1 database renamed: '${BLD}${old_name}${NC}' → '${BLD}${new_name}${NC}'"
    log "D1 database renamed: $old_name ($old_uuid) -> $new_name ($new_uuid)"
  else
    echo -e " ${SYM_WARN}"
    warn "New DB '${new_name}' created and data copied, but delete of old DB failed: $(cf_errors "$del_resp")"
  fi
  press_enter
}

# ── R2 rename ────────────────────────────────────────────────────────

r2_rename_bucket() {
  header "Rename R2 Bucket"
  require_account || return

  local old_bucket
  old_bucket=$(select_r2_bucket "Select R2 bucket to rename" "" false) || { press_enter; return; }

  echo ""
  echo -e "${SYM_INFO} Current name: ${C}${old_bucket}${NC}\n"
  read -rp "$(echo -e "${W}New name:${NC} ")" new_bucket
  [[ -z "$new_bucket" ]] && info "Cancelled." && press_enter && return

  warn "R2 rename: a new bucket will be created and all objects copied."
  warn "The old bucket will be deleted after a successful copy."
  confirm "Continue?" || { press_enter; return; }

  # 1. Create new bucket
  echo -ne "${C}Creating new R2 bucket '${new_bucket}'...${NC}"
  local create_resp
  create_resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/r2/buckets" \
    "$(jq -n --arg n "$new_bucket" '{name:$n}')")
  if ! cf_check "$create_resp"; then
    echo -e " ${SYM_ERR}"
    error "$(cf_errors "$create_resp")"
    press_enter; return
  fi
  echo -e " ${SYM_OK}"

  # 2. List and copy objects
  echo -e "${C}Listing objects in '${old_bucket}'...${NC}"
  local list_resp
  list_resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/r2/buckets/${old_bucket}/objects?limit=1000")
  local -a obj_keys
  mapfile -t obj_keys < <(echo "$list_resp" | jq -r '.result.objects[]?.key // empty' 2>/dev/null)
  local copied=0 failed=0
  for key in "${obj_keys[@]}"; do
    local enc_key
    enc_key=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$key'))" 2>/dev/null || echo "$key")
    # Download from old bucket
    local tmpobj
    tmpobj=$(mktemp)
    curl -s -o "$tmpobj" \
      "${CF_API}/accounts/${CF_ACCOUNT_ID}/r2/buckets/${old_bucket}/objects/${enc_key}" \
      -H "Authorization: Bearer ${CF_TOKEN}" 2>/dev/null
    # Upload to new bucket
    local up_resp
    up_resp=$(curl -s -X PUT \
      "${CF_API}/accounts/${CF_ACCOUNT_ID}/r2/buckets/${new_bucket}/objects/${enc_key}" \
      -H "Authorization: Bearer ${CF_TOKEN}" \
      --data-binary "@$tmpobj" 2>/dev/null)
    rm -f "$tmpobj"
    if echo "$up_resp" | jq -e '.success // false' &>/dev/null || [[ -z "$up_resp" ]]; then
      inc copied
    else
      inc failed
      warn "  Failed to copy object: ${key}"
    fi
  done
  echo -e "  ${SYM_OK} ${copied} object(s) copied${failed:+, ${R}${failed} failed${NC}}."

  # 3. Update all worker bindings referencing old_bucket
  local -a JQ_ARGS=(--arg old "$old_bucket" --arg new "$new_bucket")
  rebind_workers_for_resource \
    '.[] | select(.type=="r2_bucket" and .bucket_name==$old)' \
    'map(if .type=="r2_bucket" and .bucket_name==$old then .bucket_name=$new else . end)'

  # 4. Delete old bucket
  if [[ $failed -gt 0 ]]; then
    warn "Skipping deletion of old bucket due to copy failures. Delete manually: ${old_bucket}"
    press_enter; return
  fi
  echo -ne "${C}Deleting old bucket '${old_bucket}'...${NC}"
  local del_resp
  del_resp=$(cf_delete "/accounts/${CF_ACCOUNT_ID}/r2/buckets/${old_bucket}")
  if cf_check "$del_resp"; then
    echo -e " ${SYM_OK}"
    success "R2 bucket renamed: '${BLD}${old_bucket}${NC}' → '${BLD}${new_bucket}${NC}'"
    log "R2 bucket renamed: $old_bucket -> $new_bucket"
  else
    echo -e " ${SYM_WARN}"
    warn "New bucket '${new_bucket}' created and objects copied, but old bucket delete failed: $(cf_errors "$del_resp")"
  fi
  press_enter
}

d1_export() {
  header "D1 — Export Database (SQL dump)"
  require_account || return
  local picked
  picked=$(select_d1_database "Select database to export" "" false) || { press_enter; return; }
  local db_id db_name
  split_pipe db_id db_name "$picked"
  echo -e "\n${SYM_INFO} Exporting: ${C}${db_name}${NC}  ${DM}${db_id}${NC}\n"
  local label
  echo -ne "${W}Label for export filename${NC} ${DM}[${db_name}]:${NC} "
  read -r label
  [[ -n "$label" ]] && db_name="$label"

  echo -e "${C}Fetching table list...${NC}"
  local tables_resp
  tables_resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database/${db_id}/query"     "{"sql":"SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"}")
  if ! cf_check "$tables_resp"; then
    error "$(cf_errors "$tables_resp")"
    press_enter; return
  fi

  local tables=()
  mapfile -t tables < <(echo "$tables_resp" | jq -r '.result[]?.results[]?.name // empty' 2>/dev/null)
  if [[ ${#tables[@]} -eq 0 ]]; then
    warn "No tables found in this database."
    press_enter; return
  fi

  local out_file="$CONFIG_DIR/${db_name}_$(date +%Y%m%d_%H%M%S).sql"
  {
    echo "-- CF-Manager D1 export"
    echo "-- Database: $db_name ($db_id)"
    echo "-- Exported: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
    echo "PRAGMA foreign_keys=OFF;"
    echo "BEGIN TRANSACTION;"
    echo ""
  } > "$out_file"

  local total_rows=0
  for table in "${tables[@]}"; do
    echo -e "  ${C}Exporting table:${NC} ${table}"

    # Get CREATE TABLE statement
    local schema_resp
    schema_resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database/${db_id}/query"       "{"sql":"SELECT sql FROM sqlite_master WHERE type='table' AND name='${table}'"}")
    local create_sql
    create_sql=$(echo "$schema_resp" | jq -r '.result[]?.results[]?.sql // empty' 2>/dev/null)
    [[ -n "$create_sql" ]] && echo "${create_sql};" >> "$out_file"
    echo "" >> "$out_file"

    # Get all rows as INSERT statements (page 500 at a time)
    local offset=0
    local page_size=500
    while true; do
      local rows_resp
      rows_resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database/${db_id}/query"         "{"sql":"SELECT * FROM \"${table}\" LIMIT ${page_size} OFFSET ${offset}"}")
      local rows
      rows=$(echo "$rows_resp" | jq '.result[]?.results // []' 2>/dev/null)
      local row_count
      row_count=$(echo "$rows" | jq 'length')
      [[ "$row_count" -eq 0 ]] && break

      # Build INSERT statements from the JSON rows
      echo "$rows" | jq -r --arg t "$table" '
        if length == 0 then empty
        else
          . as $rows |
          ($rows[0] | keys_unsorted) as $cols |
          $rows[] |
          . as $row |
          "INSERT INTO "" + $t + "" (" +
          ($cols | map(""" + . + """) | join(", ")) +
          ") VALUES (" +
          ($cols | map($row[.] | if . == null then "NULL" elif type == "number" then tostring else "'"'"'" + (tostring | gsub("'"'"'";"'"'"''"'"'")) + "'"'"'" end) | join(", ")) +
          ");"
        end
      ' 2>/dev/null >> "$out_file"

      total_rows=$((total_rows + row_count))
      [[ "$row_count" -lt "$page_size" ]] && break
      offset=$((offset + page_size))
    done
    echo "" >> "$out_file"
  done

  echo "COMMIT;" >> "$out_file"
  echo "PRAGMA foreign_keys=ON;" >> "$out_file"

  success "Exported ${#tables[@]} table(s), ~${total_rows} row(s) to:"
  echo -e "  ${DM}${out_file}${NC}"
  log "D1 export: $db_name ($db_id) -> $out_file"
  press_enter
}

d1_import() {
  header "D1 — Import SQL Dump"
  require_account || return
  local picked
  picked=$(select_d1_database "Select target database" "" false) || { press_enter; return; }
  local db_id db_label
  split_pipe db_id db_label "$picked"
  echo -e "\n${SYM_INFO} Target: ${C}${db_label}${NC}  ${DM}${db_id}${NC}\n"
  local sql_file
  read -rp "$(echo -e "${W}Path to .sql file:${NC} ")" sql_file
  [[ ! -f "$sql_file" ]] && error "File not found: $sql_file" && press_enter && return

  local line_count
  line_count=$(wc -l < "$sql_file")
  warn "About to execute ${line_count}-line SQL file against database ${db_id}."
  warn "This is destructive if the file contains DROP or DELETE statements."
  confirm "Proceed?" || return

  # Send the whole file as one query (D1 supports multi-statement SQL)
  local sql_content
  sql_content=$(cat "$sql_file")
  local payload
  payload=$(jq -n --arg s "$sql_content" '{"sql":$s}')

  echo -e "${C}Executing SQL...${NC}"
  local resp
  resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/d1/database/${db_id}/query" "$payload")
  if cf_check "$resp"; then
    local rows_written
    rows_written=$(echo "$resp" | jq '[.result[]?.meta?.rows_written // 0] | add' 2>/dev/null || echo "?")
    success "Import complete. Rows written: ${rows_written}"
    log "D1 import: $db_id from $sql_file (rows_written=$rows_written)"
  else
    error "Import failed: $(cf_errors "$resp")"
  fi
  press_enter
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# R2 BUCKETS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

r2_list_buckets() {
  header "R2 Buckets"
  require_account || return
  local resp
  resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/r2/buckets")
  if cf_check "$resp"; then
    echo -e "${W}Buckets:${NC}\n"
    echo "$resp" | jq -r '.result.buckets[]? | "  \(.name)\n    Created: \(.creation_date[:10])\n    Location: \(.location // "default")\n"' 2>/dev/null
    local count
    count=$(echo "$resp" | jq '.result.buckets | length')
    echo -e "${DM}Total: ${count} bucket(s)${NC}"
  else
    error "$(cf_errors "$resp")"
  fi
  press_enter
}

r2_create_bucket() {
  header "Create R2 Bucket"
  require_account || return
  local name location
  read -rp "$(echo -e "${W}Bucket name:${NC} ")" name
  [[ -z "$name" ]] && return
  echo -e "${W}Location hint (optional):${NC} WNAM ENAM WEUR EEUR APAC"
  read -rp "$(echo -e "${W}Location (blank=auto):${NC} ")" location
  local payload="{\"name\":\"$name\"}"
  [[ -n "$location" ]] && payload="{\"name\":\"$name\",\"locationHint\":\"$location\"}"
  local resp
  resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/r2/buckets" "$payload")
  cf_check "$resp" && success "Bucket '${name}' created." || error "$(cf_errors "$resp")"
  log "R2 bucket created: $name"
  press_enter
}

r2_list_objects() {
  header "R2 — List Objects"
  require_account || return
  local bucket
  bucket=$(select_r2_bucket "Select bucket" "" false) || { press_enter; return; }
  local prefix
  read -rp "$(echo -e "${W}Prefix filter (optional):${NC} ")" prefix
  local endpoint="/accounts/${CF_ACCOUNT_ID}/r2/buckets/${bucket}/objects?limit=100"
  [[ -n "$prefix" ]] && endpoint+="&prefix=${prefix}"
  local resp
  resp=$(cf_get "$endpoint")
  if cf_check "$resp"; then
    echo -e "\n${W}Objects:${NC}\n"
    echo "$resp" | jq -r '.result.objects[]? | "  \(.key)  \(if .size then (.size/1024|round|tostring)+" KB" else "" end)  \(.uploaded[:10] // "")"' 2>/dev/null
    local truncated
    truncated=$(echo "$resp" | jq -r '.result.truncated // false')
    [[ "$truncated" == "true" ]] && echo -e "${Y}  (results truncated — more objects exist)${NC}"
  else
    error "$(cf_errors "$resp")"
  fi
  press_enter
}

r2_upload_object() {
  header "R2 — Upload Object"
  require_account || return
  local bucket key file
  bucket=$(select_r2_bucket "Select target bucket") || { press_enter; return; }
  read -rp "$(echo -e "${W}Object key (path in bucket):${NC} ")" key
  read -rp "$(echo -e "${W}Local file path:${NC} ")" file
  [[ ! -f "$file" ]] && error "File not found: $file" && press_enter && return
  echo -e "${C}Uploading...${NC}"
  local resp
  resp=$(curl -sf -X PUT "${CF_API}/accounts/${CF_ACCOUNT_ID}/r2/buckets/${bucket}/objects/${key}" \
    -H "Authorization: Bearer ${CF_TOKEN}" \
    --data-binary "@${file}" 2>/dev/null || echo '{"success":false}')
  cf_check "$resp" && success "Uploaded '$key' to bucket '$bucket'." || error "$(cf_errors "$resp")"
  press_enter
}


r2_download_object() {
  header "R2 — Download Object"
  require_account || return
  local bucket key out_path
  bucket=$(select_r2_bucket "Select bucket" "" false) || { press_enter; return; }
  read -rp "$(echo -e "${W}Object key:${NC} ")" key
  [[ -z "$key" ]] && return

  # Default save path: ~/Downloads/<key basename> or CONFIG_DIR
  local default_out
  default_out="${HOME}/$(basename "$key")"
  echo -ne "${W}Save to${NC} ${DM}[${default_out}]${NC}: "
  read -r out_path
  [[ -z "$out_path" ]] && out_path="$default_out"

  local token="${CF_TOKEN//[[:space:]]/}"
  local account_id="${CF_ACCOUNT_ID//[[:space:]]/}"
  echo -e "${C}Downloading...${NC}"
  local tmpfile="${TMPDIR:-$CONFIG_DIR}/r2_dl_resp"
  local http_code
  http_code=$(curl -s -w "%{http_code}" -o "$out_path"     -X GET "${CF_API}/accounts/${account_id}/r2/buckets/${bucket}/objects/${key}"     -H "Authorization: Bearer ${token}" 2>/dev/null)
  if [[ "$http_code" == "200" ]]; then
    local size
    size=$(wc -c < "$out_path" 2>/dev/null || echo "?")
    success "Downloaded '${key}' (${size} bytes) to:"
    echo -e "  ${DM}${out_path}${NC}"
    log "R2 download: $bucket/$key -> $out_path"
  else
    rm -f "$out_path" 2>/dev/null
    error "Download failed (HTTP ${http_code})."
    # Try to read the error body
    local err_resp
    err_resp=$(curl -sf -X GET "${CF_API}/accounts/${account_id}/r2/buckets/${bucket}/objects/${key}"       -H "Authorization: Bearer ${token}" 2>/dev/null || echo "")
    [[ -n "$err_resp" ]] && echo "$err_resp" | jq -r '.errors[]?.message' 2>/dev/null
  fi
  press_enter
}

r2_delete_object() {
  header "R2 — Delete Object"
  require_account || return
  local bucket key
  bucket=$(select_r2_bucket "Select bucket" "" false) || { press_enter; return; }
  read -rp "$(echo -e "${W}Object key:${NC} ")" key
  [[ -z "$key" ]] && return
  confirm "${R}Delete '${key}'?${NC}" || return
  local resp
  resp=$(cf_delete "/accounts/${CF_ACCOUNT_ID}/r2/buckets/${bucket}/objects/${key}")
  cf_check "$resp" && success "Deleted." || error "$(cf_errors "$resp")"
  press_enter
}

r2_delete_bucket() {
  header "R2 — Delete Bucket"
  require_account || return
  local bucket
  bucket=$(select_r2_bucket "Select bucket to delete" "" false) || { press_enter; return; }
  echo ""
  warn "This will permanently delete bucket '${BLD}${bucket}${NC}' and ALL its objects."
  confirm "${R}${BLD}Are you absolutely sure?${NC}" || return
  local resp
  resp=$(cf_delete "/accounts/${CF_ACCOUNT_ID}/r2/buckets/${bucket}")
  cf_check "$resp" && success "Bucket deleted." || error "$(cf_errors "$resp")"
  press_enter
}


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# DURABLE OBJECTS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

do_list_namespaces() {
  header "Durable Objects — Namespaces"
  require_account || return
  local resp
  resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/workers/durable_objects/namespaces")
  if cf_check "$resp"; then
    echo -e "${W}Namespaces:${NC}\n"
    echo "$resp" | jq -r '.result[]? | "  \(.name)\n    ID:     \(.id)\n    Script: \(.script // "(none)")\n    Class:  \(.class // "(none)")\n"' 2>/dev/null
  else
    error "$(cf_errors "$resp")"
  fi
  press_enter
}

do_list_objects() {
  header "Durable Objects — Instances"
  require_account || return
  local ns_id
  read -rp "$(echo -e "${W}Namespace ID:${NC} ")" ns_id
  [[ -z "$ns_id" ]] && return
  local resp
  resp=$(cf_get "/accounts/${CF_ACCOUNT_ID}/workers/durable_objects/namespaces/${ns_id}/objects")
  if cf_check "$resp"; then
    echo -e "\n${W}Objects:${NC}\n"
    echo "$resp" | jq -r '.result[]? | "  ID: \(.id)\n  HasStorageData: \(.hasStorageData)\n"' 2>/dev/null
    local count
    count=$(echo "$resp" | jq '.result | length')
    echo -e "${DM}Total: ${count} object(s)${NC}"
  else
    error "$(cf_errors "$resp")"
  fi
  press_enter
}

do_create_namespace() {
  header "Create Durable Object Namespace"
  require_account || return
  local name script class
  read -rp "$(echo -e "${W}Namespace name:${NC} ")" name
  read -rp "$(echo -e "${W}Worker script name:${NC} ")" script
  read -rp "$(echo -e "${W}Class name in script:${NC} ")" class
  [[ -z "$name" || -z "$script" || -z "$class" ]] && error "All fields required." && press_enter && return
  local resp
  resp=$(cf_post "/accounts/${CF_ACCOUNT_ID}/workers/durable_objects/namespaces" \
    "{\"name\":\"$name\",\"script\":\"$script\",\"class\":\"$class\"}")
  if cf_check "$resp"; then
    local ns_id
    ns_id=$(echo "$resp" | jq -r '.result.id')
    success "Namespace created. ID: ${ns_id}"
    log "Durable Object namespace created: $name"
  else
    error "$(cf_errors "$resp")"
  fi
  press_enter
}


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# GITHUB INTEGRATION
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

gh_clone_repo() {
  header "Clone GitHub Repo"
  local repo url dest
  read -rp "$(echo -e "${W}GitHub repo (user/repo or full URL):${NC} ")" repo
  [[ -z "$repo" ]] && return
  [[ "$repo" != http* ]] && url="https://github.com/${repo}.git" || url="$repo"
  local repo_name
  repo_name=$(basename "$url" .git)
  dest="$REPOS_DIR/${repo_name}"
  mkdir -p "$REPOS_DIR"
  if [[ -d "$dest" ]]; then
    warn "Repo already cloned at $dest"
    confirm "Pull latest changes?" && git -C "$dest" pull && success "Updated."
    press_enter; return
  fi
  echo -e "${C}Cloning ${url}...${NC}"
  git clone "$url" "$dest" && success "Cloned to $dest" || error "Clone failed."
  press_enter
}

gh_link_worker() {
  header "Link Repo to Worker"
  require_account || return
  echo -e "${W}Available local repos:${NC}"
  ls "$REPOS_DIR" 2>/dev/null | nl -v1 -w2
  local repo_name worker_name entry_file
  read -rp "$(echo -e "${W}Repo name:${NC} ")" repo_name
  read -rp "$(echo -e "${W}Worker name to deploy to:${NC} ")" worker_name
  read -rp "$(echo -e "${W}Entry JS file in repo (e.g. src/worker.js):${NC} ")" entry_file
  [[ -z "$repo_name" || -z "$worker_name" || -z "$entry_file" ]] && error "All fields required." && press_enter && return
  local link_file="$DEPLOY_HOOKS/${repo_name}.json"
  mkdir -p "$DEPLOY_HOOKS"
  echo "{\"repo\":\"$repo_name\",\"worker\":\"$worker_name\",\"entry\":\"$entry_file\",\"account\":\"$ACTIVE_ACCOUNT_NAME\"}" > "$link_file"
  local hook_script="$REPOS_DIR/${repo_name}/.git/hooks/post-merge"
  cat > "$hook_script" <<HOOKSCRIPT
#!/bin/bash
# CF-Manager auto-deploy hook
exec bash "$( cd "\$( dirname "\${BASH_SOURCE[0]}" )" && pwd )/../../../../$(basename "$0")" --auto-deploy "$repo_name"
HOOKSCRIPT
  # Simpler hook: just call cf-manager with auto-deploy
  cat > "$hook_script" <<HOOKSCRIPT
#!/bin/bash
echo "[CF-Manager] Auto-deploying worker '${worker_name}' from repo '${repo_name}'..."
SCRIPT_DIR="${CONFIG_DIR}"
CF_TOKEN_VAL=\$(cat "${ACCOUNTS_ENC}" 2>/dev/null)
# Trigger deploy via cf-manager
bash "${0}" --auto-deploy "${repo_name}" 2>&1 | tee -a "${LOG_FILE}"
HOOKSCRIPT
  chmod +x "$hook_script"
  success "Linked repo '${repo_name}' → worker '${worker_name}'"
  info "Auto-deploy will trigger on: git pull / git merge"
  log "Linked: $repo_name -> $worker_name ($entry_file)"
  press_enter
}

gh_sync_deploy() {
  local repo_name="$1"
  local link_file="$DEPLOY_HOOKS/${repo_name}.json"
  [[ ! -f "$link_file" ]] && error "No link found for repo '$repo_name'." && return 1
  local worker_name entry_file account_name
  worker_name=$(jq -r '.worker' "$link_file")
  entry_file=$(jq -r '.entry' "$link_file")
  account_name=$(jq -r '.account' "$link_file")
  local full_path="$REPOS_DIR/${repo_name}/${entry_file}"
  [[ ! -f "$full_path" ]] && error "Entry file not found: $full_path" && return 1
  echo -e "${C}Auto-deploying '${worker_name}' from '${repo_name}/${entry_file}'...${NC}"
  deploy_worker_file "$worker_name" "$full_path"
}

gh_pull_and_deploy() {
  header "Pull & Deploy from Repo"
  require_account || return
  echo -e "${W}Linked repos:${NC}"
  ls "$DEPLOY_HOOKS" 2>/dev/null | sed 's/\.json$//' | nl -v1 -w2
  local repo_name
  read -rp "$(echo -e "${W}Repo name (blank=all):${NC} ")" repo_name
  if [[ -z "$repo_name" ]]; then
    for f in "$DEPLOY_HOOKS"/*.json; do
      [[ -f "$f" ]] || continue
      local rn
      rn=$(basename "$f" .json)
      echo -e "\n${C}── Syncing $rn ──${NC}"
      git -C "$REPOS_DIR/$rn" pull 2>&1 | tail -3
      gh_sync_deploy "$rn"
    done
  else
    git -C "$REPOS_DIR/$repo_name" pull 2>&1 | tail -3
    gh_sync_deploy "$repo_name"
  fi
  press_enter
}

gh_list_linked() {
  header "GitHub — Linked Repos"
  [[ ! -d "$DEPLOY_HOOKS" ]] && warn "No repos linked." && press_enter && return
  echo -e "${W}Linked repos:${NC}\n"
  for f in "$DEPLOY_HOOKS"/*.json; do
    [[ -f "$f" ]] || { warn "No links found."; break; }
    local rn worker entry
    rn=$(jq -r '.repo' "$f")
    worker=$(jq -r '.worker' "$f")
    entry=$(jq -r '.entry' "$f")
    echo -e "  ${C}${rn}${NC} → Worker: ${G}${worker}${NC}  Entry: ${DM}${entry}${NC}"
    local last_commit=""
    last_commit=$(git -C "$REPOS_DIR/$rn" log --oneline -1 2>/dev/null || echo "(unknown)")
    echo -e "  ${DM}Last commit: ${last_commit}${NC}\n"
  done
  press_enter
}

gh_view_log() {
  header "Git Log"
  echo -e "${W}Available repos:${NC}"
  ls "$REPOS_DIR" 2>/dev/null | nl -v1 -w2
  local repo_name
  read -rp "$(echo -e "${W}Repo name:${NC} ")" repo_name
  [[ -z "$repo_name" ]] && return
  local repo_path="$REPOS_DIR/$repo_name"
  [[ ! -d "$repo_path" ]] && error "Repo not found." && press_enter && return
  git -C "$repo_path" log --oneline --color --decorate -20
  press_enter
}


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# DASHBOARD
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

show_dashboard() {
  header "Dashboard"
  require_account || return
  echo -e "${BLD}${W}Account Overview${NC}"
  echo -e "  ${SYM_GEAR} Account:    ${G}${ACTIVE_ACCOUNT_NAME}${NC}"
  echo -e "  ${SYM_CLOUD} Account ID: ${DM}${CF_ACCOUNT_ID}${NC}"
  echo ""
  echo -e "${C}Fetching resources...${NC}"

  local workers_resp kv_resp r2_resp d1_resp do_resp
  {
    # Fire all 5 lookups concurrently instead of one-after-another — they're
    # independent reads, so this turns ~5 round trips into ~1.
    local _dash_tmp
    _dash_tmp=$(mktemp -d)

    # Workers: serve from cache when fresh to skip the round-trip entirely
    local _workers_cached=false
    if cache_is_fresh "$ACTIVE_ACCOUNT_NAME" "workers"; then
      cache_get "$ACTIVE_ACCOUNT_NAME" "workers" > "$_dash_tmp/workers.json" 2>/dev/null && _workers_cached=true
    fi
    [[ "$_workers_cached" == "false" ]] && \
      cf_get "/accounts/${CF_ACCOUNT_ID}/workers/scripts"                    > "$_dash_tmp/workers.json" &

    cf_get "/accounts/${CF_ACCOUNT_ID}/storage/kv/namespaces?per_page=100" > "$_dash_tmp/kv.json"      &
    cf_get "/accounts/${CF_ACCOUNT_ID}/r2/buckets"                         > "$_dash_tmp/r2.json"      &
    cf_get "/accounts/${CF_ACCOUNT_ID}/d1/database"                        > "$_dash_tmp/d1.json"      &
    cf_get "/accounts/${CF_ACCOUNT_ID}/workers/durable_objects/namespaces" > "$_dash_tmp/do.json"      &
    wait

    workers_resp=$(cat "$_dash_tmp/workers.json" 2>/dev/null || echo '{}')
    kv_resp=$(cat "$_dash_tmp/kv.json" 2>/dev/null || echo '{}')
    r2_resp=$(cat "$_dash_tmp/r2.json" 2>/dev/null || echo '{}')
    d1_resp=$(cat "$_dash_tmp/d1.json" 2>/dev/null || echo '{}')
    do_resp=$(cat "$_dash_tmp/do.json" 2>/dev/null || echo '{}')
    rm -rf "$_dash_tmp"

    # Populate workers cache from dashboard fetch if we didn't serve from cache
    if [[ "$_workers_cached" == "false" ]] && cf_check "$workers_resp" 2>/dev/null; then
      cache_put "$ACTIVE_ACCOUNT_NAME" "workers" "$workers_resp"
    fi

    local wc kvc r2c d1c doc
    wc=$(echo "$workers_resp"  | jq '.result | length' 2>/dev/null || echo "?")
    kvc=$(echo "$kv_resp"      | jq '.result | length' 2>/dev/null || echo "?")
    r2c=$(echo "$r2_resp"      | jq '.result.buckets | length' 2>/dev/null || echo "?")
    d1c=$(echo "$d1_resp"      | jq '.result | length' 2>/dev/null || echo "?")
    doc=$(echo "$do_resp"      | jq '.result | length' 2>/dev/null || echo "?")

    echo -e "\n${BLD}Resource Summary${NC}"
    divider
    printf "  ${C}%-20s${NC} ${W}%s${NC}\n" "Workers"           "$wc"
    printf "  ${C}%-20s${NC} ${W}%s${NC}\n" "KV Namespaces"     "$kvc"
    printf "  ${C}%-20s${NC} ${W}%s${NC}\n" "R2 Buckets"        "$r2c"
    printf "  ${C}%-20s${NC} ${W}%s${NC}\n" "D1 Databases"      "$d1c"
    printf "  ${C}%-20s${NC} ${W}%s${NC}\n" "Durable Objects"   "$doc"
    divider

    if [[ "$wc" != "?" && "$wc" -gt 0 ]]; then
      echo -e "\n${BLD}Recent Workers${NC}"
      echo "$workers_resp" | jq -r '.result[:5][] | "  \(.id)  \(.modified_on[:10] // "")"' 2>/dev/null
    fi

    local linked
    linked=$(ls "$DEPLOY_HOOKS" 2>/dev/null | wc -l || echo 0)
    echo -e "\n  ${SYM_STAR} GitHub repos linked: ${BLD}${linked}${NC}"
    local accounts
    accounts=$(list_accounts | wc -l)
    echo -e "  ${SYM_STAR} Accounts stored:     ${BLD}${accounts}${NC}"
    echo ""
  }
  press_enter
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# SETTINGS MENU
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# AUTO-DEPLOY HANDLER (called by git hooks)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

handle_auto_deploy() {
  local repo_name="$1"
  local link_file="$DEPLOY_HOOKS/${repo_name}.json"
  [[ ! -f "$link_file" ]] && exit 1
  local account_name
  account_name=$(jq -r '.account' "$link_file")
  load_active_account
  CF_TOKEN=$(get_account_field "$account_name" "token")
  CF_ACCOUNT_ID=$(get_account_field "$account_name" "account_id")
  ACTIVE_ACCOUNT_NAME="$account_name"
  gh_sync_deploy "$repo_name"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# MAIN MENU & ENTRYPOINT
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

draw_splash() {
  clear
  echo -e "${C}${BLD}"
  echo '  ╔═══════════════════════════════════════════════╗'
  echo '  ║                                               ║'
  echo '  ║    ██████╗███████╗   ███╗   ███╗ ██████╗ ██╗ ║'
  echo '  ║   ██╔════╝██╔════╝   ████╗ ████║██╔════╝ ██║ ║'
  echo '  ║   ██║     █████╗     ██╔████╔██║██║  ███╗██║ ║'
  echo '  ║   ██║     ██╔══╝     ██║╚██╔╝██║██║   ██║██╗ ║'
  echo '  ║   ╚██████╗██║        ██║ ╚═╝ ██║╚██████╔╝╚█║ ║'
  echo '  ║    ╚═════╝╚═╝        ╚═╝     ╚═╝ ╚═════╝  ╚╝ ║'
  echo '  ║                                               ║'
  echo -e "  ║  ${W}Cloudflare Manager for Termux  v${VERSION}${C}        ║"
  echo '  ╚═══════════════════════════════════════════════╝'
  echo -e "${NC}"
}

main_menu() {
  while true; do
    header "Main Menu"
    echo -e "  ${SYM_CLOUD} ${BLD}${W}Cloudflare Resources${NC}"
    echo -e "  ${C}w${NC}. ${W}Workers${NC}          ${DM}deploy · edit · rollback · logs${NC}"
    echo -e "  ${C}k${NC}. ${W}KV Namespaces${NC}    ${DM}create · read · write keys${NC}"
    echo -e "  ${C}d${NC}. ${W}D1 Databases${NC}     ${DM}SQL queries · tables${NC}"
    echo -e "  ${C}r${NC}. ${W}R2 Buckets${NC}       ${DM}upload · list · manage${NC}"
    echo -e "  ${C}o${NC}. ${W}Durable Objects${NC}  ${DM}namespaces · instances${NC}"
    echo -e "  ${C}b${NC}. ${W}Bindings${NC}         ${DM}bind · list · sync names to worker${NC}"
    echo ""
    echo -e "  ${SYM_GEAR} ${BLD}${W}Tools${NC}"
    echo -e "  ${C}g${NC}. ${W}GitHub Sync${NC}      ${DM}clone · link · auto-deploy${NC}"
    echo -e "  ${C}c${NC}. ${W}Cron Triggers${NC}    ${DM}add · remove · view schedules${NC}"
    echo -e "  ${C}h${NC}. ${W}Dashboard${NC}        ${DM}overview & stats${NC}"
    echo -e "  ${C}s${NC}. ${W}Settings${NC}         ${DM}accounts · log${NC}"
    echo ""
    echo -e "  ${C}q${NC}. ${R}Quit${NC}"
    echo -ne "\n${W}Choice:${NC} "
    read -r choice
    case "$choice" in
      w) workers_menu ;;
      k) kv_menu ;;
      d) d1_menu ;;
      r) r2_menu ;;
      o) do_menu ;;
      b) bindings_menu ;;
      g) gh_menu ;;
      c) worker_cron_menu ;;
      h) show_dashboard ;;
      s) settings_menu ;;
      q)
        echo -e "\n${G}Goodbye.${NC}\n"
        exit 0
        ;;
      *) warn "Invalid option." ; sleep 0.5 ;;
    esac
  done
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# BOOTSTRAP
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

main() {
  # Handle non-interactive flag (git hook auto-deploy)
  if [[ "${1:-}" == "--auto-deploy" ]]; then
    handle_auto_deploy "${2:-}"
    exit $?
  fi

  check_deps
  draw_splash

  # Create directory structure
  mkdir -p "$CONFIG_DIR" "$WORKERS_DIR" "$REPOS_DIR" "$BACKUPS_DIR" \
           "$BACKUPS_DIR/workers" "$DEPLOY_HOOKS" "$CACHE_DIR"
  chmod 700 "$CONFIG_DIR"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"

  # One-time migration from old master-password vault (no-op if not needed)
  maybe_migrate_legacy_vault

  # First-time setup: no accounts stored yet
  if [[ ! -f "$ACCOUNTS_ENC" ]]; then
    echo -e "${Y}${BLD}Welcome to CF-Manager!${NC} No accounts found — add your first one.\n"
    add_account
  fi

  load_active_account

  if [[ -z "$ACTIVE_ACCOUNT_NAME" ]]; then
    local accounts
    mapfile -t accounts < <(list_accounts)
    if [[ ${#accounts[@]} -gt 0 ]]; then
      echo "${accounts[0]}" > "$CURRENT_ACCOUNT"
      load_active_account
    fi
  fi

  log "Session started. Account: ${ACTIVE_ACCOUNT_NAME:-none}"
  main_menu
}

main "$@"
