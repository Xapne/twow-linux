#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# Starts the world server (mangosd) in the foreground, on port 8091 by default.
# Ready when it reports "World server is up and running!", which carries the
# loading time. This terminal is also the server console
# (e.g. "account create <user> <pass>").
#
# Usage: ./3-world-server.sh [loglevel]
set -euo pipefail
SERVER="$(dirname "$(readlink -f "$0")")"
ROOT="$(dirname "$SERVER")"
KIT_TAG=world
KIT_RERUN="$0"
[[ -r "$ROOT/lib/kit.sh" ]] \
  || { printf 'lib/kit.sh is missing beside this folder; restore it from the repo\n' >&2; exit 1; }
# shellcheck source=../lib/kit.sh
. "$ROOT/lib/kit.sh"

usage() {
  cat <<EOF
Usage: $0 [loglevel]

Starts the world server and hands this terminal to its console. The optional
loglevel is written into mangosd.conf before launch and sets how much the
console says: 0 almost nothing, 1 errors only, 2 detail, 3 full debug. Without
one, whatever the config already holds is used. Log files keep their own detail
through LogFileLevel.

The world is brought back after a crash or a scheduled restart, unless
server/restart.paused exists; that file suspends it over maintenance.

The database and the login server are checked for first.
TWOW_SKIP_PREFLIGHT=1 starts without those checks.
EOF
}

CONF="$SERVER/bin/mangosd.conf"

LEVEL=""
case "${1:-}" in
  -h|--help) usage; exit 0;;
  "") ;;
  [0-3]) LEVEL="$1";;
  *)
    warn "loglevel must be 0, 1, 2 or 3 (got '$1')"
    usage; exit 1;;
esac

[[ -f "$CONF" ]] || die "server/bin/mangosd.conf is missing.
  The repack provides it; re-extract TurtleWoW_1.18.zip or restore the file."

if world_running; then
  die "the world server is already running.
  Its console is the terminal it was started in. To stop it:
  $ROOT/twow.sh stop"
fi

PORT=$(world_port)

need_binary mangosd
assert_port_ours "$PORT" mangosd
# The world keeps characters, items and the map data it serves in the database,
# and reaches accounts through the login server. Started without either it fails
# deep inside the core, far from the thing that was actually missing.
need_database mangosd.conf WorldDatabase.Info "the world server"
need_realmd "the world server"

# Written once the start is going ahead, so a refused one leaves the config as
# it found it.
[[ -n "$LEVEL" ]] && set_console_level "$LEVEL"

# Checked at every start rather than at seeding alone: a database restored from
# any older backup carries the same stale date.
fix_stale_maintenance

# Restart loop on the core's exit codes (ShutdownExitCode in src/game/World.h):
# 0 shutdown, 1 error, 2 restart. SIGINT is mapped by mangosd to 2 and SIGTERM
# to 0, so a deliberate stop cannot be told from a scheduled restart by exit
# code alone and is recorded here instead.
stop=0
trap 'stop=1' INT TERM

# Auto-restart is suspended while this file exists: the world is stopped as
# usual and then left down until the file is removed.
PAUSE="$SERVER/restart.paused"

# True when the world must not be restarted; the reason is printed.
halt() {
  ((stop))          && { echo "stopped on request; not restarting"; return 0; }
  [[ -e "$PAUSE" ]] && { echo "auto-restart paused (${PAUSE##*/} exists); leaving the world stopped"; return 0; }
  return 1
}

# The core writes every error to stderr and to its log files both, and neither
# outError nor outErrorDb consults LogLevel (src/shared/Log.cpp), so the repack's
# content errors reach the terminal at every setting. The terminal copy is put
# here instead, which leaves the console to the server's own output and prompt.
ERRLOG="$SERVER/logs/stderr.log"
mkdir -p "$SERVER/logs"
say "errors are kept in logs/server.log and logs/${ERRLOG##*/}"

cd "$SERVER/bin"
while :; do
  set +e
  ./mangosd -c mangosd.conf 2>>"$ERRLOG"
  code=$?
  set -e
  halt && exit 0
  case $code in
    0) echo "world server stopped cleanly"; exit 0;;
    2) echo "scheduled restart - bringing the world back"; sleep 2;;
    *) echo "mangosd exited with code $code - back in 5s (Ctrl+C now to stop for good)"; sleep 5;;
  esac
  halt && exit 0        # checked again: a signal may arrive during the wait
done
