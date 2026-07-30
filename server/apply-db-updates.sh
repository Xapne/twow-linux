#!/usr/bin/env bash
# Applies pending world DB migrations from the source tree
# (../src/sql/database_updates) that are newer than the last one recorded in
# turtle_world.migrations. Falls back to REPLACE INTO when a file collides
# with rows already present in the imported dump.
# Run this after import-world-db.sh, and after every git pull + rebuild.
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/../src/sql/database_updates"

DB() { mariadb -h 127.0.0.1 -P 3306 -u root -pmangos --max-allowed-packet=128M "$@"; }

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
    echo "FAILED $name:"; head -3 "$err"; rm -f "$err"; exit 1
  fi
  rm -f "$err"
  hash=$(sha1sum "$f" | awk '{print toupper($1)}')
  DB -e "INSERT INTO turtle_world.migrations (Name, Hash, AppliedAt) VALUES ('$name', '$hash', NOW());"
  echo "$status  $name"
  applied=$((applied+1))
done
echo "Done. $applied migration(s) applied."
