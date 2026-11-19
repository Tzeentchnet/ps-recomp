"""Game data files (core/gamedata.odin's gamedata.tsv): check one against
the schema, or place a player's sent file under games/.

    python3 -I tools/gamedata/gamedata.py check <file>...
    python3 -I tools/gamedata/gamedata.py place <file> <issue number> <repo root>
    python3 -I tools/gamedata/gamedata.py url < <issue body>

A file may be gzip compressed (gamedata.tsv.gz, as the web player's Send
downloads it); its first two bytes say which. check prints each file's
errors, the first ERRORS_MAX of them, and exits 1 if any file has one.
place checks the file, then writes it as
games/<serial>/gamedata-<sha7>-<issue>.tsv under the repo root and prints
that path, a tab and the id row's build. The serial is the id row's
(AAAA-NNNNN), or its disc id when the disc has none. sha7 is the first 7
characters of the id row's build, which must be a commit hash: a dev
build's file is not placed. url prints the one file attachment
(ATTACHMENT) an issue body links to, and fails if it links none or more
than one.

The file is untrusted (.github/workflows/game-data.yml runs this on a
player's attachment), so every row must be one the writer can make: its
kind known and in the writer's order, each field of its kind's type, no
run of more than HEX_RUN_MAX hex digits anywhere (the writer's widest
field is a 16-digit hash; a longer run could carry the game's own bytes),
and the file at most RAW_MAX bytes, at most PACKED_MAX before gunzip. The
schema here follows core/gamedata.odin's comment and writer at
GAMEDATA_VERSION; a change there changes it here.

Standard library only.
"""

import os
import re
import sys
import zlib

VERSION = 2
PACKED_MAX = 1 << 20  # bytes of a gzip file
RAW_MAX = 4 << 20  # bytes once gunzipped
HEX_RUN_MAX = 16
TEXT_MAX = 160  # GAMEDATA_TEXT
ERRORS_MAX = 20

DEC = re.compile(r"(0|[1-9][0-9]{0,19})\Z")
INT = re.compile(r"(0|-?[1-9][0-9]{0,19})\Z")
H8 = re.compile(r"[0-9a-f]{8}\Z")
H16 = re.compile(r"[0-9a-f]{16}\Z")
# gamedata_text's charset, plus the '?' it writes for any other byte.
TEXT = re.compile(r"[A-Za-z0-9 _.,:;()/%%+=?-]{0,%d}\Z" % TEXT_MAX)
HEX_RUN = re.compile(r"[0-9A-Fa-f]{%d,}" % (HEX_RUN_MAX + 1))
SERIAL = re.compile(r"[A-Z]{4}-[0-9]{5}\Z")
# disc.id: the serial and the hash, or the hash alone.
DISC = re.compile(r"([A-Z]{4}-[0-9]{5}\.)?[0-9a-f]{16}\Z")
SHA = re.compile(r"[0-9a-f]{7,40}\Z")
ISSUE = re.compile(r"[1-9][0-9]{0,9}\Z")
# A file attached to an issue, as GitHub links it: the whole link, so one
# the pattern would cut short (a longer name, a query) is not taken.
ATTACHMENT = re.compile(r"https://github\.com/user-attachments/files/[0-9]+/[A-Za-z0-9._-]+(?![^\s)\]>\"'])")
BODY_MAX = 1 << 18  # bytes of an issue body read: GitHub keeps 65536 characters


def one_of(*names):
    s = frozenset(names)
    return lambda v: v in s


def match(p):
    return lambda v: p.match(v) is not None


u, i, h8, h16, text = match(DEC), match(INT), match(H8), match(H16), match(TEXT)
CPU = one_of("ee", "iop")
LEARN_CPU = one_of("psx", "ee", "iop")
EE = one_of("ee")


def path(v):
    return v.startswith("/") and text(v) or v.startswith("lsn:") and h8(v[4:])


def smc_flags(v):
    f = v.split(",")
    return len(set(f)) == len(f) and all(x in ("smc", "smc_unknown", "large") for x in f)


# Each kind's columns after the first, in the writer's file order.
KINDS = {
    "gamedata": [one_of(str(VERSION))],
    "id": [match(DISC), lambda v: v == "" or SERIAL.match(v) is not None, text, text, u, h16, u],
    "host": [one_of("x64_sysv", "x64_win", "arm64", "wasm32"), one_of("0", "1", "2", "4", "8", "16")],
    "load": [CPU, path, u, u, h8, u, u, h16, u, h16],
    "interp": [LEARN_CPU, h8, u, h8, u, h16, u],
    "smc": [LEARN_CPU, h8, h8, u, h16, smc_flags],
    "sys": [text, u, h8, h8, h8],
    "irx": [text, h8, h8, h16],
    "stretch": [one_of("black", "frozen", "ram_still", "still", "deaf", "stuck"), u, u],
    "learned": [EE, h8, h8, u, h16, one_of("open", "-")],
    "refused": [EE, h8, one_of("smc", "smc_unknown", "large", "not_lowered")],
    "call": [EE, h8, h8, u],
    "thread": [i, h8, i, i, one_of("run", "ready", "wait", "suspend", "wait_suspend", "dormant", "deleted")],
    "sema": [i, i, i, one_of("live", "deleted"), i, i],
    "perf": [u] * 8,
    "cap": [one_of("learned", "refused", "call", "thread", "sema"), u, u],
    "end": [one_of("frames", "fatal", "exit", "watch", "running")] + [u] * 8 + [i, u, one_of("0", "1"), text],
}
ORDER = {k: n for n, k in enumerate(KINDS)}
# Kinds of exactly one row; perf has at most one, the rest any number.
ONCE = ("gamedata", "id", "host", "end")


def unpack(data):
    """The file's bytes, gunzipped if gzip; (bytes, error)."""
    if data[:2] != b"\x1f\x8b":
        if len(data) > RAW_MAX:
            return None, "over %d bytes" % RAW_MAX
        return data, None
    if len(data) > PACKED_MAX:
        return None, "gzip file over %d bytes" % PACKED_MAX
    d = zlib.decompressobj(wbits=31)
    try:
        out = d.decompress(data, RAW_MAX + 1)
    except zlib.error as e:
        return None, "gzip: %s" % e
    if len(out) > RAW_MAX:
        return None, "over %d bytes gunzipped" % RAW_MAX
    if not d.eof or d.unused_data:
        return None, "gzip: not one whole member"
    return out, None


def check(data):
    """The errors of a gunzipped file, each 'line N: why'; and its id row."""
    errors = []
    try:
        s = data.decode("ascii")
    except UnicodeDecodeError:
        return ["not ASCII"], None
    if not s.endswith("\n"):
        return ["the last line has no newline"], None
    seen = dict.fromkeys(KINDS, 0)
    last, prev, ident = -1, None, None
    for n, line in enumerate(s[:-1].split("\n"), 1):
        why = row(line)
        kind = line.split("\t", 1)[0]
        if why is None:
            at = ORDER[kind]
            if at < last:
                why = "%s after %s" % (kind, list(KINDS)[last])
            elif at == last and line < prev:
                why = "%s rows not sorted" % kind
            elif seen[kind] and (kind in ONCE or kind == "perf"):
                why = "a second %s row" % kind
            last, prev = at, line
            seen[kind] += 1
            if kind == "id":
                ident = line.split("\t")
        if why is not None:
            errors.append("line %d: %s" % (n, why))
    for k in ONCE:
        if not seen[k]:
            errors.append("no %s row" % k)
    return errors, ident


def row(line):
    """Why line is not a row the writer makes, or None."""
    f = line.split("\t")
    # The id row's build is the player's commit (40 hex digits on the web,
    # web/build.sh's COMMIT), the one field a longer run may fill.
    rest = line
    if f[0] == "id" and len(f) == 8 and SHA.match(f[4]):
        rest = "\t".join(f[:4] + f[5:])
    if HEX_RUN.search(rest):
        return "a run of more than %d hex digits" % HEX_RUN_MAX
    cols = KINDS.get(f[0])
    if cols is None:
        return "unknown kind %r" % f[0][:20]
    if len(f) != len(cols) + 1:
        return "%s has %d fields, not %d" % (f[0], len(f), len(cols) + 1)
    for c, (ok, v) in enumerate(zip(cols, f[1:]), 2):
        if not ok(v):
            return "%s field %d %r" % (f[0], c, v[:40])
    return None


def read(p):
    with open(p, "rb") as f:
        return f.read(max(PACKED_MAX, RAW_MAX) + 1)


def main(argv):
    if len(argv) >= 2 and argv[0] == "check":
        bad = False
        for p in argv[1:]:
            data, err = unpack(read(p))
            errors, _ = ([err], None) if err else check(data)
            for e in errors[:ERRORS_MAX]:
                print("%s: %s" % (p, e))
            bad |= bool(errors)
        return 1 if bad else 0
    if len(argv) == 4 and argv[0] == "place":
        p, issue, root = argv[1:]
        if not ISSUE.match(issue):
            print("place: issue %r is not a number" % issue[:20], file=sys.stderr)
            return 1
        data, err = unpack(read(p))
        errors, ident = ([err], None) if err else check(data)
        if not errors and not SHA.match(ident[4]):
            errors = ["build %r is not a commit hash" % ident[4][:40]]
        if errors:
            for e in errors[:ERRORS_MAX]:
                print("%s: %s" % (p, e), file=sys.stderr)
            return 1
        disc, serial, sha = ident[1], ident[2], ident[4][:7]
        out = os.path.join("games", serial or disc, "gamedata-%s-%s.tsv" % (sha, issue))
        os.makedirs(os.path.join(root, os.path.dirname(out)), exist_ok=True)
        with open(os.path.join(root, out), "xb") as f:
            f.write(data)
        print("%s\t%s" % (out, ident[4]))
        return 0
    if argv == ["url"]:
        body = sys.stdin.buffer.read(BODY_MAX).decode("utf-8", "replace")
        urls = {m.group(0) for m in ATTACHMENT.finditer(body)}
        if len(urls) != 1:
            print("url: the issue links %d file attachments, not 1" % len(urls), file=sys.stderr)
            return 1
        print(urls.pop())
        return 0
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
