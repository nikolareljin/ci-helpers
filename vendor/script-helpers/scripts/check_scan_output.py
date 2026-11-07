"""Inspect Git objects and publication text without printing scanner results."""

import argparse
import bz2
import gzip
import lzma
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import zipfile
import zlib


class Refused(Exception):
    def __init__(self, path=None, tool="Security"):
        super().__init__(*(() if path is None else (path,)))
        self.tool = tool


class Unchecked(Exception):
    pass


REPORT_NAME = re.compile(
    r"(?i)^(?:scans|scan-results|security-reports)/|\.sarif(?:\.(?:gz|bz2|xz|zip))?$|"
    r"(?:^|/)[^/]*(?:gitleaks|foxguard)[^/]*\.(?:json|sarif|log|html|csv)(?:\.(?:gz|bz2|xz|zip))?$"
)
TOOL = re.compile(r"gitleaks|foxguard", re.I)
RESULT = re.compile(
    r"(?i)\b(?:gitleaks|foxguard)(?![\w.-]).{0,80}"
    r"\b\d+\s+(?:findings?|leaks?|hits?)\b|"
    r"\b(?:gitleaks|foxguard)\s*[:=]\s*(?:clean|no leaks|no findings)\b|"
    r"\bno gitleaks findings\b|\bgitleaks findings detected\s*:|"
    r"\b(?:gitleaks|foxguard)\s*[:=]?\s*\d+\s*(?:[,;]|$)|"
    r"\b\d+\s+(?:gitleaks|foxguard)\s+(?:findings?|leaks?|hits?)\b"
)
NATIVE_RESULT = re.compile(
    r"(?i)^(?:\d{1,2}:\d{2}(?::\d{2})?(?:AM|PM)?\s+)?"
    r"(?:(?:INF|WRN|ERR)\s+)?(?:no leaks found\.?|leaks found\s*:\s*\d+|\d+\s+leaks? found)\s*$"
)
LIMIT = 64 * 1024 * 1024
BASH = shutil.which("bash") or "bash"


def inspect_archive_member(name, raw, depth):
    inspect(name, raw, depth)
    # Binary diffs do not expose archive members to the ordinary PII check.
    proc = subprocess.run(
        [BASH, Path(__file__).with_name("check_sensitive.sh").as_posix(),
         "--stdin", "--no-gitleaks", "--no-inline-allow"],
        input=raw.replace(b"\0", b" "), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if proc.returncode == 1:
        raise Refused()
    if proc.returncode:
        raise Unchecked()


def git(repo, *args):
    proc = subprocess.run(
        ["git", "-C", repo, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    if proc.returncode:
        raise Unchecked()
    return proc.stdout


def structured(value):
    if isinstance(value, dict):
        keys = {str(k).lower() for k in value}
        if isinstance(value.get("runs"), list) and (
            "sarif" in str(value.get("$schema", "")).lower()
            or str(value.get("version")) in {"1.0.0", "2.0.0", "2.1.0"}
        ):
            return True
        if {"ruleid", "fingerprint"} <= keys or {"ruleid", "secret"} <= keys:
            return True
        if "findings" in keys and keys.intersection(
            {"finding_counts", "scanner", "tool", "finding_schema_version"}
        ):
            return True
        return any(structured(v) for v in value.values())
    if isinstance(value, list):
        return any(structured(v) for v in value)
    if isinstance(value, str):
        try:
            inspect("embedded-text", value.encode("utf-8"))
        except Refused:
            return True
    return False


def inspect(name, raw, depth=0):
    try:
        _inspect(name, raw, depth)
    except Refused as exc:
        if exc.tool == "Security":
            text = raw.decode("utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8", errors="replace")
            identity = re.search(r'"(?:name|tool|scanner)"\s*:\s*"(gitleaks|foxguard)"', text, re.I)
            hint = identity or TOOL.search(name) or TOOL.search(text)
            if hint:
                label = hint.group(1) if identity else hint.group(0)
                exc.tool = "Gitleaks" if label.lower() == "gitleaks" else "Foxguard"
            elif '"RuleID"' in text:
                exc.tool = "Gitleaks"
        raise


def _inspect(name, raw, depth=0):
    normalized = "/".join(part for part in name.replace("\\", "/").split("/") if part not in ("", "."))
    if REPORT_NAME.search(normalized):
        raise Refused()
    if len(raw) > LIMIT or depth > 3:
        raise Unchecked()
    # Inspect archives in memory. Never extract paths supplied by the archive.
    if raw.startswith((b"\x1f\x8b", b"BZh", b"\xfd7zXZ\x00")):
        opener = gzip.GzipFile if raw.startswith(b"\x1f\x8b") else bz2.BZ2File if raw.startswith(b"BZh") else lzma.LZMAFile
        try:
            with opener(io.BytesIO(raw)) as stream:
                expanded = stream.read(LIMIT + 1)
            inspect_archive_member("compressed-content", expanded, depth + 1)
        except (OSError, EOFError, ValueError, lzma.LZMAError, zlib.error):
            raise Unchecked() from None
        return
    if raw.startswith(b"PK\x03\x04") or name.lower().endswith(".zip"):
        try:
            with zipfile.ZipFile(io.BytesIO(raw)) as archive:
                total = 0
                for member in archive.infolist():
                    total += member.file_size
                    if total > LIMIT or member.flag_bits & 1:
                        raise Unchecked()
                    if not member.is_dir():
                        inspect_archive_member(member.filename, archive.read(member), depth + 1)
        except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, zlib.error):
            raise Unchecked() from None
        return
    if raw[257:262] == b"ustar" or name.lower().endswith((".tar", ".tgz", ".tar.gz", ".tar.xz", ".tar.bz2")):
        try:
            with tarfile.open(fileobj=io.BytesIO(raw), mode="r:*") as archive:
                total = 0
                for member in archive:
                    total += member.size
                    if total > LIMIT:
                        raise Unchecked()
                    if member.isfile():
                        stream = archive.extractfile(member)
                        if stream is None:
                            raise Unchecked()
                        inspect_archive_member(member.name, stream.read(LIMIT + 1), depth + 1)
        except (OSError, ValueError, tarfile.TarError):
            raise Unchecked() from None
        return
    try:
        text = raw.decode("utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8-sig")
    except UnicodeError:
        # Binary blobs are still searched for embedded scanner output.
        text = raw.decode("utf-8", errors="replace")
    try:
        if structured(json.loads(text)):
            raise Refused()
    except (ValueError, RecursionError):
        pass
    decoder = json.JSONDecoder()
    for match in re.finditer(r'(?m)^[ \t>]*(?P<json>[{\[])(?=[\s"{])', text):
        try:
            value, _ = decoder.raw_decode(text, match.start("json"))
            if structured(value):
                raise Refused()
        except (ValueError, RecursionError):
            continue
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    if re.search(r"(?m)^\s*Local(?: security)? report:\s+(?:/|[A-Za-z]:[\\/])", text):
        raise Refused()
    for line in text.splitlines():
        if not RESULT.search(line) and not (TOOL.search(text) and NATIVE_RESULT.search(line.strip())):
            continue
        # Executable statements describe the scanner; their output is checked
        # separately. This is not a directory exemption for source or tests.
        stripped = line.lstrip()
        if name.endswith((".py", ".sh", ".ps1", ".yml", ".yaml")) and re.match(
            r"(?:(?:[0-9]+|\*)\)\s*)?(?:print\(|echo |printf |grep |expect |"
            r"log_info |log_warn |[rubfRUBF]{0,2}[\"']|"
            r"(?:if |elif |\[\[).*|[A-Za-z_][A-Za-z_0-9]*=)", stripped
        ):
            continue
        raise Refused()
    if TOOL.search(text) and re.search(
        r"(?m)^\s*(?:RuleID|Fingerprint|StartLine|finding_counts)\s*:", text
    ):
        raise Refused()


def check_blob(repo, oid, path, seen):
    # Names are checked even when the identical blob was seen at another path.
    if REPORT_NAME.search(path.replace("\\", "/")):
        raise Refused()
    key = (oid, Path(path).suffix)
    if key not in seen:
        size = int(git(repo, "cat-file", "-s", oid))
        if size > LIMIT:
            raise Unchecked()
        try:
            inspect(path, git(repo, "cat-file", "blob", oid))
        except Refused as exc:
            raise Refused(path, exc.tool) from None
        seen.add(key)


def check_tree(repo, ref, seen, changed=None):
    for entry in git(repo, "ls-tree", "-r", "-z", ref).split(b"\0"):
        if not entry:
            continue
        info, path = entry.split(b"\t", 1)
        mode, kind, oid = info.split()
        if kind != b"blob" or (changed is not None and path not in changed):
            continue
        check_blob(repo, oid.decode("ascii"), os.fsdecode(path), seen)


def check_commits(repo, revs, seen):
    commits = git(repo, "rev-list", *revs, "--").splitlines()
    for commit in commits:
        ref = commit.decode("ascii")
        inspect("message", git(repo, "show", "-s", "--format=%B", ref))
        changed = set(git(
            repo, "diff-tree", "--root", "--no-commit-id", "-r", "-m",
            "--no-renames", "--name-only", "--diff-filter=ACMT", "-z", ref,
        ).split(b"\0"))
        check_tree(repo, ref, seen, changed)


def push(repo, refs, remote, seen):
    lines = Path(refs).read_text().splitlines()
    if not lines:
        raise Unchecked()
    for line in lines:
        fields = line.split()
        if len(fields) != 4:
            raise Unchecked()
        local_ref, local, _, old = fields
        if not all(re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", s) for s in (local, old)):
            raise Unchecked()
        if set(local) == {"0"} or local == old:
            continue
        if local_ref.startswith("refs/heads/"):
            os.environ["SH_SECURITY_BRANCH"] = local_ref[len("refs/heads/"):]
        target = local
        while git(repo, "cat-file", "-t", target).strip() == b"tag":
            tag = git(repo, "cat-file", "tag", target)
            headers, body = tag.split(b"\n\n", 1)
            inspect("tag-message", body)
            target = headers.splitlines()[0].split()[1].decode("ascii")
        if git(repo, "cat-file", "-t", target).strip() != b"commit":
            raise Unchecked()
        if set(old) != {"0"}:
            base = git(repo, "rev-parse", "--verify", old + "^{commit}").strip().decode("ascii")
            revs = [target, "^" + base]
        else:
            revs = [target]
        # Commits already on this destination do not cross the transport boundary.
        remotes = git(repo, "remote").decode().splitlines()
        if remote in remotes:
            revs.extend(["--not", "--remotes=" + remote])
        check_commits(repo, revs, seen)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--staged", action="store_true")
    modes.add_argument("--push-refs")
    modes.add_argument("--range")
    modes.add_argument("--tree")
    modes.add_argument("--file", action="append")
    modes.add_argument("--stdin", action="store_true")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--remote", default="")
    args = parser.parse_args()
    seen = set()
    try:
        if args.file:
            for name in args.file:
                with open(name, "rb") as stream:
                    resolved = str(Path(name).resolve())
                    if REPORT_NAME.search(name.replace("\\", "/")):
                        raise Refused(name)
                    raw = stream.read(LIMIT + 1)
                    inspect(name, raw)
                    if name != resolved:
                        inspect(resolved, raw)
                    probe = subprocess.run(["git", "-C", str(Path(resolved).parent), "rev-parse", "--show-toplevel"], capture_output=True, env={k: v for k, v in os.environ.items() if not k.startswith("GIT_")})
                    if probe.returncode == 0:
                        root = Path(os.fsdecode(probe.stdout).strip())
                        try:
                            relative = Path(resolved).relative_to(root).as_posix()
                        except ValueError:
                            raise Unchecked() from None
                        if REPORT_NAME.search(relative):
                            raise Refused(name)
        elif args.stdin:
            inspect("stdin", sys.stdin.buffer.read(LIMIT + 1))
        elif args.staged:
            changed = set(git(args.repo, "diff", "--cached", "--name-only", "-z", "--diff-filter=ACMT").split(b"\0"))
            for entry in git(args.repo, "ls-files", "--stage", "-z").split(b"\0"):
                if entry:
                    info, path = entry.split(b"\t", 1)
                    mode, oid, stage = info.split()
                    if path in changed and mode != b"160000":
                        if stage != b"0":
                            raise Unchecked()
                        check_blob(args.repo, oid.decode("ascii"), os.fsdecode(path), seen)
        elif args.push_refs:
            push(args.repo, args.push_refs, args.remote, seen)
        elif args.tree:
            if args.tree.startswith("-"):
                raise Unchecked()
            check_tree(args.repo, args.tree, seen)
        else:
            if args.range.startswith("-"):
                raise Unchecked()
            check_commits(args.repo, [args.range], seen)
    except Refused as exc:
        subprocess.run([BASH, Path(__file__).with_name("security_notice.sh").as_posix(), exc.tool], check=False)
        if not (os.environ.get("CI") or os.environ.get("GITHUB_ACTIONS")):
            print("Publication refused: scanner results must stay local. Remove them from the index and outgoing commits; inspect reports outside this checkout.", file=sys.stderr)
            if exc.args:
                print("Local file to inspect: " + str(exc.args[0]), file=sys.stderr)
        return 1
    except (Unchecked, OSError, ValueError, RecursionError, IndexError, zlib.error):
        subprocess.run([BASH, Path(__file__).with_name("security_notice.sh").as_posix(), "Security"], check=False)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
