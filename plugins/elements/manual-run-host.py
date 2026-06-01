# SPDX-License-Identifier: BSD-2-Clause
# SPDX-FileCopyrightText: 2026 Harald Sitter <sitter@kde.org>

from buildstream import BuildElement, Sandbox


class ManualRunHostElement(BuildElement):

    BST_MIN_VERSION = "2.7"

    def configure(self, node):
        self.warn("Configuring manual-run-host element")
        super().configure(node)

    def preflight(self):
        self.warn("Preflighting manual-run-host element")
        super().preflight()

    def get_unique_key(self):
        self.warn("Getting unique key for manual-run-host element")
        return super().get_unique_key()

    def configure_sandbox(self, sandbox):
        self.warn("Configuring sandbox for manual-run-host element")
        super().configure_sandbox(sandbox)

    def stage(self, sandbox: Sandbox):
        self.warn("Staging manual-run-host element")

        sandbox.mark_directory("/run/host")
        sandbox._set_mount_source("/run/host", "/tmp/host")

        super().stage(sandbox)

    def assemble(self, sandbox):
        self.warn("Assembling manual-run-host element")
        return super().assemble(sandbox)


def setup():
    return ManualRunHostElement
