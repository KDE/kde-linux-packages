#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2026 Hadi Chokr <hadichokr@icloud.com>
import os
import subprocess
import logging
import urllib.request
import yaml

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_METADATA_BRANCH = os.getenv("REPO_METADATA_BRANCH", "master")
KDE_DEPS_YAML_ARCH = (
    f"https://invent.kde.org/sysadmin/repo-metadata/-/raw/"
    f"{REPO_METADATA_BRANCH}/distro-dependencies/arch.yaml"
)
CI_PROJECT_DIR = os.getenv("CI_PROJECT_DIR", "/work")
DEPS_SENTINEL = "/depsinstalled"
PACMAN_CACHE = "/var/cache/pacman/pkg"


def load_targets():
    path = os.path.join(SCRIPT_DIR, "targets.yaml")
    with open(path) as f:
        return yaml.safe_load(f)["targets"]


def disable_signature_verification():
    logger.info("Disabling pacman signature verification (trusted mirror)...")
    subprocess.run(
        ["sed", "-i", "s/^SigLevel.*/SigLevel = Never/", "/etc/pacman.conf"],
        check=True,
    )


def clear_package_cache():
    """Hard-wipe the pacman cache directory to prevent stale/corrupted packages
    from a previous CI run causing checksum failures at install time."""
    logger.info(f"Wiping pacman package cache at {PACMAN_CACHE}...")
    subprocess.run(f"rm -rf {PACMAN_CACHE}/*", shell=True, check=True)
    os.makedirs(PACMAN_CACHE, exist_ok=True)


def get_all_build_targets(targets):
    logger.info("Querying kde-builder for full resolved module list...")
    result = subprocess.run(
        ["kde-builder", "--query", "project-info"] + targets,
        capture_output=True,
        text=True,
        check=True,
    )
    project_infos = yaml.safe_load(result.stdout)
    if not project_infos:
        raise RuntimeError("kde-builder returned no project info")
    resolved = list(project_infos.keys())
    logger.info(f"Resolved {len(resolved)} modules from kde-builder")
    return resolved


def load_deps_from_yaml(url, targets):
    logger.info(f"Fetching deps from {url}")
    with urllib.request.urlopen(url) as f:
        data = yaml.full_load(f)
    builddeps = set()
    rundeps = set(data.get("common", []))
    projects = data.get("projects", {})
    for target in targets:
        project = projects.get(target, {})
        builddeps.update(project.get("makedepends") or [])
        rundeps.update(project.get("depends") or [])
    return list(builddeps), list(rundeps)


def install_arch(packages):
    packages = list(set(packages))
    cmd = ["pacman", "-S", "--noconfirm", "--needed", "--asdeps"] + packages
    logger.info(f"Installing {len(packages)} packages via pacman")
    result = subprocess.run(cmd)
    if result.returncode != 0:
        raise RuntimeError(f"pacman install failed (exit {result.returncode})")


def main():
    if os.path.exists(DEPS_SENTINEL):
        logger.info("Dependencies already installed, skipping.")
        return

    disable_signature_verification()
    clear_package_cache()

    targets = load_targets()
    all_targets = get_all_build_targets(targets)
    builddeps, rundeps = load_deps_from_yaml(KDE_DEPS_YAML_ARCH, all_targets)

    install_arch(list(set(builddeps + rundeps)))
    clear_package_cache()

    # Write all deps (runtime + build) for the Images Pipeline to consume via mkosi Packages=.
    alldeps = sorted(set(builddeps + rundeps))
    deps_path = os.path.join(CI_PROJECT_DIR, "artifacts", "packages.txt")
    os.makedirs(os.path.dirname(deps_path), exist_ok=True)
    with open(deps_path, "w") as f:
        f.write("\n".join(alldeps) + "\n")
    logger.info(f"Wrote {len(alldeps)} deps to {deps_path}")

    open(DEPS_SENTINEL, "w").close()


if __name__ == "__main__":
    main()
