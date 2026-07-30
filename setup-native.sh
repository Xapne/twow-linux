#!/usr/bin/env bash
# =============================================================================
# TurtleWoW 1.18.1: convert the SIGGZ Windows repack to a native Linux server
# and run it, in one command. Arch Linux oriented; every step is idempotent,
# so re-running only does what is missing.
#
# Layout it expects (and creates) under the folder this script lives in:
#   server/   the repack (from TurtleWoW_1.18.zip), native db in server/db
#   client/   the 1.18.1 game client (only needed to play, not to convert)
#   src/      Penqle/tortoise-wow source, branch 1181dev
#   build/    native build tree
#   deps/     locally built ACE library
#
# Usage:
#   ./setup-native.sh          convert if needed, then start everything
#   ./setup-native.sh setup    convert only
#   ./setup-native.sh run      start only (refuses if not converted)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER="$ROOT/server"
DB_HOST=127.0.0.1 DB_PORT=3306 DB_USER=root DB_PASS=mangos
ACE_VER=8.0.3
BRANCH=1181dev
REPO=https://github.com/Penqle/tortoise-wow.git

say()  { printf '\033[1;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

DB() { mariadb -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" --max-allowed-packet=128M "$@"; }

# -----------------------------------------------------------------------------
# Step 0: dependencies, with the exact package to install when one is missing
# -----------------------------------------------------------------------------
check_deps() {
  local -A pkg=(
    [gcc]=gcc [g++]=gcc [cmake]=cmake [ninja]=ninja [git]=git [curl]=curl
    [bsdtar]=libarchive [sha1sum]=coreutils
    [mariadb]=mariadb [mariadbd]=mariadb [mariadb-install-db]=mariadb
    [mariadb-dump]=mariadb [mariadb-admin]=mariadb
  )
  local missing=()
  for c in "${!pkg[@]}"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c (pacman -S ${pkg[$c]})")
  done
  ((${#missing[@]} == 0)) || die "missing commands: ${missing[*]}"
  say "all required commands present"
}

# -----------------------------------------------------------------------------
# Step 1: repack files in server/
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
# Step 2: map data in server/data (dbc, maps, mmaps, vmaps)
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
# Step 3: source checkout
# -----------------------------------------------------------------------------
ensure_source() {
  if [[ -f "$ROOT/src/CMakeLists.txt" ]]; then say "source already in src/"; return; fi
  say "cloning $REPO ($BRANCH)"
  git clone --depth 1 --branch "$BRANCH" "$REPO" "$ROOT/src" \
    || die "git clone failed. Check network access and that branch '$BRANCH' still exists."
}

# -----------------------------------------------------------------------------
# Step 4: ACE library (not packaged on Arch; built locally)
# -----------------------------------------------------------------------------
ensure_ace() {
  export ACE_ROOT="$ROOT/deps/ACE_wrappers"
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
# Step 5: build realmd + mangosd, install into server/bin
# -----------------------------------------------------------------------------
ensure_binaries() {
  if [[ -x "$SERVER/bin/mangosd" && -x "$SERVER/bin/realmd" ]]; then
    say "native binaries already in server/bin/"; return
  fi
  say "configuring and compiling the server (10-20 min on first run)"
  ACE_ROOT="$ROOT/deps/ACE_wrappers" cmake -B "$ROOT/build" -S "$ROOT/src" -GNinja \
    -DCMAKE_BUILD_TYPE=Release -DDEBUG_SYMBOLS=OFF > "$ROOT/build-configure.log" 2>&1 \
    || die "cmake configure failed, see $ROOT/build-configure.log"
  ninja -C "$ROOT/build" mangosd realmd \
    || die "compile failed. Scroll up for the first error; report it on the tortoise-wow GitHub."
  cp "$ROOT/build/src/mangosd/mangosd" "$ROOT/build/src/realmd/realmd" "$SERVER/bin/"
  say "installed native mangosd and realmd"
}

# -----------------------------------------------------------------------------
# Step 6: config fixes needed on Linux
# -----------------------------------------------------------------------------
fix_configs() {
  local f
  for f in "$SERVER/bin/realmd.conf" "$SERVER/bin/mangosd.conf"; do
    [[ -f "$f" ]] || die "$f is missing. The repack should provide it;
  re-extract TurtleWoW_1.18.zip or restore the file from it."
  done
  sed -i 's|LoginDatabaseInfo = "localhost;|LoginDatabaseInfo = "127.0.0.1;|' "$SERVER/bin/realmd.conf"
  sed -i 's|^DataDir = "\.\./Data"|DataDir = "../data"|' "$SERVER/bin/mangosd.conf"
  say "configs checked (realmd 127.0.0.1, DataDir lowercase)"
}

# -----------------------------------------------------------------------------
# Step 6b: client safety, if a client is present in client/
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
# Step 7: native database in server/db, seeded from the bundled Windows one
# -----------------------------------------------------------------------------
mariadb_running() { mariadb --socket="$SERVER/db/mysql.sock" -u root -p"$DB_PASS" -e "SELECT 1" >/dev/null 2>&1; }

start_native_db() {
  mariadb_running && return
  ss -tln | grep -q ":$DB_PORT " && die "port $DB_PORT is in use by something that is not our database.
  Stop it first (is a system mysqld/mariadbd service running?)."
  say "starting native MariaDB"
  nohup /usr/bin/mariadbd --defaults-file="$SERVER/my.cnf" > "$SERVER/logs/mysql.out" 2>&1 &
  local i; for i in $(seq 1 30); do [[ -S "$SERVER/db/mysql.sock" ]] && break; sleep 1; done
  [[ -S "$SERVER/db/mysql.sock" ]] || die "MariaDB did not come up, see $SERVER/logs/mysql.out"
}

ensure_database() {
  mkdir -p "$SERVER/logs"
  if [[ ! -f "$SERVER/my.cnf" ]]; then
    cat > "$SERVER/my.cnf" <<EOF
[mysqld]
datadir = $SERVER/db
socket  = $SERVER/db/mysql.sock
bind-address = 127.0.0.1
port = $DB_PORT
max_allowed_packet = 128M
innodb_flush_log_at_trx_commit = 2
innodb_buffer_pool_size = 512M

[client]
socket = $SERVER/db/mysql.sock
max_allowed_packet = 128M
EOF
  fi
  if [[ ! -d "$SERVER/db/mysql" ]]; then
    say "initializing native MariaDB data dir in server/db"
    mariadb-install-db --no-defaults --datadir="$SERVER/db" \
      --auth-root-authentication-method=normal > "$SERVER/logs/mysql-install.log" 2>&1 \
      || die "mariadb-install-db failed, see $SERVER/logs/mysql-install.log"
    start_native_db
    mariadb --socket="$SERVER/db/mysql.sock" -u root -e "
      ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_PASS';
      CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
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
    || die "game databases are empty and seeding them needs wine once (pacman -S wine).
  Alternative: import dumps you already have into $DB_HOST:$DB_PORT."
  local windb="$SERVER/mariadb-10.3.39-winx64"
  [[ -d "$windb/data/turtle_logon" ]] \
    || die "bundled Windows MariaDB data not found in $windb; cannot seed the databases."
  say "seeding databases from the bundled Windows MariaDB (via wine, one time)"
  ( cd "$windb/bin" && nohup wine mysqld.exe --console --port=3307 \
      > "$SERVER/logs/wine-mysql.out" 2>&1 & )
  local i; for i in $(seq 1 60); do
    mariadb -h 127.0.0.1 -P 3307 -u root -p"$DB_PASS" --skip-ssl -e "SELECT 1" >/dev/null 2>&1 && break
    sleep 2
  done
  mariadb -h 127.0.0.1 -P 3307 -u root -p"$DB_PASS" --skip-ssl -e "SELECT 1" >/dev/null 2>&1 \
    || die "wine MariaDB did not come up, see $SERVER/logs/wine-mysql.out"
  mariadb-dump -h 127.0.0.1 -P 3307 -u root -p"$DB_PASS" --skip-ssl --routines --triggers \
    --databases turtle_logon turtle_char turtle_logs turtle_world > "$SERVER/logs/seed-dump.sql" \
    || die "dumping from the wine MariaDB failed"
  mariadb-admin -h 127.0.0.1 -P 3307 -u root -p"$DB_PASS" --skip-ssl shutdown || true
  say "importing the seed dump into native MariaDB"
  DB < "$SERVER/logs/seed-dump.sql" || die "import of the seed dump failed"
}

# -----------------------------------------------------------------------------
# Step 8: bring the world DB schema up to what the compiled source expects
# -----------------------------------------------------------------------------
ensure_migrations() {
  [[ -x "$SERVER/apply-db-updates.sh" ]] \
    || die "$SERVER/apply-db-updates.sh is missing; restore it from the repo."
  "$SERVER/apply-db-updates.sh"
}

# -----------------------------------------------------------------------------
# Run: DB (background) -> realmd (background) -> mangosd (foreground console)
# -----------------------------------------------------------------------------
run_all() {
  [[ -x "$SERVER/bin/mangosd" ]] || die "no native binaries yet; run: $0 setup"
  start_native_db
  say "MariaDB ready on $DB_HOST:$DB_PORT"

  if ! ss -tln | grep -q ':3724 '; then
    ( cd "$SERVER/bin" && nohup ./realmd -c realmd.conf > "$SERVER/logs/realmd.out" 2>&1 & )
    local i; for i in $(seq 1 15); do ss -tln | grep -q ':3724 ' && break; sleep 1; done
    ss -tln | grep -q ':3724 ' || die "realmd did not come up, see $SERVER/logs/realmd.out"
  fi
  say "realmd ready on 3724"

  say "starting mangosd in the foreground; this terminal is the server console"
  say "first boot loads all maps and takes a few minutes; stop with Ctrl+C"
  trap 'warn "world server stopped; realmd and MariaDB are still running.
  Stop them with: pkill -INT -f \"realmd -c\"; mariadb-admin -h 127.0.0.1 -u root -pmangos shutdown"' EXIT
  [[ -x "$SERVER/3-world-server.sh" ]] \
    || die "$SERVER/3-world-server.sh is missing or not executable;
  restore it (chmod +x) or start manually: cd $SERVER/bin && ./mangosd -c mangosd.conf"
  exec "$SERVER/3-world-server.sh" "$@"
}

# -----------------------------------------------------------------------------
mode="${1:-all}"
case "$mode" in
  setup|all)
    check_deps; ensure_repack; ensure_mapdata; ensure_source; ensure_ace
    ensure_binaries; fix_configs; fix_client; ensure_database; ensure_migrations
    say "conversion complete"
    if [[ "$mode" == all ]]; then run_all "${@:2}"; fi
    ;;
  run) check_deps; run_all "${@:2}" ;;
  *) die "unknown mode '$mode' (use: setup, run, or no argument for both)" ;;
esac
