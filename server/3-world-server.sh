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
      echo "console LogLevel set to $1 ($(grep -m1 '^LogLevel' mangosd.conf))"
      ;;
    *)
      echo "error: loglevel must be 0, 1, 2 or 3 (got '$1')" >&2
      exit 1
      ;;
  esac
fi

exec ./mangosd -c mangosd.conf
