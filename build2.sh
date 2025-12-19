#!/usr/bin/bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2025 Harald Sitter <sitter@kde.org>

set -eux

[ -d /builder ] || mkdir /builder

if [ -f /.dockerenv ]; then
    export CI_COMMIT_SHORT_SHA=abcSHAdef
    export CI_JOB_ID=123JOBID456
    export CI_PROJECT_DIR=/work
# else
    # curl https://storage.kde.org/kde-linux-packages/testing/ccache/ccache.tar | tar --extract --directory=/builder || true
fi
export CCACHE_DIR="/builder/ccache"
ccache --set-config=max_size=50G

# Set up mirrorlist.
if [ ! -f artifacts/build_date.txt ]; then
    BUILD_DATE=$(date -u -d 'yesterday' +%Y/%m/%d)
    [ -d artifacts ] || mkdir artifacts
    echo "$BUILD_DATE" > "artifacts/build_date.txt"
    echo "Server = https://archive.archlinux.org/repos/${BUILD_DATE}/\$repo/os/\$arch" | sudo tee /etc/pacman.d/mirrorlist
fi
BUILD_DATE=$(cat artifacts/build_date.txt)

if [ ! -f /usr/bin/ninja.orig ]; then
    mv /usr/bin/ninja /usr/bin/ninja.orig
    cp strip/ninja /usr/bin/ninja
fi

rm -rf tree

export CXXFLAGS="-ffile-prefix-map=/builder/src/=/usr/src/debug/"

[ -d $HOME/.config ] || mkdir $HOME/.config
cp kde-builder.yaml.in $HOME/.config/kde-builder.yaml
python ./make-spaghetti.py

RPM_BUILD_ROOT=$PWD/tree/install \
RPM_BUILD_DIR=/builder/build \
RPM_PACKAGE_NAME=kde-linux \
    find-debuginfo \
        -m \
        -i \
        -v \
        --jobs "$(nproc)" \
        --unique-debug-src-base "$CI_COMMIT_SHORT_SHA-$CI_JOB_ID.x86-64" \
        --unique-debug-suffix "-$CI_COMMIT_SHORT_SHA-$CI_JOB_ID.x86-64" \
        "/builder/build"

mkdir -p tree/debug/usr/{lib,src}/
mv tree/install/usr/lib/debug tree/debug/usr/lib/
mv tree/install/usr/src/debug tree/debug/usr/src/

rm -rf upload
mkdir upload
mkdir upload/artifacts
mkdir upload/ccache

cp artifacts/build_date.txt upload/artifacts/
cp spaghetti.json upload/artifacts/

tar --directory=/builder --create --file=upload/ccache/ccache.tar ccache

tar --directory=tree/debug --create --file=upload/artifacts/debug.tar .
mkfs.erofs -zzstd -C65536 -Efragments,ztailpacking --tar=f upload/artifacts/debug.erofs upload/artifacts/debug.tar
zstd --rm --threads="$(nproc)" upload/artifacts/debug.tar -o upload/artifacts/debug.tar.zst

tar --directory=tree/install --create --file=upload/artifacts/install.tar.zst --zstd .

if [ ! -f /.dockerenv ]; then
    git clone --depth=1 https://invent.kde.org/sysadmin/ci-utilities.git
    CI_UTILITIES_DIR="$PWD/ci-utilities"

    # Note that --delete technically allows for a race condition between packages and imaging pipeline, the hope is that the
    # chance is so small that we don't need to care. Should this become a problem we'll need a bespoke vacuuming logic to clean
    # up packages older than X days instead.
    # "$CI_UTILITIES_DIR/sync-s3-folder.py" --mode upload --delete --local "$PWD/" --remote storage.kde.org/kde-linux-packages/testing/ --verbose

    cd "$CI_PROJECT_DIR"
    # Try to prevent the cleanup from erroring out on unexpected content.
    rm --recursive --force upload pkgbuilds artifacts
    git clean -dfx
fi
