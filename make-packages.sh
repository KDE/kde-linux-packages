#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2024 Lasath Fernando <devel@lasath.org>

# -u being missing is on purpose, as it would blow up on CDN_UPLOAD_KEY
# being missing, which is sometimes intentional
set -xe

curl https://storage.kde.org/kde-linux-packages/testing/ccache/ccache.tar | tar -x || true
# Unclear which ccache.conf gets used by makepkg :(
sudo ccache --set-config=max_size=50G # Sets /root/.config/ccache/ccache.conf
ccache --set-config=max_size=50G # Sets ~/.config/ccache/ccache.conf
export CCACHE_DIR="$HOME/ccache"
ccache --set-config=max_size=50G # Sets $CCACHE_DIR/ccache.conf
echo "BUILDENV=(!distcc color ccache check !sign)" >> "$HOME/.makepkg.conf"

curl https://aur.archlinux.org/cgit/aur.git/snapshot/paru-bin.tar.gz | tar xz
cd paru-bin
makepkg --noconfirm --syncdeps --install
cd ..

paru -S --noconfirm --needed --skipreview aurutils

# Set up mirrorlist.
BUILD_DATE=$(date -u -d 'yesterday' +%Y/%m/%d)
[ -d artifacts ] || mkdir artifacts
echo "$BUILD_DATE" > "artifacts/build_date.txt"
echo "Server = https://archive.archlinux.org/repos/${BUILD_DATE}/\$repo/os/\$arch"| sudo tee /etc/pacman.d/mirrorlist

# Since the docker image does not get rebuilt on every run,
# some packages may be out of date.
# NOTE: refresh twice forces a refresh, this is to prevent cache timing confusions causing random 404 errors
sudo pacman --sync --refresh --refresh --sysupgrade --noconfirm

AUR_TARGETS=(
    # TTY Screenreader
    fenrir-git

    # Limits USB writeback cache for safer and faster ejection.
    usb-dirty-pages-udev

    snapd
    steam-devices-git
)

pkgbuildsDir=$CI_PROJECT_DIR/pkgbuilds

PKGBUILDS_DIR="$pkgbuildsDir" ./make-pkgbuilds.py

# Assume all directories in pkgbuildsDir are packages to build
# We have to do this because some targets like `workspace` are
# not actually packages.
packages=$(basename -a $pkgbuildsDir/kde-banana-*)

# Install already built packages in parallel for a speedup (except debug packages)
alreadyBuiltPackages="$(find $pkgbuildsDir -name '*.pkg.tar.zst' | grep -v -- '-git-debug-' || true)"
echo "Reusing already built packages: $alreadyBuiltPackages"
if [ -n "$alreadyBuiltPackages" ]; then
    sudo pacman --upgrade --noconfirm --needed $alreadyBuiltPackages
fi

# Right now this creates a local version of the AUR with the packages we created.
# Long term, we should push these into the actual AUR so regular Arch Linux users
# can also benefit from well maintained KDE git packages.
mkdir -p $HOME/.config/paru
cat <<- EOF >> $HOME/.config/paru/paru.conf
[kde-linux]
Path = $pkgbuildsDir
EOF

# Paru will build an install the packages in the correct order

# Override the systemd build to enable sysupdated (--nocheck because the tests like to fail for no reason)
MESON_EXTRA_CONFIGURE_OPTIONS=-Dsysupdated=enabled \
    paru --pkgbuilds --sync --noconfirm --mflags="--skippgpcheck --nocheck" systemd

# Build our fake banana packages
paru --sync --needed --noconfirm $packages

#### Create arch repositories to be published as artifacts

artifactsDir=$CI_PROJECT_DIR/artifacts
packagesDir=$artifactsDir/packages
packagesDebugDir=$artifactsDir/packages-debug

# Move the debug packages first so regular packages are easier to find
mkdir -p $packagesDebugDir
mv $pkgbuildsDir/*/*-debug-*.pkg.tar.zst $packagesDebugDir
repo-add $packagesDebugDir/kde-linux-debug.db.tar.gz $packagesDebugDir/*.pkg.tar.zst

mkdir -p $packagesDir
mv $pkgbuildsDir/*/*.pkg.tar.zst $packagesDir
repo-add $packagesDir/kde-linux.db.tar.gz $packagesDir/*.pkg.tar.zst

# aurutils *really* doesn't like it if the repo is not in pacman.conf
sudo tee -a /etc/pacman.conf <<- EOF
[kde-linux]
SigLevel = Never
Server = file://$packagesDir
EOF
sudo pacman --sync --refresh

# This fetches from AUR, builds and adds to our repo in one command :D
# --no-check here is because systemd-git sometimes has failing tests ¯\_(ツ)_/¯
aur sync --no-view --no-confirm --no-check --database kde-linux "${AUR_TARGETS[@]}"

# $CDN_UPLOAD_KEY is only available for protected branches
if [ -z "$CDN_UPLOAD_KEY" ]; then
    echo "No CDN_UPLOAD_KEY found, skipping upload"
    exit 0
fi

chmod 600 "$CDN_UPLOAD_KEY" # make sure key is not world readable. ssh gets angry otherwise
CDN_UPLOAD_URL="$CDN_UPLOAD_ACCOUNT:/srv/www/cdn.kde.org/kde-linux/packaging"

rsync --archive --verbose --compress \
    --rsh="ssh -o StrictHostKeyChecking=no -i $CDN_UPLOAD_KEY" \
    $artifactsDir/ $CDN_UPLOAD_URL

cd
git clone --depth=1 https://invent.kde.org/sysadmin/ci-utilities.git
CI_UTILITIES_DIR="$PWD/ci-utilities"

mkdir "$CI_PROJECT_DIR/upload"
cd "$CI_PROJECT_DIR/upload"
mv "$artifactsDir" repo # rename
mkdir ccache
tar --directory="$HOME" --create --file=ccache/ccache.tar ccache # mind that chdir, it's a bit confusing

"$CI_UTILITIES_DIR/sync-s3-folder.py" --mode upload --local "$PWD/" --remote storage.kde.org/kde-linux-packages/testing/ --verbose || true

cd "$CI_PROJECT_DIR"
# Try to prevent the cleanup from erroring out on unexpected content.
rm --recursive --force upload pkgbuilds artifacts
git clean -dfx
