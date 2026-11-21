#!/usr/bin/env bash
# =============================================================================
#  WaterWall Manager — modular, menu-driven installer & tunnel manager
#  Project : https://github.com/radkesvat/WaterWall
#  Docs    : https://radkesvat.github.io/WaterWall-Docs/
#
#  Usage   : sudo bash waterwall-manager.sh            (interactive menu)
#            sudo ww <command> [args]                   (after first run)
#  Run 'ww help' for all commands.
# =============================================================================

set -o pipefail

# ----------------------------------------------------------------------------
# [MODULE] constants
# ----------------------------------------------------------------------------
readonly SCRIPT_VERSION="2.0.0"
readonly REPO="radkesvat/WaterWall"
WW_ROOT="${WW_ROOT:-}"                          # set for dry-run/testing (e.g. /tmp/wwtest)
WW_HOME="${WW_ROOT}/opt/waterwall"
WW_BIN_DIR="${WW_HOME}/bin"
WW_LIBS="${WW_HOME}/libs"
WW_ETC="${WW_ROOT}/etc/waterwall"
WW_TUNNELS="${WW_ETC}/tunnels"
WW_CERTS="${WW_ETC}/certs"
WW_BACKUPS="${WW_ETC}/backups"
WW_SETTINGS="${WW_ETC}/manager.conf"
SYSTEMD_DIR="${WW_ROOT}/etc/systemd/system"
CRON_FILE="${WW_ROOT}/etc/cron.d/waterwall"
SELF_PATH="${WW_ROOT}/usr/local/bin/ww"
KNOWN_LINUX_ASSETS=(Waterwall-linux-clang-avx512f-x64.zip Waterwall-linux-clang-x64.zip
  Waterwall-linux-gcc-x64.zip Waterwall-linux-gcc-x64-old-cpu.zip
  Waterwall-linux-gcc-arm64.zip Waterwall-linux-gcc-arm64-old-cpu.zip)

# ----------------------------------------------------------------------------
# [MODULE] ui
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_B=$'\e[34m'; C_C=$'\e[36m'
  C_W=$'\e[1m'; C_D=$'\e[2m'; C_0=$'\e[0m'
else
  C_R=; C_G=; C_Y=; C_B=; C_C=; C_W=; C_D=; C_0=
fi

info()  { printf '%s[i]%s %s\n' "$C_C" "$C_0" "$*"; }
ok()    { printf '%s[✓]%s %s\n' "$C_G" "$C_0" "$*"; }
warn()  { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*"; }
err()   { printf '%s[✗]%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()   { err "$*"; exit 1; }
line()  { printf '%s%s%s\n' "$C_D" "────────────────────────────────────────────────────────" "$C_0"; }
pause() { [[ -n "${WW_NONINTERACTIVE:-}" ]] && return; read -rp "$(printf '%sPress Enter to continue...%s' "$C_D" "$C_0")" _ || true; }

banner() {
  [[ -z "${WW_NONINTERACTIVE:-}" ]] && { clear 2>/dev/null || true; }
  printf '%s' "$C_B$C_W"
  cat <<'EOF'
 __        __    _            __        __    _ _
 \ \      / /_ _| |_ ___ _ __ \ \      / /_ _| | |
  \ \ /\ / / _` | __/ _ \ '__| \ \ /\ / / _` | | |
   \ V  V / (_| | ||  __/ |     \ V  V / (_| | | |
    \_/\_/ \__,_|\__\___|_|      \_/\_/ \__,_|_|_|
EOF
  printf '%s' "$C_0"
  printf '  %sManager v%s%s   core: %s   tunnels: %s\n' "$C_D" "$SCRIPT_VERSION" "$C_0" \
    "$(core_version_str)" "$(tunnel_count)"
  line
}

# ask VAR "Prompt" "default" [validator]
ask() {
  local __var=$1 __prompt=$2 __def=${3:-} __val=${4:-} __in
  while true; do
    if [[ -n "$__def" ]]; then
      read -rp "$(printf '%s?%s %s %s[%s]%s: ' "$C_Y" "$C_0" "$__prompt" "$C_D" "$__def" "$C_0")" __in || die "Input closed."
      __in=${__in:-$__def}
    else
      read -rp "$(printf '%s?%s %s: ' "$C_Y" "$C_0" "$__prompt")" __in || die "Input closed."
    fi
    if [[ -z "$__in" ]]; then warn "Value required."; continue; fi
    if [[ -n "$__val" ]] && ! "$__val" "$__in"; then warn "Invalid value: $__in"; continue; fi
    printf -v "$__var" '%s' "$__in"; return 0
  done
}

# confirm "Question" [y|n default]
confirm() {
  local q=$1 d=${2:-n} a hint="[y/N]"
  [[ $d == y ]] && hint="[Y/n]"
  read -rp "$(printf '%s?%s %s %s: ' "$C_Y" "$C_0" "$q" "$hint")" a || die "Input closed."
  a=${a:-$d}
  [[ $a =~ ^[Yy] ]]
}

# choose VAR "Title" opt1 opt2 ...   -> sets VAR to the 1-based index
choose() {
  local __var=$1 __title=$2; shift 2
  local i=1 __c o
  [[ -n $__title ]] && printf '%s%s%s\n' "$C_W" "$__title" "$C_0"
  for o in "$@"; do printf '  %s%2d)%s %s\n' "$C_C" "$i" "$C_0" "$o"; ((i++)); done
  while true; do
    read -rp "$(printf '%s>%s ' "$C_Y" "$C_0")" __c || die "Input closed."
    if [[ $__c =~ ^[0-9]+$ ]] && (( __c >= 1 && __c <= $# )); then printf -v "$__var" '%s' "$__c"; return 0; fi
    warn "Choose 1-$#"
  done
}

# ----------------------------------------------------------------------------
# [MODULE] validators & helpers
# ----------------------------------------------------------------------------
is_port() { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
is_ipv4() {
  [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local o; for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}
is_ipv6() { [[ $1 == *:* && $1 =~ ^[0-9a-fA-F:]+$ ]]; }
is_ip()   { is_ipv4 "$1" || is_ipv6 "$1"; }
is_ip_or_zero() { [[ $1 == 0 ]] || is_ip "$1"; }
is_domain() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }
is_host() { is_ip "$1" || is_domain "$1" || [[ $1 =~ ^[A-Za-z0-9-]+$ ]]; }
is_cidr() { [[ $1 == */* ]] && is_ipv4 "${1%/*}" && [[ ${1#*/} =~ ^[0-9]+$ ]] && (( ${1#*/} <= 32 )); }
is_name() { [[ $1 =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$ ]]; }
is_num()  { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 )); }
is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }
is_hours(){ [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 <= 24 )); }
is_byte() { [[ $1 =~ ^[0-9]+$ ]] && (( 10#$1 <= 255 )); }
is_file() { [[ -f $1 ]]; }
is_uuid() { [[ $1 =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }
is_secret32() { [[ -n $1 && ${#1} -le 32 && $1 != *'"'* && $1 != *'\'* ]]; }
is_safe_str() { [[ -n $1 && $1 != *'"'* && $1 != *'\'* ]]; }
is_json()  { jq -e . >/dev/null 2>&1 <<<"$1"; }
is_ifname() { [[ $1 =~ ^[A-Za-z0-9_-]{1,15}$ ]]; }
is_new_tunnel() {
  if is_name "$1" && [[ ! -e "$WW_TUNNELS/$1" ]]; then return 0; fi
  warn "Name exists or is invalid (use a-z 0-9 - _ , max 32)."; return 1
}

json_str() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
ip_cidr()  { if is_ipv6 "$1"; then printf '%s/128' "$1"; else printf '%s/32' "$1"; fi; }
rand_pass() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "${1:-24}"; }
rand_hex()  { openssl rand -hex "${1:-32}" 2>/dev/null || LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c $(( ${1:-32} * 2 )); }
new_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null; then uuidgen
  else local h; h=$(rand_hex 16); printf '%s-%s-4%s-a%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"; fi
}
resolve4() { getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}'; }

PUBLIC_IP_CACHE=""
public_ip() {
  [[ -n $PUBLIC_IP_CACHE ]] && { echo "$PUBLIC_IP_CACHE"; return; }
  local ip="" u
  if [[ -z ${WW_OFFLINE:-} ]]; then
    for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me; do
      ip=$(curl -fsS -4 --max-time 4 "$u" 2>/dev/null | tr -d '[:space:]')
      is_ipv4 "$ip" && break; ip=""
    done
  fi
  [[ -z $ip ]] && ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  PUBLIC_IP_CACHE=$ip; echo "$ip"
}
wan_iface() { ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'; }

# Replace a config's $var$ placeholders with strings so strict JSON tools can read it.
quote_placeholders() { sed -E 's/\$([A-Za-z0-9_]+)\$/"__V_\1__"/g' "$1"; }

# Atomic in-place jq edit: jq_inplace FILE [jq args...] FILTER
jq_inplace() {
  local f=$1 t; shift
  t=$(mktemp) || return 1
  if jq "$@" "$f" >"$t" 2>/dev/null; then cat "$t" >"$f"; rm -f "$t"; return 0; fi
  rm -f "$t"; err "jq edit failed on $f"; return 1
}

# ----------------------------------------------------------------------------
# [MODULE] system / dependencies
# ----------------------------------------------------------------------------
require_root() { [[ -n "$WW_ROOT" ]] && return; [[ $EUID -eq 0 ]] || die "Run as root (sudo)."; }

pkg_install() {
  local pkgs=("$@")
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
  elif command -v dnf >/dev/null; then dnf install -y -q "${pkgs[@]}"
  elif command -v yum >/dev/null; then yum install -y -q "${pkgs[@]}"
  elif command -v apk >/dev/null; then apk add --no-cache "${pkgs[@]}"
  elif command -v pacman >/dev/null; then pacman -Sy --noconfirm "${pkgs[@]}"
  else warn "No known package manager; install manually: ${pkgs[*]}"; return 1; fi
}

ensure_deps() {
  [[ -n $WW_ROOT ]] && return 0
  local need=() c
  for c in curl unzip openssl jq ss ip iptables; do
    command -v "$c" >/dev/null && continue
    case $c in ss|ip) [[ " ${need[*]} " == *" iproute2 "* ]] || need+=(iproute2);; *) need+=("$c");; esac
  done
  ((${#need[@]})) || return 0
  info "Installing dependencies: ${need[*]}"
  pkg_install "${need[@]}" || warn "Some dependencies could not be installed."
}
need_jq() { command -v jq >/dev/null || { ensure_deps; command -v jq >/dev/null; } || die "jq is required (apt install jq)."; }

has_systemd() { [[ -z "$WW_ROOT" ]] && command -v systemctl >/dev/null && [[ -d /run/systemd/system ]]; }

load_settings() {
  GH_PROXY=""; LOG_LEVEL="INFO"
  [[ -f $WW_SETTINGS ]] && source "$WW_SETTINGS"
}
save_settings() {
  mkdir -p "$WW_ETC"
  printf 'GH_PROXY=%q\nLOG_LEVEL=%q\n' "$GH_PROXY" "$LOG_LEVEL" >"$WW_SETTINGS"
}

# ----------------------------------------------------------------------------
# [MODULE] core installer
# ----------------------------------------------------------------------------
core_bin() { local b; for b in "$WW_BIN_DIR/Waterwall" "$WW_BIN_DIR/WaterWall"; do [[ -x $b ]] && { echo "$b"; return 0; }; done; return 1; }
core_version_str() {
  if core_bin >/dev/null; then printf '%s%s%s' "$C_G" "$(cat "$WW_HOME/VERSION" 2>/dev/null || echo installed)" "$C_0"
  else printf '%snot installed%s' "$C_R" "$C_0"; fi
}

gh_url() { printf '%s%s' "${GH_PROXY}" "$1"; }

# Ordered list of asset names that fit this CPU (best first).
asset_candidates() {
  case $(uname -m) in
    x86_64|amd64)
      grep -qw avx512f /proc/cpuinfo 2>/dev/null && echo Waterwall-linux-clang-avx512f-x64.zip
      if grep -qw avx2 /proc/cpuinfo 2>/dev/null; then
        echo Waterwall-linux-clang-x64.zip; echo Waterwall-linux-gcc-x64.zip; echo Waterwall-linux-gcc-x64-old-cpu.zip
      else
        echo Waterwall-linux-gcc-x64-old-cpu.zip; echo Waterwall-linux-gcc-x64.zip; echo Waterwall-linux-clang-x64.zip
      fi;;
    aarch64|arm64)
      if grep -qw atomics /proc/cpuinfo 2>/dev/null; then echo Waterwall-linux-gcc-arm64.zip; echo Waterwall-linux-gcc-arm64-old-cpu.zip
      else echo Waterwall-linux-gcc-arm64-old-cpu.zip; echo Waterwall-linux-gcc-arm64.zip; fi;;
    *) return 1;;
  esac
}

# Resolve "latest" to a real tag without the API (follows the releases/latest redirect).
resolve_latest_tag() {
  local loc
  loc=$(curl -fsSI --max-time 15 "$(gh_url "https://github.com/$REPO/releases/latest")" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}' | tail -n1)
  [[ $loc == */tag/* ]] && echo "${loc##*/tag/}"
}

download_url() { # tag asset
  if [[ $1 == latest ]]; then echo "https://github.com/$REPO/releases/latest/download/$2"
  else echo "https://github.com/$REPO/releases/download/$1/$2"; fi
}

core_install_from_zip() {
  local zip=$1 tag=${2:-local} tmp
  tmp=$(mktemp -d) || return 1
  unzip -oq "$zip" -d "$tmp" || { err "Failed to extract $zip"; rm -rf "$tmp"; return 1; }
  local bin; bin=$(find "$tmp" -type f \( -iname 'waterwall' -o -iname 'waterwall.exe' \) | head -n1)
  [[ -n $bin ]] || { err "WaterWall binary not found in archive."; rm -rf "$tmp"; return 1; }
  chmod +x "$bin"
  if [[ -z $WW_ROOT ]]; then
    timeout 3 "$bin" --config:/nonexistent-ww.json >/dev/null 2>&1
    if [[ $? -eq 132 ]]; then err "This build crashes on this CPU (illegal instruction)."; rm -rf "$tmp"; return 132; fi
  fi
  local was_running=() s
  if has_systemd; then mapfile -t was_running < <(systemctl list-units --type=service --state=running --no-legend 'waterwall@*' 2>/dev/null | awk '{print $1}'); fi
  for s in "${was_running[@]}"; do systemctl stop "$s"; done
  mkdir -p "$WW_BIN_DIR" "$WW_LIBS"
  install -m 0755 "$bin" "$WW_BIN_DIR/Waterwall"
  local libdir; libdir=$(find "$tmp" -type d -name libs | head -n1)
  [[ -n $libdir ]] && cp -a "$libdir/." "$WW_LIBS/"
  echo "$tag" >"$WW_HOME/VERSION"
  rm -rf "$tmp"
  for s in "${was_running[@]}"; do systemctl start "$s"; done
  ok "WaterWall core installed: $tag  ->  $WW_BIN_DIR/Waterwall"
}

core_install() { # tag(latest|vX) mode(auto|manual)
  local tag=${1:-latest} mode=${2:-auto}
  ensure_deps
  local rtag=$tag
  if [[ $tag == latest ]]; then
    info "Resolving latest release ..."
    rtag=$(resolve_latest_tag); [[ -z $rtag ]] && { warn "Could not resolve tag; using 'latest' download links."; rtag=latest; }
  fi
  local -a cands=()
  if [[ $mode == manual ]]; then
    local c; choose c "Select build ($rtag):" "${KNOWN_LINUX_ASSETS[@]}"; cands=("${KNOWN_LINUX_ASSETS[$((c-1))]}")
  else
    mapfile -t cands < <(asset_candidates)
    ((${#cands[@]})) || { warn "Unknown CPU $(uname -m); choose manually."; core_install "$tag" manual; return; }
  fi
  local a tmpz rc=1
  for a in "${cands[@]}"; do
    info "Downloading $a ($rtag) ..."
    tmpz=$(mktemp --suffix=.zip)
    if curl -fL --progress-bar --retry 3 --connect-timeout 15 -o "$tmpz" "$(gh_url "$(download_url "$rtag" "$a")")"; then
      core_install_from_zip "$tmpz" "$rtag ($a)"; rc=$?
      rm -f "$tmpz"
      (( rc == 132 )) && { warn "Trying the next build ..."; continue; }
      break
    fi
    rm -f "$tmpz"; err "Download failed: $a"
  done
  if (( rc != 0 )); then
    err "Core installation failed."
    warn "GitHub may be filtered: set a download proxy in Settings, or download the zip elsewhere and use 'Install from local zip'."
  fi
  return $rc
}

core_menu() {
  while true; do
    banner
    printf 'Installed: %s   binary: %s\n' "$(core_version_str)" "$(core_bin || echo -)"; line
    local c
    choose c "Core management:" "Install / update to latest (auto-detect build)" "Install a specific version (tag)" \
      "Install latest - choose build manually" "Install from local zip (offline)" "Remove core binary" "Back"
    case $c in
      1) core_install latest auto; pause;;
      2) local t; ask t "Release tag (e.g. v1.5.42)" "" is_safe_str; core_install "$t" auto; pause;;
      3) core_install latest manual; pause;;
      4) local z; ask z "Path to Waterwall-linux-*.zip" "" is_file; core_install_from_zip "$z" "local:$(basename "$z")"; pause;;
      5) confirm "Remove core binary?" && rm -rf "$WW_BIN_DIR" "$WW_LIBS" "$WW_HOME/VERSION" && ok "Removed."; pause;;
      6) return;;
    esac
  done
}

# ----------------------------------------------------------------------------
# [MODULE] json node builders (wizard)
# ----------------------------------------------------------------------------
# node NAME TYPE 'SETTINGS_JSON' [NEXT]
node() {
  local n=$1 t=$2 s=${3:-'{}'} nx=${4:-}
  if [[ -n $nx ]]; then
    printf '    {\n      "name": %s,\n      "type": %s,\n      "settings": %s,\n      "next": %s\n    }' \
      "$(json_str "$n")" "$(json_str "$t")" "$s" "$(json_str "$nx")"
  else
    printf '    {\n      "name": %s,\n      "type": %s,\n      "settings": %s\n    }' \
      "$(json_str "$n")" "$(json_str "$t")" "$s"
  fi
}

s_tcp_listen() { # port [whitelist_cidr]
  local wl=""; [[ -n ${2:-} ]] && wl=", \"whitelist\": [$(json_str "$2")]"
  printf '{ "address": "0.0.0.0", "port": %s, "nodelay": true%s }' "$1" "$wl"
}
s_udp_listen() {
  local wl=""; [[ -n ${2:-} ]] && wl=", \"whitelist\": [$(json_str "$2")]"
  printf '{ "address": "0.0.0.0", "port": %s%s }' "$1" "$wl"
}
s_tcp_conn() { printf '{ "address": %s, "port": %s, "nodelay": true }' "$(json_str "$1")" "$2"; }
s_udp_conn() { printf '{ "address": %s, "port": %s }' "$(json_str "$1")" "$2"; }
s_mux_client() { printf '{ "mode": "fixed-connections-count", "per-worker-connections-count": %s }' "$1"; }
s_tls_client() { printf '{ "sni": %s, "verify": %s }' "$(json_str "$1")" "$2"; }
s_tls_server() {
  printf '{ "cert-file": %s, "key-file": %s, "min-version": "TLSv1.2", "max-version": "TLSv1.3", "ciphers": "HIGH:!aNULL:!MD5", "session-cache": "none", "session-tickets": true, "verbose": false }' \
    "$(json_str "$1")" "$(json_str "$2")"
}
s_reality_client() {
  printf '{ "sni": %s, "verify": true, "password": %s, "algorithm": "chacha20-poly1305", "kdf-iterations": 12000 }' \
    "$(json_str "$1")" "$(json_str "$2")"
}
s_reality_server() {
  printf '{ "destination": "dest-visitor", "password": %s, "algorithm": "chacha20-poly1305", "kdf-iterations": 12000, "sniffing-attempts": 8 }' \
    "$(json_str "$1")"
}
s_quic_client() { printf '{ "sni": %s, "verify": %s, "protocol": "h3", "max-packet-size": 1350 }' "$(json_str "$1")" "$2"; }
s_quic_server() { printf '{ "cert-file": %s, "key-file": %s, "protocol": "h3", "max-packet-size": 1350 }' "$(json_str "$1")" "$(json_str "$2")"; }
s_kcp() {
  if (( ${FEC:-0} )); then
    printf '{ "send-mtu": 1400, "fec": true, "fec-data-shards": 10, "fec-parity-shards": 3, "kcp-no-congestion-control": false }'
  else
    printf '{ "send-mtu": 1400, "fec": false, "kcp-no-congestion-control": false }'
  fi
}
s_enc() { printf '{ "algorithm": "chacha20-poly1305", "password": %s, "salt": "waterwall-manager", "kdf-iterations": 12000, "max-frame-size": 16356 }' "$(json_str "$1")"; }

join_nodes() { local first=1 n; for n in "$@"; do ((first)) || printf ',\n'; printf '%s' "$n"; first=0; done; }

write_config() { # file name nodes...
  local f=$1 name=$2; shift 2
  {
    printf '{\n  "name": %s,\n  "author": "waterwall-manager",\n  "config-version": 1,\n  "nodes": [\n' "$(json_str "$name")"
    join_nodes "$@"
    printf '\n  ]\n}\n'
  } >"$f"
}

write_core() { # dir mtu ram_profile
  local d=$1 mtu=${2:-1500} rp=${3:-server}
  cat >"$d/core.json" <<EOF
{
  "log": {
    "path": "logs/",
    "core":     { "loglevel": "${LOG_LEVEL}", "file": "core.log",     "console": true  },
    "network":  { "loglevel": "${LOG_LEVEL}", "file": "network.log",  "console": true  },
    "dns":      { "loglevel": "WARN",         "file": "dns.log",      "console": false },
    "internal": { "loglevel": "${LOG_LEVEL}", "file": "internal.log", "console": false }
  },
  "misc": {
    "workers": 0,
    "ram-profile": "${rp}",
    "mtu": ${mtu},
    "try-enabling-bbr": true,
    "libs-path": "${WW_LIBS}/"
  },
  "dns": { "domain-strategy": "prefer-ipv4" },
  "configs": [ "${d}/config.json" ]
}
EOF
}

validate_json() { jq empty "$1" 2>/dev/null; }

# Strict check of a WaterWall node config (placeholders allowed). Prints problems.
config_check() {
  local f=$1 q
  q=$(quote_placeholders "$f" | jq -c . 2>/dev/null) || { echo "not valid JSON"; return 1; }
  jq -r '
    if (.nodes|type) != "array" or (.nodes|length) == 0 then "missing nodes array" else
    ([.nodes[].name]) as $names
    | ( ($names | group_by(.) | map(select(length>1)) | .[] | "duplicate node name: \(.[0])"),
        (.nodes[] | select((.name|type)!="string" or (.type|type)!="string") | "node without name/type"),
        (.nodes[] | . as $n | [ .next, .settings.pair?, .settings.upload?, .settings.download?,
              (if .type=="PacketSplitStream" then .settings.up?, .settings.down? else empty end),
              (if .type=="RealityServer" then .settings.destination? else empty end),
              (.settings.rules?[]?.target?) ]
           | .[] | select(type=="string") | select(. as $r | $names | any(. == $r) | not)
           | "\($n.name): unknown node reference \"\(.)\"" ) )
    end' <<<"$q"
}
config_ok() { [[ -z $(config_check "$1") ]]; }

# ----------------------------------------------------------------------------
# [MODULE] certificates
# ----------------------------------------------------------------------------
# cert_setup DOMAIN  -> sets CERT_FILE KEY_FILE VERIFY
cert_setup() {
  local sni=$1 c
  choose c "TLS certificate for $sni (server side):" \
    "Generate self-signed (quick; clients must use verify=false)" \
    "Use existing cert files (e.g. Let's Encrypt; clients verify=true)" \
    "Issue with certbot standalone (needs port 80 + domain pointing here)"
  mkdir -p "$WW_CERTS"
  case $c in
    1)
      CERT_FILE="$WW_CERTS/$sni.crt"; KEY_FILE="$WW_CERTS/$sni.key"; VERIFY=false
      openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 \
        -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=$sni" -addext "subjectAltName=DNS:$sni" >/dev/null 2>&1 \
        || openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=$sni" >/dev/null 2>&1 \
        || { err "openssl failed"; return 1; }
      chmod 600 "$KEY_FILE"; ok "Self-signed certificate created for $sni"
      warn "On the client side answer 'yes' to 'self-signed?' so verify=false is used.";;
    2)
      ask CERT_FILE "Full-chain cert path" "/etc/letsencrypt/live/$sni/fullchain.pem" is_file
      ask KEY_FILE  "Private key path"     "/etc/letsencrypt/live/$sni/privkey.pem" is_file
      VERIFY=true;;
    3)
      command -v certbot >/dev/null || pkg_install certbot || { err "certbot unavailable"; return 1; }
      certbot certonly --standalone --non-interactive --agree-tos --register-unsafely-without-email -d "$sni" \
        || { err "certbot failed"; return 1; }
      CERT_FILE="/etc/letsencrypt/live/$sni/fullchain.pem"; KEY_FILE="/etc/letsencrypt/live/$sni/privkey.pem"; VERIFY=true;;
  esac
}

# ----------------------------------------------------------------------------
# [MODULE] quick wizard templates
#   Role "client" = entry server: users connect here
#   Role "server" = exit server: the final service runs here
# ----------------------------------------------------------------------------
MODES=(
  "portfwd|Simple TCP port forward (single server)"
  "direct-tcp|Direct TCP (+optional encryption / Mux)"
  "direct-tls|Direct TLS"
  "direct-reality|Direct Reality (no cert, mimics a real site)"
  "direct-quic|Direct QUIC (UDP, TLS1.3)"
  "direct-kcp|Direct KCP (UDP, loss-tolerant, +optional FEC)"
  "reverse-tcp|Reverse TCP (server dials the client)"
  "reverse-tls|Reverse TLS"
  "reverse-reality|Reverse Reality"
  "reverse-quic|Reverse QUIC"
  "reverse-kcp|Reverse KCP"
  "ping|ICMP (Ping) tunnel — raw socket"
  "faketcp|Fake TCP header tunnel — raw socket"
  "wireguard|WireGuard VPN server (for official WireGuard apps)"
  "authapi|User database + management API (AuthenticationServer + APIServer)"
)

mode_desc() { local m; for m in "${MODES[@]}"; do [[ ${m%%|*} == "$1" ]] && { echo "${m#*|}"; return; }; done; echo "$1"; }

# Builds the client half of a transport. Sets TNODES (array) and THEAD (first node name).
build_transport_client() { # kind next_name
  local kind=$1 nx=$2
  TNODES=(); THEAD=$nx
  case $kind in
    tcp)     ;;
    tls)     TNODES+=("$(node tls_client TlsClient "$(s_tls_client "$SNI" "$VERIFY")" "$nx")"); THEAD=tls_client;;
    reality) TNODES+=("$(node reality_client RealityClient "$(s_reality_client "$SNI" "$PASSWORD")" "$nx")"); THEAD=reality_client;;
    quic)    TNODES+=("$(node quic_client QuicClient "$(s_quic_client "$SNI" "$VERIFY")" "$nx")"); THEAD=quic_client;;
    kcp)     TNODES+=("$(node kcp_client KcpClient "$(s_kcp)" "$nx")"); THEAD=kcp_client;;
  esac
  if (( ${ENC:-0} )); then
    TNODES=("$(node enc_client EncryptionClient "$(s_enc "$ENC_PASS")" "$THEAD")" "${TNODES[@]}"); THEAD=enc_client
  fi
}
# Builds the server half. The transport server forwards to $nx (through EncryptionServer if enabled).
build_transport_server() { # kind next_name
  local kind=$1 nx=$2 after=$2
  TNODES=()
  if (( ${ENC:-0} )); then TNODES+=("$(node enc_server EncryptionServer "$(s_enc "$ENC_PASS")" "$nx")"); after=enc_server; fi
  THEAD=$after
  case $kind in
    tcp)     ;;
    tls)     TNODES+=("$(node tls_server TlsServer "$(s_tls_server "$CERT_FILE" "$KEY_FILE")" "$after")"); THEAD=tls_server;;
    reality) TNODES+=("$(node reality_server RealityServer "$(s_reality_server "$PASSWORD")" "$after")")
             TNODES+=("$(node dest-visitor TcpConnector "$(s_tcp_conn "$VISITOR_IP" 443)")"); THEAD=reality_server;;
    quic)    TNODES+=("$(node quic_server QuicServer "$(s_quic_server "$CERT_FILE" "$KEY_FILE")" "$after")"); THEAD=quic_server;;
    kcp)     TNODES+=("$(node kcp_server KcpServer "$(s_kcp)" "$after")"); THEAD=kcp_server;;
  esac
}
is_udp_kind() { [[ $1 == quic || $1 == kcp ]]; }

# Collect the security parameters a transport needs, per side.
collect_transport_params() { # kind side(client|server)
  local kind=$1 side=$2 gp
  case $kind in
    tls|quic)
      if [[ $side == client ]]; then
        ask SNI "SNI / domain for the TLS handshake" "${SNI:-www.example.com}" is_domain
        if confirm "Is the server certificate self-signed?" y; then VERIFY=false; else VERIFY=true; fi
      else
        ask SNI "Certificate domain (CN/SAN)" "${SNI:-www.example.com}" is_domain
        cert_setup "$SNI" || return 1
      fi;;
    reality)
      if [[ $side == client ]]; then
        ask SNI "Reality SNI (real site the server shows to strangers)" "${SNI:-www.speedtest.net}" is_domain
      else
        local vh; ask vh "Real site for non-authenticated visitors (domain or IP)" "www.speedtest.net" is_host
        VISITOR_IP=$vh
        if ! is_ip "$vh"; then
          VISITOR_IP=$(resolve4 "$vh")
          [[ -n $VISITOR_IP ]] || ask VISITOR_IP "Could not resolve $vh; enter its IPv4" "" is_ipv4
        fi
        VISITOR_HOST=$vh
      fi
      gp=$(rand_pass 24)
      ask PASSWORD "Shared Reality password (same on both sides)" "${PASSWORD:-$gp}" is_secret32;;
    tcp|kcp)
      if [[ $kind == kcp ]] && confirm "Enable KCP FEC (forward error correction; same on both sides)?" n; then FEC=1; fi
      if confirm "Add AEAD encryption layer (ChaCha20; same choice on both sides)?" y; then
        ENC=1; gp=$(rand_pass 24)
        ask ENC_PASS "Encryption password (max 32 chars, same on both sides)" "$gp" is_secret32
      fi;;
  esac
}

ask_mux() {
  MUX=0; MUX_N=4
  if confirm "Enable Mux (same choice on both sides)?" "${1:-y}"; then
    MUX=1; ask MUX_N "Mux connections per worker" "4" is_num
  fi
}

# Optional user-facing speed limit (client/entry side). Sets SL_MBPS / SL_MODE.
ask_speed_limit() {
  SL_MBPS=0
  ask SL_MBPS "Bandwidth limit for users in MB/s (0 = unlimited)" "0" is_uint
  if (( 10#$SL_MBPS > 0 )); then
    local c; choose c "Limit applies to:" "All users together (total)" "Each connection separately"
    SL_MODE=all-lines; [[ $c == 2 ]] && SL_MODE=per-line
  fi
}

gen_portfwd() {
  ask USER_PORT "Listen port" "8080" is_port
  ask TARGET "Target host/IP" "" is_host
  ask TARGET_PORT "Target port" "$USER_PORT" is_port
  NODES=("$(node users_inbound TcpListener "$(s_tcp_listen "$USER_PORT")" outbound)"
         "$(node outbound TcpConnector "$(s_tcp_conn "$TARGET" "$TARGET_PORT")")")
  ask_speed_limit
  META+=("USER_PORT=$USER_PORT" "TARGET=$TARGET:$TARGET_PORT")
}

gen_direct() { # kind
  local kind=$1
  if [[ $ROLE == client ]]; then
    ask USER_PORT "Port users connect to (on this client server)" "443" is_port
    ask PEER_IP "Server IP (the exit server)" "" is_ip
    ask TRANSPORT_PORT "Tunnel port on the server" "$( is_udp_kind "$kind" && echo 4433 || echo 443)" is_port
    collect_transport_params "$kind" client || return 1
    if [[ $kind == tcp || $kind == kcp ]]; then ask_mux n; else ask_mux y; fi
    local conn_type=TcpConnector conn_set; conn_set=$(s_tcp_conn "$PEER_IP" "$TRANSPORT_PORT")
    if is_udp_kind "$kind"; then conn_type=UdpConnector; conn_set=$(s_udp_conn "$PEER_IP" "$TRANSPORT_PORT"); fi
    build_transport_client "$kind" to_server
    local head=$THEAD; local -a mux=()
    if ((MUX)); then mux=("$(node mux_client MuxClient "$(s_mux_client "$MUX_N")" "$head")"); head=mux_client; fi
    NODES=("$(node users_inbound TcpListener "$(s_tcp_listen "$USER_PORT")" "$head")" "${mux[@]}" "${TNODES[@]}"
           "$(node to_server "$conn_type" "$conn_set")")
    ask_speed_limit
    META+=("USER_PORT=$USER_PORT" "PEER=$PEER_IP:$TRANSPORT_PORT")
  else
    ask TRANSPORT_PORT "Tunnel listen port (on this server)" "$( is_udp_kind "$kind" && echo 4433 || echo 443)" is_port
    ask FINAL_IP "Final service address" "127.0.0.1" is_host
    ask FINAL_PORT "Final service port (e.g. your xray/v2ray inbound)" "" is_port
    ask PEER_IP "Client server IP to whitelist (0 = allow any)" "0" is_ip_or_zero
    collect_transport_params "$kind" server || return 1
    if [[ $kind == tcp || $kind == kcp ]]; then ask_mux n; else ask_mux y; fi
    local wl=""; is_ip "$PEER_IP" && wl=$(ip_cidr "$PEER_IP")
    local after=outbound; ((MUX)) && after=mux_server
    build_transport_server "$kind" "$after"
    local lst
    if is_udp_kind "$kind"; then lst=$(node transport_inbound UdpListener "$(s_udp_listen "$TRANSPORT_PORT" "$wl")" "$THEAD")
    else lst=$(node transport_inbound TcpListener "$(s_tcp_listen "$TRANSPORT_PORT" "$wl")" "$THEAD"); fi
    NODES=("$lst" "${TNODES[@]}")
    ((MUX)) && NODES+=("$(node mux_server MuxServer '{}' outbound)")
    NODES+=("$(node outbound TcpConnector "$(s_tcp_conn "$FINAL_IP" "$FINAL_PORT")")")
    META+=("TRANSPORT_PORT=$TRANSPORT_PORT" "FINAL=$FINAL_IP:$FINAL_PORT")
  fi
}

gen_reverse() { # kind
  local kind=$1
  if [[ $ROLE == client ]]; then
    ask USER_PORT "Port users connect to (on this client server)" "443" is_port
    ask TRANSPORT_PORT "Port the server connects back to (may equal the user port for TCP kinds)" \
      "$( is_udp_kind "$kind" && echo 4433 || echo "$USER_PORT")" is_port
    ask PEER_IP "Server IP (whitelisted on the tunnel port)" "" is_ip
    collect_transport_params "$kind" server || return 1
    if [[ $kind == tcp || $kind == kcp ]]; then ask_mux n; else ask_mux y; fi
    local wl; wl=$(ip_cidr "$PEER_IP")
    local after=reverse_server; ((MUX)) && after=mux_server
    build_transport_server "$kind" "$after"
    NODES=("$(node users_inbound TcpListener "$(s_tcp_listen "$USER_PORT")" bridge_user_side)"
           "$(node bridge_user_side Bridge '{ "pair": "bridge_reverse_side" }')"
           "$(node bridge_reverse_side Bridge '{ "pair": "bridge_user_side" }')"
           "$(node reverse_server ReverseServer '{}' bridge_reverse_side)")
    ((MUX)) && NODES+=("$(node mux_server MuxServer '{}' reverse_server)")
    NODES+=("${TNODES[@]}")
    if is_udp_kind "$kind"; then NODES+=("$(node reverse_transport_inbound UdpListener "$(s_udp_listen "$TRANSPORT_PORT" "$wl")" "$THEAD")")
    else NODES+=("$(node reverse_transport_inbound TcpListener "$(s_tcp_listen "$TRANSPORT_PORT" "$wl")" "$THEAD")"); fi
    ask_speed_limit
    META+=("USER_PORT=$USER_PORT" "TRANSPORT_PORT=$TRANSPORT_PORT" "PEER=$PEER_IP")
  else
    ask PEER_IP "Client server IP or domain" "" is_host
    ask TRANSPORT_PORT "Client tunnel port" "$( is_udp_kind "$kind" && echo 4433 || echo 443)" is_port
    ask FINAL_IP "Final service address" "127.0.0.1" is_host
    ask FINAL_PORT "Final service port" "" is_port
    ask MIN_HELD "Pre-opened idle reverse connections" "8" is_num
    collect_transport_params "$kind" client || return 1
    if [[ $kind == tcp || $kind == kcp ]]; then ask_mux n; else ask_mux y; fi
    local conn_type=TcpConnector conn_set; conn_set=$(s_tcp_conn "$PEER_IP" "$TRANSPORT_PORT")
    if is_udp_kind "$kind"; then conn_type=UdpConnector; conn_set=$(s_udp_conn "$PEER_IP" "$TRANSPORT_PORT"); fi
    build_transport_client "$kind" to_client
    local rc_next=$THEAD; ((MUX)) && rc_next=mux_client
    NODES=("$(node outbound TcpConnector "$(s_tcp_conn "$FINAL_IP" "$FINAL_PORT")")"
           "$(node bridge_local_side Bridge '{ "pair": "bridge_reverse_client_side" }' outbound)"
           "$(node bridge_reverse_client_side Bridge '{ "pair": "bridge_local_side" }' reverse_client)"
           "$(node reverse_client ReverseClient "{ \"minimum-unused\": $MIN_HELD }" "$rc_next")")
    ((MUX)) && NODES+=("$(node mux_client MuxClient "$(s_mux_client "$MUX_N")" "$THEAD")")
    NODES+=("${TNODES[@]}" "$(node to_client "$conn_type" "$conn_set")")
    META+=("PEER=$PEER_IP:$TRANSPORT_PORT" "FINAL=$FINAL_IP:$FINAL_PORT")
  fi
}

# Raw-socket tunnels need both public IPs on both sides.
ask_both_ips() {
  local me; me=$(public_ip)
  if [[ $ROLE == client ]]; then
    ask IP_CLIENT "This (client) server public IPv4" "$me" is_ipv4
    ask IP_SERVER "Server public IPv4" "" is_ipv4
  else
    ask IP_SERVER "This (server) public IPv4" "$me" is_ipv4
    ask IP_CLIENT "Client server public IPv4" "" is_ipv4
  fi
  ask INNER_CLIENT "Inner IP (client side)" "10.90.0.1" is_ipv4
  ask INNER_SERVER "Inner IP (server side)" "10.90.0.2" is_ipv4
  ask TUN_MTU "Inner MTU" "1400" is_num
  ask TUN_PORT "Inner tunnel port" "5300" is_port
}

s_ipover() { # up_src up_dst down_src down_dst
  printf '{ "up": { "source-ip": { "ipv4": "%s" }, "dest-ip": { "ipv4": "%s" } }, "down": { "source-ip": { "ipv4": "%s" }, "dest-ip": { "ipv4": "%s" } } }' "$@"
}
s_raw() { # capture_ip proto [peer]
  local extra=""; [[ ${3:-} == peer ]] && extra=', "opaque-flow-mode": "peer"'
  printf '{ "capture-filter-mode": "source-ip", "capture-ips": [ "%s" ], "capture-protocols": [ %s ], "fragment-policy": "reassemble"%s }' "$1" "$2" "$extra"
}

gen_ping() {
  warn "RawSocket captures ALL ICMP from the peer IP; plain ping between the servers stops working."
  ask_both_ips
  if [[ $ROLE == client ]]; then
    ask USER_PORT "Port users connect to" "443" is_port
    NODES=("$(node users_inbound TcpListener "$(s_tcp_listen "$USER_PORT")" connection_to_packets)"
           "$(node connection_to_packets ConnectionToPackets "{ \"source-ipv4\": \"$INNER_CLIENT\", \"target-address\": \"$INNER_SERVER\", \"port\": $TUN_PORT, \"mtu\": $TUN_MTU }" ping_client)"
           "$(node ping_client PingClient '{ "send-replies": false }' carrier_addresses)"
           "$(node carrier_addresses IpOverrider "$(s_ipover "$IP_CLIENT" "$IP_SERVER" "$INNER_SERVER" "$INNER_CLIENT")" raw_transport)"
           "$(node raw_transport RawSocket "$(s_raw "$IP_SERVER" 1 peer)")")
    ask_speed_limit
    META+=("USER_PORT=$USER_PORT" "PEER=$IP_SERVER")
  else
    ask FINAL_IP "Final service address" "127.0.0.1" is_host
    ask FINAL_PORT "Final service port" "" is_port
    NODES=("$(node raw_transport RawSocket "$(s_raw "$IP_CLIENT" 1 peer)" carrier_addresses)"
           "$(node carrier_addresses IpOverrider "$(s_ipover "$INNER_CLIENT" "$INNER_SERVER" "$IP_SERVER" "$IP_CLIENT")" ping_server)"
           "$(node ping_server PingServer '{ "send-replies": false }' packets_to_connection)"
           "$(node packets_to_connection PacketsToConnection "{ \"mtu\": $TUN_MTU }" outbound)"
           "$(node outbound TcpConnector "$(s_tcp_conn "$FINAL_IP" "$FINAL_PORT")")")
    META+=("FINAL=$FINAL_IP:$FINAL_PORT" "PEER=$IP_CLIENT")
  fi
}

gen_faketcp() {
  warn "RawSocket captures ALL TCP from the peer IP — SSH between these two servers will break!"
  confirm "Continue?" n || return 1
  ask_both_ips
  ask FAKE_SRV_PORT "Fake TCP server port" "40000" is_port
  ask FAKE_CLI_FROM "Fake client port range start" "40001" is_port
  ask FAKE_CLI_TO   "Fake client port range end"   "40016" is_port
  (( 10#$FAKE_CLI_TO >= 10#$FAKE_CLI_FROM )) || { err "Range end must be >= start"; return 1; }
  local gp; gp=$(rand_pass 24); ask PASSWORD "Shared password (same on both sides)" "${PASSWORD:-$gp}" is_secret32
  local ft="{ \"server-port\": $FAKE_SRV_PORT, \"client-port-range\": [ $FAKE_CLI_FROM, $FAKE_CLI_TO ], \"password\": $(json_str "$PASSWORD"), \"options\": \"\" }"
  CORE_MTU=1400
  if [[ $ROLE == client ]]; then
    ask USER_PORT "Port users connect to" "443" is_port
    NODES=("$(node users_inbound TcpListener "$(s_tcp_listen "$USER_PORT")" connection_to_packets)"
           "$(node connection_to_packets ConnectionToPackets "{ \"source-ipv4\": \"$INNER_CLIENT\", \"target-address\": \"$INNER_SERVER\", \"port\": $TUN_PORT, \"mtu\": $TUN_MTU }" fake_tcp_client)"
           "$(node fake_tcp_client FakeTcpHeaderClient "$ft" carrier_addresses)"
           "$(node carrier_addresses IpOverrider "$(s_ipover "$IP_CLIENT" "$IP_SERVER" "$INNER_SERVER" "$INNER_CLIENT")" raw_transport)"
           "$(node raw_transport RawSocket "$(s_raw "$IP_SERVER" 6)")")
    ask_speed_limit
    META+=("USER_PORT=$USER_PORT" "PEER=$IP_SERVER")
  else
    ask FINAL_IP "Final service address" "127.0.0.1" is_host
    ask FINAL_PORT "Final service port" "" is_port
    NODES=("$(node raw_transport RawSocket "$(s_raw "$IP_CLIENT" 6)" carrier_addresses)"
           "$(node carrier_addresses IpOverrider "$(s_ipover "$INNER_CLIENT" "$INNER_SERVER" "$IP_SERVER" "$IP_CLIENT")" fake_tcp_server)"
           "$(node fake_tcp_server FakeTcpHeaderServer "$ft" packets_to_connection)"
           "$(node packets_to_connection PacketsToConnection "{ \"mtu\": $TUN_MTU }" outbound)"
           "$(node outbound TcpConnector "$(s_tcp_conn "$FINAL_IP" "$FINAL_PORT")")")
    META+=("FINAL=$FINAL_IP:$FINAL_PORT" "PEER=$IP_CLIENT")
  fi
}

# ----------------------------------------------------------------------------
# [MODULE] speed limit (works on any tunnel)
# ----------------------------------------------------------------------------
# speed_limit_set FILE LISTENER_NODE MBPS MODE
speed_limit_set() {
  local f=$1 l=$2 r=$3 m=$4 sn="speed_limit_$2"
  jq_inplace "$f" --arg l "$l" --arg sn "$sn" --argjson r "$r" --arg m "$m" '
    if any(.nodes[]; .name == $sn) then
      (.nodes[] | select(.name == $sn) | .settings) = {"mega-bytes-per-sec": $r, "limit-mode": $m, "work-mode": "pause"}
    else
      (first(.nodes[] | select(.name == $l) | .next)) as $old
      | .nodes |= (map(if .name == $l then .next = $sn else . end)
          + [{"name": $sn, "type": "SpeedLimit",
              "settings": {"mega-bytes-per-sec": $r, "limit-mode": $m, "work-mode": "pause"}, "next": $old}])
    end'
}
speed_limit_remove() { # FILE LISTENER_NODE
  local f=$1 sn="speed_limit_$2"
  jq_inplace "$f" --arg l "$2" --arg sn "$sn" '
    (first(.nodes[] | select(.name == $sn) | .next)) as $nx
    | if $nx == null then . else
      .nodes |= (map(select(.name != $sn)) | map(if .name == $l then .next = $nx else . end)) end'
}
listener_nodes() { # FILE -> names of listener nodes that have a next
  quote_placeholders "$1" | jq -r '.nodes[] | select(.type | test("Listener$")) | select(.next != null) | .name' 2>/dev/null
}

tunnel_speed_limit_menu() {
  local n=$1 f="$WW_TUNNELS/$1/config.json"
  local -a ls; mapfile -t ls < <(listener_nodes "$f")
  ((${#ls[@]})) || { warn "No listener node found in this config."; return; }
  local c l; choose c "Apply to which inbound (pick the one users connect to):" "${ls[@]}"; l=${ls[$((c-1))]}
  local cur; cur=$(jq -r --arg sn "speed_limit_$l" '.nodes[] | select(.name==$sn) | .settings["mega-bytes-per-sec"]' "$f" 2>/dev/null)
  [[ -n $cur ]] && info "Current limit on $l: $cur MB/s"
  local mb; ask mb "New limit in MB/s (0 = remove limit)" "${cur:-10}" is_uint
  if (( 10#$mb == 0 )); then speed_limit_remove "$f" "$l" && ok "Limit removed."
  else
    local m; choose m "Limit applies to:" "All users together (total)" "Each connection separately"
    speed_limit_set "$f" "$l" "$((10#$mb))" "$([[ $m == 1 ]] && echo all-lines || echo per-line)" && ok "Limit set: $mb MB/s"
  fi
  svc restart "$n"
}

# ----------------------------------------------------------------------------
# [MODULE] WireGuard VPN server
# ----------------------------------------------------------------------------
wg_genkey() { # DIR NAME -> writes NAME.key / NAME.pub (base64)
  local d=$1 n=$2 der; der=$(mktemp)
  if command -v wg >/dev/null; then
    wg genkey >"$d/$n.key"; wg pubkey <"$d/$n.key" >"$d/$n.pub"
  else
    openssl genpkey -algorithm X25519 -outform DER -out "$der" 2>/dev/null || { rm -f "$der"; err "openssl X25519 unsupported"; return 1; }
    tail -c 32 "$der" | base64 >"$d/$n.key"
    openssl pkey -inform DER -in "$der" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 >"$d/$n.pub"
  fi
  rm -f "$der"; chmod 600 "$d/$n.key"
}

wg_conf_get() { grep -m1 "^$2=" "$WW_TUNNELS/$1/wg/server.env" 2>/dev/null | cut -d= -f2-; }

wg_render() { # tunnel -> rewrites config.json from wg/ state
  local n=$1 d="$WW_TUNNELS/$1" peers="[]" p
  local port subnet tun
  port=$(wg_conf_get "$n" PORT); subnet=$(wg_conf_get "$n" SUBNET); tun=$(wg_conf_get "$n" TUN)
  for p in "$d"/wg/peers/*.pub; do
    [[ -f $p ]] || continue
    peers=$(jq -c --arg k "$(cat "$p")" --arg ip "$(cat "${p%.pub}.ip")/32" '. + [{"publickey": $k, "allowedips": $ip}]' <<<"$peers")
  done
  local base=${subnet%.*}
  jq -n --arg name "$n-wireguard" --argjson port "$port" --arg priv "$(cat "$d/wg/server.key")" \
     --argjson peers "$peers" --arg tun "$tun" --arg ip "$base.1/24" '
    {name: $name, author: "waterwall-manager", "config-version": 1, nodes: [
      {name: "wg_inbound", type: "UdpListener", settings: {address: "0.0.0.0", port: $port}, next: "wg_server"},
      {name: "wg_server", type: "WireGuardServer", settings: {mode: "packet", privatekey: $priv, peers: $peers}, next: "wg_tun"},
      {name: "wg_tun", type: "TunDevice", settings: {"device-name": $tun, "device-ip": $ip, "device-mtu": 1420}}
    ]}' >"$d/config.json"
  chmod 600 "$d/config.json"
}

wg_write_hooks() { # tunnel
  local n=$1 d="$WW_TUNNELS/$1" subnet tun wan
  subnet=$(wg_conf_get "$n" SUBNET); tun=$(wg_conf_get "$n" TUN); wan=$(wg_conf_get "$n" WAN)
  cat >"$d/post-up.sh" <<EOF
#!/bin/sh
# NAT + forwarding for WireGuard clients (written by waterwall-manager)
sysctl -qw net.ipv4.ip_forward=1
iptables -t nat -C POSTROUTING -s ${subnet} -o ${wan} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${subnet} -o ${wan} -j MASQUERADE
iptables -C FORWARD -i ${tun} -j ACCEPT 2>/dev/null || iptables -I FORWARD -i ${tun} -j ACCEPT
iptables -C FORWARD -o ${tun} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -I FORWARD -o ${tun} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -t mangle -C FORWARD -o ${tun} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o ${tun} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
iptables -t mangle -C FORWARD -i ${tun} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -i ${tun} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
exit 0
EOF
  cat >"$d/post-down.sh" <<EOF
#!/bin/sh
iptables -t nat -D POSTROUTING -s ${subnet} -o ${wan} -j MASQUERADE 2>/dev/null
iptables -D FORWARD -i ${tun} -j ACCEPT 2>/dev/null
iptables -D FORWARD -o ${tun} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
iptables -t mangle -D FORWARD -o ${tun} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
iptables -t mangle -D FORWARD -i ${tun} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
exit 0
EOF
  chmod 700 "$d/post-up.sh" "$d/post-down.sh"
}

wg_next_ip() { # tunnel -> next free host IP in the /24
  local n=$1 base used i
  base=$(wg_conf_get "$n" SUBNET); base=${base%.*}
  used=$(cat "$WW_TUNNELS/$n"/wg/peers/*.ip 2>/dev/null)
  for ((i=2; i<=254; i++)); do grep -qx "$base.$i" <<<"$used" || { echo "$base.$i"; return 0; }; done
  return 1
}

wg_client_conf() { # tunnel client
  local n=$1 c=$2 d="$WW_TUNNELS/$1/wg"
  cat <<EOF
[Interface]
PrivateKey = $(cat "$d/peers/$c.key")
Address = $(cat "$d/peers/$c.ip")/32
DNS = $(wg_conf_get "$n" DNS)
MTU = 1380

[Peer]
PublicKey = $(cat "$d/server.pub")
AllowedIPs = 0.0.0.0/0
Endpoint = $(wg_conf_get "$n" ENDPOINT):$(wg_conf_get "$n" PORT)
PersistentKeepalive = 25
EOF
}

wg_show_client() { # tunnel client
  local n=$1 c=$2 f="$WW_TUNNELS/$1/wg/peers/$2.conf"
  wg_client_conf "$n" "$c" >"$f"; chmod 600 "$f"
  line; printf '%sClient "%s"%s  (file: %s)\n' "$C_W" "$c" "$C_0" "$f"; cat "$f"; line
  if command -v qrencode >/dev/null; then qrencode -t ansiutf8 <"$f"
  else info "Install 'qrencode' to show a QR code for phone apps."; fi
}

wg_add_client() { # tunnel [name]
  local n=$1 c=${2:-} d="$WW_TUNNELS/$1/wg"
  local count; count=$(find "$d/peers" -name '*.pub' 2>/dev/null | wc -l)
  (( count < 32 )) || { err "WireGuardServer supports at most 32 peers."; return 1; }
  [[ -z $c ]] && ask c "Client name" "client$((count+1))" is_name
  [[ -e $d/peers/$c.pub ]] && { err "Client exists."; return 1; }
  local ip; ip=$(wg_next_ip "$n") || { err "Subnet full."; return 1; }
  mkdir -p "$d/peers"; wg_genkey "$d/peers" "$c" || return 1
  echo "$ip" >"$d/peers/$c.ip"
  wg_render "$n"; WG_LAST=$c; ok "Client $c added ($ip)."
}

wg_pick_client() { # tunnel VAR
  local -a arr; mapfile -t arr < <(find "$WW_TUNNELS/$1/wg/peers" -name '*.pub' -printf '%f\n' 2>/dev/null | sed 's/\.pub$//' | sort)
  ((${#arr[@]})) || { warn "No clients."; return 1; }
  local c; choose c "Select client:" "${arr[@]}"; printf -v "$2" '%s' "${arr[$((c-1))]}"
}

wg_remove_client() {
  local n=$1 c
  wg_pick_client "$n" c || return
  local count; count=$(find "$WW_TUNNELS/$n/wg/peers" -name '*.pub' | wc -l)
  (( count > 1 )) || { err "At least one client must remain."; return 1; }
  confirm "Remove client $c?" n || return
  rm -f "$WW_TUNNELS/$n/wg/peers/$c".*; wg_render "$n"; ok "Removed $c."; svc restart "$n"
}

gen_wireguard() { # uses $TNAME
  local d="$WW_TUNNELS/$TNAME"
  [[ -z $WW_ROOT && ! -c /dev/net/tun ]] && warn "/dev/net/tun not found — TUN support is required."
  local port subnet dns ep tun c1
  ask port "WireGuard UDP port" "51820" is_port
  ask subnet "Client subnet (/24)" "10.66.0.0" is_ipv4
  subnet="${subnet%.*}.0"
  ask dns "DNS for clients" "1.1.1.1" is_ip
  ask ep "Endpoint clients connect to (this server's IP or domain)" "$(public_ip)" is_host
  ask tun "TUN interface name" "wwwg$(( $(tunnel_count) ))" is_ifname
  if ip link show "$tun" >/dev/null 2>&1 || grep -rqs "^TUN=$tun\$" "$WW_TUNNELS"/*/wg/server.env; then
    warn "Interface $tun is already in use — pick another name."; ask tun "TUN interface name" "${tun}b" is_ifname
  fi
  ask c1 "First client name" "client1" is_name
  mkdir -p "$d/wg/peers" "$d/logs"
  printf 'PORT=%s\nSUBNET=%s/24\nDNS=%s\nENDPOINT=%s\nTUN=%s\nWAN=%s\n' \
    "$port" "$subnet" "$dns" "$ep" "$tun" "$(wan_iface || echo eth0)" >"$d/wg/server.env"
  wg_genkey "$d/wg" server || return 1
  wg_add_client "$TNAME" "$c1" >/dev/null || return 1
  wg_write_hooks "$TNAME"
  META+=("WG_PORT=$port" "WG_SUBNET=$subnet/24" "ENDPOINT=$ep")
  PREBUILT=1
}

# ----------------------------------------------------------------------------
# [MODULE] Authentication database + management API
# ----------------------------------------------------------------------------
API_OPERATIONS='["status","get-user","list-users","create-user","update-user","change-user-password"]'

gen_authapi() { # uses $TNAME
  local d="$WW_TUNNELS/$TNAME" addr port token secret
  ask addr "API listen address (127.0.0.1 recommended — API traffic is not encrypted)" "127.0.0.1" is_ip
  ask port "API port" "9080" is_port
  [[ $addr != 127.* ]] && warn "API exposed on $addr — protect it with a firewall or put TLS in front."
  token=$(rand_hex 32); secret=$(rand_hex 32)
  mkdir -p "$d/logs"
  [[ -f $d/users.json ]] || echo '{"users":[]}' >"$d/users.json"
  printf '%s\n' "$token" >"$d/api-token"; chmod 600 "$d/api-token" "$d/users.json"
  jq -n --arg cfg "$TNAME" --arg addr "$addr" --argjson port "$port" --arg tok "$token" --arg sec "$secret" \
     --argjson ops "$API_OPERATIONS" '
    {name: $cfg, author: "waterwall-manager", "config-version": 1, nodes: [
      {name: "auth-db", type: "AuthenticationServer",
       settings: {"db-path": "users.json", "file-save-rate-ms": 60000,
                  "auth-clients": [{name: "reserved-producer", secret: $sec}]}},
      {name: "api-listener", type: "TcpListener", settings: {address: $addr, port: $port}, next: "management-api"},
      {name: "management-api", type: "APIServer",
       settings: {clients: [{name: "admin", token: $tok, allow: [{config: $cfg, node: "auth-db", operations: $ops}]}]}}
    ]}' >"$d/config.json"
  META+=("API=$addr:$port" "API_CLIENT=admin" "API_TOKEN_FILE=$d/api-token")
  PREBUILT=1
}

# ----------------------------------------------------------------------------
# [MODULE] official template catalog (generated from the WaterWall docs)
#   WW_FAMILIES : family<TAB>title<TAB>note
#   WW_TEMPLATES: id<TAB>family<TAB>variant<TAB>role<TAB>core_mtu<TAB>json
#   WW_TPLVARS  : id<TAB>var<TAB>type<TAB>default_json<TAB>label
# ----------------------------------------------------------------------------
# --- generated from the official WaterWall-Docs examples (github.com/radkesvat/WaterWall-Docs) ---
WW_FAMILIES=$(cat <<'__WWFAM__'
tunnels/bitswap-mux	BitSwap + Mux (TCP flag swap, raw socket + TUN)	raw: Needs root, iproute2, iptables, kernel NFQUEUE + bpf match. RawSocket captures ALL TCP from the peer public IP (SSH between the two servers breaks). Use the SAME flag variant on both servers. Uses wtun1 (10.10.0.0/24) and, on the server side, also wtun2 (10.20.0.0/24).
tunnels/protoswap	ProtoSwap (IP protocol swap, raw socket + TUN)	raw: Needs root, iproute2, iptables, NFQUEUE + bpf. Protocol number is an IPv4 protocol (not a port); avoid 6 and 17. Captures all packets of that protocol from the peer. XOR is not encryption.
tunnels/direct-bgp4	Direct BGP4 (looks like BGP traffic)	
tunnels/reverse-bgp4	Reverse BGP4	
tunnels/direct-rtmp	Direct RTMP / RTMPS (looks like live streaming)	RTMPS needs a certificate on the server side; plain RTMP has no encryption.
tunnels/halfduplex-split-transports	HalfDuplex: upload over TLS, download over KCP	Upload and download use different transports. UUID and KCP settings must match on both sides.
tunnels/connection-stripe-tls	ConnectionStripe: parallel TLS connections	Both servers must use the same variant (with or without Mux).
tunnels/ping	ICMP Ping tunnel (bridges or TUN)	raw: Needs root, iptables, NFQUEUE + bpf. Allow ICMP echo requests both ways. Plain ping between the two servers stops working while active.
tunnels/fake-tcp-header	Fake TCP header (bridges or TUN/GRE)	raw: Needs root, iptables, NFQUEUE + bpf. Captures ALL TCP from the peer public IP (SSH between the servers breaks). Allow the fake ports between both IPs.
tunnels/direct-tls	Direct TLS (official)	
tunnels/direct-reality	Direct Reality (official)	
tunnels/direct-quic	Direct QUIC (official)	
tunnels/direct-kcp	Direct KCP (official)	
tunnels/reverse-tls	Reverse TLS (official)	
tunnels/reverse-reality	Reverse Reality (official)	
tunnels/reverse-quic	Reverse QUIC (official)	
tunnels/reverse-kcp	Reverse KCP (official)	
proxies/local-proxies	Local SOCKS5 / HTTP proxy server	No authentication: keep the listener on 127.0.0.1 or firewall it, otherwise it is an open proxy.
proxies/protocol-proxies	VLESS / VMess / Trojan over TLS	UUID/password must match on client and server. Server needs a TLS certificate.
proxies/websocket	VMess over WebSocket + TLS	
proxies/socks-mux	SOCKS5 + Router + VLESS + Mux + TLS	
proxies/kcp	SOCKS5 -> VLESS + Mux + TLS over KCP	
proxies/quic	SOCKS5 -> VLESS + Mux over QUIC	
proxies/rtmp	SOCKS5 -> VLESS over RTMPS	
proxies/socks5-rtmp-reality	SOCKS5 over RTMP + Reality	
__WWFAM__
)
WW_TEMPLATES=$(cat <<'__WWTPL__'
bitswap-mux.0	tunnels/bitswap-mux	PSH ↔ CWR	client	1400	{"name":"client-tcp-bitswap-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_port_to_listen__","nodelay":true},"next":"mux-client"},{"name":"mux-client","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":"__V_each_worker_mux_connections_count__"},"next":"tcp-out"},{"name":"tcp-out","type":"TcpConnector","settings":{"address":"10.10.0.2","port":"__V_server_carrier_port__","nodelay":true}},{"name":"my tun","type":"TunDevice","settings":{"device-name":"wtun1","device-ip":"10.10.0.1/24","device-mtu":1400},"next":"ipovsrc"},{"name":"ipovsrc","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_client_ip__"},"dest-ip":{"ipv4":"__V_server_ip__"}},"down":{"source-ip":{"ipv4":"10.10.0.2"},"dest-ip":{"ipv4":"10.10.0.1"}}},"next":"splitter"},{"name":"splitter","type":"PacketSplitStream","settings":{"up":"obfuscator-c","down":"obfuscator-s"}},{"name":"obfuscator-c","type":"ObfuscatorClient","settings":{"method":"xor","xor_key":90,"skip":"transport"},"next":"ip-manipulator-up"},{"name":"ip-manipulator-up","type":"IpManipulator","settings":{"up-tcp-bit-psh":"packet->cwr","up-tcp-bit-cwr":"packet->psh"},"next":"rd"},{"name":"rd","type":"RawSocket","settings":{}},{"name":"obfuscator-s","type":"ObfuscatorServer","settings":{"method":"xor","xor_key":90,"skip":"transport"},"next":"ip-manipulator"},{"name":"ip-manipulator","type":"IpManipulator","settings":{"dw-tcp-bit-psh":"packet->rst","dw-tcp-bit-rst":"packet->psh"},"next":"rd2"},{"name":"rd2","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ip":"__V_server_ip__","capture-protocols":[6]}}]}
bitswap-mux.1	tunnels/bitswap-mux	PSH ↔ CWR	server	1400	{"name":"server-tcp-bitswap-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_port_to_listen__","nodelay":true},"next":"mux-s"},{"name":"mux-s","type":"MuxServer","settings":{},"next":"tcp-out"},{"name":"tcp-out","type":"TcpConnector","settings":{"address":"__V_final_ip__","port":"__V_final_port__","nodelay":true}},{"name":"my tun2","type":"TunDevice","settings":{"device-name":"wtun2","device-ip":"10.20.0.1/24","device-mtu":1400},"next":"ipcorrect"},{"name":"ipcorrect","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"10.10.0.2"},"dest-ip":{"ipv4":"10.10.0.1"}},"down":{"source-ip":{"ipv4":"10.10.0.2"},"dest-ip":{"ipv4":"10.10.0.1"}}},"next":"obfuscator-s"},{"name":"obfuscator-s","type":"ObfuscatorServer","settings":{"method":"xor","xor_key":90,"skip":"transport"},"next":"ip-manipulator-in"},{"name":"ip-manipulator-in","type":"IpManipulator","settings":{"dw-tcp-bit-psh":"packet->cwr","dw-tcp-bit-cwr":"packet->psh"},"next":"rdin"},{"name":"rdin","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ip":"__V_client_ip__","capture-protocols":[6]}},{"name":"my tun","type":"TunDevice","settings":{"device-name":"wtun1","device-ip":"10.10.0.1/24","device-mtu":1400},"next":"ipovsrc"},{"name":"ipovsrc","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_server_ip__"},"dest-ip":{"ipv4":"__V_client_ip__"}},"down":{"source-ip":{"ipv4":"10.10.0.2"},"dest-ip":{"ipv4":"10.10.0.1"}}},"next":"obfuscator-c"},{"name":"obfuscator-c","type":"ObfuscatorClient","settings":{"method":"xor","xor_key":90,"skip":"transport"},"next":"ip-manipulator"},{"name":"ip-manipulator","type":"IpManipulator","settings":{"up-tcp-bit-psh":"packet->rst","up-tcp-bit-rst":"packet->psh"},"next":"rd"},{"name":"rd","type":"RawSocket","settings":{}}]}
bitswap-mux.2	tunnels/bitswap-mux	PSH ↔ RST	client	1400	{"name":"client-tcp-bitswap-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_port_to_listen__","nodelay":true},"next":"mux-client"},{"name":"mux-client","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":"__V_each_worker_mux_connections_count__"},"next":"tcp-out"},{"name":"tcp-out","type":"TcpConnector","settings":{"address":"10.10.0.2","port":"__V_server_carrier_port__","nodelay":true}},{"name":"my tun","type":"TunDevice","settings":{"device-name":"wtun1","device-ip":"10.10.0.1/24","device-mtu":1400},"next":"ipovsrc"},{"name":"ipovsrc","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_client_ip__"},"dest-ip":{"ipv4":"__V_server_ip__"}},"down":{"source-ip":{"ipv4":"10.10.0.2"},"dest-ip":{"ipv4":"10.10.0.1"}}},"next":"splitter"},{"name":"splitter","type":"PacketSplitStream","settings":{"up":"obfuscator-c","down":"obfuscator-s"}},{"name":"obfuscator-c","type":"ObfuscatorClient","settings":{"method":"xor","xor_key":90,"skip":"transport"},"next":"ip-manipulator-up"},{"name":"ip-manipulator-up","type":"IpManipulator","settings":{"up-tcp-bit-psh":"packet->rst","up-tcp-bit-rst":"packet->psh"},"next":"rd"},{"name":"rd","type":"RawSocket","settings":{}},{"name":"obfuscator-s","type":"ObfuscatorServer","settings":{"method":"xor","xor_key":90,"skip":"transport"},"next":"ip-manipulator"},{"name":"ip-manipulator","type":"IpManipulator","settings":{"dw-tcp-bit-psh":"packet->rst","dw-tcp-bit-rst":"packet->psh"},"next":"rd2"},{"name":"rd2","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ip":"__V_server_ip__","capture-protocols":[6]}}]}
bitswap-mux.3	tunnels/bitswap-mux	PSH ↔ RST	server	1400	{"name":"server-tcp-bitswap-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_port_to_listen__","nodelay":true},"next":"mux-s"},{"name":"mux-s","type":"MuxServer","settings":{},"next":"tcp-out"},{"name":"tcp-out","type":"TcpConnector","settings":{"address":"__V_final_ip__","port":"__V_final_port__","nodelay":true}},{"name":"my tun2","type":"TunDevice","settings":{"device-name":"wtun2","device-ip":"10.20.0.1/24","device-mtu":1400},"next":"ipcorrect"},{"name":"ipcorrect","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"10.10.0.2"},"dest-ip":{"ipv4":"10.10.0.1"}},"down":{"source-ip":{"ipv4":"10.10.0.2"},"dest-ip":{"ipv4":"10.10.0.1"}}},"next":"obfuscator-s"},{"name":"obfuscator-s","type":"ObfuscatorServer","settings":{"method":"xor","xor_key":90,"skip":"transport"},"next":"ip-manipulator-in"},{"name":"ip-manipulator-in","type":"IpManipulator","settings":{"dw-tcp-bit-psh":"packet->rst","dw-tcp-bit-rst":"packet->psh"},"next":"rdin"},{"name":"rdin","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ip":"__V_client_ip__","capture-protocols":[6]}},{"name":"my tun","type":"TunDevice","settings":{"device-name":"wtun1","device-ip":"10.10.0.1/24","device-mtu":1400},"next":"ipovsrc"},{"name":"ipovsrc","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_server_ip__"},"dest-ip":{"ipv4":"__V_client_ip__"}},"down":{"source-ip":{"ipv4":"10.10.0.2"},"dest-ip":{"ipv4":"10.10.0.1"}}},"next":"obfuscator-c"},{"name":"obfuscator-c","type":"ObfuscatorClient","settings":{"method":"xor","xor_key":90,"skip":"transport"},"next":"ip-manipulator"},{"name":"ip-manipulator","type":"IpManipulator","settings":{"up-tcp-bit-psh":"packet->rst","up-tcp-bit-rst":"packet->psh"},"next":"rd"},{"name":"rd","type":"RawSocket","settings":{}}]}
bitswap-mux.4	tunnels/bitswap-mux	PSH ↔ SYN	client	1400	{"name":"client-tcp-bitswap-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_port_to_listen__","nodelay":true},"next":"mux-client"},{"name":"mux-client","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":"__V_each_worker_mux_connections_count__"},"next":"tcp-out"},{"name":"tcp-out","type":"TcpConnector","settings":{"address":"10.10.0.2","port":"__V_server_carrier_port__","nodelay":true}},{"name":"my tun","type":"TunDevice","settings":{"device-name":"wtun1","device-ip":"10.10.0.1/24","device-mtu":1400},"next":"ipovsrc"},{"name":"ipovsrc","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_client_ip__"},"dest-ip":{"ipv4":"__V_server_ip__"}},"down":{"source-ip":{"ipv4":"10.10.0.2"},"dest-ip":{"ipv4":"10.10.0.1"}}},"next":"splitter"},{"name":"splitter","type":"PacketSplitStream","settings":{"up":"obfuscator-c","down":"obfuscator-s"}},{"name":"obfuscator-c","type":"ObfuscatorClient","settings":{"method":"xor","xor_key":90,"skip":"transport"},"next":"ip-manipulator-up"},{"name":"ip-manipulator-up","type":"IpManipulator","settings":{"up-tcp-bit-psh":"packet->syn","up-tcp-bit-syn":"packet->psh"},"next":"rd"},{"name":"rd","type":"RawSocket","settings":{}},{"name":"obfuscator-s","type":"ObfuscatorServer","settings":{"method":"xor","xor_key":90,"skip":"transport"},"next":"ip-manipulator"},{"name":"ip-manipulator","type":"IpManipulator","settings":{"dw-tcp-bit-psh":"packet->rst","dw-tcp-bit-rst":"packet->psh"},"next":"rd2"},{"name":"rd2","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ip":"__V_server_ip__","capture-protocols":[6]}}]}
bitswap-mux.5	tunnels/bitswap-mux	PSH ↔ SYN	server	1400	{"name":"server-tcp-bitswap-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_port_to_listen__","nodelay":true},"next":"mux-s"},{"name":"mux-s","type":"MuxServer","settings":{},"next":"tcp-out"},{"name":"tcp-out","type":"TcpConnector","settings":{"address":"__V_final_ip__","port":"__V_final_port__","nodelay":true}},{"name":"my tun2","type":"TunDevice","settings":{"device-name":"wtun2","device-ip":"10.20.0.1/24","device-mtu":1400},"next":"ipcorrect"},{"name":"ipcorrect","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"10.10.0.2"},"dest-ip":{"ipv4":"10.10.0.1"}},"down":{"source-ip":{"ipv4":"10.10.0.2"},"dest-ip":{"ipv4":"10.10.0.1"}}},"next":"obfuscator-s"},{"name":"obfuscator-s","type":"ObfuscatorServer","settings":{"method":"xor","xor_key":90,"skip":"transport"},"next":"ip-manipulator-in"},{"name":"ip-manipulator-in","type":"IpManipulator","settings":{"dw-tcp-bit-psh":"packet->syn","dw-tcp-bit-syn":"packet->psh"},"next":"rdin"},{"name":"rdin","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ip":"__V_client_ip__","capture-protocols":[6]}},{"name":"my tun","type":"TunDevice","settings":{"device-name":"wtun1","device-ip":"10.10.0.1/24","device-mtu":1400},"next":"ipovsrc"},{"name":"ipovsrc","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_server_ip__"},"dest-ip":{"ipv4":"__V_client_ip__"}},"down":{"source-ip":{"ipv4":"10.10.0.2"},"dest-ip":{"ipv4":"10.10.0.1"}}},"next":"obfuscator-c"},{"name":"obfuscator-c","type":"ObfuscatorClient","settings":{"method":"xor","xor_key":90,"skip":"transport"},"next":"ip-manipulator"},{"name":"ip-manipulator","type":"IpManipulator","settings":{"up-tcp-bit-psh":"packet->rst","up-tcp-bit-rst":"packet->psh"},"next":"rd"},{"name":"rd","type":"RawSocket","settings":{}}]}
protoswap.0	tunnels/protoswap	-	client	1400	{"name":"client-tcp-protoswap","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_client_listen_port__","nodelay":true},"next":"tcp-out"},{"name":"tcp-out","type":"TcpConnector","settings":{"address":"10.10.0.2","port":"__V_server_service_port__","nodelay":true}},{"name":"my tun","type":"TunDevice","settings":{"device-name":"wtun1","device-ip":"10.10.0.1/24","device-mtu":1400},"next":"ipovsrc"},{"name":"ipovsrc","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_client_ip__"},"dest-ip":{"ipv4":"__V_server_ip__"}},"down":{"source-ip":{"ipv4":"10.10.0.2"},"dest-ip":{"ipv4":"10.10.0.1"}}},"next":"ip-manipulator"},{"name":"ip-manipulator","type":"IpManipulator","settings":{"protoswap-tcp":"__V_protoswap_tcp_to_number__"},"next":"obfuscator-c"},{"name":"obfuscator-c","type":"ObfuscatorClient","settings":{"method":"xor","xor_key":90,"skip":"transport"},"next":"rd"},{"name":"rd","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ip":"__V_server_ip__","capture-protocols":["__V_protoswap_tcp_to_number__"]}}]}
protoswap.1	tunnels/protoswap	-	server	1400	{"name":"server-tcp-protoswap","nodes":[{"name":"my tun2","type":"TunDevice","settings":{"device-name":"wtun1","device-ip":"10.10.0.1/24","device-mtu":1400},"next":"ipcorrect"},{"name":"ipcorrect","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_server_ip__"},"dest-ip":{"ipv4":"__V_client_ip__"}},"down":{"source-ip":{"ipv4":"10.10.0.2"},"dest-ip":{"ipv4":"10.10.0.1"}}},"next":"ip-manipulator"},{"name":"ip-manipulator","type":"IpManipulator","settings":{"protoswap-tcp":"__V_protoswap_tcp_to_number__"},"next":"obfuscator-s"},{"name":"obfuscator-s","type":"ObfuscatorServer","settings":{"method":"xor","xor_key":90,"skip":"transport"},"next":"rdin"},{"name":"rdin","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ip":"__V_client_ip__","capture-protocols":["__V_protoswap_tcp_to_number__"]}}]}
direct-bgp4.0	tunnels/direct-bgp4	Without Mux	client	1500	{"name":"client-direct-bgp4","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"bgp4_client"},{"name":"bgp4_client","type":"Bgp4Client","settings":{},"next":"tcp_to_server"},{"name":"tcp_to_server","type":"TcpConnector","settings":{"address":"__V_server_ip__","port":"__V_transport_port__","nodelay":true}}]}
direct-bgp4.1	tunnels/direct-bgp4	Without Mux	server	1500	{"name":"server-direct-bgp4","nodes":[{"name":"transport_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__","nodelay":true},"next":"bgp4_server"},{"name":"bgp4_server","type":"Bgp4Server","settings":{},"next":"outbound_to_local_service"},{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}}]}
direct-bgp4.2	tunnels/direct-bgp4	With Mux (recommended)	client	1500	{"name":"client-direct-bgp4-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"mux_client"},{"name":"mux_client","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":"__V_mux_connections_per_worker__"},"next":"bgp4_client"},{"name":"bgp4_client","type":"Bgp4Client","settings":{},"next":"tcp_to_server"},{"name":"tcp_to_server","type":"TcpConnector","settings":{"address":"__V_server_ip__","port":"__V_transport_port__","nodelay":true}}]}
direct-bgp4.3	tunnels/direct-bgp4	With Mux (recommended)	server	1500	{"name":"server-direct-bgp4-mux","nodes":[{"name":"transport_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__","nodelay":true},"next":"bgp4_server"},{"name":"bgp4_server","type":"Bgp4Server","settings":{},"next":"mux_server"},{"name":"mux_server","type":"MuxServer","settings":{},"next":"outbound_to_local_service"},{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}}]}
reverse-bgp4.0	tunnels/reverse-bgp4	Without Mux	client	1500	{"name":"client-reverse-bgp4","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"bridge_user_side"},{"name":"bridge_user_side","type":"Bridge","settings":{"pair":"bridge_reverse_side"}},{"name":"bridge_reverse_side","type":"Bridge","settings":{"pair":"bridge_user_side"}},{"name":"reverse_server","type":"ReverseServer","settings":{},"next":"bridge_reverse_side"},{"name":"bgp4_server","type":"Bgp4Server","settings":{},"next":"reverse_server"},{"name":"reverse_transport_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__","nodelay":true,"whitelist":["__V_server_ip__"]},"next":"bgp4_server"}]}
reverse-bgp4.1	tunnels/reverse-bgp4	Without Mux	server	1500	{"name":"server-reverse-bgp4","nodes":[{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}},{"name":"bridge_local_side","type":"Bridge","settings":{"pair":"bridge_reverse_client_side"},"next":"outbound_to_local_service"},{"name":"bridge_reverse_client_side","type":"Bridge","settings":{"pair":"bridge_local_side"},"next":"reverse_client"},{"name":"reverse_client","type":"ReverseClient","settings":{"minimum-unused":"__V_min_held_connections__"},"next":"bgp4_client"},{"name":"bgp4_client","type":"Bgp4Client","settings":{},"next":"tcp_to_client"},{"name":"tcp_to_client","type":"TcpConnector","settings":{"address":"__V_client_ip__","port":"__V_transport_port__","nodelay":true}}]}
reverse-bgp4.2	tunnels/reverse-bgp4	With Mux (recommended)	client	1500	{"name":"client-reverse-bgp4-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"bridge_user_side"},{"name":"bridge_user_side","type":"Bridge","settings":{"pair":"bridge_reverse_side"}},{"name":"bridge_reverse_side","type":"Bridge","settings":{"pair":"bridge_user_side"}},{"name":"reverse_server","type":"ReverseServer","settings":{},"next":"bridge_reverse_side"},{"name":"bgp4_server","type":"Bgp4Server","settings":{},"next":"mux_server"},{"name":"reverse_transport_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__","nodelay":true,"whitelist":["__V_server_ip__"]},"next":"bgp4_server"},{"name":"mux_server","type":"MuxServer","settings":{},"next":"reverse_server"}]}
reverse-bgp4.3	tunnels/reverse-bgp4	With Mux (recommended)	server	1500	{"name":"server-reverse-bgp4-mux","nodes":[{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}},{"name":"bridge_local_side","type":"Bridge","settings":{"pair":"bridge_reverse_client_side"},"next":"outbound_to_local_service"},{"name":"bridge_reverse_client_side","type":"Bridge","settings":{"pair":"bridge_local_side"},"next":"reverse_client"},{"name":"reverse_client","type":"ReverseClient","settings":{"minimum-unused":"__V_min_held_connections__"},"next":"mux_client"},{"name":"bgp4_client","type":"Bgp4Client","settings":{},"next":"tcp_to_client"},{"name":"tcp_to_client","type":"TcpConnector","settings":{"address":"__V_client_ip__","port":"__V_transport_port__","nodelay":true}},{"name":"mux_client","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":"__V_mux_connections_per_worker__"},"next":"bgp4_client"}]}
direct-rtmp.0	tunnels/direct-rtmp	RTMPS (verified TLS)	client	1500	{"name":"client-direct-rtmps","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__"},"next":"rtmp_client"},{"name":"rtmp_client","type":"RtmpClient","settings":{"tc-url":"__V_tc_url__","app":"waterwall","stream":"tunnel"},"next":"tls_client"},{"name":"tls_client","type":"TlsClient","settings":{"sni":"__V_tls_name__","verify":true,"alpns":[]},"next":"tcp_to_server"},{"name":"tcp_to_server","type":"TcpConnector","settings":{"address":"__V_server_ip__","port":"__V_transport_port__"}}]}
direct-rtmp.1	tunnels/direct-rtmp	RTMPS (verified TLS)	server	1500	{"name":"server-direct-rtmps","nodes":[{"name":"transport_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__"},"next":"tls_server"},{"name":"tls_server","type":"TlsServer","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__","select-alpns":[]},"next":"rtmp_server"},{"name":"rtmp_server","type":"RtmpServer","settings":{"app":"waterwall","stream":"tunnel"},"next":"service"},{"name":"service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__"}}]}
direct-rtmp.2	tunnels/direct-rtmp	Plain RTMP	client	1500	{"name":"client-direct-rtmp","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__"},"next":"rtmp_client"},{"name":"rtmp_client","type":"RtmpClient","settings":{"tc-url":"__V_tc_url__","app":"waterwall","stream":"tunnel"},"next":"tcp_to_server"},{"name":"tcp_to_server","type":"TcpConnector","settings":{"address":"__V_server_ip__","port":"__V_transport_port__"}}]}
direct-rtmp.3	tunnels/direct-rtmp	Plain RTMP	server	1500	{"name":"server-direct-rtmp","nodes":[{"name":"transport_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__"},"next":"rtmp_server"},{"name":"rtmp_server","type":"RtmpServer","settings":{"app":"waterwall","stream":"tunnel"},"next":"service"},{"name":"service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__"}}]}
halfduplex-split-transports.0	tunnels/halfduplex-split-transports	-	client	1500	{"name":"halfduplex-tls-kcp-client","nodes":[{"name":"application","type":"TcpListener","next":"vless-client","settings":{"address":"__V_application.address__","port":"__V_application.port__","nodelay":true}},{"name":"vless-client","type":"VlessClient","next":"split","settings":{"uuid":"__V_shared.uuid__","address":"__V_vless-client.address__","port":"__V_vless-client.port__","protocol":"tcp"}},{"name":"split","type":"HalfDuplexClient","settings":{"upload":"tls-client","download":"udp-client"}},{"name":"tls-client","type":"TlsClient","next":"tcp-out","settings":{"sni":"__V_shared.domain__","verify":false,"alpns":["http/1.1"]}},{"name":"tcp-out","type":"TcpConnector","settings":{"address":"__V_tcp-out.address__","port":"__V_tcp-out.port__","nodelay":true,"fastopen":false}},{"name":"udp-client","type":"KcpClient","next":"udp-out","settings":{"send-mtu":1400,"fec":false,"kcp-no-congestion-control":false}},{"name":"udp-out","type":"UdpConnector","settings":{"address":"__V_udp-out.address__","port":"__V_udp-out.port__","balance-mode":"packet"}}]}
halfduplex-split-transports.1	tunnels/halfduplex-split-transports	-	server	1500	{"name":"halfduplex-tls-kcp-server","nodes":[{"name":"udp-in","type":"UdpListener","next":"udp-server","settings":{"address":"__V_udp-in.address__","port":"__V_udp-in.port__"}},{"name":"udp-server","type":"KcpServer","next":"hs2","settings":{"send-mtu":1400,"fec":false,"kcp-no-congestion-control":false}},{"name":"hs2","type":"HalfDuplexServer","settings":{"pair":"hs1"}},{"name":"tcp-in","type":"TcpListener","next":"tls-server","settings":{"address":"__V_tcp-in.address__","port":"__V_tcp-in.port__","nodelay":true}},{"name":"tls-server","type":"TlsServer","next":"hs1","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__","sni":"__V_shared.domain__"}},{"name":"hs1","type":"HalfDuplexServer","next":"vless-server"},{"name":"vless-server","type":"VlessServer","next":"backend","settings":{"uuid":"__V_shared.uuid__","connect":true,"udp":true}},{"name":"backend","type":"TcpUdpConnector","settings":{"address":"dest_context->address","port":"dest_context->port","nodelay":true,"fastopen":false}}]}
connection-stripe-tls.0	tunnels/connection-stripe-tls	With Mux	client	1500	{"name":"connection-stripe-tls-mux-client","nodes":[{"name":"application","type":"TcpListener","next":"mux-client","settings":{"address":"__V_application.address__","port":"__V_application.port__","nodelay":true}},{"name":"mux-client","type":"MuxClient","next":"stripe-client","settings":{"mode":"fixed-connections-count","per-worker-connections-count":1}},{"name":"stripe-client","type":"ConnectionStripeClient","next":"tls-client","settings":{"connections":"__V_stripe_connections__"}},{"name":"tls-client","type":"TlsClient","next":"transport","settings":{"sni":"__V_shared.domain__","verify":false,"alpns":["http/1.1"]}},{"name":"transport","type":"TcpConnector","settings":{"address":"__V_transport.address__","port":"__V_transport.port__","nodelay":true,"fastopen":false}}]}
connection-stripe-tls.1	tunnels/connection-stripe-tls	Without Mux	client	1500	{"name":"connection-stripe-tls-client","nodes":[{"name":"application","type":"TcpListener","next":"stripe-client","settings":{"address":"__V_application.address__","port":"__V_application.port__","nodelay":true}},{"name":"stripe-client","type":"ConnectionStripeClient","next":"tls-client","settings":{"connections":"__V_stripe_connections__"}},{"name":"tls-client","type":"TlsClient","next":"transport","settings":{"sni":"__V_shared.domain__","verify":false,"alpns":["http/1.1"]}},{"name":"transport","type":"TcpConnector","settings":{"address":"__V_transport.address__","port":"__V_transport.port__","nodelay":true,"fastopen":false}}]}
connection-stripe-tls.2	tunnels/connection-stripe-tls	With Mux	server	1500	{"name":"connection-stripe-tls-mux-server","nodes":[{"name":"transport","type":"TcpListener","next":"tls-server","settings":{"address":"__V_transport.address__","port":"__V_transport.port__","nodelay":true}},{"name":"tls-server","type":"TlsServer","next":"stripe-server","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__","sni":"__V_shared.domain__"}},{"name":"stripe-server","type":"ConnectionStripeServer","next":"mux-server","settings":{"max-connections":32}},{"name":"mux-server","type":"MuxServer","next":"destination","settings":{}},{"name":"destination","type":"TcpConnector","settings":{"address":"__V_destination.address__","port":"__V_destination.port__","nodelay":true,"fastopen":false}}]}
connection-stripe-tls.3	tunnels/connection-stripe-tls	Without Mux	server	1500	{"name":"connection-stripe-tls-server","nodes":[{"name":"transport","type":"TcpListener","next":"tls-server","settings":{"address":"__V_transport.address__","port":"__V_transport.port__","nodelay":true}},{"name":"tls-server","type":"TlsServer","next":"stripe-server","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__","sni":"__V_shared.domain__"}},{"name":"stripe-server","type":"ConnectionStripeServer","next":"destination","settings":{"max-connections":32}},{"name":"destination","type":"TcpConnector","settings":{"address":"__V_destination.address__","port":"__V_destination.port__","nodelay":true,"fastopen":false}}]}
ping.0	tunnels/ping	Connection bridges (no TUN)	client	1500	{"name":"client-ping-bridges","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"connection_to_packets"},{"name":"connection_to_packets","type":"ConnectionToPackets","settings":{"source-ipv4":"__V_inner_ip_client__","target-address":"__V_inner_ip_server__","port":"__V_tunnel_port__","mtu":"__V_tunnel_mtu__"},"next":"ping_client"},{"name":"ping_client","type":"PingClient","settings":{"send-replies":false},"next":"carrier_addresses"},{"name":"carrier_addresses","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_client_ip__"},"dest-ip":{"ipv4":"__V_server_ip__"}},"down":{"source-ip":{"ipv4":"__V_inner_ip_server__"},"dest-ip":{"ipv4":"__V_inner_ip_client__"}}},"next":"raw_transport"},{"name":"raw_transport","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ips":["__V_server_ip__"],"capture-protocols":[1],"fragment-policy":"reassemble","opaque-flow-mode":"peer"}}]}
ping.1	tunnels/ping	Connection bridges (no TUN)	server	1500	{"name":"server-ping-bridges","nodes":[{"name":"raw_transport","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ips":["__V_client_ip__"],"capture-protocols":[1],"fragment-policy":"reassemble","opaque-flow-mode":"peer"},"next":"carrier_addresses"},{"name":"carrier_addresses","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_inner_ip_client__"},"dest-ip":{"ipv4":"__V_inner_ip_server__"}},"down":{"source-ip":{"ipv4":"__V_server_ip__"},"dest-ip":{"ipv4":"__V_client_ip__"}}},"next":"ping_server"},{"name":"ping_server","type":"PingServer","settings":{"send-replies":false},"next":"packets_to_connection"},{"name":"packets_to_connection","type":"PacketsToConnection","settings":{"mtu":"__V_tunnel_mtu__"},"next":"outbound_to_service"},{"name":"outbound_to_service","type":"TcpConnector","settings":{"address":"__V_final_ip__","port":"__V_final_port__","nodelay":true}}]}
ping.2	tunnels/ping	TunDevice	client	1500	{"name":"client-ping-tun","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"tcp_to_server"},{"name":"tcp_to_server","type":"TcpConnector","settings":{"address":"__V_inner_ip_server__","port":"__V_tunnel_port__","nodelay":true}},{"name":"inner_tun","type":"TunDevice","settings":{"device-name":"__V_tun_name__","device-ip":"__V_tun_cidr__","device-mtu":"__V_tunnel_mtu__","route-table":"off","gso":false,"fragment-policy":"reassemble"},"next":"ping_client"},{"name":"ping_client","type":"PingClient","settings":{"send-replies":false},"next":"carrier_addresses"},{"name":"carrier_addresses","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_client_ip__"},"dest-ip":{"ipv4":"__V_server_ip__"}},"down":{"source-ip":{"ipv4":"__V_inner_ip_server__"},"dest-ip":{"ipv4":"__V_inner_ip_client__"}}},"next":"raw_transport"},{"name":"raw_transport","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ips":["__V_server_ip__"],"capture-protocols":[1],"fragment-policy":"reassemble","opaque-flow-mode":"peer"}}]}
ping.3	tunnels/ping	TunDevice	server	1500	{"name":"server-ping-tun","nodes":[{"name":"raw_transport","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ips":["__V_client_ip__"],"capture-protocols":[1],"fragment-policy":"reassemble","opaque-flow-mode":"peer"},"next":"carrier_addresses"},{"name":"carrier_addresses","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_inner_ip_client__"},"dest-ip":{"ipv4":"__V_inner_ip_server__"}},"down":{"source-ip":{"ipv4":"__V_server_ip__"},"dest-ip":{"ipv4":"__V_client_ip__"}}},"next":"ping_server"},{"name":"ping_server","type":"PingServer","settings":{"send-replies":false},"next":"inner_tun"},{"name":"inner_tun","type":"TunDevice","settings":{"device-name":"__V_tun_name__","device-ip":"__V_tun_cidr__","device-mtu":"__V_tunnel_mtu__","route-table":"off","gso":false,"fragment-policy":"reassemble"}},{"name":"tunnel_inbound","type":"TcpListener","settings":{"address":"__V_inner_ip_server__","port":"__V_tunnel_port__","nodelay":true},"next":"outbound_to_service"},{"name":"outbound_to_service","type":"TcpConnector","settings":{"address":"__V_final_ip__","port":"__V_final_port__","nodelay":true}}]}
fake-tcp-header.0	tunnels/fake-tcp-header	TCP service (packet bridges)	client	1400	{"name":"client-fake-tcp-bridges","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"connection_to_packets"},{"name":"connection_to_packets","type":"ConnectionToPackets","settings":{"source-ipv4":"__V_inner_ip_client__","target-address":"__V_inner_ip_server__","port":"__V_tunnel_port__","mtu":"__V_native_mtu__"},"next":"fake_tcp_client"},{"name":"fake_tcp_client","type":"FakeTcpHeaderClient","settings":{"server-port":"__V_fake_server_port__","client-port-range":"__V_fake_client_ports__","password":"__V_password__","options":""},"next":"carrier_addresses"},{"name":"carrier_addresses","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_client_ip__"},"dest-ip":{"ipv4":"__V_server_ip__"}},"down":{"source-ip":{"ipv4":"__V_inner_ip_server__"},"dest-ip":{"ipv4":"__V_inner_ip_client__"}}},"next":"raw_transport"},{"name":"raw_transport","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ips":["__V_server_ip__"],"capture-protocols":[6],"fragment-policy":"reassemble"}}]}
fake-tcp-header.1	tunnels/fake-tcp-header	TCP service (packet bridges)	server	1400	{"name":"server-fake-tcp-bridges","nodes":[{"name":"raw_transport","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ips":["__V_client_ip__"],"capture-protocols":[6],"fragment-policy":"reassemble"},"next":"carrier_addresses"},{"name":"carrier_addresses","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_inner_ip_client__"},"dest-ip":{"ipv4":"__V_inner_ip_server__"}},"down":{"source-ip":{"ipv4":"__V_server_ip__"},"dest-ip":{"ipv4":"__V_client_ip__"}}},"next":"fake_tcp_server"},{"name":"fake_tcp_server","type":"FakeTcpHeaderServer","settings":{"server-port":"__V_fake_server_port__","client-port-range":"__V_fake_client_ports__","password":"__V_password__","options":""},"next":"packets_to_connection"},{"name":"packets_to_connection","type":"PacketsToConnection","settings":{"mtu":"__V_native_mtu__"},"next":"outbound_to_service"},{"name":"outbound_to_service","type":"TcpConnector","settings":{"address":"__V_final_ip__","port":"__V_final_port__","nodelay":true}}]}
fake-tcp-header.2	tunnels/fake-tcp-header	UDP and GRE (TunDevice)	client	1400	{"name":"client-fake-tcp-tun","nodes":[{"name":"users_inbound","type":"UdpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__"},"next":"udp_to_server"},{"name":"udp_to_server","type":"UdpConnector","settings":{"address":"__V_inner_ip_server__","port":"__V_tunnel_port__"}},{"name":"inner_tun","type":"TunDevice","settings":{"device-name":"__V_tun_name__","device-ip":"__V_tun_cidr__","device-mtu":"__V_native_mtu__","route-table":"off","gso":false,"fragment-policy":"reassemble"},"next":"fake_tcp_client"},{"name":"fake_tcp_client","type":"FakeTcpHeaderClient","settings":{"server-port":"__V_fake_server_port__","client-port-range":"__V_fake_client_ports__","password":"__V_password__","options":""},"next":"carrier_addresses"},{"name":"carrier_addresses","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_client_ip__"},"dest-ip":{"ipv4":"__V_server_ip__"}},"down":{"source-ip":{"ipv4":"__V_inner_ip_server__"},"dest-ip":{"ipv4":"__V_inner_ip_client__"}}},"next":"raw_transport"},{"name":"raw_transport","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ips":["__V_server_ip__"],"capture-protocols":[6],"fragment-policy":"reassemble"}}]}
fake-tcp-header.3	tunnels/fake-tcp-header	UDP and GRE (TunDevice)	server	1400	{"name":"server-fake-tcp-tun","nodes":[{"name":"raw_transport","type":"RawSocket","settings":{"capture-filter-mode":"source-ip","capture-ips":["__V_client_ip__"],"capture-protocols":[6],"fragment-policy":"reassemble"},"next":"carrier_addresses"},{"name":"carrier_addresses","type":"IpOverrider","settings":{"up":{"source-ip":{"ipv4":"__V_inner_ip_client__"},"dest-ip":{"ipv4":"__V_inner_ip_server__"}},"down":{"source-ip":{"ipv4":"__V_server_ip__"},"dest-ip":{"ipv4":"__V_client_ip__"}}},"next":"fake_tcp_server"},{"name":"fake_tcp_server","type":"FakeTcpHeaderServer","settings":{"server-port":"__V_fake_server_port__","client-port-range":"__V_fake_client_ports__","password":"__V_password__","options":""},"next":"inner_tun"},{"name":"inner_tun","type":"TunDevice","settings":{"device-name":"__V_tun_name__","device-ip":"__V_tun_cidr__","device-mtu":"__V_native_mtu__","route-table":"off","gso":false,"fragment-policy":"reassemble"}},{"name":"tunnel_inbound","type":"UdpListener","settings":{"address":"__V_inner_ip_server__","port":"__V_tunnel_port__"},"next":"outbound_to_service"},{"name":"outbound_to_service","type":"UdpConnector","settings":{"address":"__V_final_ip__","port":"__V_final_port__"}}]}
direct-tls.0	tunnels/direct-tls	Without Mux	client	1500	{"name":"client-direct-tls","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"tls_client"},{"name":"tls_client","type":"TlsClient","settings":{"sni":"__V_domain_to_handshake_tls__","verify":true},"next":"tcp_to_server"},{"name":"tcp_to_server","type":"TcpConnector","settings":{"address":"__V_server_ip__","port":"__V_transport_port__","nodelay":true}}]}
direct-tls.1	tunnels/direct-tls	Without Mux	server	1500	{"name":"server-direct-tls","nodes":[{"name":"transport_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__","nodelay":true},"next":"tls_server"},{"name":"tls_server","type":"TlsServer","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__","min-version":"TLSv1.2","max-version":"TLSv1.3","ciphers":"HIGH:!aNULL:!MD5","session-cache":"none","session-tickets":true,"verbose":false},"next":"outbound_to_local_service"},{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}}]}
direct-tls.2	tunnels/direct-tls	With Mux (recommended)	client	1500	{"name":"client-direct-tls-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"mux_client"},{"name":"mux_client","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":"__V_mux_connections_per_worker__"},"next":"tls_client"},{"name":"tls_client","type":"TlsClient","settings":{"sni":"__V_domain_to_handshake_tls__","verify":true},"next":"tcp_to_server"},{"name":"tcp_to_server","type":"TcpConnector","settings":{"address":"__V_server_ip__","port":"__V_transport_port__","nodelay":true}}]}
direct-tls.3	tunnels/direct-tls	With Mux (recommended)	server	1500	{"name":"server-direct-tls-mux","nodes":[{"name":"transport_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__","nodelay":true},"next":"tls_server"},{"name":"tls_server","type":"TlsServer","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__","min-version":"TLSv1.2","max-version":"TLSv1.3","ciphers":"HIGH:!aNULL:!MD5","session-cache":"none","session-tickets":true,"verbose":false},"next":"mux_server"},{"name":"mux_server","type":"MuxServer","settings":{},"next":"outbound_to_local_service"},{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}}]}
direct-reality.0	tunnels/direct-reality	Without Mux	client	1500	{"name":"client-direct-reality","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"reality-client"},{"name":"reality-client","type":"RealityClient","settings":{"sni":"__V_visitor_domain__","verify":true,"password":"__V_password__","algorithm":"chacha20-poly1305","kdf-iterations":12000},"next":"tcp_to_server"},{"name":"tcp_to_server","type":"TcpConnector","settings":{"address":"__V_server_ip__","port":"__V_transport_port__","nodelay":true}}]}
direct-reality.1	tunnels/direct-reality	Without Mux	server	1500	{"name":"server-direct-reality","nodes":[{"name":"transport_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__","nodelay":true},"next":"reality-server"},{"name":"reality-server","type":"RealityServer","settings":{"destination":"dest-visitor","password":"__V_password__","algorithm":"chacha20-poly1305","kdf-iterations":12000,"sniffing-attempts":8},"next":"outbound_to_local_service"},{"name":"dest-visitor","type":"TcpConnector","settings":{"address":"__V_visitor_ip__","port":443,"nodelay":true}},{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}}]}
direct-reality.2	tunnels/direct-reality	With Mux (recommended)	client	1500	{"name":"client-direct-reality-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"mux_client"},{"name":"mux_client","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":"__V_mux_connections_per_worker__"},"next":"reality-client"},{"name":"reality-client","type":"RealityClient","settings":{"sni":"__V_visitor_domain__","verify":true,"password":"__V_password__","algorithm":"chacha20-poly1305","kdf-iterations":12000},"next":"tcp_to_server"},{"name":"tcp_to_server","type":"TcpConnector","settings":{"address":"__V_server_ip__","port":"__V_transport_port__","nodelay":true}}]}
direct-reality.3	tunnels/direct-reality	With Mux (recommended)	server	1500	{"name":"server-direct-reality-mux","nodes":[{"name":"transport_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__","nodelay":true},"next":"reality-server"},{"name":"reality-server","type":"RealityServer","settings":{"destination":"dest-visitor","password":"__V_password__","algorithm":"chacha20-poly1305","kdf-iterations":12000,"sniffing-attempts":8},"next":"mux_server"},{"name":"dest-visitor","type":"TcpConnector","settings":{"address":"__V_visitor_ip__","port":443,"nodelay":true}},{"name":"mux_server","type":"MuxServer","settings":{},"next":"outbound_to_local_service"},{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}}]}
direct-quic.0	tunnels/direct-quic	Without Mux	client	1500	{"name":"client-direct-quic","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"quic_client"},{"name":"quic_client","type":"QuicClient","settings":{"sni":"__V_domain_to_handshake_quic__","verify":true,"protocol":"h3","max-packet-size":1350},"next":"udp_to_server"},{"name":"udp_to_server","type":"UdpConnector","settings":{"address":"__V_server_ip__","port":"__V_transport_port__"}}]}
direct-quic.1	tunnels/direct-quic	Without Mux	server	1500	{"name":"server-direct-quic","nodes":[{"name":"transport_inbound","type":"UdpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__"},"next":"quic_server"},{"name":"quic_server","type":"QuicServer","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__","protocol":"h3","max-packet-size":1350},"next":"outbound_to_local_service"},{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}}]}
direct-quic.2	tunnels/direct-quic	With Mux (recommended)	client	1500	{"name":"client-direct-quic-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"mux_client"},{"name":"mux_client","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":"__V_mux_connections_per_worker__"},"next":"quic_client"},{"name":"quic_client","type":"QuicClient","settings":{"sni":"__V_domain_to_handshake_quic__","verify":true,"protocol":"h3","max-packet-size":1350},"next":"udp_to_server"},{"name":"udp_to_server","type":"UdpConnector","settings":{"address":"__V_server_ip__","port":"__V_transport_port__"}}]}
direct-quic.3	tunnels/direct-quic	With Mux (recommended)	server	1500	{"name":"server-direct-quic-mux","nodes":[{"name":"transport_inbound","type":"UdpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__"},"next":"quic_server"},{"name":"quic_server","type":"QuicServer","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__","protocol":"h3","max-packet-size":1350},"next":"mux_server"},{"name":"mux_server","type":"MuxServer","settings":{},"next":"outbound_to_local_service"},{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}}]}
direct-kcp.0	tunnels/direct-kcp	Without Mux	client	1500	{"name":"client-direct-kcp","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"kcp_client"},{"name":"kcp_client","type":"KcpClient","settings":{"send-mtu":1400,"fec":false,"kcp-no-congestion-control":false},"next":"udp_to_server"},{"name":"udp_to_server","type":"UdpConnector","settings":{"address":"__V_server_ip__","port":"__V_transport_port__"}}]}
direct-kcp.1	tunnels/direct-kcp	Without Mux	server	1500	{"name":"server-direct-kcp","nodes":[{"name":"transport_inbound","type":"UdpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__"},"next":"kcp_server"},{"name":"kcp_server","type":"KcpServer","settings":{"send-mtu":1400,"fec":false,"kcp-no-congestion-control":false},"next":"outbound_to_local_service"},{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}}]}
direct-kcp.2	tunnels/direct-kcp	With Mux (recommended)	client	1500	{"name":"client-direct-kcp-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"mux_client"},{"name":"mux_client","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":"__V_mux_connections_per_worker__"},"next":"kcp_client"},{"name":"kcp_client","type":"KcpClient","settings":{"send-mtu":1400,"fec":false,"kcp-no-congestion-control":false},"next":"udp_to_server"},{"name":"udp_to_server","type":"UdpConnector","settings":{"address":"__V_server_ip__","port":"__V_transport_port__"}}]}
direct-kcp.3	tunnels/direct-kcp	With Mux (recommended)	server	1500	{"name":"server-direct-kcp-mux","nodes":[{"name":"transport_inbound","type":"UdpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__"},"next":"kcp_server"},{"name":"kcp_server","type":"KcpServer","settings":{"send-mtu":1400,"fec":false,"kcp-no-congestion-control":false},"next":"mux_server"},{"name":"mux_server","type":"MuxServer","settings":{},"next":"outbound_to_local_service"},{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}}]}
reverse-tls.0	tunnels/reverse-tls	Without Mux	client	1500	{"name":"client-reverse-tls","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_shared_port__","nodelay":true},"next":"bridge_user_side"},{"name":"bridge_user_side","type":"Bridge","settings":{"pair":"bridge_reverse_side"}},{"name":"bridge_reverse_side","type":"Bridge","settings":{"pair":"bridge_user_side"}},{"name":"reverse_server","type":"ReverseServer","settings":{},"next":"bridge_reverse_side"},{"name":"tls_server","type":"TlsServer","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__","min-version":"TLSv1.2","max-version":"TLSv1.3","ciphers":"HIGH:!aNULL:!MD5","session-cache":"none","session-tickets":true,"verbose":false},"next":"reverse_server"},{"name":"reverse_transport_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_shared_port__","nodelay":true,"whitelist":["__V_server_ip__"]},"next":"tls_server"}]}
reverse-tls.1	tunnels/reverse-tls	Without Mux	server	1500	{"name":"server-reverse-tls","nodes":[{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}},{"name":"bridge_local_side","type":"Bridge","settings":{"pair":"bridge_reverse_client_side"},"next":"outbound_to_local_service"},{"name":"bridge_reverse_client_side","type":"Bridge","settings":{"pair":"bridge_local_side"},"next":"reverse_client"},{"name":"reverse_client","type":"ReverseClient","settings":{"minimum-unused":"__V_min_held_connections__"},"next":"tls_client"},{"name":"tls_client","type":"TlsClient","settings":{"sni":"__V_domain_to_handshake_tls__","verify":true},"next":"tcp_to_client"},{"name":"tcp_to_client","type":"TcpConnector","settings":{"address":"__V_client_ip__","port":"__V_client_tunnel_port__","nodelay":true}}]}
reverse-tls.2	tunnels/reverse-tls	With Mux (recommended)	client	1500	{"name":"client-reverse-tls-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_shared_port__","nodelay":true},"next":"bridge_user_side"},{"name":"bridge_user_side","type":"Bridge","settings":{"pair":"bridge_reverse_side"}},{"name":"bridge_reverse_side","type":"Bridge","settings":{"pair":"bridge_user_side"}},{"name":"reverse_server","type":"ReverseServer","settings":{},"next":"bridge_reverse_side"},{"name":"tls_server","type":"TlsServer","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__","min-version":"TLSv1.2","max-version":"TLSv1.3","ciphers":"HIGH:!aNULL:!MD5","session-cache":"none","session-tickets":true,"verbose":false},"next":"mux_server"},{"name":"reverse_transport_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_shared_port__","nodelay":true,"whitelist":["__V_server_ip__"]},"next":"tls_server"},{"name":"mux_server","type":"MuxServer","settings":{},"next":"reverse_server"}]}
reverse-tls.3	tunnels/reverse-tls	With Mux (recommended)	server	1500	{"name":"server-reverse-tls-mux","nodes":[{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}},{"name":"bridge_local_side","type":"Bridge","settings":{"pair":"bridge_reverse_client_side"},"next":"outbound_to_local_service"},{"name":"bridge_reverse_client_side","type":"Bridge","settings":{"pair":"bridge_local_side"},"next":"reverse_client"},{"name":"reverse_client","type":"ReverseClient","settings":{"minimum-unused":"__V_min_held_connections__"},"next":"mux_client"},{"name":"tls_client","type":"TlsClient","settings":{"sni":"__V_domain_to_handshake_tls__","verify":true},"next":"tcp_to_client"},{"name":"tcp_to_client","type":"TcpConnector","settings":{"address":"__V_client_ip__","port":"__V_client_tunnel_port__","nodelay":true}},{"name":"mux_client","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":"__V_mux_connections_per_worker__"},"next":"tls_client"}]}
reverse-reality.0	tunnels/reverse-reality	Without Mux	client	1500	{"name":"client-reverse-reality","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_shared_port__","nodelay":true},"next":"bridge_user_side"},{"name":"bridge_user_side","type":"Bridge","settings":{"pair":"bridge_reverse_side"}},{"name":"bridge_reverse_side","type":"Bridge","settings":{"pair":"bridge_user_side"}},{"name":"reverse_server","type":"ReverseServer","settings":{},"next":"bridge_reverse_side"},{"name":"reality-server","type":"RealityServer","settings":{"destination":"dest-visitor","password":"__V_password__","algorithm":"chacha20-poly1305","kdf-iterations":12000,"sniffing-attempts":8},"next":"reverse_server"},{"name":"dest-visitor","type":"TcpConnector","settings":{"address":"__V_ip_behind_domain_white__","port":443,"nodelay":true}},{"name":"reverse_transport_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_shared_port__","nodelay":true,"whitelist":["__V_server_ip__"]},"next":"reality-server"}]}
reverse-reality.1	tunnels/reverse-reality	Without Mux	server	1500	{"name":"server-reverse-reality","nodes":[{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}},{"name":"bridge_local_side","type":"Bridge","settings":{"pair":"bridge_reverse_client_side"},"next":"outbound_to_local_service"},{"name":"bridge_reverse_client_side","type":"Bridge","settings":{"pair":"bridge_local_side"},"next":"reverse_client"},{"name":"reverse_client","type":"ReverseClient","settings":{"minimum-unused":"__V_min_held_connections__"},"next":"reality-client"},{"name":"reality-client","type":"RealityClient","settings":{"sni":"__V_domain_to_handshake_reality__","verify":true,"password":"__V_password__","algorithm":"chacha20-poly1305","kdf-iterations":12000},"next":"tcp_to_client"},{"name":"tcp_to_client","type":"TcpConnector","settings":{"address":"__V_client_ip__","port":"__V_client_tunnel_port__","nodelay":true}}]}
reverse-reality.2	tunnels/reverse-reality	With Mux (recommended)	client	1500	{"name":"client-reverse-reality-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_shared_port__","nodelay":true},"next":"bridge_user_side"},{"name":"bridge_user_side","type":"Bridge","settings":{"pair":"bridge_reverse_side"}},{"name":"bridge_reverse_side","type":"Bridge","settings":{"pair":"bridge_user_side"}},{"name":"reverse_server","type":"ReverseServer","settings":{},"next":"bridge_reverse_side"},{"name":"reality-server","type":"RealityServer","settings":{"destination":"dest-visitor","password":"__V_password__","algorithm":"chacha20-poly1305","kdf-iterations":12000,"sniffing-attempts":8},"next":"mux_server"},{"name":"dest-visitor","type":"TcpConnector","settings":{"address":"__V_ip_behind_domain_white__","port":443,"nodelay":true}},{"name":"reverse_transport_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_shared_port__","nodelay":true,"whitelist":["__V_server_ip__"]},"next":"reality-server"},{"name":"mux_server","type":"MuxServer","settings":{},"next":"reverse_server"}]}
reverse-reality.3	tunnels/reverse-reality	With Mux (recommended)	server	1500	{"name":"server-reverse-reality-mux","nodes":[{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}},{"name":"bridge_local_side","type":"Bridge","settings":{"pair":"bridge_reverse_client_side"},"next":"outbound_to_local_service"},{"name":"bridge_reverse_client_side","type":"Bridge","settings":{"pair":"bridge_local_side"},"next":"reverse_client"},{"name":"reverse_client","type":"ReverseClient","settings":{"minimum-unused":"__V_min_held_connections__"},"next":"mux_client"},{"name":"reality-client","type":"RealityClient","settings":{"sni":"__V_domain_to_handshake_reality__","verify":true,"password":"__V_password__","algorithm":"chacha20-poly1305","kdf-iterations":12000},"next":"tcp_to_client"},{"name":"tcp_to_client","type":"TcpConnector","settings":{"address":"__V_client_ip__","port":"__V_client_tunnel_port__","nodelay":true}},{"name":"mux_client","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":"__V_mux_connections_per_worker__"},"next":"reality-client"}]}
reverse-quic.0	tunnels/reverse-quic	Without Mux	client	1500	{"name":"client-reverse-quic","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"bridge_user_side"},{"name":"bridge_user_side","type":"Bridge","settings":{"pair":"bridge_reverse_side"}},{"name":"bridge_reverse_side","type":"Bridge","settings":{"pair":"bridge_user_side"}},{"name":"reverse_server","type":"ReverseServer","settings":{},"next":"bridge_reverse_side"},{"name":"quic_server","type":"QuicServer","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__","protocol":"h3","max-packet-size":1350},"next":"reverse_server"},{"name":"reverse_transport_inbound","type":"UdpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__","whitelist":["__V_server_ip__"]},"next":"quic_server"}]}
reverse-quic.1	tunnels/reverse-quic	Without Mux	server	1500	{"name":"server-reverse-quic","nodes":[{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}},{"name":"bridge_local_side","type":"Bridge","settings":{"pair":"bridge_reverse_client_side"},"next":"outbound_to_local_service"},{"name":"bridge_reverse_client_side","type":"Bridge","settings":{"pair":"bridge_local_side"},"next":"reverse_client"},{"name":"reverse_client","type":"ReverseClient","settings":{"minimum-unused":"__V_min_held_connections__"},"next":"quic_client"},{"name":"quic_client","type":"QuicClient","settings":{"sni":"__V_domain_to_handshake_quic__","verify":true,"protocol":"h3","max-packet-size":1350},"next":"udp_to_client"},{"name":"udp_to_client","type":"UdpConnector","settings":{"address":"__V_client_ip__","port":"__V_transport_port__"}}]}
reverse-quic.2	tunnels/reverse-quic	With Mux (recommended)	client	1500	{"name":"client-reverse-quic-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"bridge_user_side"},{"name":"bridge_user_side","type":"Bridge","settings":{"pair":"bridge_reverse_side"}},{"name":"bridge_reverse_side","type":"Bridge","settings":{"pair":"bridge_user_side"}},{"name":"reverse_server","type":"ReverseServer","settings":{},"next":"bridge_reverse_side"},{"name":"quic_server","type":"QuicServer","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__","protocol":"h3","max-packet-size":1350},"next":"mux_server"},{"name":"reverse_transport_inbound","type":"UdpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__","whitelist":["__V_server_ip__"]},"next":"quic_server"},{"name":"mux_server","type":"MuxServer","settings":{},"next":"reverse_server"}]}
reverse-quic.3	tunnels/reverse-quic	With Mux (recommended)	server	1500	{"name":"server-reverse-quic-mux","nodes":[{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}},{"name":"bridge_local_side","type":"Bridge","settings":{"pair":"bridge_reverse_client_side"},"next":"outbound_to_local_service"},{"name":"bridge_reverse_client_side","type":"Bridge","settings":{"pair":"bridge_local_side"},"next":"reverse_client"},{"name":"reverse_client","type":"ReverseClient","settings":{"minimum-unused":"__V_min_held_connections__"},"next":"mux_client"},{"name":"quic_client","type":"QuicClient","settings":{"sni":"__V_domain_to_handshake_quic__","verify":true,"protocol":"h3","max-packet-size":1350},"next":"udp_to_client"},{"name":"udp_to_client","type":"UdpConnector","settings":{"address":"__V_client_ip__","port":"__V_transport_port__"}},{"name":"mux_client","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":"__V_mux_connections_per_worker__"},"next":"quic_client"}]}
reverse-kcp.0	tunnels/reverse-kcp	Without Mux	client	1500	{"name":"client-reverse-kcp","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"bridge_user_side"},{"name":"bridge_user_side","type":"Bridge","settings":{"pair":"bridge_reverse_side"}},{"name":"bridge_reverse_side","type":"Bridge","settings":{"pair":"bridge_user_side"}},{"name":"reverse_server","type":"ReverseServer","settings":{},"next":"bridge_reverse_side"},{"name":"kcp_server","type":"KcpServer","settings":{"send-mtu":1400,"fec":false,"kcp-no-congestion-control":false},"next":"reverse_server"},{"name":"reverse_transport_inbound","type":"UdpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__","whitelist":["__V_server_ip__"]},"next":"kcp_server"}]}
reverse-kcp.1	tunnels/reverse-kcp	Without Mux	server	1500	{"name":"server-reverse-kcp","nodes":[{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}},{"name":"bridge_local_side","type":"Bridge","settings":{"pair":"bridge_reverse_client_side"},"next":"outbound_to_local_service"},{"name":"bridge_reverse_client_side","type":"Bridge","settings":{"pair":"bridge_local_side"},"next":"reverse_client"},{"name":"reverse_client","type":"ReverseClient","settings":{"minimum-unused":"__V_min_held_connections__"},"next":"kcp_client"},{"name":"kcp_client","type":"KcpClient","settings":{"send-mtu":1400,"fec":false,"kcp-no-congestion-control":false},"next":"udp_to_client"},{"name":"udp_to_client","type":"UdpConnector","settings":{"address":"__V_client_ip__","port":"__V_transport_port__"}}]}
reverse-kcp.2	tunnels/reverse-kcp	With Mux (recommended)	client	1500	{"name":"client-reverse-kcp-mux","nodes":[{"name":"users_inbound","type":"TcpListener","settings":{"address":"0.0.0.0","port":"__V_user_port__","nodelay":true},"next":"bridge_user_side"},{"name":"bridge_user_side","type":"Bridge","settings":{"pair":"bridge_reverse_side"}},{"name":"bridge_reverse_side","type":"Bridge","settings":{"pair":"bridge_user_side"}},{"name":"reverse_server","type":"ReverseServer","settings":{},"next":"bridge_reverse_side"},{"name":"kcp_server","type":"KcpServer","settings":{"send-mtu":1400,"fec":false,"kcp-no-congestion-control":false},"next":"mux_server"},{"name":"reverse_transport_inbound","type":"UdpListener","settings":{"address":"0.0.0.0","port":"__V_transport_port__","whitelist":["__V_server_ip__"]},"next":"kcp_server"},{"name":"mux_server","type":"MuxServer","settings":{},"next":"reverse_server"}]}
reverse-kcp.3	tunnels/reverse-kcp	With Mux (recommended)	server	1500	{"name":"server-reverse-kcp-mux","nodes":[{"name":"outbound_to_local_service","type":"TcpConnector","settings":{"address":"127.0.0.1","port":"__V_final_port__","nodelay":true}},{"name":"bridge_local_side","type":"Bridge","settings":{"pair":"bridge_reverse_client_side"},"next":"outbound_to_local_service"},{"name":"bridge_reverse_client_side","type":"Bridge","settings":{"pair":"bridge_local_side"},"next":"reverse_client"},{"name":"reverse_client","type":"ReverseClient","settings":{"minimum-unused":"__V_min_held_connections__"},"next":"mux_client"},{"name":"kcp_client","type":"KcpClient","settings":{"send-mtu":1400,"fec":false,"kcp-no-congestion-control":false},"next":"udp_to_client"},{"name":"udp_to_client","type":"UdpConnector","settings":{"address":"__V_client_ip__","port":"__V_transport_port__"}},{"name":"mux_client","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":"__V_mux_connections_per_worker__"},"next":"kcp_client"}]}
local-proxies.0	proxies/local-proxies	SOCKS5 (TCP + UDP)	single	1400	{"name":"local-socks5","nodes":[{"name":"local-listener","type":"TcpUdpListener","settings":{"address":"__V_local-listener.address__","port":"__V_local-listener.port__","nodelay":true},"next":"socks"},{"name":"socks","type":"Socks5Server","settings":{"no-auth":true,"connect":true,"udp":true,"ipv4":"127.0.0.1"},"next":"direct"},{"name":"direct","type":"TcpUdpConnector","settings":{"address":"dest_context->address","port":"dest_context->port","nodelay":true}}]}
local-proxies.1	proxies/local-proxies	HTTP proxy (HTTP + CONNECT)	single	1400	{"name":"local-http-proxy","nodes":[{"name":"local-listener","type":"TcpListener","settings":{"address":"__V_local-listener.address__","port":"__V_local-listener.port__","nodelay":true},"next":"http-proxy"},{"name":"http-proxy","type":"HttpProxyServer","settings":{"no-auth":true},"next":"direct"},{"name":"direct","type":"TcpConnector","settings":{"address":"dest_context->address","port":"dest_context->port","nodelay":true}}]}
protocol-proxies.0	proxies/protocol-proxies	VLESS	client	1400	{"name":"vless-client","nodes":[{"name":"local-socks","type":"TcpUdpListener","next":"socks","settings":{"address":"__V_local-socks.address__","port":"__V_local-socks.port__"}},{"name":"socks","type":"Socks5Server","next":"vless","settings":{"no-auth":true,"connect":true,"udp":true,"ipv4":"127.0.0.1"}},{"name":"vless","type":"VlessClient","next":"tls","settings":{"uuid":"__V_shared.uuid__","address":"dest_context->address","port":"dest_context->port","protocol":"dest_context->protocol","dns-behaviour":{"resolve":false}}},{"name":"tls","type":"TlsClient","next":"server","settings":{"sni":"__V_shared.domain__","verify":true}},{"name":"server","type":"TcpConnector","settings":{"address":"__V_server.address__","port":"__V_server.port__","nodelay":true}}]}
protocol-proxies.1	proxies/protocol-proxies	VLESS	server	1400	{"name":"vless-server","nodes":[{"name":"public-tls","type":"TcpListener","next":"tls","settings":{"address":"__V_public-tls.address__","port":"__V_public-tls.port__","nodelay":true}},{"name":"tls","type":"TlsServer","next":"vless","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__"}},{"name":"vless","type":"VlessServer","next":"destination","settings":{"uuid":"__V_shared.uuid__","connect":true,"udp":true}},{"name":"destination","type":"TcpUdpConnector","settings":{"address":"dest_context->address","port":"dest_context->port","nodelay":true}}]}
protocol-proxies.2	proxies/protocol-proxies	VMess	client	1400	{"name":"vmess-client","nodes":[{"name":"local-socks","type":"TcpUdpListener","next":"socks","settings":{"address":"__V_local-socks.address__","port":"__V_local-socks.port__"}},{"name":"socks","type":"Socks5Server","next":"vmess","settings":{"no-auth":true,"connect":true,"udp":true,"ipv4":"127.0.0.1"}},{"name":"vmess","type":"VmessClient","next":"tls","settings":{"uuid":"__V_shared.uuid__","address":"dest_context->address","port":"dest_context->port","protocol":"dest_context->protocol","security":"aes-128-gcm","dns-behaviour":{"resolve":false}}},{"name":"tls","type":"TlsClient","next":"server","settings":{"sni":"__V_shared.domain__","verify":true}},{"name":"server","type":"TcpConnector","settings":{"address":"__V_server.address__","port":"__V_server.port__","nodelay":true}}]}
protocol-proxies.3	proxies/protocol-proxies	VMess	server	1400	{"name":"vmess-server","nodes":[{"name":"public-tls","type":"TcpListener","next":"tls","settings":{"address":"__V_public-tls.address__","port":"__V_public-tls.port__","nodelay":true}},{"name":"tls","type":"TlsServer","next":"vmess","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__"}},{"name":"vmess","type":"VmessServer","next":"destination","settings":{"uuid":"__V_shared.uuid__","connect":true,"udp":true}},{"name":"destination","type":"TcpUdpConnector","settings":{"address":"dest_context->address","port":"dest_context->port","nodelay":true}}]}
protocol-proxies.4	proxies/protocol-proxies	Trojan	client	1400	{"name":"trojan-client","nodes":[{"name":"local-socks","type":"TcpUdpListener","next":"socks","settings":{"address":"__V_local-socks.address__","port":"__V_local-socks.port__"}},{"name":"socks","type":"Socks5Server","next":"trojan","settings":{"no-auth":true,"connect":true,"udp":true,"ipv4":"127.0.0.1"}},{"name":"trojan","type":"TrojanClient","next":"tls","settings":{"password":"__V_shared.password__","address":"dest_context->address","port":"dest_context->port","protocol":"dest_context->protocol","dns-behaviour":{"resolve":false}}},{"name":"tls","type":"TlsClient","next":"server","settings":{"sni":"__V_shared.domain__","verify":true}},{"name":"server","type":"TcpConnector","settings":{"address":"__V_server.address__","port":"__V_server.port__","nodelay":true}}]}
protocol-proxies.5	proxies/protocol-proxies	Trojan	server	1400	{"name":"trojan-server","nodes":[{"name":"public-tls","type":"TcpListener","next":"tls","settings":{"address":"__V_public-tls.address__","port":"__V_public-tls.port__","nodelay":true}},{"name":"tls","type":"TlsServer","next":"trojan","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__"}},{"name":"trojan","type":"TrojanServer","next":"destination","settings":{"password":"__V_shared.password__","connect":true,"udp":true}},{"name":"destination","type":"TcpUdpConnector","settings":{"address":"dest_context->address","port":"dest_context->port","nodelay":true}}]}
websocket.0	proxies/websocket	-	client	1400	{"name":"vmess-websocket-client","nodes":[{"name":"local-socks","type":"TcpUdpListener","next":"socks","settings":{"address":"__V_local-socks.address__","port":"__V_local-socks.port__"}},{"name":"socks","type":"Socks5Server","next":"vmess","settings":{"no-auth":true,"connect":true,"udp":true,"ipv4":"127.0.0.1"}},{"name":"vmess","type":"VmessClient","next":"websocket","settings":{"uuid":"__V_shared.uuid__","address":"dest_context->address","port":"dest_context->port","protocol":"dest_context->protocol","security":"aes-128-gcm","dns-behaviour":{"resolve":false}}},{"name":"websocket","type":"HttpClient","next":"tls","settings":{"http-version":1,"websocket":true,"host":"__V_shared.domain__","path":"__V_shared.ws-path__"}},{"name":"tls","type":"TlsClient","next":"server","settings":{"sni":"__V_shared.domain__","verify":true,"alpns":["http/1.1"]}},{"name":"server","type":"TcpConnector","settings":{"address":"__V_server.address__","port":"__V_server.port__","nodelay":true}}]}
websocket.1	proxies/websocket	-	server	1400	{"name":"vmess-websocket-server","nodes":[{"name":"public-tls","type":"TcpListener","next":"tls","settings":{"address":"__V_public-tls.address__","port":"__V_public-tls.port__","nodelay":true}},{"name":"tls","type":"TlsServer","next":"websocket","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__","select-alpns":["http/1.1"]}},{"name":"websocket","type":"HttpServer","next":"vmess","settings":{"http-version":1,"websocket":true,"host":"__V_shared.domain__","path":"__V_shared.ws-path__"}},{"name":"vmess","type":"VmessServer","next":"destination","settings":{"uuid":"__V_shared.uuid__","connect":true,"udp":true}},{"name":"destination","type":"TcpUdpConnector","settings":{"address":"dest_context->address","port":"dest_context->port","nodelay":true}}]}
socks-mux.0	proxies/socks-mux	-	client	1400	{"name":"socks-router-mux-client","nodes":[{"name":"local-listener","type":"TcpUdpListener","settings":{"address":"__V_local-listener.address__","port":"__V_local-listener.port__","nodelay":true},"next":"socks"},{"name":"socks","type":"Socks5Server","settings":{"no-auth":true,"connect":true,"udp":true,"ipv4":"127.0.0.1"},"next":"route"},{"name":"route","type":"Router","settings":{"rules":[{"network":"udp","target":"direct-udp"}]},"next":"vless"},{"name":"direct-udp","type":"UdpConnector","settings":{"address":"dest_context->address","port":"dest_context->port"}},{"name":"vless","type":"VlessClient","settings":{"uuid":"__V_shared.uuid__","address":"dest_context->address","port":"dest_context->port","protocol":"tcp","dns-behaviour":{"resolve":false}},"next":"mux"},{"name":"mux","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":2},"next":"tls"},{"name":"tls","type":"TlsClient","settings":{"sni":"__V_shared.domain__","verify":true},"next":"remote-server"},{"name":"remote-server","type":"TcpConnector","settings":{"address":"__V_remote-server.address__","port":"__V_remote-server.port__","nodelay":true}}]}
socks-mux.1	proxies/socks-mux	-	server	1400	{"name":"socks-router-mux-server","nodes":[{"name":"public-listener","type":"TcpListener","settings":{"address":"__V_public-listener.address__","port":"__V_public-listener.port__","nodelay":true},"next":"tls"},{"name":"tls","type":"TlsServer","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__"},"next":"mux"},{"name":"mux","type":"MuxServer","settings":{},"next":"vless"},{"name":"vless","type":"VlessServer","settings":{"uuid":"__V_shared.uuid__","connect":true,"udp":false},"next":"destination"},{"name":"destination","type":"TcpConnector","settings":{"address":"dest_context->address","port":"dest_context->port","nodelay":true}}]}
kcp.0	proxies/kcp	-	client	1400	{"name":"socks-vless-mux-tls-kcp-client","nodes":[{"name":"local-socks","type":"TcpUdpListener","settings":{"address":"__V_local-socks.address__","port":"__V_local-socks.port__","nodelay":true},"next":"socks"},{"name":"socks","type":"Socks5Server","settings":{"no-auth":true,"connect":true,"udp":true,"ipv4":"127.0.0.1"},"next":"vless"},{"name":"vless","type":"VlessClient","settings":{"uuid":"__V_shared.uuid__","address":"dest_context->address","port":"dest_context->port","protocol":"dest_context->protocol","dns-behaviour":{"resolve":false}},"next":"mux"},{"name":"mux","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":2},"next":"tls"},{"name":"tls","type":"TlsClient","settings":{"sni":"__V_shared.domain__","verify":true,"alpns":["http/1.1"]},"next":"kcp"},{"name":"kcp","type":"KcpClient","settings":{"send-mtu":1400,"fec":false,"kcp-no-congestion-control":false},"next":"server"},{"name":"server","type":"UdpConnector","settings":{"address":"__V_server.address__","port":"__V_server.port__"}}]}
kcp.1	proxies/kcp	-	server	1400	{"name":"socks-vless-mux-tls-kcp-server","nodes":[{"name":"kcp-in","type":"UdpListener","settings":{"address":"__V_kcp-in.address__","port":"__V_kcp-in.port__"},"next":"kcp"},{"name":"kcp","type":"KcpServer","settings":{"send-mtu":1400,"fec":false,"kcp-no-congestion-control":false},"next":"tls"},{"name":"tls","type":"TlsServer","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__","select-alpns":["http/1.1"]},"next":"mux"},{"name":"mux","type":"MuxServer","settings":{},"next":"vless"},{"name":"vless","type":"VlessServer","settings":{"uuid":"__V_shared.uuid__","connect":true,"udp":true},"next":"destination"},{"name":"destination","type":"TcpUdpConnector","settings":{"address":"dest_context->address","port":"dest_context->port","nodelay":true}}]}
quic.0	proxies/quic	-	client	1400	{"name":"socks-vless-mux-quic-client","nodes":[{"name":"local-socks","type":"TcpUdpListener","settings":{"address":"__V_local-socks.address__","port":"__V_local-socks.port__","nodelay":true},"next":"socks"},{"name":"socks","type":"Socks5Server","settings":{"no-auth":true,"connect":true,"udp":true,"ipv4":"127.0.0.1"},"next":"vless"},{"name":"vless","type":"VlessClient","settings":{"uuid":"__V_shared.uuid__","address":"dest_context->address","port":"dest_context->port","protocol":"dest_context->protocol","dns-behaviour":{"resolve":false}},"next":"mux"},{"name":"mux","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":2},"next":"quic"},{"name":"quic","type":"QuicClient","settings":{"sni":"__V_shared.domain__","verify":true,"protocol":"h3","max-packet-size":1350},"next":"server"},{"name":"server","type":"UdpConnector","settings":{"address":"__V_server.address__","port":"__V_server.port__"}}]}
quic.1	proxies/quic	-	server	1400	{"name":"socks-vless-mux-quic-server","nodes":[{"name":"quic-in","type":"UdpListener","settings":{"address":"__V_quic-in.address__","port":"__V_quic-in.port__"},"next":"quic"},{"name":"quic","type":"QuicServer","settings":{"cert-file":"__V_certificate_path__","key-file":"__V_key_path__","protocol":"h3","max-packet-size":1350},"next":"mux"},{"name":"mux","type":"MuxServer","settings":{},"next":"vless"},{"name":"vless","type":"VlessServer","settings":{"uuid":"__V_shared.uuid__","connect":true,"udp":true},"next":"destination"},{"name":"destination","type":"TcpUdpConnector","settings":{"address":"dest_context->address","port":"dest_context->port","nodelay":true}}]}
rtmp.0	proxies/rtmp	-	client	1400	{"name":"socks-vless-rtmps-client","nodes":[{"name":"local-socks","type":"TcpUdpListener","settings":{"address":"__V_local-socks.address__","port":"__V_local-socks.port__"},"next":"socks"},{"name":"socks","type":"Socks5Server","settings":{"no-auth":true,"connect":true,"udp":true,"ipv4":"127.0.0.1"},"next":"vless"},{"name":"vless","type":"VlessClient","settings":{"uuid":"__V_shared.uuid__","address":"dest_context->address","port":"dest_context->port","protocol":"dest_context->protocol","dns-behaviour":{"resolve":false}},"next":"rtmp"},{"name":"rtmp","type":"RtmpClient","settings":{"app":"waterwall","stream":"tunnel","tc-url":"__V_rtmp.tc-url__"},"next":"tls"},{"name":"tls","type":"TlsClient","settings":{"sni":"__V_shared.domain__","verify":true,"alpns":[]},"next":"carrier"},{"name":"carrier","type":"TcpConnector","settings":{"address":"__V_carrier.address__","port":"__V_carrier.port__"}}]}
rtmp.1	proxies/rtmp	-	server	1400	{"name":"socks-vless-rtmps-server","nodes":[{"name":"carrier","type":"TcpListener","settings":{"address":"__V_carrier.address__","port":"__V_carrier.port__"},"next":"tls"},{"name":"tls","type":"TlsServer","settings":{"sni":"__V_shared.domain__","cert-file":"__V_certificate_path__","key-file":"__V_key_path__","select-alpns":[]},"next":"rtmp"},{"name":"rtmp","type":"RtmpServer","settings":{"app":"waterwall","stream":"tunnel"},"next":"vless"},{"name":"vless","type":"VlessServer","settings":{"uuid":"__V_shared.uuid__","connect":true,"udp":true},"next":"destination"},{"name":"destination","type":"TcpUdpConnector","settings":{"address":"dest_context->address","port":"dest_context->port"}}]}
socks5-rtmp-reality.0	proxies/socks5-rtmp-reality	-	client	1400	{"name":"socks5-rtmp-reality-client","nodes":[{"name":"socks-listener","type":"TcpUdpListener","settings":{"address":"__V_socks_address__","port":"__V_socks_port__","nodelay":true},"next":"socks"},{"name":"socks","type":"Socks5Server","settings":{"no-auth":true,"connect":true,"udp":true,"ipv4":"__V_socks_address__"},"next":"trojan"},{"name":"trojan","type":"TrojanClient","settings":{"password":"__V_trojan_password__","address":"dest_context->address","port":"dest_context->port","protocol":"dest_context->protocol"},"next":"mux"},{"name":"mux","type":"MuxClient","settings":{"mode":"fixed-connections-count","per-worker-connections-count":"__V_mux_connections_per_worker__"},"next":"half-duplex"},{"name":"half-duplex","type":"HalfDuplexClient","settings":{"upload":"up","download":"down"}},{"name":"up","type":"ConnectionStripeClient","settings":{"connections":"__V_stripe_connections__"},"next":"obfuscator"},{"name":"obfuscator","type":"ObfuscatorClient","settings":{"method":"xor","xor_key":"__V_obfuscator_key__"},"next":"rtmp"},{"name":"rtmp","type":"RtmpClient","settings":{"tc-url":"__V_rtmp_url__"},"next":"rtmp-connector"},{"name":"rtmp-connector","type":"TcpConnector","settings":{"address":"__V_server_address__","port":"__V_rtmp_port__","nodelay":true,"fastopen":false}},{"name":"down","type":"RealityClient","settings":{"sni":"__V_reality_sni__","password":"__V_reality_password__","verify":true},"next":"reality-connector"},{"name":"reality-connector","type":"TcpConnector","settings":{"address":"__V_server_address__","port":"__V_reality_port__","nodelay":true,"fastopen":false}}]}
socks5-rtmp-reality.1	proxies/socks5-rtmp-reality	-	server	1400	{"name":"socks5-rtmp-reality-server","nodes":[{"name":"rtmp-listener","type":"TcpListener","settings":{"address":"__V_listen_address__","port":"__V_rtmp_port__","nodelay":true},"next":"rtmp"},{"name":"rtmp","type":"RtmpServer","next":"obfuscator"},{"name":"obfuscator","type":"ObfuscatorServer","settings":{"method":"xor","xor_key":"__V_obfuscator_key__"},"next":"stripe"},{"name":"stripe","type":"ConnectionStripeServer","settings":{"max-connections":"__V_stripe_connections__"},"next":"up"},{"name":"up","type":"HalfDuplexServer","next":"mux"},{"name":"reality-listener","type":"TcpListener","settings":{"address":"__V_listen_address__","port":"__V_reality_port__","nodelay":true},"next":"reality"},{"name":"reality","type":"RealityServer","settings":{"destination":"cover-connector","password":"__V_reality_password__"},"next":"down"},{"name":"down","type":"HalfDuplexServer","settings":{"pair":"up"}},{"name":"mux","type":"MuxServer","next":"trojan"},{"name":"trojan","type":"TrojanServer","settings":{"password":"__V_trojan_password__","connect":true,"udp":true},"next":"outbound"},{"name":"outbound","type":"TcpUdpConnector","settings":{"address":"dest_context->address","port":"dest_context->port","nodelay":true,"fastopen":false}},{"name":"cover-connector","type":"TcpConnector","settings":{"address":"__V_reality_sni__","port":443,"nodelay":true,"fastopen":false}}]}
__WWTPL__
)
WW_TPLVARS=$(cat <<'__WWVAR__'
bitswap-mux.0	client_ip	ip	"192.0.2.10"	Client public IPv4
bitswap-mux.0	server_ip	ip	"198.51.100.20"	Server public IPv4
bitswap-mux.0	port_to_listen	port	443	Listen port
bitswap-mux.0	server_carrier_port	port	443	Server carrier port
bitswap-mux.0	each_worker_mux_connections_count	int	8	Mux connections per worker
bitswap-mux.1	client_ip	ip	"192.0.2.10"	Client public IPv4
bitswap-mux.1	server_ip	ip	"198.51.100.20"	Server public IPv4
bitswap-mux.1	port_to_listen	port	443	Listen port
bitswap-mux.1	final_ip	ip	"127.0.0.1"	Final service address (on the server)
bitswap-mux.1	final_port	port	2083	Final service port (on the server)
bitswap-mux.2	client_ip	ip	"192.0.2.10"	Client public IPv4
bitswap-mux.2	server_ip	ip	"198.51.100.20"	Server public IPv4
bitswap-mux.2	port_to_listen	port	443	Listen port
bitswap-mux.2	server_carrier_port	port	443	Server carrier port
bitswap-mux.2	each_worker_mux_connections_count	int	8	Mux connections per worker
bitswap-mux.3	client_ip	ip	"192.0.2.10"	Client public IPv4
bitswap-mux.3	server_ip	ip	"198.51.100.20"	Server public IPv4
bitswap-mux.3	port_to_listen	port	443	Listen port
bitswap-mux.3	final_ip	ip	"127.0.0.1"	Final service address (on the server)
bitswap-mux.3	final_port	port	2083	Final service port (on the server)
bitswap-mux.4	client_ip	ip	"192.0.2.10"	Client public IPv4
bitswap-mux.4	server_ip	ip	"198.51.100.20"	Server public IPv4
bitswap-mux.4	port_to_listen	port	443	Listen port
bitswap-mux.4	server_carrier_port	port	443	Server carrier port
bitswap-mux.4	each_worker_mux_connections_count	int	8	Mux connections per worker
bitswap-mux.5	client_ip	ip	"192.0.2.10"	Client public IPv4
bitswap-mux.5	server_ip	ip	"198.51.100.20"	Server public IPv4
bitswap-mux.5	port_to_listen	port	443	Listen port
bitswap-mux.5	final_ip	ip	"127.0.0.1"	Final service address (on the server)
bitswap-mux.5	final_port	port	2083	Final service port (on the server)
connection-stripe-tls.0	application.address	host	"127.0.0.1"	Listen address (application)
connection-stripe-tls.0	application.port	port	1080	Listen port (application)
connection-stripe-tls.0	stripe_connections	int	8	Parallel connections per stream
connection-stripe-tls.0	shared.domain	domain	"stripe.example.test"	TLS / HTTP domain (SNI, Host, certificate)
connection-stripe-tls.0	transport.address	host	""	Server address (transport)
connection-stripe-tls.0	transport.port	port	8443	Server port (transport)
connection-stripe-tls.1	application.address	host	"127.0.0.1"	Listen address (application)
connection-stripe-tls.1	application.port	port	1080	Listen port (application)
connection-stripe-tls.1	stripe_connections	int	8	Parallel connections per stream
connection-stripe-tls.1	shared.domain	domain	"stripe.example.test"	TLS / HTTP domain (SNI, Host, certificate)
connection-stripe-tls.1	transport.address	host	""	Server address (transport)
connection-stripe-tls.1	transport.port	port	8443	Server port (transport)
connection-stripe-tls.2	transport.address	host	"0.0.0.0"	Listen address (transport)
connection-stripe-tls.2	transport.port	port	8443	Listen port (transport)
connection-stripe-tls.2	certificate_path	path	"server.crt"	TLS certificate (fullchain) path
connection-stripe-tls.2	key_path	path	"server.key"	TLS private key path
connection-stripe-tls.2	shared.domain	domain	"stripe.example.test"	TLS / HTTP domain (SNI, Host, certificate)
connection-stripe-tls.2	destination.address	host	"127.0.0.1"	Destination address (destination)
connection-stripe-tls.2	destination.port	port	9000	Destination port (destination)
connection-stripe-tls.3	transport.address	host	"0.0.0.0"	Listen address (transport)
connection-stripe-tls.3	transport.port	port	8443	Listen port (transport)
connection-stripe-tls.3	certificate_path	path	"server.crt"	TLS certificate (fullchain) path
connection-stripe-tls.3	key_path	path	"server.key"	TLS private key path
connection-stripe-tls.3	shared.domain	domain	"stripe.example.test"	TLS / HTTP domain (SNI, Host, certificate)
connection-stripe-tls.3	destination.address	host	"127.0.0.1"	Destination address (destination)
connection-stripe-tls.3	destination.port	port	9000	Destination port (destination)
direct-bgp4.0	server_ip	ip	"198.51.100.20"	Server public IPv4
direct-bgp4.0	user_port	port	443	Port users connect to
direct-bgp4.0	transport_port	port	7443	Tunnel (transport) port
direct-bgp4.1	transport_port	port	7443	Tunnel (transport) port
direct-bgp4.1	final_port	port	80	Final service port (on the server)
direct-bgp4.2	server_ip	ip	"198.51.100.20"	Server public IPv4
direct-bgp4.2	user_port	port	443	Port users connect to
direct-bgp4.2	transport_port	port	7443	Tunnel (transport) port
direct-bgp4.2	mux_connections_per_worker	int	2	Mux connections per worker
direct-bgp4.3	transport_port	port	7443	Tunnel (transport) port
direct-bgp4.3	final_port	port	80	Final service port (on the server)
direct-kcp.0	server_ip	ip	"198.51.100.20"	Server public IPv4
direct-kcp.0	user_port	port	443	Port users connect to
direct-kcp.0	transport_port	port	4000	Tunnel (transport) port
direct-kcp.1	transport_port	port	4000	Tunnel (transport) port
direct-kcp.1	final_port	port	80	Final service port (on the server)
direct-kcp.2	server_ip	ip	"198.51.100.20"	Server public IPv4
direct-kcp.2	user_port	port	443	Port users connect to
direct-kcp.2	transport_port	port	4000	Tunnel (transport) port
direct-kcp.2	mux_connections_per_worker	int	2	Mux connections per worker
direct-kcp.3	transport_port	port	4000	Tunnel (transport) port
direct-kcp.3	final_port	port	80	Final service port (on the server)
direct-quic.0	server_ip	ip	"198.51.100.20"	Server public IPv4
direct-quic.0	user_port	port	443	Port users connect to
direct-quic.0	transport_port	port	4433	Tunnel (transport) port
direct-quic.0	domain_to_handshake_quic	domain	"tunnel.example.com"	QUIC SNI / certificate domain
direct-quic.1	transport_port	port	4433	Tunnel (transport) port
direct-quic.1	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
direct-quic.1	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
direct-quic.1	final_port	port	80	Final service port (on the server)
direct-quic.2	server_ip	ip	"198.51.100.20"	Server public IPv4
direct-quic.2	user_port	port	443	Port users connect to
direct-quic.2	transport_port	port	4433	Tunnel (transport) port
direct-quic.2	domain_to_handshake_quic	domain	"tunnel.example.com"	QUIC SNI / certificate domain
direct-quic.2	mux_connections_per_worker	int	2	Mux connections per worker
direct-quic.3	transport_port	port	4433	Tunnel (transport) port
direct-quic.3	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
direct-quic.3	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
direct-quic.3	final_port	port	80	Final service port (on the server)
direct-reality.0	server_ip	ip	"198.51.100.20"	Server public IPv4
direct-reality.0	user_port	port	443	Port users connect to
direct-reality.0	transport_port	port	443	Tunnel (transport) port
direct-reality.0	visitor_domain	domain	"visitor.example.com"	Reality SNI (real website)
direct-reality.0	password	secret	"REPLACE_WITH_SHARED_PASSWORD"	Shared password (same on both sides)
direct-reality.1	transport_port	port	443	Tunnel (transport) port
direct-reality.1	visitor_ip	ip	"203.0.113.30"	IP of the real website for visitors
direct-reality.1	password	secret	"REPLACE_WITH_SHARED_PASSWORD"	Shared password (same on both sides)
direct-reality.1	final_port	port	80	Final service port (on the server)
direct-reality.2	server_ip	ip	"198.51.100.20"	Server public IPv4
direct-reality.2	user_port	port	443	Port users connect to
direct-reality.2	transport_port	port	443	Tunnel (transport) port
direct-reality.2	visitor_domain	domain	"visitor.example.com"	Reality SNI (real website)
direct-reality.2	password	secret	"REPLACE_WITH_SHARED_PASSWORD"	Shared password (same on both sides)
direct-reality.2	mux_connections_per_worker	int	2	Mux connections per worker
direct-reality.3	transport_port	port	443	Tunnel (transport) port
direct-reality.3	visitor_ip	ip	"203.0.113.30"	IP of the real website for visitors
direct-reality.3	password	secret	"REPLACE_WITH_SHARED_PASSWORD"	Shared password (same on both sides)
direct-reality.3	final_port	port	80	Final service port (on the server)
direct-rtmp.0	user_port	port	9000	Port users connect to
direct-rtmp.0	server_ip	ip	"198.51.100.20"	Server public IPv4
direct-rtmp.0	transport_port	port	443	Tunnel (transport) port
direct-rtmp.0	tls_name	domain	"tunnel.example.com"	TLS domain (SNI / certificate)
direct-rtmp.0	tc_url	str	"rtmps://tunnel.example.com:443/waterwall"	RTMP tc-url (rtmp[s]://host:port/app)
direct-rtmp.1	transport_port	port	443	Tunnel (transport) port
direct-rtmp.1	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
direct-rtmp.1	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
direct-rtmp.1	final_port	port	8080	Final service port (on the server)
direct-rtmp.2	user_port	port	9000	Port users connect to
direct-rtmp.2	server_ip	ip	"198.51.100.20"	Server public IPv4
direct-rtmp.2	transport_port	port	1935	Tunnel (transport) port
direct-rtmp.2	tc_url	str	"rtmp://198.51.100.20:1935/waterwall"	RTMP tc-url (rtmp[s]://host:port/app)
direct-rtmp.3	transport_port	port	1935	Tunnel (transport) port
direct-rtmp.3	final_port	port	8080	Final service port (on the server)
direct-tls.0	server_ip	ip	"198.51.100.20"	Server public IPv4
direct-tls.0	user_port	port	443	Port users connect to
direct-tls.0	transport_port	port	443	Tunnel (transport) port
direct-tls.0	domain_to_handshake_tls	domain	"tunnel.example.com"	TLS SNI / certificate domain
direct-tls.1	transport_port	port	443	Tunnel (transport) port
direct-tls.1	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
direct-tls.1	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
direct-tls.1	final_port	port	80	Final service port (on the server)
direct-tls.2	server_ip	ip	"198.51.100.20"	Server public IPv4
direct-tls.2	user_port	port	443	Port users connect to
direct-tls.2	transport_port	port	443	Tunnel (transport) port
direct-tls.2	domain_to_handshake_tls	domain	"tunnel.example.com"	TLS SNI / certificate domain
direct-tls.2	mux_connections_per_worker	int	2	Mux connections per worker
direct-tls.3	transport_port	port	443	Tunnel (transport) port
direct-tls.3	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
direct-tls.3	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
direct-tls.3	final_port	port	80	Final service port (on the server)
fake-tcp-header.0	client_ip	ip	"192.0.2.10"	Client public IPv4
fake-tcp-header.0	server_ip	ip	"198.51.100.20"	Server public IPv4
fake-tcp-header.0	inner_ip_client	ip	"10.90.0.1"	Inner IP of the client side
fake-tcp-header.0	inner_ip_server	ip	"10.90.0.2"	Inner IP of the server side
fake-tcp-header.0	fake_server_port	port	40000	Fake TCP server port
fake-tcp-header.0	fake_client_ports	json	[40001, 40016]	Fake TCP client port range [from, to]
fake-tcp-header.0	password	secret	"REPLACE_WITH_SHARED_PASSWORD"	Shared password (same on both sides)
fake-tcp-header.0	native_mtu	int	1400	Inner MTU
fake-tcp-header.0	user_port	port	443	Port users connect to
fake-tcp-header.0	tunnel_port	port	5300	Inner tunnel port
fake-tcp-header.1	client_ip	ip	"192.0.2.10"	Client public IPv4
fake-tcp-header.1	server_ip	ip	"198.51.100.20"	Server public IPv4
fake-tcp-header.1	inner_ip_client	ip	"10.90.0.1"	Inner IP of the client side
fake-tcp-header.1	inner_ip_server	ip	"10.90.0.2"	Inner IP of the server side
fake-tcp-header.1	fake_server_port	port	40000	Fake TCP server port
fake-tcp-header.1	fake_client_ports	json	[40001, 40016]	Fake TCP client port range [from, to]
fake-tcp-header.1	password	secret	"REPLACE_WITH_SHARED_PASSWORD"	Shared password (same on both sides)
fake-tcp-header.1	native_mtu	int	1400	Inner MTU
fake-tcp-header.1	final_ip	ip	"127.0.0.1"	Final service address (on the server)
fake-tcp-header.1	final_port	port	80	Final service port (on the server)
fake-tcp-header.2	client_ip	ip	"192.0.2.10"	Client public IPv4
fake-tcp-header.2	server_ip	ip	"198.51.100.20"	Server public IPv4
fake-tcp-header.2	inner_ip_client	ip	"10.90.0.1"	Inner IP of the client side
fake-tcp-header.2	inner_ip_server	ip	"10.90.0.2"	Inner IP of the server side
fake-tcp-header.2	fake_server_port	port	40000	Fake TCP server port
fake-tcp-header.2	fake_client_ports	json	[40001, 40016]	Fake TCP client port range [from, to]
fake-tcp-header.2	password	secret	"REPLACE_WITH_SHARED_PASSWORD"	Shared password (same on both sides)
fake-tcp-header.2	native_mtu	int	1400	Inner MTU
fake-tcp-header.2	tun_name	str	"wwfake0"	TUN device name
fake-tcp-header.2	tun_cidr	cidr	"10.90.0.1/30"	TUN device address (CIDR)
fake-tcp-header.2	user_port	port	5300	Port users connect to
fake-tcp-header.2	tunnel_port	port	5300	Inner tunnel port
fake-tcp-header.3	client_ip	ip	"192.0.2.10"	Client public IPv4
fake-tcp-header.3	server_ip	ip	"198.51.100.20"	Server public IPv4
fake-tcp-header.3	inner_ip_client	ip	"10.90.0.1"	Inner IP of the client side
fake-tcp-header.3	inner_ip_server	ip	"10.90.0.2"	Inner IP of the server side
fake-tcp-header.3	fake_server_port	port	40000	Fake TCP server port
fake-tcp-header.3	fake_client_ports	json	[40001, 40016]	Fake TCP client port range [from, to]
fake-tcp-header.3	password	secret	"REPLACE_WITH_SHARED_PASSWORD"	Shared password (same on both sides)
fake-tcp-header.3	native_mtu	int	1400	Inner MTU
fake-tcp-header.3	tun_name	str	"wwfake0"	TUN device name
fake-tcp-header.3	tun_cidr	cidr	"10.90.0.2/30"	TUN device address (CIDR)
fake-tcp-header.3	tunnel_port	port	5300	Inner tunnel port
fake-tcp-header.3	final_ip	ip	"127.0.0.1"	Final service address (on the server)
fake-tcp-header.3	final_port	port	5300	Final service port (on the server)
halfduplex-split-transports.0	application.address	host	"127.0.0.1"	Listen address (application)
halfduplex-split-transports.0	application.port	port	1080	Listen port (application)
halfduplex-split-transports.0	shared.uuid	uuid	"5783a3e7-e373-51cd-8642-c83782b807c5"	UUID (must match on both sides)
halfduplex-split-transports.0	vless-client.address	host	"127.0.0.1"	Final destination address, as seen from the server (vless-client)
halfduplex-split-transports.0	vless-client.port	port	9000	Final destination port, as seen from the server (vless-client)
halfduplex-split-transports.0	shared.domain	domain	"halfduplex.example.test"	TLS / HTTP domain (SNI, Host, certificate)
halfduplex-split-transports.0	tcp-out.address	host	""	Server address (tcp-out)
halfduplex-split-transports.0	tcp-out.port	port	8443	Server port (tcp-out)
halfduplex-split-transports.0	udp-out.address	host	""	Server address (udp-out)
halfduplex-split-transports.0	udp-out.port	port	4000	Server port (udp-out)
halfduplex-split-transports.1	udp-in.address	host	"0.0.0.0"	Listen address (udp-in)
halfduplex-split-transports.1	udp-in.port	port	4000	Listen port (udp-in)
halfduplex-split-transports.1	tcp-in.address	host	"0.0.0.0"	Listen address (tcp-in)
halfduplex-split-transports.1	tcp-in.port	port	8443	Listen port (tcp-in)
halfduplex-split-transports.1	certificate_path	path	"server.crt"	TLS certificate (fullchain) path
halfduplex-split-transports.1	key_path	path	"server.key"	TLS private key path
halfduplex-split-transports.1	shared.domain	domain	"halfduplex.example.test"	TLS / HTTP domain (SNI, Host, certificate)
halfduplex-split-transports.1	shared.uuid	uuid	"5783a3e7-e373-51cd-8642-c83782b807c5"	UUID (must match on both sides)
ping.0	client_ip	ip	"192.0.2.10"	Client public IPv4
ping.0	server_ip	ip	"198.51.100.20"	Server public IPv4
ping.0	inner_ip_client	ip	"10.90.0.1"	Inner IP of the client side
ping.0	inner_ip_server	ip	"10.90.0.2"	Inner IP of the server side
ping.0	user_port	port	443	Port users connect to
ping.0	tunnel_port	port	5300	Inner tunnel port
ping.0	tunnel_mtu	int	1400	Inner tunnel MTU
ping.1	client_ip	ip	"192.0.2.10"	Client public IPv4
ping.1	server_ip	ip	"198.51.100.20"	Server public IPv4
ping.1	tunnel_mtu	int	1400	Inner tunnel MTU
ping.1	final_ip	ip	"127.0.0.1"	Final service address (on the server)
ping.1	final_port	port	80	Final service port (on the server)
ping.1	inner_ip_client	ip	"10.90.0.1"	Inner IP of the client side
ping.1	inner_ip_server	ip	"10.90.0.2"	Inner IP of the server side
ping.2	client_ip	ip	"192.0.2.10"	Client public IPv4
ping.2	server_ip	ip	"198.51.100.20"	Server public IPv4
ping.2	inner_ip_server	ip	"10.90.0.2"	Inner IP of the server side
ping.2	tun_name	str	"wwping0"	TUN device name
ping.2	tun_cidr	cidr	"10.90.0.1/30"	TUN device address (CIDR)
ping.2	user_port	port	443	Port users connect to
ping.2	tunnel_port	port	5300	Inner tunnel port
ping.2	tunnel_mtu	int	1400	Inner tunnel MTU
ping.2	inner_ip_client	ip	"10.90.0.1"	Inner IP of the client side
ping.3	client_ip	ip	"192.0.2.10"	Client public IPv4
ping.3	server_ip	ip	"198.51.100.20"	Server public IPv4
ping.3	inner_ip_server	ip	"10.90.0.2"	Inner IP of the server side
ping.3	tun_name	str	"wwping0"	TUN device name
ping.3	tun_cidr	cidr	"10.90.0.2/30"	TUN device address (CIDR)
ping.3	tunnel_port	port	5300	Inner tunnel port
ping.3	tunnel_mtu	int	1400	Inner tunnel MTU
ping.3	final_ip	ip	"127.0.0.1"	Final service address (on the server)
ping.3	final_port	port	80	Final service port (on the server)
ping.3	inner_ip_client	ip	"10.90.0.1"	Inner IP of the client side
protoswap.0	client_ip	ip	"192.0.2.10"	Client public IPv4
protoswap.0	server_ip	ip	"198.51.100.20"	Server public IPv4
protoswap.0	client_listen_port	port	443	Port users connect to (client)
protoswap.0	server_service_port	port	443	Service port on the server (inside the tunnel)
protoswap.0	protoswap_tcp_to_number	int	50	IP protocol number to swap TCP into (not 6/17)
protoswap.1	client_ip	ip	"192.0.2.10"	Client public IPv4
protoswap.1	server_ip	ip	"198.51.100.20"	Server public IPv4
protoswap.1	protoswap_tcp_to_number	int	50	IP protocol number to swap TCP into (not 6/17)
reverse-bgp4.0	server_ip	cidr32	"198.51.100.20/32"	Server public IPv4
reverse-bgp4.0	user_port	port	443	Port users connect to
reverse-bgp4.0	transport_port	port	7443	Tunnel (transport) port
reverse-bgp4.1	client_ip	ip	"192.0.2.10"	Client public IPv4
reverse-bgp4.1	transport_port	port	7443	Tunnel (transport) port
reverse-bgp4.1	final_port	port	80	Final service port (on the server)
reverse-bgp4.1	min_held_connections	int	8	Pre-opened idle reverse connections
reverse-bgp4.2	server_ip	cidr32	"198.51.100.20/32"	Server public IPv4
reverse-bgp4.2	user_port	port	443	Port users connect to
reverse-bgp4.2	transport_port	port	7443	Tunnel (transport) port
reverse-bgp4.3	client_ip	ip	"192.0.2.10"	Client public IPv4
reverse-bgp4.3	transport_port	port	7443	Tunnel (transport) port
reverse-bgp4.3	final_port	port	80	Final service port (on the server)
reverse-bgp4.3	min_held_connections	int	8	Pre-opened idle reverse connections
reverse-bgp4.3	mux_connections_per_worker	int	2	Mux connections per worker
reverse-kcp.0	server_ip	cidr32	"198.51.100.20/32"	Server public IPv4
reverse-kcp.0	user_port	port	443	Port users connect to
reverse-kcp.0	transport_port	port	4000	Tunnel (transport) port
reverse-kcp.1	client_ip	ip	"192.0.2.10"	Client public IPv4
reverse-kcp.1	transport_port	port	4000	Tunnel (transport) port
reverse-kcp.1	final_port	port	80	Final service port (on the server)
reverse-kcp.1	min_held_connections	int	8	Pre-opened idle reverse connections
reverse-kcp.2	server_ip	cidr32	"198.51.100.20/32"	Server public IPv4
reverse-kcp.2	user_port	port	443	Port users connect to
reverse-kcp.2	transport_port	port	4000	Tunnel (transport) port
reverse-kcp.3	client_ip	ip	"192.0.2.10"	Client public IPv4
reverse-kcp.3	transport_port	port	4000	Tunnel (transport) port
reverse-kcp.3	final_port	port	80	Final service port (on the server)
reverse-kcp.3	min_held_connections	int	8	Pre-opened idle reverse connections
reverse-kcp.3	mux_connections_per_worker	int	2	Mux connections per worker
reverse-quic.0	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
reverse-quic.0	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
reverse-quic.0	server_ip	cidr32	"198.51.100.20/32"	Server public IPv4
reverse-quic.0	user_port	port	443	Port users connect to
reverse-quic.0	transport_port	port	4433	Tunnel (transport) port
reverse-quic.1	client_ip	ip	"192.0.2.10"	Client public IPv4
reverse-quic.1	transport_port	port	4433	Tunnel (transport) port
reverse-quic.1	domain_to_handshake_quic	domain	"tunnel.example.com"	QUIC SNI / certificate domain
reverse-quic.1	final_port	port	80	Final service port (on the server)
reverse-quic.1	min_held_connections	int	8	Pre-opened idle reverse connections
reverse-quic.2	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
reverse-quic.2	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
reverse-quic.2	server_ip	cidr32	"198.51.100.20/32"	Server public IPv4
reverse-quic.2	user_port	port	443	Port users connect to
reverse-quic.2	transport_port	port	4433	Tunnel (transport) port
reverse-quic.3	client_ip	ip	"192.0.2.10"	Client public IPv4
reverse-quic.3	transport_port	port	4433	Tunnel (transport) port
reverse-quic.3	domain_to_handshake_quic	domain	"tunnel.example.com"	QUIC SNI / certificate domain
reverse-quic.3	final_port	port	80	Final service port (on the server)
reverse-quic.3	min_held_connections	int	8	Pre-opened idle reverse connections
reverse-quic.3	mux_connections_per_worker	int	2	Mux connections per worker
reverse-reality.0	ip_behind_domain_white	ip	"203.0.113.30"	IP of the real website for non-authenticated visitors
reverse-reality.0	server_ip	cidr32	"198.51.100.20/32"	Server public IPv4
reverse-reality.0	shared_port	port	443	Port for users AND for the server to connect back
reverse-reality.0	password	secret	"REPLACE_WITH_SHARED_PASSWORD"	Shared password (same on both sides)
reverse-reality.1	client_ip	ip	"192.0.2.10"	Client public IPv4
reverse-reality.1	client_tunnel_port	port	443	Client tunnel port to connect to
reverse-reality.1	domain_to_handshake_reality	domain	"visitor.example.com"	Reality SNI (real website)
reverse-reality.1	password	secret	"REPLACE_WITH_SHARED_PASSWORD"	Shared password (same on both sides)
reverse-reality.1	final_port	port	80	Final service port (on the server)
reverse-reality.1	min_held_connections	int	8	Pre-opened idle reverse connections
reverse-reality.2	ip_behind_domain_white	ip	"203.0.113.30"	IP of the real website for non-authenticated visitors
reverse-reality.2	server_ip	cidr32	"198.51.100.20/32"	Server public IPv4
reverse-reality.2	shared_port	port	443	Port for users AND for the server to connect back
reverse-reality.2	password	secret	"REPLACE_WITH_SHARED_PASSWORD"	Shared password (same on both sides)
reverse-reality.3	client_ip	ip	"192.0.2.10"	Client public IPv4
reverse-reality.3	client_tunnel_port	port	443	Client tunnel port to connect to
reverse-reality.3	domain_to_handshake_reality	domain	"visitor.example.com"	Reality SNI (real website)
reverse-reality.3	password	secret	"REPLACE_WITH_SHARED_PASSWORD"	Shared password (same on both sides)
reverse-reality.3	final_port	port	80	Final service port (on the server)
reverse-reality.3	min_held_connections	int	8	Pre-opened idle reverse connections
reverse-reality.3	mux_connections_per_worker	int	2	Mux connections per worker
reverse-tls.0	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
reverse-tls.0	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
reverse-tls.0	server_ip	cidr32	"198.51.100.20/32"	Server public IPv4
reverse-tls.0	shared_port	port	443	Port for users AND for the server to connect back
reverse-tls.1	client_ip	ip	"192.0.2.10"	Client public IPv4
reverse-tls.1	client_tunnel_port	port	443	Client tunnel port to connect to
reverse-tls.1	domain_to_handshake_tls	domain	"tunnel.example.com"	TLS SNI / certificate domain
reverse-tls.1	final_port	port	80	Final service port (on the server)
reverse-tls.1	min_held_connections	int	8	Pre-opened idle reverse connections
reverse-tls.2	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
reverse-tls.2	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
reverse-tls.2	server_ip	cidr32	"198.51.100.20/32"	Server public IPv4
reverse-tls.2	shared_port	port	443	Port for users AND for the server to connect back
reverse-tls.3	client_ip	ip	"192.0.2.10"	Client public IPv4
reverse-tls.3	client_tunnel_port	port	443	Client tunnel port to connect to
reverse-tls.3	domain_to_handshake_tls	domain	"tunnel.example.com"	TLS SNI / certificate domain
reverse-tls.3	final_port	port	80	Final service port (on the server)
reverse-tls.3	min_held_connections	int	8	Pre-opened idle reverse connections
reverse-tls.3	mux_connections_per_worker	int	2	Mux connections per worker
kcp.0	local-socks.address	host	"127.0.0.1"	Listen address (local-socks)
kcp.0	local-socks.port	port	1080	Listen port (local-socks)
kcp.0	shared.uuid	uuid	"11111111-2222-4333-8444-555555555555"	UUID (must match on both sides)
kcp.0	shared.domain	domain	"tunnel.example.com"	TLS / HTTP domain (SNI, Host, certificate)
kcp.0	server.address	host	""	Server address (server)
kcp.0	server.port	port	4000	Server port (server)
kcp.1	kcp-in.address	host	"0.0.0.0"	Listen address (kcp-in)
kcp.1	kcp-in.port	port	4000	Listen port (kcp-in)
kcp.1	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
kcp.1	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
kcp.1	shared.uuid	uuid	"11111111-2222-4333-8444-555555555555"	UUID (must match on both sides)
local-proxies.0	local-listener.address	host	"127.0.0.1"	Listen address (local-listener)
local-proxies.0	local-listener.port	port	1080	Listen port (local-listener)
local-proxies.1	local-listener.address	host	"127.0.0.1"	Listen address (local-listener)
local-proxies.1	local-listener.port	port	8080	Listen port (local-listener)
protocol-proxies.0	local-socks.address	host	"127.0.0.1"	Listen address (local-socks)
protocol-proxies.0	local-socks.port	port	1080	Listen port (local-socks)
protocol-proxies.0	shared.uuid	uuid	"11111111-2222-4333-8444-555555555555"	UUID (must match on both sides)
protocol-proxies.0	shared.domain	domain	"tunnel.example.com"	TLS / HTTP domain (SNI, Host, certificate)
protocol-proxies.0	server.address	host	""	Server address (server)
protocol-proxies.0	server.port	port	443	Server port (server)
protocol-proxies.1	public-tls.address	host	"0.0.0.0"	Listen address (public-tls)
protocol-proxies.1	public-tls.port	port	443	Listen port (public-tls)
protocol-proxies.1	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
protocol-proxies.1	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
protocol-proxies.1	shared.uuid	uuid	"11111111-2222-4333-8444-555555555555"	UUID (must match on both sides)
protocol-proxies.2	local-socks.address	host	"127.0.0.1"	Listen address (local-socks)
protocol-proxies.2	local-socks.port	port	1080	Listen port (local-socks)
protocol-proxies.2	shared.uuid	uuid	"11111111-2222-4333-8444-555555555555"	UUID (must match on both sides)
protocol-proxies.2	shared.domain	domain	"tunnel.example.com"	TLS / HTTP domain (SNI, Host, certificate)
protocol-proxies.2	server.address	host	""	Server address (server)
protocol-proxies.2	server.port	port	443	Server port (server)
protocol-proxies.3	public-tls.address	host	"0.0.0.0"	Listen address (public-tls)
protocol-proxies.3	public-tls.port	port	443	Listen port (public-tls)
protocol-proxies.3	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
protocol-proxies.3	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
protocol-proxies.3	shared.uuid	uuid	"11111111-2222-4333-8444-555555555555"	UUID (must match on both sides)
protocol-proxies.4	local-socks.address	host	"127.0.0.1"	Listen address (local-socks)
protocol-proxies.4	local-socks.port	port	1080	Listen port (local-socks)
protocol-proxies.4	shared.password	secret	"replace-with-a-strong-password"	Password (must match on both sides)
protocol-proxies.4	shared.domain	domain	"tunnel.example.com"	TLS / HTTP domain (SNI, Host, certificate)
protocol-proxies.4	server.address	host	""	Server address (server)
protocol-proxies.4	server.port	port	443	Server port (server)
protocol-proxies.5	public-tls.address	host	"0.0.0.0"	Listen address (public-tls)
protocol-proxies.5	public-tls.port	port	443	Listen port (public-tls)
protocol-proxies.5	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
protocol-proxies.5	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
protocol-proxies.5	shared.password	secret	"replace-with-a-strong-password"	Password (must match on both sides)
quic.0	local-socks.address	host	"127.0.0.1"	Listen address (local-socks)
quic.0	local-socks.port	port	1080	Listen port (local-socks)
quic.0	shared.uuid	uuid	"11111111-2222-4333-8444-555555555555"	UUID (must match on both sides)
quic.0	shared.domain	domain	"tunnel.example.com"	TLS / HTTP domain (SNI, Host, certificate)
quic.0	server.address	host	""	Server address (server)
quic.0	server.port	port	4433	Server port (server)
quic.1	quic-in.address	host	"0.0.0.0"	Listen address (quic-in)
quic.1	quic-in.port	port	4433	Listen port (quic-in)
quic.1	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
quic.1	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
quic.1	shared.uuid	uuid	"11111111-2222-4333-8444-555555555555"	UUID (must match on both sides)
rtmp.0	local-socks.address	host	"127.0.0.1"	Listen address (local-socks)
rtmp.0	local-socks.port	port	1080	Listen port (local-socks)
rtmp.0	shared.uuid	uuid	"11111111-2222-4333-8444-555555555555"	UUID (must match on both sides)
rtmp.0	rtmp.tc-url	str	"rtmps://tunnel.example.com:443/waterwall"	RTMP tc-url
rtmp.0	shared.domain	domain	"tunnel.example.com"	TLS / HTTP domain (SNI, Host, certificate)
rtmp.0	carrier.address	host	""	Server address (carrier)
rtmp.0	carrier.port	port	443	Server port (carrier)
rtmp.1	carrier.address	host	"0.0.0.0"	Listen address (carrier)
rtmp.1	carrier.port	port	443	Listen port (carrier)
rtmp.1	shared.domain	domain	"tunnel.example.com"	TLS / HTTP domain (SNI, Host, certificate)
rtmp.1	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
rtmp.1	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
rtmp.1	shared.uuid	uuid	"11111111-2222-4333-8444-555555555555"	UUID (must match on both sides)
socks-mux.0	local-listener.address	host	"127.0.0.1"	Listen address (local-listener)
socks-mux.0	local-listener.port	port	1080	Listen port (local-listener)
socks-mux.0	shared.uuid	uuid	"11111111-2222-4333-8444-555555555555"	UUID (must match on both sides)
socks-mux.0	shared.domain	domain	"tunnel.example.com"	TLS / HTTP domain (SNI, Host, certificate)
socks-mux.0	remote-server.address	host	""	Server address (remote-server)
socks-mux.0	remote-server.port	port	443	Server port (remote-server)
socks-mux.1	public-listener.address	host	"0.0.0.0"	Listen address (public-listener)
socks-mux.1	public-listener.port	port	443	Listen port (public-listener)
socks-mux.1	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
socks-mux.1	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
socks-mux.1	shared.uuid	uuid	"11111111-2222-4333-8444-555555555555"	UUID (must match on both sides)
socks5-rtmp-reality.0	socks_address	ip	"127.0.0.1"	Local SOCKS5 listen address
socks5-rtmp-reality.0	socks_port	port	1080	Local SOCKS5 port
socks5-rtmp-reality.0	server_address	ip	"198.51.100.20"	Server address
socks5-rtmp-reality.0	rtmp_port	port	1935	RTMP port
socks5-rtmp-reality.0	rtmp_url	str	"rtmp://198.51.100.20:1935/waterwall"	RTMP tc-url
socks5-rtmp-reality.0	reality_port	port	443	Reality port
socks5-rtmp-reality.0	reality_sni	domain	"example.com"	Reality SNI (real website)
socks5-rtmp-reality.0	reality_password	secret	"replace-with-reality-secret"	Reality password (same on both sides)
socks5-rtmp-reality.0	trojan_password	secret	"replace-with-trojan-password"	Trojan password
socks5-rtmp-reality.0	mux_connections_per_worker	int	1	Mux connections per worker
socks5-rtmp-reality.0	stripe_connections	int	8	Parallel connections per stream
socks5-rtmp-reality.0	obfuscator_key	int	90	XOR obfuscator key (0-255)
socks5-rtmp-reality.1	listen_address	host	"0.0.0.0"	Listen address
socks5-rtmp-reality.1	rtmp_port	port	1935	RTMP port
socks5-rtmp-reality.1	reality_port	port	443	Reality port
socks5-rtmp-reality.1	reality_sni	domain	"example.com"	Reality SNI (real website)
socks5-rtmp-reality.1	reality_password	secret	"replace-with-reality-secret"	Reality password (same on both sides)
socks5-rtmp-reality.1	trojan_password	secret	"replace-with-trojan-password"	Trojan password
socks5-rtmp-reality.1	stripe_connections	int	8	Parallel connections per stream
socks5-rtmp-reality.1	obfuscator_key	int	90	XOR obfuscator key (0-255)
websocket.0	local-socks.address	host	"127.0.0.1"	Listen address (local-socks)
websocket.0	local-socks.port	port	1080	Listen port (local-socks)
websocket.0	shared.uuid	uuid	"11111111-2222-4333-8444-555555555555"	UUID (must match on both sides)
websocket.0	shared.domain	domain	"tunnel.example.com"	TLS / HTTP domain (SNI, Host, certificate)
websocket.0	shared.ws-path	str	"/vmess"	WebSocket path (same on both sides)
websocket.0	server.address	host	""	Server address (server)
websocket.0	server.port	port	443	Server port (server)
websocket.1	public-tls.address	host	"0.0.0.0"	Listen address (public-tls)
websocket.1	public-tls.port	port	443	Listen port (public-tls)
websocket.1	certificate_path	path	"/etc/waterwall/fullchain.pem"	TLS certificate (fullchain) path
websocket.1	key_path	path	"/etc/waterwall/privkey.pem"	TLS private key path
websocket.1	shared.domain	domain	"tunnel.example.com"	TLS / HTTP domain (SNI, Host, certificate)
websocket.1	shared.ws-path	str	"/vmess"	WebSocket path (same on both sides)
websocket.1	shared.uuid	uuid	"11111111-2222-4333-8444-555555555555"	UUID (must match on both sides)
__WWVAR__
)

tpl_family_list() { cut -f1 <<<"$WW_FAMILIES"; }
tpl_family_field() { awk -F'\t' -v f="$1" -v n="$2" '$1==f{print $n; exit}' <<<"$WW_FAMILIES"; }
tpl_variants() { awk -F'\t' -v f="$1" '$2==f && !s[$3]++{print $3}' <<<"$WW_TEMPLATES"; }
tpl_roles()    { awk -F'\t' -v f="$1" -v v="$2" '$2==f && $3==v{print $4}' <<<"$WW_TEMPLATES"; }
tpl_pick()     { awk -F'\t' -v f="$1" -v v="$2" -v r="$3" '$2==f && $3==v && $4==r{print $1; exit}' <<<"$WW_TEMPLATES"; }
tpl_field()    { awk -F'\t' -v id="$1" -v n="$2" '$1==id{print $n; exit}' <<<"$WW_TEMPLATES"; }
tpl_vars()     { awk -F'\t' -v id="$1" '$1==id' <<<"$WW_TPLVARS"; }
role_label() {
  case $1 in client) echo "CLIENT (entry, users connect here)";; server) echo "SERVER (exit, final service runs here)";;
    *) echo "Single server";; esac
}
counter_role() { case $1 in client) echo server;; server) echo client;; *) echo "";; esac; }

DEMO_IPS=" 192.0.2.10 198.51.100.20 198.51.100.10 203.0.113.30 "
is_demo_val() { [[ $DEMO_IPS == *" $1 "* || $1 == REPLACE_WITH* || $1 == replace-with* || $1 == 11111111-2222-* || $1 == 5783a3e7-* ]]; }

# Prompts all variables of template $1 (role $2). Fills TVJ[var] (JSON values) and SHARE (array).
tpl_prompt_vars() {
  local tid=$1 role=$2 var type def label d v prompt_def k
  declare -gA TVJ=() TVRAW=(); declare -gA REPL=(); SHARE=()
  local cert_done=0
  while IFS=$'\t' read -r -u 3 _ var type def label; do
    [[ -z $var ]] && continue
    d=$(jq -r 'if type=="string" then . else tojson end' <<<"$def")
    prompt_def=$d
    # smart defaults
    case $var in
      client_ip) [[ $role == client ]] && prompt_def=$(public_ip);;
      server_ip) [[ $role == server ]] && prompt_def=$(public_ip);;
    esac
    if [[ $prompt_def == "$d" ]] && is_demo_val "$d"; then
      case $type in secret) prompt_def=$(rand_pass 24);; uuid) prompt_def=$(new_uuid);; *) prompt_def="";; esac
    fi
    if [[ $type == str && -n $prompt_def ]]; then  # follow earlier answers (e.g. IPs inside an RTMP URL)
      for k in "${!REPL[@]}"; do prompt_def=${prompt_def//"$k"/"${REPL[$k]}"}; done
    fi
    [[ $type == cidr32 ]] && prompt_def=${prompt_def%/32}
    if [[ $var == *reality* || $var == visitor_domain ]] && [[ $type == domain && $prompt_def == *example.com ]]; then
      prompt_def=www.speedtest.net   # Reality must imitate a real, reachable TLS site
    fi
    case $var in
      certificate_path)
        local dom=""; for k in shared.domain tls_name domain_to_handshake_tls domain_to_handshake_quic; do
          [[ -n ${TVRAW[$k]:-} ]] && { dom=${TVRAW[$k]}; break; }; done
        [[ -z $dom ]] && ask dom "Certificate domain" "www.example.com" is_domain
        cert_setup "$dom" || return 1
        TVJ[certificate_path]=$(json_str "$CERT_FILE"); TVJ[key_path]=$(json_str "$KEY_FILE"); cert_done=1; continue;;
      key_path) ((cert_done)) && continue;;
      visitor_ip|ip_behind_domain_white)
        local vh; ask vh "$label (domain or IP)" "${prompt_def:-www.speedtest.net}" is_host
        if ! is_ip "$vh"; then v=$(resolve4 "$vh"); [[ -n $v ]] || ask v "Could not resolve $vh; enter its IPv4" "" is_ipv4; else v=$vh; fi
        TVJ[$var]=$(json_str "$v"); TVRAW[$var]=$v; continue;;
    esac
    ask v "$label" "$prompt_def" "$(tpl_validator "$type" "$var")"
    TVRAW[$var]=$v
    case $type in
      port|int) TVJ[$var]=$((10#$v));;
      json|bool) TVJ[$var]=$(jq -c . <<<"$v");;
      cidr32) TVJ[$var]=$(json_str "${v%/*}/32");;
      *) TVJ[$var]=$(json_str "$v");;
    esac
    # remember replacements so later string defaults follow (e.g. tc-url host/port)
    if [[ -n $d && $d != "$v" ]]; then
      case $type in ip|host|domain) REPL[$d]=$v;; port) REPL[":$d/"]=":$v/";; esac
    fi
    case $type in secret|uuid|domain) SHARE+=("$var=$v");; esac
    case $var in obfuscator_key|protoswap_tcp_to_number|fake_server_port|fake_client_ports|stripe_connections|*mux*|shared.ws-path) SHARE+=("$var=$v");; esac
  done 3< <(tpl_vars "$tid")
}
is_bool() { [[ $1 == true || $1 == false ]]; }
tpl_validator() { # type var -> name of the validator function for that prompt
  case $2 in obfuscator_key) echo is_byte; return;; *tun_name*) echo is_ifname; return;; esac
  case $1 in
    ip|cidr32) echo is_ip;; host) echo is_host;; cidr) echo is_cidr;; port) echo is_port;; int) echo is_uint;;
    json) echo is_json;; domain) echo is_domain;; uuid) echo is_uuid;; secret) echo is_secret32;;
    path) echo is_file;; bool) echo is_bool;; *) echo is_safe_str;;
  esac
}

tpl_render() { # tid -> stdout rendered compact json
  local content var; content=$(tpl_field "$1" 6)
  for var in "${!TVJ[@]}"; do content=${content//"\"__V_${var}__\""/"${TVJ[$var]}"}; done
  if [[ $content == *'"__V_'* ]]; then err "Unfilled template variable."; return 1; fi
  printf '%s' "$content"
}

# Runs the official-template flow; fills NODES_JSON etc. for tunnel_finalize.
gen_template() {
  need_jq
  local -a fams titles; mapfile -t fams < <(tpl_family_list)
  local f; for f in "${fams[@]}"; do titles+=("$(tpl_family_field "$f" 2)"); done
  local c; choose c "Official template family:" "${titles[@]}"
  local fam=${fams[$((c-1))]} note; note=$(tpl_family_field "$fam" 3)
  [[ -n $note ]] && warn "${note#raw: }"
  local -a vars; mapfile -t vars < <(tpl_variants "$fam")
  local variant=${vars[0]}
  if ((${#vars[@]} > 1)); then choose c "Variant:" "${vars[@]}"; variant=${vars[$((c-1))]}; fi
  local -a roles rl; mapfile -t roles < <(tpl_roles "$fam" "$variant")
  local r; for r in "${roles[@]}"; do rl+=("$(role_label "$r")"); done
  ROLE=${roles[0]}
  if ((${#roles[@]} > 1)); then choose c "Which side is this server?" "${rl[@]}"; ROLE=${roles[$((c-1))]}; fi
  local tid; tid=$(tpl_pick "$fam" "$variant" "$ROLE")
  [[ -n $tid ]] || { err "Template not found."; return 1; }
  if [[ $note == raw:* ]]; then
    prereq_raw_check
    confirm "Continue with this raw-socket template?" y || return 1
  fi
  tpl_prompt_vars "$tid" "$ROLE" || return 1
  local json; json=$(tpl_render "$tid") || return 1
  # client-side certificate verification for TLS/QUIC clients
  if jq -e 'any(.nodes[]; .type=="TlsClient" or .type=="QuicClient")' >/dev/null <<<"$json"; then
    local vf=false; confirm "Is the server certificate self-signed (verify=false)?" y || vf=true
    json=$(jq -c --argjson v "$vf" '(.nodes[] | select(.type=="TlsClient" or .type=="QuicClient") | .settings.verify) = $v' <<<"$json")
  fi
  if [[ $fam == tunnels/halfduplex-split-transports && $ROLE == client ]] && confirm "Swap directions (upload over KCP, download over TLS)?" n; then
    json=$(jq -c '(.nodes[] | select(.type=="HalfDuplexClient") | .settings) |= {upload: .download, download: .upload}' <<<"$json")
  fi
  TEMPLATE_JSON=$json; CORE_MTU=$(tpl_field "$tid" 5); MODE="tpl:$tid"
  META+=("FAMILY=$fam" "VARIANT=$variant" "TEMPLATE=$tid")
  local s; for s in "${SHARE[@]}"; do META+=("SHARE_$s"); done
  if [[ $ROLE == client || $ROLE == single ]]; then
    if confirm "Add a user bandwidth limit (SpeedLimit) on the entry listener?" n; then TPL_SPEEDLIMIT=1; fi
  fi
  PREBUILT=2
}

# ----------------------------------------------------------------------------
# [MODULE] custom import
# ----------------------------------------------------------------------------
gen_import() {
  local d="$WW_TUNNELS/$TNAME" c src tmp; tmp=$(mktemp)
  choose c "Import config from:" "A file on this server" "Paste JSON here (finish with a line containing only END)"
  if [[ $c == 1 ]]; then ask src "Path to config JSON" "" is_file; cp "$src" "$tmp"
  else
    info "Paste now:"; local l
    while IFS= read -r l; do [[ $l == END ]] && break; printf '%s\n' "$l" >>"$tmp"; done
  fi
  local problems; problems=$(config_check "$tmp")
  if [[ -n $problems ]]; then
    err "Config problems:"; sed 's/^/   - /' <<<"$problems"
    confirm "Import anyway?" n || { rm -f "$tmp"; return 1; }
  fi
  mkdir -p "$d/logs"; cp "$tmp" "$d/config.json"; rm -f "$tmp"
  ask CORE_MTU "core.json MTU (1400 for raw-socket/TUN tunnels, otherwise 1500)" "1500" is_num
  ROLE=custom; PREBUILT=1
}

# ----------------------------------------------------------------------------
# [MODULE] tunnel manager
# ----------------------------------------------------------------------------
tunnel_list_names() { [[ -d $WW_TUNNELS ]] && find "$WW_TUNNELS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort; }
tunnel_count() { local c; c=$(tunnel_list_names | grep -c .); echo "${c:-0}"; }
meta_get() { grep -m1 "^$2=" "$WW_TUNNELS/$1/tunnel.meta" 2>/dev/null | cut -d= -f2-; }

svc_state() {
  if has_systemd; then systemctl is-active "waterwall@$1" 2>/dev/null; else echo "n/a"; fi
}

tunnel_create() {
  core_bin >/dev/null || { warn "Core not installed yet."; if confirm "Install now?" y; then core_install || return 1; else return 1; fi; }
  need_jq
  local c
  choose c "How do you want to create the tunnel?" \
    "Quick wizard (15 guided modes: TCP/TLS/Reality/QUIC/KCP, Ping, FakeTCP, WireGuard, API)" \
    "Official templates (all 86 configs from the docs: BitSwap, ProtoSwap, BGP4, RTMP, HalfDuplex, Stripe, VLESS/VMess/Trojan, SOCKS/HTTP, WebSocket, TUN ...)" \
    "Import my own config.json" "Back"
  [[ $c == 4 ]] && return 0
  local how=$c
  ask TNAME "Tunnel name (a-z, 0-9, - _)" "tun$(( $(tunnel_count) + 1 ))" is_new_tunnel
  local d="$WW_TUNNELS/$TNAME"
  # remove the half-created tunnel if the wizard is interrupted (Ctrl+C, closed input, error)
  WW_CREATING=$d
  trap 'create_abort' INT TERM
  trap 'create_abort_exit' EXIT
  # reset per-run globals
  NODES=(); META=(); CORE_MTU=1500; SNI=""; VISITOR_HOST=""; PASSWORD=""; VERIFY=true; MUX=0; ENC=0; ENC_PASS=""; FEC=0
  SL_MBPS=0; SL_MODE=all-lines; PREBUILT=0; TEMPLATE_JSON=""; TPL_SPEEDLIMIT=0; ROLE=client; MODE=""
  mkdir -p "$d"
  local rc=0
  case $how in
    1)
      local -a labels=(); local m; for m in "${MODES[@]}"; do labels+=("${m#*|}"); done
      choose c "Tunnel type:" "${labels[@]}"
      MODE=${MODES[$((c-1))]%%|*}
      case $MODE in
        portfwd|wireguard|authapi) ROLE=single;;
        *) local r; choose r "Which server is this?" "CLIENT (entry, users connect here)" "SERVER (exit, final service runs here)"
           [[ $r == 2 ]] && ROLE=server;;
      esac
      case $MODE in
        portfwd)          gen_portfwd;;
        direct-tcp)       gen_direct tcp;;
        direct-tls)       gen_direct tls;;
        direct-reality)   gen_direct reality;;
        direct-quic)      gen_direct quic;;
        direct-kcp)       gen_direct kcp;;
        reverse-tcp)      gen_reverse tcp;;
        reverse-tls)      gen_reverse tls;;
        reverse-reality)  gen_reverse reality;;
        reverse-quic)     gen_reverse quic;;
        reverse-kcp)      gen_reverse kcp;;
        ping)             gen_ping;;
        faketcp)          gen_faketcp;;
        wireguard)        gen_wireguard;;
        authapi)          gen_authapi;;
      esac || rc=1;;
    2) gen_template || rc=1;;
    3) MODE=custom; gen_import || rc=1;;
  esac
  if (( rc )); then rm -rf "${d:?}"; WW_CREATING=""; trap - INT TERM EXIT; warn "Cancelled."; return 1; fi
  tunnel_finalize; local frc=$?
  WW_CREATING=""; trap - INT TERM EXIT
  return $frc
}
create_abort_exit() { [[ -n ${WW_CREATING:-} && -d $WW_CREATING ]] && rm -rf "${WW_CREATING:?}"; }
create_abort() { echo; create_abort_exit; WW_CREATING=""; warn "Interrupted — nothing was created."; exit 130; }

# Writes config/core/meta, validates, opens firewall, installs service, optionally starts.
tunnel_finalize() {
  local d="$WW_TUNNELS/$TNAME"
  mkdir -p "$d/logs"
  case $PREBUILT in
    0) write_config "$d/config.json" "$TNAME-$MODE-$ROLE" "${NODES[@]}";;
    2) jq --arg n "$TNAME-${MODE#tpl:}-$ROLE" '{name: $n, author: "waterwall-manager (official template)"} + del(.name)' \
         <<<"$TEMPLATE_JSON" >"$d/config.json";;
  esac
  [[ -n $SNI ]] && META+=("SNI=$SNI")
  [[ -n ${VISITOR_HOST:-} ]] && META+=("VISITOR_SITE=$VISITOR_HOST")
  [[ -n $PASSWORD ]] && META+=("PASSWORD=$PASSWORD")
  (( MUX )) && META+=("MUX=$MUX_N")
  (( ENC )) && META+=("ENCRYPTION=$ENC_PASS")
  (( FEC )) && META+=("KCP_FEC=on")
  write_core "$d" "$CORE_MTU" server
  { printf 'MODE=%s\nROLE=%s\nCREATED=%s\n' "$MODE" "$ROLE" "$(date +%F)"; printf '%s\n' "${META[@]}"; } >"$d/tunnel.meta"
  chmod 600 "$d/tunnel.meta" "$d/config.json"
  # user bandwidth limit
  if (( 10#${SL_MBPS:-0} > 0 )); then
    speed_limit_set "$d/config.json" users_inbound "$((10#$SL_MBPS))" "$SL_MODE" \
      && printf 'SPEED_LIMIT=%s MB/s (%s)\n' "$((10#$SL_MBPS))" "$SL_MODE" >>"$d/tunnel.meta"
  fi
  if (( TPL_SPEEDLIMIT )); then tunnel_speed_limit_menu_nosvc "$TNAME"; fi
  local problems=""
  if [[ $MODE != custom ]]; then
    validate_json "$d/core.json" || problems="core.json invalid"
    problems+=$(config_check "$d/config.json")
    if [[ -n $problems ]]; then err "Generated config failed self-check (please report):"; echo "$problems"; return 1; fi
  fi
  ok "Tunnel '$TNAME' created  ($(mode_desc "$MODE"), role: ${ROLE^^})"
  firewall_open "$TNAME"
  service_install_unit
  if confirm "Start '$TNAME' now and enable on boot?" y; then svc enable "$TNAME"; svc restart "$TNAME"; fi
  tunnel_info "$TNAME"
  [[ $MODE == wireguard ]] && wg_show_client "$TNAME" "$WG_LAST"
  [[ $MODE == authapi ]] && authapi_help "$TNAME"
  return 0
}

tunnel_speed_limit_menu_nosvc() { # same as menu but no restart (used during creation)
  local n=$1 f="$WW_TUNNELS/$1/config.json"
  local -a ls; mapfile -t ls < <(listener_nodes "$f")
  ((${#ls[@]})) || return 0
  local c l mb m; choose c "Apply limit to which inbound (the one users connect to):" "${ls[@]}"; l=${ls[$((c-1))]}
  ask mb "Limit in MB/s" "10" is_num
  choose m "Limit applies to:" "All users together (total)" "Each connection separately"
  speed_limit_set "$f" "$l" "$((10#$mb))" "$([[ $m == 1 ]] && echo all-lines || echo per-line)"
  printf 'SPEED_LIMIT=%s MB/s on %s\n' "$mb" "$l" >>"$WW_TUNNELS/$n/tunnel.meta"
}

authapi_help() {
  local n=$1
  line
  printf '%sManagement API%s  listen: %s   client: admin\n' "$C_W" "$C_0" "$(meta_get "$n" API)"
  printf '  Token file : %s\n' "$(meta_get "$n" API_TOKEN_FILE)"
  printf '  Users DB   : %s\n' "$WW_TUNNELS/$n/users.json"
  printf '  Config name: %s   node: auth-db\n' "$n"
  echo   "  Use the official Python client from the WaterWall source tree:"
  printf '    python3 tunnels/APIServer/examples/api_client.py --host %s --port %s \\\n' "$(meta_get "$n" API | cut -d: -f1)" "$(meta_get "$n" API | cut -d: -f2)"
  printf '      --client admin --token-file %s --config %s --node auth-db --operation status\n' "$(meta_get "$n" API_TOKEN_FILE)" "$n"
  echo   "  Allowed operations: status, get-user, list-users, create-user, update-user, change-user-password"
  line
}

tunnel_info() {
  local n=$1 d="$WW_TUNNELS/$1"
  [[ -d $d ]] || { err "No such tunnel: $n"; return 1; }
  line
  printf '%sTunnel:%s %s   %sstate:%s %s\n' "$C_W" "$C_0" "$n" "$C_W" "$C_0" "$(svc_state "$n")"
  grep -vE '^(SHARE_|PASSWORD=|ENCRYPTION=)' "$d/tunnel.meta" | sed 's/^/  /'
  printf '  config: %s\n' "$d/config.json"
  local mode role cr; mode=$(meta_get "$n" MODE); role=$(meta_get "$n" ROLE); cr=$(counter_role "$role")
  if [[ -n $cr ]]; then
    local how="the same quick-wizard type ($mode)"
    [[ $mode == tpl:* ]] && how="the same official template ($(meta_get "$n" FAMILY), variant: $(meta_get "$n" VARIANT))"
    printf '\n%sOn the other server%s create %s with role %s, using the SAME values:\n' "$C_Y" "$C_0" "$how" "${cr^^}"
    grep -E '^(SNI|PASSWORD|MUX|ENCRYPTION|KCP_FEC|SHARE_.*)=' "$d/tunnel.meta" | sed -e 's/^SHARE_//' -e 's/^/   • /'
    echo "   • matching ports / IPs"
  fi
  line
}

tunnel_list() {
  local n any=0
  printf '%s%-16s %-24s %-7s %-9s %s%s\n' "$C_W" NAME MODE ROLE STATE DETAILS "$C_0"
  while read -r n; do
    [[ -z $n ]] && continue; any=1
    local st; st=$(svc_state "$n"); local col=$C_R; [[ $st == active ]] && col=$C_G
    printf '%-16s %-24s %-7s %s%-9s%s %s\n' "$n" "$(meta_get "$n" MODE | cut -c1-24)" "$(meta_get "$n" ROLE)" \
      "$col" "$st" "$C_0" "$(grep -E '^(USER_PORT|TRANSPORT_PORT|PEER|FINAL|WG_PORT|API)=' "$WW_TUNNELS/$n/tunnel.meta" | tr '\n' ' ')"
  done < <(tunnel_list_names)
  ((any)) || info "No tunnels yet — choose 'Create new tunnel'."
}

pick_tunnel() { # VAR
  local -a arr; mapfile -t arr < <(tunnel_list_names)
  ((${#arr[@]})) || { warn "No tunnels."; return 1; }
  local c; choose c "Select tunnel:" "${arr[@]}"; printf -v "$1" '%s' "${arr[$((c-1))]}"
}

tunnel_edit() {
  local n=$1 f="$WW_TUNNELS/$1/config.json" bak
  bak=$(mktemp); cp "$f" "$bak"
  local ed=${EDITOR:-$(command -v nano || command -v vi || echo vi)}
  $ed "$f"   # unquoted on purpose: EDITOR may contain arguments (e.g. "code --wait")
  local problems; problems=$(config_check "$f")
  if [[ -z $problems ]]; then ok "Config looks valid."; svc restart "$n"
  else
    err "Problems found:"; sed 's/^/   - /' <<<"$problems"
    if confirm "Revert to the previous version?" y; then cp "$bak" "$f"; ok "Reverted."; else svc restart "$n"; fi
  fi
  rm -f "$bak"
}

tunnel_delete() {
  local n=$1
  is_name "$n" || { err "Invalid tunnel name"; return 1; }
  [[ -d "$WW_TUNNELS/$n" ]] || { err "No such tunnel: $n"; return 1; }
  confirm "Delete tunnel '$n' permanently?" n || return
  svc stop "$n"; svc disable "$n"
  [[ -f $CRON_FILE ]] && sed -i "/ww-restart $n\$/d" "$CRON_FILE"
  rm -rf "${WW_TUNNELS:?}/$n"; ok "Deleted $n"
}

tunnel_logs() {
  local n=$1 c
  choose c "Logs for $n:" "Live journal (Ctrl+C to exit)" "Last 100 journal lines" "core.log (tail)" "network.log (tail)" "Back"
  case $c in
    1) has_systemd && journalctl -u "waterwall@$n" -f -n 50 --no-pager;;
    2) has_systemd && journalctl -u "waterwall@$n" -n 100 --no-pager; pause;;
    3) tail -n 100 "$WW_TUNNELS/$n/logs/core.log" 2>/dev/null || warn "no file"; pause;;
    4) tail -n 100 "$WW_TUNNELS/$n/logs/network.log" 2>/dev/null || warn "no file"; pause;;
  esac
}

config_listeners() { # FILE -> "proto port address" per listener
  quote_placeholders "$1" | jq -r '.nodes[] | select(.type | test("Listener$")) |
    [ (if .type=="UdpListener" then "udp" elif .type=="TcpUdpListener" then "both" else "tcp" end),
      (.settings.port|tostring), ((.settings.address // "0.0.0.0")|tostring) ] | @tsv' 2>/dev/null
}

tunnel_health() {
  local n=$1 proto p a socks
  info "Service: $(svc_state "$n")"
  socks=$(ss -Hlntu 2>/dev/null | awk '{print $5}')
  while IFS=$'\t' read -r proto p a; do
    [[ $p =~ ^[0-9]+$ ]] || continue
    if grep -qE "[:.]$p\$" <<<"$socks"; then ok "Listener $a:$p ($proto) is up"
    else warn "Listener $a:$p ($proto) is NOT listening"; fi
  done < <(config_listeners "$WW_TUNNELS/$n/config.json")
  local final; final=$(meta_get "$n" FINAL)
  if [[ -n $final ]]; then
    if timeout 3 bash -c "</dev/tcp/${final%:*}/${final##*:}" 2>/dev/null; then ok "Final service $final reachable"
    else warn "Final service $final NOT reachable (is xray/your app running?)"; fi
  fi
  if [[ $(meta_get "$n" MODE) == wireguard ]]; then
    local tun; tun=$(wg_conf_get "$n" TUN)
    ip link show "$tun" >/dev/null 2>&1 && ok "TUN $tun exists" || warn "TUN $tun missing"
    [[ $(sysctl -n net.ipv4.ip_forward 2>/dev/null) == 1 ]] && ok "IP forwarding on" || warn "IP forwarding off"
  fi
}

tunnel_set_restart_cron() {
  local n=$1 h
  ask h "Auto-restart every N hours (1-24, 0 = disable)" "0" is_hours
  mkdir -p "$(dirname "$CRON_FILE")"; touch "$CRON_FILE"
  sed -i "/ww-restart $n\$/d" "$CRON_FILE"
  h=$((10#$h))
  if (( h == 24 )); then echo "30 4 * * * root systemctl restart waterwall@$n # ww-restart $n" >>"$CRON_FILE"; ok "Will restart daily at 04:30."
  elif (( h > 0 )); then echo "0 */$h * * * root systemctl restart waterwall@$n # ww-restart $n" >>"$CRON_FILE"; ok "Will restart every $h h."
  else ok "Auto-restart disabled."; fi
}

wg_menu() {
  local n=$1 c cl
  while true; do
    choose c "WireGuard clients ($n):" "Add client" "Show client config / QR" "Remove client" "List clients" "Back"
    case $c in
      1) wg_add_client "$n" && { svc restart "$n"; wg_show_client "$n" "$WG_LAST"; }; pause;;
      2) wg_pick_client "$n" cl && wg_show_client "$n" "$cl"; pause;;
      3) wg_remove_client "$n"; pause;;
      4) local p; for p in "$WW_TUNNELS/$n"/wg/peers/*.pub; do [[ -f $p ]] && printf '  %-16s %s\n' "$(basename "$p" .pub)" "$(cat "${p%.pub}.ip")"; done; pause;;
      5) return;;
    esac
  done
}

tunnel_manage() {
  local n; pick_tunnel n || { pause; return; }
  while true; do
    banner; tunnel_info "$n"
    local -a opts=("Start" "Stop" "Restart" "Status" "Logs" "Health check" "Edit config (editor)" "Show config JSON"
                   "Show shared secrets (for the other server)" "Bandwidth limit (SpeedLimit)" "Auto-restart schedule"
                   "Enable on boot" "Disable on boot" "Delete")
    local mode; mode=$(meta_get "$n" MODE)
    [[ $mode == wireguard ]] && opts+=("WireGuard clients")
    [[ $mode == authapi ]] && opts+=("API usage help")
    opts+=("Back")
    local c; choose c "Manage '$n':" "${opts[@]}"
    case ${opts[$((c-1))]} in
      Start) svc start "$n"; pause;; Stop) svc stop "$n"; pause;; Restart) svc restart "$n"; pause;;
      Status) has_systemd && systemctl status "waterwall@$n" --no-pager -l | head -n 25; pause;;
      Logs) tunnel_logs "$n";;
      "Health check") tunnel_health "$n"; pause;;
      "Edit config (editor)") tunnel_edit "$n"; pause;;
      "Show config JSON") jq . "$WW_TUNNELS/$n/config.json" 2>/dev/null || cat "$WW_TUNNELS/$n/config.json"; pause;;
      "Show shared secrets"*) grep -E '^(SNI|PASSWORD|MUX|ENCRYPTION|KCP_FEC|SHARE_.*)=' "$WW_TUNNELS/$n/tunnel.meta" | sed 's/^SHARE_//' || info "None."; pause;;
      "Bandwidth limit (SpeedLimit)") tunnel_speed_limit_menu "$n"; pause;;
      "Auto-restart schedule") tunnel_set_restart_cron "$n"; pause;;
      "Enable on boot") svc enable "$n"; pause;;
      "Disable on boot") svc disable "$n"; pause;;
      Delete) tunnel_delete "$n"; pause; [[ -d "$WW_TUNNELS/$n" ]] || return;;
      "WireGuard clients") wg_menu "$n";;
      "API usage help") authapi_help "$n"; pause;;
      Back) return;;
    esac
  done
}

# ----------------------------------------------------------------------------
# [MODULE] service (systemd)
# ----------------------------------------------------------------------------
service_install_unit() {
  mkdir -p "$SYSTEMD_DIR" "$WW_BIN_DIR"
  cat >"$WW_BIN_DIR/ww-hook" <<HOOK
#!/bin/sh
# Runs per-tunnel post-up.sh / post-down.sh if present (written by waterwall-manager)
f="${WW_TUNNELS}/\$2/post-\$1.sh"
[ -x "\$f" ] || exit 0
[ "\$1" = up ] && sleep 2
"\$f"
exit 0
HOOK
  chmod 755 "$WW_BIN_DIR/ww-hook"
  cat >"$SYSTEMD_DIR/waterwall@.service" <<EOF
[Unit]
Description=WaterWall tunnel %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${WW_TUNNELS}/%i
ExecStart=${WW_BIN_DIR}/Waterwall --config:${WW_TUNNELS}/%i/core.json
ExecStartPost=-${WW_BIN_DIR}/ww-hook up %i
ExecStopPost=-${WW_BIN_DIR}/ww-hook down %i
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
  has_systemd && systemctl daemon-reload
}

svc() { # action name
  local a=$1 n=$2
  has_systemd || { warn "systemd not available (dry-run?) — skipped: $a $n"; return 0; }
  if systemctl "$a" "waterwall@$n" 2>/dev/null; then
    case $a in
      start|restart) sleep 2
        if [[ $(svc_state "$n") == active ]]; then ok "$n is running"
        else err "$n failed to start — last logs:"; journalctl -u "waterwall@$n" -n 15 --no-pager; fi;;
      *) ok "$a $n";;
    esac
  else err "systemctl $a waterwall@$n failed"; fi
}

svc_all() { local n; while read -r n; do [[ -n $n ]] && svc "$1" "$n"; done < <(tunnel_list_names); }

# ----------------------------------------------------------------------------
# [MODULE] firewall (ufw / firewalld, only if active)
# ----------------------------------------------------------------------------
firewall_open() {
  local n=$1 proto p a ports=() x
  while IFS=$'\t' read -r proto p a; do
    [[ $p =~ ^[0-9]+$ ]] || continue
    [[ $a == 127.* || $a == "::1" ]] && continue
    case $proto in both) ports+=("$p/tcp" "$p/udp");; *) ports+=("$p/$proto");; esac
  done < <(config_listeners "$WW_TUNNELS/$n/config.json")
  ((${#ports[@]})) || return 0
  if command -v ufw >/dev/null && [[ $(ufw status 2>/dev/null) == *"Status: active"* ]]; then
    for x in "${ports[@]}"; do ufw allow "$x" >/dev/null && ok "ufw: opened $x"; done
  elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
    for x in "${ports[@]}"; do firewall-cmd -q --permanent --add-port="$x" && ok "firewalld: opened $x"; done
    firewall-cmd -q --reload
  fi
}

# ----------------------------------------------------------------------------
# [MODULE] tools: prerequisites, speed test
# ----------------------------------------------------------------------------
prereq_raw_check() {
  [[ -n $WW_ROOT ]] && return 0
  local m
  command -v iptables >/dev/null && ok "iptables present" || warn "iptables missing (apt install iptables)"
  command -v iptables-save >/dev/null || warn "iptables-save missing"
  for m in nfnetlink_queue xt_NFQUEUE xt_bpf tun; do
    modprobe -q "$m" 2>/dev/null
    if [[ -d /sys/module/$m ]]; then ok "kernel module $m available"
    else warn "kernel module $m not loaded (may be built-in or unsupported)"; fi
  done
  [[ -c /dev/net/tun ]] && ok "/dev/net/tun present" || warn "/dev/net/tun missing (TUN templates will fail)"
}

system_check() {
  info "Kernel: $(uname -r)   Arch: $(uname -m)   CPU flags: $(grep -m1 -owE 'avx512f|avx2' /proc/cpuinfo 2>/dev/null | sort -u | tr '\n' ' ')"
  info "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
  info "Public IP: $(public_ip)   WAN interface: $(wan_iface)"
  prereq_raw_check
  info "Listening sockets:"; ss -Hlntup 2>/dev/null | awk '{print "   "$1" "$5" "$7}' | head -n 40
}

speedtest_run() { # dir
  local d=$1 bin; bin=$(core_bin) || { err "Core not installed."; return 1; }
  cat >"$d/core.json" <<EOF
{ "log": { "path": "logs/", "core": { "loglevel": "INFO", "console": true }, "network": { "loglevel": "INFO", "console": true } },
  "misc": { "workers": 0, "ram-profile": "server", "mtu": 1500, "libs-path": "${WW_LIBS}/" },
  "configs": [ "$d/config.json" ] }
EOF
  mkdir -p "$d/logs"
  info "Running ... (Ctrl+C to stop)"
  ( cd "$d" && ${ST_TIMEOUT:+timeout "$ST_TIMEOUT"} "$bin" --config:"$d/core.json" ) || true
}

speedtest_server() {
  local p d; ask p "Speed-test server port" "9000" is_port
  d=$(mktemp -d)
  jq -n --argjson p "$p" '{name: "ww-speedtest-server", nodes: [
    {name: "st_in", type: "TcpListener", settings: {address: "0.0.0.0", port: $p, nodelay: true}, next: "st_server"},
    {name: "st_server", type: "SpeedTestServer", settings: {"report-interval-ms": 1000, "json-summary": false}}]}' >"$d/config.json"
  warn "Make sure TCP $p is open on this server's firewall."
  ST_TIMEOUT="" speedtest_run "$d"; rm -rf "$d"
}

speedtest_client() {
  local h p dir dur cc d
  info "Tip: to test THROUGH a tunnel, run the speed-test server on the tunnel's server side, point the final port to it,"
  info "     and here target 127.0.0.1:<tunnel user port>."
  ask h "Target host" "127.0.0.1" is_host
  ask p "Target port" "9000" is_port
  local c; choose c "Direction:" "Upload" "Download" "Both"
  case $c in 1) dir=upload;; 2) dir=download;; 3) dir=bidirectional;; esac
  ask dur "Duration in seconds" "10" is_num
  ask cc "Parallel connections" "4" is_num
  d=$(mktemp -d)
  jq -n --arg h "$h" --argjson p "$p" --arg dir "$dir" --argjson ms "$(( 10#$dur * 1000 ))" --argjson cc "$((10#$cc))" '{name: "ww-speedtest-client", nodes: [
    {name: "st_client", type: "SpeedTestClient", settings: {mode: "tcp", direction: $dir, "duration-ms": $ms, "warmup-ms": 1000,
       "report-interval-ms": 1000, "connection-count": $cc, "payload-size": 131072, "terminate-on-complete": true}, next: "st_out"},
    {name: "st_out", type: "TcpConnector", settings: {address: $h, port: $p, nodelay: true}}]}' >"$d/config.json"
  ST_TIMEOUT=$(( 10#$dur + 30 )) speedtest_run "$d"; rm -rf "$d"
}

tools_menu() {
  while true; do
    banner
    local c; choose c "Tools:" "System & prerequisites check" "Speed test — run server here" "Speed test — run client here" \
      "Optimize server (BBR, buffers, limits)" "Back"
    case $c in
      1) system_check; pause;;
      2) speedtest_server; pause;;
      3) speedtest_client; pause;;
      4) optimize_system; pause;;
      5) return;;
    esac
  done
}

# ----------------------------------------------------------------------------
# [MODULE] optimizer
# ----------------------------------------------------------------------------
optimize_system() {
  info "Applying network tuning (BBR, buffers, file limits) ..."
  mkdir -p "${WW_ROOT}/etc/sysctl.d" "${WW_ROOT}/etc/security/limits.d"
  cat >"${WW_ROOT}/etc/sysctl.d/99-waterwall.conf" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 10240 65000
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_keepalive_time = 300
fs.file-max = 2097152
EOF
  cat >"${WW_ROOT}/etc/security/limits.d/99-waterwall.conf" <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
EOF
  if [[ -z $WW_ROOT ]]; then
    modprobe -q tcp_bbr 2>/dev/null
    sysctl --system >/dev/null 2>&1
    if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; then ok "BBR active"
    else warn "BBR not active (kernel may not support it)."; fi
  fi
  ok "Optimization applied."
}

# ----------------------------------------------------------------------------
# [MODULE] backup / restore
# ----------------------------------------------------------------------------
backup_create() {
  mkdir -p "$WW_BACKUPS"
  local f="$WW_BACKUPS/waterwall-$(hostname 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).tar.gz" items=() i
  for i in tunnels certs manager.conf; do [[ -e $WW_ETC/$i ]] && items+=("$i"); done
  ((${#items[@]})) || { warn "Nothing to back up."; return 1; }
  tar -czf "$f" -C "$WW_ETC" "${items[@]}" && chmod 600 "$f" && ok "Backup: $f"
}
backup_restore() {
  local f=$1 n
  [[ -f $f ]] || { err "File not found"; return 1; }
  tar -tzf "$f" >/dev/null 2>&1 || { err "Not a valid .tar.gz backup"; return 1; }
  local list; list=$(tar -tzf "$f")
  if grep -qE '(^/|(^|/)\.\.(/|$))' <<<"$list"; then err "Unsafe paths inside backup — refusing."; return 1; fi
  confirm "Restore will overwrite existing tunnels with the same names. Continue?" n || return
  mkdir -p "$WW_ETC"; tar -xzf "$f" -C "$WW_ETC" && ok "Restored."
  service_install_unit
  while read -r n; do [[ -n $n ]] && write_core_path_fix "$n"; done < <(tunnel_list_names)
  if confirm "Start all restored tunnels?" y; then
    while read -r n; do [[ -n $n ]] && { svc enable "$n"; svc restart "$n"; }; done < <(tunnel_list_names)
  fi
}
write_core_path_fix() {
  [[ -f "$WW_TUNNELS/$1/core.json" ]] || return 0
  jq_inplace "$WW_TUNNELS/$1/core.json" --arg c "$WW_TUNNELS/$1/config.json" --arg l "$WW_LIBS/" '.configs = [$c] | .misc["libs-path"] = $l'
}

# ----------------------------------------------------------------------------
# [MODULE] settings / self-install / uninstall
# ----------------------------------------------------------------------------
settings_menu() {
  while true; do
    banner
    printf '  GitHub proxy prefix : %s\n  Default log level   : %s\n' "${GH_PROXY:-<none>}" "$LOG_LEVEL"
    line
    local c; choose c "Settings:" "Set GitHub download proxy (for filtered networks)" "Set default log level" \
      "Apply log level to all tunnels now" "Back"
    case $c in
      1) local p; read -rp "Proxy prefix (e.g. https://ghproxy.net/ , empty = none): " p || true
         if [[ -z $p || $p =~ ^https?://[^[:space:]\'\"]+$ ]]; then GH_PROXY=$p; save_settings; ok "Saved."; else warn "Invalid URL"; fi; pause;;
      2) local l lv=(DEBUG INFO WARN ERROR); choose l "Log level:" "${lv[@]}"; LOG_LEVEL=${lv[$((l-1))]}; save_settings;;
      3) local n; while read -r n; do
           [[ -n $n ]] && jq_inplace "$WW_TUNNELS/$n/core.json" --arg L "$LOG_LEVEL" '.log.core.loglevel=$L | .log.network.loglevel=$L | .log.internal.loglevel=$L'
         done < <(tunnel_list_names)
         ok "Updated; restarting all."; svc_all restart; pause;;
      4) return;;
    esac
  done
}

self_install() {
  local src; src=$(readlink -f "$0" 2>/dev/null)
  [[ -f $src && -r $src ]] || return 0           # e.g. run via 'bash <(curl ...)'
  [[ $src == "$(readlink -f "$SELF_PATH" 2>/dev/null)" ]] && return 0
  [[ $(head -c 200 "$src") == *'WaterWall Manager'* ]] || return 0
  mkdir -p "$(dirname "$SELF_PATH")"
  install -m 0755 "$src" "$SELF_PATH" 2>/dev/null && ok "Installed manager as '${SELF_PATH##*/}' — run 'ww' anytime."
}

uninstall_all() {
  warn "This removes WaterWall core, ALL tunnels, services, certs and this manager."
  confirm "Are you absolutely sure?" n || return
  confirm "Create a backup first?" y && backup_create
  local n; while read -r n; do [[ -n $n ]] && { svc stop "$n"; svc disable "$n"; }; done < <(tunnel_list_names)
  rm -f "$SYSTEMD_DIR/waterwall@.service" "$CRON_FILE" "${WW_ROOT}/etc/sysctl.d/99-waterwall.conf" "${WW_ROOT}/etc/security/limits.d/99-waterwall.conf"
  has_systemd && systemctl daemon-reload
  find "$WW_ETC" -mindepth 1 -maxdepth 1 ! -name backups -exec rm -rf {} +
  rm -rf "$WW_HOME" "$SELF_PATH"
  ok "Uninstalled. Backups kept in $WW_BACKUPS"
  exit 0
}

# ----------------------------------------------------------------------------
# [MODULE] main menu & CLI
# ----------------------------------------------------------------------------
main_menu() {
  while true; do
    banner
    tunnel_list; line
    local c
    choose c "Main menu:" \
      "Create new tunnel" "Manage a tunnel" "Core: install / update / version" \
      "Restart all tunnels" "Stop all tunnels" "Tools (speed test, system check, optimize)" \
      "Backup tunnels" "Restore from backup" "Settings" "Uninstall everything" "Exit"
    case $c in
      1) tunnel_create; pause;;
      2) tunnel_manage;;
      3) core_menu;;
      4) svc_all restart; pause;;
      5) svc_all stop; pause;;
      6) tools_menu;;
      7) backup_create; pause;;
      8) local f; ask f "Backup file path" "$(ls -1t "$WW_BACKUPS"/*.tar.gz 2>/dev/null | head -n1)" is_file; backup_restore "$f"; pause;;
      9) settings_menu;;
      10) uninstall_all;;
      11) exit 0;;
    esac
  done
}

usage() {
  cat <<EOF
WaterWall Manager v$SCRIPT_VERSION
  ww                      interactive menu
  ww install [tag]        install/update core (default: latest)
  ww install-zip <file>   install core from a local zip (offline)
  ww create               create a tunnel (wizard / official template / import)
  ww list                 list tunnels
  ww start|stop|restart|enable|disable|status|logs|health|info <name>
  ww limit <name>         set/remove a bandwidth limit
  ww wg-add <name> [client]   add a WireGuard client and print its config
  ww restart-all | stop-all
  ww delete <name>
  ww templates            list all official templates
  ww check                system & prerequisites check
  ww speedtest-server | speedtest-client
  ww optimize | backup | restore <file> | uninstall
EOF
}

tunnel_exists() { [[ -n ${1:-} && -d "$WW_TUNNELS/$1" ]] || die "No such tunnel: ${1:-<none>}"; }

main() {
  require_root
  load_settings
  mkdir -p "$WW_TUNNELS" "$WW_BACKUPS"
  local cmd=${1:-menu}; shift || true
  case $cmd in
    menu)        self_install; main_menu;;
    install)     core_install "${1:-latest}" auto;;
    install-zip) [[ -f ${1:-} ]] || die "Usage: ww install-zip <file>"; core_install_from_zip "$1" "local:$(basename "$1")";;
    create)      tunnel_create;;
    list|ls)     tunnel_list;;
    start|stop|restart|enable|disable) tunnel_exists "${1:-}"; svc "$cmd" "$1";;
    status)      tunnel_exists "${1:-}"; has_systemd && systemctl status "waterwall@$1" --no-pager -l;;
    logs)        tunnel_exists "${1:-}"; journalctl -u "waterwall@$1" -f -n 50;;
    health)      tunnel_exists "${1:-}"; tunnel_health "$1";;
    info)        tunnel_exists "${1:-}"; tunnel_info "$1";;
    limit)       tunnel_exists "${1:-}"; tunnel_speed_limit_menu "$1";;
    wg-add)      tunnel_exists "${1:-}"; [[ $(meta_get "$1" MODE) == wireguard ]] || die "$1 is not a WireGuard tunnel"
                 wg_add_client "$1" "${2:-}" && { svc restart "$1"; wg_show_client "$1" "$WG_LAST"; };;
    restart-all) svc_all restart;;
    stop-all)    svc_all stop;;
    delete|rm)   tunnel_exists "${1:-}"; tunnel_delete "$1";;
    templates)   awk -F'\t' '{printf "%-34s %-28s %-8s %s\n", $1, $3, $4, $2}' <<<"$WW_TEMPLATES";;
    check)       system_check;;
    speedtest-server) speedtest_server;;
    speedtest-client) speedtest_client;;
    optimize)    optimize_system;;
    backup)      backup_create;;
    restore)     [[ -f ${1:-} ]] || die "Usage: ww restore <file>"; backup_restore "$1";;
    uninstall)   uninstall_all;;
    -h|--help|help) usage;;
    *) usage; exit 1;;
  esac
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
