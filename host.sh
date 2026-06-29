#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Harald Sitter <sitter@kde.org>

set -eux

if [ ! -x caddy ]; then
    wget https://github.com/caddyserver/caddy/releases/download/v2.11.4/caddy_2.11.4_linux_amd64.tar.gz
    tar --extract --file=caddy_2.11.4_linux_amd64.tar.gz caddy
fi

[ -d /tmp/host ] || mkdir /tmp/host
[ -x /tmp/host/caddy ] || cp caddy /tmp/host/caddy

exec ./caddy run
