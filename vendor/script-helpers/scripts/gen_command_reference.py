#!/usr/bin/env python3
"""Generate docs/commands.md from the headers of the scripts in scripts/.

USAGE: python3 scripts/gen_command_reference.py [--check]
  --check  Exit 1 when docs/commands.md differs from what this would write.
EXIT CODES: 0 written or up to date; 1 out of date (--check); 2 bad arguments.

Each script documents itself in its header (SCRIPT, DESCRIPTION, USAGE,
PARAMETERS, EXIT_CODES). The page is built from those headers only, so it
cannot say more than the scripts do. Exit codes a header leaves out are listed
as the literal `exit N` values found in the script.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "docs", "commands.md")
DIRS = ["scripts", "scripts/git-hooks", "scripts/global-hooks",
        "scripts/agent-hooks", "scripts/claude-hooks"]
KEY = re.compile(r"^#\s*([A-Z][A-Z_ ]+):\s?(.*)$")

GROUPS = [
    ("Git hooks and setup", lambda n, d: d != "scripts" or n.startswith(("setup-hooks", "push_checks", "security_hooks", "owner_scope", "ssh_keepalive", "foxguard_report", "run_repo_tests"))),
    ("Security and release checks", lambda n, d: n.startswith(("check_", "refresh_private", "ci_gitleaks", "ci_security", "bump_version", "tag_release", "release_notes", "pin_production", "prune_branches", "preflight"))),
    ("CI runners", lambda n, d: n.startswith("ci_")),
    ("Local test runners", lambda n, d: n.startswith("local_test_")),
    ("Packaging", lambda n, d: n.startswith(("build_", "gen_brew", "render_brew", "publish_homebrew", "ppa_upload", "packaging_init"))),
    ("Examples", lambda n, d: n.startswith("example_")),
    ("Other tools", lambda n, d: True),
]


def header_lines(text):
    """Comment lines at the top of a shell script, up to a ---- rule or code."""
    out = []
    for i, line in enumerate(text.splitlines()):
        if i == 0 and line.startswith("#!"):
            continue
        if not line.startswith("#"):
            break
        if re.match(r"^#\s*-{4,}", line):
            break
        out.append(line)
    return out


def parse_shell(text):
    fields, cur = {}, None
    for line in header_lines(text):
        m = KEY.match(line)
        if m and m.group(1).strip().replace(" ", "_") in (
                "SCRIPT", "DESCRIPTION", "USAGE", "PARAMETERS", "EXIT_CODES", "EXAMPLE"):
            cur = m.group(1).strip().replace(" ", "_")
            fields[cur] = [m.group(2)] if m.group(2) else []
        elif cur:
            fields[cur].append(re.sub(r"^# ?", "", line))
    if "DESCRIPTION" not in fields:
        first = [re.sub(r"^#\s*", "", ln) for ln in header_lines(text)]
        first = [ln for ln in first if ln and not ln.startswith("shellcheck")]
        if first:
            fields["DESCRIPTION"] = [first[0]]
    return fields


def parse_ps1(text):
    m = re.search(r"\.SYNOPSIS\s*\n\s*(.+)", text)
    return {"DESCRIPTION": [m.group(1).strip()]} if m else {}


def parse_py(text):
    """The module docstring: first line, USAGE and EXIT CODES sections (or an
    inline `Exit:` line), each section being its inline text plus the indented
    lines under it. Without USAGE, the first indented block is the usage."""
    m = re.search(r'^(?:#[^\n]*\n)*\s*"""(.*?)"""', text, re.S)
    if not m:
        return {}
    lines = m.group(1).strip("\n").splitlines()
    fields = {"DESCRIPTION": [lines[0].strip()]}
    for i, ln in enumerate(lines[1:], 1):
        k = re.match(r"^(USAGE|EXIT CODES|EXIT_CODES|Exit codes|Exit):\s*(.*)$", ln)
        if not k:
            continue
        name = "USAGE" if k.group(1) == "USAGE" else "EXIT_CODES"
        body = [k.group(2)] if k.group(2) else []
        for nxt in lines[i + 1:]:
            if not nxt.startswith(" "):
                break
            body.append(nxt.rstrip())
        fields[name] = body
    if "USAGE" not in fields:
        body = []
        for ln in lines[1:]:
            if ln.startswith(" ") and ln.strip():
                body.append(ln.rstrip())
            elif body:
                break
        if body:
            fields["USAGE"] = body
    return fields


def exit_values(text):
    vals = sorted({int(v) for v in re.findall(r"\b(?:exit\s+|sys\.exit\()([0-9]+)\b", text)})
    return ", ".join(str(v) for v in vals)


def block(lines):
    lines = [ln.rstrip() for ln in lines]
    while lines and not lines[-1].strip():
        lines.pop()
    while lines and not lines[0].strip():
        lines.pop(0)
    return lines


def ascii(s):
    return (s.replace("\u2014", "-").replace("\u2013", "-").replace("\u2018", "'")
            .replace("\u2019", "'").replace("\u201c", '"').replace("\u201d", '"')
            .replace("\u2026", "...").replace("\u2192", "->"))


def entry(rel, fields, text):
    out = ["### `%s`" % rel, ""]
    desc = " ".join(x.strip() for x in block(fields.get("DESCRIPTION", [])))
    out += [desc or "No description in the header.", ""]
    usage = block(fields.get("USAGE", []))
    params = block(fields.get("PARAMETERS", []))
    if usage or params:
        if usage and usage[0][:1] == " ":
            usage = ["Usage:"] + usage
        elif usage:
            usage = ["Usage: " + usage[0]] + usage[1:]
        out += ["```text"] + usage + params + ["```", ""]
    codes = block(fields.get("EXIT_CODES", []))
    if usage and usage[0].lstrip().startswith("source"):
        pass  # a sourced library: its functions return, the file never exits
    elif codes:
        if len(codes) == 1:
            out += ["Exit codes: " + codes[0].strip(), ""]
        else:
            out += ["Exit codes:", "", "```text"] + [c.strip() for c in codes if c.strip()] + ["```", ""]
    else:
        found = exit_values(text)
        out += [("Exit codes: not in the header; the script exits with " + found + ".") if found
                else "Exit codes: not in the header; the script has no explicit `exit`.", ""]
    return out


def collect():
    items = []
    for d in DIRS:
        path = os.path.join(ROOT, d)
        if not os.path.isdir(path):
            continue
        for name in sorted(os.listdir(path)):
            full = os.path.join(path, name)
            if not os.path.isfile(full) or name.startswith("."):
                continue
            # Bytes, decoded leniently: a Latin-1 comment or a binary in scripts/
            # must not crash the page (a crash reads as "out of date" in --check).
            with open(full, "rb") as fh:
                raw = fh.read()
            text = ascii(raw.decode("utf-8", errors="replace").replace("\r\n", "\n"))
            if name.endswith(".ps1"):
                fields = parse_ps1(text)
            elif name.endswith(".py"):
                fields = parse_py(text)
            elif text.startswith("#!") or name.endswith(".sh"):
                fields = parse_shell(text)
            else:
                continue
            items.append((d, name, fields, text))
    return items


def render():
    out = ["# Command reference", "",
           "Every script under `scripts/`, from its own header. In a repository that",
           "vendors script-helpers, the paths start with `scripts/script-helpers/`.",
           "Most scripts print the same text with `-h` or `--help`.", "",
           "This page is generated by `scripts/gen_command_reference.py`; edit the",
           "script header, then run it. The library's functions are in the",
           "[API index](api.md).", ""]
    items, done = collect(), set()
    for title, pred in GROUPS:
        sel = [it for it in items if (it[0], it[1]) not in done and pred(it[1], it[0])]
        if not sel:
            continue
        out += ["## " + title, ""]
        for d, name, fields, text in sel:
            done.add((d, name))
            out += entry(d + "/" + name, fields, text)
    return "\n".join(out).rstrip() + "\n"


def main(argv):
    if argv not in ([], ["--check"]):
        sys.stderr.write("usage: gen_command_reference.py [--check]\n")
        return 2
    page = render()
    if argv == ["--check"]:
        cur = open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
        if cur != page:
            sys.stderr.write("docs/commands.md is out of date: run python3 scripts/gen_command_reference.py\n")
            return 1
        return 0
    # LF on every platform: Windows text mode would write CRLF and rewrite the page.
    with open(OUT, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(page)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
