# syntax=docker/dockerfile:1
# Copyright (C) 2026 Xapne
# SPDX-License-Identifier: GPL-3.0-or-later
#
# The repack converted and served from a container, so a machine that is not
# Linux still runs a native Linux server. Built for linux/amd64 whatever the
# host: the one-time database seed runs the repack's own Windows mysqld under
# wine, and that binary is x86-64.
#
# Debian 13 is the platform the conversion is tested on, so the container and
# the VM path answer for the same distro, MariaDB and wine.
FROM debian:13-slim@sha256:3a39a0592364683e6bab97937b72cad5a8fa6dcbbee90edb3bb48c7f8e94f258

LABEL org.opencontainers.image.title="twow-linux" \
      org.opencontainers.image.description="TurtleWoW 1.18.1 repack as a native Linux server" \
      org.opencontainers.image.source="https://github.com/Xapne/twow-linux" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TERM=xterm-256color \
    WINEDEBUG=-all \
    WINEPREFIX=/twow/.wine \
    TINI_SUBREAPER=1

# ss and pgrep settle which process holds a port, which is how the kit tells its
# own server from a stranger on 3724; neither ships in a slim base. tini reaps
# and forwards signals, so a stop reaches the world server.
RUN apt-get update && apt-get install -y \
      ca-certificates iproute2 procps tini \
 && rm -rf /var/lib/apt/lists/*

# The table in twow.sh is the only list of these anywhere, so it is asked
# rather than repeated. Copied ahead of the rest so editing server/ leaves
# this layer alone.
COPY twow.sh /opt/kit/twow.sh
COPY lib/ /opt/kit/lib/
RUN apt-get update && apt-get install -y $(/opt/kit/twow.sh deps --packages) \
 && rm -rf /var/lib/apt/lists/*

COPY . /opt/kit/
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

# An explicit uid keeps volume ownership predictable from the host, and keeps
# wine and the database off root.
RUN useradd --uid 1000 --create-home --shell /bin/bash turtle \
 && chmod +x /usr/local/bin/entrypoint.sh \
 && mkdir -p /twow && chown turtle:turtle /twow
USER turtle
WORKDIR /twow

# realmd takes the login, mangosd takes the world. The database stays inside.
EXPOSE 3724 8091

# The core opens this port once every map is loaded, which is the readiness
# signal the kit uses too. The grace period covers a first compile.
HEALTHCHECK --interval=30s --timeout=5s --start-period=90m --retries=3 \
  CMD ss -tln | grep -q ':8091 ' || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
