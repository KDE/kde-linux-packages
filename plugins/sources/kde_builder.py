# SPDX-FileCopyrightText: 2026 Aleix Pol Gonzalez <aleix.pol@codethink.co.uk>
# SPDX-License-Identifier: BSD-2-Clause

import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

from buildstream import Source, SourceError, utils
import yaml


class KdeBuilderSource(Source):
    BST_MIN_VERSION = "2.7"
    BST_REQUIRES_PREVIOUS_SOURCES_FETCH = True
    BST_REQUIRES_PREVIOUS_SOURCES_TRACK = True

    def configure(self, node):
        node.validate_keys(["ref", "state-directory", *Source.COMMON_CONFIG_KEYS])
        self.ref = self._parse_ref(node)
        self.state_directory = node.get_str("state-directory", default="prepared-state")
        self.mirror_root = os.path.join(self.get_mirror_directory(), "snapshots")
        self.manifest_root = os.path.join(self.mirror_root, "manifests")
        os.makedirs(self.mirror_root, exist_ok=True)
        os.makedirs(self.manifest_root, exist_ok=True)

    def preflight(self):
        pass

    def get_unique_key(self):
        return [self.ref, self.state_directory]

    def load_ref(self, node):
        self.ref = self._parse_ref(node)

    def get_ref(self):
        return self.ref

    def set_ref(self, ref, node):
        node["ref"] = self.ref = ref

    def is_resolved(self):
        return self.ref is not None

    def is_cached(self):
        return bool(self.ref) and (
            os.path.isfile(self._manifest_path(self.ref))
            and self._work_tree_matches_manifest(self.ref)
        )

    def track(self, *, previous_sources_dir):
        return self._prepare_snapshot(previous_sources_dir)

    def fetch(self, *, previous_sources_dir):
        if self.is_cached():
            return

        fetched_ref = self._prepare_snapshot(previous_sources_dir)
        if fetched_ref != self.ref and not self.is_cached():
            raise SourceError(
                f"KDE source snapshot changed: expected {self.ref}, got {fetched_ref}. "
                "Run `bst source track kde-linux-payload.bst` again."
            )

    def stage(self, directory):
        if not self.ref:
            raise SourceError("KDE source snapshot is not tracked")

        manifest_path = self._manifest_path(self.ref)
        if not os.path.isfile(manifest_path) or not self._work_tree_matches_manifest(
            self.ref
        ):
            raise SourceError(f"KDE source snapshot is not cached: {self.ref}")

        with self.timed_activity("Staging KDE source snapshot"):
            utils.copy_files(
                os.path.join(self.mirror_root, "work", "state"),
                os.path.join(directory, self.state_directory),
            )

    def _snapshot_dir(self, ref):
        return os.path.join(self.mirror_root, ref)

    def _manifest_path(self, ref):
        return os.path.join(self.manifest_root, f"{ref}.json")

    @staticmethod
    def _parse_ref(node):
        ref = node.get_str("ref", default=None)
        return ref or None

    def _prepare_snapshot(self, previous_sources_dir):
        os.makedirs(self.mirror_root, exist_ok=True)
        payload_candidates = [
            path
            for path in Path(previous_sources_dir).glob("**/kde-builder")
            if path.is_file() and (path.parent / "kde_builder_lib").is_dir()
        ]
        if len(payload_candidates) != 1:
            raise SourceError(
                f"Expected one staged kde-builder executable, found {len(payload_candidates)}"
            )
        payload_root = payload_candidates[0].parent

        work_dir = Path(self.mirror_root) / "work"
        if not work_dir.exists():
            seed_dir = self._seed_snapshot_dir()
            if seed_dir:
                with self.timed_activity("Migrating KDE source snapshot to work tree"):
                    seed_ref, seed_revisions = self._snapshot_ref(seed_dir)
                    self._write_manifest(seed_ref, seed_revisions)
                    work_dir.mkdir()
                    seed_dir.rename(work_dir / "state")
            else:
                leftovers = sorted(
                    Path(self.mirror_root).glob("kde-builder-*"),
                    key=lambda path: path.stat().st_mtime,
                )
                if leftovers:
                    leftovers[-1].rename(work_dir)

        state_dir = work_dir / "state"
        home_dir = work_dir / "home"
        config_dir = home_dir / ".config"
        source_dir = state_dir / "src"
        build_dir = work_dir / "build"
        log_dir = work_dir / "logs"
        config_dir.mkdir(parents=True, exist_ok=True)
        source_dir.mkdir(parents=True, exist_ok=True)
        build_dir.mkdir(parents=True, exist_ok=True)
        log_dir.mkdir(parents=True, exist_ok=True)

        shutil.copyfile(
            payload_root / "kde-linux-payload" / "kde-builder.yaml.in",
            config_dir / "kde-builder.yaml",
        )

        targets_path = payload_root / "kde-linux-payload" / "targets.yaml"
        with targets_path.open(encoding="utf-8") as stream:
            targets = yaml.safe_load(stream)["targets"]

        env = os.environ.copy()
        env["HOME"] = str(home_dir)
        env["XDG_STATE_HOME"] = str(state_dir)
        common_args = [
            str(payload_root / "kde-builder"),
            "--rc-file",
            str(config_dir / "kde-builder.yaml"),
            "--no-color",
            "--source-dir",
            str(source_dir),
            "--build-dir",
            str(build_dir),
            "--log-dir",
            str(log_dir),
        ]
        fetch_log = log_dir / "kde-builder-fetch.log"
        with self.timed_activity("Fetching KDE sources with kde-builder", silent_nested=True):
            try:
                self._run(
                    [*common_args, "--src-only", *targets],
                    env=env,
                    log_path=fetch_log,
                    progress_dir=source_dir,
                    check=True,
                )
            except subprocess.CalledProcessError as error:
                raise SourceError(
                    f"kde-builder failed to fetch KDE sources; see {fetch_log}"
                ) from error

        snapshot_ref, revisions = self._snapshot_ref(state_dir)
        self._write_manifest(snapshot_ref, revisions)
        return snapshot_ref

    def _seed_snapshot_dir(self):
        if self.ref:
            snapshot_dir = Path(self._snapshot_dir(self.ref))
            if snapshot_dir.is_dir():
                return snapshot_dir

        snapshots = [
            path
            for path in Path(self.mirror_root).iterdir()
            if path.is_dir() and self._is_snapshot_ref(path.name)
        ]
        if not snapshots:
            return None

        return max(snapshots, key=lambda path: path.stat().st_mtime)

    def _write_manifest(self, ref, revisions):
        manifest_path = Path(self._manifest_path(ref))
        if manifest_path.exists():
            return

        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        with manifest_path.open("w", encoding="utf-8") as stream:
            json.dump(revisions, stream, sort_keys=True, separators=(",", ":"))

    def _read_manifest(self, ref):
        with open(self._manifest_path(ref), encoding="utf-8") as stream:
            return json.load(stream)

    def _work_tree_matches_manifest(self, ref):
        state_dir = Path(self.mirror_root) / "work" / "state"
        if not state_dir.is_dir():
            return False

        revisions = self._read_manifest(ref)
        for relative_path, revision in revisions.items():
            repository = state_dir / relative_path
            if not (repository / ".git").is_dir():
                return False
            try:
                current = subprocess.run(
                    ["git", "-C", str(repository), "rev-parse", "HEAD"],
                    check=True,
                    stdout=subprocess.PIPE,
                    text=True,
                ).stdout.strip()
            except subprocess.CalledProcessError:
                return False
            if current != revision:
                return False

        return True

    @staticmethod
    def _is_snapshot_ref(value):
        return len(value) == 64 and all(
            character in "0123456789abcdef" for character in value
        )

    @staticmethod
    def _snapshot_ref(state_dir):
        revisions = {}
        for git_dir in KdeBuilderSource._repository_git_dirs(state_dir):
            repository = git_dir.parent
            relative_path = repository.relative_to(state_dir).as_posix()
            try:
                revision = subprocess.run(
                    ["git", "-C", str(repository), "rev-parse", "HEAD"],
                    check=True,
                    stdout=subprocess.PIPE,
                    text=True,
                ).stdout.strip()
            except subprocess.CalledProcessError as error:
                raise SourceError(f"Failed to read Git revision for {relative_path}") from error
            revisions[relative_path] = revision

        if not revisions:
            raise SourceError("kde-builder did not fetch any Git repositories")

        manifest = json.dumps(revisions, sort_keys=True, separators=(",", ":")).encode()
        return hashlib.sha256(manifest).hexdigest(), revisions

    def _run(self, args, **kwargs):
        check = kwargs.pop("check", False)
        log_path = kwargs.pop("log_path", None)
        progress_dir = kwargs.pop("progress_dir", None)
        log = None
        try:
            if log_path:
                self.status(f"Writing kde-builder fetch log to {log_path}")
                log = log_path.open("w", encoding="utf-8")
                kwargs["stdout"] = log
                kwargs["stderr"] = subprocess.STDOUT

            process = subprocess.Popen(args, start_new_session=True, **kwargs)
            try:
                if progress_dir:
                    last_count = None
                    while process.poll() is None:
                        count = self._repository_count(progress_dir)
                        if count != last_count:
                            self.status(f"KDE source repositories fetched: {count}")
                            last_count = count
                        time.sleep(5)
                    stdout = None
                else:
                    stdout, _ = process.communicate()
            except KeyboardInterrupt:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                raise
            finally:
                if progress_dir:
                    process.wait()
        finally:
            if log:
                log.close()

        returncode = process.returncode
        if check and returncode:
            raise subprocess.CalledProcessError(returncode, args)

        return subprocess.CompletedProcess(args, returncode, stdout=stdout)

    @staticmethod
    def _repository_count(directory):
        return len(KdeBuilderSource._repository_git_dirs(Path(directory).parent))

    @staticmethod
    def _repository_git_dirs(state_dir):
        source_dir = Path(state_dir) / "src"
        if not source_dir.is_dir():
            source_dir = Path(state_dir)
        return sorted(
            path / ".git"
            for path in source_dir.iterdir()
            if (path / ".git").is_dir()
        )


def setup():
    return KdeBuilderSource
