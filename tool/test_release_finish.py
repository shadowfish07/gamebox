#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "release_finish", Path(__file__).parent / "lib/release_finish.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


def run(status="completed", conclusion="success", sha="abc"):
    return json.dumps([dict(databaseId=1, headSha=sha, headBranch="v1.2.3",
                           status=status, conclusion=conclusion, url="https://example/run/1")])


def publication(**changes):
    data = dict(tagName="v1.2.3", isDraft=False, isPrerelease=False,
                assets=[dict(name="gamebox-v1.2.3-android.apk", size=10),
                        dict(name="checksums.txt", size=10)])
    data.update(changes)
    return json.dumps(data)


class ReleaseTests(unittest.TestCase):
    @patch.object(release.time, "sleep")
    @patch.object(release, "command")
    def test_waits_for_exact_release(self, command, sleep):
        command.side_effect = ["[]", run("queued", ""), run(), publication()]
        release.wait_for_release("v1.2.3", "abc", 7200)
        self.assertEqual(sleep.call_count, 2)
        args = command.call_args_list[0].args
        self.assertIn("release.yml", args)
        self.assertIn("abc", args)
        self.assertIn("v1.2.3", args)
        self.assertIn("push", args)

    def test_failed_cancelled_and_wrong_commit_stop(self):
        for response in [run(conclusion="failure"), run(conclusion="cancelled"), run(sha="wrong")]:
            with self.subTest(response=response), patch.object(release, "command", return_value=response):
                with self.assertRaises(RuntimeError):
                    release.wait_for_release("v1.2.3", "abc", 7200)

    def test_incomplete_publication_stops(self):
        for data in [publication(isDraft=True), publication(isPrerelease=True),
                     publication(assets=[]), publication(tagName="v9.9.9")]:
            with self.subTest(data=data), patch.object(release, "command", side_effect=[run(), data]):
                with self.assertRaises(RuntimeError):
                    release.wait_for_release("v1.2.3", "abc", 7200)

    @patch.object(release.time, "monotonic", side_effect=[0, 10])
    def test_timeout(self, clock):
        with self.assertRaises(TimeoutError):
            release.wait_for_release("v1.2.3", "abc", 1)

    def test_errors_never_deploy_and_preserve_exit_code(self):
        for error, status in [(RuntimeError("failed"), 1),
                              (subprocess.CalledProcessError(23, "gh"), 23),
                              (TimeoutError("deadline"), 1)]:
            with patch.object(release.sys, "argv", ["script", "v1.2.3", "abc"]), \
                    patch.object(release, "wait_for_release", side_effect=error), \
                    patch.object(release, "deploy") as deploy:
                self.assertEqual(release.main(), status)
                deploy.assert_not_called()

    def test_deploy_failure_is_not_success(self):
        with patch.object(release.sys, "argv", ["script", "v1.2.3", "abc"]), \
                patch.object(release, "wait_for_release"), \
                patch.object(release, "deploy", side_effect=subprocess.CalledProcessError(37, "zsh")):
            self.assertEqual(release.main(), 37)

    def test_deploy_uses_committed_snapshot_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", directory], check=True)
            installer = root / "deploy/macos/install.sh"
            installer.parent.mkdir(parents=True)
            marker = root / "result"
            installer.write_text(f'#!/bin/zsh\nprint released > "{marker}"\n')
            subprocess.run(["git", "-C", directory, "add", "."], check=True)
            subprocess.run(["git", "-C", directory, "-c", "user.name=Test", "-c",
                            "user.email=test@example.com", "commit", "-qm", "fixture"], check=True)
            sha = subprocess.check_output(["git", "-C", directory, "rev-parse", "HEAD"], text=True).strip()
            installer.write_text('exit 99\n')
            with patch.object(release, "ROOT", root):
                release.deploy(sha)
            self.assertEqual(marker.read_text().strip(), "released")


if __name__ == "__main__":
    unittest.main()
