#!/usr/bin/env python3
"""A deliberately small, fail-closed Restic executor for recovery units."""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import pwd
import grp
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import uuid


IDENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
AWS_KEYS = frozenset({"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_REGION", "AWS_DEFAULT_REGION", "AWS_CA_BUNDLE", "AWS_SHARED_CREDENTIALS_FILE", "AWS_CONFIG_FILE"})
MAX_JSON = 8 * 1024 * 1024
UTC = dt.timezone.utc


class Failure(Exception):
    pass


def require(ok: bool, message: str) -> None:
    if not ok:
        raise Failure(message)


def identifier(value: object) -> str:
    require(isinstance(value, str) and IDENT.fullmatch(value) is not None, "invalid identifier")
    return value


def digest(value: object) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    with tmp.open("x", encoding="utf-8") as out:
        os.chmod(tmp, 0o600)
        json.dump(value, out, sort_keys=True, separators=(",", ":"))
        out.flush()
        os.fsync(out.fileno())
    os.replace(tmp, path)


def read_json(path: Path) -> object:
    with path.open("rb") as inp:
        data = inp.read(MAX_JSON + 1)
    require(len(data) <= MAX_JSON, "metadata too large")
    return json.loads(data)


def command(value: object) -> list[str]:
    words = [value] if isinstance(value, str) else value
    require(isinstance(words, list) and bool(words) and all(isinstance(x, str) and x for x in words), "invalid command")
    require(Path(words[0]).is_absolute(), "command executable must be absolute")
    return words


def now() -> dt.datetime:
    return dt.datetime.now(UTC)


def timestamp(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC)


def safe_env() -> dict[str, str]:
    return {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LANG": "C", "LC_ALL": "C", "TZ": "UTC"}


def run(argv: list[str], env: dict[str, str], timeout: int, *, json_output: bool = False,
        user: int | None = None, group: int | None = None, cwd: str | None = None) -> object | None:
    # Never relay child stdout/stderr: Restic may print repository URLs or credentials.
    try:
        with tempfile.TemporaryFile() as output:
            result = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL, stdout=output if json_output else subprocess.DEVNULL,
                                    stderr=subprocess.DEVNULL, timeout=timeout, check=False, cwd=cwd,
                                    **({"user": user, "group": group, "extra_groups": []} if user is not None else {}))
            require(result.returncode == 0, "subprocess failed")
            if json_output:
                require(output.tell() <= MAX_JSON, "subprocess output too large")
                output.seek(0)
                return json.load(output)
    except (OSError, subprocess.TimeoutExpired, ValueError, json.JSONDecodeError) as exc:
        raise Failure("subprocess unavailable, timed out, or returned invalid output") from None
    return None


def stop_group(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    # The leader may have exited while a descendant remains in its group.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


class Executor:
    def __init__(self, path: Path):
        cfg = read_json(path)
        require(isinstance(cfg, dict), "invalid config")
        self.state = Path(cfg["stateDirectory"])
        require(self.state.is_absolute() and not self.state.is_symlink(), "invalid state directory")
        self.units = cfg["units"]
        self.destinations = cfg["destinations"]
        self.policy = cfg.get("policy", {})
        require(isinstance(self.units, dict) and self.units and isinstance(self.destinations, dict) and self.destinations, "empty units or destinations")
        require(isinstance(self.policy, dict), "invalid policy")
        for unit, spec in self.units.items():
            identifier(unit)
            require(isinstance(spec, dict) and spec.get("contractVersion") == 1 and isinstance(spec.get("formatVersion"), str) and bool(spec["formatVersion"]), "unsupported recovery contract")
            identifier(spec["formatVersion"])
            command(spec.get("captureCommand"))
            command(spec.get("validateCommand"))
        for dest, spec in self.destinations.items():
            identifier(dest)
            require(isinstance(spec, dict) and isinstance(spec.get("repository"), str) and bool(spec["repository"]), "invalid destination")
            require(not re.search(r"://[^/\s]*@", spec["repository"]), "repository URL contains userinfo")
            require(isinstance(spec.get("passwordFile"), str) and Path(spec["passwordFile"]).is_absolute(), "invalid password file")
        self.state.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.state, 0o700)

    @contextlib.contextmanager
    def locked(self, name: str):
        identifier(name)
        directory = self.state / "locks"
        directory.mkdir(mode=0o700, exist_ok=True)
        with (directory / (name + ".lock")).open("a+b") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Failure("another reliability operation is active") from None
            yield

    def lease_current(self):
        with self.locked("capture"):
            manifest = self.current()
            lock = (self.state / "generations" / manifest["id"] / ".lease").open("a+b")
            try:
                fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
            except BaseException:
                lock.close()
                raise
            return manifest, lock

    def timeout(self, key: str, default: int) -> int:
        value = self.policy.get(key, default)
        require(type(value) is int and 1 <= value <= 86400, "invalid timeout")
        return value

    def restic_env(self, dest: str) -> dict[str, str]:
        spec = self.destinations[dest]
        env = safe_env()
        env["RESTIC_PASSWORD_FILE"] = spec["passwordFile"]
        env["RESTIC_REPOSITORY"] = spec["repository"]
        source = spec.get("environmentFile")
        if source:
            require(Path(source).is_absolute(), "invalid environment file")
            for line in Path(source).read_text(encoding="utf-8").splitlines():
                if not line or line.startswith("#"):
                    continue
                key, sep, value = line.partition("=")
                require(sep == "=" and key in AWS_KEYS and "\x00" not in value, "unsupported environment key")
                require(key not in env, "duplicate environment key")
                env[key] = value
        if spec.get("rcloneConfigFile"):
            require(Path(spec["rcloneConfigFile"]).is_absolute(), "invalid rclone config")
            env["RCLONE_CONFIG"] = spec["rcloneConfigFile"]
        return env

    def restic(self, dest: str, args: list[str], *, json_output: bool = False, timeout_key: str = "backupTimeoutSeconds") -> object | None:
        return run(["restic", "--no-cache", *args], self.restic_env(dest), self.timeout(timeout_key, 7200), json_output=json_output)

    def repository_id(self, dest: str) -> str:
        cfg = self.restic(dest, ["cat", "config"], json_output=True)
        require(isinstance(cfg, dict) and isinstance(cfg.get("id"), str), "repository identity unavailable")
        return cfg["id"]

    def current(self) -> dict:
        generation = read_json(self.state / "current.json")
        require(isinstance(generation, dict) and generation.get("units") == {k: self.units[k]["formatVersion"] for k in sorted(self.units)}, "capture does not match selected units")
        identifier(generation.get("id"))
        base = self.state / "generations" / generation["id"]
        require(base.is_dir() and not base.is_symlink(), "capture generation missing")
        for unit in self.units:
            require((base / unit).is_dir() and not (base / unit).is_symlink(), "capture unit missing")
        return generation

    def capture(self) -> dict:
        max_bytes = self.policy.get("maxStagingBytes", 10 * 1024**3)
        require(type(max_bytes) is int and max_bytes > 0, "invalid staging quota")
        self.collect_generations()
        existing_bytes = self.staging_bytes()
        generation_id = uuid.uuid4().hex
        capture_started = now().isoformat()
        root = self.state / "generations"
        root.mkdir(mode=0o700, exist_ok=True)
        staged = Path(tempfile.mkdtemp(prefix=".staging-", dir=root))
        try:
            total = 0
            for unit in sorted(self.units):
                target = staged / unit
                target.mkdir(mode=0o700)
                self.run_capture([*command(self.units[unit]["captureCommand"]), str(target)], staged,
                                 existing_bytes, max_bytes)
                require(any(target.iterdir()), "capture produced no files")
                for dirpath, dirs, files in os.walk(target, followlinks=False):
                    for name in dirs + files:
                        path = Path(dirpath) / name
                        require(not path.is_symlink(), "capture contains symlink")
                        if path.is_file():
                            total += path.stat().st_size
                            require(existing_bytes + total <= max_bytes, "staging quota exceeded")
                write_json(target / "reliability-manifest.json", {"generation": generation_id, "capturedAt": capture_started,
                                                                   "unit": unit, "formatVersion": self.units[unit]["formatVersion"]})
                require(self.staging_bytes() <= max_bytes, "staging quota exceeded")
            manifest = {"id": generation_id, "capturedAt": capture_started, "completedAt": now().isoformat(),
                        "units": {k: self.units[k]["formatVersion"] for k in sorted(self.units)}}
            write_json(staged / "manifest.json", manifest)
            require(self.staging_bytes() <= max_bytes, "staging quota exceeded")
            os.replace(staged, root / generation_id)
            write_json(self.state / "current.json", manifest)
            self.collect_generations()
            return {"generation": generation_id, "capturedAt": manifest["capturedAt"], "units": len(self.units)}
        finally:
            if staged.exists():
                shutil.rmtree(staged)

    def run_capture(self, argv: list[str], staged: Path, existing_bytes: int, max_bytes: int) -> None:
        timeout = self.timeout("captureTimeoutSeconds", 3600)
        # Reserve capacity for unrelated OS writes as well as polling overshoot.
        reserve = min(max_bytes // 10, 256 * 1024 * 1024)
        try:
            process = subprocess.Popen(argv, env=safe_env(), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, start_new_session=True)
        except OSError:
            raise Failure("capture producer unavailable") from None
        deadline = time.monotonic() + timeout
        try:
            while True:
                used = 0
                for dirpath, dirs, files in os.walk(staged, followlinks=False):
                    for name in dirs + files:
                        path = Path(dirpath) / name
                        require(not path.is_symlink(), "capture contains symlink")
                        try:
                            if path.is_file():
                                used += path.stat().st_size
                        except FileNotFoundError:
                            # Producers may atomically replace temporary files.
                            continue
                require(existing_bytes + used <= max_bytes and shutil.disk_usage(staged).free > reserve,
                        "staging quota exceeded")
                code = process.poll()
                if code is not None:
                    require(code == 0, "subprocess failed")
                    return
                require(time.monotonic() < deadline, "capture producer timed out")
                time.sleep(0.05)
        except BaseException:
            stop_group(process)
            raise
        finally:
            # A producer is not allowed to leave child writers behind after exit.
            stop_group(process)

    def staging_bytes(self) -> int:
        total = 0
        root = self.state / "generations"
        if root.exists():
            for dirpath, dirs, files in os.walk(root, followlinks=False):
                for name in dirs + files:
                    path = Path(dirpath) / name
                    require(not path.is_symlink(), "staging contains symlink")
                    if path.is_file():
                        total += path.stat().st_size
        return total

    def collect_generations(self) -> None:
        root = self.state / "generations"
        if not root.exists():
            return
        current = read_json(self.state / "current.json")["id"] if (self.state / "current.json").exists() else None
        for path in root.iterdir():
            require(path.is_dir() and not path.is_symlink(), "invalid staging entry")
            if path.name.startswith(".staging-"):
                shutil.rmtree(path)
                continue
            if path.name == current:
                continue
            identifier(path.name)
            with (path / ".lease").open("a+b") as lease:
                try:
                    fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                manifest = read_json(path / "manifest.json")
                require(manifest.get("id") == path.name, "staging manifest mismatch")
                shutil.rmtree(path)

    def snapshots(self, dest: str) -> list[dict]:
        result = self.restic(dest, ["snapshots", "--json"], json_output=True)
        require(isinstance(result, list), "invalid snapshot listing")
        return result

    def tagged(self, snapshot: dict) -> tuple[str, str, str] | None:
        tags = snapshot.get("tags", [])
        if "reliability:v1" not in tags:
            return None
        def one(prefix: str) -> str:
            matches = [x[len(prefix):] for x in tags if isinstance(x, str) and x.startswith(prefix)]
            require(len(matches) == 1, "ambiguous snapshot tags")
            return identifier(matches[0])
        return one("unit:"), one("format:"), one("generation:")

    def complete(self, snapshots: list[dict], generation: str) -> dict[str, dict]:
        found: dict[str, dict] = {}
        for snapshot in snapshots:
            tagged = self.tagged(snapshot)
            if tagged is None or tagged[2] != generation:
                continue
            unit, format_version, _ = tagged
            require(unit in self.units and format_version == self.units[unit]["formatVersion"] and unit not in found, "unknown or duplicate lineage")
            found[unit] = snapshot
        require(set(found) == set(self.units), "incomplete repository generation")
        return found

    def backup(self, dest: str, manifest: dict) -> dict:
        snapshots = self.snapshots(dest)
        base = self.state / "generations" / manifest["id"]
        for unit in sorted(self.units):
            matching = [s for s in snapshots if self.tagged(s) == (unit, self.units[unit]["formatVersion"], manifest["id"])]
            require(len(matching) <= 1, "duplicate unit snapshot")
            marker = self.state / "attempts" / manifest["id"] / (dest + "-" + unit + ".json")
            require(not marker.exists(), "prior unit upload did not complete cleanly")
            if matching:
                continue
            write_json(marker, {"generation": manifest["id"], "destination": dest, "unit": unit})
            self.restic(dest, ["backup", "--time", timestamp(manifest["capturedAt"]).strftime("%Y-%m-%d %H:%M:%S"), "--tag", "reliability:v1", "--tag", "unit:" + unit,
                               "--tag", "format:" + self.units[unit]["formatVersion"], "--tag", "generation:" + manifest["id"], str(base / unit)])
            marker.unlink()
        complete = self.complete(self.snapshots(dest), manifest["id"])
        evidence = {"generation": manifest["id"], "capturedAt": manifest["capturedAt"], "repositoryId": self.repository_id(dest),
                    "repositoryFingerprint": digest(self.destinations[dest]["repository"]),
                    "snapshots": {unit: complete[unit]["id"] for unit in sorted(self.units)}, "recordedAt": now().isoformat()}
        write_json(self.state / "commits" / dest / (manifest["id"] + ".json"), evidence)
        write_json(self.state / "evidence" / dest / "backup.json", evidence)
        return {"destination": dest, "generation": manifest["id"], "units": len(complete)}

    def check(self, dest: str, read_data: bool) -> dict:
        backup = read_json(self.state / "evidence" / dest / "backup.json")
        require(backup.get("repositoryFingerprint") == digest(self.destinations[dest]["repository"]), "backup evidence destination changed")
        self.complete(self.snapshots(dest), backup["generation"])
        self.restic(dest, ["check", *(["--read-data"] if read_data else [])], timeout_key="checkTimeoutSeconds")
        evidence = {"repositoryId": self.repository_id(dest), "repositoryFingerprint": backup["repositoryFingerprint"],
                    "generation": backup["generation"], "recordedAt": now().isoformat(), "readData": read_data}
        write_json(self.state / "evidence" / dest / "check.json", evidence)
        return {"destination": dest, "generation": backup["generation"], "readData": read_data}

    def validate(self, unit: str, restored: Path, scratch: Path) -> None:
        executable = command(self.units[unit]["validateCommand"])
        require(executable[0].startswith("/nix/store/"), "validator must reside in Nix store")
        bwrap = shutil.which("bwrap")
        require(bool(bwrap), "bubblewrap unavailable")
        require(os.geteuid() == 0, "restore validation requires privileged orchestrator")
        try:
            user = pwd.getpwnam("reliability-validator")
            group = grp.getgrnam("reliability-validator")
        except KeyError:
            raise Failure("validator account unavailable") from None
        require(user.pw_uid != 0 and group.gr_gid != 0, "validator account must be unprivileged")
        require(not restored.is_symlink(), "restored source contains symlink")
        # Do not follow links or expose any other part of the restore scratch tree.
        for dirpath, dirs, files in os.walk(restored, followlinks=False):
            for name in dirs + files:
                path = Path(dirpath) / name
                require(not path.is_symlink(), "restored source contains symlink")
                os.chown(path, user.pw_uid, group.gr_gid, follow_symlinks=False)
        os.chown(restored, user.pw_uid, group.gr_gid, follow_symlinks=False)
        ancestor = restored.parent
        while True:
            require(ancestor == scratch or scratch in ancestor.parents, "restore path escaped scratch")
            require(not ancestor.is_symlink(), "restore path contains symlink")
            os.chown(ancestor, user.pw_uid, group.gr_gid, follow_symlinks=False)
            os.chmod(ancestor, 0o700)
            if ancestor == scratch:
                break
            ancestor = ancestor.parent
        run([bwrap, "--unshare-all", "--die-with-parent", "--new-session", "--ro-bind", "/nix/store", "/nix/store",
             "--ro-bind", str(restored), "/input", "--tmpfs", "/tmp", "--dev", "/dev", "--proc", "/proc", "--chdir", "/",
             "--clearenv", *executable, "/input"], {}, self.timeout("restoreTimeoutSeconds", 7200),
            user=user.pw_uid, group=group.gr_gid, cwd="/")

    def restore_check(self, dest: str) -> dict:
        backup = read_json(self.state / "evidence" / dest / "backup.json")
        require(backup.get("repositoryFingerprint") == digest(self.destinations[dest]["repository"]), "backup evidence destination changed")
        snapshots = self.complete(self.snapshots(dest), backup["generation"])
        for unit in sorted(self.units):
            snap = snapshots[unit]
            paths = snap.get("paths")
            require(isinstance(paths, list) and len(paths) == 1 and isinstance(paths[0], str) and paths[0].startswith("/"), "unsupported snapshot path")
            with tempfile.TemporaryDirectory(prefix="reliability-restore-", dir="/var/tmp") as scratch:
                self.restic(dest, ["restore", snap["id"], "--target", scratch], timeout_key="restoreTimeoutSeconds")
                restored = Path(scratch) / paths[0].lstrip("/")
                require(restored.is_dir(), "restored source missing")
                self.validate(unit, restored, Path(scratch))
        evidence = {"repositoryId": self.repository_id(dest), "repositoryFingerprint": backup["repositoryFingerprint"],
                    "generation": backup["generation"], "recordedAt": now().isoformat()}
        write_json(self.state / "evidence" / dest / "restore.json", evidence)
        return {"destination": dest, "generation": backup["generation"], "validatedUnits": len(self.units)}

    def maintenance_guard(self, dest: str) -> tuple[list[dict], dict]:
        require(self.policy.get("maintenanceEnabled") is True, "maintenance disabled")
        expected = self.destinations[dest].get("expectedRepositoryId")
        require(isinstance(expected, str) and len(expected) == 64 and re.fullmatch(r"[a-f0-9]+", expected) is not None, "expected repository ID missing")
        require(self.repository_id(dest) == expected, "repository identity mismatch")
        ceiling = self.policy.get("maintenanceDeletionCeiling", 0)
        minimum = self.policy.get("maintenanceMinimumSnapshotsPerUnit", 2)
        require(type(ceiling) is int and ceiling > 0 and type(minimum) is int and minimum >= 2, "maintenance limits missing")
        ev = self.state / "evidence" / dest
        backup, check, restore = (read_json(ev / (name + ".json")) for name in ("backup", "check", "restore"))
        require(all(x.get("repositoryId") == expected and x.get("repositoryFingerprint") == digest(self.destinations[dest]["repository"])
                    for x in (backup, check, restore)), "maintenance evidence mismatch")
        require((now() - timestamp(backup["capturedAt"])) <= dt.timedelta(hours=18), "backup evidence stale")
        require((now() - timestamp(check["recordedAt"])) <= dt.timedelta(days=8), "check evidence stale")
        require((now() - timestamp(restore["recordedAt"])) <= dt.timedelta(days=35), "restore evidence stale")
        snapshots = self.snapshots(dest)
        require(bool(snapshots), "empty repository")
        attempts = self.state / "attempts"
        if attempts.exists():
            for marker in attempts.glob("*/*.json"):
                attempt = read_json(marker)
                require(isinstance(attempt, dict) and isinstance(attempt.get("destination"), str), "invalid upload attempt marker")
                require(attempt["destination"] != dest, "unresolved upload attempt")
        committed: dict[str, tuple[str, str]] = {}
        commit_dir = self.state / "commits" / dest
        require(commit_dir.is_dir(), "no committed recovery points")
        for file in commit_dir.glob("*.json"):
            entry = read_json(file)
            require(isinstance(entry, dict) and entry.get("repositoryId") == expected and
                    entry.get("repositoryFingerprint") == digest(self.destinations[dest]["repository"]), "commit identity mismatch")
            generation = identifier(entry.get("generation"))
            require(file.stem == generation and isinstance(entry.get("snapshots"), dict) and
                    set(entry["snapshots"]) == set(self.units), "invalid committed recovery point")
            for unit, snapshot_id in entry["snapshots"].items():
                require(isinstance(snapshot_id, str) and re.fullmatch(r"[a-f0-9]{64}", snapshot_id) and
                        snapshot_id not in committed, "invalid committed snapshot ID")
                committed[snapshot_id] = (unit, generation)
        require(bool(committed), "no committed recovery points")
        for snap in snapshots:
            tags = self.tagged(snap)
            require(tags is not None and tags[0] in self.units and tags[1] == self.units[tags[0]]["formatVersion"], "unmanaged or unknown lineage")
            require(snap.get("id") in committed and committed[snap["id"]] == (tags[0], tags[2]),
                    "uncommitted repository snapshot")
        require(set(committed) == {snap.get("id") for snap in snapshots}, "committed snapshot missing")
        self.complete(snapshots, backup["generation"])
        self.complete(snapshots, check["generation"])
        self.complete(snapshots, restore["generation"])
        return snapshots, {"ceiling": ceiling, "minimum": minimum, "expected": expected}

    def scope_fingerprint(self, dest: str) -> str:
        return digest({"units": {unit: self.units[unit]["formatVersion"] for unit in sorted(self.units)},
                       "destination": dest, "repositoryId": self.destinations[dest].get("expectedRepositoryId"),
                       "retention": self.policy.get("retention")})

    def maintenance_plan(self, dest: str) -> dict:
        snapshots, guard = self.maintenance_guard(dest)
        retention = self.policy.get("retention", {})
        require(isinstance(retention, dict), "invalid retention")
        keys = {"keepWithin": "--keep-within", "keepWithinDaily": "--keep-within-daily", "keepWithinWeekly": "--keep-within-weekly", "keepWithinMonthly": "--keep-within-monthly"}
        args = []
        for field, flag in keys.items():
            value = retention.get(field)
            require(isinstance(value, str) and re.fullmatch(r"[1-9][0-9]*[ydmh]", value) is not None, "invalid retention policy")
            args.extend((flag, value))
        remove: list[str] = []
        for unit in sorted(self.units):
            groups = self.restic(dest, ["forget", "--dry-run", "--json", "--group-by", "", "--tag", "reliability:v1,unit:" + unit, *args], json_output=True)
            require(isinstance(groups, list), "invalid maintenance preview")
            for group in groups:
                for snap in group.get("remove") or []:
                    require(isinstance(snap, dict) and isinstance(snap.get("id"), str), "invalid preview snapshot")
                    remove.append(snap["id"])
        require(len(remove) == len(set(remove)) and len(remove) <= guard["ceiling"], "deletion ceiling exceeded")
        removed = set(remove)
        by_generation: dict[str, set[str]] = {}
        for snap in snapshots:
            generation = self.tagged(snap)[2]
            by_generation.setdefault(generation, set()).add(snap["id"])
        require(all(not (ids & removed) or ids <= removed for ids in by_generation.values()),
                "retention would split a recovery point")
        by_unit = {u: 0 for u in self.units}
        for snap in snapshots:
            by_unit[self.tagged(snap)[0]] += snap["id"] not in remove
        require(all(count >= guard["minimum"] for count in by_unit.values()), "minimum snapshots violated")
        plan = {"destination": dest, "repositoryId": guard["expected"], "snapshotIds": sorted(s["id"] for s in snapshots),
                "removeIds": sorted(remove), "scopeFingerprint": self.scope_fingerprint(dest),
                "recordedAt": now().isoformat()}
        write_json(self.state / "maintenance" / (dest + ".json"), plan)
        return {"destination": dest, "plannedRemovals": len(remove), "planFingerprint": digest(plan), "scopeFingerprint": plan["scopeFingerprint"]}

    def maintenance_apply(self, dest: str) -> dict:
        require(self.policy.get("maintenanceCommissioned") is True and
                self.destinations[dest].get("maintenancePolicyFingerprint") == self.scope_fingerprint(dest), "maintenance scope not commissioned")
        saved = read_json(self.state / "maintenance" / (dest + ".json"))
        require(isinstance(saved, dict) and saved.get("destination") == dest and now() - timestamp(saved["recordedAt"]) <= dt.timedelta(hours=1), "maintenance plan missing or stale")
        old_hash = digest(saved)
        current = self.maintenance_plan(dest)
        fresh = read_json(self.state / "maintenance" / (dest + ".json"))
        require({k: v for k, v in saved.items() if k != "recordedAt"} == {k: v for k, v in fresh.items() if k != "recordedAt"}, "maintenance plan changed")
        ids = saved["removeIds"]
        if ids:
            self.restic(dest, ["forget", *ids], timeout_key="backupTimeoutSeconds")
            for generation, snapshots in self.committed_generations(dest).items():
                if set(snapshots.values()) <= set(ids):
                    (self.state / "commits" / dest / (generation + ".json")).unlink()
            self.restic(dest, ["prune"], timeout_key="backupTimeoutSeconds")
        return {"destination": dest, "removedSnapshots": len(ids), "planFingerprint": old_hash}

    def committed_generations(self, dest: str) -> dict[str, dict[str, str]]:
        commits = {}
        for file in (self.state / "commits" / dest).glob("*.json"):
            entry = read_json(file)
            commits[entry["generation"]] = entry["snapshots"]
        return commits

    def maintenance_run(self, dest: str) -> dict:
        require(self.policy.get("maintenanceCommissioned") is True and
                self.destinations[dest].get("maintenancePolicyFingerprint") == self.scope_fingerprint(dest), "maintenance scope not commissioned")
        self.maintenance_plan(dest)
        return self.maintenance_apply(dest)

    def status(self, metrics_file: Path | None) -> dict:
        warning = self.policy.get("warningAgeHours", 18)
        critical = self.policy.get("criticalAgeHours", 24)
        require(type(warning) is int and type(critical) is int and 0 < warning < critical, "invalid freshness thresholds")
        result = {}
        lines = ["# HELP reliability_backup_age_seconds Age of latest complete capture by destination",
                 "# TYPE reliability_backup_age_seconds gauge",
                 "# HELP reliability_backup_severity 0 healthy, 1 warning, 2 critical",
                 "# TYPE reliability_backup_severity gauge"]
        for dest in sorted(self.destinations):
            file = self.state / "evidence" / dest / "backup.json"
            if file.exists() and read_json(file).get("repositoryFingerprint") == digest(self.destinations[dest]["repository"]):
                evidence = read_json(file)
                captured = evidence.get("capturedAt")
                require(isinstance(captured, str), "invalid backup evidence")
                raw_age = int((now() - timestamp(captured)).total_seconds())
                require(raw_age >= -300, "backup evidence is from the future")
                age = max(0, raw_age)
                severity = 2 if age >= critical * 3600 else 1 if age >= warning * 3600 else 0
                check = self.state / "evidence" / dest / "check.json"
                restore = self.state / "evidence" / dest / "restore.json"
                entry = {"capturedAt": captured, "backupAgeSeconds": age, "severity": severity,
                         "checkedAt": read_json(check).get("recordedAt") if check.exists() else None,
                         "restoredAt": read_json(restore).get("recordedAt") if restore.exists() else None}
                lines.append(f'reliability_backup_age_seconds{{destination="{dest}"}} {age}')
            else:
                severity = 2
                entry = {"capturedAt": None, "backupAgeSeconds": None, "severity": severity, "checkedAt": None, "restoredAt": None}
            result[dest] = entry
            lines.append(f'reliability_backup_severity{{destination="{dest}"}} {severity}')
        if metrics_file is not None:
            require(metrics_file.is_absolute() and not metrics_file.is_symlink(), "invalid metrics path")
            metrics_file.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
            tmp = metrics_file.with_name(metrics_file.name + "." + uuid.uuid4().hex + ".tmp")
            try:
                with tmp.open("x", encoding="ascii") as output:
                    os.chmod(tmp, 0o644)
                    output.write("\n".join(lines) + "\n")
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(tmp, metrics_file)
            finally:
                tmp.unlink(missing_ok=True)
        return {"destinations": result}


def main() -> int:
    parser = argparse.ArgumentParser(prog="reliability")
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("action", choices=("capture", "backup", "check", "restore-check", "maintenance-plan", "maintenance-apply", "maintenance-run", "status"))
    parser.add_argument("destination", nargs="?")
    parser.add_argument("--read-data", action="store_true")
    parser.add_argument("--metrics-file", type=Path)
    args = parser.parse_args()
    try:
        executor = Executor(args.config)
        require((args.action in ("capture", "status")) == (args.destination is None), "destination required only for repository actions")
        require(not args.read_data or args.action == "check", "--read-data applies only to check")
        require(args.metrics_file is None or args.action == "status", "--metrics-file applies only to status")
        if args.destination is not None:
            identifier(args.destination)
            require(args.destination in executor.destinations, "unknown destination")
        if args.action == "status":
            status = executor.status(args.metrics_file)
        elif args.action == "capture":
            with executor.locked("capture"):
                status = executor.capture()
        else:
            with executor.locked("destination-" + args.destination):
                if args.action == "backup":
                    manifest, lease = executor.lease_current()
                    try:
                        status = executor.backup(args.destination, manifest)
                    finally:
                        lease.close()
                elif args.action == "check":
                    status = executor.check(args.destination, args.read_data)
                elif args.action == "restore-check":
                    status = executor.restore_check(args.destination)
                elif args.action == "maintenance-plan":
                    status = executor.maintenance_plan(args.destination)
                elif args.action == "maintenance-run":
                    status = executor.maintenance_run(args.destination)
                else:
                    status = executor.maintenance_apply(args.destination)
        print(json.dumps({"ok": True, "action": args.action, **status}, sort_keys=True))
        return 0
    except (Failure, KeyError, TypeError, OSError, ValueError, json.JSONDecodeError) as exc:
        # Fixed messages only. Never include paths, command output, or secret-bearing exception text.
        message = str(exc) if isinstance(exc, Failure) else "invalid config, metadata, or filesystem state"
        print(json.dumps({"ok": False, "action": args.action, "error": message}, sort_keys=True))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
