#!/usr/bin/env bash
# Applies pending world DB migrations from the source tree
# (../src/sql/database_updates) that are newer than the last one recorded in
# turtle_world.migrations. Falls back to REPLACE INTO when a file collides
# with rows already present in the imported dump.
# Run this after import-world-db.sh, and after every git pull + rebuild.
set -euo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
cd "$HERE/../src/sql/database_updates"

# db.env carries the port setup-native.sh settled on, which is not 3306 when a
# system MariaDB already holds that one.
# shellcheck source=/dev/null
[ -f "$HERE/db.env" ] && . "$HERE/db.env"
TWOW_DB_HOST=${TWOW_DB_HOST:-127.0.0.1}
TWOW_DB_PORT=${TWOW_DB_PORT:-3306}
TWOW_DB_USER=${TWOW_DB_USER:-root}
TWOW_DB_PASS=${TWOW_DB_PASS:-mangos}

DB() { mariadb -h "$TWOW_DB_HOST" -P "$TWOW_DB_PORT" -u "$TWOW_DB_USER" -p"$TWOW_DB_PASS" --max-allowed-packet=128M "$@"; }

last=$(DB -N -e "SELECT Name FROM turtle_world.migrations WHERE Name REGEXP '^[0-9]{14}_world$' ORDER BY Name DESC LIMIT 1")
last="${last%_world}"
echo "DB is at migration: $last"

applied=0
for f in $(ls *_world.sql | sort); do
  stamp="${f%%_*}"
  [ "$stamp" \> "$last" ] || continue
  name="${f%.sql}"
  err=$(mktemp)
  if DB turtle_world < "$f" 2>"$err"; then
    status=ok
  elif grep -q 'Duplicate entry' "$err" \
       && sed 's/^INSERT INTO/REPLACE INTO/' "$f" | DB turtle_world 2>"$err"; then
    status="ok (replace)"
  else
    # The client echoes the offending statement ahead of the error, so the
    # first lines are the statement and the ERROR line is what has to surface.
    echo "FAILED $name:"
    grep -m3 -E '^ERROR' "$err" || head -5 "$err"
    mkdir -p "$HERE/logs" && cp -f "$err" "$HERE/logs/migration-$name.err" 2>/dev/null \
      && echo "full output: server/logs/migration-$name.err"
    rm -f "$err"; exit 1
  fi
  rm -f "$err"
  hash=$(sha1sum "$f" | awk '{print toupper($1)}')
  DB -e "INSERT INTO turtle_world.migrations (Name, Hash, AppliedAt) VALUES ('$name', '$hash', NOW());"
  echo "$status  $name"
  applied=$((applied+1))
done
echo "Done. $applied migration(s) applied."
