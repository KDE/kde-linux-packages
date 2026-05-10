#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2026 Hadi Chokr <hadichokr@icloud.com>
set -eux

# Detect if we're already inside docker/VM if so, just run directly
if [ -f /.dockerenv ]; then
    echo "Already inside container, running build2-fedora.sh directly"
    ./build2-fedora.sh
    exit $?
fi

# Local run: skip bootstrap.sh (no pacman/systemctl needed), just use docker directly
[ -d /builder ] || sudo mkdir -p /builder

sudo docker run --rm \
  --privileged \
  --volume "$PWD:/work" \
  --volume "/builder:/builder" \
  --workdir /work \
  --env CI_COMMIT_SHORT_SHA="localSHA" \
  --env CI_JOB_ID="localJOB" \
  --env CI_PROJECT_DIR=/work \
  fedora:rawhide \
  bash -c "dnf install -y bash && ./bootstrap-fedora.sh && ./build2-fedora.sh"
