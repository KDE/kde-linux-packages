# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2024 Lasath Fernando <devel@lasath.org>
# SPDX-FileCopyrightText: 2025 Harald Sitter <sitter@kde.org>

set -eux

# Set environment variables
export PARALLELL_DOWNLOADS=50
export ARTIFACTS_DIR="artifacts"
export MIRRORLIST=/etc/pacman.d/mirrorlist

# Use the pacman.conf without kde linux repos. Otherwise we'd download binaries form there when instead we want to build from source.
cp /etc/pacman.conf.nolinux /etc/pacman.conf

# Enable parallel downloads for more speed
sed -i "s/ParallelDownloads = 5/ParallelDownloads = $PARALLELL_DOWNLOADS/" /etc/pacman.conf
sed -i 's/NoProgressBar//' /etc/pacman.conf

[ -d artifacts ] || mkdir artifacts

MAX_DAYS=30
BASE_URL="https://archive.archlinux.org/repos"
mirror_found=0
for ((offset=1; offset<=MAX_DAYS; offset++)); do
    DATE=$(date -u -d "-${offset} days" +%Y/%m/%d)
    DB_URL="${BASE_URL}/${DATE}/extra/os/x86_64/extra.db"

    echo "Checking $DATE ..."

    # Fetch the database and grep for fastfetch
    if curl --silent --fail "$DB_URL" | zgrep -q "fastfetch"; then
        echo "Found working repo: $DATE"
        echo "$DATE" > "$ARTIFACTS_DIR/build_date.txt"
        echo "Server = ${BASE_URL}/${DATE}/\$repo/os/\$arch" | sudo tee "$MIRRORLIST" > /dev/null
        mirror_found=1
        break
    fi
done

if [ $mirror_found -eq 0 ]; then
    echo "No working archive found in last $MAX_DAYS days."
    echo "Check https://status.archlinux.org for potential DDoS or service problems."
    echo "Or check https://bbs.archlinux.org for incident reports."
    exit 1
fi

# Initialize pacman and install packages
pacman-key --init
pacman-key --populate
# --refresh twice to force a refresh
pacman --sync --refresh --refresh --noconfirm --sysupgrade \
        sudo base-devel git ninja rsync openssh ccache \
        python-yaml python-setproctitle python-requests python-srcinfo \
        python-minio python-pip

# Packaged version as of 2025-11-28 is broken and doesn't work with our scripts
# Also note the same hack in make-packages.sh
pip install minio --break-system-packages

# Clone the KDE Builder repository and pin to a specific commit
# because there are some issues with the latest version
git clone https://invent.kde.org/sdk/kde-builder.git /kde-builder
ln -s /kde-builder/kde-builder /usr/local/bin

chown -R user:user $ARTIFACTS_DIR