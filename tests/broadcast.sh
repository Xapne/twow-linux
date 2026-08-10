#!/usr/bin/env bash
# Whether the repack's broadcast is put to the reader, and what each answer
# leaves behind. The rows belong to the dump, so the question follows them.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"
# shellcheck source=twow.sh
. "$KIT/twow.sh"

TMP=$(mktemp -d)
# Invoked by the trap below.
# shellcheck disable=SC2329
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/bin"
SERVER="$TMP"
printf 'AutoBroadcast.Timer = 2400000\n' > "$TMP/bin/mangosd.conf"

ASKED=no CLEARED=no ROWS=0 PICK=0 CLEAR_RC=0
broadcast_text()   { echo "a line the repack ships"; }
broadcast_count()  { echo "$ROWS"; }
clear_broadcasts() { CLEARED=yes; return "$CLEAR_RC"; }
ui_intro() { :; }
ui_note()  { :; }
ui_outro() { :; }
ui_warn()  { :; }
ui_select() { ASKED=yes; ANSWER=$PICK; }

asks() {  # $1 label, $2 rows, $3 pick, $4 expected asked, $5 expected cleared
  ASKED=no CLEARED=no ROWS=$2 PICK=$3
  offer_broadcast
  expect "$1, asked" "$ASKED" "$4"
  expect "$1, cleared" "$CLEARED" "$5"
}

asks "an install carrying no broadcast stays quiet" 0 1 no  no
asks "the repack's row is put to the reader"        1 1 yes yes
asks "keeping it leaves the rows alone"             1 0 yes no

# A refused delete keeps the rows, and setup goes on to the account question.
CLEAR_RC=1 ROWS=1 PICK=1 CLEARED=no
offer_broadcast
expect "a refused delete still returns success" "$?" 0

# The interval is read from the config, so a repack shipping another value is
# described in its own terms.
expect "the shipped interval reads as 40 minutes" "$(broadcast_minutes)" 40

printf 'Motd = "hello"\n' > "$TMP/bin/mangosd.conf"
expect "an absent key falls back to the compiled-in minute" "$(broadcast_minutes)" 1

printf 'AutoBroadcast.Timer = wat\n' > "$TMP/bin/mangosd.conf"
expect "a value that is no number falls back too" "$(broadcast_minutes)" 1

exit $RC
