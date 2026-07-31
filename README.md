# TurtleWoW 1.18.1 repack, native on Linux

Run the SIGGZ TurtleWoW 1.18.1 server repack as a fully native Linux server:
native MariaDB, native `realmd` and `mangosd` compiled from the same source
the repack is built from (Penqle's tortoise-wow, branch 1181dev). No Wine in
the server stack. The game client still runs under Wine, as usual.

Tested on Arch Linux. The dependency checks name Arch packages; on other
distros install the equivalents (gcc, cmake, ninja, git, curl, libarchive,
mariadb) and it should work the same.

## What you need

Get these from the TurtleWoW preservation community (see the setup guide or
the preservation Discord; links in the guide can expire):

- `TurtleWoW_1.18.zip` - the SIGGZ server repack
- `data.zip` - pre-made map data (dbc, maps, mmaps, vmaps)
- a clean pre-shutdown 1.18.1 client, extracted into `client/` (only needed
  to play, not to convert)

## Usage

```
git clone <this repo> twow && cd twow
# put TurtleWoW_1.18.zip and data.zip here
./setup-native.sh          # convert everything, then start the server
```

The script is idempotent: it skips finished steps, so re-run it freely.

## Configure your server

```
./setup-native.sh interactive
```

A guided, arrow-key setup screen for the settings most people want to change:
realm name, LAN play, game type, XP/drop/honor rates, MOTD, player limit and
starting level. It is configuration only - it never converts, builds, or
starts anything. Run it any time after setup, then restart the server to
apply. Enter keeps the current value everywhere, so it is safe to just look
around.

## Other modes

`./setup-native.sh setup` converts without starting; `./setup-native.sh run
[loglevel]` starts without converting; `./setup-native.sh update` follows
upstream: it pulls the latest source, rebuilds only what changed, backs up
the world database, and applies any new schema migrations (stop the world
server first). `./setup-native.sh help` shows all modes. Day-to-day
operation is documented in `server/README.linux.md`.

First boot: log in with admin / admin and create your own account from the
world console. The realm shows OFFLINE in the realm list on local servers;
that is cosmetic.

## Credits

- SIGGZ (send me a link) for the repack, [Penqle](https://github.com/Penqle/) for the 1181dev source
- [Kes](https://ko-fi.com/scribblesbykes) (NoGuiltGaming) for the Windows setup guide this follows
- The TurtleWoW preservation [Discord](https://discord.gg/kpnCR644kk)

## Donations

If this setup saved an evening of fiddling, a small BTC tip is appreciated:

```
bc1qxsuelwvrs28u43eewj39rpn34g4qtkhpdwwlhe
```

For personal preservation and educational use, private local play only. No
public hosting, no monetization.
