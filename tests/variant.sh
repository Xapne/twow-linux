#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# Which core an install runs, and what the tables in lib/variant.sh say follows
# from it. The rules tested here are the ones a switch cannot get wrong twice:
# what is active, where its source and build live, and whether the binaries in
# server/bin are what the record claims.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP/kit"; SERVER="$ROOT/server"
mkdir -p "$SERVER/bin"
# shellcheck source=lib/variant.sh
. "$KIT/lib/variant.sh"

# -- the tables ---------------------------------------------------------------
malformed=0
for row in "${VARIANTS[@]}"; do
  variant_parse "$row"
  [[ -n "$v_label" && -n "$v_repo" && -n "$v_branch" && -n "$v_summary" ]] \
    || malformed=$(( malformed + 1 ))
done
expect "every variant declares a label, a repository, a branch and a summary" "$malformed" 0
expect "both cores are declared" "$(variant_labels | tr '\n' ' ')" "stock bots "
expect "the stock core takes no build options" "$(variant_field stock cmake)" ""
expect "the bots core is built with its option" "$(variant_field bots cmake)" "-DBUILD_PLAYERBOTS=ON"
expect "an unknown label has no row" "$(variant_field nope repo 2>/dev/null || echo none)" none
# The configs a core brings are placed from this column alone, so a file the
# core reads and the table leaves out is one nobody ever writes.
expect "the stock core brings no config of its own" "$(variant_field stock conf)" ""
expect "the bots core brings the players' and the auction house's" \
  "$(variant_field bots conf)" "aiplayerbot.conf ahbot.conf"

malformed=0
for row in "${VARIANT_STREAMS[@]}"; do
  IFS='|' read -r s_variant s_dir s_db s_glob <<<"$row"
  variant_known "$s_variant" || malformed=$(( malformed + 1 ))
  [[ -n "$s_dir" && -n "$s_db" && -n "$s_glob" ]] || malformed=$(( malformed + 1 ))
done
expect "every seeded stream names a known core, a directory, a database and a glob" "$malformed" 0

# -- what is active -----------------------------------------------------------
expect "an install with nothing written down runs the stock core" "$(variant_active)" stock
expect "the stock source path"  "$(variant_src)"   "$ROOT/src/stock"
expect "the stock build path"   "$(variant_build)" "$ROOT/build/stock"

variant_save bots
expect "a saved core is what the install runs" "$(variant_active)" bots
expect "and its trees move with it" "$(variant_src)" "$ROOT/src/bots"
expect "the environment overrides the record" "$(TWOW_VARIANT=stock variant_active)" stock
expect "a label no table knows falls back to stock" "$(TWOW_VARIANT=eggs variant_active)" stock

expect "the bots core seeds streams of its own" "$(variant_streams | wc -l)" 4
expect "the stock core seeds none" "$(TWOW_VARIANT=stock variant_streams | wc -l)" 0
expect "a seeded stream is applied against the world or the characters" \
  "$(variant_streams | cut -d'|' -f2 | sort -u | grep -cv '^turtle_\(world\|char\)$')" 0

# -- dependencies -------------------------------------------------------------
expect "the bots core claims Boost"        "$(variant_needs_dep Boost && echo yes || echo no)" yes
expect "the stock core does not"           "$(TWOW_VARIANT=stock variant_needs_dep Boost && echo yes || echo no)" no
expect "a dependency neither claims is nobody's" "$(variant_claiming_dep cmake)" ""
expect "and Boost is named as the bots core's" "$(variant_claiming_dep Boost)" bots

# -- what the binaries say ----------------------------------------------------
expect "no binary at all answers nothing" "$(variant_binary_label || echo none)" none
printf 'a stock build with no bot strings in it\n' > "$SERVER/bin/mangosd"
chmod +x "$SERVER/bin/mangosd"
expect "a build without the bot subsystem reads as stock" "$(variant_binary_label)" stock
printf 'this build reads AiPlayerbot.Enabled from its config\n' > "$SERVER/bin/mangosd"
chmod +x "$SERVER/bin/mangosd"
expect "a build carrying the bot subsystem reads as bots" "$(variant_binary_label)" bots
# The record and the binaries disagreeing is a switch that stopped halfway, and
# is the one thing doctor cannot take on trust.
expect "the record and the binaries can disagree, and it shows" \
  "$([[ "$(variant_active)" == "$(variant_binary_label)" ]] && echo agree || echo differ)" agree
printf 'a stock build\n' > "$SERVER/bin/mangosd"; chmod +x "$SERVER/bin/mangosd"
expect "a half-finished switch shows as a disagreement" \
  "$([[ "$(variant_active)" == "$(variant_binary_label)" ]] && echo agree || echo differ)" differ

# -- the fixes the kit carries ------------------------------------------------
# A patch is applied to a checkout that has not got it, is left alone on one
# that has, and is named rather than forced on one it no longer fits.
mkdir -p "$ROOT/src/bots" "$ROOT/patches/bots"
git -C "$ROOT/src/bots" init -q
printf 'find_package(Boost COMPONENTS thread system)\n' > "$ROOT/src/bots/CMakeLists.txt"
git -C "$ROOT/src/bots" add -A
git -C "$ROOT/src/bots" -c user.email=t@t -c user.name=t commit -qm base
printf 'find_package(Boost COMPONENTS thread)\n' > "$ROOT/src/bots/CMakeLists.txt"
git -C "$ROOT/src/bots" diff > "$ROOT/patches/bots/0001-drop-system.patch"
git -C "$ROOT/src/bots" checkout -q -- CMakeLists.txt

expect "a fix is carried per core" "$(variant_patches | wc -l)" 1
expect "the stock core carries none" "$(TWOW_VARIANT=stock variant_patches | wc -l)" 0
variant_apply_patches >/dev/null
expect "a fix the checkout lacks is applied" \
  "$(grep -c system "$ROOT/src/bots/CMakeLists.txt")" 0
expect "applying again is not an error" \
  "$(variant_apply_patches >/dev/null && echo ok || echo failed)" ok
variant_unapply_patches
expect "and it comes back out for a pull" \
  "$(grep -c system "$ROOT/src/bots/CMakeLists.txt")" 1

printf 'upstream rewrote this file entirely\n' > "$ROOT/src/bots/CMakeLists.txt"
expect "a fix that fits neither way is named, not forced" \
  "$(variant_apply_patches | wc -l)" 1
expect "and says so through its status" \
  "$(variant_apply_patches >/dev/null || echo stale)" stale
expect "taking a fix out that is not in there changes nothing" \
  "$(variant_unapply_patches; cat "$ROOT/src/bots/CMakeLists.txt")" \
  "upstream rewrote this file entirely"

# -- the old layout -----------------------------------------------------------
rm -rf "$ROOT/src" "$ROOT/build"
mkdir -p "$ROOT/src" "$ROOT/build"
: > "$ROOT/src/CMakeLists.txt"
: > "$ROOT/build/build.ninja"
variant_migrate_legacy
expect "a checkout from the old layout moves under its core's name" \
  "$([[ -f "$ROOT/src/stock/CMakeLists.txt" ]] && echo moved || echo no)" moved
# cmake writes absolute paths into its cache and refuses a build tree that moved,
# so the tree is dropped rather than carried over. server/bin is untouched, which
# is what keeps a converted install running until it next rebuilds.
expect "the build tree it cannot carry is dropped" \
  "$([[ -e "$ROOT/build/build.ninja" ]] && echo kept || echo gone)" gone
variant_migrate_legacy
expect "migrating an install that has already moved does nothing" \
  "$([[ -f "$ROOT/src/stock/CMakeLists.txt" ]] && echo intact || echo lost)" intact

exit $RC
