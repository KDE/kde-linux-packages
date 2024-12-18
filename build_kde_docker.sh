#!/bin/sh

# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL

# SPDX-FileCopyrightText: 2024 Lasath Fernando <devel@lasath.org>

set -ex

CONTAINER_RUNTIME="docker"
PODMAN_RUN_OPT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --podman)
            CONTAINER_RUNTIME="podman"
            PODMAN_RUN_OPT="--userns=keep-id"
            # podman doesn't create mount points automatically
            mkdir -p "$(pwd)/pacman-cache"
            shift
            ;;
        *)
            break
            ;;
    esac
done

$CONTAINER_RUNTIME build --build-arg PROJECT_DIR=/work/src -t banana-builder .

# Build inside docker
$CONTAINER_RUNTIME run -it \
  --volume "$(pwd):/work/src" \
  --volume "$(pwd)/pacman-cache:/var/cache/pacman/pkg" \
  --env CI_PROJECT_DIR=/work/src \
  --workdir /work/src \
  --rm=true \
  ${PODMAN_RUN_OPT} \
  banana-builder "$@"
