#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 -I - "$root" <<'PY'
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    upstream = base / "upstream"
    consumer = base / "consumer"
    upstream.mkdir()
    (consumer / "scripts").mkdir(parents=True)
    shutil.copy2(Path(sys.argv[1]) / "scripts/sync_script_helpers.sh", consumer / "scripts")
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull)

    def git(*args):
        return subprocess.check_output(["git", "-C", str(upstream), *args], env=env).decode().strip()

    def commit():
        git("add", ".")
        git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture")
        return git("rev-parse", "HEAD")

    def sync(ref):
        return subprocess.run(["bash", str(consumer / "scripts/sync_script_helpers.sh"), "--repo-url", str(upstream), "--ref", ref], env=env, capture_output=True)

    git("init", "-q")
    (upstream / "scripts").mkdir()
    (upstream / "scripts/check_publication.sh").write_text("#!/bin/sh\nexit 0\n")
    (upstream / "helpers.sh").write_text("shlib_import() { :; }; log_info() { :; }; log_warn() { :; }; log_error() { :; }\n")
    changelog = upstream / "CHANGELOG.md"
    changelog.write_text("## Older\n\nARCHIVE_SENTINEL\n")
    old = commit()
    assert sync(old).returncode == 0
    changelog.write_text("## Unreleased\n\nNEW_ENTRY\n\n" + changelog.read_text())
    new = commit()
    result = sync(new)
    assert result.returncode == 0, result.stderr.decode()
    notes = (consumer / "vendor/.script-helpers-notes.md").read_text()
    assert "NEW_ENTRY" in notes
    assert not notes.endswith("\n\n"), "generated notes contain trailing blank lines"
    assert "ARCHIVE_SENTINEL" not in notes, "SHA pin recopied old history"
    print("PASS commit pins copy only the changelog delta")

    (upstream / "scripts/check_publication.sh").write_text("#!/bin/sh\nexit 2\n")
    result = sync(commit())
    assert result.returncode != 0
    assert (consumer / "vendor/.script-helpers-sha").read_text().strip() == new
    print("PASS incomplete publication checks preserve the previous pin")

    (upstream / "scripts/check_publication.sh").unlink()
    assert sync(commit()).returncode != 0
    print("PASS missing publication checker refuses the sync")
PY
