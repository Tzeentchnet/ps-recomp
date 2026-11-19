"""tools/gamedata tests: a file with a row of every kind passes check and
place (gunzipped or not); each way a sent file can be wrong is refused,
before place writes anything: a bad field, a file too large (raw, packed,
or gunzipped), a run of 64 hex digits in a text field, rows out of the
writer's order or unsorted, a verdict row, an unknown kind, a wrong field
count, a dev build, an issue that is not a number. url takes the one
attachment link of an issue body and refuses none or two.

    python3 -I tools/gamedata/test.py
"""

import contextlib
import gzip
import importlib.util
import io
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True  # no __pycache__ beside gamedata.py
spec = importlib.util.spec_from_file_location("gamedata", os.path.join(os.path.dirname(os.path.abspath(__file__)), "gamedata.py"))
gd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gd)

SHA = "bca8d59" + "0" * 33
GOOD = [
    "gamedata\t2",
    "id\tSLUS-21503.87a1f19509adbf9b\tSLUS-21503\tps2\t%s\t0\t0000000000000000\t3600" % SHA,
    "host\twasm32\t8",
    "load\tee\t/DATA/AREA01.BIN\t0\t65536\t00400000\t1\t120\t0123456789abcdef\t121\t0123456789abcdef",
    "load\tiop\tlsn:00001234\t0\t2048\t000a0000\t2\t30\t0000000000000000\t0\t0000000000000000",
    "interp\tee\t001c6408\t52\t001c6400\t24\t0123456789abcdef\t1",
    "smc\tee\t00200000\t00200000\t40\t0123456789abcdef\tsmc,large",
    "sys\tsif rpc 0x80000597 fn 3\t7\t00123456\t00123400\t80000597",
    "irx\tCsd_\t000a0000\t00001000\t0123456789abcdef",
    "stretch\tblack\t0\t120",
    "learned\tee\t00100000\t00100000\t64\t0123456789abcdef\t-",
    "refused\tee\t00200000\tsmc",
    "call\tee\t001c9e28\t01345e78\t12",
    "thread\t1\t00100008\t1\t65536\trun",
    "sema\t1\t0\t1\tlive\t0\t0",
    "perf\t3600\t1200\t2400\t9000\t17\t3\t0\t0",
    "cap\tsema\t256\t8200",
    "end\tframes\t3600\t17712000868\t579220067\t1\t130299087\t0\t0\t3580\t-1\t0\t0\t",
]


def text(rows):
    return ("\n".join(rows) + "\n").encode()


def errors(rows):
    return gd.check(text(rows))[0]


def swap(n, row):
    rows = list(GOOD)
    rows[n] = row
    return rows


class Check(unittest.TestCase):
    def test_good(self):
        self.assertEqual(errors(GOOD), [])

    def test_bad_field(self):
        # a 7-digit address
        e = errors(swap(5, "interp\tee\t01c6408\t52\t001c6400\t24\t0123456789abcdef\t1"))
        self.assertEqual(e, ["line 6: interp field 3 '01c6408'"])

    def test_hex_run_in_text(self):
        e = errors(swap(7, "sys\tx" + "0123456789abcdef" * 4 + "\t7\t00123456\t00123400\t80000597"))
        self.assertEqual(e, ["line 8: a run of more than 16 hex digits"])

    def test_hex_run_across_fields_is_fields(self):
        # 16 digits, a tab, 16 more: two fields, not one run.
        self.assertEqual(errors(GOOD), [])
        self.assertIsNone(gd.row(GOOD[3]))

    def test_out_of_order(self):
        rows = list(GOOD)
        rows[3], rows[7] = rows[7], rows[3]  # sys before load
        self.assertIn("line 5: load after sys", errors(rows))

    def test_unsorted(self):
        rows = list(GOOD)
        rows[3], rows[4] = rows[4], rows[3]
        self.assertEqual(errors(rows), ["line 5: load rows not sorted"])

    def test_verdict(self):
        rows = GOOD[:-1] + ["verdict\t5\tingame"] + GOOD[-1:]
        self.assertEqual(errors(rows), ["line 18: unknown kind 'verdict'"])

    def test_unknown_kind_and_count(self):
        self.assertEqual(errors(swap(9, "stretch\tblack\t0")), ["line 10: stretch has 3 fields, not 4"])
        self.assertEqual(errors(swap(9, "pnach\tblack\t0\t1")), ["line 10: unknown kind 'pnach'"])

    def test_once(self):
        self.assertEqual(errors(GOOD[:-1]), ["no end row"])
        self.assertEqual(errors(GOOD[:2] + GOOD[1:]), ["line 3: a second id row"])

    def test_bytes(self):
        self.assertEqual(gd.check(b"gamedata\t2")[0], ["the last line has no newline"])
        self.assertEqual(gd.check("gamedata\t2é\n".encode())[0], ["not ASCII"])


class Unpack(unittest.TestCase):
    def test_gzip(self):
        data, err = gd.unpack(gzip.compress(text(GOOD)))
        self.assertIsNone(err)
        self.assertEqual(data, text(GOOD))

    def test_oversized_raw(self):
        self.assertEqual(gd.unpack(b"x" * (gd.RAW_MAX + 1)), (None, "over %d bytes" % gd.RAW_MAX))

    def test_oversized_gunzipped(self):
        # a few KB that gunzip to over RAW_MAX
        data = gzip.compress(b"\n" * (gd.RAW_MAX + 1))
        self.assertLess(len(data), gd.PACKED_MAX)
        self.assertEqual(gd.unpack(data), (None, "over %d bytes gunzipped" % gd.RAW_MAX))

    def test_oversized_packed(self):
        data = gzip.compress(os.urandom(gd.PACKED_MAX + 1))
        self.assertEqual(gd.unpack(data), (None, "gzip file over %d bytes" % gd.PACKED_MAX))

    def test_two_members(self):
        data = gzip.compress(text(GOOD)) * 2
        self.assertEqual(gd.unpack(data), (None, "gzip: not one whole member"))


class Place(unittest.TestCase):
    def place(self, rows, issue="42", packed=True):
        root = tempfile.mkdtemp()
        p = os.path.join(root, "sent.gz")
        with open(p, "wb") as f:
            f.write(gzip.compress(text(rows)) if packed else text(rows))
        rc = gd.main(["place", p, issue, root])
        return rc, root

    def test_place(self):
        rc, root = self.place(GOOD)
        self.assertEqual(rc, 0)
        with open(os.path.join(root, "games/SLUS-21503/gamedata-bca8d59-42.tsv"), "rb") as f:
            self.assertEqual(f.read(), text(GOOD))

    def test_no_serial(self):
        rows = swap(1, "id\t87a1f19509adbf9b\t\tps2\t%s\t0\t0000000000000000\t3600" % SHA)
        rc, root = self.place(rows, packed=False)
        self.assertEqual(rc, 0)
        self.assertTrue(os.path.isfile(os.path.join(root, "games/87a1f19509adbf9b/gamedata-bca8d59-42.tsv")))

    def refused(self, rows, issue="42"):
        rc, root = self.place(rows, issue)
        self.assertEqual(rc, 1)
        self.assertFalse(os.path.exists(os.path.join(root, "games")))

    def test_refused(self):
        self.refused(swap(1, GOOD[1].replace(SHA, "dev")))
        self.refused(GOOD, issue="42/../x")
        self.refused(swap(1, GOOD[1].replace("SLUS-21503.", "../../x.")))
        self.refused(swap(5, "interp\tee\t01c6408\t52\t001c6400\t24\t0123456789abcdef\t1"))

    def test_prints_build(self):
        out = io.StringIO()
        root = tempfile.mkdtemp()
        p = os.path.join(root, "sent")
        with open(p, "wb") as f:
            f.write(text(GOOD))
        with contextlib.redirect_stdout(out):
            self.assertEqual(gd.main(["place", p, "7", root]), 0)
        self.assertEqual(out.getvalue(), "games/SLUS-21503/gamedata-bca8d59-7.tsv\t%s\n" % SHA)


class IdBuild(unittest.TestCase):
    def test_long_run_only_in_build(self):
        # The build field may hold a 40-digit commit; no other id field may.
        self.assertIsNone(gd.row(GOOD[1]))
        bad = GOOD[1].replace("\tps2\t", "\t" + "a" * 40 + "\t")
        self.assertEqual(gd.row(bad), "a run of more than 16 hex digits")
        self.assertEqual(gd.row(GOOD[1].replace(SHA, SHA + "0")), "a run of more than 16 hex digits")


class Url(unittest.TestCase):
    LINK = "https://github.com/user-attachments/files/23456789/gamedata.tsv.gz"

    def url(self, body):
        out, err = io.StringIO(), io.StringIO()
        old = sys.stdin
        sys.stdin = io.TextIOWrapper(io.BytesIO(body.encode()))
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                rc = gd.main(["url"])
        finally:
            sys.stdin = old
        return rc, out.getvalue()

    def test_one(self):
        body = "Sent from the web player.\n\n[gamedata.tsv.gz](%s)\n" % self.LINK
        self.assertEqual(self.url(body), (0, self.LINK + "\n"))
        # the same link twice is one attachment
        self.assertEqual(self.url(body + self.LINK + "\n"), (0, self.LINK + "\n"))

    def test_none(self):
        self.assertEqual(self.url("no file\n"), (1, ""))
        # a link the pattern would cut short is not taken
        self.assertEqual(self.url(self.LINK + "?x=1\n"), (1, ""))
        self.assertEqual(self.url(self.LINK.replace("files/", "files/../") + "\n"), (1, ""))

    def test_two(self):
        self.assertEqual(self.url("%s\n%s2\n" % (self.LINK, self.LINK)), (1, ""))


if __name__ == "__main__":
    unittest.main()
