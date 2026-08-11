#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# What doctor reports, with the database, the configs and the firewall replaced.
# Each case sets a fault and asserts the tally, so a check that stops noticing
# fails here rather than in somebody's install.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"
# shellcheck source=twow.sh
. "$KIT/twow.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/server/bin"
: > "$TMP/server/bin/realmd.conf"
: > "$TMP/server/bin/mangosd.conf"
ROOT="$TMP" SERVER="$TMP/server"

ADDR="" RBIND="" MBIND="" HTTPAPI="" STOCK=0 ORPHC=0 ORPHP=0 SELFPASS=0
realm_address() { printf '%s\n' "$ADDR"; }
conf_get() {
  case "$1:$2" in
    *realmd.conf:BindIP)  printf '%s\n' "$RBIND";;
    *mangosd.conf:BindIP) printf '%s\n' "$MBIND";;
    *HttpApi.Enable)      printf '%s\n' "$HTTPAPI";;
    *)                    printf '\n';;
  esac
}
conf_has()      { [[ -n "$HTTPAPI" ]]; }
fw_backend()    { printf '\n'; }
realm_port()    { echo 3724; }
world_port()    { echo 8091; }
dr_db_ready()   { return 0; }
dr_count()      { printf '%s\n' "$SELFPASS"; }
count_stock_accounts()    { printf '%s\n' "$STOCK"; }
count_orphan_characters() { printf '%s\n' "$ORPHC"; }
count_orphan_pets()       { printf '%s\n' "$ORPHP"; }

# Runs one check with the tallies zeroed, and reports what it counted.
tally() { DOC_BAD=0 DOC_NOTE=0; "$1" >/dev/null 2>&1; printf '%s/%s\n' "$DOC_BAD" "$DOC_NOTE"; }

# reach - the fault this session actually hit
ADDR=10.0.0.5 RBIND=127.0.0.1 MBIND=127.0.0.1
expect "a realm advertising what it does not listen on is bad" "$(tally doctor_reach)" 1/0

ADDR=10.0.0.5 RBIND=0.0.0.0 MBIND=0.0.0.0
expect "a realm bound wide is fine" "$(tally doctor_reach)" 0/0

ADDR=127.0.0.1 RBIND=127.0.0.1 MBIND=127.0.0.1
expect "a loopback realm bound to the loopback is fine" "$(tally doctor_reach)" 0/0

ADDR=127.0.0.1 RBIND=0.0.0.0 MBIND=0.0.0.0
expect "a port forward advertising the loopback is fine" "$(tally doctor_reach)" 0/0

ADDR=10.0.0.5 RBIND=0.0.0.0 MBIND=127.0.0.1
expect "the two servers binding differently is bad" "$(tally doctor_reach)" 1/0

# what the dump carries
STOCK=0 ORPHC=0 ORPHP=0 SELFPASS=0
expect "a swept database is clean" "$(tally doctor_dump)" 0/0

STOCK=2 ORPHC=0 ORPHP=0 SELFPASS=0
expect "the repack's own accounts are bad" "$(tally doctor_dump)" 1/0

STOCK=0 ORPHC=6 ORPHP=2 SELFPASS=0
expect "orphaned characters and pets are two findings" "$(tally doctor_dump)" 2/0

STOCK=0 ORPHC=0 ORPHP=0 SELFPASS=1
expect "a game master named as its own password is a note" "$(tally doctor_dump)" 0/1

# configuration
HTTPAPI=0
expect "the HTTP API turned off is fine" "$(tally doctor_config)" 0/0

HTTPAPI=1
expect "the HTTP API left on is a note" "$(tally doctor_config)" 0/1

HTTPAPI=""
expect "no HttpApi.Enable line at all is a note" "$(tally doctor_config)" 0/1

# the exit code is what makes it scriptable
STOCK=2 ADDR=127.0.0.1 RBIND=127.0.0.1 MBIND=127.0.0.1
doctor_install() { :; }; doctor_database() { :; }
if doctor_all >/dev/null 2>&1; then code=0; else code=1; fi
expect "doctor_all exits non-zero when something is wrong" "$code" 1

STOCK=0
if doctor_all >/dev/null 2>&1; then code=0; else code=1; fi
expect "doctor_all exits zero when nothing is wrong" "$code" 0

exit $RC
