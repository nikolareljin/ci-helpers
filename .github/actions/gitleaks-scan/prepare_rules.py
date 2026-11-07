"""Read reviewed scanner configuration instead of configuration added by a PR."""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib


def git(*args):
    return subprocess.run(["git", "-C", os.environ.get("SCAN_PATH", "."), *args], capture_output=True)


def content(ref):
    result = git("show", ref)
    if result.returncode:
        raise ValueError("unreadable reviewed configuration")
    return result.stdout


def main():
    target = Path(sys.argv[1])
    configured = os.environ.get("CONFIG_PATH", "")
    if configured and (configured.startswith(("/", "\\")) or ".." in Path(configured).parts or ":" in configured):
        return 1
    config = b"[extend]\nuseDefault = true\n"
    ignore = b""
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
        config_ref = base + ":" + (configured or ".gitleaks.toml")
        if git("cat-file", "-e", config_ref).returncode == 0:
            config = content(config_ref)
            # A reviewed config must not extend a file from the unreviewed tree.
            parsed = tomllib.loads(config.decode("utf-8-sig"))
            for key, extension in parsed.items():
                if key.casefold() != "extend":
                    continue
                if not isinstance(extension, dict):
                    return 1
                for field, value in extension.items():
                    if field.casefold() == "path" and value != "":
                        return 1
        elif configured:
            return 1
        ignore_ref = base + ":.gitleaksignore"
        if git("cat-file", "-e", ignore_ref).returncode == 0:
            ignore = content(ignore_ref)
    elif configured:
        return 1
    (target / "rules.toml").write_bytes(config)
    (target / "approved-ignore").write_bytes(ignore)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError):
        sys.exit(1)
