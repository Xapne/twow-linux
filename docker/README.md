# The server in a container

Runs the whole conversion and the server itself inside Debian 13, so a macOS or
Windows machine serves the realm from the same native Linux stack this repo
builds everywhere else. The container carries the compiler, MariaDB and wine;
the host carries Docker and your two archives.

## What you need

Docker Desktop (macOS, Windows) or Docker Engine (Linux), about 20 GB of disk,
and 8 GB given to the Docker VM. Bring `TurtleWoW_1.18.zip` and `data.zip` and
put them beside `compose.yaml`.

## Start it

```
cd docker
docker compose up -d
docker compose logs -f
```

The first run extracts the repack, clones and compiles the core, seeds the
databases and starts the server, which takes 15-45 minutes on an x86-64 host.
It is the same idempotent conversion as everywhere else, so it resumes where it
stopped if it is interrupted.

It runs unattended: the questions the kit asks a person at a terminal are left
at their defaults here, so the realm comes up called TurtleWoW and answering on
127.0.0.1. The same screen is there whenever you want it:

```
docker compose exec twow ./twow.sh interactive
```

The compile sizes itself to the memory the container is given: `compose.yaml`
grants 8 GB and the kit reads that limit, holding the job count to what fits.
`TWOW_BUILD_JOBS=4` in the service's `environment:` sets it by hand.

## The world console, and the two other ways in

There are three prompts here and they are easy to mix up, so each one and what
it is for:

**1. The `mangos>` world console.** It is the container's main process, so
attaching reaches it:

```
docker attach twow
```

That is where the core's own commands live: `server info`, `account create`,
`.gm on`. Leaving it does two different things, and both are worth knowing:

- `Ctrl+P` then `Ctrl+Q` - detaches, and the server keeps running.
- `Ctrl+C` - stops the server, same as `server shutdown 1` at the prompt, and
  the container stops with it. `docker compose up -d` starts it again.

**2. The kit's own screens**, for the jobs that are easier answered than typed.
Account creation is one of them, and it hashes the password and offers to set
the game master level:

```
docker compose exec twow ./twow.sh account
docker compose exec twow ./twow.sh interactive
```

Both draw a terminal, so they want one: `docker compose exec` gives them a
terminal already, and plain `docker exec` wants `-it` for the same result.

**3. A shell**, when something wants looking at directly:

```
docker compose exec twow bash
```

`docker compose logs -f` watches the world console's output from outside, which
suits reading along rather than typing.

## Other modes

Every mode the kit has is reachable in the running container:

```
docker compose exec twow ./twow.sh doctor
docker compose exec twow ./twow.sh account --list
docker compose exec twow ./twow.sh backup
docker compose exec twow ./twow.sh logs world -f
```

`./twow.sh doctor` is the first thing to run when something looks wrong: it
reads only, and names the fix beside each finding.

## Connecting a client

The realm answers on `127.0.0.1`, and `compose.yaml` publishes 3724 and 8091 on
the host with the same numbers, so a client on that machine reaches it by
putting one line in `realmlist.wtf`:

```
set realmlist 127.0.0.1
```

Create an account first, either with `./twow.sh account` as above or with
`account create <name> <pass>` at the `mangos>` prompt.

## LAN play

Two things decide who reaches the realm, one on each side of the container, and
both have to say the same thing.

Publish on every interface rather than the host's loopback, in `compose.yaml`:

```yaml
ports:
  - "3724:3724"
  - "8091:8091"
```

Then give the realm the host's address and put the same one in `realmlist.wtf`:

```
docker compose up -d --force-recreate
docker compose exec twow ./twow.sh realm 192.168.1.50
```

Type that address rather than taking the one offered: the interactive screen
reads the address of the machine it runs on, which inside a container is the
bridge network, and a realm advertising 172.17.0.2 is reachable from the
container alone.

## Where the data lives

The `twow-data` volume holds everything a conversion makes: the compiled
binaries, the map data, the database and the characters in it. It outlives the
container, so `docker compose down` and `up` again returns to the same realm.

```
docker compose exec twow ./twow.sh backup      # into the volume
docker compose down                            # stop, keeping the volume
docker volume rm twow_twow-data                # start the realm over
```

The two archives are mounted read-only and stay exactly as you brought them.

## On Apple Silicon and Windows on ARM

The image is `linux/amd64` on every host, because the one-time database seed
runs the repack's own Windows MariaDB, which is an x86-64 binary. Docker
Desktop translates that on an ARM machine, and the translation shows up in the
first compile: budget hours for it rather than minutes. Everything after the
first run is ordinary server work and stays comfortable.

Windows on x86-64 runs the image natively through WSL2, at Linux speed.
