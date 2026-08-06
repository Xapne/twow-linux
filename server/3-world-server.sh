#!/usr/bin/env bash
# Replaces "3.World server.bat": native world server (port 8091).
# Start after MySQL and the realm server. First boot loads maps and takes a
# few minutes. This terminal is also the server console
# (e.g. "account create <user> <pass>").
#
# Usage: ./3-world-server.sh [loglevel]
#   loglevel (optional): console verbosity 0-3, written into mangosd.conf
#   before launch. 0 = almost nothing, 1 = errors only, 2 = detail,
#   3 = full debug. Without an argument the current config value is used.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/bin"

if [[ $# -ge 1 ]]; then
  case "$1" in
    [0-3])
      sed -i -E "s/^LogLevel = [0-9]+/LogLevel = $1/" mangosd.conf
      # quiet levels also mute the per-query SQL echo (LogFilter_SQLText),
      # chatty levels show it; it prints at basic level regardless of LogLevel
      if [[ "$1" -le 1 ]]; then sqlfilter=1; else sqlfilter=0; fi
      sed -i -E "s/^LogFilter_SQLText = [0-9]+/LogFilter_SQLText = $sqlfilter/" mangosd.conf
      echo "console LogLevel set to $1, SQL echo $([[ $sqlfilter == 1 ]] && echo off || echo on)"
      ;;
    *)
      echo "error: loglevel must be 0, 1, 2 or 3 (got '$1')" >&2
      exit 1
      ;;
  esac
fi

# Restart loop on the core's exit codes (ShutdownExitCode in src/game/World.h):
# 0 shutdown, 1 error, 2 restart. SIGINT is mapped by mangosd to 2 and SIGTERM
# to 0, so a deliberate stop cannot be told from a scheduled restart by exit
# code alone and is recorded here instead.
stop=0
trap 'stop=1' INT TERM

# Auto-restart is suspended while this file exists: the world is stopped as
# usual and then left down until the file is removed.
PAUSE="$(dirname "$(readlink -f "$0")")/restart.paused"

# True when the world must not be restarted; the reason is printed.
halt() {
  ((stop))          && { echo "stopped on request; not restarting"; return 0; }
  [[ -e "$PAUSE" ]] && { echo "auto-restart paused (${PAUSE##*/} exists); leaving the world stopped"; return 0; }
  return 1
}

while :; do
  set +e
  ./mangosd -c mangosd.conf
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
