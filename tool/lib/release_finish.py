#!/usr/bin/env python3
"""Wait for a tag's release, then deploy its immutable source on this Mac."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

REPO = "shadowfish07/gamebox"
ROOT = Path(__file__).resolve().parents[2]


def command(*args, **kwargs):
    return subprocess.check_output(args, text=True, cwd=ROOT, **kwargs)


def wait_for_release(tag, sha, timeout):
    deadline = time.monotonic() + timeout
    previous = None
    delay = 5
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError(f"release {tag} timed out; production was not updated")
        runs = json.loads(command(
            "gh", "run", "list", "--repo", REPO, "--workflow", "release.yml",
            "--branch", tag, "--commit", sha, "--event", "push", "--limit", "1",
            "--json", "databaseId,headSha,headBranch,status,conclusion,url",
            timeout=min(60, remaining)))
        run = runs[0] if runs else None
        if run and (run["headSha"] != sha or run["headBranch"] != tag):
            raise RuntimeError("release workflow identity mismatch")
        state = (run["status"], run["conclusion"]) if run else ("waiting for workflow", "")
        if state != previous:
            print(f"release {tag}: {' '.join(state).strip()}"
                  + (f" ({run['url']})" if run else ""), flush=True)
            previous = state
        if run and run["status"] == "completed":
            if run["conclusion"] != "success":
                raise RuntimeError(f"release failed: {run['conclusion']}; {run['url']}")
            release = json.loads(command(
                "gh", "release", "view", tag, "--repo", REPO,
                "--json", "tagName,isDraft,isPrerelease,assets", timeout=60))
            assets = {a["name"] for a in release["assets"] if a["size"] > 0}
            if (release["tagName"] != tag or release["isDraft"] or release["isPrerelease"]
                    or not {f"gamebox-{tag}-android.apk", "checksums.txt"} <= assets):
                raise RuntimeError("release is not public and complete; production was not updated")
            return
        time.sleep(max(0, min(delay, deadline - time.monotonic())))
        delay = min(delay * 2, 60)


def deploy(sha):
    # Never build from the user's checkout: it may change during the CI wait.
    with tempfile.TemporaryDirectory(prefix="gamebox-release-") as directory:
        archive = Path(directory) / "source.tar"
        command("git", "archive", "--format=tar", f"--output={archive}", sha)
        command("tar", "-xf", str(archive), "-C", directory)
        subprocess.run(["zsh", str(Path(directory) / "deploy/macos/install.sh")],
                       cwd=directory, check=True)


def main():
    tag, sha = sys.argv[1:]
    try:
        timeout = int(os.environ.get("GAMEBOX_RELEASE_TIMEOUT_SECONDS", "7200"))
        if timeout <= 0:
            raise ValueError("GAMEBOX_RELEASE_TIMEOUT_SECONDS must be positive")
        wait_for_release(tag, sha, timeout)
        print(f"release {tag}: updating production from {sha}", flush=True)
        deploy(sha)
        print(f"release {tag}: published and production updated", flush=True)
    except (subprocess.SubprocessError, RuntimeError, ValueError, OSError) as error:
        print(f"release: {error}\nResume: bash tool/release.sh --resume {tag}", file=sys.stderr)
        return error.returncode if isinstance(error, subprocess.CalledProcessError) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
