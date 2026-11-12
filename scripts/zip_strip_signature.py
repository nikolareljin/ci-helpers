#!/usr/bin/env python3
"""Copy a zip (an .aab) without its JAR signature, so jarsigner signs it once.

    /usr/bin/python3 -I zip_strip_signature.py IN OUT

Drops META-INF/MANIFEST.MF and every META-INF/*.SF, *.RSA, *.DSA and *.EC
entry (the debug or upload signature the build left); every other entry is
copied byte for byte with its compression. An entry name that is absolute,
holds a `..` component, a backslash or a control character is refused, as
is a name that appears twice. Exit 0 on success, 1 on a refusal, 2 on usage.
"""
import re
import sys
import zipfile

SIG = re.compile(r"META-INF/(MANIFEST\.MF|[^/]+\.(SF|RSA|DSA|EC))", re.I)
BAD = re.compile(r"[\x00-\x1f\x7f\\]")


def main(argv):
    if len(argv) != 3:
        print("usage: zip_strip_signature.py IN OUT", file=sys.stderr)
        return 2
    seen = set()
    with zipfile.ZipFile(argv[1]) as zin, zipfile.ZipFile(argv[2], "x") as zout:
        for info in zin.infolist():
            name = info.filename
            if name.startswith("/") or BAD.search(name) or ".." in name.split("/") or name in seen:
                print(f"::error::zip entry {name!r} is absolute, repeated, or holds .., a backslash or a control character.", file=sys.stderr)
                return 1
            seen.add(name)
            if SIG.fullmatch(name):
                continue
            zout.writestr(info, zin.read(info), compress_type=info.compress_type)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
