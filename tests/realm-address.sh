#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# offer_realm_address, with the writers and the prompts replaced, so only the
# control flow is under test. No database and no terminal are needed.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"
# shellcheck source=twow.sh
. "$KIT/twow.sh"

WROTE="" FW="" SELECT=0 TEXT=""
set_realm_address() { WROTE="$1"; return 0; }
fw_offer_ports()    { FW="$1 $2"; }
realm_port()        { echo 3724; }
world_port()        { echo 8091; }
ui_select()         { ANSWER=$SELECT; PROMPTED_DEFAULT=$2; }
ui_text()           { ANSWER=$TEXT;   PREFILLED=$2; }
ui_warn()           { :; }
PROMPTED_DEFAULT="" PREFILLED=""

WROTE="" FW="" SELECT=0
offer_realm_address 127.0.0.1
expect "loopback answer writes the loopback" "$WROTE" 127.0.0.1
expect "loopback answer leaves the firewall alone" "$FW" ""

WROTE="" FW="" SELECT=1 TEXT=10.0.0.5
offer_realm_address 127.0.0.1
expect "LAN answer writes the address given" "$WROTE" 10.0.0.5
expect "LAN answer offers the realm and world ports" "$FW" "3724 8091"

WROTE="" FW="" SELECT=1 TEXT=10.0.0.5
offer_realm_address 10.0.0.5
expect "an address in place opens the list on LAN" "$PROMPTED_DEFAULT" 1
expect "an address in place prefills the field" "$PREFILLED" 10.0.0.5

WROTE="" FW="" SELECT=1 TEXT=10.0.0.5
set_realm_address() { return 1; }
offer_realm_address 127.0.0.1
expect "a refused write offers no ports" "$FW" ""

exit $RC
