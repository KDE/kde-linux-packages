#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2024 Lasath Fernando <devel@lasath.org>

set -xe

env

# Since the docker imge does not get rebuilt on every run, 
# some packges may be out of date.
sudo pacman --sync --refresh --sysupgrade --noconfirm 

AUR_TARGETS=(
    snapd
    steam-devices-git
    systemd-bootchart

    calamares-git

    paru-bin
    visual-studio-code-bin
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
[banana]
Path = $pkgbuildsDir
EOF

# Paru will build an install the packages in the correct order
paru --sync --needed --noconfirm $packages

#### Create arch repositories to be published as artifacts

artifactsDir=$CI_PROJECT_DIR/artifacts
bananaDir=$artifactsDir/banana
bananaDebugDir=$artifactsDir/banana-debug

# Move the debug packages first so regular packages are easier to find
mkdir -p $bananaDebugDir
ln -f $pkgbuildsDir/*/*-debug-*.pkg.tar.zst $bananaDebugDir
repo-add $bananaDebugDir/banana-debug.db.tar.gz $bananaDebugDir/*.pkg.tar.zst

mkdir -p $bananaDir
ln -f $pkgbuildsDir/*/*.pkg.tar.zst $bananaDir
repo-add $bananaDir/banana.db.tar.gz $bananaDir/*.pkg.tar.zst

# aurutils *really* doesn't like it if the repo is not in pacman.conf
sudo tee -a /etc/pacman.conf <<- EOF
[banana]
SigLevel = Never
Server = file://$bananaDir
EOF
sudo pacman --sync --refresh

# This fetches from AUR, builds and adds to our repo in one command :D
aur sync --no-view --no-confirm --database banana "${AUR_TARGETS[@]}"

# Gitlab artifacts does not seem to like symlinks so we make copies
find $artifactsDir -type l | while read file; do
    cp --remove-destination "$(dirname $file)/$(readlink $file)" $file
done
