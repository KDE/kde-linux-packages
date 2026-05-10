#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2026 Hadi Chokr <hadichokr@icloud.com>
set -eux

[ -d /builder ] || sudo mkdir -p /builder

sudo docker run --rm \
  --privileged \
  --volume "$CI_PROJECT_DIR:/work" \
  --volume "/builder:/builder" \
  --workdir /work \
  --env CI_COMMIT_SHORT_SHA="${CI_COMMIT_SHORT_SHA}" \
  --env CI_JOB_ID="${CI_JOB_ID}" \
  --env CI_PROJECT_DIR=/work \
  fedora:rawhide \
  bash -c "./bootstrap-fedora.sh && ./build2-fedora.sh"
