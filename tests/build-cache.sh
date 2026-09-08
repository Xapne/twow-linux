#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# A build tree left by another cmake is dropped before it can fail the compile,
# and a healthy one is left where it is.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# shellcheck source=twow.sh
. "$KIT/twow.sh"
say() { :; }

# The two lines the guard reads, as cmake writes them.
tree() {  # $1 dir, $2 cmake version that wrote it, $3 compiler id
  mkdir -p "$1/CMakeFiles/$2"
  printf 'CMAKE_CACHE_MAJOR_VERSION:INTERNAL=%s\nCMAKE_CACHE_MINOR_VERSION:INTERNAL=%s\nCMAKE_CACHE_PATCH_VERSION:INTERNAL=%s\n' \
    "${2%%.*}" "$(cut -d. -f2 <<< "$2")" "${2##*.}" > "$1/CMakeCache.txt"
  printf 'set(CMAKE_CXX_COMPILER_ID "%s")\n' "$3" > "$1/CMakeFiles/$2/CMakeCXXCompiler.cmake"
}

state() { [[ -d "$1" ]] && printf kept || printf wiped; }

have=$(cmake --version 2>/dev/null | sed -n '1s/.*version \([0-9][0-9.]*\).*/\1/p')
if [[ -z "$have" ]]; then
  printf '    SKIP no cmake here to compare against\n'
  exit 0
fi

tree "$TMP/current" "$have" GNU
drop_amnesiac_build "$TMP/current"
expect "a tree from this cmake is kept" "$(state "$TMP/current")" kept

tree "$TMP/older" "0.0.1" GNU
drop_amnesiac_build "$TMP/older"
expect "a tree from another cmake is dropped" "$(state "$TMP/older")" wiped

tree "$TMP/blank" "$have" ""
drop_amnesiac_build "$TMP/blank"
expect "a tree with no compiler identity is dropped" "$(state "$TMP/blank")" wiped

mkdir -p "$TMP/bare"
drop_amnesiac_build "$TMP/bare"
expect "a tree with nothing in it yet is kept" "$(state "$TMP/bare")" kept

drop_amnesiac_build "$TMP/absent"
expect "no tree at all is not an error" "$?" 0

exit $RC
