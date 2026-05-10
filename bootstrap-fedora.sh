#!/usr/bin/bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2026 Hadi Chokr <hadichokr@icloud.com>
set -eux

# Use ComposeID instead of a fragile build_date hack
[ -d artifacts ] || mkdir artifacts
if [ ! -f artifacts/compose_id.txt ]; then
    curl -sf https://kojipkgs.fedoraproject.org/compose/rawhide/latest-Fedora-Rawhide/COMPOSE_ID > artifacts/compose_id.txt
fi
COMPOSE_ID=$(cat artifacts/compose_id.txt)
dnf config-manager setopt "*.baseurl=https://kojipkgs.fedoraproject.org/compose/rawhide/${COMPOSE_ID}/compose/Everything/x86_64/os/"
dnf config-manager setopt "*.metalink="
dnf config-manager setopt "*.mirrorlist="
dnf distro-sync -y

dnf install -y \
    sudo git ninja-build rsync openssh-clients ccache \
    python3-yaml python3-requests python3-pip python3-setproctitle ruby erofs-utils \
    cmake rpm-build \
    'dnf-command(repoquery)'

pip install minio --break-system-packages

git clone https://invent.kde.org/sdk/kde-builder.git /kde-builder
ln -s /kde-builder/kde-builder /usr/local/bin/kde-builder
