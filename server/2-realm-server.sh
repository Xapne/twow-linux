#!/usr/bin/env bash
# Starts the login server (realmd) in the foreground, on port 3724 by default.
# Ready when it reports the login server is up and running; Ctrl+C stops it.
#
# Usage: ./2-realm-server.sh [--help]
set -euo pipefail
SERVER="$(dirname "$(readlink -f "$0")")"
ROOT="$(dirname "$SERVER")"
KIT_TAG=realm
KIT_RERUN="$0"
[[ -r "$ROOT/lib/kit.sh" ]] \
  || { printf 'lib/kit.sh is missing beside this folder; restore it from the repo\n' >&2; exit 1; }
# shellcheck source=../lib/kit.sh
. "$ROOT/lib/kit.sh"

case "${1:-}" in
  -h|--help)
    cat <<EOF
Usage: $0

Starts the login server and stays in the foreground. A client talks to this
first: it checks the account and hands back the realm to connect to.

The database comes before it and the world server after, and both are checked
for. TWOW_SKIP_PREFLIGHT=1 starts without those checks.
EOF
    exit 0;;
  "") ;;
  *)  die "$0 takes no arguments (got '$1'); see --help";;
esac

CONF="$SERVER/bin/realmd.conf"
[[ -f "$CONF" ]] || die "server/bin/realmd.conf is missing.
  The repack provides it; re-extract TurtleWoW_1.18.zip or restore the file."

if realm_running; then
  say "the login server is already running; nothing to do"
  exit 0
fi

PORT=$(conf_get "$CONF" RealmServerPort); PORT=${PORT:-3724}

need_binary realmd
assert_port_ours "$PORT" realmd
# The login server writes account and session state, so a database it cannot
# reach leaves it retrying in a loop that reads like a broken build.
need_database realmd.conf LoginDatabaseInfo "the login server"

say "starting realmd on port $PORT"
cd "$SERVER/bin"
exec ./realmd -c realmd.conf
