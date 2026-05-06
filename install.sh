#!/usr/bin/env bash
# Copyright (c) 2026 vevc
# SPDX-License-Identifier: MIT
set -euo pipefail

PROJECT="sing-box"
REPO="SagerNet/sing-box"

DEFAULT_VERSION="v1.13.7"
DEFAULT_INSTALL_DIR="/usr/local/bin"
DEFAULT_CONFIG_PATH="/etc/sing-box/config.json"
DEFAULT_TLS_CERT_PATH="/etc/sing-box/certs/server.crt"
DEFAULT_TLS_KEY_PATH="/etc/sing-box/certs/server.key"
DEFAULT_TLS_SERVER_NAME="www.bing.com"
DEFAULT_TLS_CERT_NAME="www.bing.com"
DEFAULT_VLESS_PORT="0"
DEFAULT_HY2_PORT="0"
DEFAULT_TUIC_PORT="0"
DEFAULT_WS_PATH="/"

DEFAULT_ARGO_ENABLED="false"

STATE_DIR="/var/lib/sing-box"
SUB_FILE="${STATE_DIR}/sub.txt"
MANIFEST_FILE="${STATE_DIR}/manifest.env"

BIN_NAME="sing-box"
DOWNLOAD_VERBOSE="false"

# Init system: "systemd" or "openrc". Set by detect_init() in main()/uninstall_main().
INIT_SYSTEM=""

# Service file paths per init system.
SINGBOX_SYSTEMD_UNIT="/etc/systemd/system/sing-box.service"
CLOUDFLARED_SYSTEMD_UNIT="/etc/systemd/system/cloudflared.service"
SINGBOX_OPENRC_INITD="/etc/init.d/sing-box"
CLOUDFLARED_OPENRC_INITD="/etc/init.d/cloudflared"

# OpenRC log files (systemd uses journald instead).
SINGBOX_OPENRC_LOG="/var/log/sing-box.log"
CLOUDFLARED_OPENRC_LOG="/var/log/cloudflared.log"

usage() {
  cat <<'EOF'
sing-box one-click installer (systemd or OpenRC; vless-ws/hy2/tuic + cloudflare argo tunnel)

Usage:
  sudo ./install.sh [options]
  sudo ./install.sh uninstall [--dry-run]
EOF

  echo
  echo "Install options:"
  local w=36
  printf "  %-${w}s %s\n" "--install-deps" "automatically install missing dependencies (default: disabled)"
  printf "  %-${w}s %s\n" "--verbose" "show download progress and extra logs"
  printf "  %-${w}s %s\n" "--version <tag|latest>" "sing-box version tag (default: v1.13.7)"
  printf "  %-${w}s %s\n" "--install-dir <dir>" "install dir for sing-box binary (default: /usr/local/bin)"
  printf "  %-${w}s %s\n" "--config <path>" "config path (default: /etc/sing-box/config.json)"
  printf "  %-${w}s %s\n" "--tls-cert-path <path>" "TLS certificate path (PEM). When set, --tls-key-path is required"
  printf "  %-${w}s %s\n" "--tls-key-path <path>" "TLS private key path (PEM). When set, --tls-cert-path is required"
  printf "  %-${w}s %s\n" "--tls-server-name <name>" "TLS server name (SNI). Used in share links as sni/host (default: www.bing.com)"
  printf "  %-${w}s %s\n" "--tls-cert-name <name>" "Name used when generating a self-signed cert (CN) (default: www.bing.com)"
  printf "  %-${w}s %s\n" "--tls-trusted" "treat TLS cert as trusted; omit insecure/allowInsecure in share links"
  printf "  %-${w}s %s\n" "--host <public_ip>" "address used in subscription (default: auto-detect)"
  printf "  %-${w}s %s\n" "--user <name[:uuid]>" "add a user (repeatable). uuid auto-generated if omitted"
  printf "  %-${w}s %s\n" "--user-socks5 <spec>" "bind user to socks5 outbound (repeatable)"
  printf "  %-${w}s %s\n" "" "spec: name=host:port[:username:password]"
  printf "  %-${w}s %s\n" "--user-http <spec>" "bind user to HTTP proxy outbound (repeatable)"
  printf "  %-${w}s %s\n" "" "spec: name=host:port[:username:password]"
  printf "  %-${w}s %s\n" "--user-https <spec>" "bind user to HTTPS proxy outbound (HTTP proxy over TLS) (repeatable)"
  printf "  %-${w}s %s\n" "" "spec: name=host:port[:username:password]"
  printf "  %-${w}s %s\n" "--user-https-sni <spec>" "set TLS SNI for user's HTTPS proxy (optional, repeatable)"
  printf "  %-${w}s %s\n" "" "spec: name=server_name"
  printf "  %-${w}s %s\n" "--user-https-insecure <spec>" "skip TLS verify for user's HTTPS proxy (default: false) (repeatable)"
  printf "  %-${w}s %s\n" "" "spec: name=true|false"
  printf "  %-${w}s %s\n" "--vless-port <port|public:listen>" "vless+ws port (TCP). NAT mapping supported. set 0 to disable (default: 0)"
  printf "  %-${w}s %s\n" "--ws-path <path>" "websocket path for vless+ws (default: /)"
  printf "  %-${w}s %s\n" "--argo" "enable Cloudflare Tunnel for vless (default: disabled)"
  printf "  %-${w}s %s\n" "--argo-domain <domain>" "public domain for a Named Tunnel (used only when --argo-token is also set)"
  printf "  %-${w}s %s\n" "--argo-token <token>" "Named Tunnel token (when set -> use Named Tunnel; otherwise -> use Quick Tunnel with a *.trycloudflare.com domain)"
  printf "  %-${w}s %s\n" "--hy2-port <port|public:listen>" "hysteria2 port (UDP). NAT mapping supported. set 0 to disable (default: 0)"
  printf "  %-${w}s %s\n" "--tuic-port <port|public:listen>" "tuic port (UDP). NAT mapping supported. set 0 to disable (default: 0)"
  printf "  %-${w}s %s\n" "-h, --help" "show this help"

  echo
  echo "Uninstall options:"
  printf "  %-${w}s %s\n" "--dry-run" "print planned paths; do not remove anything"

  cat <<'EOF'

Notes:
  - By default a self-signed certificate is generated; clients usually need insecure/skip TLS verify in share links.
  - With a trusted CA certificate, pass --tls-trusted so insecure/allowInsecure are omitted from share links.
  - vless+ws behavior:
      - argo disabled: vless is exposed publicly as WSS with self-signed cert.
      - argo enabled: vless listens on 127.0.0.1 with plain WS; cloudflared provides public HTTPS.
  - hy2 (hysteria2) and tuic are UDP-based; ensure firewall allows UDP ports.
  - NAT/port-mapping: use public:listen format, e.g. --hy2-port 28443:8443 (share link uses 28443, server listens on 8443).
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[*] $*"; }
log_err() { echo "[*] $*" >&2; }

sh_quote() {
  printf "%q" "$1"
}

# Parse port spec "port" or "public:listen". Sets two global reply vars.
# Usage: parse_port "--hy2-port" "28443:8443"
#   -> _PORT_PUBLIC=28443  _PORT_LISTEN=8443
# Usage: parse_port "--hy2-port" "8443"
#   -> _PORT_PUBLIC=8443   _PORT_LISTEN=8443
_PORT_PUBLIC=""
_PORT_LISTEN=""
parse_port() {
  local flag="$1" val="$2"
  if [[ "$val" == *:* ]]; then
    _PORT_PUBLIC="${val%%:*}"
    _PORT_LISTEN="${val#*:}"
    [[ "$_PORT_PUBLIC" =~ ^[0-9]+$ && "$_PORT_LISTEN" =~ ^[0-9]+$ ]] || die "Invalid ${flag} value: ${val} (expected [public:]listen)"
    if [[ "$_PORT_PUBLIC" == "0" || "$_PORT_LISTEN" == "0" ]]; then
      [[ "$_PORT_PUBLIC" == "0" && "$_PORT_LISTEN" == "0" ]] || die "Invalid ${flag} value: ${val} (use 0 to disable, not 0:port or port:0)"
    fi
  else
    [[ "$val" =~ ^[0-9]+$ ]] || die "Invalid ${flag} value: ${val} (expected [public:]listen)"
    _PORT_PUBLIC="$val"
    _PORT_LISTEN="$val"
  fi
}

# Percent-encode for VLESS share-link query values (path=...). "/" -> %2F; reserved
# chars in custom --ws-path do not break the URI. Prefer python3 when present (UTF-8).
uri_encode_query_value() {
  local s="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$s"
    return 0
  fi
  local out="" i c hex
  local LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~-])
        out+="$c"
        ;;
      \')
        out+="%27"
        ;;
      *)
        printf -v hex '%%%02X' "'$c"
        out+="$hex"
        ;;
    esac
  done
  printf '%s' "$out"
}

ensure_dir() {
  local d="$1"
  mkdir -p "$d"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

read_os_id_like() {
  local id="unknown"
  local like=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
    id="${ID:-unknown}"
    like="${ID_LIKE:-}"
  fi
  printf '%s|%s' "$id" "$like"
}

detect_init() {
  # Prefer systemd when its runtime dir + tools are present; otherwise fall back to OpenRC.
  if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    echo "systemd"; return 0
  fi
  if command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
    echo "openrc"; return 0
  fi
  echo "unknown"
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"; return 0; fi
  if command -v dnf >/dev/null 2>&1; then echo "dnf"; return 0; fi
  if command -v yum >/dev/null 2>&1; then echo "yum"; return 0; fi
  if command -v apk >/dev/null 2>&1; then echo "apk"; return 0; fi
  if command -v pacman >/dev/null 2>&1; then echo "pacman"; return 0; fi
  if command -v zypper >/dev/null 2>&1; then echo "zypper"; return 0; fi
  if command -v opkg >/dev/null 2>&1; then echo "opkg"; return 0; fi
  echo "unknown"
}

deps_for_cmd() {
  # Return package names (space-separated) for a given command.
  # Best-effort: package names vary by distro; we keep common ones.
  local cmd="$1"
  case "$cmd" in
    curl) echo "curl" ;;
    wget) echo "wget" ;;
    tar) echo "tar" ;;
    openssl) echo "openssl" ;;
    systemctl) echo "systemd" ;;
    timeout|mktemp|sha256sum|uname|dirname|head|tr|cut|cat|chmod|install|mkdir) echo "coreutils" ;;
    sed) echo "sed" ;;
    *) echo "" ;;
  esac
}

install_packages() {
  local mgr="$1"; shift
  local pkgs=("$@")
  [[ "${#pkgs[@]}" -gt 0 ]] || return 0

  log "Installing dependencies: ${pkgs[*]}"
  case "$mgr" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
      ;;
    dnf)
      dnf install -y "${pkgs[@]}"
      ;;
    yum)
      yum install -y "${pkgs[@]}"
      ;;
    apk)
      apk add --no-cache "${pkgs[@]}"
      ;;
    pacman)
      pacman -Sy --noconfirm "${pkgs[@]}"
      ;;
    zypper)
      zypper --non-interactive install -y "${pkgs[@]}"
      ;;
    opkg)
      opkg update
      opkg install "${pkgs[@]}"
      ;;
    *)
      die "No supported package manager found to auto-install dependencies"
      ;;
  esac
}

is_alpine() {
  local id=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
    id="${ID:-}"
  fi
  [[ "$id" == "alpine" ]]
}

ensure_alpine_glibc_compat() {
  # sing-box / cloudflared official Linux builds are dynamically linked to glibc.
  # Alpine uses musl and lacks the glibc loader, causing "cannot execute: required
  # file not found". `gcompat` provides a shim so glibc-linked binaries can run.
  local auto_install="$1"
  is_alpine || return 0
  command -v apk >/dev/null 2>&1 || return 0

  if apk info -e gcompat >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$auto_install" != "true" ]]; then
    log_err "Alpine detected: sing-box requires glibc compatibility (package 'gcompat')."
    log_err "  Re-run with --install-deps, or install manually: apk add gcompat"
    return 0
  fi

  log "Installing gcompat (glibc compatibility for musl)..."
  apk add --no-cache gcompat || die "Failed to install gcompat. Run manually: apk add gcompat"
}

ensure_cmds_or_install() {
  local auto_install="$1"; shift
  local required=("$@")
  local missing=()
  local pkgs=()
  local pkg

  local c
  for c in "${required[@]}"; do
    if ! command -v "$c" >/dev/null 2>&1; then
      missing+=("$c")
      pkg="$(deps_for_cmd "$c")"
      if [[ -n "$pkg" ]]; then
        pkgs+=($pkg)
      fi
    fi
  done

  if [[ "${#missing[@]}" -eq 0 ]]; then
    return 0
  fi

  if [[ "$auto_install" != "true" ]]; then
    die "Missing required command(s): ${missing[*]}. Re-run with --install-deps or install them manually."
  fi

  local mgr
  mgr="$(detect_pkg_manager)"
  if [[ "$mgr" == "unknown" ]]; then
    die "Missing required command(s): ${missing[*]}. No supported package manager found for auto-install."
  fi

  # De-duplicate packages (basic O(n^2), small list).
  local uniq=()
  local p u
  for p in "${pkgs[@]}"; do
    local seen="false"
    for u in "${uniq[@]}"; do
      if [[ "$u" == "$p" ]]; then seen="true"; break; fi
    done
    if [[ "$seen" != "true" ]]; then uniq+=("$p"); fi
  done

  install_packages "$mgr" "${uniq[@]}"

  # Re-check.
  for c in "${missing[@]}"; do
    command -v "$c" >/dev/null 2>&1 || die "Auto-install completed but still missing command: $c"
  done
}

need_http_client() {
  if command -v curl >/dev/null 2>&1; then
    return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    return 0
  fi
  die "Need curl or wget"
}

detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    i386|i686) echo "386" ;;
    *)
      die "Unsupported architecture: $m"
      ;;
  esac
}

detect_cloudflared_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "arm" ;;
    i386|i686) echo "386" ;;
    *)
      die "Unsupported architecture for cloudflared: $m"
      ;;
  esac
}

http_get() {
  local url="$1"
  need_http_client
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url"
  else
    die "Need curl or wget"
  fi
}

download_file() {
  local url="$1"
  local out="$2"
  need_http_client
  if command -v curl >/dev/null 2>&1; then
    if [[ "${DOWNLOAD_VERBOSE:-false}" == "true" ]]; then
      curl -fL --show-error --progress-bar --retry 3 --retry-delay 1 -o "$out" "$url" \
        || die "Download failed: ${url} -> ${out}"
    else
      curl -fSsL --retry 3 --retry-delay 1 -o "$out" "$url" \
        || die "Download failed: ${url} -> ${out}"
    fi
  else
    if [[ "${DOWNLOAD_VERBOSE:-false}" == "true" ]]; then
      wget -O "$out" "$url" \
        || die "Download failed: ${url} -> ${out}"
    else
      wget -q -O "$out" "$url" \
        || die "Download failed: ${url} -> ${out}"
    fi
  fi
}

json_escape() {
  # Minimal JSON string escaping.
  # Escapes: backslash, double-quote, newline, carriage return, tab.
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

sanitize_tag() {
  # Make a safe tag for sing-box (letters, digits, underscore).
  local s="$1"
  s="$(printf '%s' "$s" | tr -c 'A-Za-z0-9_' '_' )"
  # Collapse consecutive underscores a bit.
  s="$(printf '%s' "$s" | sed 's/__*/_/g' )"
  # Avoid empty.
  [[ -n "$s" ]] || s="user"
  printf '%s' "$s"
}

build_socks5_outbound() {
  local tag="$1" host="$2" port="$3" username="$4" password="$5"
  if [[ -n "$username" ]]; then
    cat <<EOF
    {
      "type": "socks",
      "tag": "$(json_escape "$tag")",
      "server": "$(json_escape "$host")",
      "server_port": ${port},
      "username": "$(json_escape "$username")",
      "password": "$(json_escape "$password")"
    }
EOF
  else
    cat <<EOF
    {
      "type": "socks",
      "tag": "$(json_escape "$tag")",
      "server": "$(json_escape "$host")",
      "server_port": ${port}
    }
EOF
  fi
}

build_http_outbound() {
  local tag="$1" host="$2" port="$3" username="$4" password="$5" tls_enabled="${6:-false}" tls_sni="${7:-}" tls_insecure="${8:-false}"

  local auth_block=""
  if [[ -n "$username" ]]; then
    auth_block=$',\n      "username": "'"$(json_escape "$username")"$'",\n      "password": "'"$(json_escape "$password")"$'"'
  fi

  local tls_block=""
  if [[ "$tls_enabled" == "true" ]]; then
    local sni="${tls_sni:-$host}"
    tls_block=$',\n      "tls": {\n        "enabled": true,\n        "server_name": "'"$(json_escape "$sni")"$'",\n        "insecure": '"$([[ "$tls_insecure" == "true" ]] && echo true || echo false)"$'\n      }'
  fi

  cat <<EOF
    {
      "type": "http",
      "tag": "$(json_escape "$tag")",
      "server": "$(json_escape "$host")",
      "server_port": ${port}${auth_block}${tls_block}
    }
EOF
}

build_route_rule_auth_user() {
  local user_name="$1" outbound_tag="$2"
  cat <<EOF
      {
        "auth_user": ["$(json_escape "$user_name")"],
        "action": "route",
        "outbound": "$(json_escape "$outbound_tag")"
      }
EOF
}

build_vless_ws_inbound() {
  local vless_port="$1" ws_path="$2" vless_listen="$3" vless_tls_enabled="$4" tls_cert_path="$5" tls_key_path="$6" users_json="$7"

  local tls_block=""
  if [[ "$vless_tls_enabled" == "true" ]]; then
    tls_block=$',\n      "tls": {\n        "enabled": true,\n        "certificate_path": "'"$(json_escape "$tls_cert_path")"$'",\n        "key_path": "'"$(json_escape "$tls_key_path")"$'"\n      }'
  fi

  cat <<EOF
    {
      "type": "vless",
      "tag": "vless-ws-in",
      "listen": "$(json_escape "$vless_listen")",
      "listen_port": ${vless_port},
      "users": [
${users_json}
      ],
      "transport": {
        "type": "ws",
        "path": "$(json_escape "$ws_path")"
      }${tls_block}
    }
EOF
}

build_hy2_inbound() {
  local hy2_port="$1" tls_cert_path="$2" tls_key_path="$3" users_json="$4"
  cat <<EOF
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${hy2_port},
      "users": [
${users_json}
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$(json_escape "$tls_cert_path")",
        "key_path": "$(json_escape "$tls_key_path")"
      }
    }
EOF
}

build_tuic_inbound() {
  local tuic_port="$1" tls_cert_path="$2" tls_key_path="$3" users_json="$4"
  cat <<EOF
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "::",
      "listen_port": ${tuic_port},
      "users": [
${users_json}
      ],
      "congestion_control": "bbr",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$(json_escape "$tls_cert_path")",
        "key_path": "$(json_escape "$tls_key_path")"
      }
    }
EOF
}

fetch_latest_tag() {
  # GitHub API without jq.
  http_get "https://api.github.com/repos/${REPO}/releases/latest" \
    | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n 1
}

download_release_tarball() {
  local version="$1" arch="$2" out="$3"
  local tag="$version"
  if [[ "$version" == "latest" ]]; then
    tag="$(fetch_latest_tag)"
    [[ -n "$tag" ]] || die "Failed to determine latest version tag"
  fi

  # Release URL path uses Git tag (usually "v1.2.3"); tarball basename uses "1.2.3" (no leading v).
  local path_tag="$tag"
  if [[ "$path_tag" != v* && "$path_tag" == [0-9]* ]]; then
    path_tag="v${path_tag}"
  fi
  local ver_in_file="$path_tag"
  if [[ "$ver_in_file" == v* ]]; then
    ver_in_file="${ver_in_file#v}"
  fi

  local file="sing-box-${ver_in_file}-linux-${arch}.tar.gz"
  local url="https://github.com/${REPO}/releases/download/${path_tag}/${file}"
  log "Downloading ${url}"

  download_file "$url" "$out"
}

install_binary_from_tarball() {
  local tarball="$1" install_dir="$2" ver_in_file="$3" arch="$4"
  local tmpdir
  tmpdir="$(mktemp -d)" || die "Failed to create temp directory"
  # Expand path when registering the trap: on RETURN, `local tmpdir` may already be
  # unset (set -u), so the trap must not reference $tmpdir at fire time.
  trap "rm -rf $(sh_quote "$tmpdir")" RETURN

  tar -xzf "$tarball" -C "$tmpdir"

  local found
  found="${tmpdir}/sing-box-${ver_in_file}-linux-${arch}/${BIN_NAME}"
  if [[ ! -f "$found" ]]; then
    die "Failed to find extracted ${BIN_NAME} at expected path: ${found}. Top-level: $(ls -1 "$tmpdir" 2>/dev/null | tr '\n' ' ')"
  fi

  mkdir -p "$install_dir"
  install -m 0755 "$found" "${install_dir}/${BIN_NAME}"
}

gen_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  else
    die "Cannot generate UUID (need /proc or uuidgen)"
  fi
}

detect_public_ip() {
  # Try multiple endpoints.
  local ip=""
  ip="$(http_get "https://api.ipify.org" 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then ip="$(http_get "https://ifconfig.me/ip" 2>/dev/null || true)"; fi
  if [[ -z "$ip" ]]; then ip="$(http_get "https://icanhazip.com" 2>/dev/null || true)"; fi
  echo "$ip" | tr -d '[:space:]'
}

gen_self_signed_cert() {
  local crt_path="$1" key_path="$2" cn="$3"
  ensure_dir "$(dirname "$crt_path")"

  if [[ -s "$key_path" && -s "$crt_path" ]]; then
    log "Existing certificate found (${crt_path}), reusing."
    CERT_MANAGED="false"
    return 0
  fi

  need_cmd openssl
  log "Generating self-signed certificate:"
  log "  crt: ${crt_path}"
  log "  key: ${key_path}"
  # openssl prints keygen progress ('.' and '+') to stderr; keep install logs clean.
  # On failure, dump stderr so the user can diagnose.
  local openssl_err
  # BusyBox mktemp requires TEMPLATE to end with XXXXXX (no trailing suffix), so
  # we don't append `.err`. The file is only used to capture stderr; name doesn't matter.
  openssl_err="$(mktemp -t openssl.XXXXXX)" || die "Failed to create temp file"
  if ! openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$key_path" \
    -out "$crt_path" \
    -subj "/CN=${cn}" \
    2>"$openssl_err"; then
    cat "$openssl_err" >&2 || true
    rm -f "$openssl_err" || true
    die "openssl certificate generation failed"
  fi
  rm -f "$openssl_err" || true

  chmod 600 "$key_path"
  chmod 644 "$crt_path"
  CERT_MANAGED="true"
}

install_cloudflared() {
  local install_dir="$1"
  local arch
  arch="$(detect_cloudflared_arch)"

  local url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
  local out="${install_dir}/cloudflared"

  if [[ -x "$out" ]]; then
    log "cloudflared already installed at ${out}, reusing."
    return 0
  fi

  log "Downloading cloudflared ${url}"
  ensure_dir "$install_dir"
  download_file "$url" "$out"

  chmod 0755 "$out"
  if ! "$out" --version >/dev/null 2>&1; then
    if is_alpine; then
      log_err "Hint: on Alpine, run 'apk add gcompat' (or re-run with --install-deps)."
    fi
    die "cloudflared installed but failed to run"
  fi
}

write_cloudflared_service() {
  local install_dir="$1"
  local argo_mode="$2"
  local origin_url="$3"
  local argo_token="$4"

  local exec_args=""
  if [[ "$argo_mode" == "try" ]]; then
    exec_args="tunnel --no-autoupdate --url ${origin_url}"
  elif [[ "$argo_mode" == "token" ]]; then
    # Named Tunnel: prefer Cloudflare-managed ingress (Public Hostname).
    exec_args="tunnel --no-autoupdate run --token ${argo_token}"
  else
    die "write_cloudflared_service called with invalid mode: ${argo_mode}"
  fi

  case "$INIT_SYSTEM" in
    systemd) write_cloudflared_systemd_unit "$install_dir" "$exec_args" ;;
    openrc)  write_cloudflared_openrc_initd  "$install_dir" "$exec_args" ;;
    *)       die "Unsupported init system: ${INIT_SYSTEM:-unknown}" ;;
  esac
}

write_cloudflared_systemd_unit() {
  local install_dir="$1" exec_args="$2"
  cat >"$CLOUDFLARED_SYSTEMD_UNIT" <<EOF
[Unit]
Description=cloudflared tunnel
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${install_dir}/cloudflared ${exec_args}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

write_cloudflared_openrc_initd() {
  local install_dir="$1" exec_args="$2"
  ensure_dir "$(dirname "$CLOUDFLARED_OPENRC_LOG")"
  cat >"$CLOUDFLARED_OPENRC_INITD" <<EOF
#!/sbin/openrc-run
# Managed by singbox-installer. Do not edit by hand.

name="cloudflared"
description="cloudflared tunnel"

command="${install_dir}/cloudflared"
command_args="${exec_args}"

supervisor=supervise-daemon
respawn_delay=2

output_log="${CLOUDFLARED_OPENRC_LOG}"
error_log="${CLOUDFLARED_OPENRC_LOG}"

rc_ulimit="-n 1048576"

depend() {
    need net
    after net sing-box
}
EOF
  chmod 0755 "$CLOUDFLARED_OPENRC_INITD"
}

# After cloudflared service is running (Quick Tunnel), extract the hostname assigned
# by Cloudflare. systemd: read the same unit's logs from journald; OpenRC: tail the
# log file written via supervise-daemon's output_log/error_log. Truncate the log
# before starting the service in OpenRC mode to avoid picking up a stale domain.
wait_trycloudflare_domain() {
  local max_wait="${1:-60}"
  local since_epoch="${2:-0}"
  case "$INIT_SYSTEM" in
    systemd) wait_trycloudflare_domain_from_journal "$max_wait" "$since_epoch" ;;
    openrc)  wait_trycloudflare_domain_from_logfile "$max_wait" "$CLOUDFLARED_OPENRC_LOG" ;;
    *)       die "Unsupported init system: ${INIT_SYSTEM:-unknown}" ;;
  esac
}

wait_trycloudflare_domain_from_journal() {
  local max_wait="${1:-60}"
  local since_epoch="${2:-0}"
  local elapsed=0
  local domain=""
  need_cmd journalctl

  # This function is used via command substitution. Log to stderr to avoid polluting stdout.
  log_err "Waiting for Quick Tunnel hostname in cloudflared logs (up to ${max_wait}s)..."
  while [[ "$elapsed" -lt "$max_wait" ]]; do
    domain="$(
      if [[ "$since_epoch" != "0" ]]; then
        journalctl -u cloudflared.service -b --since "@${since_epoch}" -n 500 --no-pager -o cat 2>/dev/null
      else
        journalctl -u cloudflared.service -b -n 500 --no-pager -o cat 2>/dev/null
      fi \
        | tr -d '\r' \
        | sed -E $'s/\x1B\\[[0-9;]*[[:alpha:]]//g' \
        | sed -n 's/.*https:\/\/\([^[:space:]]*\.trycloudflare\.com\).*/\1/p' \
        | tail -n 1
    )"
    if [[ -n "$domain" ]]; then
      printf '%s' "$domain"
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

wait_trycloudflare_domain_from_logfile() {
  local max_wait="${1:-60}"
  local logfile="${2:-$CLOUDFLARED_OPENRC_LOG}"
  local elapsed=0
  local domain=""

  log_err "Waiting for Quick Tunnel hostname in ${logfile} (up to ${max_wait}s)..."
  while [[ "$elapsed" -lt "$max_wait" ]]; do
    if [[ -f "$logfile" ]]; then
      domain="$(
        tr -d '\r' <"$logfile" \
          | sed -E $'s/\x1B\\[[0-9;]*[[:alpha:]]//g' \
          | sed -n 's/.*https:\/\/\([^[:space:]]*\.trycloudflare\.com\).*/\1/p' \
          | tail -n 1
      )"
      if [[ -n "$domain" ]]; then
        printf '%s' "$domain"
        return 0
      fi
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

write_config() {
  local config_path="$1"
  local tls_cert_path="$2"
  local tls_key_path="$3"
  local hy2_port="$4"
  local tuic_port="$5"
  local vless_port="$6"
  local ws_path="$7"
  local vless_listen="$8"
  local vless_tls_enabled="$9" # true|false

  local cfg_dir
  cfg_dir="$(dirname "$config_path")"
  ensure_dir "$cfg_dir"

  local users_vless=""
  local users_hy2=""
  local users_tuic=""

  local outbounds_extra=()
  local route_rules=()

  local idx
  for idx in "${!USER_NAMES[@]}"; do
    local name="${USER_NAMES[$idx]}"
    local uuid="${USER_UUIDS[$idx]}"
    local tuic_pw="${USER_TUIC_PASSWORDS[$idx]}"

    local vless_user="        { \"name\": \"$(json_escape "$name")\", \"uuid\": \"$(json_escape "$uuid")\" }"
    local hy2_user="        { \"name\": \"$(json_escape "$name")\", \"password\": \"$(json_escape "$uuid")\" }"
    local tuic_user="        { \"name\": \"$(json_escape "$name")\", \"uuid\": \"$(json_escape "$uuid")\", \"password\": \"$(json_escape "$tuic_pw")\" }"

    if [[ -n "$users_vless" ]]; then users_vless+=$',\n'; fi
    users_vless+="${vless_user}"

    if [[ -n "$users_hy2" ]]; then users_hy2+=$',\n'; fi
    users_hy2+="${hy2_user}"

    if [[ -n "$users_tuic" ]]; then users_tuic+=$',\n'; fi
    users_tuic+="${tuic_user}"

    local proxy_type="${USER_PROXY_TYPES[$idx]}"
    local proxy_host="${USER_PROXY_HOSTS[$idx]}"
    local proxy_port="${USER_PROXY_PORTS[$idx]}"
    local proxy_user="${USER_PROXY_USERS[$idx]}"
    local proxy_pass="${USER_PROXY_PASSES[$idx]}"
    local proxy_sni="${USER_PROXY_HTTPS_SNIS[$idx]}"
    local proxy_insecure="${USER_PROXY_HTTPS_INSECURES[$idx]}"

    if [[ -n "$proxy_type" ]]; then
      local tag="proxy_$(sanitize_tag "$name")"
      case "$proxy_type" in
        socks5)
          outbounds_extra+=("$(build_socks5_outbound "$tag" "$proxy_host" "$proxy_port" "$proxy_user" "$proxy_pass")")
          ;;
        http)
          outbounds_extra+=("$(build_http_outbound "$tag" "$proxy_host" "$proxy_port" "$proxy_user" "$proxy_pass" "false" "" "false")")
          ;;
        https)
          outbounds_extra+=("$(build_http_outbound "$tag" "$proxy_host" "$proxy_port" "$proxy_user" "$proxy_pass" "true" "$proxy_sni" "$proxy_insecure")")
          ;;
        *)
          die "Unknown proxy type for user ${name}: ${proxy_type}"
          ;;
      esac
      route_rules+=("$(build_route_rule_auth_user "$name" "$tag")")
    fi
  done

  local inbounds_json=()
  if [[ "$vless_port" != "0" ]]; then
    inbounds_json+=("$(build_vless_ws_inbound "$vless_port" "$ws_path" "$vless_listen" "$vless_tls_enabled" "$tls_cert_path" "$tls_key_path" "$users_vless")")
  fi
  if [[ "$hy2_port" != "0" ]]; then
    inbounds_json+=("$(build_hy2_inbound "$hy2_port" "$tls_cert_path" "$tls_key_path" "$users_hy2")")
  fi
  if [[ "$tuic_port" != "0" ]]; then
    inbounds_json+=("$(build_tuic_inbound "$tuic_port" "$tls_cert_path" "$tls_key_path" "$users_tuic")")
  fi

  if [[ "${#inbounds_json[@]}" -eq 0 ]]; then
    die "No protocol enabled. Set at least one of --vless-port/--hy2-port/--tuic-port to a non-zero port."
  fi

  local joined_inbounds=""
  local i
  for i in "${!inbounds_json[@]}"; do
    if [[ "$i" -gt 0 ]]; then joined_inbounds+=$',\n'; fi
    joined_inbounds+="${inbounds_json[$i]}"
  done

  local joined_outbounds_extra=""
  local j
  for j in "${!outbounds_extra[@]}"; do
    joined_outbounds_extra+=$',\n'
    joined_outbounds_extra+="${outbounds_extra[$j]}"
  done

  local route_block=""
  if [[ "${#route_rules[@]}" -gt 0 ]]; then
    local joined_rules=""
    local k
    for k in "${!route_rules[@]}"; do
      if [[ "$k" -gt 0 ]]; then joined_rules+=$',\n'; fi
      joined_rules+="${route_rules[$k]}"
    done
    route_block=$',\n  "route": {\n    "rules": [\n'"${joined_rules}"$'\n    ],\n    "final": "direct"\n  }'
  fi

  cat >"$config_path" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
${joined_inbounds}
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" },
    { "type": "block", "tag": "block" }${joined_outbounds_extra}
  ]${route_block}
}
EOF
}

write_singbox_service() {
  local install_dir="$1"
  local config_path="$2"
  case "$INIT_SYSTEM" in
    systemd) write_singbox_systemd_unit "$install_dir" "$config_path" ;;
    openrc)  write_singbox_openrc_initd  "$install_dir" "$config_path" ;;
    *)       die "Unsupported init system: ${INIT_SYSTEM:-unknown}" ;;
  esac
}

write_singbox_systemd_unit() {
  local install_dir="$1" config_path="$2"
  cat >"$SINGBOX_SYSTEMD_UNIT" <<EOF
[Unit]
Description=sing-box service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${install_dir}/${BIN_NAME} run -c ${config_path}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

write_singbox_openrc_initd() {
  local install_dir="$1" config_path="$2"
  ensure_dir "$(dirname "$SINGBOX_OPENRC_LOG")"
  cat >"$SINGBOX_OPENRC_INITD" <<EOF
#!/sbin/openrc-run
# Managed by singbox-installer. Do not edit by hand.

name="sing-box"
description="sing-box service"

command="${install_dir}/${BIN_NAME}"
command_args="run -c ${config_path}"

supervisor=supervise-daemon
respawn_delay=2

output_log="${SINGBOX_OPENRC_LOG}"
error_log="${SINGBOX_OPENRC_LOG}"

rc_ulimit="-n 1048576"

depend() {
    need net
    after net
}
EOF
  chmod 0755 "$SINGBOX_OPENRC_INITD"
}

service_enable_start() {
  # svc: bare name (e.g. "sing-box", "cloudflared"). systemctl accepts both with
  # and without the .service suffix; OpenRC uses the bare name directly.
  local svc="$1"
  case "$INIT_SYSTEM" in
    systemd)
      need_cmd systemctl
      systemctl daemon-reload
      # Ensure changes apply on re-run too.
      systemctl enable "$svc" >/dev/null 2>&1 || true
      systemctl restart "$svc"
      ;;
    openrc)
      need_cmd rc-service
      need_cmd rc-update
      rc-update add "$svc" default >/dev/null 2>&1 || true
      rc-service "$svc" restart
      ;;
    *)
      die "Unsupported init system: ${INIT_SYSTEM:-unknown}"
      ;;
  esac
}

service_disable_stop() {
  # Best-effort stop+disable; ignores missing tools/services.
  local svc="$1"
  case "$INIT_SYSTEM" in
    systemd)
      command -v systemctl >/dev/null 2>&1 || return 0
      systemctl disable --now "$svc" >/dev/null 2>&1 || true
      ;;
    openrc)
      if command -v rc-service >/dev/null 2>&1; then
        rc-service "$svc" stop >/dev/null 2>&1 || true
      fi
      if command -v rc-update >/dev/null 2>&1; then
        rc-update del "$svc" default >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

write_manifest() {
  local singbox_bin="$1"
  local cloudflared_bin="$2"
  local config_path="$3"
  local tls_cert_path="$4"
  local tls_key_path="$5"

  local singbox_unit="" cloudflared_unit=""
  local singbox_log="" cloudflared_log=""
  case "$INIT_SYSTEM" in
    systemd)
      singbox_unit="$SINGBOX_SYSTEMD_UNIT"
      cloudflared_unit="$CLOUDFLARED_SYSTEMD_UNIT"
      ;;
    openrc)
      singbox_unit="$SINGBOX_OPENRC_INITD"
      cloudflared_unit="$CLOUDFLARED_OPENRC_INITD"
      singbox_log="$SINGBOX_OPENRC_LOG"
      cloudflared_log="$CLOUDFLARED_OPENRC_LOG"
      ;;
  esac

  ensure_dir "$STATE_DIR"
  cat >"$MANIFEST_FILE" <<EOF
STATE_DIR=$(sh_quote "$STATE_DIR")
SUB_FILE=$(sh_quote "$SUB_FILE")
CONFIG_PATH=$(sh_quote "$config_path")
TLS_CERT_PATH=$(sh_quote "$tls_cert_path")
TLS_KEY_PATH=$(sh_quote "$tls_key_path")
CERT_MANAGED=$(sh_quote "${CERT_MANAGED:-true}")
INIT_SYSTEM=$(sh_quote "$INIT_SYSTEM")
SINGBOX_BIN=$(sh_quote "$singbox_bin")
CLOUDFLARED_BIN=$(sh_quote "$cloudflared_bin")
SINGBOX_UNIT=$(sh_quote "$singbox_unit")
CLOUDFLARED_UNIT=$(sh_quote "$cloudflared_unit")
SINGBOX_LOG=$(sh_quote "$singbox_log")
CLOUDFLARED_LOG=$(sh_quote "$cloudflared_log")
EOF
  chmod 600 "$MANIFEST_FILE" 2>/dev/null || true
}

uninstall_main() {
  local dry_run="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry_run="true"; shift 1 ;;
      -h|--help)
        cat <<'EOF'
Usage:
  sudo ./install.sh uninstall [--dry-run]

Options:
  --dry-run   Print actions without executing
EOF
        exit 0
        ;;
      *) die "Unknown uninstall option: $1" ;;
    esac
  done

  is_root || die "Please run as root (use sudo)."

  local singbox_bin="${DEFAULT_INSTALL_DIR}/${BIN_NAME}"
  local cloudflared_bin="${DEFAULT_INSTALL_DIR}/cloudflared"
  local config_path="$DEFAULT_CONFIG_PATH"
  local tls_cert_path="$DEFAULT_TLS_CERT_PATH"
  local tls_key_path="$DEFAULT_TLS_KEY_PATH"
  local cert_dir
  cert_dir="$(dirname "$tls_cert_path")"
  local cert_managed="true"
  local singbox_unit=""
  local cloudflared_unit=""
  local singbox_log=""
  local cloudflared_log=""

  if [[ -r "$MANIFEST_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$MANIFEST_FILE" || true
    singbox_bin="${SINGBOX_BIN:-$singbox_bin}"
    cloudflared_bin="${CLOUDFLARED_BIN:-$cloudflared_bin}"
    config_path="${CONFIG_PATH:-$config_path}"
    tls_cert_path="${TLS_CERT_PATH:-$tls_cert_path}"
    tls_key_path="${TLS_KEY_PATH:-$tls_key_path}"
    cert_dir="$(dirname "$tls_cert_path")"
    cert_managed="${CERT_MANAGED:-$cert_managed}"
    INIT_SYSTEM="${INIT_SYSTEM:-}"
    singbox_unit="${SINGBOX_UNIT:-}"
    cloudflared_unit="${CLOUDFLARED_UNIT:-}"
    singbox_log="${SINGBOX_LOG:-}"
    cloudflared_log="${CLOUDFLARED_LOG:-}"
  fi

  # Fall back to live detection when manifest is missing or pre-dates init-system field.
  if [[ -z "$INIT_SYSTEM" ]]; then
    INIT_SYSTEM="$(detect_init)"
  fi

  # Backfill paths for both init systems so we clean up any leftovers from older
  # installs even if the manifest only knows about one.
  local cleanup_units=()
  local cleanup_logs=()
  [[ -n "$singbox_unit"     ]] && cleanup_units+=("$singbox_unit")
  [[ -n "$cloudflared_unit" ]] && cleanup_units+=("$cloudflared_unit")
  cleanup_units+=("$SINGBOX_SYSTEMD_UNIT" "$CLOUDFLARED_SYSTEMD_UNIT" \
                  "$SINGBOX_OPENRC_INITD" "$CLOUDFLARED_OPENRC_INITD")
  [[ -n "$singbox_log"      ]] && cleanup_logs+=("$singbox_log")
  [[ -n "$cloudflared_log"  ]] && cleanup_logs+=("$cloudflared_log")
  cleanup_logs+=("$SINGBOX_OPENRC_LOG" "$CLOUDFLARED_OPENRC_LOG")

  log "Uninstall plan:"
  log "  init_system: ${INIT_SYSTEM:-unknown}"
  log "  singbox_bin: ${singbox_bin}"
  log "  cloudflared_bin: ${cloudflared_bin}"
  log "  service files: ${cleanup_units[*]}"
  log "  log files: ${cleanup_logs[*]}"
  log "  config: ${config_path}"
  log "  tls_cert_path: ${tls_cert_path}"
  log "  tls_key_path: ${tls_key_path}"
  log "  cert_managed: ${cert_managed}"
  log "  cert_dir: ${cert_dir} (will remove if empty)"
  log "  state_dir: ${STATE_DIR}"
  log "  dry_run: ${dry_run}"

  if [[ "$dry_run" == "true" ]]; then
    return 0
  fi

  # Stop+disable via both init systems best-effort, so this works regardless of
  # what was actually used to install.
  local prev_init="$INIT_SYSTEM"
  if command -v systemctl >/dev/null 2>&1; then
    INIT_SYSTEM="systemd"
    service_disable_stop "cloudflared.service"
    service_disable_stop "sing-box.service"
  fi
  if command -v rc-service >/dev/null 2>&1; then
    INIT_SYSTEM="openrc"
    service_disable_stop "cloudflared"
    service_disable_stop "sing-box"
  fi
  INIT_SYSTEM="$prev_init"

  local f
  for f in "${cleanup_units[@]}"; do
    rm -f "$f" 2>/dev/null || true
  done
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  rm -f "$singbox_bin" 2>/dev/null || true
  rm -f "$cloudflared_bin" 2>/dev/null || true

  for f in "${cleanup_logs[@]}"; do
    rm -f "$f" 2>/dev/null || true
  done

  rm -f "$config_path" 2>/dev/null || true
  if [[ "$cert_managed" == "true" ]]; then
    rm -f "$tls_cert_path" "$tls_key_path" 2>/dev/null || true
  fi
  rm -f "$SUB_FILE" 2>/dev/null || true
  rm -f "$MANIFEST_FILE" 2>/dev/null || true

  # Remove empty directories only (safe cleanup).
  rmdir "$cert_dir" 2>/dev/null || true
  rmdir "$(dirname "$config_path")" 2>/dev/null || true
  rmdir "$STATE_DIR" 2>/dev/null || true

  log "Uninstall complete."
}

write_subscription() {
  local host="$1" vless_port="$2" hy2_port="$3" tuic_port="$4" ws_path="$5" vless_public_host="$6" vless_public_port="$7" vless_public_security="$8" argo_enabled="${9:-false}" tls_server_name="${10:-www.bing.com}" tls_trusted="${11:-false}"

  ensure_dir "$STATE_DIR"

  local lines=()
  local enc_sni_cert enc_sni_public
  enc_sni_cert="$(uri_encode_query_value "$tls_server_name")"
  enc_sni_public="$(uri_encode_query_value "$vless_public_host")"

  local idx
  for idx in "${!USER_NAMES[@]}"; do
    local name="${USER_NAMES[$idx]}"
    local uuid="${USER_UUIDS[$idx]}"
    local tuic_pw="${USER_TUIC_PASSWORDS[$idx]}"

    if [[ "$vless_port" != "0" ]]; then
      local vh="${vless_public_host}"
      local vp="${vless_public_port}"
      local vs="${vless_public_security}"
      local enc_path
      enc_path="$(uri_encode_query_value "$ws_path")"
      # WS Host header: match public hostname (Argo) or cert CN when address is IP (self-signed).
      local enc_host_ws
      if [[ "$argo_enabled" == "true" ]]; then
        enc_host_ws="${enc_sni_public}"
      else
        enc_host_ws="${enc_sni_cert}"
      fi
      local vq="encryption=none&security=${vs}&type=ws&path=${enc_path}&host=${enc_host_ws}"
      # TLS SNI: self-signed CN (--tls-server-name) vs Argo public hostname (Cloudflare cert).
      if [[ "$vs" == "tls" ]]; then
        if [[ "$argo_enabled" == "true" ]]; then
          vq+="&sni=${enc_sni_public}"
        else
          if [[ "$tls_trusted" != "true" ]]; then
            vq+="&allowInsecure=1&insecure=1"
          fi
          vq+="&sni=${enc_sni_cert}"
        fi
      fi
      vq+="&fp=chrome"
      lines+=("vless://${uuid}@${vh}:${vp}?${vq}#${name}-vless-ws")
    fi

    if [[ "$hy2_port" != "0" ]]; then
      local hq="alpn=h3&sni=${enc_sni_cert}"
      if [[ "$tls_trusted" != "true" ]]; then
        hq="insecure=1&allowInsecure=1&${hq}"
      fi
      lines+=("hy2://${uuid}@${host}:${hy2_port}?${hq}#${name}-hy2")
    fi

    if [[ "$tuic_port" != "0" ]]; then
      local tq="congestion_control=bbr&alpn=h3&sni=${enc_sni_cert}"
      if [[ "$tls_trusted" != "true" ]]; then
        tq="${tq}&insecure=1&allowInsecure=1"
      fi
      lines+=("tuic://${uuid}:${tuic_pw}@${host}:${tuic_port}?${tq}#${name}-tuic")
    fi
  done

  (IFS=$'\n'; printf '%s\n' "${lines[@]}") >"$SUB_FILE"
}

main() {
  local version="$DEFAULT_VERSION"
  local install_dir="$DEFAULT_INSTALL_DIR"
  local config_path="$DEFAULT_CONFIG_PATH"
  local tls_cert_path=""
  local tls_key_path=""
  local tls_server_name=""
  local tls_cert_name=""
  CERT_MANAGED="true"
  local host=""
  local vless_listen_port="$DEFAULT_VLESS_PORT"
  local vless_public_port="$DEFAULT_VLESS_PORT"
  local hy2_listen_port="$DEFAULT_HY2_PORT"
  local hy2_public_port="$DEFAULT_HY2_PORT"
  local tuic_listen_port="$DEFAULT_TUIC_PORT"
  local tuic_public_port="$DEFAULT_TUIC_PORT"
  local ws_path="$DEFAULT_WS_PATH"
  local argo_enabled="$DEFAULT_ARGO_ENABLED"
  local argo_domain=""
  local argo_token=""
  local install_deps="false"
  local verbose="false"
  local tls_trusted="false"

  # Multi-user support (parallel arrays).
  USER_NAMES=()
  USER_UUIDS=()
  USER_TUIC_PASSWORDS=()
  # Per-user outbound proxy (optional). One of: socks5/http/https.
  USER_PROXY_TYPES=()
  USER_PROXY_HOSTS=()
  USER_PROXY_PORTS=()
  USER_PROXY_USERS=()
  USER_PROXY_PASSES=()
  # HTTPS proxy (HTTP proxy over TLS) options.
  USER_PROXY_HTTPS_SNIS=()
  USER_PROXY_HTTPS_INSECURES=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-deps) install_deps="true"; shift 1 ;;
      --verbose) verbose="true"; shift 1 ;;
      --tls-trusted) tls_trusted="true"; shift 1 ;;
      --user)
        # name[:uuid]
        local spec="${2:-}"; shift 2
        [[ -n "$spec" ]] || die "--user requires value name[:uuid]"
        local name_part="${spec%%:*}"
        local uuid_part=""
        if [[ "$spec" == *:* ]]; then uuid_part="${spec#*:}"; fi
        [[ -n "$name_part" ]] || die "Invalid --user value: $spec"
        USER_NAMES+=("$name_part")
        USER_UUIDS+=("$uuid_part")
        USER_TUIC_PASSWORDS+=("") # fill later
        USER_PROXY_TYPES+=("")
        USER_PROXY_HOSTS+=("")
        USER_PROXY_PORTS+=("")
        USER_PROXY_USERS+=("")
        USER_PROXY_PASSES+=("")
        USER_PROXY_HTTPS_SNIS+=("")
        USER_PROXY_HTTPS_INSECURES+=("false")
        ;;
      --user-socks5)
        # name=host:port[:username:password]
        local spec="${2:-}"; shift 2
        [[ -n "$spec" ]] || die "--user-socks5 requires value name=host:port[:username:password]"
        local uname="${spec%%=*}"
        local rest="${spec#*=}"
        [[ -n "$uname" && "$rest" != "$spec" ]] || die "Invalid --user-socks5 value: $spec"
        local host_part="${rest%%:*}"
        local after_host="${rest#*:}"
        [[ -n "$host_part" && "$after_host" != "$rest" ]] || die "Invalid --user-socks5 value: $spec"
        local port_part="${after_host%%:*}"
        local creds_part=""
        if [[ "$after_host" == *:* ]]; then creds_part="${after_host#*:}"; fi
        local su=""; local sp=""
        if [[ -n "$creds_part" ]]; then
          su="${creds_part%%:*}"
          if [[ "$creds_part" == *:* ]]; then sp="${creds_part#*:}"; fi
        fi

        # Find user index by name.
        local found="false"
        local i
        for i in "${!USER_NAMES[@]}"; do
          if [[ "${USER_NAMES[$i]}" == "$uname" ]]; then
            if [[ -n "${USER_PROXY_TYPES[$i]}" && "${USER_PROXY_TYPES[$i]}" != "socks5" ]]; then
              die "User ${uname} already bound to proxy type: ${USER_PROXY_TYPES[$i]} (cannot also set socks5)"
            fi
            USER_PROXY_TYPES[$i]="socks5"
            USER_PROXY_HOSTS[$i]="$host_part"
            USER_PROXY_PORTS[$i]="$port_part"
            USER_PROXY_USERS[$i]="$su"
            USER_PROXY_PASSES[$i]="$sp"
            found="true"
            break
          fi
        done
        [[ "$found" == "true" ]] || die "--user-socks5 references unknown user: $uname (add --user first)"
        ;;
      --user-http|--user-https)
        # name=host:port[:username:password]
        local flag="$1"
        local spec="${2:-}"; shift 2
        [[ -n "$spec" ]] || die "${flag} requires value name=host:port[:username:password]"
        local uname="${spec%%=*}"
        local rest="${spec#*=}"
        [[ -n "$uname" && "$rest" != "$spec" ]] || die "Invalid ${flag} value: $spec"
        local host_part="${rest%%:*}"
        local after_host="${rest#*:}"
        [[ -n "$host_part" && "$after_host" != "$rest" ]] || die "Invalid ${flag} value: $spec"
        local port_part="${after_host%%:*}"
        local creds_part=""
        if [[ "$after_host" == *:* ]]; then creds_part="${after_host#*:}"; fi
        local su=""; local sp=""
        if [[ -n "$creds_part" ]]; then
          su="${creds_part%%:*}"
          if [[ "$creds_part" == *:* ]]; then sp="${creds_part#*:}"; fi
        fi

        local ptype="http"
        if [[ "$flag" == "--user-https" ]]; then ptype="https"; fi

        local found="false"
        local i
        for i in "${!USER_NAMES[@]}"; do
          if [[ "${USER_NAMES[$i]}" == "$uname" ]]; then
            if [[ -n "${USER_PROXY_TYPES[$i]}" && "${USER_PROXY_TYPES[$i]}" != "$ptype" ]]; then
              die "User ${uname} already bound to proxy type: ${USER_PROXY_TYPES[$i]} (cannot also set ${ptype})"
            fi
            USER_PROXY_TYPES[$i]="$ptype"
            USER_PROXY_HOSTS[$i]="$host_part"
            USER_PROXY_PORTS[$i]="$port_part"
            USER_PROXY_USERS[$i]="$su"
            USER_PROXY_PASSES[$i]="$sp"
            # Default SNI for https proxy: use host (can be overridden by --user-https-sni).
            if [[ "$ptype" == "https" && -z "${USER_PROXY_HTTPS_SNIS[$i]}" ]]; then
              USER_PROXY_HTTPS_SNIS[$i]="$host_part"
            fi
            found="true"
            break
          fi
        done
        [[ "$found" == "true" ]] || die "${flag} references unknown user: $uname (add --user first)"
        ;;
      --user-https-sni)
        # name=server_name
        local spec="${2:-}"; shift 2
        [[ -n "$spec" ]] || die "--user-https-sni requires value name=server_name"
        local uname="${spec%%=*}"
        local sni="${spec#*=}"
        [[ -n "$uname" && -n "$sni" && "$sni" != "$spec" ]] || die "Invalid --user-https-sni value: $spec"
        local found="false"
        local i
        for i in "${!USER_NAMES[@]}"; do
          if [[ "${USER_NAMES[$i]}" == "$uname" ]]; then
            USER_PROXY_HTTPS_SNIS[$i]="$sni"
            found="true"
            break
          fi
        done
        [[ "$found" == "true" ]] || die "--user-https-sni references unknown user: $uname (add --user first)"
        ;;
      --user-https-insecure)
        # name=true|false
        local spec="${2:-}"; shift 2
        [[ -n "$spec" ]] || die "--user-https-insecure requires value name=true|false"
        local uname="${spec%%=*}"
        local val="${spec#*=}"
        [[ -n "$uname" && -n "$val" && "$val" != "$spec" ]] || die "Invalid --user-https-insecure value: $spec"
        [[ "$val" == "true" || "$val" == "false" ]] || die "Invalid --user-https-insecure value: $spec (expected true|false)"
        local found="false"
        local i
        for i in "${!USER_NAMES[@]}"; do
          if [[ "${USER_NAMES[$i]}" == "$uname" ]]; then
            USER_PROXY_HTTPS_INSECURES[$i]="$val"
            found="true"
            break
          fi
        done
        [[ "$found" == "true" ]] || die "--user-https-insecure references unknown user: $uname (add --user first)"
        ;;
      --version) version="${2:-}"; shift 2 ;;
      --install-dir) install_dir="${2:-}"; shift 2 ;;
      --config) config_path="${2:-}"; shift 2 ;;
      --tls-cert-path) tls_cert_path="${2:-}"; shift 2 ;;
      --tls-key-path) tls_key_path="${2:-}"; shift 2 ;;
      --tls-server-name) tls_server_name="${2:-}"; shift 2 ;;
      --tls-cert-name) tls_cert_name="${2:-}"; shift 2 ;;
      --host) host="${2:-}"; shift 2 ;;
      --vless-port) parse_port "--vless-port" "${2:-}"; vless_public_port="$_PORT_PUBLIC"; vless_listen_port="$_PORT_LISTEN"; shift 2 ;;
      --ws-path) ws_path="${2:-}"; shift 2 ;;
      --argo) argo_enabled="true"; shift 1 ;;
      --argo-domain) argo_domain="${2:-}"; shift 2 ;;
      --argo-token) argo_token="${2:-}"; shift 2 ;;
      --hy2-port) parse_port "--hy2-port" "${2:-}"; hy2_public_port="$_PORT_PUBLIC"; hy2_listen_port="$_PORT_LISTEN"; shift 2 ;;
      --tuic-port) parse_port "--tuic-port" "${2:-}"; tuic_public_port="$_PORT_PUBLIC"; tuic_listen_port="$_PORT_LISTEN"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  is_root || die "Please run as root (use sudo)."

  INIT_SYSTEM="$(detect_init)"
  if [[ "$INIT_SYSTEM" == "unknown" ]]; then
    die "No supported init system found (need systemd or OpenRC)."
  fi
  log "Detected init system: ${INIT_SYSTEM}"

  DOWNLOAD_VERBOSE="$verbose"
  # openssl is needed by gen_self_signed_cert(); include it here so --install-deps
  # actually installs it (it's only invoked deep in the flow via need_cmd, and skipping
  # auto-install caused "Missing required command: openssl" on minimal Alpine images).
  ensure_cmds_or_install "$install_deps" \
    uname tar sed head tr cut dirname mkdir cat chmod install mktemp date openssl
  need_http_client

  local arch
  arch="$(detect_arch)"
  log "Detected arch: linux-${arch}"

  # Backward compatible single-user mode.
  if [[ "${#USER_NAMES[@]}" -eq 0 ]]; then
    USER_NAMES+=("user")
    USER_UUIDS+=("")
    USER_TUIC_PASSWORDS+=("")
    USER_PROXY_TYPES+=("")
    USER_PROXY_HOSTS+=("")
    USER_PROXY_PORTS+=("")
    USER_PROXY_USERS+=("")
    USER_PROXY_PASSES+=("")
    USER_PROXY_HTTPS_SNIS+=("")
    USER_PROXY_HTTPS_INSECURES+=("false")
  fi

  # Fill UUIDs and per-user TUIC passwords.
  local idx
  for idx in "${!USER_NAMES[@]}"; do
    if [[ -z "${USER_UUIDS[$idx]}" ]]; then
      USER_UUIDS[$idx]="$(gen_uuid)"
    fi
    USER_TUIC_PASSWORDS[$idx]="${USER_UUIDS[$idx]}"

    # Validate per-user proxy config.
    local ptype="${USER_PROXY_TYPES[$idx]}"
    if [[ "$ptype" == "https" ]]; then
      local p_sni="${USER_PROXY_HTTPS_SNIS[$idx]}"
      [[ -n "$p_sni" ]] || USER_PROXY_HTTPS_SNIS[$idx]="${USER_PROXY_HOSTS[$idx]}"
    else
      # Non-https proxy should not have https-only options.
      if [[ -n "${USER_PROXY_HTTPS_SNIS[$idx]}" ]]; then
        die "User ${USER_NAMES[$idx]} has --user-https-sni set but is not using --user-https"
      fi
      if [[ "${USER_PROXY_HTTPS_INSECURES[$idx]}" != "false" ]]; then
        die "User ${USER_NAMES[$idx]} has --user-https-insecure set but is not using --user-https"
      fi
    fi
  done

  if [[ -z "$host" ]]; then
    host="$(detect_public_ip)"
  fi
  [[ -n "$host" ]] || die "Failed to detect public IP. Please provide --host <public_ip>."

  # TLS name defaults:
  # - If neither is set, use defaults.
  # - If only one is set, let the other follow it.
  if [[ -z "$tls_server_name" && -z "$tls_cert_name" ]]; then
    tls_server_name="$DEFAULT_TLS_SERVER_NAME"
    tls_cert_name="$DEFAULT_TLS_CERT_NAME"
  elif [[ -z "$tls_cert_name" ]]; then
    tls_cert_name="$tls_server_name"
  elif [[ -z "$tls_server_name" ]]; then
    tls_server_name="$tls_cert_name"
  fi

  # TLS certificate path defaults:
  # - If one is set, the other must also be set.
  # - If neither is set, use default paths (and generate/reuse self-signed when needed).
  if [[ -n "$tls_cert_path" || -n "$tls_key_path" ]]; then
    [[ -n "$tls_cert_path" && -n "$tls_key_path" ]] || die "--tls-cert-path and --tls-key-path must be set together"
    CERT_MANAGED="false"
  else
    tls_cert_path="$DEFAULT_TLS_CERT_PATH"
    tls_key_path="$DEFAULT_TLS_KEY_PATH"
  fi

  # Validate enabled listen ports are unique (they bind to the same host).
  if [[ "$vless_listen_port" != "0" && "$hy2_listen_port" != "0" && "$vless_listen_port" == "$hy2_listen_port" ]]; then
    die "--vless-port and --hy2-port listen ports cannot be the same (${vless_listen_port})"
  fi
  if [[ "$vless_listen_port" != "0" && "$tuic_listen_port" != "0" && "$vless_listen_port" == "$tuic_listen_port" ]]; then
    die "--vless-port and --tuic-port listen ports cannot be the same (${vless_listen_port})"
  fi
  if [[ "$hy2_listen_port" != "0" && "$tuic_listen_port" != "0" && "$hy2_listen_port" == "$tuic_listen_port" ]]; then
    die "--hy2-port and --tuic-port listen ports cannot be the same (${hy2_listen_port})"
  fi

  log "Preparing to install:"
  log "  version: ${version}"
  log "  install_dir: ${install_dir}"
  log "  config: ${config_path}"
  log "  tls_cert_path: ${tls_cert_path}"
  log "  tls_key_path: ${tls_key_path}"
  log "  tls_server_name: ${tls_server_name}"
  log "  tls_cert_name: ${tls_cert_name}"
  log "  tls_trusted: ${tls_trusted}"
  log "  install_deps: ${install_deps}"
  log "  verbose: ${verbose}"
  log "  host: ${host}"
  log "  users: ${#USER_NAMES[@]}"
  if [[ "$vless_listen_port" == "$vless_public_port" ]]; then
    log "  vless_port: ${vless_listen_port}"
  else
    log "  vless_port: ${vless_public_port}:${vless_listen_port} (public:listen)"
  fi
  if [[ "$hy2_listen_port" == "$hy2_public_port" ]]; then
    log "  hy2_port: ${hy2_listen_port}"
  else
    log "  hy2_port: ${hy2_public_port}:${hy2_listen_port} (public:listen)"
  fi
  if [[ "$tuic_listen_port" == "$tuic_public_port" ]]; then
    log "  tuic_port: ${tuic_listen_port}"
  else
    log "  tuic_port: ${tuic_public_port}:${tuic_listen_port} (public:listen)"
  fi
  log "  ws_path: ${ws_path}"
  log "  argo_enabled: ${argo_enabled}"
  if [[ -n "$argo_domain" ]]; then log "  argo_domain: ${argo_domain}"; fi

  local tmp_tgz
  # BusyBox mktemp requires TEMPLATE to end with XXXXXX (no trailing suffix). The
  # extension is irrelevant to `tar -xzf`, which detects gzip from content/`-z`.
  tmp_tgz="$(mktemp -t sing-box.XXXXXX)" || die "Failed to create temp tarball path"
  # EXIT runs after `main` returns; `local tmp_tgz` may be unset then (set -u).
  trap "rm -f $(sh_quote "$tmp_tgz")" EXIT

  # sing-box release tarball layout is stable: sing-box-<ver>-linux-<arch>/sing-box
  local ver_in_file="${version#v}"
  download_release_tarball "$version" "$arch" "$tmp_tgz"
  install_binary_from_tarball "$tmp_tgz" "$install_dir" "$ver_in_file" "$arch"

  # On Alpine, the glibc-linked sing-box binary needs the `gcompat` shim.
  ensure_alpine_glibc_compat "$install_deps"

  if ! "${install_dir}/${BIN_NAME}" version >/dev/null 2>&1; then
    if is_alpine; then
      log_err "Hint: on Alpine, run 'apk add gcompat' (or re-run with --install-deps)."
    fi
    die "Installed binary failed to run"
  fi
  "${install_dir}/${BIN_NAME}" version

  if [[ "$argo_enabled" == "true" && "$vless_listen_port" == "0" ]]; then
    die "--argo requires --vless-port to be enabled (non-zero)"
  fi
  if [[ -n "$argo_token" && -z "$argo_domain" ]]; then
    die "--argo-token requires --argo-domain"
  fi

  # Cert generation:
  # - vless requires TLS only when argo is disabled (public WSS self-signed)
  # - hy2/tuic always require TLS
  if [[ "$hy2_listen_port" != "0" || "$tuic_listen_port" != "0" || ( "$vless_listen_port" != "0" && "$argo_enabled" != "true" ) ]]; then
    if [[ "$CERT_MANAGED" == "true" ]]; then
      gen_self_signed_cert "$tls_cert_path" "$tls_key_path" "$tls_cert_name"
    fi
  fi

  local vless_listen="::"
  local vless_tls_enabled="false"
  local vless_public_host="$host"
  local vless_sub_port="$vless_public_port"
  local vless_public_security="none"

  if [[ "$vless_listen_port" != "0" ]]; then
    if [[ "$argo_enabled" != "true" ]]; then
      vless_listen="::"
      vless_tls_enabled="true"
      vless_public_host="$host"
      vless_sub_port="$vless_public_port"
      vless_public_security="tls"
    else
      vless_listen="127.0.0.1"
      vless_tls_enabled="false"
      vless_sub_port="443"
      vless_public_security="tls"
    fi
  fi

  write_config "$config_path" "$tls_cert_path" "$tls_key_path" "$hy2_listen_port" "$tuic_listen_port" "$vless_listen_port" "$ws_path" "$vless_listen" "$vless_tls_enabled"

  # Validate config before starting service.
  "${install_dir}/${BIN_NAME}" check -c "$config_path" || die "Config validation failed: ${config_path}"

  write_singbox_service "$install_dir" "$config_path"
  service_enable_start "sing-box"

  # Setup cloudflared if needed.
  if [[ "$argo_enabled" == "true" ]]; then
    install_cloudflared "$install_dir"
    local origin_url="http://127.0.0.1:${vless_listen_port}"

    local argo_mode=""
    if [[ -n "$argo_domain" && -n "$argo_token" ]]; then
      argo_mode="token"
    else
      argo_mode="try"
    fi

    if [[ "$argo_mode" == "try" ]]; then
      if [[ -n "$argo_domain" && -z "$argo_token" ]]; then
        log "Ignoring --argo-domain without --argo-token (temporary tunnel domain is assigned automatically)."
        argo_domain=""
      fi
      write_cloudflared_service "$install_dir" "try" "$origin_url" ""
      local since_epoch
      since_epoch="$(date +%s)"
      # OpenRC: truncate the log so we don't pick up a stale domain from a previous run.
      if [[ "$INIT_SYSTEM" == "openrc" ]]; then
        ensure_dir "$(dirname "$CLOUDFLARED_OPENRC_LOG")"
        : >"$CLOUDFLARED_OPENRC_LOG" 2>/dev/null || true
      fi
      service_enable_start "cloudflared"
      argo_domain="$(wait_trycloudflare_domain 60 "$since_epoch")"
      if [[ -z "$argo_domain" ]]; then
        if [[ "$INIT_SYSTEM" == "systemd" ]]; then
          die "Failed to read Quick Tunnel domain from cloudflared logs. Try: journalctl -u cloudflared.service -n 80 --no-pager"
        else
          die "Failed to read Quick Tunnel domain from cloudflared logs. Try: tail -n 80 ${CLOUDFLARED_OPENRC_LOG}"
        fi
      fi
    else
      write_cloudflared_service "$install_dir" "token" "$origin_url" "$argo_token"
      service_enable_start "cloudflared"
    fi

    vless_public_host="$argo_domain"
  fi

  write_subscription "$host" "$vless_public_port" "$hy2_public_port" "$tuic_public_port" "$ws_path" "$vless_public_host" "$vless_sub_port" "$vless_public_security" "$argo_enabled" "$tls_server_name" "$tls_trusted"
  write_manifest "${install_dir}/${BIN_NAME}" "${install_dir}/cloudflared" "$config_path" "$tls_cert_path" "$tls_key_path"

  log "Installed ${BIN_NAME} to ${install_dir}/${BIN_NAME}"
  log "Config: ${config_path}"
  if [[ "$hy2_listen_port" != "0" || "$tuic_listen_port" != "0" || ( "$vless_listen_port" != "0" && "$argo_enabled" != "true" ) ]]; then
    if [[ "${CERT_MANAGED:-false}" == "true" ]]; then
      log "Cert: ${tls_cert_path} (self-signed)"
    else
      log "Cert: ${tls_cert_path} (existing)"
    fi
  fi
  log "Subscription file: ${SUB_FILE}"
  log "Import links:"
  cat "$SUB_FILE"
}

if [[ "${1:-}" == "uninstall" ]]; then
  shift 1
  uninstall_main "$@"
else
  main "$@"
fi

