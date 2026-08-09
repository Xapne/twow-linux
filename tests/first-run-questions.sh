#!/usr/bin/env bash
# Which states make first_run_questions ask how far the realm reaches. The
# loopback the repack ships is the one that asks; a wider bind under the same
# address is twow-vm.sh's port forward and is left alone.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"
# shellcheck source=twow.sh
. "$KIT/twow.sh"

ASKED="" ADDR="" BIND=""
offer_realm_name()    { :; }
has_own_gm()          { return 0; }
offer_realm_address() { ASKED=yes; }
realm_address()       { echo "$ADDR"; }
conf_get()            { echo "$BIND"; }

asks() {  # $1 label, $2 address, $3 bind, $4 expected
  ASKED=no ADDR=$2 BIND=$3
  first_run_questions
  expect "$1" "$ASKED" "$4"
}

asks "a fresh install asks"                     127.0.0.1   127.0.0.1 yes
asks "a VM behind a port forward stays quiet"    127.0.0.1   0.0.0.0   no
asks "a VM on the host's address stays quiet"    10.0.0.5    0.0.0.0   no
asks "a realm already moved stays quiet"         10.0.0.5    127.0.0.1 no

exit $RC
