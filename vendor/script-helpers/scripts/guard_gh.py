"""Validate supported gh publication payloads before the real CLI sends them."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

TOOL_NAME = "Security"
BASH = shutil.which("bash") or "bash"


def main():
    global TOOL_NAME
    if sys.argv[1:] in (["-h"], ["--help"]):
        print(__doc__)
        return 0
    executable, *args = sys.argv[1:]
    if not args:
        return subprocess.call([executable])
    text_flags = {"--body", "-b", "--title", "-t", "--notes", "-n", "--name"}
    file_flags = {"--body-file", "--notes-file", "--input", "--template"}
    field_flags = {"--field", "-F", "--raw-field", "-f"}
    command_start = 0
    while command_start < len(args) and args[command_start].startswith("-"):
        token = args[command_start]
        if token in {"-R", "--repo", "--hostname"}:
            command_start += 2
        elif token.startswith(("--repo=", "--hostname=")) or token.startswith("-R") and len(token) > 2:
            command_start += 1
        elif token in {"--help", "-h", "--version"}:
            return subprocess.call([executable, *args])
        else:
            return 1
    if command_start >= len(args):
        return 1
    family = args[command_start]
    verb = args[command_start + 1] if len(args) > command_start + 1 else ""
    publishing = family == "api" or family in {"pr", "issue", "release", "gist"} and verb in {
        "create", "edit", "comment", "review", "upload",
    }
    if not publishing:
        return subprocess.call([executable, *args])
    if family != "api":
        field_flags.discard("-F")
        file_flags.add("-F")
    if any(flag.split("=", 1)[0] in {"--web", "--fill", "--fill-first", "--fill-verbose", "--generate-notes", "--notes-from-tag", "--template", "--recover"} for flag in args) or family == "pr" and verb == "create" and "-f" in args:
        return 1
    if family == "gist" and verb == "edit":
        return 1
    checker = Path(__file__).with_name("check_publication.sh").as_posix()
    texts = args[:]
    files = []
    rewritten = args[:]
    has_body = False
    with tempfile.TemporaryDirectory(prefix="publication-") as temp:
        os.chmod(temp, 0o700)
        i = 0
        while i < len(args):
            token = args[i]
            flag, separator, value = token.partition("=")
            if not separator and len(token) > 2 and token[:2] in text_flags | file_flags | field_flags:
                flag, separator, value = token[:2], "=", token[2:]
            recognized = flag in text_flags | file_flags | field_flags
            if recognized:
                if not separator:
                    i += 1
                    if i >= len(args):
                        return 1
                    value = args[i]
                if flag in text_flags:
                    texts.append(value)
                    has_body = has_body or flag in {"--body", "-b", "--notes", "-n"}
                elif flag in field_flags:
                    if "=" not in value:
                        return 1
                    field = value.split("=", 1)[1]
                    if field.startswith("@"):
                        files.append(field[1:])
                    else:
                        texts.append(field)
                else:
                    has_body = True
                    if value == "-":
                        path = Path(temp) / "input"
                        path.write_bytes(sys.stdin.buffer.read())
                        path.chmod(0o600)
                        value = str(path)
                        rewritten[i] = flag + "=" + value if separator else value
                    files.append(value)
            i += 1
        if family == "release" and verb in {"create", "upload"} or family == "gist" and verb == "create":
            # Tag and asset operands, excluding option values.
            operands = []
            i = command_start + 2
            while i < len(args):
                token = args[i]
                if token in text_flags | file_flags | field_flags | {"--repo", "-R", "--target", "--discussion-category", "--description", "-d"}:
                    i += 2
                    continue
                if not token.startswith("-"):
                    operands.append(token)
                i += 1
            files.extend(name.split("#", 1)[0] for name in (operands if family == "gist" else operands[1:]))
        has_body = has_body or family == "gist" and verb == "create" and bool(files)
        has_body = has_body or family == "pr" and verb == "review" and any(a in args for a in ("--approve", "-a"))
        if family in {"pr", "issue", "release", "gist"} and verb in {"create", "comment", "review"} and not has_body:
            return 1
        payload = Path(temp) / "text"
        payload.write_text("\n".join(texts))
        payload.chmod(0o600)
        for path in [str(payload), *files]:
            if path == "-" or not Path(path).is_file():
                return 1
            result = subprocess.run([BASH, checker, "--file", path], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                for tool in ("Gitleaks", "Foxguard"):
                    if result.stderr.startswith((tool + " check failed.").encode()):
                        TOOL_NAME = tool
                return 1
        response = subprocess.run([executable, *rewritten], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for name, data in (("stdout", response.stdout), ("stderr", response.stderr)):
            path = Path(temp) / name
            path.write_bytes(data)
            path.chmod(0o600)
            result = subprocess.run([BASH, checker, "--file", str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if result.returncode:
                return 1
        sys.stdout.buffer.write(response.stdout)
        sys.stderr.buffer.write(response.stderr)
        return response.returncode


if __name__ == "__main__":
    try:
        status = main()
    except (OSError, ValueError):
        status = 1
    if status:
        subprocess.run([BASH, Path(__file__).with_name("security_notice.sh").as_posix(), TOOL_NAME], check=False)
    sys.exit(status)
