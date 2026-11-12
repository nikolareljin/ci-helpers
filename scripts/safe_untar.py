#!/usr/bin/env python3
"""Unpack a bundle directory a build job tarred, without trusting the tar.

    /usr/bin/python3 -I safe_untar.py TARBALL DEST TOP_RE

The tarball came from a job that ran the caller's code. It must hold
exactly one top-level directory whose name matches TOP_RE whole, and under
it only directories, regular files and relative symlinks that resolve
inside that directory. Refused: absolute or `..` paths, a backslash, a
control character, a hard link, a device or fifo, a duplicate name, a
member under a symlink, and more than 8 GiB in all. Members are written by
this script, not by tar, into DEST, which must be an empty directory.
Modes are 0755 for a file with any execute bit, else 0644; owners, times
and extended headers are dropped.

Prints the top-level name. Exit 0 on success, 1 on a refusal, 2 on usage.
Runs on the macOS system Python (3.9).
"""
import os
import posixpath
import re
import sys
import tarfile
from pathlib import Path

LIMIT = 8 << 30
BAD_CHARS = re.compile(r"[\x00-\x1f\x7f\\]")


def fail(msg):
    print(f"::error::{msg}", file=sys.stderr)
    sys.exit(1)


def check_path(name):
    if not name or name.startswith("/") or BAD_CHARS.search(name):
        fail(f"tar member {name!r} is absolute or holds a control character or backslash.")
    parts = name.rstrip("/").split("/")
    if any(p in ("", ".", "..") for p in parts):
        fail(f"tar member {name!r} has an empty, . or .. component.")
    return "/".join(parts)


def main(argv):
    if len(argv) != 4:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    tarball, dest, top_re = argv[1], argv[2], argv[3]
    top_pat = re.compile(top_re)
    if not os.path.isdir(dest) or os.path.islink(dest):
        fail(f"{dest} is not a directory.")
    if any(Path(dest).iterdir()):
        fail(f"{dest} is not empty.")
    if not os.path.isfile(tarball) or os.path.islink(tarball):
        fail(f"{tarball} is not a regular file.")

    members = []
    seen = set()
    links = set()
    total = 0
    top = None
    with tarfile.open(tarball, "r:gz") as tf:
        for m in tf:
            name = check_path(m.name)
            first = name.split("/")[0]
            if top is None:
                top = first
                if not top_pat.fullmatch(top):
                    fail(f"the top-level name {top!r} does not match {top_re}.")
            elif first != top:
                fail(f"the tarball holds more than one top-level entry ({top!r}, {first!r}).")
            if name in seen:
                fail(f"tar member {name!r} appears twice.")
            seen.add(name)
            if m.isdir():
                kind = "d"
            elif m.isreg():
                kind = "f"
                total += m.size
                if total > LIMIT:
                    fail("the tarball unpacks to more than 8 GiB.")
            elif m.issym():
                kind = "l"
                target = m.linkname
                if not target or target.startswith("/") or BAD_CHARS.search(target):
                    fail(f"symlink {name!r} points to {target!r}, not a relative path.")
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
                if resolved != top and not resolved.startswith(top + "/"):
                    fail(f"symlink {name!r} points outside {top!r} ({target!r}).")
                if name == top:
                    fail(f"the top-level entry {top!r} is a symlink.")
                links.add(name)
            else:
                fail(f"tar member {name!r} is not a file, directory or symlink.")
            if name == top and kind != "d":
                fail(f"the top-level entry {top!r} is not a directory.")
            members.append((m, name, kind))

        if top is None:
            fail("the tarball is empty.")
        # No member may sit under a symlink, whichever comes first in the
        # tar: writing it would follow the link.
        for m, name, kind in members:
            parent = posixpath.dirname(name)
            while parent:
                if parent in links:
                    fail(f"tar member {name!r} is under the symlink {parent!r}.")
                parent = posixpath.dirname(parent)
        # Directories first so every parent exists; files and links after.
        os.mkdir(os.path.join(dest, top), 0o755)
        for m, name, kind in members:
            path = os.path.join(dest, *name.split("/"))
            if kind == "d" and name != top:
                os.makedirs(path, 0o755, exist_ok=True)
        for m, name, kind in members:
            path = os.path.join(dest, *name.split("/"))
            parent = os.path.dirname(path)
            os.makedirs(parent, 0o755, exist_ok=True)
            real_parent, real_dest = os.path.realpath(parent), os.path.realpath(dest)
            if os.path.islink(parent) or not (real_parent == real_dest or real_parent.startswith(real_dest + os.sep)):
                fail(f"the parent of {name!r} is not a directory inside {dest}.")
            if kind == "f":
                src = tf.extractfile(m)
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
                             0o755 if m.mode & 0o111 else 0o644)
                with os.fdopen(fd, "wb") as out:
                    while True:
                        chunk = src.read(1 << 20)
                        if not chunk:
                            break
                        out.write(chunk)
            elif kind == "l":
                os.symlink(m.linkname, path)
    print(top)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
