#!/usr/bin/env python3
"""CLI integrity regressions. Only disposable fake-data bundles; never boots a guest."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import uuid
import time

BINARY = str(Path(sys.argv.pop(1)).resolve()) if len(sys.argv) > 1 else os.environ["VITRINECTL"]


class LifecycleIntegrity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="vitrine-lifecycle-", dir="/private/tmp")
        self.root = Path(self.tmp.name)
        self.library = self.root / "library"
        self.bundle = self.library / "fixture.vitrinevm"
        self.bundle.mkdir(parents=True)
        self.cache = self.root / "cache"
        self.cache.mkdir()
        self.env = dict(os.environ, VITRINE_HOME=str(self.library), VITRINE_CACHE=str(self.cache))
        self.config = {
            "version": 1, "id": str(uuid.uuid4()), "name": "fixture", "guestOS": "linux",
            "cpuCount": 1, "memoryMiB": 2048,
            "disks": [{"path": "disk.img", "readOnly": False, "interface": "nvme", "caching": "automatic"}],
            "shares": [], "network": {"mode": "none", "macAddress": "02:00:00:00:00:01"},
            "display": {"widthPixels": 640, "heightPixels": 480, "pixelsPerInch": 96, "autoResize": False},
            "features": {}, "backend": "qemu", "architecture": "aarch64", "notes": "fake fixture",
        }
        (self.bundle / "disk.img").write_bytes(b"DISK-SENTINEL")
        self.write_config()

    def tearDown(self):
        self.doCleanups()  # terminate owned synthetic backends before removing their bundle files
        self.tmp.cleanup()

    def write_config(self):
        (self.bundle / "config.json").write_text(json.dumps(self.config))

    def cli(self, *args):
        return subprocess.run([BINARY, *args], env=self.env, capture_output=True, text=True, timeout=10)

    def test_suspended_hardware_edits_preserve_configuration(self):
        for state in ("state.qemusave", "state.vzvmsave"):
            with self.subTest(state=state):
                (self.bundle / state).write_bytes(b"FAKE-RAM")
                before = (self.bundle / "config.json").read_bytes()
                r = self.cli("set", "fixture", "--memory", "4G")
                self.assertNotEqual(r.returncode, 0, r.stdout)
                self.assertEqual((self.bundle / "config.json").read_bytes(), before)
                (self.bundle / state).unlink()

    def test_failed_eject_and_hardware_edit_preserves_media(self):
        self.config["extraMedia"] = ["seed.iso"]
        self.write_config()
        seed = self.bundle / "seed.iso"
        seed.write_bytes(b"PASSWORD-SEED")
        before = (self.bundle / "config.json").read_bytes()
        r = self.cli("set", "fixture", "--eject", "--cpus", "0")
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(seed.exists(), "rejected edit deleted seed")
        self.assertEqual((self.bundle / "config.json").read_bytes(), before)

    def test_eject_preserves_external_and_user_installer_media(self):
        external = self.library / "keep.iso"
        external.write_bytes(b"EXTERNAL-ISO")
        link = self.bundle / "linked"
        link.symlink_to(self.library, target_is_directory=True)
        internal = self.bundle / "user-installer.iso"
        internal.write_bytes(b"USER-INSTALLER")
        for media in ("../keep.iso", "linked/keep.iso", "user-installer.iso"):
            with self.subTest(media=media):
                self.config["installMedia"] = media
                self.write_config()
                r = self.cli("set", "fixture", "--eject")
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertTrue(external.exists(), "eject deleted external target")
                self.assertTrue(internal.exists(), "eject deleted user installer")

    def test_eject_cleans_generated_internal_seed_only(self):
        seed = self.bundle / "seed.iso"
        seed.write_bytes(b"PASSWORD-SEED")
        self.config["extraMedia"] = ["seed.iso"]
        self.write_config()
        r = self.cli("set", "fixture", "--eject")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(seed.exists())
        self.assertFalse(json.loads((self.bundle / "config.json").read_text()).get("extraMedia"))

    def test_hardware_edit_refuses_lock_without_readable_owner(self):
        with (self.bundle / "run.lock").open("w+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            before = (self.bundle / "config.json").read_bytes()
            r = self.cli("set", "fixture", "--memory", "4G")
            self.assertNotEqual(r.returncode, 0, r.stdout)
            self.assertEqual((self.bundle / "config.json").read_bytes(), before)

    def test_delete_refuses_lock_without_readable_owner(self):
        with (self.bundle / "run.lock").open("w+") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            r = self.cli("delete", "fixture")
            self.assertNotEqual(r.returncode, 0, r.stdout)
            self.assertTrue(self.bundle.exists(), "deleted bundle under held lock")

    def test_rejected_disk_shrink_with_eject_preserves_media_and_config(self):
        seed = self.bundle / "seed.iso"
        seed.write_bytes(b"PASSWORD-SEED")
        self.config["extraMedia"] = ["seed.iso"]
        self.write_config()
        before = (self.bundle / "config.json").read_bytes()
        disk = (self.bundle / "disk.img").read_bytes()
        r = self.cli("set", "fixture", "--eject", "--disk", "1")
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(seed.exists())
        self.assertEqual((self.bundle / "config.json").read_bytes(), before)
        self.assertEqual((self.bundle / "disk.img").read_bytes(), disk)

    def test_disk_grow_and_config_edit_commit_together(self):
        r = self.cli("set", "fixture", "--disk", "4K", "--memory", "4G")
        self.assertEqual(r.returncode, 0, r.stderr)
        saved = json.loads((self.bundle / "config.json").read_text())
        self.assertEqual(saved["memoryMiB"], 4096)
        self.assertTrue(saved["pendingDiskGrow"])
        self.assertEqual((self.bundle / "disk.img").stat().st_size, 4096)

    def test_malformed_display_reports_validation_error_without_crashing(self):
        for value in ("@", "", "640x480@bad", "640x480x900", "640x480@@96"):
            with self.subTest(value=value):
                before = (self.bundle / "config.json").read_bytes()
                r = self.cli("set", "fixture", "--display", value)
                self.assertGreater(r.returncode, 0, f"signal crash or accepted invalid display: {r.returncode}")
                self.assertEqual((self.bundle / "config.json").read_bytes(), before)

    def test_stopped_hardware_edit_and_delete_succeed(self):
        r = self.cli("set", "fixture", "--memory", "4G", "--display", "800x600@96")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads((self.bundle / "config.json").read_text())["memoryMiB"], 4096)
        r = self.cli("delete", "fixture")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.bundle.exists())

    def start_fake_qemu(self, mode="disconnect"):
        prefix = self.root / "fake-qemu"
        (prefix / "bin").mkdir(parents=True)
        firmware = prefix / "share" / "qemu"
        firmware.mkdir(parents=True)
        for name in ("edk2-aarch64-code.fd", "edk2-arm-vars.fd"):
            (firmware / name).write_bytes(b"FAKE-FIRMWARE")
        executable = prefix / "bin" / "qemu-system-aarch64"
        executable.write_text(Path(__file__).with_name("fake-qemu.py").read_text())
        executable.chmod(0o700)
        log = self.root / "qmp-events"
        self.env.update(VITRINE_QEMU_PREFIX=str(prefix), VITRINE_FAKE_QEMU_LOG=str(log), VITRINE_NO_AGENT="1",
                        VITRINE_FAKE_QEMU_FAILURE=mode)
        self.config["features"]["sound"] = True
        self.write_config()
        runner = subprocess.Popen([BINARY, "run", "fixture"], env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.stop_fake_qemu, runner)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if log.exists() and "qmp_capabilities" in log.read_text():
                time.sleep(0.3)
                self.wait_for_control_socket(runner)
                return runner, log
            if runner.poll() is not None:
                self.fail(f"fixture did not start: {runner.communicate()}")
            time.sleep(0.05)
        self.fail("fake QEMU did not receive control connection")

    def wait_for_control_socket(self, runner):
        # The owner opens its control socket (which carries stop/suspend) once the VM is up.
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.cli("usb", "list", "fixture").returncode == 0:
                return
            if runner.poll() is not None:
                self.fail(f"fixture exited before answering on its control socket: {runner.communicate()}")
            time.sleep(0.05)
        self.fail("VM owner never answered on its control socket")

    def suspend_in_background(self):
        # A recovered suspend leaves the VM up, so `vitrinectl suspend` would wait out its 90 s.
        request = subprocess.Popen([BINARY, "suspend", "fixture"], env=self.env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(request.wait)
        self.addCleanup(request.kill)

    def stop_fake_qemu(self, runner):
        if runner.poll() is None:
            try:
                self.cli("stop", "fixture", "--force")
            except subprocess.TimeoutExpired:
                pass  # killed below
        try:
            runner.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            runner.kill()
            runner.communicate()

    def test_qemu_suspend_transport_failure_recovers_running_machine_and_audio(self):
        runner, log = self.start_fake_qemu()
        self.suspend_in_background()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            events = log.read_text().splitlines()
            if "injected-disconnect" in events and "device_add" in events:
                break
            time.sleep(0.05)
        self.assertIn("injected-disconnect", events)
        self.assertIn("migrate_cancel", events, "active migration was never cancelled after monitor failure")
        self.assertIn("cont", events, "guest remained paused after failed suspend")
        self.assertIn("device_add", events, "audio was never restored after failed suspend")
        self.assertFalse((self.bundle / "state.qemusave").exists())
        self.assertIsNone(runner.poll(), "VM owner exited after recoverable suspend failure")

    def test_qemu_failed_publication_recovers_without_deleting_previous_destination(self):
        runner, log = self.start_fake_qemu("publish")
        self.suspend_in_background()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            events = log.read_text().splitlines()
            if "device_add" in events:
                break
            time.sleep(0.05)
        self.assertIn("cont", events)
        self.assertIn("device_add", events)
        self.assertTrue((self.bundle / "state.qemusave").is_dir(), "failed publication removed previous destination")
        self.assertFalse((self.bundle / "state.qemusave.partial").exists())

    def test_qemu_unrecoverable_monitor_retains_owner_and_partial(self):
        runner, log = self.start_fake_qemu("unrecoverable")
        self.suspend_in_background()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if "injected-disconnect" in log.read_text():
                break
            time.sleep(0.05)
        time.sleep(1)
        self.assertIsNone(runner.poll(), "lost control must not orphan the backend")
        self.assertTrue((self.bundle / "state.qemusave.partial").exists(), "unsettled migration output was removed")
        with (self.bundle / "run.lock").open("r") as held:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_qemu_completed_suspend_publishes_state_and_exits(self):
        runner, log = self.start_fake_qemu("complete")
        r = self.cli("suspend", "fixture")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.strip(), "suspended fixture")
        output, error = runner.communicate(timeout=10)
        self.assertEqual(runner.returncode, 0, error.decode())
        self.assertEqual((self.bundle / "state.qemusave").read_bytes(), b"COMPLETED-SAVE")
        self.assertFalse((self.bundle / "state.qemusave.partial").exists())
        self.assertIn("quit", log.read_text().splitlines())


if __name__ == "__main__":
    unittest.main()
