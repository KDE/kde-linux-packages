#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2024 Lasath Fernando <devel@lasath.org>

set -xe

env

pkgbuildsDir=$CI_PROJECT_DIR/pkgbuilds

kde-builder --generate-config

skipPackages=(
    "packagekit-qt"
)

# To unblock the build. Will investigate and fix later
useSystemPackages=(
    "gpgme"
)

# These can move into repo-metadata when this issue is resolved:
# https://invent.kde.org/sysadmin/repo-metadata/-/issues/12
declare -A extraTargets
extraTargets=(
    ["gpgme"]="libgpgme.so qgpgme-qt6"
    ["qca"]="qca-qt5 qca-qt6"
    ["poppler"]="poppler-qt6 poppler-qt5"
    ["qtkeychain"]="qtkeychain-qt6"
    ["phonon"]="phonon-qt5"
)
declare -A extraDeps
extraDeps=(
    ["krdp"]="freerdp2"
    ["discover"]="fwupd"
    ["kio-extras"]="smbclient"
    ["selenium"]="python-atspi"
    ["kdenetwork-filesharing"]="samba"
    ["spectacle"]="opencv"
)

packages=''

AUR_TARGETS=(
    snapd
    steam-devices-git
    systemd-bootchart
)

KDE_BUILDER_TARGET=(
    "pulseaudio-qt"
    "workspace"
    "dolphin-plugins"
    "ffmpegthumbs"
    "kdegraphics-thumbnailers"
    "kimageformats"
    "kio-fuse"
    "kio-gdrive"
    "kpmcore"
    "spectacle"
    "xwaylandvideobridge"
    "partitionmanager"
    "kde-inotify-survey"
    "kdeconnect-kde"
    "kdenetwork-filesharing"

    "phonon-vlc"
)
allTargets=$(kde-builder --query branch "${KDE_BUILDER_TARGET[@]}" | cut -d':' -f1)

toRemove=(
    # we don't build skanlite
    poppler-glib sane

    # stop discover discovering arch packagekit backend
    packagekit
)

sudo pacman --remove --noconfirm ${toRemove[@]}

for target in $allTargets; do
    if [[ "${skipPackages[@]}" =~ $target || "${useSystemPackages[@]}" =~ $target ]]; then
        continue
    fi

    package="kde-banana-$target-git"

    targetDir=$pkgbuildsDir/$package
    # skip if the package has successfully built
    if compgen -G "$targetDir/*.pkg.tar.zst" > /dev/null; then
        continue
    fi

    mkdir -p $targetDir

    pkgver=${CI_COMMIT_SHA:-local}
    dependencies=$(
        kde-builder --query branch $target |
            cut -d':' -f1 |
            while read dep; do
                # Skip the target itself
                [ "$dep" == "$target" ] && continue

                if [[ "${skipPackages[@]}" =~ $dep ]]; then
                    continue
                fi

                if [[ "${useSystemPackages[@]}" =~ $dep ]]; then
                    echo -n "$dep "
                    continue
                fi

                # skip phonon-vlc from phonon to avoid a circular dependency
                if [ "$target" == "phonon" ] && [ "$dep" == "phonon-vlc" ]; then
                    continue
                fi

                echo -n "kde-banana-$dep-git "
            done
    )

    conflicts="$target ${extraTargets[$target]}"

    # Phonon is actually a group containing phonon and phonon-vlc
    # This tells kde-builder to build the project phonon
    if [ "$target" == "phonon" ]; then
        target="kdesupport/phonon"
    fi

    kdeBuilderArgs=(
        --no-include-dependencies
        --persistent-data-file \$srcdir/kde-builder-persistent-data
        --cmake-options -DCMAKE_CXX_FLAGS=-DQT_FORCE_ASSERTS
        --install-dir /usr
        --source-dir \$srcdir/src
        --build-dir \$srcdir/build
        --log-dir $CI_PROJECT_DIR/logs
    )

    cat << EOF > $targetDir/PKGBUILD
        pkgname=$package
        pkgver=$pkgver
        pkgrel=1
        pkgdesc="Build of $target for KDE Linux"
        arch=('x86_64')
        url=https://kde.org/kde-linux
        license=('GPL-2.0-only')
        groups=(banana)
        source=()
        sha256sums=()
        depends=($dependencies ${extraDeps[$target]})
        replaces=($conflicts)
        provides=($conflicts)
        conflicts=($conflicts)

        prepare() {
            kde-builder \
                ${kdeBuilderArgs[@]} \
                --src-only \
                $target
        }

        build() {
            kde-builder \
                ${kdeBuilderArgs[@]} \
                --no-src \
                --no-install \
                $target
        }

        package() {
            DESTDIR=\$pkgdir kde-builder \
                ${kdeBuilderArgs[@]} \
                --install-only $target
        }
EOF

done

# Assume all directories in pkgbuildsDir are packages to build
# We have to do this because some targets like `workspace` are
# not actually packages.
packages=$(basename -a $pkgbuildsDir/kde-banana-*)

# Install already built packages in parallel for a speedup (except debug packages)
alreadyBuiltPackages="$(find $pkgbuildsDir -name '*.pkg.tar.zst' | grep -v -- '-git-debug-' || true)"
echo "Reusing already built packages: $alreadyBuiltPackages"
if [ -n "$alreadyBuiltPackages" ]; then
    yes | sudo pacman -U $alreadyBuiltPackages
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
yes | paru --sync --needed $packages

#### Create arch repositories to be published as artifacts

artifactsDir=$CI_PROJECT_DIR/artifacts
bananaDir=$artifactsDir/banana
bananaDebugDir=$artifactsDir/banana-debug

# Move the debug packages first so regular packages are easier to find
mkdir -p $bananaDebugDir
mv $pkgbuildsDir/*/*-debug-*.pkg.tar.zst $bananaDebugDir
repo-add $bananaDebugDir/banana-debug.db.tar.gz $bananaDebugDir/*.pkg.tar.zst

mkdir -p $bananaDir
ln $pkgbuildsDir/*/*.pkg.tar.zst $bananaDir
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
