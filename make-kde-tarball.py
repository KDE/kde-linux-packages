#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2026 Hadi Chokr <hadichokr@icloud.com>
import os
import subprocess
import logging
import yaml

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CI_PROJECT_DIR = os.getenv("CI_PROJECT_DIR", ".")


def load_targets():
    path = os.path.join(SCRIPT_DIR, "targets.yaml")
    with open(path) as f:
        return yaml.safe_load(f)["targets"]


def patch_builder_config(log_dir):
    config_path = os.path.join(os.environ["HOME"], ".config", "kde-builder.yaml")
    with open(config_path) as f:
        config = yaml.full_load(f)
    config["global"]["log-dir"] = log_dir
    with open(config_path, "w") as f:
        f.write(yaml.dump(config))


def build(targets):
    env = os.environ.copy()
    env["PATH"] = "/work/strip:" + env["PATH"]
    args = ["kde-builder", "--refresh-build"] + targets
    logger.info(f"Running: {' '.join(args)}")
    result = subprocess.run(args, env=env)
    if result.returncode != 0:
        raise RuntimeError(f"kde-builder failed (exit {result.returncode})")


def main():
    targets = load_targets()
    patch_builder_config(log_dir=f"{CI_PROJECT_DIR}/artifacts/logs")
    build(targets)


if __name__ == "__main__":
    main()
