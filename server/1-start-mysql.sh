#!/usr/bin/env bash
# Starts this server's own MariaDB in the foreground: the project-local data
# directory in server/db, configured by server/my.cnf.
# Ready when the log says "ready for connections"; Ctrl+C stops it.
#
# Usage: ./1-start-mysql.sh [--help]
set -euo pipefail
SERVER="$(dirname "$(readlink -f "$0")")"
ROOT="$(dirname "$SERVER")"
KIT_TAG=mysql
KIT_RERUN="$0"
[[ -r "$ROOT/lib/kit.sh" ]] \
  || { printf 'lib/kit.sh is missing beside this folder; restore it from the repo\n' >&2; exit 1; }
# shellcheck source=../lib/kit.sh
. "$ROOT/lib/kit.sh"

case "${1:-}" in
  -h|--help)
    cat <<EOF
Usage: $0

Starts this server's database and stays in the foreground. The data directory
is server/db, the settings are server/my.cnf, and the port is the one recorded
in server/db.env, which is not 3306 when a distro MariaDB already holds that.

The login server and the world server both need it, so it comes first.
EOF
    exit 0;;
  "") ;;
  *)  die "$0 takes no arguments (got '$1'); see --help";;
esac

# A data directory is made once, by the setup, which then seeds the game
# databases into it. Started against nothing, the daemon prints a page of
# errors that name neither the cause nor the way out.
[[ -d "$SERVER/db/mysql" ]] \
  || die "there is no database in server/db yet; the setup creates and seeds it:
  $ROOT/setup-native.sh setup"

# A second daemon on the same data directory is refused by the first one's lock
# file, several screens later. Say so here instead.
if mariadb_running; then
  resolve_db_port
  say "the database is already running on $TWOW_DB_HOST:$TWOW_DB_PORT; nothing to do"
  exit 0
fi

resolve_db_port
sync_my_cnf
write_db_env

port_free "$TWOW_DB_PORT" || die "port $TWOW_DB_PORT is in use by something that is not this database.
  A distro mariadb service is the usual answer, and a second copy of this kit
  the other one. What holds it:  ss -tlnp | grep ':$TWOW_DB_PORT '
  Stop it, or run this database elsewhere: TWOW_DB_PORT=<port> $0"

mariadbd=$(find_mariadbd) \
  || die "no mariadbd/mysqld found; install your distro's MariaDB server package
  ($ROOT/setup-native.sh deps names it for this system)"

say "starting MariaDB on $TWOW_DB_HOST:$TWOW_DB_PORT, data in server/db"
exec "$mariadbd" --defaults-file="$SERVER/my.cnf"
