import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "src" / "reliability.py"
CAPTURE = ROOT / "tests" / "fixtures" / "capture.py"
GROW = ROOT / "tests" / "fixtures" / "grow.py"


@unittest.skipUnless(shutil.which("restic"), "restic executable unavailable")
class RuntimeIntegration(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="reliability-integration-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.password = self.root / "password"
        self.password.write_text("disposable test password", encoding="utf-8")
        self.repository = self.root / "repository"
        self.state = self.root / "state"
        self.env = {**os.environ, "RESTIC_PASSWORD_FILE": str(self.password), "RESTIC_REPOSITORY": str(self.repository),
                    "RESTIC_CACHE_DIR": str(self.root / "cache")}
        subprocess.run(["restic", "init"], env=self.env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.config = self.root / "config.json"
        self.data = {"stateDirectory": str(self.state),
                     "units": {"alpha": {"contractVersion": 1, "formatVersion": "v1", "captureCommand": [sys.executable, str(CAPTURE)], "validateCommand": [sys.executable, str(CAPTURE)]},
                               "beta": {"contractVersion": 1, "formatVersion": "v1", "captureCommand": [sys.executable, str(CAPTURE)], "validateCommand": [sys.executable, str(CAPTURE)]}},
                     "destinations": {"local": {"repository": str(self.repository), "passwordFile": str(self.password)}},
                     "policy": {"maxStagingBytes": 4096, "maintenanceEnabled": False, "maintenanceCommissioned": False}}
        self.save()

    def save(self):
        self.config.write_text(json.dumps(self.data), encoding="utf-8")

    def invoke(self, *args):
        process = subprocess.run([sys.executable, str(RUNTIME), "--config", str(self.config), *args],
                                 text=True, capture_output=True)
        self.assertEqual(process.stderr, "")
        return process.returncode, json.loads(process.stdout)

    def test_capture_backup_check_and_real_restore(self):
        code, capture = self.invoke("capture")
        self.assertEqual(code, 0, capture)
        code, backup = self.invoke("backup", "local")
        self.assertEqual(code, 0, backup)
        self.assertEqual(backup["units"], 2)
        code, check = self.invoke("check", "local", "--read-data")
        self.assertEqual(code, 0, check)
        self.assertTrue(check["readData"])
        snapshots = json.loads(subprocess.check_output(["restic", "snapshots", "--json"], env=self.env))
        self.assertEqual(len(snapshots), 2)
        for snap in snapshots:
            self.assertIn("generation:" + capture["generation"], snap["tags"])
            self.assertEqual(snap["time"][:19], capture["capturedAt"][:19])
            restored = self.root / ("restored-" + snap["id"])
            subprocess.run(["restic", "restore", snap["id"], "--target", str(restored)], env=self.env,
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.assertEqual((restored / snap["paths"][0].lstrip("/") / "payload.txt").read_text(), "captured content")
        self.assertEqual(self.invoke("backup", "local")[0], 0)
        self.assertEqual(len(json.loads(subprocess.check_output(["restic", "snapshots", "--json"], env=self.env))), 2)

    def test_partial_capture_never_publishes(self):
        self.assertEqual(self.invoke("capture")[0], 0)
        previous = json.loads((self.state / "current.json").read_text())
        self.data["units"]["beta"]["captureCommand"].append("fail")
        self.save()
        code, failed = self.invoke("capture")
        self.assertEqual(code, 1)
        self.assertFalse(failed["ok"])
        self.assertEqual(json.loads((self.state / "current.json").read_text()), previous)
        self.assertEqual(len([p for p in (self.state / "generations").iterdir() if p.is_dir()]), 1)

    def test_fail_closed_maintenance_and_sanitized_credential_error(self):
        self.assertEqual(self.invoke("capture")[0], 0)
        self.assertEqual(self.invoke("backup", "local")[0], 0)
        code, status = self.invoke("maintenance-plan", "local")
        self.assertEqual(code, 1)
        self.assertIn("disabled", status["error"])
        self.data["destinations"]["local"]["passwordFile"] = str(self.root / "missing-secret-password")
        self.save()
        code, status = self.invoke("check", "local")
        self.assertEqual(code, 1)
        self.assertNotIn("missing-secret-password", json.dumps(status))
        self.assertNotIn("disposable test password", json.dumps(status))

    def test_invalid_environment_file_fails_closed(self):
        envfile = self.root / "environment"
        envfile.write_text("AWS_SECRET_ACCESS_KEY=private-value\nOTHER_SECRET=forbidden\n", encoding="utf-8")
        self.data["destinations"]["local"]["environmentFile"] = str(envfile)
        self.save()
        self.assertEqual(self.invoke("capture")[0], 0)
        code, status = self.invoke("backup", "local")
        self.assertEqual(code, 1)
        self.assertEqual(status["error"], "unsupported environment key")
        self.assertNotIn("private-value", json.dumps(status))

    def test_status_missing_then_fresh_and_generation_collection(self):
        metrics = self.root / "metrics.prom"
        code, status = self.invoke("status", "--metrics-file", str(metrics))
        self.assertEqual(code, 0)
        self.assertEqual(status["destinations"]["local"]["severity"], 2)
        self.assertIn('reliability_backup_severity{destination="local"} 2', metrics.read_text())
        self.assertEqual(self.invoke("capture")[0], 0)
        first = json.loads((self.state / "current.json").read_text())["id"]
        self.assertEqual(self.invoke("backup", "local")[0], 0)
        self.assertEqual(self.invoke("capture")[0], 0)
        self.assertFalse((self.state / "generations" / first).exists())
        code, status = self.invoke("status", "--metrics-file", str(metrics))
        self.assertEqual(code, 0)
        self.assertEqual(status["destinations"]["local"]["severity"], 0)
        self.assertIn('reliability_backup_age_seconds{destination="local"}', metrics.read_text())

    def test_staging_quota_counts_unuploaded_generations(self):
        self.data["policy"]["maxStagingBytes"] = 600
        self.save()
        self.assertEqual(self.invoke("capture")[0], 0)
        previous = json.loads((self.state / "current.json").read_text())
        code, status = self.invoke("capture")
        self.assertEqual(code, 1)
        self.assertEqual(status["error"], "staging quota exceeded")
        self.assertEqual(json.loads((self.state / "current.json").read_text()), previous)

    def test_growing_child_is_stopped_before_capture_completes(self):
        heartbeat = self.root / "heartbeat"
        self.data["policy"]["maxStagingBytes"] = 65536
        self.data["units"]["alpha"]["captureCommand"] = [sys.executable, str(GROW), "parent", str(heartbeat)]
        self.save()
        code, failed = self.invoke("capture")
        self.assertEqual(code, 1)
        self.assertEqual(failed["error"], "staging quota exceeded")
        self.assertFalse((self.state / "current.json").exists())
        before = heartbeat.read_text()
        import time
        time.sleep(0.2)
        self.assertEqual(heartbeat.read_text(), before, "producer descendant kept writing after quota failure")
        self.assertEqual(list((self.state / "generations").iterdir()), [])

    def test_destination_outage_keeps_capture_bounded_and_recovers_latest(self):
        self.data["policy"]["maxStagingBytes"] = 2048
        self.save()
        latest = None
        for _ in range(5):
            code, status = self.invoke("capture")
            self.assertEqual(code, 0, status)
            latest = status["generation"]
            generations = [p for p in (self.state / "generations").iterdir() if p.is_dir()]
            self.assertEqual([p.name for p in generations], [latest])
        code, backup = self.invoke("backup", "local")
        self.assertEqual(code, 0, backup)
        self.assertEqual(backup["generation"], latest)
        snapshots = json.loads(subprocess.check_output(["restic", "snapshots", "--json"], env=self.env))
        self.assertEqual(len(snapshots), 2)
        self.assertTrue(all("generation:" + latest in snap["tags"] for snap in snapshots))

    def test_maintenance_guard_accepts_recent_older_restore_generation(self):
        repository_id = json.loads(subprocess.check_output(["restic", "--no-cache", "cat", "config"], env=self.env))["id"]
        self.data["destinations"]["local"]["expectedRepositoryId"] = repository_id
        self.data["policy"].update({"maintenanceEnabled": True, "maintenanceDeletionCeiling": 1,
                                    "retention": {"keepWithin": "7d", "keepWithinDaily": "1m",
                                                  "keepWithinWeekly": "3m", "keepWithinMonthly": "1y"}})
        self.save()
        self.assertEqual(self.invoke("capture")[0], 0)
        self.assertEqual(self.invoke("backup", "local")[0], 0)
        self.assertEqual(self.invoke("check", "local")[0], 0)
        evidence_dir = self.state / "evidence" / "local"
        shutil.copyfile(evidence_dir / "check.json", evidence_dir / "restore.json")
        self.assertEqual(self.invoke("capture")[0], 0)
        self.assertEqual(self.invoke("backup", "local")[0], 0)
        code, plan = self.invoke("maintenance-plan", "local")
        self.assertEqual(code, 0, plan)
        self.assertEqual(plan["plannedRemovals"], 0)
        self.data["policy"]["maintenanceCommissioned"] = True
        self.data["destinations"]["local"]["maintenancePolicyFingerprint"] = plan["scopeFingerprint"]
        self.save()
        code, applied = self.invoke("maintenance-run", "local")
        self.assertEqual(code, 0, applied)
        self.assertEqual(applied["removedSnapshots"], 0)

    def test_maintenance_rejects_uncommitted_and_uncertain_snapshots(self):
        repository_id = json.loads(subprocess.check_output(["restic", "--no-cache", "cat", "config"], env=self.env))["id"]
        self.data["destinations"]["local"]["expectedRepositoryId"] = repository_id
        self.data["policy"].update({"maintenanceEnabled": True, "maintenanceDeletionCeiling": 2,
                                    "retention": {"keepWithin": "7d", "keepWithinDaily": "1m",
                                                  "keepWithinWeekly": "3m", "keepWithinMonthly": "1y"}})
        self.save()
        for _ in range(2):
            self.assertEqual(self.invoke("capture")[0], 0)
            self.assertEqual(self.invoke("backup", "local")[0], 0)
        self.assertEqual(self.invoke("check", "local")[0], 0)
        evidence_dir = self.state / "evidence" / "local"
        shutil.copyfile(evidence_dir / "check.json", evidence_dir / "restore.json")
        self.assertEqual(self.invoke("maintenance-plan", "local")[0], 0)
        extra = self.root / "extra"
        extra.mkdir()
        (extra / "payload").write_text("looks complete but was never committed", encoding="utf-8")
        subprocess.run(["restic", "--no-cache", "backup", "--tag", "reliability:v1", "--tag", "unit:alpha",
                        "--tag", "format:v1", "--tag", "generation:uncommitted", str(extra)],
                       env=self.env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        code, status = self.invoke("maintenance-plan", "local")
        self.assertEqual(code, 1)
        self.assertEqual(status["error"], "uncommitted repository snapshot")
        marker = self.state / "attempts" / "uncertain" / "local-alpha.json"
        marker.parent.mkdir(parents=True)
        marker.write_text(json.dumps({"destination": "local", "unit": "alpha", "generation": "uncertain"}), encoding="utf-8")
        code, status = self.invoke("maintenance-plan", "local")
        self.assertEqual(code, 1)
        self.assertEqual(status["error"], "unresolved upload attempt")


if __name__ == "__main__":
    unittest.main()
