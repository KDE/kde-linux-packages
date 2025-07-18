#!/usr/bin/python3
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only OR LicenseRef-KDE-Accepted-GPL
# SPDX-FileCopyrightText: 2024 Lasath Fernando <devel@lasath.org>

# kde-builder should already be in the path
import datetime
import logging.config
import multiprocessing
import os
import subprocess
import logging
import requests
import yaml

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

KDE_BUILDER_TARGETS = [
    "dolphin-plugins",
    "ffmpegthumbs",
    "kdeconnect-kde",
    "kdegraphics-thumbnailers",
    "kde-inotify-survey",
    "kdenetwork-filesharing",
    "kimageformats",
    "kio-fuse",
    "kio-gdrive",
    "kpmcore",
    "kunifiedpush",
    "kwalletmanager",
    "partitionmanager",
    "phonon-vlc",
    "pulseaudio-qt",
    "spectacle",
    "workspace",
]

IGNORE_PROJECTS = [
    "cxx-rust-cssparser", # Dependency of Union; not ready for use yet
    "kgamma", # X11-only and we only ship Wayland
    "kwin-x11", # KDE Linux plans on using new technologies when possible
    "packagekit-qt", # To avoid pacman packages showing up in discover
    "oxygen", # KDE Linux is about the future; this old theme is the past
    "oxygen-icons", # KDE Linux is about the future; this old theme is the past
    "oxygen-sounds", # KDE Linux is about the future; this old theme is the past
    "plasma-keyboard", # Still under construction; not ready for use yet
    "plasma-nano", # Not sure why this is needed to begin with
    "selenium-webdriver-at-spi", # Testing only
    "union", # Still under construction; not ready for use yet
    "plymouth-kcm", # Not needed as we have an offcial Plymouth theme
    "qqc2-breeze-style", # Mobile-only; not needed for desktop UX
    "wacomtablet", # X11-only and we only ship Wayland
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
    # Build the KDE-Linux backend of Discover
    "-DBUILD_SystemdSysupdateBackend=ON"
]


CI_PROJECT_DIR = os.getenv("CI_PROJECT_DIR", default=".")
PKGBUILDS_DIR = os.getenv("PKGBUILDS_DIR", default=f"{CI_PROJECT_DIR}/pkgbuilds")


def package_name(project: str):
    # Since we use third party projects from repos,
    # we need to use the original package name.
    if project in third_party_projects:
        return project

    return f"kde-banana-{project}-git"


def to_bash_array(arr: list[str] | set[str]) -> str:
    return " ".join([f'"{dep}"' for dep in arr])


def build_command(project: str, info: dict) -> list[str]:
    if not info["options"]:
        logger.warning(f"No package options for {project}. Assuming cmake build")
        info["options"] = {"cmake-options": ""}

    options = info["options"]
    if "cmake-options" in options:
        return [
            " \\\n\t\t".join(
                [
                    f'cmake -B build -S "{project}"',
                    *EXTRA_CMAKE_OPTIONS,
                    options["cmake-options"],
                ]
            ),
            f"cmake --build build --parallel {multiprocessing.cpu_count() + 1}",
        ]

    # Turns out KDE uses cmake for everything.
    # Without third party projects, this is easy.
    raise Exception(f"Unable to determine build command for {info}")


def package_command(project: str, info: dict) -> str:
    options = info["options"]

    if "cmake-options" in options:
        return "cmake --install build"

    raise Exception(f"Unable to determine package command for {info}")


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
run_kde_builder(["--metadata-only"])

# get project info from kde-builder
result = run_kde_builder(["--query", "project-info"] + KDE_BUILDER_TARGETS)
project_infos = yaml.safe_load(result)

third_party_projects = [
    project
    for project, info in project_infos.items()
    if not info["repository"].startswith("kde:")
] + FORCE_THIRD_PARTY

# This file will be split up into individual repositories
arch_deps_info = {}
with open(
    os.path.expanduser(
        "~/.local/state/sysadmin-repo-metadata/distro-dependencies/arch.yaml"
    ),
    "r",
) as f:
    arch_deps_info = yaml.safe_load(f)

arch_projects = arch_deps_info["projects"]

jobs: list[tuple[subprocess.Popen, str]] = []

build_time: str = datetime.datetime.now().strftime("%Y%m%d%H%M")

for project, info in project_infos.items():
    if project in IGNORE_PROJECTS or project in third_party_projects:
        continue

    if project not in arch_projects:
        raise Exception(f"Missing arch dependencies for {project}")

    pkgname = package_name(project)

    arch_deps = arch_projects[project]
    if not arch_deps:
        raise Exception(f"Missing dependencies for {project}")

    repo: str = info["repository"].replace("kde:", "https://invent.kde.org/")

    optdepends = "\n".join(
        [f'"{dep["dep"]}: {dep["reason"]}"' for dep in arch_deps["optdepends"]]
    )

    depends = [ad for ad in arch_deps["depends"] if ad not in IGNORE_ARCH_DEPS]
    # append the KDE internal dependencies from project-info
    for kde_dep in info["dependencies"]:
        if kde_dep in IGNORE_PROJECTS:
            continue

        if kde_dep in third_party_projects and kde_dep in arch_projects:
            for replace in arch_projects[kde_dep]["replaces"]:
                depends.append(replace)
        else:
            depends.append(package_name(kde_dep))

    pkgbuild = f"""
# Maintainer: KDE Community <http://www.kde.org>

pkgbase={package_name(project)}
pkgname=({pkgname})
pkgver=0
pkgrel=1
url="https://community.kde.org/KDE_Linux"
pkgdesc="Build of {project} for KDE Linux"
arch=('x86_64')
license=('GPL-2.0-only')
groups=(kde-linux banana)
source=("{project}::git+{repo}")
sha256sums=('SKIP')
depends=({to_bash_array(depends)})
makedepends=({to_bash_array(arch_deps["makedepends"])})
optdepends=({optdepends})
provides=({to_bash_array(arch_deps['replaces'] + VIRTUAL_PACKAGES.get(project, []))})
conflicts=({to_bash_array(arch_deps['replaces'])})
replaces=({to_bash_array(arch_deps['replaces'])})

pkgver() {{
  cd "{project}"
  ( set -o pipefail
    git describe --long --abbrev=7 2>/dev/null | sed 's/-/./g;s/\\(g[a-z0-9]\\{{7\\}}\\)$/r{build_time}.\\1/;s|.*/||' ||
    printf "%s.r{build_time}.%s" "$(git rev-list --count HEAD)" "$(git rev-parse --short=7 HEAD)"
  )
}}

build() {{
    {";\n    ".join(build_command(project, info))};
}}

package() {{
    DESTDIR="$pkgdir" {package_command(project, info)};
}}
"""

    project_dir = f"{PKGBUILDS_DIR}/{package_name(project)}"
    os.makedirs(project_dir, exist_ok=True)

    with open(f"{project_dir}/PKGBUILD", "w") as f:
        f.write(pkgbuild)

    # generate .SRCINFO in the background
    jobs.append(
        (
            subprocess.Popen(
                ["makepkg", "--printsrcinfo"],
                cwd=project_dir,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            ),
            project_dir,
        )
    )

# wait for all jobs to finish
for job, project_dir in jobs:
    stdout, stderr = job.communicate()
    if job.returncode != 0:
        raise Exception(f"Error running makepkg ({result}): {stderr}")

    with open(f"{project_dir}/.SRCINFO", "w") as f:
        f.write(stdout)
