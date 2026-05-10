#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2024 Lasath Fernando <devel@lasath.org>
# SPDX-FileCopyrightText: 2025 Harald Sitter <sitter@kde.org>
# SPDX-FileCopyrightText: 2026 Hadi Chokr <hadichokr@icloud.com>
set -eux

pacman --sync --refresh --noconfirm docker
systemctl start docker
