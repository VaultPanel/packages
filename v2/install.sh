#!/usr/bin/env bash
# Installs VaultPanel on this server. On a fresh Ubuntu or Debian server, as root:
#
#   apt update && apt -y upgrade && apt -y install curl wget sudo
#   curl -sS https://installer.vaultpanel.net/v2/install.sh -o install.sh
#   echo "<the checksum shown at github.com/VaultPanel/packages> install.sh" | sha256sum -c && sudo DB_ENGINE=MARIADB_12.3 bash install.sh
#
# It checks the server, installs what the panel needs (Node.js 22, Docker) and
# a MariaDB server for websites and apps, adds VaultPanel's package repository
# (installer.vaultpanel.net/apt, signed with VaultPanel's key) and installs the
# vaultpanel package. The package sets the panel up in /opt/vaultpanel: its
# secrets and a self-signed HTTPS certificate, its own MariaDB and Redis in
# Docker, systemd services that run as the unprivileged "vaultpanel" user and
# start at boot, and this server connected through its agent. At the end it
# prints the panel's address and the setup token. "vaultpanel update" (or apt
# upgrade) installs newer packages the same way.
#
# From a copy of the repository, to try code that is not released yet, it
# installs that copy instead and builds it on the server:
#
#   sudo bash install.sh
#
# Running it again is safe: it keeps the secrets and data.
#
# Options (after "bash install.sh", or after "bash -s --" when piped from curl):
#   --db-engine <e>   Database server for websites and apps, such as MARIADB_12.3 (what
#                     each system offers is in the README), or NONE. A new install gets
#                     the newest MariaDB this system offers; an update leaves it alone
#   --port <n>        Port the panel listens on (default 8090)
#   --url <url>       Address people open the panel at (default http://<this server's IP>:<port>)
#   --version <v>     Version to install, such as v0.2.0 (default: the newest)
#   --http            Serve the panel over plain HTTP (not recommended)
#   --https           Turn on HTTPS for a panel installed before it was the default
# Only when installing from a copy of the repository:
#   --dir <path>      Where VaultPanel lives (default /opt/vaultpanel)
#   --repo <url>      Git repository to install from
#   --branch <name>   Install a branch instead of a release (e.g. main)
#   --no-fetch        Use the code already in --dir as it is (used by "vaultpanel update")
# Run by the vaultpanel package itself:
#   --configure       Set up the installed package (its postinst runs this)
#
# The same as environment variables: DB_ENGINE, VAULTPANEL_PORT, VAULTPANEL_URL,
# VAULTPANEL_HTTPS (on or off), VAULTPANEL_DIR, VAULTPANEL_VERSION, VAULTPANEL_BRANCH,
# e.g. sudo VAULTPANEL_PORT=9000 bash install.sh
#
# Supported: Ubuntu 22.04 / 24.04 / 26.04 and Debian 12 / 13, as root, with systemd.
# Everything is inside main(), so a download cut short runs nothing.

set -euo pipefail

main() {
  local REPO="https://github.com/VaultPanel/VaultPanel.git"
  # Options can also come as environment variables, e.g. sudo VAULTPANEL_PORT=9000 bash install.sh
  local BRANCH="${VAULTPANEL_BRANCH:-}"
  local VERSION="${VAULTPANEL_VERSION:-}"
  local TLS_MODE="${VAULTPANEL_HTTPS:-}"
  local IF_NEWER=""
  local CONFIGURE=""
  local DIR="${VAULTPANEL_DIR:-/opt/vaultpanel}"
  local PORT="${VAULTPANEL_PORT:-}"
  local URL="${VAULTPANEL_URL:-}"
  local DB_ENGINE="${DB_ENGINE:-}"
  local FETCH=1
  local REPO_SET=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db-engine) DB_ENGINE="${2:-}"; shift 2 ;;
      --port) PORT="${2:-}"; shift 2 ;;
      --url) URL="${2:-}"; shift 2 ;;
      --dir) DIR="${2:-}"; shift 2 ;;
      --repo) REPO="${2:-}"; REPO_SET=1; shift 2 ;;
      --branch) BRANCH="${2:-}"; shift 2 ;;
      --version) VERSION="${2:-}"; shift 2 ;;
      --http) TLS_MODE=off; shift ;;
      --https) TLS_MODE=on; shift ;;
      --no-fetch) FETCH=""; shift ;;
      --if-newer) IF_NEWER=1; shift ;;
      --configure) CONFIGURE=1; shift ;;
      -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null; return 0 ;;
      *) fail "Unknown option: $1 (see the top of install.sh for the options)" ;;
    esac
  done
  [[ -z "$PORT" || "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]] || fail "--port must be a number from 1 to 65535"
  [[ -z "$URL" || "$URL" =~ ^https?://[^/[:space:]]+/?$ ]] || fail "--url must look like https://203.0.113.10:8090 or https://panel.example.com"
  [[ -z "$VERSION" || "$VERSION" == latest || "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || fail "--version must be a release tag such as v0.2.0, or latest"
  [[ -z "$VERSION" || -z "$BRANCH" ]] || fail "use --version or --branch, not both"
  [[ -z "$TLS_MODE" || "$TLS_MODE" == on || "$TLS_MODE" == off ]] || fail "VAULTPANEL_HTTPS must be on or off"
  DIR="${DIR%/}"

  # Never the Node.js of a version manager under /root: services and the
  # agent's helpers run as other users and must reach it.
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
  export DEBIAN_FRONTEND=noninteractive

  if [[ -n "$CONFIGURE" ]]; then
    configure_panel
    return 0
  fi

  banner
  check_system
  choose_db_engine
  # From VaultPanel's packages, unless this runs from a copy of the repository
  # or updates a panel installed from one.
  local from_source=""
  if [[ -n "$(local_checkout)" || -d "$DIR/.git" || -n "$REPO_SET" || -n "$BRANCH" ]]; then from_source=1; fi
  if [[ -z "${VAULTPANEL_SKIP_PACKAGES:-}" ]]; then
    step "Installing system packages"
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates git openssl tar iproute2 gnupg >/dev/null
    install_node
    install_docker
    install_site_database
  fi
  if [[ -z "$from_source" ]]; then
    install_from_packages
    return 0
  fi

  if [[ -n "$FETCH" ]]; then
    get_code
  else
    [[ -f "$DIR/backend/src/server.js" ]] || fail "$DIR has no VaultPanel code (run without --no-fetch)"
  fi

  ensure_user
  write_env
  setup_tls
  # From here on the settings come from the .env file.
  PORT="$(env_get VAULTPANEL_PORT)"
  check_ports
  start_database
  build_panel
  install_services
  install_command
  install_backups
  open_firewall
  start_panel
  summary
}

# ---- Output --------------------------------------------------------------------

if [[ -t 1 ]]; then
  BOLD=$'\e[1m'; DIM=$'\e[2m'; BLUE=$'\e[34m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; RED=$'\e[31m'; RESET=$'\e[0m'
else
  BOLD=""; DIM=""; BLUE=""; GREEN=""; YELLOW=""; RED=""; RESET=""
fi
step() { echo; echo "${BLUE}${BOLD}==>${RESET} ${BOLD}$*${RESET}"; }
info() { echo "    $*"; }
warn() { echo "${YELLOW}    ! $*${RESET}"; }
FAILED=""
fail() { echo; echo "${RED}${BOLD}VaultPanel was not installed:${RESET} $*" >&2; FAILED=1; exit 1; }
# A command that fails without a message of its own stops the installer
# (set -e). Say which one, so it does not stop in silence.
on_exit() {
  local status=$?
  [[ $status -eq 0 || -n "$FAILED" ]] && return
  echo
  echo "${RED}${BOLD}VaultPanel was not installed:${RESET} the installer stopped at: $BASH_COMMAND (exit $status)" >&2
}
trap on_exit EXIT

banner() {
  echo "${BLUE}${BOLD}"
  cat <<'ART'
 __     __          _ _   ____                  _
 \ \   / /_ _ _   _| | |_|  _ \ __ _ _ __   ___| |
  \ \ / / _` | | | | | __| |_) / _` | '_ \ / _ \ |
   \ V / (_| | |_| | | |_|  __/ (_| | | | |  __/ |
    \_/ \__,_|\__,_|_|\__|_|   \__,_|_| |_|\___|_|
ART
  echo "${RESET}${DIM}  Installer${RESET}"
}

# ---- Checks --------------------------------------------------------------------

check_system() {
  step "Checking this server"
  [[ "$(id -u)" -eq 0 ]] || fail "run it as root, for example: curl -fsSL <installer address> | sudo bash"
  [[ "$(uname -s)" == "Linux" ]] || fail "VaultPanel runs on Linux servers"
  [[ -d /run/systemd/system ]] || fail "systemd is required (containers without systemd are not supported)"
  command -v apt-get >/dev/null || fail "this installer supports Ubuntu and Debian (apt) only"
  [[ -r /etc/os-release ]] || fail "cannot tell which Linux this is (/etc/os-release is missing)"
  # shellcheck disable=SC1091
  local id version
  id="$(. /etc/os-release && echo "${ID:-}")"
  version="$(. /etc/os-release && echo "${VERSION_ID:-}")"
  case "$id:$version" in
    ubuntu:22.04|ubuntu:24.04|ubuntu:26.04|debian:12|debian:13) info "$(. /etc/os-release && echo "$PRETTY_NAME")" ;;
    ubuntu:*|debian:*) warn "$id $version is not tested; Ubuntu 22.04/24.04/26.04 and Debian 12/13 are. Continuing." ;;
    *) fail "this installer supports Ubuntu 22.04/24.04/26.04 and Debian 12/13 (found ${id:-unknown} ${version})" ;;
  esac
  local mem_mb
  mem_mb="$(awk '/MemTotal/ { print int($2 / 1024) }' /proc/meminfo)"
  [[ "$mem_mb" -ge 900 ]] || warn "this server has ${mem_mb} MB of memory; 2 GB or more is recommended"
}

# Fails when a port is taken by something other than VaultPanel.
check_ports() {
  step "Checking ports"
  local ours=""
  # Read whole, not piped to grep -q: grep stops at the first container, the
  # next one written kills compose (SIGPIPE), and pipefail then reads "none".
  if [[ -n "$(compose ps -q 2>/dev/null)" ]]; then ours=1; fi
  local port name
  for entry in "$(env_get VAULTPANEL_DB_PORT):the panel's MariaDB" "$(env_get VAULTPANEL_REDIS_PORT):the panel's Redis"; do
    port="${entry%%:*}"; name="${entry#*:}"
    if [[ -z "$ours" ]] && port_in_use "$port"; then
      fail "port $port (for $name) is already in use on 127.0.0.1. If an earlier VaultPanel started by hand runs here, stop its containers first (docker compose -f docker/compose.yml down, from that copy), or install on a fresh server."
    fi
  done
  if port_in_use "$PORT" && ! systemctl is-active --quiet vaultpanel.service; then
    fail "port $PORT is already in use. Stop what uses it, or pick another port: --port 8095"
  fi
  local loopback
  loopback="$(env_get VAULTPANEL_LOOPBACK_PORT)"
  if [[ -n "$TLS_ON" && -n "$loopback" ]] && port_in_use "$loopback" && ! systemctl is-active --quiet vaultpanel.service; then
    fail "port $loopback (the panel's loopback port) is already in use. Set another one in $ENV_FILE: VAULTPANEL_LOOPBACK_PORT=<port>"
  fi
  info "ports $PORT${loopback:+ (and $loopback on loopback)}, $(env_get VAULTPANEL_DB_PORT) and $(env_get VAULTPANEL_REDIS_PORT) are free for VaultPanel"
}

port_in_use() {
  [[ -n "$(ss -ltnH "sport = :$1" 2>/dev/null)" ]]
}

# ---- Dependencies --------------------------------------------------------------

install_node() {
  step "Installing Node.js 22"
  local major=0 package
  if [[ -x /usr/bin/node ]]; then major="$(/usr/bin/node -p 'process.versions.node.split(".")[0]')"; fi
  # The vaultpanel package needs it as a package as well (Depends: nodejs >= 22).
  # dpkg-query fails when nodejs is not installed, which here only means "no".
  package="$(dpkg-query -W -f='${Version}' nodejs 2>/dev/null | sed -E 's/^[0-9]+://; s/\..*//' || true)"
  if [[ "$major" -ge 22 && "${package:-0}" -ge 22 ]]; then
    info "Node.js $(/usr/bin/node -v) is already installed system-wide"
    return
  fi
  info "adding the NodeSource repository"
  local setup
  setup="$(mktemp)"
  curl -fsSL https://deb.nodesource.com/setup_22.x -o "$setup" || fail "could not download Node.js from deb.nodesource.com"
  bash "$setup" >/dev/null || fail "could not add the NodeSource repository for Node.js"
  rm -f "$setup"
  apt-get install -y -qq nodejs >/dev/null || fail "could not install Node.js"
  # An older nodejs from Ubuntu's own repository can win over NodeSource's.
  major="$(/usr/bin/node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  [[ "$major" -ge 22 ]] || fail "Node.js 22 did not install (found $(/usr/bin/node -v 2>/dev/null || echo none))"
  info "Node.js $(/usr/bin/node -v) installed"
}

install_docker() {
  step "Installing Docker"
  if ! command -v docker >/dev/null; then
    info "using Docker's official install script (get.docker.com)"
    local script
    script="$(mktemp)"
    curl -fsSL https://get.docker.com -o "$script" || fail "could not download Docker's install script from get.docker.com"
    sh "$script" >/dev/null || fail "Docker did not install"
    rm -f "$script"
  else
    info "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '(not running)') is already installed"
  fi
  # Started now and at every boot: the panel's database lives in it.
  if systemctl list-unit-files docker.service >/dev/null 2>&1 && systemctl cat docker.service >/dev/null 2>&1; then
    systemctl enable --now docker.service >/dev/null 2>&1 || true
  elif command -v snap >/dev/null && snap list docker >/dev/null 2>&1; then
    snap start --enable docker >/dev/null 2>&1 || true
  fi
  local tries=0
  until docker info >/dev/null 2>&1; do
    tries=$((tries + 1))
    [[ $tries -le 30 ]] || fail "Docker is installed but not running (try: systemctl start docker)"
    sleep 1
  done
  if ! docker compose version >/dev/null 2>&1; then
    info "adding Docker Compose"
    apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 \
      || apt-get install -y -qq docker-compose-v2 >/dev/null 2>&1 \
      || fail "Docker Compose v2 is missing and could not be installed (apt install docker-compose-plugin)"
  fi
  info "Docker Compose $(docker compose version --short) ready"
}

# ---- Database for websites and apps --------------------------------------------

# DB_ENGINE picks the database server this server gets for its websites and
# apps, on port 3306; the panel keeps its own MariaDB in Docker. What each
# system offers, newest first. MySQL 8.4 and 8.0 come in a later version.
db_engines_for() {
  case "$1" in
    ubuntu:26.04) echo "MARIADB_12.3 MARIADB_11.8" ;;
    ubuntu:24.04) echo "MARIADB_12.3 MARIADB_11.4 MARIADB_10.11" ;;
    ubuntu:22.04) echo "MARIADB_11.4 MARIADB_10.11 MARIADB_10.6" ;;
    debian:13) echo "MARIADB_12.3 MARIADB_11.8" ;;
    debian:12) echo "MARIADB_12.3 MARIADB_11.4 MARIADB_10.11" ;;
  esac
}

# Settles DB_ENGINE before anything is installed: a value this system offers,
# or NONE. A new install gets the newest MariaDB the system offers; an update
# (the panel's .env exists) installs nothing unless DB_ENGINE asks.
choose_db_engine() {
  local system offered
  system="$(. /etc/os-release && echo "${ID:-}:${VERSION_ID:-}")"
  offered="$(db_engines_for "$system")"
  DB_ENGINE="${DB_ENGINE^^}"
  if [[ -z "$DB_ENGINE" ]]; then
    if [[ -f "$DIR/.env" || -z "$offered" ]]; then DB_ENGINE=NONE; else DB_ENGINE="${offered%% *}"; fi
    return 0
  fi
  case "$DB_ENGINE" in
    NONE) return 0 ;;
    MYSQL_*) fail "MySQL is not available yet; it comes in a later version of VaultPanel. Choose ${offered:+one of $offered, or }NONE" ;;
    MARIADB_[0-9]*.[0-9]*) ;;
    *) fail "DB_ENGINE must be a value such as MARIADB_12.3, or NONE (got $DB_ENGINE)" ;;
  esac
  if [[ -n "$offered" && " $offered " != *" $DB_ENGINE "* ]]; then
    fail "$DB_ENGINE is not available on $(. /etc/os-release && echo "${PRETTY_NAME:-$system}"). Choose one of: $offered"
  fi
}

# The chosen MariaDB, from this system's own packages when they have that
# version, else from MariaDB's repository. A server that already has a database
# server keeps it: VaultPanel never replaces one.
install_site_database() {
  [[ "$DB_ENGINE" != NONE ]] || return 0
  local version="${DB_ENGINE#MARIADB_}" installed candidate
  step "Installing MariaDB $version for websites and apps"
  installed="$(site_database)"
  if [[ -n "$installed" ]]; then
    info "$installed is already installed on this server; keeping it"
    return 0
  fi
  if port_in_use 3306; then
    fail "port 3306 is already in use, so MariaDB cannot start there. Stop what uses it, or install with DB_ENGINE=NONE"
  fi
  # awk reads to the end: stopping at the first match kills apt-cache (SIGPIPE),
  # and pipefail then stops the installer.
  candidate="$(apt-cache policy mariadb-server 2>/dev/null | awk '/Candidate:/ && !found { found = 1; print $2 }')"
  if [[ "$(release_of "$candidate")" == "$version" ]]; then
    info "from this system's package sources"
  else
    add_mariadb_repository "$version"
  fi
  apt-get install -y -qq mariadb-server mariadb-client >/dev/null || fail "MariaDB $version did not install (apt-get install mariadb-server)"
  installed="$(site_database)"
  [[ "$installed" == "MariaDB $version" ]] || fail "MariaDB $version was asked for, but ${installed:-nothing} was installed"
  systemctl enable --now mariadb >/dev/null 2>&1 || fail "MariaDB is installed but did not start (see: journalctl -u mariadb)"
  info "MariaDB $(upstream_version "$(dpkg-query -W -f='${Version}' mariadb-server)") is installed and running"
}

# MariaDB's own repository, for a version this system's packages do not have.
add_mariadb_repository() {
  local version="$1" id codename
  local key=/etc/apt/keyrings/vaultpanel-mariadb.asc list=/etc/apt/sources.list.d/vaultpanel-mariadb.list
  id="$(. /etc/os-release && echo "${ID:-}")"
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  [[ -n "$codename" ]] || fail "cannot tell this system's code name (VERSION_CODENAME in /etc/os-release), which MariaDB's repository needs"
  info "adding MariaDB's repository for $version (deb.mariadb.org)"
  fetch_signing_key https://mariadb.org/mariadb_release_signing_key.pgp 177F4010FE56CA3336300305F1656F24C74CD1D8 "$key" MariaDB
  printf '# Managed by VaultPanel: MariaDB %s for websites and apps.\ndeb [signed-by=%s] https://deb.mariadb.org/%s/%s %s main\n' \
    "$version" "$key" "$version" "$id" "$codename" > "$list"
  apt-get update -qq || fail "could not read MariaDB's repository for $version (deb.mariadb.org)"
}

# A package repository's signing key, kept only when its fingerprint is the
# one its publisher gives: fetch_signing_key <url> <fingerprint> <file> <name>
fetch_signing_key() {
  local url="$1" expected="$2" dest="$3" name="$4" tmp fingerprint
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/key.asc" || fail "could not download $name's signing key ($url)"
  fingerprint="$(GNUPGHOME="$tmp" gpg --show-keys --with-colons "$tmp/key.asc" 2>/dev/null | awk -F: '$1 == "fpr" && !found { found = 1; print $10 }' || true)"
  [[ "$fingerprint" == "$expected" ]] || fail "the key from $url is not $name's signing key (fingerprint ${fingerprint:-unreadable})"
  install -d -m 0755 "$(dirname "$dest")"
  install -m 0644 "$tmp/key.asc" "$dest"
  rm -rf "$tmp"
}

# The database server installed for websites and apps, such as "MariaDB 11.4", or nothing.
site_database() {
  local entry pkg
  for entry in mariadb-server:MariaDB mysql-server:MySQL; do
    pkg="${entry%%:*}"
    if [[ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null)" == "install ok installed" ]]; then
      echo "${entry#*:} $(release_of "$(dpkg-query -W -f='${Version}' "$pkg")")"
      return 0
    fi
  done
}

# A package version without its epoch and packaging: "1:11.4.13+maria~ubu2404" -> "11.4.13"
upstream_version() { sed -E 's/^[0-9]+://; s/[-+~].*//' <<< "$1"; }

# ... and its release: "11.4"
release_of() { upstream_version "$1" | cut -d. -f1,2; }

# ---- VaultPanel's packages -----------------------------------------------------

# VaultPanel's own package repository, signed with VaultPanel's key. The
# VAULTPANEL_APT_* variables point the installer at another repository and key
# (the package tests use a local one).
add_vaultpanel_repository() {
  local url="${VAULTPANEL_APT_URL:-https://installer.vaultpanel.net/apt}"
  local key_url="${VAULTPANEL_APT_KEY_URL:-${url%/}/key.asc}"
  local expected="${VAULTPANEL_APT_FINGERPRINT:-79B34D79D2A7D0DE54A3D906B62A47C2ED2775A6}"
  local key=/etc/apt/keyrings/vaultpanel.asc list=/etc/apt/sources.list.d/vaultpanel.list
  step "Adding VaultPanel's package repository"
  fetch_signing_key "$key_url" "$expected" "$key" VaultPanel
  printf '# Managed by VaultPanel: its own packages.\ndeb [signed-by=%s] %s/ ./\n' "$key" "${url%/}" > "$list"
  apt-get update -qq || fail "could not read VaultPanel's package repository (${url%/})"
  info "${url%/} (signing key $expected)"
}

# Installs (or updates to) the vaultpanel package, whose postinst sets the
# panel up (configure_panel). A new install's choices reach it through
# /etc/vaultpanel/install.env, which it removes once used.
install_from_packages() {
  [[ "$DIR" == /opt/vaultpanel ]] || fail "--dir only works when installing from a copy of the repository; the vaultpanel package installs in /opt/vaultpanel"
  add_vaultpanel_repository
  step "Installing VaultPanel"
  local want=vaultpanel
  [[ -z "$VERSION" || "$VERSION" == latest ]] || want="vaultpanel=${VERSION#v}"
  if [[ ! -f "$DIR/.env" ]]; then
    install -d -m 0755 /etc/vaultpanel
    {
      [[ -z "$PORT" ]] || echo "VAULTPANEL_PORT=$PORT"
      [[ -z "$URL" ]] || echo "VAULTPANEL_URL=$URL"
      [[ -z "$TLS_MODE" ]] || echo "VAULTPANEL_HTTPS=$TLS_MODE"
    } > /etc/vaultpanel/install.env
  fi
  apt-get install -y -q "$want" || fail "the vaultpanel package did not install. Fix what the lines above say, then finish with: sudo dpkg --configure -a"
  ENV_FILE="$DIR/.env"
  [[ -f "$ENV_FILE" ]] || fail "the vaultpanel package is installed but the panel was not set up (sudo dpkg --configure -a tries again)"
  summary
}

# Run by the vaultpanel package's postinst, as root, on a new install and after
# every upgrade: settings, certificate, the panel's database and its schema,
# services, the command and backups. The code is already in place.
configure_panel() {
  DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local seed=/etc/vaultpanel/install.env
  if [[ -f "$seed" && ! -f "$DIR/.env" ]]; then
    PORT="$(sed -n 's/^VAULTPANEL_PORT=//p' "$seed")"
    URL="$(sed -n 's/^VAULTPANEL_URL=//p' "$seed")"
    TLS_MODE="$(sed -n 's/^VAULTPANEL_HTTPS=//p' "$seed")"
  fi
  docker info >/dev/null 2>&1 || fail "Docker is not running, and the panel's own database runs in it. Install VaultPanel with its installer (installer.vaultpanel.net), or start Docker, then: sudo dpkg --configure -a"
  ensure_user
  write_env
  setup_tls
  PORT="$(env_get VAULTPANEL_PORT)"
  check_ports
  start_database
  migrate_database
  install_services
  install_command
  install_backups
  open_firewall
  start_panel
  rm -f "$seed"
}

# ---- Code ----------------------------------------------------------------------

get_code() {
  step "Getting VaultPanel"
  # Never wait for a password: a private repository fails with a clear message.
  export GIT_TERMINAL_PROMPT=0
  local local_copy existing="" before="" ref
  local_copy="$(local_checkout)"
  if [[ -d "$DIR/.git" ]]; then
    existing=1
    before="$(git -C "$DIR" rev-parse HEAD)"
    if [[ -z "$REPO_SET" && -n "$local_copy" && -z "$VERSION" ]]; then
      # Run from a copy of the repository: install exactly what that copy has
      # (no GitHub login needed, which a private repository would ask for).
      local branch
      branch="$(git -C "$local_copy" rev-parse --abbrev-ref HEAD)"
      info "updating $DIR from $local_copy ($branch)"
      git -C "$DIR" fetch --quiet "$local_copy" "$branch" || fail "could not read $local_copy"
      prepare_update "$before" "$(git -C "$DIR" rev-parse 'FETCH_HEAD^{commit}')"
      git -C "$DIR" checkout --quiet -B "$branch" FETCH_HEAD
    else
      ref="$(wanted_ref "$(git -C "$DIR" remote get-url origin)" existing)"
      fetch_ref "$ref"
      prepare_update "$before" "$(git -C "$DIR" rev-parse 'FETCH_HEAD^{commit}')"
      checkout_ref "$ref"
    fi
  elif [[ -e "$DIR" && -n "$(ls -A "$DIR" 2>/dev/null)" ]]; then
    fail "$DIR exists and is not a VaultPanel install. Move it away or choose another folder with --dir"
  else
    mkdir -p "$(dirname "$DIR")"
    if [[ -z "$REPO_SET" && -n "$local_copy" && -z "$VERSION" ]]; then
      # install.sh run from a copy of the repository: install that copy's
      # branch, and keep updating from where that copy came from.
      local branch origin
      branch="$(git -C "$local_copy" rev-parse --abbrev-ref HEAD)"
      info "installing from $local_copy ($branch)"
      git clone --quiet --branch "$branch" "$local_copy" "$DIR" || fail "could not copy VaultPanel from $local_copy"
      origin="$(git -C "$local_copy" remote get-url origin 2>/dev/null || true)"
      [[ -z "$origin" ]] || git -C "$DIR" remote set-url origin "$origin"
    else
      ref="$(wanted_ref "$REPO" fresh)"
      info "downloading from $REPO"
      git clone --quiet --no-checkout "$REPO" "$DIR" || fail "could not download VaultPanel from $REPO. $(private_hint)"
      fetch_ref "$ref"
      checkout_ref "$ref"
    fi
  fi
  info "version $(describe_version)"
  if [[ -n "$IF_NEWER" && -n "$existing" && "$before" == "$(git -C "$DIR" rev-parse HEAD)" ]]; then
    echo
    echo "VaultPanel is up to date ($(describe_version)). To rebuild anyway: sudo vaultpanel update --force"
    exit 0
  fi
  reexec_new_installer
}

# What to install: "tag <vX.Y.Z>" or "branch <name>". By default the latest
# release (a vX.Y.Z tag); a fresh install falls back to main while the
# repository has no release yet, and an install that follows a branch keeps
# following it until --version is given.
wanted_ref() {
  local remote="$1" kind="$2" latest
  if [[ -n "$BRANCH" ]]; then echo "branch $BRANCH"; return; fi
  if [[ -n "$VERSION" && "$VERSION" != latest ]]; then echo "tag $VERSION"; return; fi
  if [[ -z "$VERSION" && "$kind" == existing ]]; then
    local current
    current="$(git -C "$DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    if [[ -n "$current" ]]; then echo "branch $current"; return; fi
  fi
  latest="$(latest_release "$remote")"
  if [[ -n "$latest" ]]; then echo "tag $latest"; return; fi
  [[ "$VERSION" != latest ]] || fail "$remote has no release yet (no vX.Y.Z tag). Install a branch instead: --branch main"
  echo "branch main"
}

# The highest vX.Y.Z tag of a repository (pre-releases such as v1.0.0-rc.1 are skipped).
latest_release() {
  git ls-remote --tags --refs "$1" 'v*' 2>/dev/null \
    | sed -n 's|.*refs/tags/\(v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$|\1|p' \
    | sort -V | tail -n 1
}

fetch_ref() {
  local kind="${1%% *}" name="${1#* }" origin
  origin="$(git -C "$DIR" remote get-url origin)"
  if [[ "$kind" == tag ]]; then
    info "release $name"
    git -C "$DIR" fetch --quiet --force origin "refs/tags/$name:refs/tags/$name" \
      || fail "could not download release $name from $origin (does the tag exist?). $(private_hint)"
  else
    info "branch $name"
    git -C "$DIR" fetch --quiet origin "$name" || fail "could not download branch $name from $origin. $(private_hint)"
  fi
}

checkout_ref() {
  local kind="${1%% *}" name="${1#* }"
  if [[ "$kind" == tag ]]; then
    git -C "$DIR" -c advice.detachedHead=false checkout --quiet --force --detach "refs/tags/$name"
    [[ "$(git -C "$DIR" describe --tags --exact-match HEAD 2>/dev/null)" == "$name" ]] || fail "the code in $DIR is not release $name after checkout"
  else
    git -C "$DIR" checkout --quiet --force -B "$name" FETCH_HEAD
  fi
}

describe_version() {
  git -C "$DIR" describe --tags --exact-match HEAD 2>/dev/null \
    || echo "$(git -C "$DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || echo detached) $(git -C "$DIR" rev-parse --short HEAD)"
}

# Before an installed panel changes version: a backup of its database and
# settings, and a note of the version it had, for "vaultpanel rollback".
prepare_update() {
  local before="$1" after="$2"
  [[ -n "$before" && "$before" != "$after" ]] || return 0
  echo "$before" > "$DIR/.git/vaultpanel-previous"
  rm -f "$DIR/.git/vaultpanel-previous-backup"
  if grep -q '^cmd_backup()' "$DIR/scripts/vaultpanel.sh" 2>/dev/null && [[ -f "$DIR/.env" ]]; then
    info "backing up the panel before updating"
    local file
    if file="$(bash "$DIR/scripts/vaultpanel.sh" backup --label pre-update --keep 3 --quiet)"; then
      echo "$file" > "$DIR/.git/vaultpanel-previous-backup"
      info "backup: $file"
    else
      warn "the backup before updating failed; updating anyway (vaultpanel rollback cannot bring the database back)"
    fi
  fi
}

# The installer of the version being installed finishes the job, so changes to
# install.sh apply from the release that brings them.
reexec_new_installer() {
  local self="${BASH_SOURCE[0]:-}"
  if [[ -n "$self" && -f "$self" ]] && cmp -s "$self" "$DIR/install.sh"; then return 0; fi
  [[ -f "$DIR/install.sh" ]] || return 0
  info "continuing with the installer of this version"
  local args=(--dir "$DIR" --no-fetch)
  [[ -z "$PORT" ]] || args+=(--port "$PORT")
  [[ -z "$URL" ]] || args+=(--url "$URL")
  [[ "$TLS_MODE" != on ]] || args+=(--https)
  [[ "$TLS_MODE" != off ]] || args+=(--http)
  VAULTPANEL_SKIP_PACKAGES=1 exec bash "$DIR/install.sh" "${args[@]}"
}

# The repository this script was started from, if it was started from one.
local_checkout() {
  local src="${BASH_SOURCE[0]:-}"
  [[ -n "$src" && -f "$src" ]] || return 0
  local dir
  dir="$(cd "$(dirname "$src")" && pwd)"
  if [[ "$dir" != "$DIR" && -f "$dir/backend/src/server.js" && -d "$dir/.git" ]]; then echo "$dir"; fi
}

private_hint() {
  echo "The repository is private: clone it with your own GitHub login (git clone <repository>) and run: sudo bash VaultPanel/install.sh (to update later: git -C VaultPanel pull, then the same command). Servers that only run VaultPanel install it from its packages instead."
}

# ---- Settings ------------------------------------------------------------------

ENV_FILE=""
PANEL_USER=vaultpanel
# Where the panel keeps its own files. /var/lib/vaultpanel itself belongs to the
# agent (cron state, Let's Encrypt challenges, its mode file), so the panel,
# which runs as its own user, gets a folder of its own inside it.
PANEL_DATA_DIR=/var/lib/vaultpanel/panel
TLS_DIR=/etc/vaultpanel/tls
TLS_ON=""

env_get() {
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n 1
}

# Adds KEY=VALUE when the file has no KEY yet; never changes a value already there.
env_default() {
  grep -q "^$1=" "$ENV_FILE" || echo "$1=$2" >> "$ENV_FILE"
}

env_set() {
  if grep -q "^$1=" "$ENV_FILE"; then
    local tmp
    tmp="$(mktemp)"
    awk -v k="$1" -v v="$2" 'BEGIN { FS = OFS = "=" } $1 == k { print k "=" v; next } { print }' "$ENV_FILE" > "$tmp"
    cat "$tmp" > "$ENV_FILE"
    rm -f "$tmp"
  else
    echo "$1=$2" >> "$ENV_FILE"
  fi
}

env_unset() {
  grep -q "^$1=" "$ENV_FILE" || return 0
  local tmp
  tmp="$(mktemp)"
  grep -v "^$1=" "$ENV_FILE" > "$tmp" || true
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

secret() { openssl rand -hex "$1"; }

public_ip() {
  local ip
  ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip="$(hostname -I 2>/dev/null | awk '{ print $1 }')"
  echo "${ip:-127.0.0.1}"
}

# The panel runs as this user, never as root. Only connecting this server
# (connectLocal.js, before the API starts) runs as root.
ensure_user() {
  if ! id "$PANEL_USER" >/dev/null 2>&1; then
    useradd --system --user-group --home-dir "$PANEL_DATA_DIR" --no-create-home --shell /usr/sbin/nologin "$PANEL_USER" \
      || fail "could not create the $PANEL_USER user"
  fi
}

write_env() {
  step "Writing settings"
  ENV_FILE="$DIR/.env"
  local fresh=""
  if [[ ! -f "$ENV_FILE" ]]; then
    fresh=1
    install -m 640 -o root -g "$PANEL_USER" /dev/null "$ENV_FILE"
    cat > "$ENV_FILE" <<'HEADER'
# VaultPanel settings, written by install.sh. Keep this file secret: it holds
# the key that encrypts two-factor secrets and the agent signing key.
# After a change, run: vaultpanel restart
HEADER
  fi
  # Root writes it; the panel's user may only read it.
  chown "root:$PANEL_USER" "$ENV_FILE"
  chmod 640 "$ENV_FILE"

  # HTTPS on the panel's own port: always for a new install (unless --http);
  # an existing install keeps what it has unless --https or --http says otherwise.
  if [[ -n "$fresh" ]]; then
    [[ "$TLS_MODE" == off ]] || TLS_ON=1
  else
    [[ -z "$(env_get VAULTPANEL_TLS_CERT)" ]] || TLS_ON=1
    [[ "$TLS_MODE" != on ]] || TLS_ON=1
    [[ "$TLS_MODE" != off ]] || TLS_ON=""
  fi
  local scheme=http
  [[ -z "$TLS_ON" ]] || scheme=https

  local db_password redis_password
  db_password="$(env_get VAULTPANEL_DB_PASSWORD)"; [[ -n "$db_password" ]] || db_password="$(secret 24)"
  redis_password="$(env_get VAULTPANEL_REDIS_PASSWORD)"; [[ -n "$redis_password" ]] || redis_password="$(secret 24)"

  env_default NODE_ENV production
  env_default VAULTPANEL_HOST 0.0.0.0
  env_default VAULTPANEL_PORT "${PORT:-8090}"
  local old_port
  old_port="$(env_get VAULTPANEL_PORT)"
  if [[ -n "$PORT" && "$PORT" != "$old_port" ]]; then
    env_set VAULTPANEL_PORT "$PORT"
    # An address that names the old port moves with it.
    local current
    current="$(env_get VAULTPANEL_PUBLIC_URL)"
    if [[ -z "$URL" && "$current" == http*://*:"$old_port" ]]; then URL="${current%:*}:$PORT"; fi
  fi
  local url_changed=""
  if [[ -n "$URL" ]]; then
    env_set VAULTPANEL_PUBLIC_URL "${URL%/}"
    url_changed=1
  else
    env_default VAULTPANEL_PUBLIC_URL "$scheme://$(public_ip):$(env_get VAULTPANEL_PORT)"
    # HTTPS turned on or off: the address on the panel's own port follows.
    local address port
    address="$(env_get VAULTPANEL_PUBLIC_URL)"
    port="$(env_get VAULTPANEL_PORT)"
    if [[ -n "$TLS_ON" && "$address" == http://*:"$port" ]]; then
      env_set VAULTPANEL_PUBLIC_URL "https://${address#http://}"; url_changed=1
    elif [[ -z "$TLS_ON" && "$address" == https://*:"$port" ]]; then
      env_set VAULTPANEL_PUBLIC_URL "http://${address#https://}"; url_changed=1
    fi
  fi
  # Secure cookies and HTTPS-only agents follow the address.
  local secure=false
  [[ "$(env_get VAULTPANEL_PUBLIC_URL)" != https://* ]] || secure=true
  local insecure_agents=true
  [[ "$secure" == false ]] || insecure_agents=false
  if [[ -n "$url_changed" ]]; then
    env_set VAULTPANEL_COOKIE_SECURE "$secure"
    env_set VAULTPANEL_ALLOW_INSECURE_AGENTS "$insecure_agents"
  else
    env_default VAULTPANEL_COOKIE_SECURE "$secure"
    env_default VAULTPANEL_ALLOW_INSECURE_AGENTS "$insecure_agents"
  fi
  env_default VAULTPANEL_TRUST_PROXY loopback
  env_default VAULTPANEL_UI_DIR "$DIR/frontend/dist"
  env_default VAULTPANEL_DATA_DIR "$PANEL_DATA_DIR"
  env_default VAULTPANEL_LOCAL_AGENT true
  env_default VAULTPANEL_LOG_LEVEL info
  env_default VAULTPANEL_SECRET_KEY "$(secret 32)"
  # Fixed, so the installer can show it. It only works until the owner account exists.
  env_default VAULTPANEL_SETUP_TOKEN "$(secret 16)"
  env_default VAULTPANEL_DB_PORT 3307
  env_default VAULTPANEL_REDIS_PORT 6379
  env_default VAULTPANEL_DB_ROOT_PASSWORD "$(secret 24)"
  env_default VAULTPANEL_DB_PASSWORD "$db_password"
  env_default VAULTPANEL_REDIS_PASSWORD "$redis_password"
  env_default DATABASE_URL "mysql://vaultpanel:$db_password@127.0.0.1:$(env_get VAULTPANEL_DB_PORT)/vaultpanel"
  env_default REDIS_URL "redis://:$redis_password@127.0.0.1:$(env_get VAULTPANEL_REDIS_PORT)"
  # Webhooks may not call private networks on a new panel. A panel installed
  # before this default changed keeps the behaviour it had.
  if [[ -n "$fresh" ]]; then env_default VAULTPANEL_WEBHOOK_ALLOW_PRIVATE false; else env_default VAULTPANEL_WEBHOOK_ALLOW_PRIVATE true; fi
  # Daily backups of the panel itself (vaultpanel backup), kept on this server.
  env_default VAULTPANEL_BACKUP_DIR /var/backups/vaultpanel-panel
  env_default VAULTPANEL_BACKUP_KEEP 14

  move_data_dir
  if [[ -n "$fresh" ]]; then info "new secrets generated in $ENV_FILE"; else info "kept the settings in $ENV_FILE"; fi
}

# The panel's own folder, owned by its user. Panels installed before it ran
# as its own user kept their files in /var/lib/vaultpanel, next to the agent's
# private state; those files move to the panel's folder.
move_data_dir() {
  local data
  data="$(env_get VAULTPANEL_DATA_DIR)"
  if [[ "$data" == /var/lib/vaultpanel ]]; then
    data="$PANEL_DATA_DIR"
    mkdir -p "$data"
    local entry
    for entry in downloads uploads terminal-recordings backup-downloads panel-hosts.json; do
      [[ ! -e "/var/lib/vaultpanel/$entry" ]] || mv "/var/lib/vaultpanel/$entry" "$data/"
    done
    env_set VAULTPANEL_DATA_DIR "$data"
    info "the panel's files moved to $data"
  fi
  mkdir -p "$data"
  # The agent opens /var/lib/vaultpanel for traversal (Let's Encrypt challenges).
  [[ "$(dirname "$data")" != /var/lib/vaultpanel ]] || chmod 711 /var/lib/vaultpanel
  chown -R "$PANEL_USER:$PANEL_USER" "$data"
  chmod 700 "$data"
}

# ---- HTTPS ---------------------------------------------------------------------

# A self-signed certificate for the panel's own port, so the panel is never on
# plain HTTP, like Cockpit, Webmin or Proxmox. Browsers warn about it once.
# Agents on other servers trust exactly this certificate: their install
# command carries its public key pin. A domain with a Let's Encrypt
# certificate (System > Panel Domain) can be added on top at any time.
setup_tls() {
  if [[ -z "$TLS_ON" ]]; then
    if [[ -n "$(env_get VAULTPANEL_TLS_CERT)" ]]; then
      env_unset VAULTPANEL_TLS_CERT
      env_unset VAULTPANEL_TLS_KEY
      env_unset VAULTPANEL_LOOPBACK_PORT
      warn "HTTPS is off (--http): the panel uses plain HTTP"
    fi
    return 0
  fi
  step "Setting up HTTPS"
  local cert key
  cert="$(env_get VAULTPANEL_TLS_CERT)"; cert="${cert:-$TLS_DIR/panel.crt}"
  key="$(env_get VAULTPANEL_TLS_KEY)"; key="${key:-$TLS_DIR/panel.key}"
  if [[ ! -s "$cert" || ! -s "$key" ]]; then
    make_certificate "$cert" "$key"
    info "self-signed certificate created ($cert, valid 10 years)"
  else
    info "keeping the certificate in $cert"
  fi
  # The key stays root's; the panel's user may read it, not change it.
  chown "root:$PANEL_USER" "$(dirname "$cert")" "$cert" "$key"
  chmod 750 "$(dirname "$cert")"
  chmod 644 "$cert"
  chmod 640 "$key"
  env_set VAULTPANEL_TLS_CERT "$cert"
  env_set VAULTPANEL_TLS_KEY "$key"
  env_default VAULTPANEL_LOOPBACK_PORT "$(( $(env_get VAULTPANEL_PORT) + 1 ))"
}

# Subject names: localhost, this server's name and addresses, and the host of
# the panel's address, so agents can check the name they connect to.
make_certificate() {
  local cert="$1" key="$2" host san addr url_host tmpkey cn err
  mkdir -p "$(dirname "$cert")" "$(dirname "$key")"
  host="$(hostname -f 2>/dev/null || hostname)"
  san="DNS:localhost,IP:127.0.0.1,IP:::1"
  [[ -z "$host" ]] || san="$san,DNS:$host"
  for addr in $(public_ip) $(hostname -I 2>/dev/null); do
    [[ ",$san," == *",IP:$addr,"* ]] || san="$san,IP:$addr"
  done
  url_host="$(env_get VAULTPANEL_PUBLIC_URL | sed -E 's|^https?://||; s|/.*$||; s|^\[(.*)\](:[0-9]+)?$|\1|; s|^([^:]+):[0-9]+$|\1|')"
  if [[ -n "$url_host" && ",$san," != *":$url_host,"* ]]; then
    if [[ "$url_host" =~ ^[0-9.]+$ || "$url_host" == *:* ]]; then san="$san,IP:$url_host"; else san="$san,DNS:$url_host"; fi
  fi
  # A common name may be at most 64 characters, and cloud servers' names can be
  # longer; browsers and agents check the subject alternative names anyway.
  cn="VaultPanel ${host:-panel}"
  (( ${#cn} <= 64 )) || cn="VaultPanel"
  tmpkey="$(mktemp)"
  if ! err="$(openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=$cn" \
    -addext "subjectAltName=$san" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=serverAuth" \
    -keyout "$tmpkey" -out "$cert.new" 2>&1 >/dev/null)"; then
    rm -f "$tmpkey" "$cert.new"
    fail "could not create the HTTPS certificate with openssl: $(tail -n 2 <<< "$err" | tr '\n' ' ')"
  fi
  install -m 640 -o root -g "$PANEL_USER" "$tmpkey" "$key"
  rm -f "$tmpkey"
  mv "$cert.new" "$cert"
}

# The panel's own address on this server, for health checks: the plain HTTP
# loopback port when HTTPS is on.
local_url() {
  local loopback
  loopback="$(env_get VAULTPANEL_LOOPBACK_PORT)"
  if [[ -n "$(env_get VAULTPANEL_TLS_CERT)" && -n "$loopback" ]]; then echo "http://127.0.0.1:$loopback"; else echo "http://127.0.0.1:$(env_get VAULTPANEL_PORT)"; fi
}

# ---- Database ------------------------------------------------------------------

compose() {
  docker compose -p vaultpanel --env-file "$ENV_FILE" -f "$DIR/docker/compose.prod.yml" "$@"
}

start_database() {
  step "Starting the panel's MariaDB and Redis"
  compose up -d --quiet-pull >/dev/null 2>&1 || compose up -d || fail "could not start the database containers"
  local tries=0
  until [[ "$(health mariadb)" == "healthy" && "$(health redis)" == "healthy" ]]; do
    tries=$((tries + 1))
    [[ $tries -le 90 ]] || fail "the database did not become ready. See: docker compose -p vaultpanel logs"
    sleep 2
  done
  info "MariaDB on 127.0.0.1:$(env_get VAULTPANEL_DB_PORT), Redis on 127.0.0.1:$(env_get VAULTPANEL_REDIS_PORT)"
}

health() {
  local id
  id="$(compose ps -q "$1" 2>/dev/null)"
  [[ -n "$id" ]] && docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null
}

# ---- Build ---------------------------------------------------------------------

build_panel() {
  step "Installing packages and building the web interface"
  cd "$DIR"
  info "npm ci (this takes a minute)"
  npm ci --no-audit --no-fund --update-notifier=false --loglevel=error >/dev/null || fail "npm ci failed. Run it by hand in $DIR to see why."
  info "building"
  npm run build --silent >/dev/null 2>&1 || fail "the web interface did not build. Run 'npm run build' in $DIR to see why."
  migrate_database
}

migrate_database() {
  info "updating the database"
  (cd "$DIR" && npm run db:migrate --silent >/dev/null) || fail "the database update failed. Run 'npm run db:migrate' in $DIR to see why."
}

# ---- Services ------------------------------------------------------------------

install_services() {
  step "Installing the services"
  local node=/usr/bin/node data caps="" bind=""
  data="$(env_get VAULTPANEL_DATA_DIR)"
  # A port below 1024 needs this one capability; nothing else is granted.
  if [[ "$PORT" -lt 1024 ]]; then
    caps="CAP_NET_BIND_SERVICE"
    bind="AmbientCapabilities=CAP_NET_BIND_SERVICE"
  fi
  local sandbox
  sandbox="User=$PANEL_USER
Group=$PANEL_USER
UMask=0077
NoNewPrivileges=yes
CapabilityBoundingSet=$caps
$bind
ProtectSystem=strict
ReadWritePaths=$data
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
SystemCallArchitectures=native
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6"

  cat > /etc/systemd/system/vaultpanel.service <<UNIT
# Written by VaultPanel's install.sh; running it again rewrites this file.
[Unit]
Description=VaultPanel control panel (web interface and API)
After=network-online.target docker.service snap.docker.dockerd.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DIR/backend
# Connects this server to the panel, and updates its agent after an update.
# The only step that runs as root ("+"); the panel itself runs as $PANEL_USER.
ExecStartPre=-+$node --env-file=$ENV_FILE src/cli/connectLocal.js --auto
ExecStart=$node --env-file=$ENV_FILE src/server.js
Restart=always
RestartSec=5
TimeoutStartSec=300
SyslogIdentifier=vaultpanel
$sandbox

[Install]
WantedBy=multi-user.target
UNIT

  cat > /etc/systemd/system/vaultpanel-worker.service <<UNIT
# Written by VaultPanel's install.sh; running it again rewrites this file.
[Unit]
Description=VaultPanel worker (backups, deployments, schedules and other background jobs)
After=network-online.target docker.service snap.docker.dockerd.service vaultpanel.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DIR/backend
ExecStart=$node --env-file=$ENV_FILE src/worker.js
Restart=always
RestartSec=5
SyslogIdentifier=vaultpanel-worker
$sandbox

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable vaultpanel.service vaultpanel-worker.service >/dev/null 2>&1
  info "vaultpanel and vaultpanel-worker start at boot, as the $PANEL_USER user"
}

# Daily backups of the panel's database, settings and certificate
# (vaultpanel backup), kept in VAULTPANEL_BACKUP_DIR.
install_backups() {
  step "Scheduling daily backups of the panel"
  cat > /etc/systemd/system/vaultpanel-backup.service <<UNIT
# Written by VaultPanel's install.sh; running it again rewrites this file.
[Unit]
Description=Back up VaultPanel (database, settings, certificate)
After=docker.service snap.docker.dockerd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vaultpanel backup --label scheduled --quiet
SyslogIdentifier=vaultpanel-backup
UNIT
  cat > /etc/systemd/system/vaultpanel-backup.timer <<UNIT
# Written by VaultPanel's install.sh; running it again rewrites this file.
[Unit]
Description=Daily VaultPanel backup

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
  systemctl daemon-reload
  systemctl enable --now vaultpanel-backup.timer >/dev/null 2>&1 || warn "could not start vaultpanel-backup.timer"
  info "every day to $(env_get VAULTPANEL_BACKUP_DIR), keeping $(env_get VAULTPANEL_BACKUP_KEEP) (sudo vaultpanel backup makes one now)"
}

# The "vaultpanel" command and the banner shown when someone logs in over SSH.
install_command() {
  step "Adding the vaultpanel command"
  chmod 755 "$DIR/scripts/vaultpanel.sh" "$DIR/scripts/motd.sh"
  ln -sfn "$DIR/scripts/vaultpanel.sh" /usr/local/bin/vaultpanel
  if [[ -d /etc/update-motd.d ]]; then
    ln -sfn "$DIR/scripts/motd.sh" /etc/update-motd.d/99-vaultpanel
    info "the login banner shows the panel's address"
  fi
  info "type 'vaultpanel' for its address, status, logs and updates"
}

open_firewall() {
  if command -v ufw >/dev/null && [[ "$(ufw status 2>/dev/null)" == *"Status: active"* ]]; then
    step "Opening port $PORT in the firewall"
    ufw allow "$PORT/tcp" comment 'VaultPanel' >/dev/null
    info "ufw now allows $PORT/tcp"
  fi
}

start_panel() {
  step "Starting VaultPanel"
  systemctl restart vaultpanel.service
  systemctl restart vaultpanel-worker.service
  local tries=0
  until curl -fsS --max-time 3 "$(local_url)/api/v1/health" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [[ $tries -gt 150 ]]; then
      journalctl -u vaultpanel --no-pager -n 30 >&2 || true
      fail "the panel did not start. The log above says why (more with: vaultpanel logs)"
    fi
    sleep 2
  done
  info "the panel is running"
}

summary() {
  local url token=""
  url="$(env_get VAULTPANEL_PUBLIC_URL)"
  if [[ "$(curl -fsS --max-time 5 "$(local_url)/api/v1/auth/setup" 2>/dev/null)" == *'"needsSetup":true'* ]]; then
    token="$(env_get VAULTPANEL_SETUP_TOKEN)"
  fi
  echo
  echo "${GREEN}${BOLD}VaultPanel is installed.${RESET}"
  echo
  if [[ -n "$token" ]]; then
    echo "  Open:          ${BOLD}$url/setup${RESET}"
    echo "  Setup token:   ${BOLD}$token${RESET}"
    echo "                 ${DIM}(creates the owner account; it stops working once you have)${RESET}"
  else
    echo "  Open:          ${BOLD}$url${RESET} and sign in"
  fi
  local db
  db="$(site_database)"
  [[ -z "$db" ]] || echo "  Database:      ${BOLD}$db${RESET} for websites and apps"
  echo
  if [[ "$url" == http://* ]]; then
    echo "  ${YELLOW}The panel uses plain HTTP, which sends passwords unencrypted. Turn on HTTPS:${RESET}"
    echo "  ${BOLD}sudo vaultpanel https on${RESET}"
    echo
  elif [[ -n "$(env_get VAULTPANEL_TLS_CERT)" ]]; then
    local fp
    fp="$(openssl x509 -in "$(env_get VAULTPANEL_TLS_CERT)" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' || true)"
    echo "  ${DIM}The panel uses a self-signed certificate, so your browser warns once: check that it${RESET}"
    echo "  ${DIM}shows this SHA-256 fingerprint, then continue.${RESET}"
    echo "  ${DIM}  $fp${RESET}"
    echo "  ${DIM}For a trusted certificate, give the panel a domain: System > Panel Domain.${RESET}"
    echo
  fi
  echo "  On this server: ${BOLD}vaultpanel${RESET} shows the address and status; ${BOLD}vaultpanel help${RESET} lists the rest."
  echo
}

# One line, so bash never reads further in a file the update just replaced.
main "$@"; exit $?
