# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2024 Lasath Fernando <devel@lasath.org>
# SPDX-FileCopyrightText: 2025 Harald Sitter <sitter@kde.org>

set -eux

# Set environment variables
export PARALLEL_DOWNLOADS=50
export ARTIFACTS_DIR="artifacts"
export MIRRORLIST=/etc/pacman.d/mirrorlist

# Use the pacman.conf without KDE Linux repos so we build from source,
# not pull pre-built binaries.
cp /etc/pacman.conf.nolinux /etc/pacman.conf || true

# Enable parallel downloads for more speed
sed -i "s/ParallelDownloads = 5/ParallelDownloads = $PARALLEL_DOWNLOADS/" /etc/pacman.conf
sed -i 's/NoProgressBar//' /etc/pacman.conf

mkdir -p "$ARTIFACTS_DIR"

LATEST=$(curl --fail --silent http://archive.kde-linux.haraldsitter.eu/latest.txt)
REPO="http://archive.kde-linux.haraldsitter.eu/${LATEST}"
echo "$REPO" > "$ARTIFACTS_DIR/build_repo.txt"
echo "Server = ${REPO}/\$repo/os/\$arch" | sudo tee "$MIRRORLIST" > /dev/null

pacman-key --init
pacman-key --populate
# --refresh twice forces a cache refresh
pacman --sync --refresh --refresh --noconfirm --sysupgrade \
        sudo base-devel git ninja rsync openssh ccache \
        python-yaml python-setproctitle python-requests python-srcinfo \
        python-minio python-pip debugedit erofs-utils

# The packaged minio (as of 2025-11-28) is broken; install from PyPI instead.
# Same workaround applied in make-kde-tarball.py.
pip install minio --break-system-packages

git clone https://invent.kde.org/sdk/kde-builder.git /kde-builder
ln -s /kde-builder/kde-builder /usr/local/bin

id user 2>/dev/null || useradd -m user
chown -R user:user "$ARTIFACTS_DIR"
