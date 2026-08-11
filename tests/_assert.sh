# shellcheck shell=bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared by the tests: where the kit is, and one assertion. Files here starting
# with an underscore are helpers, which check.sh leaves out of the test run.
# KIT and RC are read by the tests that source this.
# shellcheck disable=SC2034
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RC=0

expect() {  # $1 label, $2 got, $3 want
  if [[ "$2" == "$3" ]]; then
    printf '    PASS %s\n' "$1"
  else
    printf '    FAIL %s: got %q, want %q\n' "$1" "$2" "$3"
    # shellcheck disable=SC2034
    RC=1
  fi
}
