# SPDX-FileCopyrightText: 2025 Aleix Pol Gonzalez <aleix.pol@codethink.co.uk>
# SPDX-License-Identifier: BSD-2-Clause

kind: junction

sources:
- kind: git_repo
  url: invent:sitter/kde-buildstream.git
  track: master
  ref: b524fde39c2b7237a36d6fcb607b4daf969faa6a

config:
  overrides:
    plugins/buildstream-plugins-community.bst: plugins/buildstream-plugins-community.bst
