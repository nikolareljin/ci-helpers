"""Read reviewed scanner configuration instead of configuration added by a PR."""

import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys

REVIEW_ROOT = os.environ.get("SCAN_PATH", ".")


def names_a_baseline(text):
    """True when any mapping key at any depth is `baseline`.

    `scan.baseline` names a findings file read from the unreviewed tree, which
    would let a pull request silence what it adds. The parsed structure is
    walked, not the text: flow mappings, escapes, anchors and merge keys all
    resolve before the keys are compared. No parser, or a parse error, refuses.
    """
    try:
        import yaml
    except ImportError:
        raise ValueError("PyYAML is needed to review a foxguard config")
    try:
        documents = list(yaml.safe_load_all(text))
    except yaml.YAMLError:
        raise ValueError("unparsable configuration")
    pending = list(documents)
    while pending:
        node = pending.pop()
        if isinstance(node, dict):
            for key, value in node.items():
                if isinstance(key, str) and key.strip().casefold() == "baseline":
                    return True
                pending.append(value)
        elif isinstance(node, (list, tuple, set)):
            pending.extend(node)
    return False


def git(*args):
    return subprocess.run(["git", "-C", REVIEW_ROOT, *args], capture_output=True)


def content(ref):
    result = git("show", ref)
    if result.returncode:
        raise ValueError("unreadable reviewed configuration")
    return result.stdout


def place_beside(target, toplevel, relative, config):
    """Write the vetted config in the caller's config directory, at a new name.

    foxguard resolves path keys (`scan.ignore_rules[].path`,
    `secrets.exclude_paths`) against the config's own directory and refuses
    paths outside the scanned tree, so a copy elsewhere silently stops
    matching or errors. The directory must resolve inside the repository; the
    file is created exclusively, never followed through a link.
    """
    root = Path(toplevel).resolve()
    folder = (root / relative).parent
    real = folder.resolve()
    if real != root and root not in real.parents:
        raise ValueError("config directory leaves the repository")
    if not real.is_dir():
        raise ValueError("config directory missing")
    path = real / (".foxguard-reviewed-" + secrets.token_hex(8) + ".yml")
    # Recorded before the file exists, so run.sh removes it even if the
    # write fails part-way.
    (target / "config.path").write_text(str(path))
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as fh:
        fh.write(config)
    return path


def main():
    global REVIEW_ROOT
    target = Path(sys.argv[1])
    configured = os.environ.get("CONFIG_PATH", "")
    if configured and (configured.startswith(("/", "\\")) or ".." in Path(configured).parts or ":" in configured):
        return 1
    if configured and git("rev-parse", "--show-toplevel").returncode:
        REVIEW_ROOT = os.getcwd()
    config = b""
    placed = None
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
            if names_a_baseline(config):
                return 1
            toplevel = repo.stdout.decode().strip()
            placed = place_beside(target, toplevel, configured or ".foxguard.yml", config)
        elif configured:
            return 1
    elif configured:
        return 1
    if placed is None:
        placed = target / "config.yml"
        placed.write_bytes(config)
        (target / "config.path").write_text(str(placed))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError):
        sys.exit(1)
