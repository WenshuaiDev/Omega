"""Behavioral shell lifecycle regressions; Docker is an isolated fake command."""
import hashlib
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]


class WrapperLifecycle(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="omega wrapper test ")
        self.work = Path(self.tmp.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", MOCK_EVENTS=str(self.work / "events"))
        self.children = []

    def tearDown(self):
        for child in self.children:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
        self.tmp.cleanup()

    def executable(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\n" + body)
        path.chmod(0o755)

    def start(self, argv):
        proc = subprocess.Popen(argv, env=self.env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        self.children.append(proc)
        return proc

    def event(self, text, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            path = self.work / "events"
            if path.exists() and text in path.read_text():
                return
            time.sleep(0.05)
        self.fail(f"missing controlled test event {text}")

    def test_shared_wait_preserves_exit_and_bounds_term_ignoring_child(self):
        command = f'source "{ROOT}/scripts/process.sh"; bounded 1 bash -c \'trap "" TERM; while :; do sleep 1; done\'; exit $?'
        started = time.monotonic()
        proc = self.start(["bash", "-c", command])
        self.assertEqual(proc.wait(timeout=7), 5)
        self.assertLess(time.monotonic() - started, 6)
        result = subprocess.run(["bash", "-c", f'source "{ROOT}/scripts/process.sh"; bounded 2 bash -c "exit 6"'], check=False)
        self.assertEqual(result.returncode, 6)

    def test_dev_cancel_releases_locks_before_unresponsive_docker_cleanup(self):
        self.executable("docker", '''
case "$1 $2" in
  'volume inspect') exit 1;;
  'run --rm') echo run >> "$MOCK_EVENTS"; exec sleep 1000;;
  'rm -f') echo cleanup >> "$MOCK_EVENTS"; trap '' TERM; while :; do sleep 1; done;;
esac
exit 0
''')
        inputs = self.work / "inputs with spaces"
        proc = self.start(["bash", str(ROOT / "scripts/dev.sh"), "dev", "--input", str(inputs)])
        self.event("run")
        self.assertTrue((inputs / ".lock").exists())
        proc.send_signal(signal.SIGTERM)
        self.event("cleanup")
        self.assertFalse((inputs / ".lock").exists())
        self.assertEqual(proc.wait(timeout=16), 130)

    def test_dev_volume_query_failure_never_generates_identity_or_credentials(self):
        self.executable("docker", 'case "$1 $2" in "volume ls") exit 1;; esac; exit 0\n')
        inputs = self.work / "inputs"
        result = subprocess.run(["bash", str(ROOT / "scripts/dev.sh"), "dev", "--input", str(inputs)], env=self.env, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 5)
        self.assertFalse((inputs / "instance.env").exists())
        (inputs / "instance.env").write_text("ENVIRONMENT=dev\nINSTANCE_ID=dev-query-failure\nHTTP_PORT=24567\nHTTPS_PORT=24568\nDOMAIN=localhost\n")
        original = (inputs / "instance.env").read_bytes()
        result = subprocess.run(["bash", str(ROOT / "scripts/dev.sh"), "dev", "--input", str(inputs)], env=self.env, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 5)
        self.assertEqual((inputs / "instance.env").read_bytes(), original)
        self.assertFalse((inputs / "secrets").exists())
        self.assertFalse((inputs / ".lock").exists())

    def test_dev_preflight_daemon_timeout(self):
        self.executable("docker", "exec sleep 1000\n")
        started = time.monotonic()
        proc = self.start(["bash", str(ROOT / "scripts/dev.sh"), "status", "--input", str(self.work)])
        self.assertEqual(proc.wait(timeout=26), 2)
        self.assertLess(time.monotonic() - started, 25)
        self.assertFalse((self.work / ".lock").exists())

    def test_import_disk_refuses_before_destination_and_load(self):
        self.executable("docker", '''
echo "$*" >> "$MOCK_EVENTS"
case "$1 $2" in
  'version --format') echo '1.49 1.49';;
  'info --format') echo /var/lib/docker;;
esac
''')
        self.executable("df", 'echo "Filesystem 1024-blocks Used Available Capacity Mounted"; echo "fixture 1000000 999999 1 99% /"\n')
        public = self.work / "public"
        public.mkdir()
        (public / "file").write_text("public fixture")
        archive = self.work / "candidate.tar"
        subprocess.run(["tar", "-cf", str(archive), "-C", str(public), "."], check=True)
        dest = self.work / "new release"
        result = subprocess.run(["bash", str(ROOT / "scripts/import-release.sh"), str(archive), hashlib.sha256(archive.read_bytes()).hexdigest(), str(dest)], env=self.env, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("insufficient destination disk", result.stderr)
        self.assertFalse(dest.exists())
        self.assertNotIn("load", (self.work / "events").read_text())
        self.executable("df", 'echo "Filesystem 1024-blocks Used Available Capacity Mounted"; if [ "$2" = /var/lib/docker ]; then echo "docker 1000000 999999 1 99% /"; else echo "destination 100000000 0 100000000 0% /"; fi\n')
        result = subprocess.run(["bash", str(ROOT / "scripts/import-release.sh"), str(archive), hashlib.sha256(archive.read_bytes()).hexdigest(), str(dest)], env=self.env, capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("insufficient Docker disk", result.stderr)
        self.assertFalse(dest.exists())
        self.assertNotIn("load", (self.work / "events").read_text())

    def test_acceptance_requires_distinct_old_candidate_before_work(self):
        candidate = self.work / "candidate.tar"
        candidate.touch()
        base = ["bash", str(ROOT / "scripts/acceptance.sh"), "release", "--archive", str(candidate), "--archive-sha256", "new", "--version", "v1", "--manifest-sha256", "manifest", "--harness-image", "fixture"]
        missing = subprocess.run(base, capture_output=True, text=True, check=False)
        self.assertEqual(missing.returncode, 2)
        self.assertIn("four old-candidate", missing.stderr)
        same = subprocess.run(base + ["--old-archive", str(candidate), "--old-archive-sha256", "new", "--old-version", "v1", "--old-manifest-sha256", "manifest"], capture_output=True, text=True, check=False)
        self.assertEqual(same.returncode, 2)
        self.assertIn("distinct", same.stderr)

    def test_dispatcher_cancellation_reaps_child_and_records_failed_suite(self):
        repo = self.work / "repo"
        (repo / "scripts").mkdir(parents=True)
        for name in ("process.sh", "acceptance.sh"):
            shutil.copy(ROOT / "scripts" / name, repo / "scripts" / name)
        check = repo / "scripts/check.sh"
        check.write_text("#!/usr/bin/env bash\ntrap 'sleep 1; echo stopped >> \"$MOCK_EVENTS\"; exit 130' TERM\necho started >> \"$MOCK_EVENTS\"\nwhile :; do sleep 1; done\n")
        check.chmod(0o755)
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], check=True)
        self.executable("docker", "exit 0\n")
        output = self.work / "acceptance"
        proc = self.start(["bash", str(repo / "scripts/acceptance.sh"), "quality", "--output", str(output)])
        self.event("started")
        proc.send_signal(signal.SIGTERM)
        self.assertEqual(proc.wait(timeout=8), 130)
        self.event("stopped")
        self.assertIn("quality\tFAIL\t130", (output / "results.tsv").read_text())
        self.assertIn("local_run_exit=130", (output / "result.txt").read_text())

    def test_browser_cancellation_with_unresponsive_daemon_records_failure(self):
        repo = self.work / "repo"
        (repo / "scripts/acceptance").mkdir(parents=True)
        shutil.copy(ROOT / "scripts/process.sh", repo / "scripts/process.sh")
        shutil.copy(ROOT / "scripts/acceptance/browser.sh", repo / "scripts/acceptance/browser.sh")
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
        subprocess.run(["git", "-C", str(repo), "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], check=True)
        self.executable("docker", '''
case "$1" in
  build) echo build >> "$MOCK_EVENTS"; exec sleep 1000;;
  info) exec sleep 1000;;
esac
exit 0
''')
        evidence = self.work / "evidence"
        proc = self.start(["bash", str(repo / "scripts/acceptance/browser.sh"), "--output", str(evidence)])
        self.event("build")
        proc.send_signal(signal.SIGTERM)
        self.assertEqual(proc.wait(timeout=12), 130)
        record = (evidence / "result.txt").read_text()
        self.assertIn("exit=130", record)
        self.assertIn("cleanup_complete=false", record)
        retained = Path((evidence / "cleanup.txt").read_text().strip().split(" at ", 1)[1])
        # This is a generated credential-free fixture, never a user checkout.
        shutil.rmtree(retained)


if __name__ == "__main__":
    unittest.main()
