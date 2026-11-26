# SPDX-FileCopyrightText: 2025 Aleix Pol Gonzalez <aleix.pol@codethink.co.uk>
# SPDX-License-Identifier: BSD-2-Clause

kind: junction

sources:
- kind: git_repo
  url: invent:sitter/kde-buildstream.git
  track: master
  ref: 83fadb7ad8589811d5c66e92345cdfd96c78486c

config:
  overrides:
    plugins/buildstream-plugins-community.bst: plugins/buildstream-plugins-community.bst
