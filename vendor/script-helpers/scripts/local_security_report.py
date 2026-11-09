"""Allocate a private diagnostics file outside any Git worktree."""

import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    sys.stdout.reconfigure(newline="\n")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output")
    parser.add_argument("--name", default="security.log")
    parser.add_argument("--existing", action="store_true")
    parser.add_argument("--temporary", action="store_true")
    args = parser.parse_args()
    if (os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS")) and not args.temporary:
        return 2
    try:
        if args.output:
            target = Path(args.output).absolute()
            if target.is_symlink():
                return 2
        else:
            root = subprocess.run(
                ["git", "rev-parse", "--show-toplevel"], capture_output=True
            )
            key = hashlib.sha256(root.stdout or os.fsencode(os.getcwd())).hexdigest()[:20]
            if args.temporary:
                parent = Path(os.environ.get("RUNNER_TEMP", tempfile.gettempdir()))
            else:
                state = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
                parent = state / "script-helpers" / "scans" / key
            target = parent / args.name
        parent = target.parent.resolve()
        probe = parent
        while not probe.exists():
            probe = probe.parent
        # Reject worktrees including ones other than the current repository.
        for flag in ("--is-inside-work-tree", "--is-inside-git-dir"):
            check = subprocess.run(
                ["git", "-C", str(probe), "rev-parse", flag],
                capture_output=True,
                env={k: v for k, v in os.environ.items() if not k.startswith("GIT_")},
            )
            if check.returncode == 0 and check.stdout.strip() == b"true":
                return 2
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        if args.existing:
            if not args.output or not target.is_file():
                return 2
            print(target)
            return 0
        if args.output:
            target = parent / target.name
        else:
            parent = Path(tempfile.mkdtemp(prefix="run-", dir=parent))
            target = parent / args.name
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        fd = os.open(target, flags, 0o600)
        os.close(fd)
        print(target)
        return 0
    except (OSError, ValueError):
        return 2


if __name__ == "__main__":
    sys.exit(main())
