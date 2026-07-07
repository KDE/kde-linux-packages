#!/usr/bin/bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2026 Hadi Chokr <hadichokr@icloud.com>

set -eux

export CI_PROJECT_DIR="${CI_PROJECT_DIR:-$PWD}"
export KDECI_BUILD="${KDECI_BUILD:-FALSE}"

rm -rf tree upload

HOST_PID=""
if [ "$KDECI_BUILD" = "TRUE" ]; then
    # Set up cache overrides
    mkdir --parents ~/.config
    cp buildstream.conf ~/.config/buildstream.conf
    set +x
    echo "$BST_CACHE_TOKEN" > /tmp/bst-cache-token
    set -x

    # Start a reverse proxy from a unix socket to the real ccache server.
    # This is a bit complicated because buildstream really doesn't want to let us poke into the sandbox.
    # We'll create a host dir in tmp. This will be mounted into the sandbox via a somewhat naughty bst plugin.
    # Inside the sandbox we stand up another reverse proxy so ccache knows this is http.
    # Basically
    #   ccache(sandbox) -> caddy(sandbox) -> socket (mounted) -> caddy(host) -> real.ccache.server
    #
    # host does act as a general interaction point in this set up as we also want a way to collect logs from the kde-builder stage anyway.
    # Mind that this only applies to the payload.bst, the other elements are all built as per usual bst constraints (e.g. no network during build).
    ./host.sh &
    HOST_PID=$!
fi

function finish {
    set +e
    if [ "$HOST_PID" != "" ]; then
        kill ${HOST_PID} || true
    fi

    [ -d artifacts ] || mkdir artifacts
    cp --recursive /tmp/host/kde-builder-logs artifacts/
    cp --recursive ~/.cache/buildstream/logs artifacts/buildstream-logs
}
trap finish EXIT INT ABRT TERM

bst source track kde-linux-payload.bst
# Make sure most of everything will be in the cache for the imaging pipeline.
# Bit of a hack until we move things here.
bst build \
    kde-linux.bst:os/deps.bst \
    kde-linux.bst:os/deps-core.bst \
    kde-linux.bst:os/deps-kde.bst \
    kde-linux.bst:freedesktop-sdk.bst:components/ovmf-maybe.bst \
    kde-linux.bst:freedesktop-sdk.bst:vm/prepare-image.bst \
    kde-linux.bst:components/calamares.bst \
    kde-linux-payload.bst

if [ "$KDECI_BUILD" = "TRUE" ]; then
    kill ${HOST_PID} || true
fi

[ -d artifacts ] || mkdir artifacts

# Only ship the KDE payload. Build dependencies are provided by the image pipeline.
bst artifact checkout kde-linux-payload.bst --deps none --directory tree/install

mkdir --parents upload/artifacts
mkdir --parents upload/repo

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

S3_REMOTE="storage.kde.org/kde-linux-packages/testing/"

if [ "${CI_COMMIT_BRANCH:-}" != "master" ]; then
    S3_REMOTE="storage.kde.org/ci-artifacts/$CI_PROJECT_PATH/j/$CI_JOB_ID/testing"
fi

if [ ! -f /.dockerenv ]; then
    # Keep the images pipeline on the same KDE Linux package mirror version.
    cp "$CI_PROJECT_DIR/artifacts/build_repo.txt" upload/repo/build_repo.txt

    git clone --depth=1 https://invent.kde.org/sysadmin/ci-utilities.git
    CI_UTILITIES_DIR="$PWD/ci-utilities"
    "$CI_UTILITIES_DIR/sync-s3-folder.py" --mode upload --delete --local "$PWD/upload/" --remote "$S3_REMOTE" --verbose
    cd "$CI_PROJECT_DIR"
    rm --recursive --force upload pkgbuilds
    git clean -dfx --exclude=artifacts
fi
