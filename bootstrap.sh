# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2024 Lasath Fernando <devel@lasath.org>
# SPDX-FileCopyrightText: 2025 Harald Sitter <sitter@kde.org>

set -eux

# Set environment variables
export PARALLELL_DOWNLOADS=50

# Use the pacman.conf without kde linux repos. Otherwise we'd download binaries form there when instead we want to build from source.
cp /etc/pacman.conf.nolinux /etc/pacman.conf

# Enable parallel downloads for more speed
sed -i "s/ParallelDownloads = 5/ParallelDownloads = $PARALLELL_DOWNLOADS/" /etc/pacman.conf
sed -i 's/NoProgressBar//' /etc/pacman.conf

echo "Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist

# Initialize pacman and install packages
pacman-key --init
pacman-key --populate
# --refresh twice to force a refresh
pacman --sync --refresh --refresh --noconfirm --sysupgrade \
        sudo base-devel git ninja rsync openssh ccache \
        python-yaml python-setproctitle python-requests python-srcinfo \
        python-minio python-pip

# Packaged version as of 2025-11-28 is broken and doesn't work with our scripts
pip install minio --break-system-packages

# Clone the KDE Builder repository and pin to a specific commit
# because there are some issues with the latest version
git clone https://invent.kde.org/sdk/kde-builder.git /kde-builder
ln -s /kde-builder/kde-builder /usr/local/bin
