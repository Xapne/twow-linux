#!/usr/bin/env bash
# Applies pending world DB migrations from the source tree
# (../src/sql/database_updates) that are newer than the last one recorded in
# turtle_world.migrations. Falls back to an upsert when a file collides with
# rows already present in the imported dump.
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

# Gives a colliding INSERT the migration's newer values by appending
# ON DUPLICATE KEY UPDATE over exactly the columns the statement names, so
# columns it does not mention keep what they hold. REPLACE would serve for a
# statement listing every column, but several list only a few, and REPLACE
# deletes the old row first: the unnamed columns would fall back to their
# defaults. Statements that carry their own ON DUPLICATE KEY UPDATE settle
# collisions already and are left alone, as are row forms with no column list,
# which name every column and so may be swapped whole.
#
# Statements are gathered up to their closing semicolon, since they span many
# lines. The kind is read from the first line that is neither blank nor a
# comment: generated migrations open with a -- banner, which hides the INSERT
# from a match anchored at the start of the statement. Everything up to the
# VALUES keyword names the table and then its columns, in that order.
to_upsert() {
  awk '
    function emit(   i) { for (i = 1; i <= n; i++) print line[i]; n = 0; first = 0; buf = "" }
    function flush(   i, hdr, rest, col, ncol, cols, clause, seen_values) {
      if (!first || buf ~ /ON DUPLICATE KEY UPDATE/ \
          || line[first] !~ /^[[:space:]]*INSERT INTO/) { emit(); return }
      hdr = ""; seen_values = 0
      for (i = first; i <= n; i++) {
        if (line[i] ~ /(^|[^A-Za-z0-9_])VALUES([^A-Za-z0-9_]|$)/) {
          rest = line[i]; sub(/(^|[^A-Za-z0-9_])VALUES([^A-Za-z0-9_]|$).*/, "", rest)
          hdr = hdr " " rest; seen_values = 1; break
        }
        hdr = hdr " " line[i]
      }
      ncol = 0
      while (match(hdr, /`[A-Za-z0-9_]+`/)) {
        col = substr(hdr, RSTART + 1, RLENGTH - 2)
        hdr = substr(hdr, RSTART + RLENGTH)
        if (++ncol > 1) cols[ncol - 1] = col            # the first one is the table
      }
      ncol--
      if (!seen_values || ncol < 1) {
        sub(/^[[:space:]]*INSERT INTO/, "REPLACE INTO", line[first]); emit(); return
      }
      clause = "ON DUPLICATE KEY UPDATE "
      for (i = 1; i <= ncol; i++)
        clause = clause (i > 1 ? ", " : "") "`" cols[i] "`=VALUES(`" cols[i] "`)"
      sub(/;[[:space:]]*$/, "\n" clause ";", line[n])
      emit()
    }
    {
      line[++n] = $0; buf = buf $0 "\n"
      if (!first && $0 !~ /^[[:space:]]*(--.*)?$/) first = n
      if ($0 ~ /;[[:space:]]*$/) flush()
    }
    END { if (n) flush() }
  '
}

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
       && to_upsert < "$f" | DB turtle_world 2>"$err"; then
    status="ok (upsert)"
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
