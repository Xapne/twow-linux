#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# Which core a VM converts to. The conversion inside a guest runs with no
# terminal, so the question setup would ask is answered by the environment, and
# what reaches the guest is what decides it.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/logs"
export TWOW_VM_DIR="$TMP"
# shellcheck source=twow-vm.sh
. "$KIT/twow-vm.sh"
set +e

OUT="$TMP/cmd"
# The conversion is stopped at the command that starts it: that string is the
# whole answer, and the progress loop after it reaches a guest there is none of.
converted_with() {  # $1 a core, or nothing for an environment that names none
  : > "$OUT"
  (
    vm() { case "$1" in *"twow.sh setup"*) printf '%s\n' "$1" > "$OUT"; exit 0;; esac; return 1; }
    say() { :; }; warn() { :; }
    die() { printf 'refused\n' > "$OUT"; exit 3; }
    if [[ -n "${1:-}" ]]; then export TWOW_VARIANT="$1"; else unset TWOW_VARIANT; fi
    convert >/dev/null 2>&1
  )
  cat "$OUT"
}

has() { case "$1" in *"$2"*) echo yes;; *) echo no;; esac; }

expect "an environment naming no core converts as it always did" \
  "$(has "$(converted_with)" 'TWOW_VARIANT')" no
expect "and still starts the conversion" \
  "$(has "$(converted_with)" './twow.sh setup')" yes
expect "a named core reaches the guest's own setup" \
  "$(has "$(converted_with bots)" 'TWOW_VARIANT=bots ./twow.sh setup')" yes
expect "a core this kit has never heard of is refused" \
  "$(converted_with nosuchcore)" refused

exit $RC
