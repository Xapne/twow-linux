#!/usr/bin/env bash
# Replaces "Import_World_DB.bat": drops and re-imports the turtle_world DB
# from turtle_world.sql. MySQL must be running first (./1-start-mysql.sh).
# WARNING: turtle_world.sql is a snapshot; the compiled server may expect a
# newer schema. Always run ./apply-db-updates.sh after this import.
set -euo pipefail
SERVER="$(dirname "$(readlink -f "$0")")"
ROOT="$(dirname "$SERVER")"
KIT_TAG=import
KIT_RERUN="$0"
[[ -r "$ROOT/lib/kit.sh" ]] \
  || { printf 'lib/kit.sh is missing beside this folder; restore it from the repo\n' >&2; exit 1; }
# shellcheck source=../lib/kit.sh
. "$ROOT/lib/kit.sh"
cd "$SERVER"

[[ -f turtle_world.sql ]] || die "turtle_world.sql is not in server/; it comes with the repack."
# Asked through the same connection the import will use, so a database on
# another host answers for itself rather than being judged by a local socket.
DB -e "SELECT 1" >/dev/null 2>&1 \
  || die "nothing answers at $TWOW_DB_HOST:${TWOW_DB_PORT:-3306}; start the database with:
  ./1-start-mysql.sh"

say "dropping and recreating turtle_world"
DB -e "DROP DATABASE IF EXISTS turtle_world; CREATE DATABASE turtle_world CHARACTER SET utf8mb4;"

say "importing turtle_world.sql ($(du -h turtle_world.sql | cut -f1), this takes a while)"
DB turtle_world < turtle_world.sql

say "import done; now run ./apply-db-updates.sh"
