"""Read reviewed scanner configuration instead of configuration added by a PR."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys

REVIEW_ROOT = os.environ.get("SCAN_PATH", ".")
# `scan.baseline` names a findings file read from the unreviewed tree, which
# would let a pull request silence what it adds.
BASELINE_KEY = re.compile(rb"^\s*['\"]?baseline['\"]?\s*:", re.M)


def git(*args):
    return subprocess.run(["git", "-C", REVIEW_ROOT, *args], capture_output=True)


def content(ref):
    result = git("show", ref)
    if result.returncode:
        raise ValueError("unreadable reviewed configuration")
    return result.stdout


def main():
    global REVIEW_ROOT
    target = Path(sys.argv[1])
    configured = os.environ.get("CONFIG_PATH", "")
    if configured and (configured.startswith(("/", "\\")) or ".." in Path(configured).parts or ":" in configured):
        return 1
    if configured and git("rev-parse", "--show-toplevel").returncode:
        REVIEW_ROOT = os.getcwd()
    config = b""
    repo = git("rev-parse", "--show-toplevel")
    if repo.returncode == 0:
        base = "HEAD"
        event_path = os.environ.get("GITHUB_EVENT_PATH")
        if event_path:
            event = json.loads(Path(event_path).read_text())
            pull = event.get("pull_request")
            if pull:
                base = pull["base"]["sha"]
                if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", base):
                    return 1
        if git("cat-file", "-e", base + "^{commit}").returncode:
            return 1
        config_ref = base + ":" + (configured or ".foxguard.yml")
        if git("cat-file", "-e", config_ref).returncode == 0:
            config = content(config_ref)
            if BASELINE_KEY.search(config):
                return 1
        elif configured:
            return 1
    elif configured:
        return 1
    (target / "config.yml").write_bytes(config)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError):
        sys.exit(1)
