# TurtleWoW 1.18.1 repack, native on Linux

Run the SIGGZ TurtleWoW 1.18.1 server repack as a fully native Linux server:
native MariaDB, native `realmd` and `mangosd` compiled from the same source
the repack is built from (Penqle's tortoise-wow, branch 1181dev). No Wine in
the server stack. The game client still runs under Wine, as usual.

Works on any Linux distro: the dependency check names the right packages
for Debian/Ubuntu, Fedora, openSUSE and Arch, and finds the MariaDB daemon
wherever your distro keeps it. Tested on Arch and Debian 13.

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

## Don't want to touch your OS? Build a machine instead

`setup-vm.sh` runs the whole thing inside a fresh headless Debian VM and
works from any Linux distro. It checks your host tools (and asks before
installing anything), downloads Debian's official cloud image, boots it
with the game ports forwarded, installs every guest dependency, pushes
your two zips in, runs the conversion with a live progress bar, offers to
create your GM account, and hands your terminal over as the world console.

```
./setup-vm.sh          # zero to world console; asks only what it must
```

### Requirements

x86_64 with KVM (virtualization on in BIOS, your user in the `kvm` group),
8 GB RAM, 15 GB free disk, and ports 2222/3724/8091 free. First run takes
15-45 minutes depending on cores; after that it starts in seconds. The
script checks all of it up front, and warns but keeps going if RAM is tight.

### Changing the VM's hardware

Environment variables, no editing:

```
TWOW_VM_CPUS=4 TWOW_VM_MEM=8G ./setup-vm.sh
TWOW_VM_DISK=60G ./setup-vm.sh                   # only on first run
TWOW_VM_DIR=/mnt/games/twow-vm ./setup-vm.sh     # another drive
TWOW_SSH_PORT=2299 ./setup-vm.sh
```

By default the VM gets half your RAM (4-12 GB) and up to 8 cores. Cores
matter for the compile, nothing else. Disk size is fixed at creation:
`destroy` and run again, or `qemu-img resize` and grow it in the guest.

Day to day: `console` reattaches the world console, `tune` opens the
interactive config inside the VM, `ssh` gives a shell, `status` and
`destroy` do what they say. The realm advertises your LAN address when
you have one, so clients on this host and on the local network both work
(if a firewall runs on the host, open tcp 3724 and 8091 for LAN play).
SSH into the VM on port 2222 (turtle / turtle). The zips can sit in
`~/twow-vm`, the current directory, or `~/Downloads` - it finds them.

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

If this setup saved an evening of fiddling, a small BTC tip is welcome:

```
bc1qxsuelwvrs28u43eewj39rpn34g4qtkhpdwwlhe
```

Never required, always appreciated.

For personal preservation and educational use, private local play only. No
public hosting, no monetization.
