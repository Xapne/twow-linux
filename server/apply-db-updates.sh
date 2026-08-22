#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# Applies the migrations in this install's source checkout that the database has
# not recorded yet, each to the database its stream belongs to. Falls back to an
# upsert when a file collides with rows already present in the imported dump.
# Run this after import-world-db.sh, and after every git pull + rebuild.
set -euo pipefail
HERE="$(dirname "$(readlink -f "$0")")"
SERVER="$HERE"
ROOT="$(dirname "$HERE")"
KIT_TAG=migrate
KIT_RERUN="$0"
[[ -r "$ROOT/lib/kit.sh" ]] \
  || { printf 'lib/kit.sh is missing beside this folder; restore it from the repo\n' >&2; exit 1; }
# shellcheck source=../lib/kit.sh
. "$ROOT/lib/kit.sh"
# Which core this install runs, and the tables that core seeds once.
# shellcheck source=../lib/variant.sh
. "$ROOT/lib/variant.sh"

# Every migration stream a source checkout carries, declared once. The applier,
# the count doctor asks for through --check and the table each stream records
# into are all derived from this; a second list drifts, and a stream left out of
# it is schema the core expects and the database does not have.
#
# Columns, separated by | :
#   1 directory  under the source checkout
#   2 database   the stream applies to
#   3 glob       what a file of this stream is called; a stream is ordered by
#                the 14-digit stamp its files open with, so the glob asks for
#                one rather than taking every .sql in the directory
#
# What a particular core seeds beyond these is its own business and is declared
# in lib/variant.sh, which is asked for it below.
STREAMS=(
  "sql/database_updates|turtle_world|*_world.sql"
  "sql/database_updates/world|turtle_world|*_world.sql"
  "sql/database_updates/character|turtle_char|*_character.sql"
  "sql/character_updates|turtle_char|[0-9]*.sql"
)

# The core also carries a whole world dump, one file per table under sql/base,
# each opening with DROP TABLE. Only the tables a database has never had are
# taken from there: the repack's own dump is this realm's world data, and a file
# that rebuilt a table it already filled would throw that data away. A file is
# named tw_<database>_<table>.sql, which is where both come from.
BASE_DIR=sql/base

# The base files whose table is absent, as database|directory|file. Reading the
# table list once per database keeps this one query rather than one per file.
# $1 a file holding the applied names, which are also skipped
base_missing() {
  local applied=$1 f name db table have
  [[ -d "$SRC/$BASE_DIR" ]] || return 0
  have=$(mktemp)
  for f in "$SRC/$BASE_DIR"/tw_*.sql; do
    [ -e "$f" ] || continue
    name=${f##*/}; name=${name%.sql}
    case "$name" in
      tw_world_*) db=turtle_world; table=${name#tw_world_} ;;
      tw_char_*)  db=turtle_char;  table=${name#tw_char_}  ;;
      tw_logon_*) db=turtle_logon; table=${name#tw_logon_} ;;
      *) continue ;;
    esac
    grep -qxF -- "$name" "$applied" && continue
    DB -N -B -e "SHOW TABLES FROM \`$db\`" > "$have" 2>/dev/null || true
    grep -qxF -- "$table" "$have" && continue
    printf '%s|%s|%s\n' "$db" "$BASE_DIR" "$name.sql"
  done
  rm -f "$have"
  return 0
}

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

# The bookkeeping table, in the core's own shape, since both write to it. The
# world database arrives from the dump with one; a character stream is applied
# against whatever the repack left, so the table is created where it is absent.
# $1 database
ensure_migration_table() {
  DB "$1" <<'SQL'
CREATE TABLE IF NOT EXISTS `migrations` (
  `Id` INT(10) UNSIGNED NOT NULL AUTO_INCREMENT,
  `Name` VARCHAR(255) NOT NULL DEFAULT '0' COLLATE 'utf8_general_ci',
  `Module` VARCHAR(255) NOT NULL DEFAULT '' COLLATE 'utf8_general_ci',
  `Hash` VARCHAR(128) NOT NULL DEFAULT '0' COLLATE 'utf8_general_ci',
  `AppliedAt` DATETIME NOT NULL,
  PRIMARY KEY (`Id`) USING BTREE
) COLLATE = 'utf8_general_ci' ENGINE = InnoDB;
SQL
}

# What the database has recorded, one name per line. A database with no such
# table has recorded nothing, which is what a first run finds; creating it
# belongs to the applier, so counting stays a read.
# $1 database
applied_names() { DB -N -B -e "SELECT Name FROM \`$1\`.migrations" 2>/dev/null || true; }

# Errors that say the database already has the structure a migration adds:
# a table, a column, an index, a foreign key, or something dropped that was
# never there.
ALREADY_THERE='1050|1060|1061|1091|1826'

# Whether the client reported errors and every one of them is structure the
# database already has.
# $1 the client's output
only_already_there() {
  grep -qE '^ERROR' "$1" || return 1
  ! grep -E '^ERROR' "$1" | grep -qvE "^ERROR ($ALREADY_THERE) "
}

# Whether a file failed only on structure that is already in place. The
# character databases arrive as a slice of a live server with no record of what
# that server had applied, so their older migrations describe schema the dump
# already carries. The file is run again with the client kept going past those
# errors, so every statement it carries is still attempted, and it counts as
# applied only when nothing failed for another reason.
# $1 database, $2 file, $3 where the output is kept
already_there() {
  grep -qE "^ERROR ($ALREADY_THERE) " "$3" || return 1
  DB --force "$1" < "$2" 2>"$3" || true
  only_already_there "$3"
}

# The stream's files the database has yet to record, oldest first. What has
# been applied is matched by name rather than measured against the newest stamp
# recorded: two branches of the source interleave their stamps, so a file
# carried only by the branch being switched to would sit below such a mark and
# never be applied. The 14-digit stamp makes the glob's lexical order
# chronological.
# $1 the glob naming this stream's files, $2 a file holding the applied names
pending_files() {
  local glob=$1 applied=$2 f
  # The glob reaches the loop unquoted on purpose; it is the pattern, not a name.
  # shellcheck disable=SC2086
  for f in $glob; do
    [ -e "$f" ] || continue
    grep -qxF -- "${f%.sql}" "$applied" && continue
    printf '%s\n' "$f"
  done
}

# Every pending file of every stream, as stamp|database|directory|file, oldest
# first. The order is the stamp a file opens with rather than the directory
# holding it: the streams interleave, and a fix in one names a column another
# adds. A name carrying no stamp is a core's own seed and sorts ahead of them
# all, which is where those belong.
pending_all() {
  local stream dir db glob f key
  {
  # A table the database has never had comes before every stamp, since a
  # migration a few files along inserts into one of them.
  applied_names turtle_world > "$APPLIED"
  applied_names turtle_char >> "$APPLIED"
  base_missing "$APPLIED" | sed 's/^/00000000000000|/'
  for stream in "${ALL_STREAMS[@]}"; do
    IFS='|' read -r dir db glob <<< "$stream"
    [[ -d "$SRC/$dir" ]] || continue
    applied_names "$db" > "$APPLIED"
    cd "$SRC/$dir" || continue
    while IFS= read -r f; do
      key=${f%%_*}
      [[ "$key" =~ ^[0-9]{14}$ ]] || key=00000000000000
      printf '%s|%s|%s|%s\n' "$key" "$db" "$dir" "$f"
    done < <(pending_files "$glob" "$APPLIED")
  done
  } | sort -s -t'|' -k1,1
}

# run only when executed, not when sourced (keeps the functions testable)
[[ "${BASH_SOURCE[0]}" == "$0" ]] || return 0

# The core's own tables come before the stamped migrations: one of them indexes
# a table seeded there, and a stream that runs first cannot depend on one that
# has not.
mapfile -t ALL_STREAMS < <(variant_streams; printf '%s\n' "${STREAMS[@]}")

CHECK=0
case "${1:-}" in
  "")        ;;
  --check)   CHECK=1 ;;
  # What the update mode asks before it dumps anything: the databases a
  # migration can reach, so the backup it takes covers them without a second
  # list of them living over there.
  --databases) printf '%s\n' "${ALL_STREAMS[@]}" | cut -d'|' -f2 | sort -u; exit 0 ;;
  -h|--help) printf 'Usage: %s [--check | --databases]\n  --check      counts what is pending and applies none\n  --databases  names the databases the streams reach\n' "$0"; exit 0 ;;
  *)         die "unknown option '$1'; --check counts what is pending and applies none,
  --databases names the databases the streams reach" ;;
esac

SRC=$(variant_src)
[[ -d "$SRC/sql" ]] \
  || die "no source checkout in ${SRC#"$ROOT"/}, which is where the migrations live:
  $ROOT/twow.sh setup"

APPLIED=$(mktemp); trap 'rm -f "$APPLIED"' EXIT
TOTAL=0

# Applies one file and records it by name, or says what went wrong and stops.
# A collision with the imported dump is settled as an upsert, and structure the
# database already has counts as applied.
# $1 database, $2 directory under the source, $3 file
apply_file() {
  local db=$1 dir=$2 f=$3 name err hash status
  cd "$SRC/$dir" || die "the source lost $dir while it was being applied"
  name="${f%.sql}"
  err=$(mktemp)
  if DB "$db" < "$f" 2>"$err"; then
    status=ok
  elif grep -q 'Duplicate entry' "$err" \
       && to_upsert < "$f" | DB "$db" 2>"$err"; then
    status="ok (upsert)"
  elif already_there "$db" "$f" "$err"; then
    status="ok (already there)"
  else
    # The client echoes the offending statement ahead of the error, so the
    # first lines are the statement and the ERROR line is what has to surface.
    echo "FAILED $name:"
    grep -m3 -E '^ERROR' "$err" || head -5 "$err"
    mkdir -p "$SERVER/logs" && cp -f "$err" "$SERVER/logs/migration-$name.err" 2>/dev/null \
      && echo "full output: server/logs/migration-$name.err"
    rm -f "$err"; exit 1
  fi
  rm -f "$err"
  hash=$(sha1sum "$f" | awk '{print toupper($1)}')
  DB -e "INSERT INTO \`$db\`.migrations (Name, Hash, AppliedAt) VALUES ('$name', '$hash', NOW());"
  echo "$status  $name"
}

if [ "$CHECK" = 1 ]; then
  pending_all | wc -l
  exit 0
fi

# The table both cores record into has to exist before anything is applied, and
# a stream may be the first thing its database ever saw.
for stream in "${ALL_STREAMS[@]}"; do
  IFS='|' read -r dir db glob <<< "$stream"
  ensure_migration_table "$db" >/dev/null 2>&1 \
    || die "could not reach the migrations table in $db; is the database up?"
done

LAST=""
while IFS='|' read -r key db dir f; do
  [[ "$db: applying from $dir" == "$LAST" ]] || {
    LAST="$db: applying from $dir"; echo "$LAST"; }
  apply_file "$db" "$dir" "$f"
  TOTAL=$(( TOTAL + 1 ))
done < <(pending_all)

echo "Done. $TOTAL migration(s) applied."
