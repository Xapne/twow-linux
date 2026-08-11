# The server in a container

Runs the whole conversion and the server itself inside Debian 13, so a macOS or
Windows machine serves the realm from the same native Linux stack this repo
builds everywhere else. The container carries the compiler, MariaDB and wine;
the host carries Docker and your two archives.

Every command below runs from the repo root, where `compose.yaml` sits.

## What you need

Docker Desktop (macOS, Windows) or Docker Engine (Linux), about 20 GB of disk,
and 8 GB given to the Docker VM. `TurtleWoW_1.18.zip` and `data.zip` go in the
repo root, the same place the rest of the setup expects them.

## Start it

Convert first, with the questions in front of you:

```
docker compose run --rm twow setup
```

That extracts the repack, clones and compiles the core, seeds the databases and
then asks the same first-run questions as every other install: the realm's name,
who can reach it, whether the repack's broadcast keeps running, and a game
master account. It takes 15-45 minutes on an x86-64 host, and resumes where it
stopped if it is interrupted.

Then start the realm:

```
docker compose up -d
docker compose logs -f          # Ctrl+C stops watching, the realm keeps running
```

`docker compose up -d` on its own converts as well, on a machine nobody is
watching. Every answer keeps its default there, so the realm comes up called
TurtleWoW, answering on 127.0.0.1, without an account; the log says so, and both
screens are reachable afterwards:

```
docker compose exec twow ./twow.sh interactive
docker compose exec twow ./twow.sh account
```

The compile sizes itself to the memory the container is given: `compose.yaml`
grants 8 GB and the kit reads that limit, holding the job count to what fits.

## The world console, and the two other ways in

Three prompts live here, and which one to use is worth knowing.

**The `mangos>` world console** runs in a tmux session of its own inside the
container, which an exec reaches. This is where the core's own commands are:
`server info`, `account create`, `.gm on`.

```
docker compose exec twow ./twow.sh console
```

Leaving it:

- `Ctrl+B` then `d` - detaches, and the server keeps running. Closing the
  terminal, or losing the connection it came over, does the same.
- `Ctrl+C`, or `server shutdown 1` at the prompt - stops the world server.

**The kit's own screens** handle what is easier answered than typed. Account
creation is one: it hashes the password and offers to set the game master level.

```
docker compose exec twow ./twow.sh account
docker compose exec twow ./twow.sh interactive
```

Both draw a terminal and `docker compose exec` gives them one; plain
`docker exec` wants `-it` for the same result.

**A shell**, when something wants looking at directly:

```
docker compose exec twow bash
```

`docker compose logs` carries the conversion and the start, and the world's own
log is followed from inside:

```
docker compose exec twow ./twow.sh logs world -f
```

## Other modes

Every mode the kit has is reachable in the running container:

```
docker compose exec twow ./twow.sh doctor
docker compose exec twow ./twow.sh account --list
docker compose exec twow ./twow.sh backup
docker compose exec twow ./twow.sh logs world -f
```

`doctor` is the first thing to run when something looks wrong: it reads only,
and names the fix beside each finding.

## Connecting a client

The realm answers on 127.0.0.1 and the ports are published there, so a client on
the same machine reaches it with one line in `realmlist.wtf`:

```
set realmlist 127.0.0.1
```

An account comes first, from `./twow.sh account` above or `account create
<name> <pass>` at the `mangos>` prompt.

## LAN play

Two settings, one on each side of the container, naming the same address.
Compose reads `.env` on its own:

```
cp docker/env.example .env
$EDITOR .env
docker compose up -d --force-recreate
```

`TWOW_PUBLISH_ON=0.0.0.0` opens the published ports to the network, and
`TWOW_REALM_ADDRESS` is what clients are told to dial. The same address goes
in `realmlist.wtf`.

That address is typed rather than detected, because a container has no way to
read the host's. The interactive screen offers the address of the machine it
runs on, which here is the bridge network, and a realm advertising 172.17.0.2
is reachable from the container alone.

## Where the data lives

The `twow-data` volume holds everything a conversion makes: the compiled
binaries, the map data, the database and the characters in it. It outlives the
container, so `down` and `up` return to the same realm.

```
docker compose exec twow ./twow.sh backup      # into the volume
docker compose down                            # stop, keeping the volume
docker volume rm twow_twow-data                # start the realm over
```

The two archives are mounted read-only and stay as you brought them.

## On Apple Silicon and Windows on ARM

The image is `linux/amd64` on every host, because the one-time database seed
runs the repack's own Windows MariaDB, an x86-64 binary. Docker Desktop
translates that on an ARM machine, and the translation shows in the first
compile: budget hours for it rather than minutes. Everything after that is
ordinary server work.

Windows on x86-64 runs the image natively through WSL2, at Linux speed.

## A published image

`ghcr.io/xapne/twow-linux` carries the same build, which a host pulls rather
than assembling the image itself:

```
docker compose pull
docker compose up -d
```

The conversion inside still runs once, on first start.
