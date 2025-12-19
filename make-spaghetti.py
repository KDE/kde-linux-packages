#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2024 Lasath Fernando <devel@lasath.org>
# SPDX-FileCopyrightText: 2025 Harald Sitter <sitter@kde.org>

# kde-builder should already be in the path

import os
import subprocess
import logging
import yaml

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

KDE_BUILDER_TARGETS = [
    "ark",
    "audiocd-kio",
    "dolphin",
    "dolphin-plugins",
    "ffmpegthumbs",
    "kaccounts-providers",
    "kdeconnect-kde",
    "kdegraphics-thumbnailers",
    "kde-inotify-survey",
    "kdenetwork-filesharing",
    "kimageformats",
    "kio-admin",
    "kio-fuse",
    "kio-gdrive",
    "plasma-setup",
    "konsole",
    "kpmcore",
    "kunifiedpush",
    "kwalletmanager",
    "partitionmanager",
    "pulseaudio-qt",
    "spectacle",
    "kf6-support",
    "workspace",
]

IGNORE_PROJECTS = [
    "kgamma", # X11-only and we only ship Wayland
    "kwin-x11", # KDE Linux plans on using new technologies when possible
    "packagekit-qt", # To avoid pacman packages showing up in discover
    "oxygen", # KDE Linux is about the future; this old theme is the past
    "oxygen-icons", # KDE Linux is about the future; this old theme is the past
    "oxygen-sounds", # KDE Linux is about the future; this old theme is the past
    "plasma-nano", # Not sure why this is needed to begin with
    "selenium-webdriver-at-spi", # Testing only
    "plymouth-kcm", # Not needed as we have an offcial Plymouth theme
    "qqc2-breeze-style", # Mobile-only; not needed for desktop UX
    "wacomtablet", # X11-only and we only ship Wayland
    "kde-dev-scripts", # Pretty useless
]

IGNORE_ARCH_DEPS = {
    # Package group with only one package in it
    "phonon-qt6-backend",
}

VIRTUAL_PACKAGES = {"kwallet": ["org.freedesktop.secrets"]}

FORCE_THIRD_PARTY = [
    # Is not output from kde-builder
    # TODO: investigate issue in repo-metadata
    "taglib",
    "zxing-cpp",
    # wayland-protocols is a dependency of kwin and others worth having from git
    "wayland-protocols",
]

EXTRA_CMAKE_OPTIONS = [
    "-G Ninja",
    "-DCMAKE_INSTALL_PREFIX=/usr",
    "-DBUILD_TESTING=OFF",
    "-DCMAKE_INSTALL_LIBEXECDIR=lib",
    "-DWITH_PYTHON_VENDORING=OFF",
    "-DBUILD_PYTHON_BINDINGS=OFF",
    "-DCMAKE_BUILD_TYPE=RelWithDebInfo",
    # CMake 3.31 added new warnings that get triggered a lot with
    # our Extra CMake Modules. Suppress them to avoid exceeding the
    # log size limit.
    # https://cmake.org/cmake/help/latest/policy/CMP0175.html
    "-Wno-dev",
]


CI_PROJECT_DIR = os.getenv("CI_PROJECT_DIR", default=".")
PKGBUILDS_DIR = os.getenv("PKGBUILDS_DIR", default=f"{CI_PROJECT_DIR}/pkgbuilds")


# run kde-builder and capture stdout
def run_kde_builder(args):
    args = ["kde-builder"] + args
    logger.info(f"Running: {' '.join(args)}")
    process = subprocess.run(
        args=args,
        capture_output=True,
        text=True,
    )

    if process.stderr or process.returncode != 0:
        raise Exception(
            f"Error running kde-builder ({process.returncode}): {process.stdout}"
        )

    return process.stdout


# initialize kde-builder
run_kde_builder(["--generate-config"])

kde_builder_config_file_path = f"{os.environ['HOME']}/.config/kde-builder.yaml"
extra_projects_config_file = "extra-projects.yaml"

with open(extra_projects_config_file, 'r') as extras, open(kde_builder_config_file_path, 'a') as base:
    base.write(extras.read())

with open(kde_builder_config_file_path, 'r+') as f:
    config = yaml.full_load(f)
    config['global']['log-dir'] = f'{CI_PROJECT_DIR}/artifacts/logs'
    f.seek(0)
    f.truncate()
    f.write(yaml.dump(config))

with open(kde_builder_config_file_path, 'r') as base:
    logger.info("Using kde-builder config:")
    logger.info(base.read())

run_kde_builder(["--metadata-only"])

# get project info from kde-builder
result = run_kde_builder(["--query", "project-info"] + KDE_BUILDER_TARGETS)
project_infos = yaml.safe_load(result)
if not project_infos or len(project_infos) == 0:
    raise Exception(f"Error parsing project info: {result}")

third_party_projects = []
for project, info in project_infos.items():
    if project in FORCE_THIRD_PARTY:
        continue
    if not info["repository"].startswith("kde:"):
        third_party_projects.append(project)

# This file will be split up into individual repositories
arch_deps_info = {}
with open(
    os.path.expanduser(
        "~/.local/state/sysadmin-repo-metadata/distro-dependencies/arch.yaml"
    ),
    "r",
) as f:
    arch_deps_info = yaml.safe_load(f)

if len(arch_deps_info) == 0:
    raise Exception("Error loading arch dependencies")

arch_projects = arch_deps_info["projects"]

projects_to_build = []
spaghetti = {
    "depends": ["gdb", "elfutils", "meson", "cpio", "ccache"], # some basic deps for our own tools
    "makedepends": [],
}

for project, info in project_infos.items():
    if project in IGNORE_PROJECTS or project in third_party_projects:
        continue

    if project not in arch_projects:
        raise Exception(f"Missing arch dependencies for {project}")

    arch_deps = arch_projects[project]
    if not arch_deps:
        raise Exception(f"Missing dependencies for {project}")

    depends = [ad for ad in arch_deps["depends"] if ad not in IGNORE_ARCH_DEPS]
    make_depends = arch_deps["makedepends"]

    spaghetti["depends"] = spaghetti["depends"] + depends
    spaghetti["makedepends"] = spaghetti["makedepends"] + make_depends
    projects_to_build.append(project)

spaghetti["depends"] = list(set(spaghetti["makedepends"] + spaghetti["depends"]))
spaghetti["makedepends"] = list(set(spaghetti["makedepends"]))

def install():
    args = ["pacman", '--sync', '--noconfirm'] + spaghetti["depends"]
    logger.info(f"Running: {' '.join(args)}")
    process = subprocess.run(
        args=args,
        capture_output=False
    )
    if process.returncode != 0:
        raise Exception(
            f"Error running pacman ({process.returncode}): {process.stdout}"
        )
if not os.path.exists("/depsinstalled"):
    install()
    open("/depsinstalled", "w").close()

def build():
    args = ["kde-builder", "--refresh-build"] + projects_to_build
    logger.info(f"Running: {' '.join(args)}")
    os.environ['PATH'] = f"/work/strip:" + os.environ['PATH']
    process = subprocess.run(
        args=args,
        capture_output=False,
    )
    if process.returncode != 0:
        raise Exception(
            f"Error running kde-builder ({process.returncode}): {process.stdout}"
        )
build()

import json
with open("spaghetti.json", "w") as f:
    f.write(json.dumps(spaghetti, indent=4))
