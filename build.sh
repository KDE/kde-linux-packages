#!/usr/bin/bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2026 Hadi Chokr <hadichokr@icloud.com>
set -eux

export CI_PROJECT_DIR="${CI_PROJECT_DIR:-$PWD}"

rm -rf tree upload
mkdir -p ccache

if [ ! -f /.dockerenv ]; then
    curl --fail https://storage.kde.org/kde-linux-packages/testing/ccache/ccache.tar \
        | tar --extract --directory=ccache --strip-components=1 || true
fi

bst source track kde-linux-payload.bst
bst build kde-linux-payload.bst

# Only ship the KDE payload. Build dependencies are provided by the image pipeline.
bst artifact checkout kde-linux-payload.bst --deps none --directory tree/install

mkdir -p upload/artifacts upload/ccache upload/repo

tar --directory=tree/install/.kde-linux-payload-cache \
    --create --file=upload/ccache/ccache.tar ccache
rm -rf tree/install/.kde-linux-payload-cache

mkdir -p tree/debug/usr/{lib,src}/
mv tree/install/usr/lib/debug tree/debug/usr/lib/
mv tree/install/usr/src/debug tree/debug/usr/src/

tar --directory=tree/debug --create --file=upload/artifacts/debug.tar .

mkfs.erofs -zzstd -C65536 -Efragments,ztailpacking --tar=f \
    upload/artifacts/debug.erofs upload/artifacts/debug.tar

zstd --rm --threads="$(nproc)" upload/artifacts/debug.tar \
    -o upload/artifacts/debug.tar.zst

tar --directory=tree/install --create \
    --file=upload/artifacts/install.tar.zst --zstd .


if [ ! -f /.dockerenv ] && [ "${CI_COMMIT_BRANCH:-}" = "master" ]; then
    # Keep the images pipeline on the same KDE Linux package mirror version.
    cp "$CI_PROJECT_DIR/artifacts/build_repo.txt" upload/repo/build_repo.txt

    git clone --depth=1 https://invent.kde.org/sysadmin/ci-utilities.git
    CI_UTILITIES_DIR="$PWD/ci-utilities"
    "$CI_UTILITIES_DIR/sync-s3-folder.py" --mode upload --delete --local "$PWD/upload/" --remote storage.kde.org/kde-linux-packages/testing/ --verbose
    cd "$CI_PROJECT_DIR"
    rm --recursive --force upload pkgbuilds
    git clean -dfx --exclude=artifacts
fi
