#!/usr/bin/env bash
# Replaces "1.Start mysql.bat": runs native MariaDB with the project-local
# data directory (server/db), config in server/my.cnf.
# Ready when the log says "ready for connections".
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"
exec /usr/bin/mariadbd --defaults-file="$PWD/my.cnf"
