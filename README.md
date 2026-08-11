# TurtleWoW 1.18.1 repack, native on Linux

[![check](https://github.com/Xapne/twow-linux/actions/workflows/check.yml/badge.svg)](https://github.com/Xapne/twow-linux/actions/workflows/check.yml)

Run the SIGGZ TurtleWoW 1.18.1 server repack as a fully native Linux server:
native MariaDB, native `realmd` and `mangosd` compiled from the same source
the repack is built from (Penqle's tortoise-wow, branch 1181dev). No Wine in
the server stack. The game client still runs under Wine, as usual.

Works on any Linux distro: the dependency check names the right packages
for Debian/Ubuntu, Fedora, openSUSE and Arch, and finds the MariaDB daemon
wherever your distro keeps it. Tested on Arch, Debian 13, and Debian 12 in a
Proxmox LXC container, where it runs as root beside the packaged MariaDB and
sizes the compile to what the container is given.

The build takes about a gigabyte of memory per parallel job, and follows a
container's limits on its own. `TWOW_BUILD_JOBS=4 ./twow.sh` sets the count by
hand, which suits a machine whose memory is tighter than its core count
suggests.

A Debian or Ubuntu box starts its packaged MariaDB on 3306 as soon as it is
installed. This server notices, takes the next free port for its own database,
and writes the port it settled on to `server/db.env`. Free 3306 up beforehand
if you would rather the game have it.

## What you need

Get these from the TurtleWoW preservation community (see the setup guide or
the preservation Discord; links in the guide can expire):

- `TurtleWoW_1.18.zip` - the SIGGZ server repack
- `data.zip` - pre-made map data (dbc, maps, mmaps, vmaps)
- a clean pre-shutdown 1.18.1 client, extracted into `client/` (only needed
  to play, not to convert)

### What this release was tested against

Other builds are likely to work; these are the ones a conversion was run on
end to end.

| Piece | Version |
|---|---|
| Server repack | `TurtleWoW_1.18.zip`, 198,874,545 bytes |
| Map data | `data.zip`, 1,246,273,520 bytes |
| Client | `1.18.1-7272-Hotfix-2026-04-12` |
| Core source | Penqle/tortoise-wow, branch `1181dev`, at `b6b0e3d` |

`./twow.sh doctor` checks an install against what this conversion knows, which
is the first thing to run when a newer repack appears.

## Usage

```
git clone <this repo> twow && cd twow
# put TurtleWoW_1.18.zip and data.zip here
./twow.sh          # convert everything, then start the server
```

The script is idempotent: it skips finished steps, so re-run it freely.

## Dependencies

```
./twow.sh deps
```

Shows what this system needs, what it already has, and the one command that
installs the rest, in your distro's package names. Every mode runs the same
check before it starts, and says everything at once - including what only the
database seed will want later, an hour into the job.

The table it reads lives in `twow.sh`, and that is where package names
belong. `twow-vm.sh` asks for the list with `deps --packages` when it
provisions its guest, so both paths install from the same place: add a
dependency once and every install path picks it up.

## Repo layout

- `twow.sh` - the converter and the server CLI; owns the dependency table
- `twow-vm.sh` - the VM deployer, a wrapper around the above
- `lib/ui.sh` - the terminal prompts and palette both scripts draw with
- `lib/kit.sh` - logging, the database handle and the port, process and config
  checks every script here shares
- `server/` - the converted repack and its day-to-day scripts
- `check.sh` - shell syntax, shellcheck and the tests in `tests/`, run in one
  go; `.github/workflows/check.yml` runs the same script on push
- `tests/` - assertions over the kit's own functions, no database or terminal
- `docker/` - the same conversion in a container, for macOS and Windows hosts
- `setup-native.sh`, `setup-vm.sh` - the former names, standing in until the
  installs carrying them have moved on

## Don't want to touch your OS? Build a machine instead

`twow-vm.sh` runs the whole thing inside a fresh headless Debian VM and
works from any Linux distro. It checks your host tools (and asks before
installing anything), downloads Debian's official cloud image, boots it
with the game ports forwarded, installs every guest dependency, pushes
your two zips in, runs the conversion with a live progress bar, offers to
create your GM account, and hands your terminal over as the world console.

```
./twow-vm.sh          # zero to world console; asks only what it must
```

### Requirements

x86_64 with KVM (virtualization on in BIOS, your user in the `kvm` group),
8 GB RAM, 15 GB free disk, and ports 2222/3724/8091 free. First run takes
15-45 minutes depending on cores; after that it starts in seconds. The
script checks all of it up front, and warns but keeps going if RAM is tight.

### Changing the VM's hardware

Environment variables, no editing:

```
TWOW_VM_CPUS=4 TWOW_VM_MEM=8G ./twow-vm.sh
TWOW_VM_DISK=60G ./twow-vm.sh                   # only on first run
TWOW_VM_DIR=/mnt/games/twow-vm ./twow-vm.sh     # another drive
TWOW_SSH_PORT=2299 ./twow-vm.sh
```

By default the VM gets half your RAM (4-12 GB) and up to 8 cores. Cores
matter for the compile, nothing else. Disk size is fixed at creation:
`destroy` and run again, or `qemu-img resize` and grow it in the guest.

### Managing the VMs it builds

```
./twow-vm.sh vms          # every VM built here, running or not
./twow-vm.sh destroy      # pick one and remove it
```

Each work dir gets one VM, named after that directory and marked with a
`vm.id` file. `vms` lists those, and separately counts the other VMs on the
host (libvirt domains, other qemu processes), which stay untouched.

`destroy` only ever offers VMs carrying that marker, and asks twice: which one,
then how much of it goes. It is fully destructive, and says so: the disk is
deleted and the server, database and characters inside it go with it. The
second question chooses between keeping the Debian image and your zips for a
quick rebuild, or clearing the work dir out entirely.

Building a new VM while older ones are still around says so first, and offers
to remove one on the spot.

Day to day: `console` reattaches the world console, `tune` opens the
interactive config inside the VM, `ssh` gives a shell, and `status` reports
what is running. The realm advertises your LAN address when
you have one, so clients on this host and on the local network both work
(if a firewall runs on the host, open tcp 3724 and 8091 for LAN play).
SSH into the VM on port 2222 (turtle / turtle). The zips can sit in
`~/twow-vm`, the current directory, or `~/Downloads` - it finds them.

## What the repack's dump carries

`turtle_logon` ships ADMIN and TEST at administrator level, each holding its own
name as its password. A realm reachable on the LAN hands full administrator
rights to anyone who finds port 3724, so setup removes both and starts the
account counter again at 1.

`turtle_char` is a slice of a live server. Six level 60s come with account ids
that stayed behind, and two hunter pets come with owners that were deleted
before the export. Character guids are handed out from `MAX(guid)+1`, which
lands on one of those owners, so the first character created adopts a stray pet:
a Mistvale Gorilla follows a mage or a warrior around from the moment it logs
in.

Setup clears all of it, so the realm starts empty and the first account and
character are yours. An account whose password has been changed is somebody's
own and stays, as does any character that has an account.

`./twow.sh doctor` checks for each of these, so a later repack that
carries something similar is caught before anyone plays on it.

## Configure your server

```
./twow.sh interactive
```

A guided, arrow-key setup screen for the settings most people want to change:
realm name, LAN play, game type, XP/drop/honor rates, MOTD, player limit and
starting level. It is configuration only - it never converts, builds, or
starts anything. Run it any time after setup, then restart the server to
apply. Enter keeps the current value everywhere, so it is safe to just look
around.

## Other modes

`./twow.sh setup` converts without starting; `./twow.sh run
[loglevel]` starts without converting; `./twow.sh update` follows
upstream: it pulls the latest source, rebuilds only what changed, backs up
the world database, and applies any new schema migrations (stop the world
server first). `./twow.sh help` shows all modes. Day-to-day
operation is documented in `server/README.linux.md`.

`./twow.sh status` reports what is running. `./twow.sh doctor`
answers the other question, whether the install is correct: binaries and map
data, the game databases and any migrations still waiting, what the repack's
dump left behind, whether the realm listens where it advertises, and the
firewall in front of it. It reads only, names the fix beside each finding, and
exits non-zero when something is wrong.

The world server holds the `mangos>` console on the terminal that starts it.
`./twow.sh run --detached` puts that console in a tmux session instead, so the
server outlives the shell, and `./twow.sh console` returns to it.

Leaving that console does two different things, so it is worth knowing both:

- tmux prefix, then `d` - detaches, and the server keeps running.
  The prefix is `Ctrl+B` unless your `tmux.conf` changes it.
- `Ctrl+C` - stops the server, same as `server shutdown 1` at the prompt.

tmux is all `--detached` needs; plain `run` works without it.

More modes:

- `./twow.sh logs [world|realmd|errors|db|stderr] [-f]` - last 40 lines of a
  log, or `-f` to follow it
- `./twow.sh account --list` - who has an account and at what level;
  `--password <name>` changes one from a shell
- `./twow.sh reset --world` - empties the realm; the build, the world database
  and the client stay
- `./twow.sh reset --all` - removes what setup generated, keeping `client/` and
  the archives, so a conversion starts again from what is downloaded
- `./twow.sh backup` - dumps characters and accounts into `server/backups`,
  keeping the newest 10 of each; safe to run while the server is up.
  `--restore <file>` puts one back. `setup` and `update` rebuild the world
  database, so these two hold what only this realm has
- `./twow.sh stop` - stops the world, then realmd, then the database, in the
  order they depend on each other

`reset` and `backup --restore` ask before doing anything; `--yes` carries the
answer where a run has no terminal to ask on.

First boot: setup offers a name for the realm, who can reach it, whether the
repack's timed broadcast to every player keeps running, and a game master
account, and points `client/realmlist.wtf` at this realm; a client carried over
from the live game arrives pointed at Turtle's own login server.
`./twow.sh account` creates further accounts, and the world console
takes `account create <name> <pass>` just as well. The name can be changed later
with `./twow.sh realm --name <name>`, the address with
`./twow.sh realm <address>`, or both from the interactive screen.

## Credits

- SIGGZ (send me a link) for the repack, [Penqle](https://github.com/Penqle/) for the 1181dev source
- [Kes](https://ko-fi.com/scribblesbykes) (NoGuiltGaming) for the Windows setup guide this follows
- Ramach for battle-testing the setup on Debian and in a Proxmox LXC container
- The TurtleWoW preservation [Discord](https://discord.gg/kpnCR644kk)

## Donations

If this setup saved an evening of fiddling, a small BTC tip toward the work on
these scripts is welcome:

```
bc1qxsuelwvrs28u43eewj39rpn34g4qtkhpdwwlhe
```

Never required, always appreciated.

## License

The scripts in this repo are free software under the GNU General Public
License, version 3 or later. `LICENSE` carries the terms, and
`./twow.sh license` prints the same from a terminal.

    Copyright (C) 2026 Xapne
    Contact: https://github.com/Xapne/twow-linux/issues or xapne@protonmail.ch

The server core is Penqle's tortoise-wow, cloned at build time, and keeps the
MaNGOS lineage's own GPL-2.0-or-later terms. The repack, the map data and the
game client come from elsewhere and are supplied by whoever runs this; the
copyright in them rests with their authors.

This exists for preservation and for private local play. That is the spirit the
setup is written in rather than a term of the license above.
