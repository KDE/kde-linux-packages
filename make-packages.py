#!/usr/bin/python3

# kde-builder should already be in the path
import logging.config
import os
import subprocess
import logging
import requests
import yaml

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

KDE_BUILDER_TARGETS = [
    "pulseaudio-qt",
    "workspace",
    "dolphin-plugins",
    "ffmpegthumbs",
    "kdegraphics-thumbnailers",
    "kimageformats",
    "kio-fuse",
    "kio-gdrive",
    "kpmcore",
    "spectacle",
    "xwaylandvideobridge",
    "partitionmanager",
    "kde-inotify-survey",
    "kdeconnect-kde",
    "kdenetwork-filesharing",
]

IGNORE_PROJECTS = [
    # Testing only
    "selenium-webdriver-at-spi",
    # Not sure why this is needed to begin with
    "plasma-nano",
    # To avoid pacman packages showing up in discover
    "packagekit-qt",
]

FORCE_THIRD_PARTY = [
    # Is not output from kde-builder
    # TODO: investigate issue in repo-metadata
    "taglib",
    "zxing-cpp",
]

EXTRA_CMAKE_OPTIONS = "-G Ninja -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=RelWithDebInfo"

CI_PROJECT_DIR = os.getenv("CI_PROJECT_DIR", default=".")
PKGBUILDS_DIR = os.getenv("PKGBUILDS_DIR", default=f"{CI_PROJECT_DIR}/pkgbuilds")


def package_name(project: str):
    # Since we use third party projects from repos,
    # we need to use the original package name.
    if project in third_party_projects:
        return project

    return f"kde-banana-{project}-git"


def to_bash_array(arr: list[str]) -> str:
    return " ".join([f'"{dep}"' for dep in arr])


def build_command(project: str, info: dict) -> list[str]:
    options = info["options"]
    if "cmake-options" in options:
        return [
            " ".join(
                [
                    f'cmake -B build -S "{project}"',
                    EXTRA_CMAKE_OPTIONS,
                    options["cmake-options"],
                ]
            ),
            "cmake --build build",
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
dependencies = yaml.safe_load(
    requests.get(
        "https://invent.kde.org/sysadmin/repo-metadata/-/raw/work/lasath/arch-deps/distro-dependencies/arch.yaml",
        verify=True,
    ).content
)

jobs: list[tuple[subprocess.Popen, str]] = []

for project, info in project_infos.items():
    if project in IGNORE_PROJECTS or project in third_party_projects:
        continue

    if project not in dependencies["projects"]:
        logger.warning(f"Skipping missing project {project}")
        continue

    pkgname = package_name(project)

    deps = dependencies["projects"][project]
    if not deps:
        raise Exception(f"Missing dependencies for {project}")

    repo: str = info["repository"].replace("kde:", "https://invent.kde.org/")

    pkgver = os.getenv("CI_COMMIT_SHA", default="local")
    optdepends = "\n".join(
        [f'"{dep["dep"]}: {dep["reason"]}"' for dep in deps["optdepends"]]
    )

    # append the KDE internal dependencies from project-info
    depends = deps["depends"] + [
        package_name(kde_dep)
        for kde_dep in info["dependencies"]
        if not kde_dep in IGNORE_PROJECTS
    ]

    pkgbuild = f"""
# Maintainer: KDE Community <http://www.kde.org>

pkgbase={package_name(project)}
pkgname=({pkgname})
pkgver={pkgver}
pkgrel=1
url="https://community.kde.org/KDE_Linux"
pkgdesc="Build of {project} for KDE Linux"
arch=('x86_64')
license=('GPL-2.0-only')
groups=(kde-linux banana)
source=("{project}::git+{repo}")
sha256sums=('SKIP')
depends=({to_bash_array(depends)})
makedepends=({to_bash_array(deps["makedepends"])})
optdepends=({optdepends})
provides=({to_bash_array(deps['replaces'])})
conflicts=({to_bash_array(deps['replaces'])})
replaces=({to_bash_array(deps['replaces'])})

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
