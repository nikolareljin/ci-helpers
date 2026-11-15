"""Inspect Git objects and publication text without printing scanner results."""

import argparse
import bz2
import csv
import gzip
import lzma
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import struct
import sys
import tarfile
import tempfile
import time
import zipfile
import zlib

try:
    from compression.zstd import ZstdDecompressor, ZstdError
except ImportError:
    ZstdDecompressor = None

    class ZstdError(Exception):
        pass


class Refused(Exception):
    def __init__(self, path=None, tool="Security"):
        super().__init__(*(() if path is None else (path,)))
        self.tool = tool


class Unchecked(Exception):
    pass


class Anomaly(Exception):
    """A large object that could not be fully checked; the argument is a reason class."""


REPORT_NAME = re.compile(
    r"(?i)^(?:scans|scan-results|security-reports)/|\.sarif(?:\.(?:gz|bz2|xz|zip))?$|"
    r"(?:^|/)[^/]*(?:gitleaks|foxguard)[^/]*\.(?:json|sarif|log|html|csv)(?:\.(?:gz|bz2|xz|zip))?$"
)
TOOL = re.compile(r"gitleaks|foxguard", re.I)
RESULT = re.compile(
    r"(?i)\b(?:gitleaks|foxguard)(?![\w.-]).{0,80}"
    r"\b\d+\s+(?:findings?|leaks?|hits?|credentials?)\b|"
    r"\b(?:gitleaks|foxguard)\s*[:=]?\s*(?:clean|no leaks|no findings)\b|"
    r"\b(?:gitleaks|foxguard)\s+(?:findings?|leaks?|hits?|credentials?)\s*[:=]\s*\d+\b|"
    r"\bno gitleaks findings\b|\bgitleaks findings detected\s*:|"
    r"\b(?:gitleaks|foxguard)\s*[:=]?\s*\d+\s*(?:[,;]|$)|"
    r"\b\d+\s+(?:gitleaks|foxguard)\s+(?:findings?|leaks?|hits?|credentials?)\b"
)
NATIVE_RESULT = re.compile(
    r"(?i)^(?:\d{1,2}:\d{2}(?::\d{2})?(?:AM|PM)?\s+)?"
    r"(?:(?:INF|WRN|ERR)\s+)?(?:no leaks found\.?|leaks found\s*:\s*\d+|\d+\s+leaks? found)\s*$"
)
MIB = 1024 * 1024
# Objects up to LIMIT are inspected whole (text, JSON, archives). Larger binary
# executables up to MAX_BYTES are streamed in CHUNK pieces; see inspect_large.
LIMIT = 64 * MIB
MAX_MIB_CAP = 2048
MAX_BYTES = MAX_MIB_CAP * MIB
CHUNK = 8 * MIB
# Every pattern this file matches is shorter than OVERLAP, so a match that
# crosses a chunk boundary lies whole inside the next window.
OVERLAP = 64 * 1024
# A JSON report can be larger than one window, so its keys alone are an anomaly.
STREAM_JSON_REPORT = re.compile(rb'(?i)"(?:ruleid|fingerprint|finding_counts)"\s*:')
# Only executables are streamed: ELF, Mach-O (thin and fat) and PE.
STREAM_FORMATS = (b"\x7fELF", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe",
                  b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"MZ")
# Embedded compressed or archived data. Each hit is decoded and scanned; a hit
# that does not decode is stray bytes (Go binaries carry these magics as code).
STREAM_PACKED = re.compile(b"|".join([re.escape(magic) for magic in (
    b"\x1f\x8b\x08", b"\xfd7zXZ\x00", b"PK\x03\x04", b"7z\xbc\xaf\x27\x1c", b"\x28\xb5\x2f\xfd", b"ustar",
)] + [b"BZh[1-9]"]))
MEMBER_MAX = 64 * MIB      # decoded bytes per embedded member
DECODED_MAX = 512 * MIB    # decoded bytes per large object
SIGNATURES_MAX = 4096      # signature hits per large object
DECODE_SECONDS = 300       # wall time per large object
BUDGET_SPENT = ("decode limit reached", "time limit reached", "too many embedded signatures")
ANOMALIES = []
NON_BLOCKING = [False]
BASH = shutil.which("bash") or "bash"


# File types. A built binary or package gets the secrets-only profile in
# check_sensitive.sh (--binary): credentials and a local home path still block;
# personal-data patterns and the CI runner's home path do not.
SPLIT_PART = re.compile(r"\.split-[0-9]{3}$")
MACHO = (b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe")
PACKAGE_MARKERS = {"AndroidManifest.xml", "classes.dex", "BundleConfig.pb",
                   "base/manifest/AndroidManifest.xml", "META-INF/MANIFEST.MF"}
HEAD = 4096
# Printable runs for --strings and --binary input: UTF-8, UTF-16LE and UTF-16BE
# (ASCII and Latin-1 code points), at least 3 characters, the shortest personal term.
STRINGS_UTF8 = re.compile(rb"(?:[\t\n\r\x20-\x7e]|[\xc2-\xdf][\x80-\xbf]|[\xe0-\xef][\x80-\xbf]{2}"
                          rb"|[\xf0-\xf4][\x80-\xbf]{3}){3,}")
STRINGS_LE = re.compile(rb"(?:[\x20-\x7e\xa0-\xff]\x00){3,}")
STRINGS_BE = re.compile(rb"(?:\x00[\x20-\x7e\xa0-\xff]){3,}")
# No run crosses a control byte (other than tab, LF, CR) or two NULs.
STRINGS_BREAK = re.compile(rb"[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]|\x00\x00")
CURRENT = [""]
NOTICES = set()


def _is_text(head):
    """True when head is UTF-8 text: a renamed text file is not a split part."""
    if not head or b"\0" in head:
        return False
    try:
        head.decode("utf-8")
    except UnicodeDecodeError as exc:
        # Only a character cut at the end of head is allowed.
        return exc.start >= len(head) - 3 and exc.reason == "unexpected end of data"
    return True


def _elf_ok(head, size):
    """A structurally valid ELF header: class, byte order, type, and tables inside the file."""
    if len(head) < 64 or head[4] not in (1, 2) or head[5] not in (1, 2) or head[6] != 1:
        return False
    order = "<" if head[5] == 1 else ">"
    if head[4] == 2:
        fields = struct.unpack(order + "HHIQQQIHHHHHH", head[16:64])
        ehsize, phent, shent = 64, 56, 64
    else:
        fields = struct.unpack(order + "HHIIIIIHHHHHH", head[16:52])
        ehsize, phent, shent = 52, 32, 40
    kind, _, version, _, phoff, shoff, _, size_eh, size_ph, phnum, size_sh, shnum, _ = fields
    if not 1 <= kind <= 4 or version != 1 or size_eh != ehsize or phnum + shnum == 0:
        return False
    if phnum and (size_ph != phent or phoff < ehsize or phoff + phnum * phent > size):
        return False
    if shnum and (size_sh != shent or shoff < ehsize or shoff + shnum * shent > size):
        return False
    return True


def _macho_ok(head, size):
    """A thin Mach-O header with a load command table inside the file, or a fat header."""
    if head[:4] in MACHO:
        order = "<" if head[:4] in (b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe") else ">"
        if len(head) < 28:
            return False
        _, _, filetype, ncmds, sizeofcmds = struct.unpack(order + "iiIII", head[4:24])
        header = 32 if head[:4] in (b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe") else 28
        return 1 <= filetype <= 12 and 1 <= ncmds <= 10000 and header + sizeofcmds <= size
    count = int.from_bytes(head[4:8], "big")
    if not 1 <= count <= 30 or len(head) < 8 + 20 * count:
        return False
    for index in range(count):
        _, _, offset, length, _ = struct.unpack(">iiIII", head[8 + 20 * index:28 + 20 * index])
        if offset < 8 + 20 * count or offset + length > size:
            return False
    return True


def _pe_ok(head, size):
    if len(head) < 64:
        return False
    offset = struct.unpack("<I", head[60:64])[0]
    if offset + 24 > min(len(head), size) or head[offset:offset + 4] != b"PE\0\0":
        return False
    machine, sections = struct.unpack("<HH", head[offset + 4:offset + 8])
    optional = struct.unpack("<H", head[offset + 20:offset + 22])[0]
    return machine in (0x14C, 0x8664, 0xAA64, 0x1C0, 0x1C4) and 1 <= sections <= 96 and optional > 0


def _container(head):
    """True when head starts a format the checker decodes: gzip, xz, bzip2, zstd, zip, tar, cpio, ar, rpm."""
    return (head.startswith((b"\x1f\x8b", b"\xfd7zXZ\x00", b"\x28\xb5\x2f\xfd", b"PK\x03\x04", b"0707",
                             b"!<arch>\n", b"\xed\xab\xee\xdb"))
            or (head.startswith(b"BZh") and head[3:4].isdigit()) or head[257:262] == b"ustar")


def classify(name, head, tail=b"", names=None, size=None):
    """Return the built-binary type of a file from its magic bytes and headers, or None.

    head is the first HEAD bytes, tail the last 512, names the member names of
    a zip, size the file size. A byte-split part or a disk image is only named
    when no decodable container starts the data.
    """
    size = len(head) if size is None else size
    if head.startswith(b"\x7fELF"):
        if not _elf_ok(head, size):
            return None
        return "AppImage" if head[8:10] == b"AI" and head[10:11] in (b"\x01", b"\x02") else "ELF"
    if head[:4] in MACHO or (head.startswith(b"\xca\xfe\xba\xbe") and int.from_bytes(head[4:8], "big") < 45):
        return "Mach-O" if _macho_ok(head, size) else None
    if head.startswith(b"\xca\xfe\xba\xbe") and 45 <= int.from_bytes(head[6:8], "big") <= 80:
        return "Java class"
    if head.startswith(b"MZ"):
        return "PE" if _pe_ok(head, size) else None
    if head.startswith(b"!<arch>\n"):
        return "deb" if head[8:21] == b"debian-binary" else "ar archive"
    if head.startswith(b"\xed\xab\xee\xdb"):
        return "rpm"
    if names is not None and PACKAGE_MARKERS.intersection(names):
        return "Android or Java package"
    if _container(head):
        return None
    base = name.replace("\\", "/").rsplit("/", 1)[-1]
    if SPLIT_PART.search(base) and not _is_text(head):
        return "split part"
    if len(tail) == 512 and tail.startswith(b"koly"):
        return "disk image"
    return None


TEXT_SUFFIXES = (".txt", ".json", ".xml", ".properties", ".yaml", ".yml", ".md", ".html", ".htm", ".js",
                 ".css", ".sh", ".py", ".rb", ".kt", ".java", ".dart", ".toml", ".ini", ".cfg", ".conf",
                 ".plist", ".csv", ".env", ".pem", ".key", ".desktop", ".service", ".ts", ".c", ".h", ".rs", ".go")
DEB_CONTROL_FIELD = re.compile(rb"(?im)^(?:Maintainer|Uploaders|Original-Maintainer|XSBC-Original-Maintainer|Changed-By):.*(?:\n[ \t].*)*$")


COMPRESSED_SUFFIX = re.compile(r"(?i)\.(?:gz|z|bz2|xz|zst)$")
DOC_PREFIXES = ("usr/share/doc/", "usr/share/licenses/")
LICENSE_NAME = re.compile(r"(?i)(?:license|licence|copying|notice|notices|copyright|thirdpartynotices?"
                          r"|third-party-notices|third_party_notices)(?:\.(?:txt|md|html|rst))?"
                          r"|licenses\.[a-z0-9_-]+\.html")
DOC_FORMAT = re.compile(r"(?i)[^/]+\.(?:txt|md|html|rst)|changelog[a-z0-9._-]*|readme[a-z0-9._-]*")


def doc_member(member):
    """True for a license or documentation member path inside a package.

    member is the member's own path inside its archive. It is normalized;
    a path with a .. component never matches.
    """
    parts = [part for part in member.replace("\\", "/").split("/") if part not in ("", ".")]
    if not parts or ".." in parts:
        return False
    if LICENSE_NAME.fullmatch(parts[-1]):
        return True
    return "/".join(parts).lower().startswith(DOC_PREFIXES) and DOC_FORMAT.fullmatch(parts[-1]) is not None


def _app_bundles(archive, members):
    """Prefixes of real macOS .app bundles in a tarball: Contents/Info.plist and a Mach-O in Contents/MacOS/."""
    names = {member.name for member in members if member.isfile()}
    bundles = set()
    for member in members:
        match = re.fullmatch(r"(.*?\.app/)Contents/MacOS/[^/]+", member.name)
        if not match or not member.isfile() or match.group(1) + "Contents/Info.plist" not in names:
            continue
        stream = archive.extractfile(member)
        head = stream.read(HEAD) if stream is not None else b""
        if classify(member.name, head, size=member.size) == "Mach-O":
            bundles.add(match.group(1))
    return bundles


def looks_text(name, raw):
    """True for a text member: a text suffix, UTF-8 or UTF-16 with a BOM. Text keeps every check."""
    if name.lower().endswith(TEXT_SUFFIXES) or not raw or raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return True
    return _is_text(raw[:8192])


def classify_file(name, f):
    """classify() for a seekable file."""
    size = os.fstat(f.fileno()).st_size
    f.seek(0)
    head = f.read(HEAD)
    tail = b""
    if size >= 512:
        f.seek(size - 512)
        tail = f.read(512)
    names = None
    if head.startswith(b"PK\x03\x04"):
        try:
            f.seek(0)
            with zipfile.ZipFile(f) as archive:
                names = archive.namelist()
        except (OSError, ValueError, RuntimeError, zipfile.BadZipFile):
            names = None
    f.seek(0)
    return classify(name, head, tail, names, size)


def downgrade(category):
    """Log a policy downgrade on stderr: the checked file and a category, never content."""
    key = (CURRENT[0], category)
    if key in NOTICES:
        return
    NOTICES.add(key)
    path = re.sub(r"[\x00-\x1f\x7f]", "?", CURRENT[0] or "input")
    print("NOTICE: security policy: " + path + ": " + category, file=sys.stderr)


def strings(data, out, final=True):
    """Write the printable runs of data to out, one per line. Return the unread tail.

    With final False the tail that may continue in the next block is returned
    instead of written: no run contains a byte STRINGS_BREAK matches.
    """
    cut = len(data)
    if not final:
        cut = 0
        start = max(0, len(data) - MIB)
        for match in STRINGS_BREAK.finditer(data, start):
            cut = match.end()
        if cut == 0 and len(data) > MIB:
            cut = len(data) - OVERLAP
    block = data[:cut]
    for match in STRINGS_UTF8.finditer(block):
        out.write(match.group() + b"\n")
    for pattern, codec in ((STRINGS_LE, "utf-16-le"), (STRINGS_BE, "utf-16-be")):
        for match in pattern.finditer(block):
            out.write(match.group().decode(codec).encode("utf-8") + b"\n")
    return data[cut:]


def strings_of(raw):
    out = io.BytesIO()
    strings(raw, out)
    return out.getvalue()


def write_strings(path):
    """--strings: the printable runs of a file, streamed to stdout."""
    out = sys.stdout.buffer
    with Path(path).open("rb") as stream:
        carry = b""
        while True:
            chunk = stream.read(CHUNK)
            if not chunk:
                break
            carry = strings(carry + chunk, out, final=False)
        strings(carry, out)
    out.flush()


def run_sensitive(raw, binary):
    """check_sensitive.sh on raw; with binary, on its printable runs with --binary."""
    proc = subprocess.run(
        [BASH, Path(__file__).with_name("check_sensitive.sh").as_posix(), "--stdin", "--no-inline-allow",
         "--binary" if binary else "--no-inline-allow"],
        input=raw, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    return proc.returncode


def _label(name):
    """The name line for check_sensitive.sh: a member name, never the checked file's own path.

    The path is local (a home directory, a build directory), not content the file carries.
    """
    current = CURRENT[0]
    # main() also checks the resolved path (/private/var on macOS for /var).
    for outer in ((current, os.path.abspath(current), str(Path(current).resolve())) if current else ()):
        if name == outer:
            return b""
        if name.startswith(outer + ":"):
            name = name[len(outer) + 1:]
            break
    return os.fsencode(name) + b"\n"


def _sensitive_or_raise(payload, binary):
    status = run_sensitive(payload, binary)
    if status == 1:
        raise Refused()
    if status:
        raise Unchecked()


def inspect_archive_member(name, raw, depth, binary=False, member=None):
    """Check one member. binary means the member is inside a built binary or package.

    Only a member that is itself a built binary, or binary data inside a
    package, gets the secrets-only profile; a text member keeps every check.
    """
    kind = classify(name, raw[:HEAD], raw[-512:] if len(raw) >= 512 else b"", size=len(raw))
    decoded = inspect(name, raw, depth, binary=binary or kind is not None, member=member)
    label = _label(name)
    # Binary diffs and archive scanners can omit member names and link targets.
    # A container's own bytes: each member gets its own check, so only secrets,
    # terms and identifiers are looked for across them (tar owner names, say).
    # Only bytes _inspect actually decoded count: magic bytes alone do not.
    if kind is not None or decoded or (binary and not looks_text(name, raw)):
        _sensitive_or_raise(label + strings_of(raw), True)
        return
    if binary and doc_member(name if member is None else member):
        # License and copyright text of a package: email, phone, SSN and card
        # patterns do not block; secrets, terms, identifiers and home paths do.
        downgrade("license or documentation text in a package: personal-data patterns do not block")
        _sensitive_or_raise(label + raw.replace(b"\0", b" "), True)
        return
    base = name.replace("\\", "/").rsplit("/", 1)[-1]
    if binary and base == "control" and raw.startswith(b"Package:"):
        # A deb control file: only its maintainer fields get the secrets-only profile.
        fields = b"\n".join(m.group() for m in DEB_CONTROL_FIELD.finditer(raw))
        if fields:
            downgrade("deb control maintainer fields: personal-data patterns do not block")
            _sensitive_or_raise(label + fields, True)
            raw = DEB_CONTROL_FIELD.sub(b"", raw)
    _sensitive_or_raise(label + raw.replace(b"\0", b" "), False)


def opaque_in_binary(name, raw, what):
    """Data in a built binary that cannot be decoded: scan its raw bytes for secrets only."""
    downgrade(what + " in a built binary was not decoded; its raw bytes were checked for secrets only")
    status = run_sensitive(_label(name) + strings_of(raw), True)
    if status == 1:
        raise Refused()
    if status:
        raise Unchecked()


def _checked(pending, check, *args):
    """Run one member check; an Anomaly is kept so later members are still checked."""
    try:
        check(*args)
    except Anomaly as exc:
        pending.append(exc)


def _read_exact(f, size):
    data = f.read(size)
    if len(data) != size:
        raise Unchecked()
    return data


def _package_member(label, stream, size, depth, package=True, member=None):
    """One member of a deb or rpm: read whole, or spooled and streamed above LIMIT.

    label is outer:member for messages; member is the path inside the archive.
    """
    if size <= LIMIT:
        inspect_archive_member(label, _read_exact(stream, size), depth, binary=package, member=member)
        return
    with tempfile.TemporaryFile() as spool:
        left = size
        while left:
            piece = stream.read(min(CHUNK, left))
            if not piece:
                raise Unchecked()
            spool.write(piece)
            left -= len(piece)
        spool.flush()
        spool.seek(0)
        magic = spool.read(6)
        compressed = magic.startswith((b"\x1f\x8b", b"BZh", b"\xfd7zXZ"))
        if magic.startswith(b"\x28\xb5\x2f\xfd"):
            if ZstdDecompressor is None:
                downgrade("zstd data (no zstd decoder) in a built binary was not decoded;"
                          " its raw bytes were checked for secrets only")
            else:
                compressed = True
        if not compressed:
            status = _sensitive_spool(label, spool)
            if status == 1:
                raise Refused()
            if status:
                raise Unchecked()
        if compressed:
            _large_tar(label, spool, depth)
        elif not magic.startswith(b"\x28\xb5\x2f\xfd"):
            try:
                inspect_large(label, spool)
            except Anomaly as exc:
                # Its raw bytes had the secrets check above; it is part of a package.
                if exc.args[0] != "not an executable":
                    raise
                downgrade("a large member of a package that is not an executable was not decoded;"
                          " its raw bytes were checked for secrets only")


def _large_tar(label, spool, depth):
    """A compressed tarball above LIMIT inside a package, read as a stream."""
    spool.seek(0)
    pending = []
    try:
        with tarfile.open(fileobj=spool, mode="r|*") as archive:
            for index, member in enumerate(archive):
                if index >= 100000:
                    raise Unchecked()
                if REPORT_NAME.search(member.name):
                    raise Refused()
                if not member.isfile():
                    _checked(pending, inspect_archive_member, label + ":" + member.name,
                             os.fsencode(member.linkname), depth + 1, False)
                    continue
                stream = archive.extractfile(member)
                if stream is None:
                    raise Unchecked()
                _checked(pending, _package_member, label + ":" + member.name, stream, member.size, depth + 1, True, member.name)
    except (OSError, ValueError, EOFError, tarfile.TarError, lzma.LZMAError, zlib.error, ZstdError):
        raise Unchecked() from None
    if pending:
        raise pending[0]


def _sensitive_spool(label, spool):
    """check_sensitive.sh --binary on a spooled member's printable runs, in bounded memory."""
    with tempfile.TemporaryFile() as text:
        text.write(_label(label))
        spool.seek(0)
        carry = b""
        while True:
            chunk = spool.read(CHUNK)
            if not chunk:
                break
            carry = strings(carry + chunk, text, final=False)
        strings(carry, text)
        text.seek(0)
        proc = subprocess.run(
            [BASH, Path(__file__).with_name("check_sensitive.sh").as_posix(), "--stdin", "--no-inline-allow", "--binary"],
            stdin=text, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        return proc.returncode


def _ar_package(name, f, depth):
    """Members of an ar archive (a deb), each checked with the binary profile."""
    if f.read(8) != b"!<arch>\n":
        raise Unchecked()
    pending = []
    for _ in range(2000):
        header = f.read(60)
        if not header:
            break
        if len(header) != 60 or header[58:60] != b"`\n":
            raise Unchecked()
        try:
            size = int(header[48:58].strip() or b"x")
        except ValueError:
            raise Unchecked() from None
        member = header[:16].decode("utf-8", "replace").strip().rstrip("/") or "member"
        if REPORT_NAME.search(member):
            raise Refused()
        _checked(pending, _package_member, name + ":" + member, f, size, depth + 1, True, member)
        if size % 2:
            f.read(1)
    else:
        raise Unchecked()
    if pending:
        raise pending[0]


def _rpm_header(f, align):
    head = _read_exact(f, 16)
    if head[:4] != b"\x8e\xad\xe8\x01":
        raise Unchecked()
    count, size = struct.unpack(">II", head[8:16])
    length = 16 * count + size
    if length > LIMIT:
        raise Unchecked()
    _read_exact(f, length)
    if align and (16 + length) % 8:
        _read_exact(f, 8 - (16 + length) % 8)


def _rpm_package(name, f, depth):
    """The cpio payload of an rpm, each member checked with the binary profile."""
    lead = _read_exact(f, 96)
    if not lead.startswith(b"\xed\xab\xee\xdb"):
        raise Unchecked()
    _rpm_header(f, True)
    _rpm_header(f, False)
    start = f.tell()
    magic = f.read(6)
    f.seek(start)
    if magic.startswith(b"\x1f\x8b"):
        payload = gzip.GzipFile(fileobj=f)
    elif magic.startswith(b"\xfd7zXZ"):
        payload = lzma.LZMAFile(f)
    elif magic.startswith(b"BZh"):
        payload = bz2.BZ2File(f)
    elif magic.startswith(b"\x28\xb5\x2f\xfd") and ZstdDecompressor is not None:
        from compression.zstd import ZstdFile
        payload = ZstdFile(f)
    elif magic.startswith(b"\x28\xb5\x2f\xfd"):
        downgrade("a zstd rpm payload (no zstd decoder) in a built binary was not decoded;"
                  " its raw bytes were checked for secrets only")
        status = _sensitive_spool(name, f)
        if status == 1:
            raise Refused()
        if status:
            raise Unchecked()
        return
    elif magic.startswith(b"0707"):
        payload = f
    else:
        raise Unchecked()
    pending = []
    try:
        for _ in range(100000):
            header = payload.read(110)
            if len(header) != 110 or header[:6] not in (b"070701", b"070702"):
                raise Unchecked()
            size = int(header[54:62], 16)
            link = int(header[14:22], 16) & 0o170000 == 0o120000
            name_size = int(header[94:102], 16)
            member = payload.read(name_size)
            payload.read((4 - (110 + name_size) % 4) % 4)
            member = member.rstrip(b"\0").decode("utf-8", "replace")
            if member == "TRAILER!!!":
                break
            if REPORT_NAME.search(member):
                raise Refused()
            _checked(pending, _package_member, name + ":" + member, payload, size, depth + 1, not link, member)
            payload.read((4 - size % 4) % 4)
        else:
            raise Unchecked()
    except (OSError, EOFError, ValueError, lzma.LZMAError, zlib.error, ZstdError):
        raise Unchecked() from None
    if pending:
        raise pending[0]


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
        for key, item in value.items():
            if str(key).lower() in {"gitleaks", "foxguard"}:
                if isinstance(item, (int, float)) and not isinstance(item, bool):
                    return True
                if isinstance(item, str) and item.lower() in {"clean", "no leaks", "no findings"}:
                    return True
                if isinstance(item, dict) and {str(k).lower() for k in item}.intersection(
                    {"findings", "finding_counts", "leaks", "hits", "credentials", "fingerprints", "count", "total"}
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


def set_max_mib(value):
    """Apply CHECK_SCAN_OUTPUT_MAX_MIB or --max-mib (1..2048, default 2048)."""
    global LIMIT, MAX_BYTES
    if value is None:
        value = os.environ.get("CHECK_SCAN_OUTPUT_MAX_MIB", "")
    if value == "":
        value = str(MAX_MIB_CAP)
    if not re.fullmatch(r"[0-9]{1,4}", value) or not 1 <= int(value) <= MAX_MIB_CAP:
        raise Unchecked()
    MAX_BYTES = int(value) * MIB
    LIMIT = min(LIMIT, MAX_BYTES)


class _Budget:
    """Bounds the decoding work spent on one large object."""

    def __init__(self, outer="", package=False):
        # The checked file's own path: a local path, not content it carries.
        self.outer = outer + ":"
        # Decoded data is a packaged file's bytes (an AppImage's squashfs blocks):
        # the secrets-only profile, as for its undecoded raw bytes.
        self.package = package
        self.decoded = 0
        self.hits = 0
        # (start, end) of every embedded tar already read, so a header inside
        # one is not read again as the start of another (2000 members cost n^2).
        self.tars = []
        # Set when data in the executable could not be decoded: its raw bytes get a secrets check.
        self.opaque = False
        self.pending = []
        self.pending_bytes = 0
        self.deadline = time.monotonic() + DECODE_SECONDS

    def take(self, count):
        self.decoded += count
        if self.decoded > DECODED_MAX:
            raise Anomaly("decode limit reached")

    def sensitive(self, name, data):
        """Queue decoded data for check_sensitive.sh: one process per batch, not per member.

        A text member keeps every check; binary data embedded in the executable
        gets the secrets-only profile.
        """
        if name.startswith(self.outer):
            name = name[len(self.outer):]
        binary = self.package or not looks_text(name, data)
        body = strings_of(data) if binary else data.replace(b"\0", b" ")
        self.pending.append((binary, os.fsencode(name) + b"\n" + body + b"\n"))
        self.pending_bytes += len(self.pending[-1][1])
        if self.pending_bytes > MEMBER_MAX:
            self.flush()

    def flush(self):
        if not self.pending:
            return
        pending, self.pending, self.pending_bytes = self.pending, [], 0
        for binary in (False, True):
            raw = b"".join(body for kind, body in pending if kind == binary)
            if not raw:
                continue
            status = run_sensitive(raw, binary)
            if status == 1:
                raise Refused()
            if status:
                raise Anomaly("embedded data could not be checked")

    def tick(self):
        if time.monotonic() > self.deadline:
            raise Anomaly("time limit reached")


def _decode(dec, f, offset, budget):
    """Feed f from offset into a zlib, bz2, lzma or zstd decompressor; return (data, complete)."""
    out = bytearray()
    f.seek(offset)

    def grow(data):
        out.extend(data)
        if len(out) > MEMBER_MAX:
            raise Anomaly("embedded data above the decode limit")

    try:
        while not dec.eof:
            piece = f.read(65536)
            if not piece:
                break
            if hasattr(dec, "unconsumed_tail"):
                while piece and not dec.eof:
                    grow(dec.decompress(piece, MIB))
                    piece = dec.unconsumed_tail
            else:
                grow(dec.decompress(piece, MIB))
                while not dec.eof and not dec.needs_input:
                    grow(dec.decompress(b"", MIB))
            budget.tick()
    except (zlib.error, OSError, EOFError, lzma.LZMAError, ValueError, ZstdError):
        return bytes(out), False
    return bytes(out), dec.eof


def _scan_decoded(name, data, complete, budget):
    budget.take(len(data))
    try:
        if complete:
            inspect(name, data, 1)
            budget.sensitive(name, data)
        elif data:
            # Partial output of stray bytes: cheap result scan only.
            inspect(name, data, 1)
    except Unchecked:
        raise Anomaly("embedded data could not be checked") from None


def _zip_member(name, f, offset, budget):
    f.seek(offset)
    header = f.read(30)
    if len(header) < 30:
        return
    _, version, flags, method, _, _, crc, csize, usize, nlen, xlen = struct.unpack("<4s5H3I2H", header)
    raw_name = f.read(nlen)
    try:
        member = raw_name.decode("utf-8")
    except UnicodeError:
        return
    # A real local header names its member in printable text.
    if not 1 <= nlen <= 1024 or len(raw_name) != nlen or (version & 0xFF) > 63 or not member.isprintable() \
            or method not in (0, 8, 12, 14, 93, 95, 98, 99):
        return
    label = name + ":" + member
    if REPORT_NAME.search(member):
        raise Refused()
    if flags & 1:
        raise Anomaly("encrypted archive member")
    start = offset + 30 + nlen + xlen
    if method == 8:
        data, complete = _decode(zlib.decompressobj(-15), f, start, budget)
    elif method == 0 and not flags & 8:
        if csize > MEMBER_MAX:
            raise Anomaly("embedded data above the decode limit")
        f.seek(start)
        data = f.read(csize)
        complete = len(data) == csize
    else:
        raise Anomaly("unsupported archive member format")
    if complete and not flags & 8:
        complete = zlib.crc32(data) & 0xFFFFFFFF == crc and len(data) == usize
    _scan_decoded(label, data, complete, budget)


def _tar_members(name, f, offset, budget):
    if offset < 257 or any(start <= offset < end for start, end in budget.tars):
        return
    f.seek(offset - 257)
    header = f.read(512)
    if len(header) < 512:
        return
    try:
        stored = int(header[148:156].replace(b"\0", b" ").strip() or b"x", 8)
    except ValueError:
        return
    if stored != sum(header[:148]) + 256 + sum(header[156:]):
        return
    f.seek(offset - 257)
    archive = None
    try:
        with tarfile.open(fileobj=f, mode="r|") as archive:
            for index, member in enumerate(archive):
                budget.tick()
                if index >= 2000:
                    raise Anomaly("archive has too many members")
                if REPORT_NAME.search(member.name):
                    raise Refused()
                if not member.isfile():
                    budget.sensitive(member.name, os.fsencode(member.linkname))
                    continue
                if member.size > MEMBER_MAX:
                    raise Anomaly("embedded data above the decode limit")
                stream = archive.extractfile(member)
                data = stream.read() if stream is not None else b""
                _scan_decoded(name + ":" + member.name, data, len(data) == member.size, budget)
    except (OSError, ValueError, tarfile.TarError):
        pass
    except Unchecked:
        raise Anomaly("embedded data could not be checked") from None
    finally:
        if archive is not None:
            budget.tars.append((offset - 257, offset - 257 + max(archive.offset, 512)))


def _zstd_blocks_end(f, offset, descriptor):
    """Walk a zstd frame's block headers; True when they reach a last block.

    Without a decoder this tells a frame from the stray magic bytes Go binaries
    carry: those are followed by code, or by zero bytes (empty raw blocks).
    """
    single = descriptor & 0x20
    pos = offset + 5 + (0 if single else 1) + (0, 1, 2, 4)[descriptor & 3]
    pos += ((1 if single else 0), 2, 4, 8)[descriptor >> 6]
    for _ in range(SIGNATURES_MAX):
        f.seek(pos)
        raw = f.read(3)
        if len(raw) != 3:
            return False
        header = int.from_bytes(raw, "little")
        kind, length = (header >> 1) & 3, header >> 3
        if kind == 3 or length > 128 * 1024 or (kind == 0 and length == 0 and not header & 1):
            return False
        pos += 3 + (1 if kind == 1 else length)
        if header & 1:
            return True
    return False


def _zstd_frame(name, f, offset, budget):
    f.seek(offset + 4)
    descriptor = f.read(1)
    if len(descriptor) != 1 or descriptor[0] & 0x08:
        return
    # Python 3.14+ only; no external decoder is run.
    if ZstdDecompressor is None:
        # Only executables are decoded; inspect_large checks the raw bytes for secrets.
        if _zstd_blocks_end(f, offset, descriptor[0]):
            budget.opaque = "zstd data (no zstd decoder)"
        return
    data, complete = _decode(ZstdDecompressor(), f, offset, budget)
    _scan_decoded(name + ":zstd", data, complete, budget)


def _embedded(name, f, offset, magic, budget):
    """Decode the data a signature starts; bytes that do not decode are not a finding."""
    budget.hits += 1
    if budget.hits > SIGNATURES_MAX:
        raise Anomaly("too many embedded signatures")
    budget.tick()
    if magic.startswith(b"\x1f\x8b"):
        data, complete = _decode(zlib.decompressobj(16 + zlib.MAX_WBITS), f, offset, budget)
        _scan_decoded(name + ":gzip", data, complete, budget)
    elif magic.startswith(b"BZh"):
        f.seek(offset + 4)
        if f.read(6) in (b"1AY&SY", b"\x17rE8P\x90"):
            data, complete = _decode(bz2.BZ2Decompressor(), f, offset, budget)
            _scan_decoded(name + ":bzip2", data, complete, budget)
    elif magic.startswith(b"\xfd7zXZ"):
        f.seek(offset + 6)
        flags = f.read(6)
        if len(flags) == 6 and zlib.crc32(flags[:2]) & 0xFFFFFFFF == struct.unpack("<I", flags[2:])[0]:
            data, complete = _decode(lzma.LZMADecompressor(lzma.FORMAT_XZ), f, offset, budget)
            _scan_decoded(name + ":xz", data, complete, budget)
    elif magic.startswith(b"PK"):
        _zip_member(name, f, offset, budget)
    elif magic.startswith(b"7z"):
        f.seek(offset + 8)
        start = f.read(24)
        if len(start) == 24 and zlib.crc32(start[4:]) & 0xFFFFFFFF == struct.unpack("<I", start[:4])[0]:
            budget.opaque = "7z data"
    elif magic == b"ustar":
        _tar_members(name, f, offset, budget)
    else:
        _zstd_frame(name, f, offset, budget)


def _large_package(name, f, kind):
    """Decode a package above LIMIT that is not an executable: deb, ar, rpm, APK/AAB/JAR.

    A disk image or a byte-split part is not decoded: inspect_large checks
    its raw bytes for secrets instead.
    """
    f.seek(0)
    try:
        if kind in ("deb", "ar archive"):
            _ar_package(name, f, 0)
        elif kind == "rpm":
            _rpm_package(name, f, 0)
        elif kind == "Android or Java package":
            pending = []
            with zipfile.ZipFile(f) as archive:
                members = archive.infolist()
                if len(members) > 2000:
                    raise Anomaly("archive has too many members")
                for member in members:
                    if member.flag_bits & 1:
                        raise Anomaly("encrypted archive member")
                    if REPORT_NAME.search(member.filename):
                        raise Refused()
                    with archive.open(member) as stream:
                        _checked(pending, _package_member, name + ":" + member.filename, stream, member.file_size, 1, True, member.filename)
            if pending:
                raise pending[0]
    except Unchecked:
        raise Anomaly("package could not be decoded") from None
    except (OSError, ValueError, RuntimeError, EOFError, zipfile.BadZipFile, zlib.error):
        raise Anomaly("package could not be decoded") from None


def _zip_package_expands(name, f):
    """True for an APK/AAB/JAR at most LIMIT long whose members total more than LIMIT.

    Read in memory it would be refused as unchecked; _large_package streams
    each member instead, as for a package above LIMIT.
    """
    try:
        if classify_file(name, f) != "Android or Java package":
            return False
        with zipfile.ZipFile(f) as archive:
            return sum(member.file_size for member in archive.infolist()) > LIMIT
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile):
        return False
    finally:
        f.seek(0)


def inspect_large(name, f):
    """Inspect a seekable object above LIMIT without holding more than CHUNK + OVERLAP bytes.

    Every object is scanned as text to the end, so a scanner result blocks
    even when something earlier could not be checked. Only executables
    (STREAM_FORMATS) also have embedded compressed data and archives decoded,
    within bounds. A scanner result raises Refused; otherwise anything not fully
    checked raises Anomaly once the whole object has been read.
    """
    normalized = "/".join(part for part in name.replace("\\", "/").split("/") if part not in ("", "."))
    if REPORT_NAME.search(normalized):
        raise Refused()
    size = os.fstat(f.fileno()).st_size
    if size > MAX_BYTES:
        raise Anomaly("larger than the size limit")
    kind = classify_file(name, f)
    reasons = []
    try:
        _large_package(name, f, kind)
    except Anomaly as exc:
        reasons.append(exc.args[0])
    f.seek(0)
    chunk = f.read(CHUNK)
    archive_name = name.lower().endswith((".zip", ".tar", ".tgz", ".tar.gz", ".tar.xz", ".tar.bz2"))
    decoding = chunk.startswith(STREAM_FORMATS) and not archive_name
    # A known package is decoded by _large_package; anything else not decoded is incomplete.
    if not decoding and (kind is None or archive_name and kind not in ("disk image", "split part")):
        reasons.append("not an executable")
    budget = _Budget(name, package=kind == "AppImage")
    done = set()
    pos = 0
    carry = b""
    while chunk:
        pos += len(chunk)
        window = carry + chunk
        base = pos - len(window)
        # The carry holds the start of any signature or line cut at the chunk boundary.
        if STREAM_JSON_REPORT.search(window) and "possible report data" not in reasons:
            reasons.append("possible report data")
        for match in STREAM_PACKED.finditer(window) if decoding else ():
            offset = base + match.start()
            if offset not in done:
                done.add(offset)
                try:
                    _embedded(name, f, offset, match.group(), budget)
                except Anomaly as exc:
                    reasons.append(exc.args[0])
                    # The object's budget is spent: stop decoding, keep scanning text.
                    decoding = exc.args[0] not in BUDGET_SPENT
                    if not decoding:
                        break
        # Carry the unfinished last line, or the last OVERLAP bytes of a longer one.
        cut = window.rfind(b"\n", max(0, len(window) - OVERLAP)) + 1
        if cut:
            inspect(name, window[:cut], text_only=True)
            carry = window[cut:]
        else:
            inspect(name, window, text_only=True)
            carry = window[-OVERLAP:]
        f.seek(pos)
        chunk = f.read(CHUNK)
    if carry:
        inspect(name, carry, text_only=True)
    try:
        budget.flush()
    except Anomaly as exc:
        reasons.append(exc.args[0])
    opaque = budget.opaque or {"disk image": "disk image", "split part": "split part",
                               "AppImage": "the AppImage squashfs payload"}.get(kind)
    if opaque:
        # What was not decoded gets a secrets check on its raw bytes, in every mode.
        status = _sensitive_spool(name, f)
        if status == 1:
            raise Refused()
        if status:
            reasons.append("raw bytes could not be checked")
        else:
            downgrade(opaque + " in a built binary was not decoded; its raw bytes were checked for secrets only")
    if reasons:
        raise Anomaly(reasons[0])


def report_anomalies():
    """Print each anomaly (path and reason class only). Return the exit status."""
    if not ANOMALIES:
        return 0
    ci = os.environ.get("GITHUB_ACTIONS") == "true" or NON_BLOCKING[0]
    for path, reason in ANOMALIES:
        clean = re.sub(r"[\x00-\x1f\x7f]", "?", path)
        if ci:
            clean = clean.replace("%", "%25")
            # Workflow commands are read from stdout.
            print("::warning title=Security check incomplete::" + clean + " could not be fully checked: " + reason)
        else:
            print("WARNING: security check incomplete: " + clean + ": could not fully check: " + reason, file=sys.stderr)
    if ci:
        return 0
    print("WARNING: security check incomplete: inspect the files above locally before publishing them.", file=sys.stderr)
    return 3


def inspect(name, raw, depth=0, text_only=False, binary=False, member=None):
    try:
        try:
            return _inspect(name, raw, depth, text_only, binary, member)
        except Unchecked:
            # The first part of a split compressed file is a truncated stream.
            base = name.replace("\\", "/").rsplit("/", 1)[-1]
            if depth or text_only or not SPLIT_PART.search(base) or not _container(raw[:HEAD]):
                raise
            opaque_in_binary(name, raw, "a split part that does not decode alone")
            return False
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


def _decompressed_name(member):
    """The member path a compressed member expands to: NOTICES.Z -> NOTICES, changelog.gz -> changelog."""
    return COMPRESSED_SUFFIX.sub("", member)


def _inspect(name, raw, depth=0, text_only=False, binary=False, member=None):
    normalized = "/".join(part for part in name.replace("\\", "/").split("/") if part not in ("", "."))
    if REPORT_NAME.search(normalized):
        raise Refused()
    # Every decompression and archive layer counts. A .tar.gz inside a .tar.gz
    # puts its members at depth 4; one level deeper is refused.
    if len(raw) > LIMIT or depth > 4:
        raise Unchecked()
    # Inspect archives in memory. Never extract paths supplied by the archive.
    kind = None if text_only else classify(name, raw[:HEAD], raw[-512:] if len(raw) >= 512 else b"", size=len(raw))
    if kind in ("split part", "disk image"):
        # Not decodable alone: its raw bytes get the secrets check instead.
        opaque_in_binary(name, raw, kind)
        text_only = True
    elif kind == "AppImage":
        opaque_in_binary(name, raw, "the AppImage squashfs payload")
    if text_only:
        pass
    elif kind in ("deb", "ar archive", "rpm"):
        try:
            (_rpm_package if kind == "rpm" else _ar_package)(name, io.BytesIO(raw), depth)
        except (OSError, ValueError, EOFError, RuntimeError, zipfile.BadZipFile, zlib.error):
            raise Unchecked() from None
        return True
    elif raw.startswith((b"\x1f\x8b", b"BZh", b"\xfd7zXZ\x00")):
        # GzipFile's first positional argument is a filename; BZ2File and
        # LZMAFile take a file object there.
        if raw.startswith(b"\x1f\x8b"):
            def opener(fileobj):
                return gzip.GzipFile(fileobj=fileobj)
        else:
            opener = bz2.BZ2File if raw.startswith(b"BZh") else lzma.LZMAFile
        try:
            with opener(io.BytesIO(raw)) as stream:
                expanded = stream.read(LIMIT + 1)
            # The expanded data keeps its member path, so a compressed license
            # file (Flutter's NOTICES.Z, a deb's changelog.gz) is still one.
            inspect_archive_member("compressed-content", expanded, depth + 1, binary,
                                   member=_decompressed_name(name if member is None else member))
        except (OSError, EOFError, ValueError, lzma.LZMAError, zlib.error):
            raise Unchecked() from None
        return True
    elif raw.startswith(b"\x28\xb5\x2f\xfd"):
        if ZstdDecompressor is None:
            if not binary:
                raise Anomaly("no zstd decoder")
            opaque_in_binary(name, raw, "zstd data (no zstd decoder)")
            return
        try:
            decoder = ZstdDecompressor()
            expanded = decoder.decompress(raw, LIMIT + 1)
            if not decoder.eof or decoder.unused_data:
                raise Unchecked()
        except ZstdError:
            raise Unchecked() from None
        inspect_archive_member("compressed-content", expanded, depth + 1, binary,
                               member=_decompressed_name(name if member is None else member))
        return True
    elif raw.startswith(b"PK\x03\x04") or name.lower().endswith(".zip"):
        try:
            with zipfile.ZipFile(io.BytesIO(raw)) as archive:
                total = 0
                members = archive.infolist()
                if len(members) > 2000:
                    raise Unchecked()
                package = binary or classify(name, b"", names=archive.namelist()) is not None
                pending = []
                for member in members:
                    total += member.file_size
                    if total > LIMIT or member.flag_bits & 1:
                        raise Unchecked()
                    _checked(pending, inspect_archive_member, member.filename,
                             b"" if member.is_dir() else archive.read(member), depth + 1, package)
                if pending:
                    raise pending[0]
        except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, zlib.error):
            raise Unchecked() from None
        return True
    elif raw[257:262] == b"ustar" or name.lower().endswith((".tar", ".tgz", ".tar.gz", ".tar.xz", ".tar.bz2")):
        try:
            with tarfile.open(fileobj=io.BytesIO(raw), mode="r:*") as archive:
                total = 0
                members = []
                for index, member in enumerate(archive):
                    if index >= 2000:
                        raise Unchecked()
                    members.append(member)
                pending = []
                bundles = _app_bundles(archive, members)
                for member in members:
                    # Members of a real macOS .app bundle are package members.
                    package = binary or any(member.name.startswith(prefix) for prefix in bundles)
                    total += member.size
                    if total > LIMIT:
                        raise Unchecked()
                    if member.isfile():
                        stream = archive.extractfile(member)
                        if stream is None:
                            raise Unchecked()
                        _checked(pending, inspect_archive_member, member.name, stream.read(LIMIT + 1), depth + 1, package)
                    else:
                        # A link target keeps every check: a link cannot borrow a document path.
                        _checked(pending, inspect_archive_member, member.name, os.fsencode(member.linkname), depth + 1, False)
                if pending:
                    raise pending[0]
        except (OSError, ValueError, tarfile.TarError):
            raise Unchecked() from None
        return True
    try:
        text = raw.decode("utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8-sig")
    except UnicodeError:
        # Binary blobs are still searched for embedded scanner output.
        text = raw.decode("utf-8", errors="replace")
    if re.search(r"(?m)^[ \t>]*SCRIPT_HELPERS_PRIVATE_SECURITY_REPORT_V1[ \t]*\r?$", text):
        raise Refused()
    for line in text.splitlines():
        candidate = line.lstrip(" \t>\ufeff")
        if not re.match(r'(?i)["\']?RuleID["\']?\s*,', candidate):
            continue
        try:
            columns = {field.strip().lower() for field in next(csv.reader([candidate]), [])}
            if {"ruleid", "secret"} <= columns or {"ruleid", "fingerprint"} <= columns:
                raise Refused(tool="Gitleaks")
        except csv.Error:
            pass
    for suite in re.finditer(r"<testsuites?\b[^>]{0,4096}>", text, re.I):
        tag = suite.group(0)
        identity = re.search(r'''\bname\s*=\s*["'](gitleaks|foxguard)["']''', tag, re.I)
        count = re.search(r'''\b(?:tests|failures)\s*=\s*["']\d+["']''', tag, re.I)
        if identity and count:
            raise Refused(tool="Gitleaks" if identity.group(1).lower() == "gitleaks" else "Foxguard")
    try:
        if structured(json.loads(text)):
            raise Refused()
    except RecursionError:
        raise Unchecked() from None
    except ValueError:
        pass
    decoder = json.JSONDecoder()
    for match in re.finditer(r'(?m)^[ \t>]*(?P<json>[{\[])(?=[\s"{])', text):
        try:
            value, _ = decoder.raw_decode(text, match.start("json"))
            if structured(value):
                raise Refused()
        except RecursionError:
            raise Unchecked() from None
        except ValueError:
            continue
    text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
    if re.search(r"(?m)^\s*Local(?: security)? report:\s+(?:/|[A-Za-z]:[\\/])", text):
        raise Refused()
    for line in text.splitlines():
        if not RESULT.search(line) and not NATIVE_RESULT.search(line.lstrip(" \t>")):
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
        r"(?im)^[ \t>]*(?:\[sensitive\]\s+gitleaks:\s*)?(?:RuleID|Fingerprint|StartLine|finding_counts)\s*:", text
    ):
        raise Refused()


def check_blob(repo, oid, path, seen):
    # Names are checked even when the identical blob was seen at another path.
    if REPORT_NAME.search(path.replace("\\", "/")):
        raise Refused()
    key = (oid, Path(path).suffix)
    CURRENT[0] = path
    if key not in seen:
        size = int(git(repo, "cat-file", "-s", oid))
        try:
            if size > MAX_BYTES:
                ANOMALIES.append((path, "larger than the size limit"))
            elif size > LIMIT:
                # Decoding embedded data needs a seekable copy; it is deleted on close.
                with tempfile.TemporaryFile() as spool:
                    if subprocess.run(["git", "-C", repo, "cat-file", "blob", oid], stdout=spool, stderr=subprocess.DEVNULL).returncode:
                        raise Unchecked()
                    try:
                        inspect_large(path, spool)
                    except Anomaly as exc:
                        ANOMALIES.append((path, exc.args[0]))
            else:
                try:
                    inspect(path, git(repo, "cat-file", "blob", oid))
                except Anomaly as exc:
                    ANOMALIES.append((path, exc.args[0]))
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
        local_ref, local, remote_ref, old = fields
        if not all(re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", s) for s in (local, old)):
            raise Unchecked()
        if set(local) == {"0"} or local == old:
            continue
        inspect("ref metadata", re.sub(r"[/_.-]", " ", local_ref + " " + remote_ref).encode())
        if local_ref.startswith("refs/heads/"):
            os.environ["SH_SECURITY_BRANCH"] = local_ref[len("refs/heads/"):]
        target = local
        while git(repo, "cat-file", "-t", target).strip() == b"tag":
            tag = git(repo, "cat-file", "tag", target)
            headers, body = tag.split(b"\n\n", 1)
            inspect("tag-message", body)
            for header in headers.splitlines():
                if header.startswith(b"tag "):
                    inspect("tag name", re.sub(rb"[/_.-]", b" ", header[4:]))
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
    modes.add_argument("--strings")
    modes.add_argument("--classify")
    parser.add_argument("--repo", default=".")
    parser.add_argument("--remote", default="")
    parser.add_argument("--max-mib")
    parser.add_argument("--non-blocking", action="store_true")
    args = parser.parse_args()
    seen = set()
    try:
        NON_BLOCKING[0] = args.non_blocking
        set_max_mib(args.max_mib)
        if args.strings:
            write_strings(args.strings)
            return 0
        if args.classify:
            with open(args.classify, "rb") as stream:
                print(classify_file(args.classify, stream) or "text")
            return 0
        if args.file:
            for name in args.file:
                CURRENT[0] = name
                with open(name, "rb") as stream:
                    resolved = str(Path(name).resolve())
                    if REPORT_NAME.search(name.replace("\\", "/")):
                        raise Refused(name)
                    if os.fstat(stream.fileno()).st_size > LIMIT or _zip_package_expands(name, stream):
                        if REPORT_NAME.search(resolved.replace("\\", "/")):
                            raise Refused(name)
                        try:
                            inspect_large(name, stream)
                        except Anomaly as exc:
                            ANOMALIES.append((name, exc.args[0]))
                    else:
                        raw = stream.read(LIMIT + 1)
                        try:
                            inspect(name, raw)
                            if name != resolved:
                                inspect(resolved, raw)
                        except Anomaly as exc:
                            ANOMALIES.append((name, exc.args[0]))
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
    except (Unchecked, Anomaly, OSError, ValueError, RecursionError, IndexError, zlib.error):
        subprocess.run([BASH, Path(__file__).with_name("security_notice.sh").as_posix(), "Security"], check=False)
        return 2
    return report_anomalies()


if __name__ == "__main__":
    sys.exit(main())
