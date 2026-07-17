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
    logger.info("Querying kde-builder for true build targets (respecting ignore list)...")
    result = subprocess.run(
        ["kde-builder", "--include-dependencies", "--no-stop-on-failure", "--pretend"] + targets,
        capture_output=True,
        text=True,
    )
    if result.stderr:
        logger.debug("kde-builder stderr:\n%s", result.stderr)
    resolved = []
    for line in result.stdout.splitlines():
        if "Building " in line:
            part = line.split("Building ", 1)[1]
            module = part.split()[0]
            module = module.split("/")[-1]
            resolved.append(module)
    if not resolved:
        logger.error("kde-builder stdout:\n%s", result.stdout)
        logger.error("kde-builder stderr:\n%s", result.stderr)
        raise RuntimeError(
            f"kde-builder --pretend returned no buildable modules (exit {result.returncode})"
        )
    logger.info(f"Resolved {len(resolved)} modules from kde-builder: {', '.join(resolved)}")
    return resolved


def load_deps_from_yaml(url, targets):
    logger.info(f"Fetching deps from {url}")
    with urllib.request.urlopen(url) as f:
        data = yaml.full_load(f)

    builddeps = set()
    rundeps = set(data.get("common", []))
    projects = data.get("projects", {})

    built_packages = set()
    module_dep_map = {}
    for target in targets:
        project = projects.get(target, {})
        target_builddeps = project.get("makedepends") or []
        target_rundeps = project.get("depends") or []
        target_replaces = project.get("replaces") or []

        builddeps.update(target_builddeps)
        rundeps.update(target_rundeps)
        built_packages.add(target)
        built_packages.update(target_replaces)

        if target_builddeps or target_rundeps:
            module_dep_map[target] = {
                "makedepends": sorted(target_builddeps),
                "depends": sorted(target_rundeps),
                "replaces": sorted(target_replaces),
            }

    # Log per-module dep breakdown
    logger.info("=== Per-module dependency breakdown ===")
    for module, deps in sorted(module_dep_map.items()):
        parts = []
        if deps["depends"]:
            parts.append(f"depends=[{', '.join(deps['depends'])}]")
        if deps["makedepends"]:
            parts.append(f"makedepends=[{', '.join(deps['makedepends'])}]")
        if deps["replaces"]:
            parts.append(f"replaces=[{', '.join(deps['replaces'])}]")
        logger.info(f"  {module}: {' | '.join(parts)}")
    logger.info("=== End of per-module breakdown ===")

    return list(builddeps), list(rundeps), built_packages


def install_arch(packages):
    packages = list(set(packages))
    # supremely awesome hack to make the build succeed with part of python pips installed from pip and the other from pacman
    # this either needs fixing properly or we need to move to buildstream!
    subprocess.run(["sh", "-c", "rm -rfv /usr/lib/python*/site-packages/{psutil,click}*"], check=True)
    cmd = ["pacman", "-S", "--noconfirm", "--needed", "--asdeps"] + packages
    logger.info(f"Installing {len(packages)} packages via pacman: {', '.join(sorted(packages))}")
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
    builddeps, rundeps, built_packages = load_deps_from_yaml(KDE_DEPS_YAML_ARCH, all_targets)
    install_arch(list(set(builddeps + rundeps)))
    clear_package_cache()

    # Write only runtime deps for the Images Pipeline to consume via mkosi Packages=.
    alldeps = sorted(set(rundeps) - built_packages)
    if built_packages:
        logger.info(
            f"Excluding {len(built_packages)} built-from-source package(s) from packages.txt: "
            + ", ".join(sorted(built_packages))
        )
    deps_path = os.path.join(CI_PROJECT_DIR, "artifacts", "packages.txt")
    os.makedirs(os.path.dirname(deps_path), exist_ok=True)
    with open(deps_path, "w") as f:
        f.write("\n".join(alldeps) + "\n")
    logger.info(f"Wrote {len(alldeps)} runtime deps to {deps_path}")

    open(DEPS_SENTINEL, "w").close()


if __name__ == "__main__":
    main()
