# TurtleWoW 1.18.1 server on Linux (native)

Everything server-side runs natively. No Wine in the server stack.

- `bin/realmd`, `bin/mangosd`: native Linux builds of Penqle's tortoise-wow,
  branch 1181dev, compiled from `../src` into `../build`. ACE is taken from the
  distribution where a recent enough version is packaged (`../setup-native.sh
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

## Start order (every session)

Three terminals, in this order, each started once the previous one is ready:

1. `./1-start-mysql.sh`   - ready at "ready for connections"
2. `./2-realm-server.sh`  - ready at "Login server is up and running"
3. `./3-world-server.sh [loglevel]` - ready at "World initialized"; this
   terminal is the server console (account create <user> <pass>).
   Optional loglevel 0-3 sets console verbosity in mangosd.conf before
   launch (0 near-silent, 1 errors only, 2 detail, 3 debug). Same argument
   works on `setup-native.sh run [loglevel]`. Log files keep their own
   detail via LogFileLevel.

Login: admin / admin (see README.txt; the password is meant to be replaced).

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
  and rebuild.
- `./clear-logs.sh`: empties the logs/ folder.

## Updating

1. Stop the world server (see above); `setup-native.sh update` refuses while it is running
2. `cd ../src && git pull`
3. `ninja -C ../build mangosd realmd` and copy the two binaries into `bin/`
4. `./apply-db-updates.sh` (with MySQL running)

## Notes

- mangosd expects its console on stdin and therefore requires a real terminal.
  With stdin closed (background or service) it shuts down right after startup;
  for a systemd unit, Console.Enable = 0 is set in bin/mangosd.conf instead.
- Ports: MySQL per `db.env` (3306 unless taken), 3724 realmd (auth), 8091
  mangosd (world), all bound to 127.0.0.1. LAN play is covered in Section 14 of
  the setup guide (BindIP, HostAddressOverride in bin/realmd.conf, and the
  realmlist table address).
