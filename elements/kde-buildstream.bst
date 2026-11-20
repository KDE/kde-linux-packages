# SPDX-FileCopyrightText: 2025 Aleix Pol Gonzalez <aleix.pol@codethink.co.uk>
# SPDX-License-Identifier: BSD-2-Clause

kind: junction

sources:
- kind: git_repo
  url: invent:sitter/kde-buildstream.git
  track: master
  ref: ee0596eed22fe46a45c357ee976022c47088f9e2

config:
  overrides:
    plugins/buildstream-plugins-community.bst: plugins/buildstream-plugins-community.bst
