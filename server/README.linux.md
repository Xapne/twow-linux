# TurtleWoW 1.18.1 server on Arch Linux (native)

Everything server-side runs natively. No Wine in the server stack.

- `bin/realmd`, `bin/mangosd`: native Linux builds of Penqle's tortoise-wow,
  branch 1181dev, compiled from `../src` into `../build` (links ACE from
  `../deps/ACE_wrappers`).
- Database: system MariaDB binary with a project-local data directory in
  `db/`, config in `my.cnf` (127.0.0.1, root/mangos). The port is normally
  3306, but setup-native.sh moves to the next free one when a distro MariaDB
  service already holds it; the value in use is recorded in `db.env`, which
  the scripts here read.
- The Windows leftovers (`*.bat`, `bin/*.exe`, `bin/*.dll`,
  `mariadb-10.3.39-winx64/`) are unused now. The old Windows MariaDB data dir
  still holds the original DB snapshot, so keep it until you have backups.
- The game client stays under Wine: run `WoW.exe` in `../client`
  (realmlist already points at 127.0.0.1). Never run TurtleWoW.exe.

## Start order (every session)

Three terminals, in this order, wait for each to be ready:

1. `./1-start-mysql.sh`   - ready at "ready for connections"
2. `./2-realm-server.sh`  - ready at "Login server is up and running"
3. `./3-world-server.sh [loglevel]` - ready at "World initialized"; this
   terminal is the server console (account create <user> <pass>).
   Optional loglevel 0-3 sets console verbosity in mangosd.conf before
   launch (0 near-silent, 1 errors only, 2 detail, 3 debug). Same argument
   works on `setup-native.sh run [loglevel]`. Log files keep their own
   detail via LogFileLevel.

Login: admin / admin (see README.txt, change it).

## Other scripts

- `./import-world-db.sh`: drop + re-import turtle_world from
  turtle_world.sql. Only for updates. ALWAYS follow with apply-db-updates.sh.
- `./apply-db-updates.sh`: apply world migrations from `../src` that the DB
  does not have yet. Run after an import and after every git pull + rebuild.
- `./clear-logs.sh`: empty the logs/ folder.

## Updating

1. `cd ../src && git pull`
2. `ninja -C ../build mangosd realmd` and copy the two binaries into `bin/`
3. `./apply-db-updates.sh` (with MySQL running)

## Notes

- mangosd expects its console on stdin; run it in a real terminal. With
  stdin closed (background/service) it shuts down right after startup. For a
  systemd unit, set Console.Enable = 0 in bin/mangosd.conf instead.
- Ports: MySQL per `db.env` (3306 unless taken), 3724 realmd (auth),
  8091 mangosd (world). All bound to
  127.0.0.1. For LAN play see Section 14 of the setup guide (BindIP,
  HostAddressOverride in bin/realmd.conf, and the realmlist table address).
