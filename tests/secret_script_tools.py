#!/usr/bin/env python3
"""List the command names a shell script calls, one per line.

    python3 tests/secret_script_tools.py scripts/github_release.sh

A line-based reading, enough for the library's own scripts: the first word
of each simple command, after `;`, `&&`, `||`, `|`, `$(`, `then`, `do`,
`else`, `if`, `!` and `while`. Assignments, words with quotes or `$` in them,
shell keywords and the functions the script defines are left out.
"""
import re
import sys

KEYWORDS = {"if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until",
            "case", "esac", "function", "select", "time", "{", "}", "[[", "]]", "!", "local",
            "return", "exit", "set", "shift", "export", "readonly", "declare", "unset", "echo",
            "printf", "read", "trap", "cd", "test", "[", "true", "false", ":", "break",
            "continue", "eval", "exec", "command", "type", "mapfile", "wait", "umask", "pwd",
            "source", ".", "shopt", "getopts", "let", "builtin", "hash", "kill"}
SPLIT = re.compile(r";|&&|\|\||\||\$\(|`|\bthen\b|\bdo\b|\belse\b|\bif\b|\bwhile\b|\buntil\b|!\s")


def tools(text: str) -> set[str]:
    funcs = set(re.findall(r"^\s*([A-Za-z_][\w-]*)\s*\(\)", text, re.M))
    found = set()
    heredoc = None
    for raw in text.splitlines():
        if heredoc:
            if raw.strip() == heredoc:
                heredoc = None
            continue
        m = re.search(r"<<-?\s*'?\"?([A-Za-z_]+)", raw)
        line = re.sub(r"(^|\s)#.*$", "", raw)
        line = re.sub(r"'[^']*'", "''", line)
        # Text in double quotes, but a command substitution inside stays.
        line = re.sub(r'"(?:[^"$\\]|\\.|\$(?!\())*"', '""', line)
        for part in SPLIT.split(line):
            words = part.strip().split()
            while words and re.match(r"^[A-Za-z_]\w*=", words[0]):
                words.pop(0)
            if not words:
                continue
            w = words[0].lstrip("(")
            if w in KEYWORDS or w in funcs or not re.match(r"^[a-z][a-z0-9_.+-]*$", w):
                continue
            found.add(w)
        if m:
            heredoc = m.group(1)
    return found


if __name__ == "__main__":
    for name in sorted(set().union(*(tools(open(p, encoding="utf-8").read()) for p in sys.argv[1:]))):
        print(name)
