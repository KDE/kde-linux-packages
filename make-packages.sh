#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2024 Lasath Fernando <devel@lasath.org>

# -u being missing is on purpose, as it would blow up on CDN_UPLOAD_KEY
# being missing, which is sometimes intentional
set -xe

echo "BUILDENV=(!distcc color ccache check !sign)" > "$HOME/.makepkg.conf"

curl --location https://github.com/archlinux/aur/archive/refs/heads/paru.tar.gz | tar xz
cd aur-paru
makepkg --noconfirm --syncdeps --install
cd ..

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

    snapd
    steam-devices-git
)

pkgbuildsDir=$CI_PROJECT_DIR/pkgbuilds
packages=()

systemd_version=$(pacman -Q --info systemd |grep -E 'Version\s+:(.+)' | cut --delimiter=: --fields=2 | xargs)
git clone --branch "$systemd_version" https://gitlab.archlinux.org/archlinux/packaging/packages/systemd "$pkgbuildsDir/systemd"

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

for package in "${AUR_TARGETS[@]}"; do
    rm -rf "${pkgbuildsDir:?}/$package"
    git clone --branch "$package" --single-branch https://github.com/archlinux/aur.git "$pkgbuildsDir/$package"
done
packages+=" ${AUR_TARGETS[*]}"

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

mkdir "$CI_PROJECT_DIR/upload"
cd "$CI_PROJECT_DIR/upload"
mv "$artifactsDir" repo # rename
