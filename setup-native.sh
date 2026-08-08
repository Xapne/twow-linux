#!/usr/bin/env bash
# =============================================================================
# TurtleWoW 1.18.1: convert the SIGGZ Windows repack to a native Linux server
# and run it, in one command. Works on any Linux distro; every step is idempotent,
# so re-running only does what is missing.
#
# Layout it expects (and creates) under the folder this script lives in:
#   server/   the repack (from TurtleWoW_1.18.zip), native db in server/db
#   client/   the 1.18.1 game client (only needed to play, not to convert)
#   src/      Penqle/tortoise-wow source, branch 1181dev
#   build/    native build tree
#   deps/     locally built ACE library
#   lib/      terminal prompts shared with setup-vm.sh
#
# Usage: ./setup-native.sh help
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$ROOT/server"
# shellcheck source=lib/ui.sh
. "$ROOT/lib/ui.sh"
# The TWOW_ prefix avoids collision with a bare DB_HOST/DB_PORT/DB_USER already
# present in the environment. db.env is written in ${VAR:-default} form so
# environment values take precedence over it; an empty port is resolved below.
# shellcheck source=/dev/null
[[ -f "$SERVER/db.env" ]] && . "$SERVER/db.env"
TWOW_DB_HOST=${TWOW_DB_HOST:-127.0.0.1}
TWOW_DB_PORT=${TWOW_DB_PORT:-}
TWOW_DB_USER=${TWOW_DB_USER:-root}
TWOW_DB_PASS=${TWOW_DB_PASS:-mangos}
export TWOW_DB_HOST TWOW_DB_PORT TWOW_DB_USER TWOW_DB_PASS
ACE_VER=8.0.3
BRANCH=1181dev
REPO=https://github.com/Penqle/tortoise-wow.git

say()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

DB() { mariadb -h "$TWOW_DB_HOST" -P "$TWOW_DB_PORT" -u "$TWOW_DB_USER" -p"$TWOW_DB_PASS" --max-allowed-packet=128M "$@"; }

# -----------------------------------------------------------------------------
# dependencies, with the exact package to install when one is missing
# -----------------------------------------------------------------------------
# What this distro calls things. Falls back to Arch names with a note when
# the distro is unknown; INSTALL is the command that would install them.
detect_distro() {
  local id
  # shellcheck source=/dev/null
  id=$(. "${OS_RELEASE:-/etc/os-release}" 2>/dev/null && echo "${ID:-} ${ID_LIKE:-}") || id=""
  case " $id " in
    *" debian "*|*" ubuntu "*)
      INSTALL="sudo apt install -y"
      PKG_BUILD="build-essential cmake"; PKG_NINJA="ninja-build"; PKG_TAR="libarchive-tools"
      PKG_DB="mariadb-server mariadb-client"; PKG_WINE="wine"
      PKG_DEV="default-libmysqlclient-dev libssl-dev zlib1g-dev";;
    *" fedora "*|*" rhel "*|*" centos "*)
      INSTALL="sudo dnf install -y"
      PKG_BUILD="gcc gcc-c++ make cmake"; PKG_NINJA="ninja-build"; PKG_TAR="bsdtar"
      PKG_DB="mariadb-server mariadb"; PKG_WINE="wine"
      PKG_DEV="mariadb-connector-c-devel openssl-devel zlib-devel";;
    *" suse "*|*" opensuse "*)
      INSTALL="sudo zypper install -y"
      PKG_BUILD="gcc gcc-c++ make cmake"; PKG_NINJA="ninja"; PKG_TAR="bsdtar"
      PKG_DB="mariadb mariadb-client"; PKG_WINE="wine"
      PKG_DEV="libmariadb-devel libopenssl-devel zlib-devel";;
    *)
      INSTALL="sudo pacman -S --needed"
      PKG_BUILD="gcc make cmake"; PKG_NINJA="ninja"; PKG_TAR="libarchive"
      PKG_DB="mariadb"; PKG_WINE="wine"
      PKG_DEV=""  # Arch ships headers with the runtime packages
      case " $id " in *" arch "*|*" manjaro "*|*" endeavouros "*) ;; *)
        [[ -n "$id" ]] && UNKNOWN_DISTRO=1;; esac;;
  esac
}

# The daemon lives in a different place on every distro, and some of them
# keep sbin out of a normal user's PATH. Look everywhere, print the path.
find_mariadbd() {
  local c p
  for c in mariadbd mysqld; do
    p=$(command -v "$c" 2>/dev/null) && { echo "$p"; return 0; }
  done
  for p in /usr/sbin/mariadbd /usr/libexec/mariadbd /usr/local/sbin/mariadbd \
           /usr/sbin/mysqld /usr/libexec/mysqld /usr/local/sbin/mysqld; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}

# mangosd renames its main thread ("MainThread" in /proc comm), so process
# checks have to look at the command line, not the process name.
world_running() { pgrep -f 'mangosd -c' >/dev/null 2>&1; }

# Copy into place without ETXTBSY: write beside the target, then rename over
# it. rename() only swaps the directory entry, so a running binary keeps its
# old inode and the next start picks up the new one.
install_binaries() {
  local src
  for src in "$@"; do
    local dest="$SERVER/bin/${src##*/}"
    cp -f "$src" "$dest.new" || die "could not stage ${src##*/} into server/bin/"
    chmod +x "$dest.new"
    mv -f "$dest.new" "$dest" || die "could not install ${src##*/} into server/bin/"
  done
}

check_deps() {
  local -A pkg=(
    [gcc]=$PKG_BUILD [g++]=$PKG_BUILD [make]=$PKG_BUILD [cmake]=$PKG_BUILD
    [ninja]=$PKG_NINJA [git]=git [curl]=curl
    [bsdtar]=$PKG_TAR [sha1sum]=coreutils
    [mariadb]=$PKG_DB [mariadb-install-db]=$PKG_DB
    [mariadb-dump]=$PKG_DB [mariadb-admin]=$PKG_DB
  )
  local missing=() c
  for c in "${!pkg[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c (${pkg[$c]})")
  done
  find_mariadbd >/dev/null || missing+=("mariadbd ($PKG_DB)")

  # Headers, not binaries: distros that split -dev packages pass every command
  # check above and then fail in cmake. Catch it here instead.
  local h hdr_missing=()
  for h in mysql/mysql.h mariadb/mysql.h; do
    [[ -f "/usr/include/$h" ]] && { hdr_missing=(); break; }
    hdr_missing=(MySQL)
  done
  [[ -f /usr/include/openssl/ssl.h ]] || hdr_missing+=(OpenSSL)
  [[ -f /usr/include/zlib.h ]]        || hdr_missing+=(ZLIB)

  if ((${#missing[@]})) || ((${#hdr_missing[@]})); then
    local msg="missing dependencies:"
    ((${#missing[@]}))     && msg+=$'\n  commands: '"${missing[*]}"
    ((${#hdr_missing[@]})) && msg+=$'\n  headers:  '"${hdr_missing[*]} (development packages)"
    msg+=$'\n\n  '"$INSTALL $PKG_BUILD $PKG_NINJA git curl $PKG_TAR $PKG_DB${PKG_DEV:+ $PKG_DEV}"
    [[ -n "${UNKNOWN_DISTRO:-}" ]] && msg+=$'\n  (unrecognized distro; those are Arch package names, adapt as needed)'
    die "$msg"
  fi
  say "all required commands and headers present"
}

# -----------------------------------------------------------------------------
# repack files in server/
# -----------------------------------------------------------------------------
ensure_repack() {
  if [[ -f "$SERVER/turtle_world.sql" && -d "$SERVER/bin" ]]; then
    say "repack already in server/"; return
  fi
  local zip="$ROOT/TurtleWoW_1.18.zip"
  [[ -f "$zip" ]] || die "server/ is not populated and $zip not found.
  Download the SIGGZ repack (TurtleWoW_1.18.zip) into $ROOT first."
  say "extracting repack into server/"
  mkdir -p "$SERVER"
  bsdtar -xf "$zip" --strip-components=1 -C "$SERVER"
}

# -----------------------------------------------------------------------------
# map data in server/data (dbc, maps, mmaps, vmaps)
# -----------------------------------------------------------------------------
ensure_mapdata() {
  local ok=1 d
  for d in dbc maps mmaps vmaps; do [[ -d "$SERVER/data/$d" ]] || ok=0; done
  if ((ok)); then say "map data already in server/data/"; return; fi
  local zip="$ROOT/data.zip"
  [[ -f "$zip" ]] || die "server/data is missing dbc/maps/mmaps/vmaps and $zip not found.
  Download SIGGZ's pre-made map data as $zip (or extract it from a client,
  see the setup guide, Section 5)."
  say "extracting map data into server/data/"
  mkdir -p "$SERVER/data"
  bsdtar -xf "$zip" --strip-components=1 -C "$SERVER/data"
}

# -----------------------------------------------------------------------------
# source checkout
# -----------------------------------------------------------------------------
ensure_source() {
  if [[ -f "$ROOT/src/CMakeLists.txt" ]]; then say "source already in src/"; return; fi
  say "cloning $REPO ($BRANCH)"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$ROOT/src" \
    || die "git clone failed. Check network access and that branch '$BRANCH' still exists."
}

# -----------------------------------------------------------------------------
# ACE library: the distribution's when it is recent enough, otherwise built here
# -----------------------------------------------------------------------------
# Only Debian packages a usable version (13 ships 8.0.2); Fedora, openSUSE and
# Arch package none at all, and Ubuntu 24.04 is on 7.1.2, a major version below
# what the core is built against.
ACE_MIN_MAJOR=8
ACE_FROM=""

# Both the headers and the link library have to be present, or find_package(ACE)
# would fail after the local build had already been skipped. The linker is asked
# directly, since the library sits in a multiarch or lib64 directory depending
# on the distribution, and an absolute path is only returned when it exists.
system_ace() {
  local h=/usr/include/ace/Version.h v
  [[ -f "$h" ]] || return 1
  [[ "$(gcc -print-file-name=libACE.so 2>/dev/null)" == /* ]] || return 1
  v=$(sed -n 's/^#define ACE_VERSION[[:space:]]*"\([^"]*\)".*/\1/p' "$h")
  [[ -n "$v" && "${v%%.*}" -ge "$ACE_MIN_MAJOR" ]] || return 1
  echo "$v"
}

# ACE_ROOT is left unset for a packaged ACE, which is where FindACE.cmake finds
# it under /usr; otherwise it points at the tree built below.
select_ace() {
  local v
  if v=$(system_ace); then
    unset ACE_ROOT
    ACE_FROM="the distribution's ACE $v"
  else
    export ACE_ROOT="$ROOT/deps/ACE_wrappers"
    ACE_FROM=""
  fi
}

ensure_ace() {
  select_ace
  [[ -n "$ACE_FROM" ]] && { say "using $ACE_FROM"; return; }
  if [[ -f "$ACE_ROOT/lib/libACE.so" ]]; then say "ACE already built"; return; fi
  say "downloading and building ACE $ACE_VER (a few minutes)"
  mkdir -p "$ROOT/deps"; cd "$ROOT/deps"
  local url="https://github.com/DOCGroup/ACE_TAO/releases/download/ACE%2BTAO-${ACE_VER//./_}/ACE-$ACE_VER.tar.gz"
  [[ -f "ACE-$ACE_VER.tar.gz" ]] || curl -sfLO "$url" \
    || die "could not download ACE from $url
  Check https://github.com/DOCGroup/ACE_TAO/releases for the current name."
  tar xf "ACE-$ACE_VER.tar.gz"
  echo '#include "ace/config-linux.h"' > "$ACE_ROOT/ace/config.h"
  echo 'include $(ACE_ROOT)/include/makeinclude/platform_linux.GNU' \
    > "$ACE_ROOT/include/makeinclude/platform_macros.GNU"
  make -C "$ACE_ROOT/ace" -j"$(nproc)" > "$ROOT/deps/ace-build.log" 2>&1 \
    || die "ACE build failed, see $ROOT/deps/ace-build.log"
  [[ -f "$ACE_ROOT/lib/libACE.so" ]] || die "ACE build produced no libACE.so, see $ROOT/deps/ace-build.log"
}

# -----------------------------------------------------------------------------
# build realmd + mangosd, install into server/bin
# -----------------------------------------------------------------------------
ensure_binaries() {
  if [[ -x "$SERVER/bin/mangosd" && -x "$SERVER/bin/realmd" ]]; then
    say "native binaries already in server/bin/"; return
  fi
  say "configuring and compiling the server (10-20 min on first run)"
  cmake -B "$ROOT/build" -S "$ROOT/src" -GNinja \
    -DCMAKE_BUILD_TYPE=Release -DDEBUG_SYMBOLS=OFF > "$ROOT/build-configure.log" 2>&1 \
    || die "cmake configure failed, see $ROOT/build-configure.log"
  ninja -C "$ROOT/build" mangosd realmd \
    || die "compile failed. Scroll up for the first error; report it on the tortoise-wow GitHub."
  install_binaries "$ROOT/build/src/mangosd/mangosd" "$ROOT/build/src/realmd/realmd"
  say "installed native mangosd and realmd"
}

# -----------------------------------------------------------------------------
# config fixes needed on Linux
# -----------------------------------------------------------------------------
fix_configs() {
  local f
  for f in "$SERVER/bin/realmd.conf" "$SERVER/bin/mangosd.conf"; do
    [[ -f "$f" ]] || die "$f is missing. The repack should provide it;
  re-extract TurtleWoW_1.18.zip or restore the file from it."
  done
  resolve_db_port
  # The repack points these at localhost:3306. "localhost" makes the client
  # library use the distro's default socket path instead of ours, and 3306 is
  # not necessarily where we ended up, so rewrite host and port on every
  # connection string while leaving the user, password and database alone.
  for f in "$SERVER/bin/realmd.conf" "$SERVER/bin/mangosd.conf"; do
    sed -i -E "s@^([[:space:]]*(Login|World|Character|Logs)DatabaseInfo[[:space:]]*=[[:space:]]*\")[^;\"]*;[^;\"]*;@\1$TWOW_DB_HOST;$TWOW_DB_PORT;@" "$f"
  done
  sed -i 's|^DataDir = "\.\./Data"|DataDir = "../data"|' "$SERVER/bin/mangosd.conf"
  write_db_env
  say "configs checked (database $TWOW_DB_HOST:$TWOW_DB_PORT, DataDir lowercase)"
}

# -----------------------------------------------------------------------------
# client safety, if a client is present in client/
#   - defuse the live launcher, which patches the client and needs WebView2
#   - report where realmlist points (never changed here: LAN setups use
#     the host's IP, see the setup guide, Section 14)
# -----------------------------------------------------------------------------
fix_client() {
  local client="$ROOT/client"
  [[ -d "$client" ]] || { warn "no client/ folder yet; skipping client fixes"; return; }
  if [[ -f "$client/realmlist.wtf" ]]; then
    say "client realmlist: $(head -1 "$client/realmlist.wtf") (edit client/realmlist.wtf to change)"
  fi
  if [[ -f "$client/TurtleWoW.exe" ]]; then
    mv "$client/TurtleWoW.exe" "$client/TurtleWoW.exe.DO-NOT-RUN"
    say "live launcher renamed to TurtleWoW.exe.DO-NOT-RUN (start WoW.exe instead)"
  fi
}

# -----------------------------------------------------------------------------
# native database in server/db, seeded from the bundled Windows one
# -----------------------------------------------------------------------------
# The project's instance is always reachable on its own socket, whatever the port.
# ping is used rather than a query because it reports the daemon as alive even
# when the credentials are refused; a password problem would otherwise look
# like "not running" and be reported as a port clash further down.
mariadb_running() { mariadb-admin --socket="$SERVER/db/mysql.sock" -u "$TWOW_DB_USER" -p"$TWOW_DB_PASS" ping >/dev/null 2>&1; }

port_free() {
  if command -v ss >/dev/null 2>&1; then
    ! ss -tln 2>/dev/null | grep -q "[:.]$1 "
  else
    ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}

# On Debian and Ubuntu the packaged mariadb is started on 3306 as soon as it is
# installed, so that port is frequently unavailable; a free one is picked
# instead of requiring the system service to be disabled. 3307 is reserved for
# the wine seeding instance further down.
resolve_db_port() {
  [[ -n "$TWOW_DB_PORT" ]] && return 0
  local p
  if p=$(mariadb --socket="$SERVER/db/mysql.sock" -u "$TWOW_DB_USER" -p"$TWOW_DB_PASS" \
           -N -B -e "SELECT @@port" 2>/dev/null) && [[ -n "$p" ]]; then
    TWOW_DB_PORT="$p"; return 0            # already running: keep the port it has
  fi
  for p in 3306 3308 3309 3310 3311 3312; do
    port_free "$p" || continue
    TWOW_DB_PORT="$p"
    [[ "$p" == 3306 ]] || warn "port 3306 is in use by something else (a system mariadb/mysql service?);
  using port $p for this server's own database instead"
    return 0
  done
  die "no free port for the database between 3306 and 3312.
  Pick one yourself with: TWOW_DB_PORT=<port> $0 ${mode:-setup}"
}

write_db_env() {
  cat > "$SERVER/db.env" <<EOF
# Written by setup-native.sh and read by the helper scripts in this folder so
# they reach the same database. Safe to edit; the environment still wins.
TWOW_DB_HOST=\${TWOW_DB_HOST:-$TWOW_DB_HOST}
TWOW_DB_PORT=\${TWOW_DB_PORT:-$TWOW_DB_PORT}
TWOW_DB_USER=\${TWOW_DB_USER:-$TWOW_DB_USER}
TWOW_DB_PASS=\${TWOW_DB_PASS:-$TWOW_DB_PASS}
EOF
}

# my.cnf is the user's to tune, so it is created once and thereafter only the
# port and the run-as user are kept in sync.
sync_my_cnf() {
  local f="$SERVER/my.cnf"
  # mariadbd aborts when invoked by root unless it is explicitly told to run as
  # root ("Please consult the Knowledge Base to find out how to run mysqld as
  # root!" in mysql.out); server/db is owned by root in that case anyway.
  local run_as=""; [[ $EUID -eq 0 ]] && run_as=$'user = root\n'
  if [[ ! -f "$f" ]]; then
    cat > "$f" <<EOF
[mysqld]
datadir = $SERVER/db
socket  = $SERVER/db/mysql.sock
bind-address = 127.0.0.1
port = $TWOW_DB_PORT
${run_as}max_allowed_packet = 128M
innodb_flush_log_at_trx_commit = 2
innodb_buffer_pool_size = 512M

[client]
socket = $SERVER/db/mysql.sock
port = $TWOW_DB_PORT
max_allowed_packet = 128M
EOF
    return
  fi
  if grep -qE '^[[:space:]]*port[[:space:]]*=' "$f"; then
    sed -i -E "s@^([[:space:]]*port[[:space:]]*=).*@\1 $TWOW_DB_PORT@" "$f"
  else
    sed -i "0,/^\[mysqld\]/s@@[mysqld]\nport = $TWOW_DB_PORT@" "$f"
  fi
  if [[ -n "$run_as" ]] && ! grep -qE '^[[:space:]]*user[[:space:]]*=' "$f"; then
    sed -i "0,/^\[mysqld\]/s@@[mysqld]\nuser = root@" "$f"
  fi
}

start_native_db() {
  mkdir -p "$SERVER/logs"
  if mariadb_running; then
    mariadb --socket="$SERVER/db/mysql.sock" -u "$TWOW_DB_USER" -p"$TWOW_DB_PASS" \
        -e "SELECT 1" >/dev/null 2>&1 \
      || die "the database in server/db is running but rejects $TWOW_DB_USER's password.
  Pass the right one as TWOW_DB_PASS=..., or shut it down and let this script start it:
  mariadb-admin --socket=$SERVER/db/mysql.sock -u $TWOW_DB_USER -p<password> shutdown"
    resolve_db_port
    return
  fi
  resolve_db_port
  sync_my_cnf
  port_free "$TWOW_DB_PORT" || die "port $TWOW_DB_PORT is in use by something that is not our database.
  Stop it, or run this on another port: TWOW_DB_PORT=<port> $0 ${mode:-setup}"
  say "starting native MariaDB on port $TWOW_DB_PORT"
  # distros disagree on where the daemon lives (/usr/bin on Arch, /usr/sbin on
  # Debian, /usr/libexec on Fedora); ask the shell instead of guessing
  local mariadbd; mariadbd=$(find_mariadbd) \
    || die "no mariadbd/mysqld found; install $PKG_DB"
  nohup "$mariadbd" --defaults-file="$SERVER/my.cnf" > "$SERVER/logs/mysql.out" 2>&1 &
  local i; for i in $(seq 1 30); do [[ -S "$SERVER/db/mysql.sock" ]] && break; sleep 1; done
  [[ -S "$SERVER/db/mysql.sock" ]] || die "MariaDB did not come up. Last lines of ${SERVER#"$ROOT"/}/logs/mysql.out:

$(tail -n 15 "$SERVER/logs/mysql.out" 2>/dev/null | sed 's/^/  /')"
  write_db_env
}

ensure_database() {
  mkdir -p "$SERVER/logs"
  resolve_db_port
  sync_my_cnf
  if [[ ! -d "$SERVER/db/mysql" ]]; then
    say "initializing native MariaDB data dir in server/db"
    mariadb-install-db --no-defaults --datadir="$SERVER/db" \
      --auth-root-authentication-method=normal > "$SERVER/logs/mysql-install.log" 2>&1 \
      || die "mariadb-install-db failed, see $SERVER/logs/mysql-install.log"
    start_native_db
    mariadb --socket="$SERVER/db/mysql.sock" -u root -e "
      ALTER USER 'root'@'localhost' IDENTIFIED BY '$TWOW_DB_PASS';
      CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '$TWOW_DB_PASS';
      GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
      FLUSH PRIVILEGES;" || die "could not set the root password"
  else
    start_native_db
  fi

  if DB -N -e "SELECT 1 FROM turtle_logon.account LIMIT 1" >/dev/null 2>&1; then
    say "game databases already present"; return
  fi

  # Seed: dump the four preloaded DBs out of the bundled Windows MariaDB.
  # One-time only; needs wine. Runs on port 3307 so it cannot clash.
  command -v wine >/dev/null 2>&1 \
    || die "game databases are empty and seeding them needs wine once ($INSTALL $PKG_WINE).
  Alternative: import dumps you already have into $TWOW_DB_HOST:$TWOW_DB_PORT."
  local windb="$SERVER/mariadb-10.3.39-winx64"
  [[ -d "$windb/data/turtle_logon" ]] \
    || die "bundled Windows MariaDB data not found in $windb; cannot seed the databases."
  say "seeding databases from the bundled Windows MariaDB (via wine, one time)"
  ( cd "$windb/bin" && nohup wine mysqld.exe --console --port=3307 \
      > "$SERVER/logs/wine-mysql.out" 2>&1 & )
  local i; for i in $(seq 1 60); do
    mariadb -h 127.0.0.1 -P 3307 -u root -p"$TWOW_DB_PASS" --skip-ssl -e "SELECT 1" >/dev/null 2>&1 && break
    sleep 2
  done
  mariadb -h 127.0.0.1 -P 3307 -u root -p"$TWOW_DB_PASS" --skip-ssl -e "SELECT 1" >/dev/null 2>&1 \
    || die "wine MariaDB did not come up, see $SERVER/logs/wine-mysql.out"
  mariadb-dump -h 127.0.0.1 -P 3307 -u root -p"$TWOW_DB_PASS" --skip-ssl --routines --triggers \
    --databases turtle_logon turtle_char turtle_logs turtle_world > "$SERVER/logs/seed-dump.sql" \
    || die "dumping from the wine MariaDB failed"
  mariadb-admin -h 127.0.0.1 -P 3307 -u root -p"$TWOW_DB_PASS" --skip-ssl shutdown || true
  say "importing the seed dump into native MariaDB"
  DB < "$SERVER/logs/seed-dump.sql" || die "import of the seed dump failed"
}

# -----------------------------------------------------------------------------
# bring the world DB schema up to what the compiled source expects
# -----------------------------------------------------------------------------
ensure_migrations() {
  [[ -x "$SERVER/apply-db-updates.sh" ]] \
    || die "$SERVER/apply-db-updates.sh is missing; restore it from the repo."
  "$SERVER/apply-db-updates.sh"
}

# -----------------------------------------------------------------------------
# Interactive mode: a guided, clack-style prompt for the most common options.
# Text fields come pre-filled with the current value (Enter keeps it), lists
# are picked with the arrow keys. Nothing is written unless a value changed.
# The prompts themselves live in lib/ui.sh, shared with setup-vm.sh.
# -----------------------------------------------------------------------------
CHANGES=()

conf_get() {  # $1 file, $2 key -> value, quotes and CR stripped
  sed -n "s/^${2//./\\.}[[:space:]]*=[[:space:]]*//p" "$1" \
    | tail -1 | tr -d '\r' | sed 's/^"\(.*\)"$/\1/'
}

conf_set() {  # $1 file, $2 key, $3 value, [$4 = quote]; no-op if unchanged
  local file="$1" key="$2" val="$3" cur esc
  cur="$(conf_get "$file" "$key")"
  [[ "$cur" == "$val" ]] && return 0
  if ! grep -q "^${key//./\\.}[[:space:]]*=" "$file"; then
    ui_warn "$key not found in ${file##*/}, skipped"
    return 0
  fi
  CHANGES+=("$key: ${cur:-unset} -> $val")
  [[ "${4:-}" == quote ]] && val="\"$val\""
  esc="${val//\\/\\\\}"; esc="${esc//&/\\&}"; esc="${esc//|/\\|}"
  sed -i "s|^${key//./\\.}[[:space:]]*=.*|$key = $esc|" "$file"
}

interactive_config() {
  local M="$SERVER/bin/mangosd.conf" R="$SERVER/bin/realmd.conf" RATE="$SERVER/bin/rate.conf"
  [[ -f "$M" && -f "$R" ]] || die "no configs in server/bin yet; run: $0 setup"
  trap 'printf "\033[?25h\n"; exit 130' INT

  # realm name/address live in the turtle_logon DB; bring it up if it exists
  local have_db=0 rname="" raddr=""
  if [[ -d "$SERVER/db/mysql" ]]; then
    start_native_db
    if rname="$(DB -N -e 'SELECT name FROM turtle_logon.realmlist LIMIT 1' 2>/dev/null)"; then
      have_db=1
      raddr="$(DB -N -e 'SELECT address FROM turtle_logon.realmlist LIMIT 1' 2>/dev/null)" || raddr=""
    fi
  fi

  ui_banner "apne's all-in-one CLI" "for TurtleWoW on Linux"
  ui_intro "server configuration"
  ui_note "Enter keeps the shown value · pick from lists with ↑/↓ + Enter · Ctrl+C quits"

  if (( have_db )); then
    ui_text "Realm name (shown in the in-game realm list)" "$rname"
    if [[ "$ANSWER" != "$rname" ]]; then
      DB -e "UPDATE turtle_logon.realmlist SET name='${ANSWER//\'/\'\'}'"
      CHANGES+=("realm name: $rname -> $ANSWER")
    fi

    local defidx=0; [[ -n "$raddr" && "$raddr" != 127.0.0.1 ]] && defidx=1
    ui_select "Who can connect?" "$defidx" \
      "Only this machine (127.0.0.1)" \
      "My local network (LAN play)"
    if (( ANSWER == 1 )); then
      local lanip=""
      [[ -n "$raddr" && "$raddr" != 127.0.0.1 ]] && lanip="$raddr"
      [[ -n "$lanip" ]] || lanip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' || true)"
      ui_text "This machine's LAN IP (clients connect here)" "${lanip:-192.168.?.?}"
      if [[ "$ANSWER" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if [[ "$ANSWER" != "$raddr" ]]; then
          DB -e "UPDATE turtle_logon.realmlist SET address='$ANSWER'"
          CHANGES+=("realm address: ${raddr:-unset} -> $ANSWER")
        fi
        conf_set "$R" BindIP 0.0.0.0 quote
        conf_set "$M" BindIP 0.0.0.0 quote
      else
        ui_warn "not an IPv4 address, leaving the realm address unchanged"
      fi
    else
      if [[ "$raddr" != 127.0.0.1 ]]; then
        DB -e "UPDATE turtle_logon.realmlist SET address='127.0.0.1'"
        CHANGES+=("realm address: ${raddr:-unset} -> 127.0.0.1")
      fi
      conf_set "$R" BindIP 127.0.0.1 quote
    fi
  else
    ui_note "realm name/address live in the database, which is not initialized yet;"
    ui_note "run '$0 setup' first, then come back here"
  fi

  local gt gtidx=0 i
  gt="$(conf_get "$M" GameType)"
  local gtvals=(0 1 6 8)
  for i in "${!gtvals[@]}"; do [[ "${gtvals[i]}" == "$gt" ]] && gtidx=$i; done
  ui_select "Game type" "$gtidx" "Normal / PvE" "PvP" "RP (Turtle default)" "RP-PvP"
  conf_set "$M" GameType "${gtvals[ANSWER]}"

  ui_text "Message of the day" "$(conf_get "$M" Motd)"
  conf_set "$M" Motd "$ANSWER" quote

  local xp; xp="$(conf_get "$M" Rate.XP.Kill)"
  ui_num "XP rate (kill/quest/explore, 1 = Blizzlike)" "$xp"
  if [[ "$ANSWER" != "$xp" ]]; then
    conf_set "$M" Rate.XP.Kill "$ANSWER"
    conf_set "$M" Rate.XP.Quest "$ANSWER"
    conf_set "$M" Rate.XP.Explore "$ANSWER"
  fi
  if [[ -f "$RATE" ]] \
      && grep -E '^Rate\.XP\.Kill' "$RATE" | tr -d '\r' | grep -vqE '=[[:space:]]*1$'; then
    ui_select "rate.conf also scales kill XP per level bracket (Turtle tuning)" 0 \
      "Keep the per-bracket tuning" \
      "Flatten all brackets to 1x (my XP rate applies at every level)"
    if (( ANSWER == 1 )); then
      sed -i 's/^Rate\.XP\.Kill.*/Rate.XP.Kill    = 1/' "$RATE"
      CHANGES+=("rate.conf: all level brackets flattened to 1x")
    fi
  fi

  # Scales Turtle's shipped tuning (uncommon 2x, everything else 1x), so
  # 1 always restores the authentic defaults no matter what was set before.
  local dr q; dr="$(conf_get "$M" Rate.Drop.Item.Rare)"
  ui_num "Item drop rate (1 = Turtle default: uncommon 2x, rest 1x)" "$dr"
  for q in Poor Normal Uncommon Rare Epic Legendary Artifact Referenced; do
    if [[ "$q" == Uncommon ]]; then
      conf_set "$M" "Rate.Drop.Item.$q" "$(awk -v a="$ANSWER" 'BEGIN{print a*2}')"
    else
      conf_set "$M" "Rate.Drop.Item.$q" "$ANSWER"
    fi
  done

  ui_num "Money drop rate" "$(conf_get "$M" Rate.Drop.Money)"
  conf_set "$M" Rate.Drop.Money "$ANSWER"

  ui_num "Honor rate" "$(conf_get "$M" Rate.Honor)"
  conf_set "$M" Rate.Honor "$ANSWER"

  local rr; rr="$(conf_get "$M" Rate.Rest.InGame)"
  ui_num "Rest bonus rate (inns and cities)" "$rr"
  if [[ "$ANSWER" != "$rr" ]]; then
    conf_set "$M" Rate.Rest.InGame "$ANSWER"
    conf_set "$M" Rate.Rest.Offline.InTavernOrCity "$ANSWER"
  fi

  ui_num "Player limit (0 = unlimited)" "$(conf_get "$M" PlayerLimit)"
  conf_set "$M" PlayerLimit "$ANSWER"

  ui_num "Starting level for new characters" "$(conf_get "$M" StartPlayerLevel)"
  conf_set "$M" StartPlayerLevel "$ANSWER"

  if (( ${#CHANGES[@]} )); then
    printf '%s\n' "$GUT"
    local c; for c in "${CHANGES[@]}"; do
      printf '%s  %s %s\n' "$GUT" "${C_GREEN}✔${C_RST}" "$c"
    done
    ui_outro "saved — restart the server ('$0 run') to apply"
  else
    ui_outro "nothing changed"
  fi
}

# -----------------------------------------------------------------------------
# Update: pull the latest source, rebuild incrementally, back up the world DB,
# apply new migrations. Refuses while the world server is running.
# -----------------------------------------------------------------------------
update_all() {
  [[ -d "$ROOT/src/.git" ]] || die "no source checkout in src/; run: $0 setup"
  [[ -x "$SERVER/bin/mangosd" ]] || die "not converted yet; run: $0 setup"
  # mangosd renames its main thread, so its /proc comm is "MainThread" and
  # pgrep -x never matches it; match the command line instead.
  if world_running; then
    die "the world server is running; stop it first.
  In its console: Ctrl+C. Detached: pkill -TERM -f 'mangosd -c'
  SIGINT is the core's restart signal; with pkill -INT the world is only restarted.
  Swapping schema under a live server is how characters get eaten."
  fi
  if pgrep -f 'realmd -c' >/dev/null 2>&1; then
    pkill -INT -f 'realmd -c'; sleep 1
    say "stopped realmd (a running binary cannot be replaced)"
  fi

  say "pulling latest $BRANCH source"
  local before after
  before=$(git -C "$ROOT/src" rev-parse --short HEAD)
  git -C "$ROOT/src" pull --ff-only \
    || die "git pull failed (local changes in src/? no network?); nothing was touched"
  after=$(git -C "$ROOT/src" rev-parse --short HEAD)
  if [[ "$before" == "$after" ]]; then
    say "source already at $after; still checking build and migrations"
  else
    say "source updated: $before -> $after"
  fi

  say "rebuilding mangosd and realmd (incremental, only what changed)"
  # ninja re-runs cmake itself when the source's build files changed, and that
  # re-run needs the same ACE in the environment as the first configure
  select_ace
  [[ -f "$ROOT/build/build.ninja" ]] \
    || cmake -B "$ROOT/build" -S "$ROOT/src" -GNinja \
         -DCMAKE_BUILD_TYPE=Release -DDEBUG_SYMBOLS=OFF > "$ROOT/build-configure.log" 2>&1 \
    || die "cmake configure failed, see $ROOT/build-configure.log"
  ninja -C "$ROOT/build" mangosd realmd \
    || die "compile failed; the installed binaries were not touched.
  Fix the error above or report it on the tortoise-wow GitHub."
  install_binaries "$ROOT/build/src/mangosd/mangosd" "$ROOT/build/src/realmd/realmd"
  say "installed updated binaries into server/bin/"

  start_native_db
  mkdir -p "$SERVER/backups"
  local backup="$SERVER/backups/turtle_world-$(date +%Y%m%d-%H%M%S)-$after.sql.gz"
  say "backing up turtle_world before migrations"
  mariadb-dump -h "$TWOW_DB_HOST" -P "$TWOW_DB_PORT" -u "$TWOW_DB_USER" -p"$TWOW_DB_PASS" \
      --routines --triggers turtle_world | gzip > "$backup" \
    || die "backup failed; not touching the database"
  say "backup: ${backup#"$ROOT"/}"
  ensure_migrations

  say "update complete; start the server with: $0 run"
}

# -----------------------------------------------------------------------------
# Run: DB (background) -> realmd (background) -> mangosd (foreground console)
# -----------------------------------------------------------------------------
run_all() {
  [[ -x "$SERVER/bin/mangosd" ]] || die "no native binaries yet; run: $0 setup"
  start_native_db
  say "MariaDB ready on $TWOW_DB_HOST:$TWOW_DB_PORT"

  if ! ss -tln | grep -q ':3724 '; then
    ( cd "$SERVER/bin" && nohup ./realmd -c realmd.conf > "$SERVER/logs/realmd.out" 2>&1 & )
    local i; for i in $(seq 1 15); do ss -tln | grep -q ':3724 ' && break; sleep 1; done
    ss -tln | grep -q ':3724 ' || die "realmd did not come up, see $SERVER/logs/realmd.out"
  fi
  say "realmd ready on 3724"

  say "starting mangosd in the foreground; this terminal is the server console"
  say "first boot loads all maps and takes a few minutes; stop with Ctrl+C"
  trap 'warn "world server stopped; realmd and MariaDB are still running.
  Stop them with: pkill -INT -f \"realmd -c\"; mariadb-admin --socket=$SERVER/db/mysql.sock -u $TWOW_DB_USER -p$TWOW_DB_PASS shutdown"' EXIT
  [[ -x "$SERVER/3-world-server.sh" ]] \
    || die "$SERVER/3-world-server.sh is missing or not executable;
  restore it (chmod +x) or start manually: cd $SERVER/bin && ./mangosd -c mangosd.conf"
  exec "$SERVER/3-world-server.sh" "$@"
}

# -----------------------------------------------------------------------------
usage() {
  cat <<EOF

${C_BOLD}${C_CYAN}apne's all-in-one CLI${C_RST}${C_BOLD} for TurtleWoW 1.18.1 on Linux${C_RST}
Converts the SIGGZ Windows repack to a fully native Linux server and runs it.

${C_BOLD}Usage:${C_RST}  $0 [mode]

${C_BOLD}Modes:${C_RST}
  ${C_GREEN}(none)${C_RST}         convert whatever is missing, then start the server
  ${C_GREEN}setup${C_RST}          convert only: dependencies, repack, map data, source
                 checkout, ACE + server build, configs, database seed,
                 schema migrations; every step is skipped once done
  ${C_GREEN}run${C_RST} [level]    start only: MariaDB and realmd in the background,
                 mangosd in the foreground as the server console
                 (Ctrl+C stops it); optional [level] is the mangosd
                 console log level, 0 (quiet) to 3 (debug)
  ${C_GREEN}interactive${C_RST}    guided setup screen for the most common options:
                 realm name, LAN play, game type, XP/drop/honor rates,
                 MOTD, player limit, starting level.
                 ${C_DIM}Configuration only: converts, builds and starts
                 nothing. Restart the server afterwards to apply.${C_RST}
  ${C_GREEN}update${C_RST}         after upstream changes: pull the latest 1181dev source,
                 rebuild only what changed, back up the world database,
                 then apply any new schema migrations.
                 ${C_DIM}Refuses while the world server is running; stop it
                 with Ctrl+C in its console first.${C_RST}
  ${C_GREEN}help${C_RST}           this text

${C_BOLD}Files:${C_RST}
  server/bin/mangosd.conf    world server settings (rates, game type, ...)
  server/bin/realmd.conf     login server settings
  server/bin/rate.conf       Turtle's per-level-bracket kill XP tuning
  server/README.linux.md     day-to-day operation guide

First boot: log in with admin / admin and create your own account from the
world console. See README.md for what to download before the first run.

EOF
}

detect_distro   # package names and the daemon hint, whatever mode we run

mode="${1:-all}"
case "$mode" in
  setup|all)
    check_deps; ensure_repack; ensure_mapdata; ensure_source; ensure_ace
    ensure_binaries; fix_configs; fix_client; ensure_database; ensure_migrations
    say "conversion complete"
    say "customize the server anytime with: $0 interactive"
    if [[ "$mode" == all ]]; then run_all "${@:2}"; fi
    ;;
  run) check_deps; run_all "${@:2}" ;;
  interactive) check_deps; ensure_repack; interactive_config ;;
  update) check_deps; update_all ;;
  help|-h|--help) usage ;;
  *) warn "unknown mode '$mode'"; usage; exit 1 ;;
esac
