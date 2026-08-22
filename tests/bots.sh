#!/usr/bin/env bash
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
# What a cohort size means once the core has it: how many accounts and guilds
# are created for it, and how the config it lives in is carried forward. The
# counts are the part an install cannot get wrong quietly - the core writes nine
# characters per account it is told to create, whatever the cohort asks for.
# shellcheck source=tests/_assert.sh
. "$(dirname "${BASH_SOURCE[0]}")/_assert.sh"
# shellcheck source=twow.sh
. "$KIT/twow.sh"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
ROOT="$TMP"; SERVER="$TMP/server"
mkdir -p "$SERVER/bin"
BOT_CONF="$SERVER/bin/aiplayerbot.conf"
AHBOT_CONF="$SERVER/bin/ahbot.conf"
CHANGES=()

# -- the counts a cohort implies ----------------------------------------------
expect "no bots need no accounts"                "$(bot_accounts_for 0)"    0
expect "a cohort under one account's worth takes one" "$(bot_accounts_for 1)" 1
expect "nine bots fit in one account"            "$(bot_accounts_for 9)"    1
expect "ten need a second"                       "$(bot_accounts_for 10)"   2
expect "the default cohort takes three"          "$(bot_accounts_for "$VARIANT_BOTS_DEFAULT")" 3
expect "a thousand take a hundred and twelve"    "$(bot_accounts_for 1000)" 112
# The core founds guilds from the same pool, so a small realm gets few of them
# and a large one stops at what the core ships.
expect "a small realm gets a guild per account"  "$(bot_guilds_for 20)"     3
expect "a large one stops at the core's twenty"  "$(bot_guilds_for 1000)"   20
expect "no bots found no guilds"                 "$(bot_guilds_for 0)"      0

# -- what a cohort size writes into the config --------------------------------
cat > "$BOT_CONF" <<'CONF'
[AiPlayerbotConf]
AiPlayerbot.Enabled = 1
AiPlayerbot.MinRandomBots = 1000
AiPlayerbot.MaxRandomBots = 1000
AiPlayerbot.RandomBotAccountCount = 500
AiPlayerbot.RandomBotGuildCount = 20
AiPlayerbot.RandomBotAccountPrefix = RNDBOT
CONF
set_bot_count 20
expect "both ends of the range move together" \
  "$(conf_get "$BOT_CONF" AiPlayerbot.MinRandomBots)/$(conf_get "$BOT_CONF" AiPlayerbot.MaxRandomBots)" "20/20"
# The shipped five hundred accounts are four and a half thousand characters,
# whatever the cohort is set to, which is the number this test exists for.
expect "the accounts follow the cohort" \
  "$(conf_get "$BOT_CONF" AiPlayerbot.RandomBotAccountCount)" 3
expect "and so do the guilds" \
  "$(conf_get "$BOT_CONF" AiPlayerbot.RandomBotGuildCount)" 3
expect "the account prefix is left where it is" \
  "$(bot_prefix)" RNDBOT

# -- the config carried forward -----------------------------------------------
DIST="$TMP/aiplayerbot.conf.dist"
# The core keeps one dist per config, named after it, which is what the kit
# asks for by name.
bot_conf_dist() { printf '%s' "$TMP/$1.dist"; }
cat > "$DIST" <<'CONF'
[AiPlayerbotConf]
AiPlayerbot.Enabled = 1
AiPlayerbot.MinRandomBots = 1000
AiPlayerbot.MaxRandomBots = 1000
AiPlayerbot.RandomBotAccountCount = 500
AiPlayerbot.RandomBotGuildCount = 20
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
  "$(conf_get "$BOT_CONF" AiPlayerbot.MinRandomBots)" 1000

# A config that is not there is not an error: a stock install has none, and
# every one of these is asked on every run.
rm -f "$BOT_CONF"
expect "no config carries nothing forward" \
  "$(bot_conf_freshen "$BOT_CONF" && echo ok || echo failed)" ok
expect "and lists nothing missing" "$(bot_conf_missing "$BOT_CONF")" ""

# -- the auction house ---------------------------------------------------------
# The bots' own auction house is the same module and the same lifetime: it is
# placed with them and trades as their characters, so it is on only while there
# are bots to trade.
cat > "$TMP/ahbot.conf.dist" <<'CONF'
[AhbotConf]
AuctionHouseBot.Seller.Enabled = 0
AhBot.Enabled = 0
AhBot.GUID = 0
CONF
rm -f "$BOT_CONF" "$AHBOT_CONF"
TWOW_VARIANT=bots ensure_variant_conf 20 > /dev/null
expect "both of the core's configs are placed beside mangosd.conf" \
  "$([[ -f "$BOT_CONF" && -f "$AHBOT_CONF" ]] && echo both || echo missing)" both
expect "the auction house is on where there are bots to trade" \
  "$(conf_get "$AHBOT_CONF" AhBot.Enabled)" 1
# The bidders are the cohort's characters, so the fallback guid stays as the
# core ships it.
expect "and it is left pointing at no character of its own" \
  "$(conf_get "$AHBOT_CONF" AhBot.GUID)" 0
TWOW_VARIANT=bots ensure_variant_conf 0 > /dev/null
expect "a realm that asks for no bots leaves it quiet" \
  "$(conf_get "$AHBOT_CONF" AhBot.Enabled)" 0
expect "and the repack's own auction bot stays where the core put it" \
  "$(conf_get "$AHBOT_CONF" AuctionHouseBot.Seller.Enabled)" 0
rm -f "$AHBOT_CONF"
TWOW_VARIANT=stock ensure_variant_conf 20 > /dev/null
expect "the stock core places neither" \
  "$([[ -f "$AHBOT_CONF" ]] && echo placed || echo none)" none

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
  "$(TWOW_VARIANT=stock world_wait)" "$WORLD_WAIT"
expect "a bots install with no cohort waits longer, since it writes one" \
  "$(TWOW_VARIANT=bots world_wait)" "$(( WORLD_WAIT * 5 ))"
COHORT=3
expect "and waits the usual time once the cohort is there" \
  "$(TWOW_VARIANT=bots world_wait)" "$WORLD_WAIT"

exit $RC
