# SPDX-FileCopyrightText: 2026 Aleix Pol <aleixpol@kde.org>
#
# SPDX-License-Identifier: BSD-2-Clause

kind: cmake

description: Calamares system installer

build-depends:
- freedesktop-sdk.bst:public-stacks/buildsystem-cmake.bst
- freedesktop-sdk.bst:sdk.bst
- kde-buildstream.bst:os/deps-kde.bst
- kde-linux-payload.bst

depends:
- freedesktop-sdk.bst:public-stacks/runtime-minimal.bst

variables:
  cmake-local: >-
    -DBUILD_TESTING=OFF
    -DWITH_QT6=ON

sources:
- kind: git_repo
  url: codeberg:Calamares/calamares.git
  track: calamares
  # exclude:
  # - '*rc*'
  # - '*beta*'
  # - '*alpha*'
  ref: v3.4.2-4-g841b478570c35261cd73e48c5aeb6acefd3db425
- kind: patch
  path: patches/calamares/0001-modules-partition-use-typeForUntranslatedName.patch
