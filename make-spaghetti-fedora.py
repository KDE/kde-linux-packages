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

KDE_BUILDER_TARGETS = [
    "ark",
    "audiocd-kio",
    "auto-chmod",
    "dolphin",
    "dolphin-plugins",
    "ffmpegthumbs",
    "kapsule",
    "kdeconnect-kde",
    "kdegraphics-thumbnailers",
    "kde-inotify-survey",
    "kdenetwork-filesharing",
    "kimageformats",
    "kio-admin",
    "kio-fuse",
    "kio-gdrive",
    "plasma-setup",
    "plasma-wayland-protocols",
    "konlineaccounts",
    "konsole",
    "kpmcore",
    "kunifiedpush",
    "kup",
    "kwalletmanager",
    "package-compatibility-helper",
    "partitionmanager",
    "pulseaudio-qt",
    "selenium-webdriver-at-spi",
    "spectacle",
    "workspace",
]

CI_PROJECT_DIR = os.getenv("CI_PROJECT_DIR", default=".")
KDE_DEPS_YAML = "https://invent.kde.org/sysadmin/repo-metadata/-/raw/master/distro-dependencies/fedora.yaml"


def load_deps_from_yaml(url):
    with urllib.request.urlopen(url) as f:
        data = yaml.full_load(f)
    deps = []
    for pkg in data.values():
        deps.extend(pkg.get("builddeps", []))
    return list(set(deps))


def install(packages):
    packages = list(set(packages))
    logger.info(f"Installing {len(packages)} packages via dnf")
    process = subprocess.run(
        [
            "dnf", "install", "-y",
            "--best",
            "--allowerasing",
            "--skip-unavailable",
            "--skip-broken",
        ] + packages,
        capture_output=False,
    )
    if process.returncode != 0:
        raise Exception(f"dnf install failed ({process.returncode})")


def run_kde_builder(args):
    args = ["kde-builder"] + args
    logger.info(f"Running: {' '.join(args)}")
    process = subprocess.run(args=args, capture_output=True, text=True)
    if process.returncode != 0:
        raise Exception(
            f"kde-builder failed ({process.returncode}): {process.stdout}"
        )
    return process.stdout


# --- kde-builder setup ---
run_kde_builder(["--generate-config"])
kde_builder_config = f"{os.environ['HOME']}/.config/kde-builder.yaml"

with open(kde_builder_config, "r+") as f:
    config = yaml.full_load(f)
    config["global"]["log-dir"] = f"{CI_PROJECT_DIR}/artifacts/logs"
    f.seek(0)
    f.truncate()
    f.write(yaml.dump(config))

run_kde_builder(["--metadata-only"])

# --- Dependency installation ---
if not os.path.exists("/depsinstalled"):
    deps = load_deps_from_yaml(KDE_DEPS_YAML)
    install(deps)
    open("/depsinstalled", "w").close()


# --- Build ---
def build():
    args = ["kde-builder", "--refresh-build"] + KDE_BUILDER_TARGETS
    logger.info(f"Running: {' '.join(args)}")
    os.environ["PATH"] = "/work/strip:" + os.environ["PATH"]
    process = subprocess.run(args=args, capture_output=False)
    if process.returncode != 0:
        raise Exception(f"kde-builder failed ({process.returncode})")

build()
