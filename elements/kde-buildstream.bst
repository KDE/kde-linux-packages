# SPDX-FileCopyrightText: 2025 Aleix Pol Gonzalez <aleix.pol@codethink.co.uk>
# SPDX-License-Identifier: BSD-2-Clause

kind: junction

sources:
- kind: git_repo
  url: invent:sitter/kde-buildstream.git
  track: master
  ref: abb1c22e6d8727f4a20315e44056cfaea1910039

config:
  overrides:
    plugins/buildstream-plugins-community.bst: plugins/buildstream-plugins-community.bst
