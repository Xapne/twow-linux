# =============================================================================
# The kit's shared machinery: how it speaks, how it reaches the database, and
# how it answers what is already running
# =============================================================================
# Sourced by setup-native.sh and by every script in server/, which had a copy
# each: db.env was read in three places, the MariaDB daemon looked for in two,
# and config keys rewritten in two dialects, of which only one could tell a
# missing key from a rewritten one.
#
# ROOT and SERVER are derived from this file's own location; a caller that has
# them already keeps its own.

KIT_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${ROOT:=$(dirname "$KIT_LIB")}"
: "${SERVER:=$ROOT/server}"

# What to suggest re-running in a message that offers a variable or a flag.
# Every entry point sets its own; the plain command is the fallback.
: "${KIT_RERUN:=$0}"

# -----------------------------------------------------------------------------
# Saying things
# -----------------------------------------------------------------------------
# KIT_TAG names the speaker, so a line reads as coming from the mysql script or
# the world script rather than from "setup" wherever it was printed. The three
# spellings themselves are a contract: setup-vm.sh reads "[setup]", "[warn]" and
# "[error]" out of the guest's log to drive its progress bar and to fail fast.
: "${KIT_TAG:=setup}"
say()  { printf '\033[1;32m[%s]\033[0m %s\n' "$KIT_TAG" "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# The database handle
# -----------------------------------------------------------------------------
# db.env carries the port setup-native.sh settled on, which is not 3306 when a
# system MariaDB already holds that one. It is written in ${VAR:-default} form
# so a value from the environment still wins, and the TWOW_ prefix keeps a bare
# DB_HOST/DB_PORT/DB_USER already in the environment out of the way.
#
# The port is deliberately left empty when nothing has settled it: setup-native.sh
# resolves it against what is listening, and a script that cannot resolve says
# 3306 for itself.
[[ -f "$SERVER/db.env" ]] && . "$SERVER/db.env"
TWOW_DB_HOST=${TWOW_DB_HOST:-127.0.0.1}
TWOW_DB_PORT=${TWOW_DB_PORT:-}
TWOW_DB_USER=${TWOW_DB_USER:-root}
TWOW_DB_PASS=${TWOW_DB_PASS:-mangos}
# The bundled Windows MariaDB is only borrowed once, to dump the game databases
# out of, and it carries the password the repack shipped with. That is not this
# server's password: TWOW_DB_PASS may be set to anything, and reusing it for the
# seeding instance makes a fresh install fail at the one step a new password
# cannot reach.
TWOW_SEED_PASS=${TWOW_SEED_PASS:-mangos}
export TWOW_DB_HOST TWOW_DB_PORT TWOW_DB_USER TWOW_DB_PASS TWOW_SEED_PASS

DB() { mariadb -h "$TWOW_DB_HOST" -P "${TWOW_DB_PORT:-3306}" -u "$TWOW_DB_USER" -p"$TWOW_DB_PASS" --max-allowed-packet=128M "$@"; }

# The project's instance is always reachable on its own socket, whatever the
# port. ping is used rather than a query because it reports the daemon as alive
# even when the credentials are refused; a password problem would otherwise look
# like "not running" and be reported as a port clash further down.
mariadb_running() { mariadb-admin --socket="$SERVER/db/mysql.sock" -u "$TWOW_DB_USER" -p"$TWOW_DB_PASS" ping >/dev/null 2>&1; }

# Whether the game databases have already been imported. InnoDB gives each
# database a directory, so this answers without starting the server.
seeded() { [[ -d "$SERVER/db/turtle_logon" ]]; }

# -----------------------------------------------------------------------------
# Ports, processes and the daemon
# -----------------------------------------------------------------------------
# The MariaDB daemon lives in a different place on every distro (/usr/bin on
# Arch, /usr/sbin on Debian, /usr/libexec on Fedora), and some of them keep sbin
# out of a normal user's PATH. Look everywhere, print the path.
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

# The ports the two servers answer on, as their configs have them. Asked in one
# place so starting, stopping and reporting all reach the same server when a
# port has been moved.
realm_port() {
  local p; p=$(conf_get "$SERVER/bin/realmd.conf" RealmServerPort 2>/dev/null) || p=""
  printf '%s' "${p:-3724}"
}
world_port() {
  local p; p=$(conf_get "$SERVER/bin/mangosd.conf" WorldServerPort 2>/dev/null) || p=""
  printf '%s' "${p:-8091}"
}

port_free() {
  if command -v ss >/dev/null 2>&1; then
    ! ss -tln 2>/dev/null | grep -q "[:.]$1 "
  else
    ! (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
  fi
}

# Both cores rename their main thread ("MainThread" in /proc comm), so process
# checks have to look at the command line, not the process name.
world_running() { pgrep -f 'mangosd -c' >/dev/null 2>&1; }
realm_running() { pgrep -f 'realmd -c' >/dev/null 2>&1; }

# The pid holding a port, but only when the binary behind it is one of ours.
# Anything may listen on 3724: a second install of this kit, a repack still
# running under wine, or a virtual machine forwarding the port from a guest.
# Treating any listener as proof that our login server is up starts the world
# against somebody else's, which fails later and further away. /proc/pid/exe is
# asked rather than the command line, since that cannot be spoofed by a name.
our_listener() {  # $1 port -> pid, or empty when nobody or not ours
  local pid exe
  pid=$( { ss -tlnp 2>/dev/null || true; } | grep "[:.]$1 " | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
  [[ -n "$pid" ]] || return 0
  exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || return 0
  [[ "$exe" == "$SERVER/bin/"* ]] && printf '%s' "$pid"
  return 0
}

# Someone is on the port, and it is not us.
port_taken_by_other() {  # $1 port
  ss -tln 2>/dev/null | grep -q "[:.]$1 " && [[ -z "$(our_listener "$1")" ]]
}

# "Something is listening" is not "our server is up". A stranger on the port is
# reported rather than adopted, since starting against another realm's login
# server fails much later, with nothing pointing here.
assert_port_ours() {  # $1 port, $2 what should be holding it
  port_taken_by_other "$1" || return 0
  die "port $1 is held by something that is not this server's $2.
  Another install of this kit, a repack still running under wine, or a virtual
  machine forwarding the port? Stop it, then start again. What holds it:
  ss -tlnp | grep ':$1 '"
}

# -----------------------------------------------------------------------------
# Reading and writing the repack's config files
# -----------------------------------------------------------------------------
conf_get() {  # $1 file, $2 key -> value, quotes and CR stripped
  sed -n "s/^${2//./\\.}[[:space:]]*=[[:space:]]*//p" "$1" \
    | tail -1 | tr -d '\r' | sed 's/^"\(.*\)"$/\1/'
}

# Whether a key is in the file at all. A plain sed rewrite cannot tell a missing
# key from a rewritten one and reports success either way.
conf_has() {  # $1 file, $2 key
  grep -q "^${2//./\\.}[[:space:]]*=" "$1"
}

# $1 file, $2 key, $3 value, [$4 = quote]; no-op if unchanged. A missing key is
# reported and skipped rather than treated as an error, so one absent setting
# does not abandon a form half filled in. CONF_WARN names the voice, so the
# interactive screen keeps its gutter style.
conf_set() {
  local file="$1" key="$2" val="$3" cur esc
  cur="$(conf_get "$file" "$key")"
  [[ "$cur" == "$val" ]] && return 0
  if ! conf_has "$file" "$key"; then
    "${CONF_WARN:-warn}" "$key not found in ${file##*/}, skipped"
    return 0
  fi
  CHANGES+=("$key: ${cur:-unset} -> $val")
  [[ "${4:-}" == quote ]] && val="\"$val\""
  esc="${val//\\/\\\\}"; esc="${esc//&/\\&}"; esc="${esc//|/\\|}"
  sed -i "s|^${key//./\\.}[[:space:]]*=.*|$key = $esc|" "$file"
}

# The connection string the core will actually use, as host port user pass db.
# Asked of the config rather than of db.env because that is what the server
# reads, and the two disagree when a config was left pointing at 3306 where a
# distro MariaDB answers and refuses.
conf_db_info() {  # $1 file, $2 key
  local info
  info=$(conf_get "$1" "$2" 2>/dev/null) || return 1
  [[ -n "$info" ]] || return 1
  printf '%s' "${info//;/ }"
}

# Whether the database named in a config answers there.
conf_db_reachable() {  # $1 file, $2 key
  local h p u w n
  read -r h p u w n <<<"$(conf_db_info "$1" "$2")" || return 1
  [[ -n "$h" && -n "$p" ]] || return 1
  mariadb -h "$h" -P "$p" -u "$u" -p"$w" -e "SELECT 1" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Preflight: the questions each start script asks before it launches anything
# -----------------------------------------------------------------------------
# Ordering used to be documented and not enforced, so a world server started
# before its database failed deep inside the core with nothing pointing back
# here. TWOW_SKIP_PREFLIGHT=1 starts anyway, for a setup these do not describe.
preflight_skipped() {
  [[ -n "${TWOW_SKIP_PREFLIGHT:-}" ]] || return 1
  warn "TWOW_SKIP_PREFLIGHT is set; starting without checking $1"
  return 0
}

need_binary() {  # $1 name in server/bin
  [[ -x "$SERVER/bin/$1" ]] && return 0
  die "server/bin/$1 is missing or not executable.
  The native binaries are built by: $ROOT/setup-native.sh setup"
}

need_database() {  # $1 config file, $2 key, $3 who is asking
  preflight_skipped "the database" && return 0
  conf_db_reachable "$SERVER/bin/$1" "$2" && return 0
  local h p rest
  read -r h p rest <<<"$(conf_db_info "$SERVER/bin/$1" "$2" 2>/dev/null)" || h=""
  die "$3 needs the database, and nothing answers at ${h:-?}:${p:-?}, where $1 points.
  Start it with: $SERVER/1-start-mysql.sh
  Already running elsewhere? Point the config at it, or set TWOW_SKIP_PREFLIGHT=1."
}

need_realmd() {  # $1 who is asking
  preflight_skipped "the login server" && return 0
  realm_running && return 0
  die "$1 needs the login server, which is not running.
  Start it with: $SERVER/2-realm-server.sh
  Running it elsewhere on purpose? Set TWOW_SKIP_PREFLIGHT=1."
}

# -----------------------------------------------------------------------------
# Where this server's database lives
# -----------------------------------------------------------------------------
# On Debian and Ubuntu the packaged mariadb is started on 3306 as soon as it is
# installed, so that port is frequently unavailable; a free one is picked
# instead of requiring the system service to be disabled. 3307 is left for the
# wine seeding instance, which picks its own free port too.
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
  using port $p for this server's own database instead. Note that a bare
  'mariadb' in a shell still reaches 3306, not this server's database; see
  server/db.env for the port in use. To hand 3306 back to this server, stop
  the other one (Debian/Ubuntu: sudo systemctl disable --now mariadb) and
  re-run this script."
    return 0
  done
  die "no free port for the database between 3306 and 3312.
  Pick one yourself with: TWOW_DB_PORT=<port> $KIT_RERUN"
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

# -----------------------------------------------------------------------------
# honor maintenance date left behind by whoever made the dump
# -----------------------------------------------------------------------------
# saved_variables records the PvP maintenance week of the machine a database
# came from, and the repack's dump is months old by the time anyone installs
# from it. The core compares that date with today, finds it long past, and
# schedules a restart into a server that has only just started. Worse, it moves
# the record on by a single week per restart (HonorMgr.cpp, DoMaintenance ends
# with SetMaintenanceDays(GetNextMaintenanceDay())), so a month-old date costs a
# month of restarts before it catches up.
#
# Only a date already more than a week stale is touched. A server that is
# running normally always has its next day ahead of today, and one that was off
# over its maintenance day has a genuinely due restart worth keeping, so
# neither is disturbed. The record is cleared rather than guessed at: with no
# last day set, HonorMaintenancer::Initialize works both dates out itself from
# the core's own maintenance weekday.
fix_stale_maintenance() {
  local next today
  next=$(DB -N -B -e "SELECT nextHonorMaintenanceDay FROM turtle_char.saved_variables" 2>/dev/null) || return 0
  [[ "$next" =~ ^[0-9]+$ ]] || return 0
  today=$(( $(date +%s) / 86400 ))
  (( next > 0 && next < today - 7 )) || return 0
  DB turtle_char -e "UPDATE saved_variables SET lastHonorMaintenanceDay = 0,
                       nextHonorMaintenanceDay = 0, honorMaintenanceMarker = 0" 2>/dev/null \
    && say "honor maintenance date was $(( today - next )) days stale; cleared, the core sets its own on this start" \
    || warn "could not clear a stale honor maintenance date; the server may announce
  a restart shortly after starting, and will not come back on its own."
}
