#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# What a cohort size means once the core has it: which keys it settles, where
# the module's configs are placed, and how each is carried forward. The keys
# are the part an install cannot get wrong quietly - the module ships with the
# cohort neither created nor logged in, whatever the count asks for.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"
# shellcheck source=twow.sh
. "$KIT/twow.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP"; SERVER="$TMP/server"
mkdir -p "$SERVER/bin"
BOT_CONF="$SERVER/bin/aiplayerbot.conf"
MODULE_CONF="$SERVER/bin/modules/tortoise_bots.conf"
CHANGES=()

# -- what a cohort size writes into the config --------------------------------
cat > "$BOT_CONF" <<'CONF'
[AiPlayerbotConf]
AiPlayerbot.MinRandomBots = 0
AiPlayerbot.MaxRandomBots = 0
AiPlayerbot.RandomBotAccountPrefix = RNDBOT
CONF
set_bot_count 20
expect "both ends of the range move together" \
  "$(conf_get "$BOT_CONF" AiPlayerbot.MinRandomBots)/$(conf_get "$BOT_CONF" AiPlayerbot.MaxRandomBots)" "20/20"
expect "the account prefix is left where it is" \
  "$(bot_prefix)" RNDBOT

# -- where a dist is looked for -----------------------------------------------
# A build writes the configured copy under modules/ in the build tree, and the
# checkout's template stands in once that tree is cleared; neither is the
# module's own name for the file.
BUILT="$ROOT/build/bots/$(variant_conf_generated aiplayerbot.conf)"
TEMPLATE="$ROOT/src/bots/$(VARIANT_TARGET=bots variant_conf_source aiplayerbot.conf)"
mkdir -p "${BUILT%/*}" "${TEMPLATE%/*}"; : > "$BUILT"; : > "$TEMPLATE"
expect "the configured copy in the build tree comes first" \
  "$(VARIANT_TARGET=bots bot_conf_dist aiplayerbot.conf)" "$BUILT"
rm -f "$BUILT"
expect "the checkout's template stands in without it" \
  "$(VARIANT_TARGET=bots bot_conf_dist aiplayerbot.conf)" "$TEMPLATE"
rm -f "$TEMPLATE"
expect "and a config with neither is named as missing" \
  "$(VARIANT_TARGET=bots bot_conf_dist aiplayerbot.conf || echo none)" none
expect "a config the table leaves out has no dist to look for" \
  "$(VARIANT_TARGET=bots bot_conf_dist ahbot.conf || echo none)" none

# -- the config carried forward -----------------------------------------------
DIST="$TMP/aiplayerbot.conf.dist"
# The core keeps one dist per config, named after it, which is what the kit
# asks for by the name it is placed under.
bot_conf_dist() { printf '%s' "$TMP/$1.dist"; }
cat > "$DIST" <<'CONF'
[AiPlayerbotConf]
AiPlayerbot.MinRandomBots = 0
AiPlayerbot.MaxRandomBots = 0
AiPlayerbot.RandomBotAccountPrefix = RNDBOT
AiPlayerbot.NewSettingUpstreamAdded = 7
# AiPlayerbot.CommentedOut = 3
CONF
expect "a setting the core has added is noticed" \
  "$(bot_conf_missing "$BOT_CONF")" "AiPlayerbot.NewSettingUpstreamAdded = 7"
bot_conf_freshen "$BOT_CONF" > /dev/null
expect "and is taken in at the value the core ships" \
  "$(conf_get "$BOT_CONF" AiPlayerbot.NewSettingUpstreamAdded)" 7
expect "a setting the core keeps commented out is left alone" \
  "$(conf_has "$BOT_CONF" AiPlayerbot.CommentedOut && echo added || echo left)" left
expect "what the file already held keeps its own value" \
  "$(conf_get "$BOT_CONF" AiPlayerbot.MinRandomBots)" 20
expect "nothing is left to carry forward twice" "$(bot_conf_missing "$BOT_CONF")" ""

# A config whose last line was never terminated is what an editor leaves behind,
# and the first setting taken in would otherwise land on the end of it.
printf '[AiPlayerbotConf]\nAiPlayerbot.Enabled = 1' > "$BOT_CONF"
bot_conf_freshen "$BOT_CONF" > /dev/null
expect "a config with no closing newline still reads back" \
  "$(conf_get "$BOT_CONF" AiPlayerbot.Enabled)" 1
expect "and the settings after it are their own lines" \
  "$(conf_get "$BOT_CONF" AiPlayerbot.MinRandomBots)" 0

# A config that is not there is not an error: a stock install has none, and
# every one of these is asked on every run.
rm -f "$BOT_CONF"
expect "no config carries nothing forward" \
  "$(bot_conf_freshen "$BOT_CONF" && echo ok || echo failed)" ok
expect "and lists nothing missing" "$(bot_conf_missing "$BOT_CONF")" ""

# -- what a switch settles ----------------------------------------------------
# The module's own config sits in a directory of its own under mangosd.conf's,
# and the world server stops without it. It is placed as shipped: nothing in it
# follows from the cohort.
mkdir -p "$TMP/modules"
cat > "$TMP/modules/tortoise_bots.conf.dist" <<'CONF'
[TortoiseBotsConf]
TortoiseBots.LogLevel = 1
CONF
rm -rf "$BOT_CONF" "$SERVER/bin/modules"
VARIANT_TARGET=bots ensure_variant_conf 20 > /dev/null
expect "both of the module's configs are placed where it reads them" \
  "$([[ -f "$BOT_CONF" && -f "$MODULE_CONF" ]] && echo both || echo missing)" both
expect "the module's own is placed as shipped" \
  "$(conf_get "$MODULE_CONF" TortoiseBots.LogLevel)" 1
# The shipped file has the module off and the cohort neither created nor
# logged in, so the count alone would ask for bots that never appear. The dist
# above carries none of the three, which is a copy an older kit placed: they
# are written in rather than looked for.
expect "the module is switched on" "$(conf_get "$BOT_CONF" AiPlayerbot.Enabled)" 1
expect "the cohort is created" "$(conf_get "$BOT_CONF" AiPlayerbot.RandomBotAutoCreate)" 1
expect "and logged in" "$(conf_get "$BOT_CONF" AiPlayerbot.RandomBotAutologin)" 1
expect "at the count asked for" "$(bot_count)" 20
# What an older kit placed beside them, and what the core reads unless told
# not to, are settled on the same pass.
: > "$SERVER/bin/ahbot.conf"; printf 'LogLevel = 3\n' > "$SERVER/bin/mangosd.conf"
VARIANT_TARGET=bots ensure_variant_conf 20 > /dev/null
expect "the auction house config an older kit placed is removed" \
  "$([[ -e "$SERVER/bin/ahbot.conf" ]] && echo kept || echo gone)" gone
expect "and the core's own updater is switched off" \
  "$(conf_get "$SERVER/bin/mangosd.conf" Database.AutoUpdate.Enabled)" 0
rm -rf "$SERVER/bin/modules"
VARIANT_TARGET=stock ensure_variant_conf 20 > /dev/null
expect "the stock core places neither" \
  "$([[ -f "$MODULE_CONF" ]] && echo placed || echo none)" none

# -- the checkout a switch replaces -------------------------------------------
# The clone is stood in for, so the source is what an older kit left: a
# checkout from a repository the row no longer names, with its build tree.
git() {
  if [[ "$1" == clone ]]; then mkdir -p "${*: -1}" "${*: -1}/.git"; : > "${*: -1}/CMakeLists.txt"; return 0; fi
  command git "$@"
}
SRC="$ROOT/src/bots"; rm -rf "$ROOT/src" "$ROOT/build"
mkdir -p "$SRC" "$ROOT/build/bots"; : > "$ROOT/build/bots/build.ninja"
command git -C "$SRC" init -q
command git -C "$SRC" remote add origin https://github.com/Shyalya/tortoise-wow.git
: > "$SRC/CMakeLists.txt"; command git -C "$SRC" add -A
command git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm base
printf 'edited\n' > "$SRC/CMakeLists.txt"
expect "a checkout with local edits is refused, not replaced" \
  "$( (VARIANT_TARGET=bots ensure_source) >/dev/null 2>&1 && echo went || echo refused)" refused
expect "and stays where it is" "$([[ -f "$SRC/CMakeLists.txt" ]] && echo kept || echo gone)" kept
command git -C "$SRC" checkout -q -- CMakeLists.txt
expect "one with none is replaced" \
  "$( (VARIANT_TARGET=bots ensure_source) >/dev/null 2>&1 && echo went || echo refused)" went
expect "along with the build tree made from it" \
  "$([[ -e "$ROOT/build/bots/build.ninja" ]] && echo kept || echo gone)" gone
expect "and the module is cloned into the fresh checkout" \
  "$([[ -d "$SRC/modules/TortoiseBots/.git" ]] && echo cloned || echo missing)" cloned
rm -rf "$SRC/modules/TortoiseBots/.git"
expect "a module directory that is not a checkout is named, not cloned over" \
  "$(VARIANT_TARGET=bots ensure_source 2>&1 >/dev/null | grep -c 'not a checkout')" 1
unset -f git

# -- where their levels sit ---------------------------------------------------
# The core comments these keys out in its own config, so setting one means
# adding the line rather than rewriting it. 'spread' is what the core ships.
rm -f "$BOT_CONF"; VARIANT_TARGET=bots ensure_variant_conf 20 > /dev/null
expect "a fresh config runs the levels the core ships" "$(bot_levels)" spread
expect "and says so in a line of its own" \
  "$(conf_get "$BOT_CONF" AiPlayerbot.SyncLevelWithPlayers)" 0
set_bot_levels near
expect "near keeps them to the players online" "$(bot_levels)" near
expect "and names the band it keeps to" \
  "$(conf_get "$BOT_CONF" AiPlayerbot.SyncLevelMaxAbove)" "$BOT_LEVELS_ABOVE"
# Without this the band would be measured against the cohort's own top while
# nobody is online, which is every level at once.
expect "with a reference level for an empty realm" \
  "$(conf_get "$BOT_CONF" AiPlayerbot.SyncLevelNoPlayer)" 1
expect "an answer the config already carries is kept through a setup" \
  "$(VARIANT_TARGET=bots ensure_variant_conf 20 > /dev/null; bot_levels)" near
expect "and a setup told otherwise writes what it was told" \
  "$(VARIANT_TARGET=bots ensure_variant_conf 20 spread > /dev/null; bot_levels)" spread
expect "a level nobody offers is refused" \
  "$(set_bot_levels sideways 2>/dev/null && echo taken || echo refused)" refused
expect "setting the same one twice writes one line" \
  "$(set_bot_levels near; set_bot_levels near; grep -c '^AiPlayerbot.SyncLevelWithPlayers' "$BOT_CONF")" 1

# -- where the core looks for them --------------------------------------------
# A module reads its config from beside the mangosd.conf the core was started
# with, so a bare name would send it to the prefix the build was configured with
# and the settings placed above would never be read.
expect "the world server names its config by full path" \
  "$(world_start_names_conf "$KIT/server/3-world-server.sh" && echo full || echo bare)" full
printf './mangosd -c mangosd.conf\n' > "$TMP/bare.sh"
expect "and a start that names it without its directory is caught" \
  "$(world_start_names_conf "$TMP/bare.sh" && echo full || echo bare)" bare

# -- how long a first boot is given -------------------------------------------
bot_cohort() { printf '%s' "$COHORT"; }
COHORT=0
expect "a stock install waits the usual time" \
  "$(VARIANT_TARGET=stock world_wait)" "$WORLD_WAIT"
expect "a bots install with no cohort waits longer, since it writes one" \
  "$(VARIANT_TARGET=bots world_wait)" "$(( WORLD_WAIT * 5 ))"
COHORT=3
expect "and waits the usual time once the cohort is there" \
  "$(VARIANT_TARGET=bots world_wait)" "$WORLD_WAIT"

exit $RC
