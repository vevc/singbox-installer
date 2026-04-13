#!/usr/bin/env bash
# Copyright (c) 2026 vevc
# SPDX-License-Identifier: MIT
set -euo pipefail

PROJECT="sing-box"
REPO="SagerNet/sing-box"

DEFAULT_VERSION="v1.13.7"
DEFAULT_INSTALL_DIR="/usr/local/bin"
DEFAULT_CONFIG_PATH="/etc/sing-box/config.json"
DEFAULT_CERT_DIR="/etc/sing-box/certs"
DEFAULT_CERT_CN="www.bing.com"
DEFAULT_VLESS_PORT="0"
DEFAULT_HY2_PORT="0"
DEFAULT_TUIC_PORT="0"
DEFAULT_WS_PATH="/"

DEFAULT_ARGO_ENABLED="false"

STATE_DIR="/var/lib/sing-box"
SUB_FILE="${STATE_DIR}/sub.txt"
MANIFEST_FILE="${STATE_DIR}/manifest.env"

BIN_NAME="sing-box"

usage() {
  cat <<'EOF'
sing-box one-click installer (systemd, vless-ws/hy2/tuic + cloudflare argo tunnel)

Usage:
  sudo ./install.sh [options]
  sudo ./install.sh uninstall [--dry-run] [--purge]

Options:
  --install-deps                 automatically install missing dependencies (default: disabled)
  --version <tag|latest>        sing-box version tag (default: v1.13.7)
  --install-dir <dir>           install dir for sing-box binary (default: /usr/local/bin)
  --config <path>               config path (default: /etc/sing-box/config.json)
  --cert-dir <dir>              cert output dir (default: /etc/sing-box/certs)
  --cert-cn <name>              self-signed cert CN (default: www.bing.com)
  --host <public_ip>            address used in subscription (default: auto-detect)
  --user <name[:uuid]>          add a user (repeatable). uuid auto-generated if omitted
  --user-socks5 <spec>          bind user to socks5 outbound (repeatable)
                               spec: name=host:port[:username:password]
  --vless-port <port>           vless+ws port (TCP). set 0 to disable (default: 0)
  --ws-path <path>              websocket path for vless+ws (default: /)
  --argo                         enable Cloudflare Tunnel for vless (default: disabled)
  --argo-domain <domain>         public domain for a Named Tunnel (used only when --argo-token is also set)
  --argo-token <token>           Named Tunnel token (when set -> use Named Tunnel; otherwise -> use Quick Tunnel with a *.trycloudflare.com domain)
  --hy2-port <port>             hysteria2 port (UDP). set 0 to disable (default: 0)
  --tuic-port <port>            tuic port (UDP). set 0 to disable (default: 0)
  -h, --help                    show this help

Uninstall:
  --dry-run                     print planned paths; do not remove anything
  --purge                       also remove config, certs, state, cloudflared config

Notes:
  - This script generates a self-signed certificate. Clients must enable insecure/skip TLS verify.
  - vless+ws behavior:
      - argo disabled: vless is exposed publicly as WSS with self-signed cert.
      - argo enabled: vless listens on 127.0.0.1 with plain WS; cloudflared provides public HTTPS.
  - hy2 (hysteria2) and tuic are UDP-based; ensure firewall allows UDP ports.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "[*] $*"; }

sh_quote() {
  # Quote a string so it can be safely eval/source'd in bash.
  printf "%q" "$1"
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
    find) echo "findutils" ;;
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
    curl -fsSL --retry 3 --retry-delay 1 -o "$out" "$url"
  else
    wget -q -O "$out" "$url"
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
  local vless_port="$1" ws_path="$2" vless_listen="$3" vless_tls_enabled="$4" cert_dir="$5" users_json="$6"

  local tls_block=""
  if [[ "$vless_tls_enabled" == "true" ]]; then
    tls_block=$',\n      "tls": {\n        "enabled": true,\n        "certificate_path": "'"$(json_escape "${cert_dir}/server.crt")"$'",\n        "key_path": "'"$(json_escape "${cert_dir}/server.key")"$'"\n      }'
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
  local hy2_port="$1" cert_dir="$2" users_json="$3"
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
        "certificate_path": "$(json_escape "${cert_dir}/server.crt")",
        "key_path": "$(json_escape "${cert_dir}/server.key")"
      }
    }
EOF
}

build_tuic_inbound() {
  local tuic_port="$1" cert_dir="$2" users_json="$3"
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
        "certificate_path": "$(json_escape "${cert_dir}/server.crt")",
        "key_path": "$(json_escape "${cert_dir}/server.key")"
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
  local tarball="$1" install_dir="$2"
  local tmpdir
  tmpdir="$(mktemp -d)" || die "Failed to create temp directory"
  # Expand path when registering the trap: on RETURN, `local tmpdir` may already be
  # unset (set -u), so the trap must not reference $tmpdir at fire time.
  trap "rm -rf $(sh_quote "$tmpdir")" RETURN

  tar -xzf "$tarball" -C "$tmpdir"

  local found
  found="$(find "$tmpdir" -type f -name "$BIN_NAME" -perm -u+x 2>/dev/null | head -n 1 || true)"
  [[ -n "$found" ]] || found="$(find "$tmpdir" -type f -name "$BIN_NAME" 2>/dev/null | head -n 1 || true)"
  [[ -n "$found" ]] || die "Failed to find ${BIN_NAME} in tarball"

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
  local cert_dir="$1" cn="$2"
  local key_path="${cert_dir}/server.key"
  local crt_path="${cert_dir}/server.crt"

  ensure_dir "$cert_dir"

  if [[ -s "$key_path" && -s "$crt_path" ]]; then
    log "Existing certificate found in ${cert_dir}, reusing."
    return 0
  fi

  need_cmd openssl
  log "Generating self-signed certificate in ${cert_dir}"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$key_path" \
    -out "$crt_path" \
    -subj "/CN=${cn}"

  chmod 600 "$key_path"
  chmod 644 "$crt_path"
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
  "$out" --version >/dev/null 2>&1 || die "cloudflared installed but failed to run"
}

write_cloudflared_config() {
  local origin_url="$1"
  local config_dir="/etc/cloudflared"
  local config_path="${config_dir}/config.yml"

  ensure_dir "$config_dir"
  cat >"$config_path" <<EOF
ingress:
  - service: ${origin_url}
  - service: http_status:404
EOF
}

write_cloudflared_service() {
  local install_dir="$1"
  local argo_mode="$2"
  local origin_url="$3"
  local argo_token="$4"

  local unit_path="/etc/systemd/system/cloudflared.service"
  local exec=""

  if [[ "$argo_mode" == "try" ]]; then
    exec="${install_dir}/cloudflared tunnel --no-autoupdate --url ${origin_url}"
  elif [[ "$argo_mode" == "token" ]]; then
    exec="${install_dir}/cloudflared tunnel --no-autoupdate --config /etc/cloudflared/config.yml run --token ${argo_token}"
  else
    die "write_cloudflared_service called with invalid mode: ${argo_mode}"
  fi

  cat >"$unit_path" <<EOF
[Unit]
Description=cloudflared tunnel
After=network-online.target sing-box.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=${exec}
Restart=on-failure
RestartSec=2
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

detect_trycloudflare_domain() {
  local install_dir="$1"
  local origin_url="$2"

  need_cmd timeout
  # Capture first trycloudflare domain from output.
  local out
  out="$(timeout 20s "${install_dir}/cloudflared" tunnel --no-autoupdate --url "${origin_url}" 2>&1 || true)"
  echo "$out" | sed -n 's/.*https:\/\/\([^[:space:]]*\.trycloudflare\.com\).*/\1/p' | head -n 1
}

write_config() {
  local config_path="$1"
  local cert_dir="$2"
  local hy2_port="$3"
  local tuic_port="$4"
  local vless_port="$5"
  local ws_path="$6"
  local vless_listen="$7"
  local vless_tls_enabled="$8" # true|false

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

    local socks_host="${USER_SOCKS_HOSTS[$idx]}"
    local socks_port="${USER_SOCKS_PORTS[$idx]}"
    local socks_user="${USER_SOCKS_USERS[$idx]}"
    local socks_pass="${USER_SOCKS_PASSES[$idx]}"
    if [[ -n "$socks_host" ]]; then
      local tag="socks_$(sanitize_tag "$name")"
      outbounds_extra+=("$(build_socks5_outbound "$tag" "$socks_host" "$socks_port" "$socks_user" "$socks_pass")")
      route_rules+=("$(build_route_rule_auth_user "$name" "$tag")")
    fi
  done

  local inbounds_json=()
  if [[ "$vless_port" != "0" ]]; then
    inbounds_json+=("$(build_vless_ws_inbound "$vless_port" "$ws_path" "$vless_listen" "$vless_tls_enabled" "$cert_dir" "$users_vless")")
  fi
  if [[ "$hy2_port" != "0" ]]; then
    inbounds_json+=("$(build_hy2_inbound "$hy2_port" "$cert_dir" "$users_hy2")")
  fi
  if [[ "$tuic_port" != "0" ]]; then
    inbounds_json+=("$(build_tuic_inbound "$tuic_port" "$cert_dir" "$users_tuic")")
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
  local unit_path="/etc/systemd/system/sing-box.service"

  cat >"$unit_path" <<EOF
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

systemd_reload_enable_start() {
  local svc="$1"
  need_cmd systemctl
  systemctl daemon-reload
  # Ensure changes apply on re-run too.
  systemctl enable "$svc" >/dev/null 2>&1 || true
  systemctl restart "$svc"
}

write_manifest() {
  local singbox_bin="$1"
  local cloudflared_bin="$2"
  local config_path="$3"
  local cert_dir="$4"
  local singbox_unit="/etc/systemd/system/sing-box.service"
  local cloudflared_unit="/etc/systemd/system/cloudflared.service"
  local cloudflared_config="/etc/cloudflared/config.yml"

  ensure_dir "$STATE_DIR"
  cat >"$MANIFEST_FILE" <<EOF
STATE_DIR=$(sh_quote "$STATE_DIR")
SUB_FILE=$(sh_quote "$SUB_FILE")
CONFIG_PATH=$(sh_quote "$config_path")
CERT_DIR=$(sh_quote "$cert_dir")
SINGBOX_BIN=$(sh_quote "$singbox_bin")
CLOUDFLARED_BIN=$(sh_quote "$cloudflared_bin")
SINGBOX_UNIT=$(sh_quote "$singbox_unit")
CLOUDFLARED_UNIT=$(sh_quote "$cloudflared_unit")
CLOUDFLARED_CONFIG=$(sh_quote "$cloudflared_config")
EOF
  chmod 600 "$MANIFEST_FILE" 2>/dev/null || true
}

uninstall_main() {
  local purge="false"
  local dry_run="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge) purge="true"; shift 1 ;;
      --dry-run) dry_run="true"; shift 1 ;;
      -h|--help)
        cat <<'EOF'
Usage:
  sudo ./install.sh uninstall [--dry-run] [--purge]

Options:
  --dry-run   Print actions without executing
  --purge     Remove config/certs/state files too
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
  local cert_dir="$DEFAULT_CERT_DIR"
  local singbox_unit="/etc/systemd/system/sing-box.service"
  local cloudflared_unit="/etc/systemd/system/cloudflared.service"
  local cloudflared_config="/etc/cloudflared/config.yml"

  if [[ -r "$MANIFEST_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$MANIFEST_FILE" || true
    singbox_bin="${SINGBOX_BIN:-$singbox_bin}"
    cloudflared_bin="${CLOUDFLARED_BIN:-$cloudflared_bin}"
    config_path="${CONFIG_PATH:-$config_path}"
    cert_dir="${CERT_DIR:-$cert_dir}"
    singbox_unit="${SINGBOX_UNIT:-$singbox_unit}"
    cloudflared_unit="${CLOUDFLARED_UNIT:-$cloudflared_unit}"
    cloudflared_config="${CLOUDFLARED_CONFIG:-$cloudflared_config}"
  fi

  log "Uninstall plan:"
  log "  singbox_bin: ${singbox_bin}"
  log "  cloudflared_bin: ${cloudflared_bin}"
  log "  singbox_unit: ${singbox_unit}"
  log "  cloudflared_unit: ${cloudflared_unit}"
  log "  config: ${config_path}"
  log "  cert_dir: ${cert_dir}"
  log "  state_dir: ${STATE_DIR}"
  log "  purge: ${purge}"
  log "  dry_run: ${dry_run}"

  if [[ "$dry_run" == "true" ]]; then
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now cloudflared.service >/dev/null 2>&1 || true
    systemctl disable --now sing-box.service >/dev/null 2>&1 || true
  fi

  rm -f "$cloudflared_unit" "$singbox_unit" 2>/dev/null || true
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  rm -f "$singbox_bin" 2>/dev/null || true
  rm -f "$cloudflared_bin" 2>/dev/null || true
  rm -f "$MANIFEST_FILE" 2>/dev/null || true

  if [[ "$purge" == "true" ]]; then
    rm -f "$config_path" 2>/dev/null || true
    rm -rf "$cert_dir" 2>/dev/null || true
    rm -f "$cloudflared_config" 2>/dev/null || true
    rm -rf "$STATE_DIR" 2>/dev/null || true
  fi

  log "Uninstall complete."
}

write_subscription() {
  local host="$1" vless_port="$2" hy2_port="$3" tuic_port="$4" ws_path="$5" vless_public_host="$6" vless_public_port="$7" vless_public_security="$8" argo_enabled="${9:-false}" cert_cn="${10:-www.bing.com}"

  ensure_dir "$STATE_DIR"

  local lines=()
  local enc_sni_cert enc_sni_public
  enc_sni_cert="$(uri_encode_query_value "$cert_cn")"
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
      # TLS SNI: self-signed CN (--cert-cn) vs Argo public hostname (Cloudflare cert).
      if [[ "$vs" == "tls" ]]; then
        if [[ "$argo_enabled" == "true" ]]; then
          vq+="&sni=${enc_sni_public}"
        else
          vq+="&allowInsecure=1&insecure=1"
          vq+="&sni=${enc_sni_cert}"
        fi
      fi
      vq+="&fp=chrome"
      lines+=("vless://${uuid}@${vh}:${vp}?${vq}#${name}-vless-ws")
    fi

    if [[ "$hy2_port" != "0" ]]; then
      lines+=("hy2://${uuid}@${host}:${hy2_port}?insecure=1&allowInsecure=1&alpn=h3&sni=${enc_sni_cert}#${name}-hy2")
    fi

    if [[ "$tuic_port" != "0" ]]; then
      lines+=("tuic://${uuid}:${tuic_pw}@${host}:${tuic_port}?congestion_control=bbr&alpn=h3&insecure=1&allowInsecure=1&sni=${enc_sni_cert}#${name}-tuic")
    fi
  done

  (IFS=$'\n'; printf '%s\n' "${lines[@]}") >"$SUB_FILE"
}

main() {
  local version="$DEFAULT_VERSION"
  local install_dir="$DEFAULT_INSTALL_DIR"
  local config_path="$DEFAULT_CONFIG_PATH"
  local cert_dir="$DEFAULT_CERT_DIR"
  local cert_cn="$DEFAULT_CERT_CN"
  local host=""
  local vless_port="$DEFAULT_VLESS_PORT"
  local hy2_port="$DEFAULT_HY2_PORT"
  local tuic_port="$DEFAULT_TUIC_PORT"
  local ws_path="$DEFAULT_WS_PATH"
  local argo_enabled="$DEFAULT_ARGO_ENABLED"
  local argo_domain=""
  local argo_token=""
  local install_deps="false"

  # Multi-user support (parallel arrays).
  USER_NAMES=()
  USER_UUIDS=()
  USER_TUIC_PASSWORDS=()
  USER_SOCKS_HOSTS=()
  USER_SOCKS_PORTS=()
  USER_SOCKS_USERS=()
  USER_SOCKS_PASSES=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --install-deps) install_deps="true"; shift 1 ;;
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
        USER_SOCKS_HOSTS+=("")
        USER_SOCKS_PORTS+=("")
        USER_SOCKS_USERS+=("")
        USER_SOCKS_PASSES+=("")
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
            USER_SOCKS_HOSTS[$i]="$host_part"
            USER_SOCKS_PORTS[$i]="$port_part"
            USER_SOCKS_USERS[$i]="$su"
            USER_SOCKS_PASSES[$i]="$sp"
            found="true"
            break
          fi
        done
        [[ "$found" == "true" ]] || die "--user-socks5 references unknown user: $uname (add --user first)"
        ;;
      --version) version="${2:-}"; shift 2 ;;
      --install-dir) install_dir="${2:-}"; shift 2 ;;
      --config) config_path="${2:-}"; shift 2 ;;
      --cert-dir) cert_dir="${2:-}"; shift 2 ;;
      --cert-cn) cert_cn="${2:-}"; shift 2 ;;
      --host) host="${2:-}"; shift 2 ;;
      --vless-port) vless_port="${2:-}"; shift 2 ;;
      --ws-path) ws_path="${2:-}"; shift 2 ;;
      --argo) argo_enabled="true"; shift 1 ;;
      --argo-domain) argo_domain="${2:-}"; shift 2 ;;
      --argo-token) argo_token="${2:-}"; shift 2 ;;
      --hy2-port) hy2_port="${2:-}"; shift 2 ;;
      --tuic-port) tuic_port="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  is_root || die "Please run as root (use sudo)."

  ensure_cmds_or_install "$install_deps" \
    uname tar sed head tr cut dirname mkdir cat chmod install mktemp find
  need_http_client

  local arch
  arch="$(detect_arch)"
  log "Detected arch: linux-${arch}"

  # Backward compatible single-user mode.
  if [[ "${#USER_NAMES[@]}" -eq 0 ]]; then
    USER_NAMES+=("user")
    USER_UUIDS+=("")
    USER_TUIC_PASSWORDS+=("")
    USER_SOCKS_HOSTS+=("")
    USER_SOCKS_PORTS+=("")
    USER_SOCKS_USERS+=("")
    USER_SOCKS_PASSES+=("")
  fi

  # Fill UUIDs and per-user TUIC passwords.
  local idx
  for idx in "${!USER_NAMES[@]}"; do
    if [[ -z "${USER_UUIDS[$idx]}" ]]; then
      USER_UUIDS[$idx]="$(gen_uuid)"
    fi
    USER_TUIC_PASSWORDS[$idx]="${USER_UUIDS[$idx]}"
  done

  if [[ -z "$host" ]]; then
    host="$(detect_public_ip)"
  fi
  [[ -n "$host" ]] || die "Failed to detect public IP. Please provide --host <public_ip>."

  # Validate enabled ports are unique.
  if [[ "$vless_port" != "0" && "$hy2_port" != "0" && "$vless_port" == "$hy2_port" ]]; then
    die "--vless-port and --hy2-port cannot be the same"
  fi
  if [[ "$vless_port" != "0" && "$tuic_port" != "0" && "$vless_port" == "$tuic_port" ]]; then
    die "--vless-port and --tuic-port cannot be the same"
  fi
  if [[ "$hy2_port" != "0" && "$tuic_port" != "0" && "$hy2_port" == "$tuic_port" ]]; then
    die "--hy2-port and --tuic-port cannot be the same"
  fi

  log "Preparing to install:"
  log "  version: ${version}"
  log "  install_dir: ${install_dir}"
  log "  config: ${config_path}"
  log "  cert_dir: ${cert_dir}"
  log "  host: ${host}"
  log "  users: ${#USER_NAMES[@]}"
  log "  vless_port: ${vless_port}"
  log "  hy2_port: ${hy2_port}"
  log "  tuic_port: ${tuic_port}"
  log "  ws_path: ${ws_path}"
  log "  argo_enabled: ${argo_enabled}"
  if [[ -n "$argo_domain" ]]; then log "  argo_domain: ${argo_domain}"; fi

  local tmp_tgz
  tmp_tgz="$(mktemp -t sing-box.XXXXXX.tar.gz)" || die "Failed to create temp tarball path"
  # EXIT runs after `main` returns; `local tmp_tgz` may be unset then (set -u).
  trap "rm -f $(sh_quote "$tmp_tgz")" EXIT

  download_release_tarball "$version" "$arch" "$tmp_tgz"
  install_binary_from_tarball "$tmp_tgz" "$install_dir"

  "${install_dir}/${BIN_NAME}" version || die "Installed binary failed to run"

  if [[ "$argo_enabled" == "true" && "$vless_port" == "0" ]]; then
    die "--argo requires --vless-port to be enabled (non-zero)"
  fi
  if [[ -n "$argo_token" && -z "$argo_domain" ]]; then
    die "--argo-token requires --argo-domain"
  fi

  # Cert generation:
  # - vless requires TLS only when argo is disabled (public WSS self-signed)
  # - hy2/tuic always require TLS
  if [[ "$hy2_port" != "0" || "$tuic_port" != "0" || ( "$vless_port" != "0" && "$argo_enabled" != "true" ) ]]; then
    gen_self_signed_cert "$cert_dir" "$cert_cn"
  fi

  local vless_listen="::"
  local vless_tls_enabled="false"
  local vless_public_host="$host"
  local vless_public_port="$vless_port"
  local vless_public_security="none"

  if [[ "$vless_port" != "0" ]]; then
    if [[ "$argo_enabled" != "true" ]]; then
      # Public WSS with self-signed cert.
      vless_listen="::"
      vless_tls_enabled="true"
      vless_public_host="$host"
      vless_public_port="$vless_port"
      vless_public_security="tls"
    else
      # Only local origin; cloudflared provides public HTTPS on 443.
      vless_listen="127.0.0.1"
      vless_tls_enabled="false"
      vless_public_port="443"
      vless_public_security="tls"
    fi
  fi

  write_config "$config_path" "$cert_dir" "$hy2_port" "$tuic_port" "$vless_port" "$ws_path" "$vless_listen" "$vless_tls_enabled"

  # Validate config before starting service.
  "${install_dir}/${BIN_NAME}" check -c "$config_path" || die "Config validation failed: ${config_path}"

  write_singbox_service "$install_dir" "$config_path"
  systemd_reload_enable_start "sing-box.service"

  # Setup cloudflared if needed.
  if [[ "$argo_enabled" == "true" ]]; then
    install_cloudflared "$install_dir"
    local origin_url="http://127.0.0.1:${vless_port}"

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
      argo_domain="$(detect_trycloudflare_domain "$install_dir" "$origin_url")"
      [[ -n "$argo_domain" ]] || die "Failed to detect trycloudflare domain. Please re-run."
      write_cloudflared_service "$install_dir" "try" "$origin_url" ""
    else
      write_cloudflared_config "$origin_url"
      write_cloudflared_service "$install_dir" "token" "$origin_url" "$argo_token"
    fi

    systemd_reload_enable_start "cloudflared.service"
    vless_public_host="$argo_domain"
  fi

  write_subscription "$host" "$vless_port" "$hy2_port" "$tuic_port" "$ws_path" "$vless_public_host" "$vless_public_port" "$vless_public_security" "$argo_enabled" "$cert_cn"
  write_manifest "${install_dir}/${BIN_NAME}" "${install_dir}/cloudflared" "$config_path" "$cert_dir"

  log "Installed ${BIN_NAME} to ${install_dir}/${BIN_NAME}"
  log "Config: ${config_path}"
  if [[ "$hy2_port" != "0" || "$tuic_port" != "0" || ( "$vless_port" != "0" && "$argo_enabled" != "true" ) ]]; then
    log "Cert: ${cert_dir}/server.crt (self-signed)"
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

