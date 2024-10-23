#!/bin/sh

# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL

# SPDX-FileCopyrightText: 2024 Lasath Fernando <devel@lasath.org>

set -ex

docker build --build-arg PROJECT_DIR=/work/src -t banana-builder .

# Build inside docker
docker run -it \
  --volume "$(pwd):/work/src" \
  --volume "$(pwd)/pacman-cache:/var/cache/pacman/pkg" \
  --env CI_PROJECT_DIR=/work/src \
  --workdir /work/src \
  --rm=true \
  banana-builder "$@"
