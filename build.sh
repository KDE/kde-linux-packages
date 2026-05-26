#!/usr/bin/bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2026 Hadi Chokr <hadichokr@icloud.com>
set -eux

mkdir -p /builder

if [ -f /.dockerenv ]; then
    export CI_COMMIT_SHORT_SHA=abcSHAdef
    export CI_JOB_ID=123JOBID456
    export CI_PROJECT_DIR=/work
fi

if [ ! -f /.dockerenv ]; then
    # In CI, pull a warm ccache from object storage to speed up the build.
    curl --fail https://storage.kde.org/kde-linux-packages/testing/ccache/ccache.tar \
        | tar --extract --directory=/builder || true
fi

export CCACHE_DIR="/builder/ccache"
ccache --set-config=max_size=50G

export KDE_LINUX_INSTALL_DESTDIR="$PWD/tree/install"

# Wrap ninja with the strip shim so debug info is stripped during install.
if [ ! -f /usr/bin/ninja.orig ]; then
    mv /usr/bin/ninja /usr/bin/ninja.orig
    cp strip/ninja /usr/bin/ninja
fi

rm -rf tree
export CXXFLAGS="-ffile-prefix-map=/builder/src/=/usr/src/debug/"

mkdir -p "$HOME/.config"
cp kde-builder.yaml.in "$HOME/.config/kde-builder.yaml"
kde-builder --generate-config
kde-builder --metadata-only

# ------------------------------------------------------
# WARNING! THIS IS DISTRO-SPECIFIC
python ./install-kde-deps.py
# ------------------------------------------------------

python ./make-kde-tarball.py

RPM_BUILD_ROOT=$PWD/tree/install \
RPM_BUILD_DIR=/builder/build \
RPM_PACKAGE_NAME=kde-linux \
    find-debuginfo \
        -m -i -v \
        --jobs "$(nproc)" \
        --unique-debug-src-base "$CI_COMMIT_SHORT_SHA-$CI_JOB_ID.x86-64" \
        --unique-debug-suffix "-$CI_COMMIT_SHORT_SHA-$CI_JOB_ID.x86-64" \
        "/builder/build"

mkdir -p tree/debug/usr/{lib,src}/
mv tree/install/usr/lib/debug tree/debug/usr/lib/
mv tree/install/usr/src/debug tree/debug/usr/src/

rm -rf upload
mkdir -p upload/artifacts upload/ccache

tar --directory=/builder --create --file=upload/ccache/ccache.tar ccache
tar --directory=tree/debug --create --file=upload/artifacts/debug.tar .

mkfs.erofs -zzstd -C65536 -Efragments,ztailpacking --tar=f \
    upload/artifacts/debug.erofs upload/artifacts/debug.tar

zstd --rm --threads="$(nproc)" upload/artifacts/debug.tar \
    -o upload/artifacts/debug.tar.zst

# Only ship kde-builder output.
# The Images Pipeline uses packages.txt to install runtime deps via mkosi.
tar --directory=tree/install --create \
    --file=upload/artifacts/install.tar.zst --zstd .

# Copy packages list artifact
cp "$CI_PROJECT_DIR/artifacts/packages.txt" upload/artifacts/packages.txt

if [ ! -f /.dockerenv ]; then
    git clone --depth=1 https://invent.kde.org/sysadmin/ci-utilities.git
    CI_UTILITIES_DIR="$PWD/ci-utilities"
    "$CI_UTILITIES_DIR/sync-s3-folder.py" --mode upload --delete --local "$PWD/upload/" --remote storage.kde.org/kde-linux-packages/testing/ --verbose
    cd "$CI_PROJECT_DIR"
    rm --recursive --force upload pkgbuilds
    git clean -dfx --exclude=artifacts
fi
