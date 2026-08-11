#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# What decides that a guest needs provisioning again. A dependency added to the
# table after a guest was built has to reach it, which a sampled check missed.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/logs"
export TWOW_VM_DIR="$TMP"
# shellcheck source=twow-vm.sh
. "$KIT/twow-vm.sh"
set +e

# Everything reaching the guest is recorded instead of sent, and the gate's
# answer is whatever a case is testing.
CALLS=(); GATE_RC=0
vm()   { CALLS+=("$1"); [[ "$1" == *"bash -s"* ]] && return 0; return "$GATE_RC"; }
say()  { :; }
note() { :; }
die()  { return 1; }

has() { case "$1" in *"$2"*) echo yes;; *) echo no;; esac; }

# --- what the gate asks -------------------------------------------------------
CALLS=(); GATE_RC=0; provision
expect "the gate puts the packages to dpkg"      "$(has "${CALLS[0]}" 'dpkg -s')"        yes
expect "the list comes from the kit's own table" "$(has "${CALLS[0]}" 'deps --packages')" yes

# --- a satisfied guest is left alone ------------------------------------------
expect "a satisfied gate installs nothing" "${#CALLS[@]}" 1

# --- a guest missing one package is provisioned again -------------------------
# The case this exists for: dpkg reports a package from a newly added row as
# absent, which has to send the run down the install path rather than past it.
CALLS=(); GATE_RC=1; provision
expect "an unsatisfied gate reaches the installer" \
  "$(has "${CALLS[1]:-}" 'bash -s')" yes

exit $RC
