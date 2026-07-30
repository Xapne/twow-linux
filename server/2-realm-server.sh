#!/usr/bin/env bash
# Replaces "2.Realm server.bat": native login/auth server (port 3724).
# Start after MySQL is up. Ready when it reports the login server is running.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/bin"
exec ./realmd -c realmd.conf
