#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2024 Lasath Fernando <devel@lasath.org>
# SPDX-FileCopyrightText: 2026 Hadi Chokr <hadichokr@icloud.com>
set -ex

CONTAINER_RUNTIME="docker"

while [ $# -gt 0 ]; do
    case "$1" in
        --podman)
            CONTAINER_RUNTIME="podman"
            mkdir -p "$(pwd)/pacman-cache"
            shift
            ;;
        *)
            break
            ;;
    esac
done

mkdir -p /builder

$CONTAINER_RUNTIME run \
  --privileged \
  --rm \
  --volume "$(pwd):/work" \
  --volume "/builder:/builder" \
  --volume "$(pwd)/pacman-cache:/var/cache/pacman/pkg" \
  --env CI_PROJECT_DIR=/work \
  --env LOCAL_BUILD=1 \
  --workdir /work \
  archlinux:latest \
  sh -c "${@:- ./bootstrap.sh && ./build.sh}"
