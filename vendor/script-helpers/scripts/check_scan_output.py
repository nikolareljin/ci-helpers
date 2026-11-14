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


def inspect_archive_member(name, raw, depth):
    inspect(name, raw, depth)
    # Binary diffs and archive scanners can omit member names and link targets.
    proc = subprocess.run(
        [BASH, Path(__file__).with_name("check_sensitive.sh").as_posix(),
         "--stdin", "--no-inline-allow"],
        input=os.fsencode(name) + b"\n" + raw.replace(b"\0", b" "), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
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

    def __init__(self, outer=""):
        # The checked file's own path: a local path, not content it carries.
        self.outer = outer + ":"
        self.decoded = 0
        self.hits = 0
        # (start, end) of every embedded tar already read, so a header inside
        # one is not read again as the start of another (2000 members cost n^2).
        self.tars = []
        self.pending = []
        self.pending_bytes = 0
        self.deadline = time.monotonic() + DECODE_SECONDS

    def take(self, count):
        self.decoded += count
        if self.decoded > DECODED_MAX:
            raise Anomaly("decode limit reached")

    def sensitive(self, name, data):
        """Queue decoded data for check_sensitive.sh: one process per batch, not per member."""
        if name.startswith(self.outer):
            name = name[len(self.outer):]
        self.pending.append(os.fsencode(name) + b"\n" + data.replace(b"\0", b" ") + b"\n")
        self.pending_bytes += len(self.pending[-1])
        if self.pending_bytes > MEMBER_MAX:
            self.flush()

    def flush(self):
        if not self.pending:
            return
        raw, self.pending, self.pending_bytes = b"".join(self.pending), [], 0
        proc = subprocess.run(
            [BASH, Path(__file__).with_name("check_sensitive.sh").as_posix(), "--stdin", "--no-inline-allow"],
            input=raw, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        if proc.returncode == 1:
            raise Refused()
        if proc.returncode:
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
        if _zstd_blocks_end(f, offset, descriptor[0]):
            raise Anomaly("no zstd decoder")
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
            raise Anomaly("no 7z decoder")
    elif magic == b"ustar":
        _tar_members(name, f, offset, budget)
    else:
        _zstd_frame(name, f, offset, budget)


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
    f.seek(0)
    chunk = f.read(CHUNK)
    reasons = []
    decoding = (chunk.startswith(STREAM_FORMATS)
                and not name.lower().endswith((".zip", ".tar", ".tgz", ".tar.gz", ".tar.xz", ".tar.bz2")))
    if not decoding:
        reasons.append("not an executable")
    budget = _Budget(name)
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


def inspect(name, raw, depth=0, text_only=False):
    try:
        _inspect(name, raw, depth, text_only)
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


def _inspect(name, raw, depth=0, text_only=False):
    normalized = "/".join(part for part in name.replace("\\", "/").split("/") if part not in ("", "."))
    if REPORT_NAME.search(normalized):
        raise Refused()
    if len(raw) > LIMIT or depth > 3:
        raise Unchecked()
    # Inspect archives in memory. Never extract paths supplied by the archive.
    if text_only:
        pass
    elif raw.startswith((b"\x1f\x8b", b"BZh", b"\xfd7zXZ\x00")):
        opener = gzip.GzipFile if raw.startswith(b"\x1f\x8b") else bz2.BZ2File if raw.startswith(b"BZh") else lzma.LZMAFile
        try:
            with opener(io.BytesIO(raw)) as stream:
                expanded = stream.read(LIMIT + 1)
            inspect_archive_member("compressed-content", expanded, depth + 1)
        except (OSError, EOFError, ValueError, lzma.LZMAError, zlib.error):
            raise Unchecked() from None
        return
    elif raw.startswith(b"PK\x03\x04") or name.lower().endswith(".zip"):
        try:
            with zipfile.ZipFile(io.BytesIO(raw)) as archive:
                total = 0
                members = archive.infolist()
                if len(members) > 2000:
                    raise Unchecked()
                for member in members:
                    total += member.file_size
                    if total > LIMIT or member.flag_bits & 1:
                        raise Unchecked()
                    inspect_archive_member(member.filename, b"" if member.is_dir() else archive.read(member), depth + 1)
        except (OSError, ValueError, RuntimeError, zipfile.BadZipFile, zlib.error):
            raise Unchecked() from None
        return
    elif raw[257:262] == b"ustar" or name.lower().endswith((".tar", ".tgz", ".tar.gz", ".tar.xz", ".tar.bz2")):
        try:
            with tarfile.open(fileobj=io.BytesIO(raw), mode="r:*") as archive:
                total = 0
                members = []
                for index, member in enumerate(archive):
                    if index >= 2000:
                        raise Unchecked()
                    members.append(member)
                for member in members:
                    total += member.size
                    if total > LIMIT:
                        raise Unchecked()
                    if member.isfile():
                        stream = archive.extractfile(member)
                        if stream is None:
                            raise Unchecked()
                        inspect_archive_member(member.name, stream.read(LIMIT + 1), depth + 1)
                    else:
                        inspect_archive_member(member.name, os.fsencode(member.linkname), depth + 1)
        except (OSError, ValueError, tarfile.TarError):
            raise Unchecked() from None
        return
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
    parser.add_argument("--repo", default=".")
    parser.add_argument("--remote", default="")
    parser.add_argument("--max-mib")
    parser.add_argument("--non-blocking", action="store_true")
    args = parser.parse_args()
    seen = set()
    try:
        NON_BLOCKING[0] = args.non_blocking
        set_max_mib(args.max_mib)
        if args.file:
            for name in args.file:
                with open(name, "rb") as stream:
                    resolved = str(Path(name).resolve())
                    if REPORT_NAME.search(name.replace("\\", "/")):
                        raise Refused(name)
                    if os.fstat(stream.fileno()).st_size > LIMIT:
                        if REPORT_NAME.search(resolved.replace("\\", "/")):
                            raise Refused(name)
                        try:
                            inspect_large(name, stream)
                        except Anomaly as exc:
                            ANOMALIES.append((name, exc.args[0]))
                    else:
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
    return report_anomalies()


if __name__ == "__main__":
    sys.exit(main())
