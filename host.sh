#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Harald Sitter <sitter@kde.org>

set -eux

[ -d /tmp/host ] || mkdir /tmp/host
[ -d /tmp/host/kde-builder-logs ] || mkdir /tmp/host/kde-builder-logs
# Make sure the build namespace can write into the logs directory
chmod 777 /tmp/host/kde-builder-logs

if [ ! -x caddy ]; then
    wget https://github.com/caddyserver/caddy/releases/download/v2.11.4/caddy_2.11.4_linux_amd64.tar.gz
    tar --extract --file=caddy_2.11.4_linux_amd64.tar.gz caddy
fi
[ -x /tmp/host/caddy ] || cp caddy /tmp/host/caddy

exec ./caddy run
