#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2024 Lasath Fernando <devel@lasath.org>

set -xe

curl https://storage.kde.org/kde-linux-packages/testing/ccache/ccache.tar | tar -x || true
sudo ccache --set-config=max_size=50G
ccache --set-config=max_size=50G
export CCACHE_DIR="$HOME/ccache"
ccache --set-config=max_size=50G
echo "BUILDENV=(!distcc color ccache check !sign)" >> "$HOME/.makepkg.conf"

# Install paru-bin from AUR
git clone https://aur.archlinux.org/paru-bin.git /tmp/paru-bin
cd /tmp/paru-bin
makepkg --noconfirm --syncdeps --install
cd ..

# Set up mirrorlist.
BUILD_DATE=$(date -u -d 'yesterday' +%Y/%m/%d)
[ -d artifacts ] || mkdir artifacts
echo "$BUILD_DATE" > "artifacts/build_date.txt"
echo "Server = https://archive.archlinux.org/repos/${BUILD_DATE}/\$repo/os/\$arch"| sudo tee /etc/pacman.d/mirrorlist

sudo pacman --sync --refresh --refresh --sysupgrade --noconfirm

AUR_TARGETS=(
    fenrir-git
)

pkgbuildsDir=$CI_PROJECT_DIR/pkgbuilds
PKGBUILDS_DIR="$pkgbuildsDir" ./make-pkgbuilds.py

packages=$(basename -a $pkgbuildsDir/kde-banana-*)

# Install already built packages in parallel
alreadyBuiltPackages="$(find $pkgbuildsDir -name '*.pkg.tar.zst' | grep -v -- '-git-debug-' || true)"
echo "Reusing already built packages: $alreadyBuiltPackages"
if [ -n "$alreadyBuiltPackages" ]; then
    sudo pacman --upgrade --noconfirm --needed $alreadyBuiltPackages
fi

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

# -----------------------------------------------------------------
# Build shadow
git clone https://gitlab.archlinux.org/archlinux/packaging/packages/shadow "$pkgbuildsDir/shadow"
cd "$pkgbuildsDir/shadow"

if ! grep -q "pkgver=4.18.0" PKGBUILD; then
    echo "ERROR: shadow package in Arch has been updated. Please remove this version bump code."
    exit 1
fi

# Set new version
sed -i 's/pkgver=.*/pkgver=4.19.4/' PKGBUILD

# Replace checksum arrays with SKIP
sed -i '/^sha512sums=/,/^)/c\sha512sums=('\''SKIP'\'')' PKGBUILD
sed -i '/^b2sums=/,/^)/c\b2sums=('\''SKIP'\'')' PKGBUILD

# Clear validpgpkeys array to avoid PGP errors
sed -i '/^validpgpkeys=/,/^)/c\validpgpkeys=()' PKGBUILD

cd -
paru --pkgbuilds --sync --noconfirm --mflags="--skippgpcheck" shadow
# -----------------------------------------------------------------

# Build systemd (with extra options)
MESON_EXTRA_CONFIGURE_OPTIONS=-Dsysupdated=enabled \
    paru --pkgbuilds --sync --noconfirm --mflags="--skippgpcheck --nocheck" systemd

# Remove old iptables
sudo pacman --remove --nodeps --nodeps --noconfirm iptables

# Build banana packages
paru --sync --needed --noconfirm $packages

#### Create arch repositories for artifacts
artifactsDir=$CI_PROJECT_DIR/artifacts
packagesDir=$artifactsDir/packages
packagesDebugDir=$artifactsDir/packages-debug

mkdir -p $packagesDebugDir
mv $pkgbuildsDir/*/*-debug-*.pkg.tar.zst $packagesDebugDir
repo-add $packagesDebugDir/kde-linux-debug.db.tar.gz $packagesDebugDir/*.pkg.tar.zst

mkdir -p $packagesDir
mv $pkgbuildsDir/*/*.pkg.tar.zst $packagesDir
repo-add $packagesDir/kde-linux.db.tar.gz $packagesDir/*.pkg.tar.zst

sudo tee -a /etc/pacman.conf <<- EOF
[kde-linux]
SigLevel = Never
Server = file://$packagesDir
EOF
sudo pacman --sync --refresh

if [ -z "$CDN_UPLOAD_KEY" ]; then
    echo "No CDN_UPLOAD_KEY found, skipping upload"
    exit 0
fi

chmod 600 "$CDN_UPLOAD_KEY"
CDN_UPLOAD_URL="$CDN_UPLOAD_ACCOUNT:/srv/www/cdn.kde.org/kde-linux/packaging"

rsync --archive --verbose --compress \
    --rsh="ssh -o StrictHostKeyChecking=no -i $CDN_UPLOAD_KEY" \
    $artifactsDir/ $CDN_UPLOAD_URL

cd
git clone --depth=1 https://invent.kde.org/sysadmin/ci-utilities.git
CI_UTILITIES_DIR="$PWD/ci-utilities"

mkdir "$CI_PROJECT_DIR/upload"
cd "$CI_PROJECT_DIR/upload"
mv "$artifactsDir" repo
mkdir ccache
tar --directory="$HOME" --create --file=ccache/ccache.tar ccache

pip install minio --break-system-packages

"$CI_UTILITIES_DIR/sync-s3-folder.py" --mode upload --delete --local "$PWD/" --remote storage.kde.org/kde-linux-packages/testing/ --verbose

cd "$CI_PROJECT_DIR"
rm --recursive --force upload pkgbuilds artifacts
git clean -dfx