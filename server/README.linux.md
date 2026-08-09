# TurtleWoW 1.18.1 server on Linux (native)

Everything server-side runs natively. No Wine in the server stack.

- `bin/realmd`, `bin/mangosd`: native Linux builds of Penqle's tortoise-wow,
  branch 1181dev, compiled from `../src` into `../build`. ACE is taken from the
  distribution where a recent enough version is packaged (`../twow.sh
  deps` says whether it is here), and otherwise built into
  `../deps/ACE_wrappers`.
- Database: system MariaDB binary with a project-local data directory in
  `db/`, config in `my.cnf` (127.0.0.1, root/mangos). The port is 3306 where it
  is free and the next one up where a distro MariaDB service already holds it
  (Debian and Ubuntu start one on install), and the value in use is recorded in
  `db.env`, which the scripts here read. That file is part of the install and
  should not be deleted: without it a stopped database may be brought back on a
  different port. Note that a bare `mariadb` in a shell reaches 3306, which is
  the distro's own server rather than this one whenever the two coexist; the
  helper scripts here always use the port from `db.env`.
- The Windows leftovers (`*.bat`, `bin/*.exe`, `bin/*.dll`,
  `mariadb-10.3.39-winx64/`) are unused. The original database snapshot is still
  held in the old Windows MariaDB data directory, which should be retained until
  backups exist.
- The game client stays under Wine: `WoW.exe` in `../client` is the entry point,
  with realmlist already pointing at 127.0.0.1. TurtleWoW.exe must not be
  started; it patches the client and requires WebView2.

## Starting the server (every session)

One command does all three, the database and login server in the background and
the world console in front:

```
../twow.sh run [loglevel]
```

`--detached` puts the world console in a tmux session instead, so the server
outlives the shell that started it, and `../twow.sh console` returns to it:

```
../twow.sh run --detached [loglevel]
../twow.sh console
```

Leaving that console does two different things:

- tmux prefix, then `d` - detaches, and the server keeps running.
  The prefix is `Ctrl+B` unless your `tmux.conf` changes it.
- `Ctrl+C` - stops the server, same as `server shutdown 1` at the prompt.

The three pieces also start on their own, one per terminal, which keeps their
logs apart:

1. `./1-start-mysql.sh`   - ready at "ready for connections"
2. `./2-realm-server.sh`  - ready at "Login server is up and running"
3. `./3-world-server.sh [loglevel]` - ready at "World initialized"; this
   terminal is the server console (account create <user> <pass>).
   Optional loglevel 0-3 sets console verbosity in mangosd.conf before
   launch (0 near-silent, 1 errors only, 2 detail, 3 debug). Same argument
   works on `twow.sh run [loglevel]`. Log files keep their own
   detail via LogFileLevel.

Either way the same scripts run, and the order is checked rather than assumed:
each refuses to start without the piece below it, and names what is missing.
`TWOW_SKIP_PREFLIGHT=1` starts anyway, for a database or login server these
checks do not describe. Every script takes `--help`.

Login: the game master account setup offered on the first run.
`../twow.sh account --list` shows who is here, `--password <name>` changes one,
and a bare `../twow.sh account` makes another.

## Stopping the world

Ctrl+C in the console, or `pkill -TERM -f 'mangosd -c'` when detached. SIGINT is
the core's restart signal; with `pkill -INT` the world is only restarted.

The world is restarted automatically after a crash or a scheduled restart. That
is suspended while `restart.paused` exists in this folder, so the file is created
before the world is stopped for maintenance, and removed afterwards.

## Other scripts

- `./import-world-db.sh`: drops and re-imports turtle_world from
  turtle_world.sql. Only for updates, and always followed by
  `apply-db-updates.sh`.
- `./apply-db-updates.sh`: applies world migrations from `../src` that the
  database does not have yet. Required after an import, and after every git pull
  and rebuild. `--check` counts what is waiting and applies none.
- `./clear-logs.sh`: empties the logs/ folder.

`../twow.sh doctor` examines an install rather than running one:
binaries and map data, the game databases and their pending migrations, what
the repack's dump left behind, whether the realm listens where it advertises,
and the firewall in front of it. It reads only, so it is safe against a running
server, and exits non-zero when something is wrong.

All of them read `../lib/kit.sh`, which holds the logging, the database handle
and the port and process checks they share with `twow.sh`.

## Updating

1. Stop the world server (see above); `twow.sh update` refuses while it is running
2. `cd ../src && git pull`
3. `ninja -C ../build mangosd realmd` and copy the two binaries into `bin/`
4. `./apply-db-updates.sh` (with MySQL running)

## Notes

- mangosd expects its console on stdin and therefore requires a real terminal.
  With stdin closed (background or service) it shuts down right after startup.
  `../twow.sh run --detached` gives it one that outlives the shell, and
  `../twow.sh console` returns to it. A systemd unit is the other way, and needs
  `Console.Enable = 0` in `bin/mangosd.conf`, which trades the console away.
- Ports: MySQL per `db.env` (3306 unless taken), 3724 realmd (auth), 8091
  mangosd (world). The bind follows the realm's address, asked at first boot and
  changed with `./twow.sh realm <address>`; Section 14 of the setup guide
  covers the same by hand (BindIP, HostAddressOverride in bin/realmd.conf, and
  the realmlist table address).
