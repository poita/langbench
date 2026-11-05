#!/usr/bin/env python3
"""Regenerate problems/sqlitefile/tests/.

Builds every test database deterministically (from the vendored corpora in
corpus/ and from seeded synthetic data), writes each case's queries.txt, fills
expected/ with the reference implementation's output, and cross-checks every
oracle-translatable query against the sqlite3 command line shell.  Any
disagreement aborts the run.
"""
import csv
import gzip
import os
import random
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
CORPUS = os.path.join(HERE, "corpus")
WORK = None  # set to a temporary directory by main()
REFERENCE = os.path.join(HERE, "reference", "main.py")
SQLITE3 = "sqlite3"


# ---------------------------------------------------------------------------
# database construction
# ---------------------------------------------------------------------------


def new_db(name, page_size=4096):
    path = os.path.join(WORK, name)
    if os.path.exists(path):
        os.unlink(path)
    con = sqlite3.connect(path)
    con.execute("PRAGMA page_size=%d" % page_size)
    con.execute("PRAGMA journal_mode=delete")
    return path, con


def finish(con):
    con.commit()
    con.close()


def db_people():
    """A small database: one rowid table with every storage class."""
    path, con = new_db("people.sqlite", 4096)
    con.execute("""CREATE TABLE people(
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        age INTEGER,
        height REAL,
        photo BLOB)""")
    rows = [
        (1, "Ada", 36, 1.65, b"\x00\x01\x02"),
        (2, "Grace", 45, 1.7, None),
        (3, "Alan", None, 1.8, b""),
        (4, "Edsger", 72, None, b"\xff\xee"),
        (5, "Barbara", 51, 1.575, None),
        (6, "", 0, 0.0, b"\x7f"),
    ]
    con.executemany("INSERT INTO people VALUES(?,?,?,?,?)", rows)
    con.execute("CREATE TABLE notes(note TEXT)")
    con.executemany("INSERT INTO notes VALUES(?)", [("first",), ("second",)])
    finish(con)
    return path


def db_rowids():
    """Explicit rowids spanning every varint width, negatives included, with
    the rowid alias declared in the middle of the column list."""
    path, con = new_db("rowids.sqlite", 4096)
    con.execute("""CREATE TABLE r(
        label TEXT,
        id INTEGER PRIMARY KEY,
        weight REAL)""")
    ids = [
        -9223372036854775808, -72057594037927936, -140737488355328,
        -2147483648, -32768, -129, -1, 0, 1, 127, 128, 32767, 32768,
        8388607, 8388608, 2147483647, 2147483648, 140737488355327,
        140737488355328, 72057594037927935, 72057594037927936,
        4611686018427387904, 9223372036854775807,
    ]
    weights = [None, 0.0, 1.0, -2.5, 1e100]
    rows = [(i, "row-%02d" % n, weights[n % len(weights)])
            for n, i in enumerate(ids)]
    con.executemany("INSERT INTO r(id,label,weight) VALUES(?,?,?)", rows)
    con.execute("CREATE INDEX r_label ON r(label)")
    con.execute("CREATE INDEX r_id ON r(id)")
    finish(con)
    return path


def db_types():
    """Every record serial type, including the integer width boundaries."""
    path, con = new_db("types.sqlite", 4096)
    con.execute("CREATE TABLE vals(k INTEGER PRIMARY KEY, v)")
    values = [
        None, 0, 1, -1, 127, -128, 128, -129,
        32767, -32768, 32768, -32769,
        8388607, -8388608, 8388608, -8388609,
        2147483647, -2147483648, 2147483648, -2147483649,
        140737488355327, -140737488355328, 140737488355328, -140737488355329,
        9223372036854775807, -9223372036854775808,
        0.0, 1.0, -1.0, 0.5, 0.1, 3.14159265358979, 1.5e16, 2.5e-10,
        1e100, -1e-100, 1234567890.125,
        # %.15g switches to exponential form when the decimal exponent is
        # below -4 or at least 15, and "-0" must still print as "0.0".
        -0.0, 1e14, 1e15, 999999999999999.0, 123456789012345.0, 1e-4, 1e-5,
        "", "a", "hello world", "0", "007", "3.5",
        b"", b"\x00", b"\x00\xff\x10", bytes(range(16)),
    ]
    con.executemany("INSERT INTO vals(v) VALUES(?)", [(v,) for v in values])
    finish(con)
    return path


def db_affinity():
    """Columns of each declared-type family, for affinity comparisons."""
    path, con = new_db("affinity.sqlite", 4096)
    con.execute("""CREATE TABLE aff(
        id INTEGER PRIMARY KEY,
        i INTEGER,
        t TEXT,
        r REAL,
        n NUMERIC(10,2),
        b BLOB,
        x)""")
    rows = [
        (1, 5, "5", 5.0, 5, b"5", "5"),
        (2, 10, "10", 10.5, 10.5, b"\x05", 10),
        (3, -3, "-3", -3.25, -3, b"", 10.5),
        (4, 0, "0", 0.0, 0, b"\x00", None),
        (5, None, None, None, None, None, "abc"),
        (6, 100, "abc", 100.0, "abc", b"abc", b"abc"),
        (7, 2, "02", 2.0, 2, b"02", 2),
    ]
    con.executemany("INSERT INTO aff VALUES(?,?,?,?,?,?,?)", rows)
    # Declared type names that make the order of the affinity rules visible:
    # STRING, FLOATING POINT and INTTEXT all contain "INT" and so are INTEGER,
    # CHARFLOAT is TEXT, BLOBREAL is BLOB.  SQLite applies the column affinity
    # when the row is stored, so the values land in different storage classes.
    con.execute("""CREATE TABLE affname(
        id INTEGER PRIMARY KEY,
        s STRING,
        fp FLOATING POINT,
        it INTTEXT,
        cf CHARFLOAT,
        br BLOBREAL,
        dp DOUBLE PRECISION,
        dc DECIMAL(10,5),
        nt)""")
    con.executemany("INSERT INTO affname VALUES(?,?,?,?,?,?,?,?,?)", [
        (n,) + (v,) * 8 for n, v in
        enumerate([7, "7", 0, None, 2.5, "abc"], 1)
    ])
    finish(con)
    return path


def db_shapes():
    """Primary keys that are *not* rowid aliases, plus a view and a trigger."""
    path, con = new_db("shapes.sqlite", 4096)
    # The declared type must be exactly INTEGER, so `code` is an ordinary
    # column and its value differs from the rowid.
    con.execute("CREATE TABLE intpk(code INT PRIMARY KEY, label TEXT, score REAL)")
    con.executemany("INSERT INTO intpk(code,label,score) VALUES(?,?,?)",
                    [(100, "alpha", 1.5), (200, "beta", 2.0),
                     (50, "gamma", -0.75), (7, "delta", 0.0)])
    # A DESC primary key is not a rowid alias either, in both spellings.
    con.execute("CREATE TABLE descpk(n INTEGER PRIMARY KEY DESC, label TEXT)")
    con.executemany("INSERT INTO descpk(n,label) VALUES(?,?)",
                    [(500, "five"), (400, "four"), (600, "six")])
    con.execute("CREATE TABLE tdesc(n INTEGER NOT NULL, label TEXT, "
                "CONSTRAINT pk_tdesc PRIMARY KEY(n DESC))")
    con.executemany("INSERT INTO tdesc(n,label) VALUES(?,?)",
                    [(90, "ninety"), (80, "eighty")])
    # A two-column primary key: neither column aliases the rowid.
    con.execute("CREATE TABLE pair(a INTEGER, b INTEGER, note TEXT, PRIMARY KEY(a,b))")
    con.executemany("INSERT INTO pair(a,b,note) VALUES(?,?,?)",
                    [(3, 1, "x"), (3, 2, "y"), (1, 9, "z")])
    con.execute("CREATE TABLE host(id INTEGER PRIMARY KEY, name TEXT)")
    con.executemany("INSERT INTO host VALUES(?,?)",
                    [(1, "ada"), (2, "grace"), (3, "alan")])
    # A view and a trigger are sqlite_schema rows with no root page; the
    # trigger is created after the inserts, so it never fires.
    con.execute("CREATE VIEW hostview AS SELECT id, name FROM host")
    con.execute("CREATE TRIGGER host_touch AFTER INSERT ON host BEGIN "
                "UPDATE host SET name = NEW.name WHERE id = NEW.id; END")
    con.execute("CREATE INDEX intpk_label ON intpk(label)")
    finish(con)
    return path


def db_deep_index():
    """512-byte pages and a low-cardinality index, so that one key's run of
    entries spans whole subtrees rooted at interior index pages."""
    path, con = new_db("deep_index.sqlite", 512)
    con.execute("""CREATE TABLE ping(
        id INTEGER PRIMARY KEY,
        flag TEXT,
        host TEXT,
        ms INTEGER)""")
    rnd = random.Random(8080)
    rows = [(i, "A" if i % 5 == 0 else "B", "h-%03d" % rnd.randrange(250),
             rnd.randrange(1, 900)) for i in range(1, 8001)]
    con.executemany("INSERT INTO ping VALUES(?,?,?,?)", rows)
    con.execute("CREATE INDEX ping_flag ON ping(flag)")
    con.execute("CREATE INDEX ping_host ON ping(host)")
    finish(con)
    return path


def db_alter():
    """ALTER TABLE ADD COLUMN leaves short records in the older pages."""
    path, con = new_db("alter.sqlite", 4096)
    con.execute("CREATE TABLE item(id INTEGER PRIMARY KEY, name TEXT)")
    con.executemany("INSERT INTO item VALUES(?,?)",
                    [(i, "item-%d" % i) for i in range(1, 21)])
    con.execute("ALTER TABLE item ADD COLUMN qty INTEGER")
    con.execute("ALTER TABLE item ADD COLUMN tag TEXT")
    con.executemany("INSERT INTO item VALUES(?,?,?,?)",
                    [(i, "item-%d" % i, i * 3, "tag%d" % (i % 4)) for i in range(21, 31)])
    finish(con)
    return path


def db_unicode():
    """UTF-8 text with an index, to exercise BINARY (byte order) collation."""
    path, con = new_db("unicode.sqlite", 4096)
    con.execute("CREATE TABLE words(id INTEGER PRIMARY KEY, w TEXT, lang TEXT)")
    rows = [
        ("apple", "en"), ("Apple", "en"), ("zebra", "en"), ("Zebra", "en"),
        ("éclair", "fr"), ("Éclair", "fr"), ("naïve", "fr"),
        ("你好", "zh"), ("世界", "zh"), ("こんにちは", "ja"),
        ("привет", "ru"), ("مرحبا", "ar"),
        ("\U0001f600", "emoji"), ("\U0001f680 launch", "emoji"),
        ("", "empty"), (" leading", "en"), ("trailing ", "en"),
    ]
    con.executemany("INSERT INTO words(w,lang) VALUES(?,?)", rows)
    con.execute("CREATE INDEX words_w ON words(w)")
    con.execute("CREATE INDEX words_lang ON words(lang)")
    finish(con)
    return path


def db_small_pages():
    """1024-byte pages and enough rows for a three-level table B-tree."""
    path, con = new_db("small_pages.sqlite", 1024)
    con.execute("""CREATE TABLE reading(
        id INTEGER PRIMARY KEY,
        station TEXT,
        celsius REAL,
        quality INTEGER)""")
    rnd = random.Random(20240117)
    rows = []
    for i in range(1, 20001):
        rows.append((i, "ST-%04d" % rnd.randrange(400),
                     round(rnd.uniform(-40, 45), 3), rnd.randrange(4)))
    con.executemany("INSERT INTO reading VALUES(?,?,?,?)", rows)
    con.execute("CREATE INDEX reading_station ON reading(station)")
    con.execute("CREATE INDEX reading_quality ON reading(quality)")
    finish(con)
    return path


def db_big_pages():
    """65536-byte pages."""
    path, con = new_db("big_pages.sqlite", 65536)
    con.execute("""CREATE TABLE doc(
        id INTEGER PRIMARY KEY,
        title TEXT,
        words INTEGER,
        ratio REAL)""")
    rnd = random.Random(777)
    rows = [(i, "doc-%05d" % i, rnd.randrange(50, 50000),
             round(rnd.uniform(0, 1), 6)) for i in range(1, 6001)]
    con.executemany("INSERT INTO doc VALUES(?,?,?,?)", rows)
    con.execute("CREATE INDEX doc_words ON doc(words)")
    finish(con)
    return path


def IKEY(n):
    """An n-character index key for the ikey table."""
    return ("k%03d-" % n) + "y" * (n - 5)


def db_overflow():
    """512-byte pages with payloads that spill onto long overflow chains."""
    path, con = new_db("overflow.sqlite", 512)
    con.execute("CREATE TABLE blobs(id INTEGER PRIMARY KEY, n INTEGER, body BLOB, label TEXT)")
    rnd = random.Random(31337)
    rows = []
    sizes = [0, 1, 10, 50, 100, 200, 400, 440, 445, 450, 455, 460, 500,
             600, 1000, 2000, 4000, 8000, 20000, 60000]
    for i, n in enumerate(sizes, 1):
        body = bytes(rnd.randrange(256) for _ in range(n))
        rows.append((i, n, body, "blob-%d" % n))
    con.executemany("INSERT INTO blobs VALUES(?,?,?,?)", rows)
    con.execute("CREATE TABLE texts(id INTEGER PRIMARY KEY, body TEXT)")
    tr = []
    for i, n in enumerate([3, 300, 900, 5000, 30000], 1):
        tr.append((i, "".join(chr(97 + ((j * 7) % 26)) for j in range(n))))
    con.executemany("INSERT INTO texts VALUES(?,?)", tr)
    con.execute("CREATE INDEX blobs_n ON blobs(n)")
    # Table-leaf payloads either side of X = U - 35 = 477: the record of
    # edge row n is n + 4 bytes, so 473 is the largest that stays local.
    con.execute("CREATE TABLE edge(id INTEGER PRIMARY KEY, b BLOB)")
    con.executemany("INSERT INTO edge VALUES(?,?)",
                    [(n, bytes((n * 7 + j) % 256 for j in range(n)))
                     for n in range(465, 486)])
    # Index payloads either side of X = ((U-12)*64/255) - 23 = 102: the index
    # record for a key of n characters is n + 5 bytes.
    con.execute("CREATE TABLE ikey(id INTEGER PRIMARY KEY, s TEXT)")
    con.executemany("INSERT INTO ikey VALUES(?,?)",
                    [(n, IKEY(n)) for n in range(90, 111)])
    con.execute("CREATE INDEX ikey_s ON ikey(s)")
    finish(con)
    return path


def db_overflow_index():
    """Index keys long enough to overflow an index page."""
    path, con = new_db("long_keys.sqlite", 512)
    con.execute("CREATE TABLE k(id INTEGER PRIMARY KEY, key TEXT, payload TEXT)")
    rows = []
    for i in range(1, 201):
        rows.append((i, ("key%03d-" % i) + "z" * 700, "payload %d" % i))
    con.executemany("INSERT INTO k VALUES(?,?,?)", rows)
    con.execute("CREATE INDEX k_key ON k(key)")
    finish(con)
    return path


def db_freelist():
    """Deleting most of a large table leaves a long freelist behind."""
    path, con = new_db("freelist.sqlite", 1024)
    con.execute("PRAGMA auto_vacuum=none")
    con.execute("CREATE TABLE ev(id INTEGER PRIMARY KEY, kind TEXT, amount INTEGER, note TEXT)")
    rnd = random.Random(99)
    rows = [(i, "kind-%d" % (i % 7), rnd.randrange(100000),
             "note for event %d padded out a little" % i) for i in range(1, 30001)]
    con.executemany("INSERT INTO ev VALUES(?,?,?,?)", rows)
    con.execute("CREATE INDEX ev_kind ON ev(kind)")
    con.commit()
    con.execute("DELETE FROM ev WHERE id % 13 != 0")
    con.commit()
    free = con.execute("PRAGMA freelist_count").fetchone()[0]
    assert free > 50, "expected a substantial freelist, got %d" % free
    finish(con)
    return path


def db_indexes():
    """Several index shapes: duplicates, NULLs, text keys, a composite index."""
    path, con = new_db("indexes.sqlite", 4096)
    con.execute("""CREATE TABLE emp(
        emp_id INTEGER PRIMARY KEY,
        dept TEXT,
        salary INTEGER,
        grade REAL,
        manager INTEGER)""")
    rnd = random.Random(4242)
    depts = ["eng", "sales", "ops", "hr", "legal", "études"]
    rows = []
    for i in range(1, 4001):
        dept = depts[rnd.randrange(len(depts))] if i % 17 else None
        rows.append((i, dept, rnd.randrange(30000, 200000),
                     round(rnd.uniform(1, 5), 2),
                     None if i % 11 == 0 else rnd.randrange(1, 40)))
    con.executemany("INSERT INTO emp VALUES(?,?,?,?,?)", rows)
    con.execute("CREATE INDEX emp_dept ON emp(dept)")
    con.execute("CREATE INDEX emp_manager ON emp(manager)")
    con.execute("CREATE INDEX emp_grade ON emp(grade)")
    con.execute("CREATE INDEX emp_dept_salary ON emp(dept, salary)")
    con.execute("CREATE TABLE tag(name TEXT PRIMARY KEY, weight INTEGER)")
    con.executemany("INSERT INTO tag VALUES(?,?)",
                    [("tag-%03d" % i, i * 3) for i in range(1, 60)])
    # AUTOINCREMENT makes SQLite create the internal sqlite_sequence table,
    # which ".tables" must not list.
    con.execute("CREATE TABLE seq(id INTEGER PRIMARY KEY AUTOINCREMENT, label TEXT)")
    con.executemany("INSERT INTO seq(label) VALUES(?)",
                    [("s-%d" % i,) for i in range(1, 6)])
    finish(con)
    return path


def db_chinook(name="chinook.sqlite"):
    path = os.path.join(WORK, name)
    src = os.path.join(CORPUS, "chinook", "chinook.sqlite.gz")
    with gzip.open(src, "rb") as f, open(path, "wb") as out:
        shutil.copyfileobj(f, out)
    return path


def read_corpus_csv(name):
    with gzip.open(os.path.join(CORPUS, "ourairports", name), "rt",
                   encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def _num(s, real=False):
    """Parse a CSV field.  Coordinates are rounded to six decimal places (about
    0.1 m) so that every stored REAL round-trips through 15 significant
    digits, as SPEC.md guarantees."""
    if s == "":
        return None
    try:
        return round(float(s), 6) if real else int(s)
    except ValueError:
        return None


def db_airports():
    """The full OurAirports corpus: 134k rows across two tables."""
    path, con = new_db("airports.sqlite", 4096)
    con.execute("""CREATE TABLE airport(
        id INTEGER PRIMARY KEY,
        ident TEXT NOT NULL,
        type TEXT,
        name TEXT,
        latitude_deg REAL,
        longitude_deg REAL,
        elevation_ft INTEGER,
        continent TEXT,
        iso_country TEXT,
        iso_region TEXT,
        municipality TEXT,
        scheduled_service TEXT,
        gps_code TEXT,
        iata_code TEXT)""")
    rows = []
    for r in read_corpus_csv("airports.csv.gz"):
        rows.append((int(r["id"]), r["ident"], r["type"], r["name"],
                     _num(r["latitude_deg"], True), _num(r["longitude_deg"], True),
                     _num(r["elevation_ft"]), r["continent"] or None,
                     r["iso_country"], r["iso_region"], r["municipality"] or None,
                     r["scheduled_service"], r["gps_code"] or None,
                     r["iata_code"] or None))
    con.executemany("INSERT INTO airport VALUES(%s)" % ",".join("?" * 14), rows)
    con.execute("""CREATE TABLE runway(
        id INTEGER PRIMARY KEY,
        airport_ref INTEGER,
        airport_ident TEXT,
        length_ft INTEGER,
        width_ft INTEGER,
        surface TEXT,
        lighted INTEGER,
        closed INTEGER,
        le_ident TEXT,
        he_ident TEXT)""")
    rrows = []
    for r in read_corpus_csv("runways.csv.gz"):
        rrows.append((int(r["id"]), _num(r["airport_ref"]), r["airport_ident"],
                      _num(r["length_ft"]), _num(r["width_ft"]), r["surface"] or None,
                      _num(r["lighted"]), _num(r["closed"]),
                      r["le_ident"] or None, r["he_ident"] or None))
    con.executemany("INSERT INTO runway VALUES(%s)" % ",".join("?" * 10), rrows)
    con.execute("CREATE INDEX airport_country ON airport(iso_country)")
    con.execute("CREATE INDEX airport_ident ON airport(ident)")
    con.execute("CREATE INDEX airport_type ON airport(type)")
    con.execute("CREATE INDEX runway_ref ON runway(airport_ref)")
    finish(con)
    return path


def db_airports_us():
    """A narrower slice of the same corpus stored in 65536-byte pages."""
    path, con = new_db("us_airports.sqlite", 65536)
    con.execute("""CREATE TABLE usap(
        id INTEGER PRIMARY KEY,
        ident TEXT,
        type TEXT,
        name TEXT,
        elevation_ft INTEGER,
        iso_region TEXT,
        municipality TEXT)""")
    rows = []
    for r in read_corpus_csv("airports.csv.gz"):
        if r["iso_country"] != "US":
            continue
        rows.append((int(r["id"]), r["ident"], r["type"], r["name"],
                     _num(r["elevation_ft"]), r["iso_region"],
                     r["municipality"] or None))
    con.executemany("INSERT INTO usap VALUES(?,?,?,?,?,?,?)", rows)
    con.execute("CREATE INDEX usap_region ON usap(iso_region)")
    con.execute("CREATE INDEX usap_type ON usap(type)")
    finish(con)
    return path


BUILDERS = {
    "people": db_people,
    "shapes": db_shapes,
    "deep_index": db_deep_index,
    "rowids": db_rowids,
    "types": db_types,
    "affinity": db_affinity,
    "alter": db_alter,
    "unicode": db_unicode,
    "small_pages": db_small_pages,
    "big_pages": db_big_pages,
    "overflow": db_overflow,
    "long_keys": db_overflow_index,
    "freelist": db_freelist,
    "indexes": db_indexes,
    "chinook": db_chinook,
    "airports": db_airports,
    "us_airports": db_airports_us,
}


# ---------------------------------------------------------------------------
# an independent parser for the query language, used to drive the oracle
# ---------------------------------------------------------------------------


class Parse:
    def __init__(self, s):
        self.s = s
        self.i = 0

    def ws(self):
        while self.i < len(self.s) and self.s[self.i] in " \t":
            self.i += 1

    def done(self):
        self.ws()
        return self.i >= len(self.s)

    def word(self):
        self.ws()
        j = self.i
        while j < len(self.s) and (self.s[j].isalnum() or self.s[j] == "_"):
            j += 1
        w = self.s[self.i:j]
        self.i = j
        return w

    def look(self):
        save = self.i
        w = self.word()
        self.i = save
        return w.upper()

    def ch(self, c):
        self.ws()
        if self.i < len(self.s) and self.s[self.i] == c:
            self.i += 1
            return True
        return False

    def op(self):
        self.ws()
        for o in ("<=", ">=", "!=", "=", "<", ">"):
            if self.s.startswith(o, self.i):
                self.i += len(o)
                return "<>" if o == "!=" else o
        if self.look() == "IS":
            self.word()
            if self.look() == "NOT":
                self.word()
                return "IS NOT"
            return "IS"
        raise ValueError("operator")

    def literal(self):
        self.ws()
        c = self.s[self.i]
        if c == "'":
            j, buf = self.i + 1, []
            while True:
                if self.s[j] == "'":
                    if self.s[j + 1:j + 2] == "'":
                        buf.append("'")
                        j += 2
                        continue
                    break
                buf.append(self.s[j])
                j += 1
            self.i = j + 1
            return "".join(buf)
        if c in "Xx" and self.s[self.i + 1:self.i + 2] == "'":
            j = self.s.index("'", self.i + 2)
            h = self.s[self.i + 2:j]
            self.i = j + 1
            return bytes.fromhex(h)
        if c.isalpha():
            w = self.word()
            if w.upper() != "NULL":
                raise ValueError("literal")
            return None
        j = self.i
        if self.s[j] in "+-":
            j += 1
        start = j
        while j < len(self.s) and self.s[j].isdigit():
            j += 1
        if j == start:
            raise ValueError("literal")
        real = False
        if self.s[j:j + 1] == ".":
            real = True
            j += 1
            while j < len(self.s) and self.s[j].isdigit():
                j += 1
        if self.s[j:j + 1] in ("e", "E"):
            k = j + 1
            if self.s[k:k + 1] in ("+", "-"):
                k += 1
            if self.s[k:k + 1].isdigit():
                while k < len(self.s) and self.s[k].isdigit():
                    k += 1
                j, real = k, True
        text = self.s[self.i:j]
        self.i = j
        return float(text) if real else int(text)


IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*$")


def parse_line(line):
    """Return a structured query, or raise ValueError."""
    if line.startswith("."):
        parts = line.split()
        if parts == [".tables"]:
            return {"kind": "tables"}
        if len(parts) == 2 and parts[0] == ".schema" and IDENT.match(parts[1]):
            return {"kind": "schema", "table": parts[1]}
        raise ValueError("dot command")
    p = Parse(line)
    head = p.look()
    if head == "COUNT":
        p.word()
        t = p.word()
        if not t or not p.done():
            raise ValueError("count")
        return {"kind": "count", "table": t}
    if head == "INDEX":
        p.word()
        name = p.word()
        val = p.literal()
        if not name or not p.done():
            raise ValueError("index")
        return {"kind": "index", "index": name, "value": val}
    if head != "SELECT":
        raise ValueError("command")
    p.word()
    if p.ch("*"):
        cols = None
    else:
        cols = [p.word()]
        while p.ch(","):
            cols.append(p.word())
        if not all(cols):
            raise ValueError("columns")
    if p.word().upper() != "FROM":
        raise ValueError("from")
    table = p.word()
    where = []
    if not p.done() and p.look() == "WHERE":
        p.word()
        while True:
            c = p.word()
            o = p.op()
            v = p.literal()
            where.append((c, o, v))
            if p.done() or p.look() != "AND":
                break
            p.word()
    order = None
    if not p.done() and p.look() == "ORDER":
        p.word()
        if p.word().upper() != "BY":
            raise ValueError("by")
        col = p.word()
        desc = False
        if not p.done() and p.look() in ("ASC", "DESC"):
            desc = p.word().upper() == "DESC"
        order = (col, desc)
    limit = None
    if not p.done() and p.look() == "LIMIT":
        p.word()
        p.ws()
        j = p.i
        while j < len(p.s) and p.s[j].isdigit():
            j += 1
        if j == p.i:
            raise ValueError("limit")
        limit = int(p.s[p.i:j])
        p.i = j
    if not p.done():
        raise ValueError("trailing")
    return {"kind": "select", "cols": cols, "table": table,
            "where": where, "order": order, "limit": limit}


# ---------------------------------------------------------------------------
# oracle
# ---------------------------------------------------------------------------


def ident(name):
    # Bracket quoting, because SQLite silently reinterprets an unresolvable
    # double-quoted identifier as a string literal, which would hide the errors
    # the oracle is meant to report.
    assert "]" not in name, name
    return "[" + name + "]"


def sql_literal(v):
    if v is None:
        return "NULL"
    if isinstance(v, bytes):
        return "X'" + v.hex() + "'" if v else "X''"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(v)
    return "'" + v.replace("'", "''") + "'"


def shell(db, *args):
    proc = subprocess.run([SQLITE3, "-batch", "-noheader", "-separator", "\t",
                           "-nullvalue", "NULL", db] + list(args),
                          capture_output=True)
    return proc.returncode, proc.stdout.decode("utf-8"), proc.stderr.decode("utf-8")


def table_columns(db, table):
    con = sqlite3.connect(db)
    try:
        rows = con.execute('PRAGMA table_info(%s)' % ident(table)).fetchall()
    finally:
        con.close()
    return [r[1] for r in rows]


def index_info(db, name):
    """Return (table, [columns]) for a named index, or None."""
    con = sqlite3.connect(db)
    try:
        row = con.execute("SELECT tbl_name, sql FROM sqlite_schema "
                          "WHERE type='index' AND lower(name)=lower(?)",
                          (name,)).fetchone()
        if not row or not row[1]:
            return None
        cols = [r[2] for r in con.execute("PRAGMA index_info(%s)" % ident(name))]
    finally:
        con.close()
    return row[0], cols


def col_expr(name):
    if name.lower() == "rowid":
        return "rowid"
    return ident(name)


def out_expr(name):
    e = col_expr(name)
    return "CASE WHEN typeof(%s)='blob' THEN hex(%s) ELSE %s END" % (e, e, e)


def oracle_sql(db, q):
    """Translate a parsed query into SQL for the sqlite3 shell, or None."""
    if q["kind"] == "tables":
        return ("SELECT name FROM sqlite_schema WHERE type='table' "
                "AND name NOT LIKE 'sqlite@_%' ESCAPE '@' ORDER BY name;")
    if q["kind"] == "count":
        return "SELECT count(*) FROM %s;" % ident(q["table"])
    if q["kind"] == "select":
        cols = q["cols"] if q["cols"] is not None else table_columns(db, q["table"])
        sel = ", ".join(out_expr(c) for c in cols)
        sql = "SELECT %s FROM %s" % (sel, ident(q["table"]))
        if q["where"]:
            parts = []
            for c, o, v in q["where"]:
                parts.append("%s %s %s" % (col_expr(c), o, sql_literal(v)))
            sql += " WHERE " + " AND ".join(parts)
        if q["order"]:
            sql += " ORDER BY %s %s, rowid ASC" % (col_expr(q["order"][0]),
                                                   "DESC" if q["order"][1] else "ASC")
        else:
            sql += " ORDER BY rowid ASC"
        if q["limit"] is not None:
            sql += " LIMIT %d" % q["limit"]
        return sql + ";"
    if q["kind"] == "index":
        info = index_info(db, q["index"])
        if info is None or len(info[1]) != 1:
            return None
        table, (col,) = info[0], info[1]
        cols = table_columns(db, table)
        sel = ", ".join(out_expr(c) for c in cols)
        return "SELECT %s FROM %s WHERE %s = %s ORDER BY rowid ASC;" % (
            sel, ident(table), ident(col), sql_literal(q["value"]))
    return None


def normalize(text):
    return "\n".join(l.rstrip() for l in text.replace("\r\n", "\n").split("\n")).rstrip("\n")


def oracle_output(db, line):
    """Return the oracle's expected file contents, or None when not checkable."""
    q = parse_line(line)
    if q["kind"] == "schema":
        code, out, err = shell(db, ".schema %s" % q["table"])
        if code != 0:
            raise RuntimeError("oracle .schema failed: %s" % err)
        return out
    sql = oracle_sql(db, q)
    if sql is None:
        return None
    code, out, err = shell(db, sql)
    if code != 0:
        raise RuntimeError("oracle failed on %r -> %s\n%s" % (line, sql, err))
    return out


def oracle_rejects(db, line):
    """True when the sqlite3 shell also refuses this query."""
    try:
        q = parse_line(line)
    except (ValueError, IndexError):
        return True
    try:
        sql = oracle_sql(db, q)
    except sqlite3.Error:
        return True
    if sql is None:
        return True
    code, _out, _err = shell(db, sql)
    return code != 0


# ---------------------------------------------------------------------------
# test cases
# ---------------------------------------------------------------------------

E = "ERROR"   # expected result is the single line "error", and sqlite3
              # must reject the query too
EX = "ERROR!"  # expected result is "error" by a rule of SPEC.md that sqlite3
               # does not share (views, sqlite_schema, oid/_rowid_), so only
               # the reference's output is checked

CASES = [
    ("001_hello", "people", [
        ".tables",
        ".schema people",
        "COUNT people",
        "SELECT * FROM people",
        "SELECT name FROM people",
    ]),
    ("002_rowid_alias", "people", [
        "SELECT id FROM people",
        "SELECT rowid FROM people",
        "SELECT rowid,id,name FROM people WHERE rowid >= 3",
        "SELECT * FROM notes",
        "SELECT rowid,note FROM notes",
        "COUNT notes",
    ]),
    ("003_rowid_extremes", "rowids", [
        ".schema r",
        "COUNT r",
        "SELECT * FROM r",
        "SELECT rowid,label FROM r WHERE rowid < 0",
        "SELECT id,label FROM r WHERE id >= 72057594037927936",
        "SELECT id,label FROM r ORDER BY id DESC LIMIT 5",
        "SELECT label,weight FROM r ORDER BY weight LIMIT 8",
        "SELECT label FROM r WHERE weight = 0",
        # A text literal converted by INTEGER affinity must become an
        # INTEGER, so that the comparison stays exact past 2**53.
        "SELECT id,label FROM r WHERE id = '9223372036854775807'",
        "SELECT id,label FROM r WHERE id > '9223372036854775806'",
        "SELECT id,label FROM r WHERE id = '-9223372036854775808'",
        "SELECT id,label FROM r WHERE id < '-9223372036854775807'",
        "INDEX r_id 9223372036854775807",
        "INDEX r_id '9223372036854775807'",
        "INDEX r_id -1",
        "INDEX r_id 0",
        "INDEX r_label 'row-07'",
    ]),
    ("004_null_and_blob", "people", [
        "SELECT name,photo FROM people",
        "SELECT * FROM people WHERE photo IS NULL",
        "SELECT * FROM people WHERE photo IS NOT NULL",
        "SELECT name FROM people WHERE age IS NULL",
        "SELECT name,age FROM people WHERE age > 40",
        "SELECT name,photo FROM people WHERE photo = X'00ff'",
        "SELECT name,photo FROM people WHERE photo = X''",
    ]),
    ("005_where_operators", "people", [
        "SELECT name FROM people WHERE age = 45",
        "SELECT name FROM people WHERE age != 45",
        "SELECT name FROM people WHERE age < 45",
        "SELECT name FROM people WHERE age <= 45",
        "SELECT name FROM people WHERE age > 45",
        "SELECT name FROM people WHERE age >= 45",
        "SELECT name FROM people WHERE name = 'Ada'",
        "SELECT name FROM people WHERE name > 'B'",
        "SELECT name FROM people WHERE height < 1.7",
        "SELECT name FROM people WHERE age IS NULL",
        "SELECT name FROM people WHERE age IS 45",
        "SELECT name FROM people WHERE age IS NOT NULL",
    ]),
    ("006_order_limit", "people", [
        "SELECT name,age FROM people ORDER BY age",
        "SELECT name,age FROM people ORDER BY age ASC",
        "SELECT name,age FROM people ORDER BY age DESC",
        "SELECT name FROM people ORDER BY name",
        "SELECT name FROM people ORDER BY name DESC LIMIT 2",
        "SELECT * FROM people LIMIT 0",
        "SELECT * FROM people LIMIT 3",
        "SELECT name,height FROM people ORDER BY height DESC LIMIT 4",
        "SELECT name FROM people ORDER BY photo",
        "SELECT name FROM people ORDER BY rowid DESC",
    ]),
    ("007_serial_types", "types", [
        "COUNT vals",
        "SELECT * FROM vals",
        "SELECT k FROM vals WHERE v = 0",
        "SELECT k FROM vals WHERE v = 1",
        "SELECT k,v FROM vals WHERE v > 2147483647",
        "SELECT k,v FROM vals WHERE v < -2147483648",
        "SELECT k,v FROM vals ORDER BY v LIMIT 12",
        "SELECT k,v FROM vals ORDER BY v DESC LIMIT 12",
    ]),
    ("008_affinity", "affinity", [
        ".schema aff",
        "SELECT * FROM aff",
        "SELECT id FROM aff WHERE i = '5'",
        "SELECT id FROM aff WHERE t = 5",
        "SELECT id FROM aff WHERE t = '5'",
        "SELECT id FROM aff WHERE r = '10.5'",
        "SELECT id FROM aff WHERE n = '10.5'",
        "SELECT id FROM aff WHERE b = '5'",
        "SELECT id FROM aff WHERE b = X'35'",
        "SELECT id FROM aff WHERE x = 10",
        "SELECT id FROM aff WHERE x = '10'",
        "SELECT id,x FROM aff ORDER BY x",
        "SELECT id FROM aff WHERE t = '02'",
        "SELECT id FROM aff WHERE i = 2 AND t = '02'",
    ]),
    ("009_affinity_rule_order", "affinity", [
        ".schema affname",
        "SELECT * FROM affname",
        "SELECT id FROM affname WHERE s = '7'",
        "SELECT id FROM affname WHERE fp = '7'",
        "SELECT id FROM affname WHERE it = '7'",
        "SELECT id FROM affname WHERE cf = 7",
        "SELECT id FROM affname WHERE cf = '7'",
        "SELECT id FROM affname WHERE br = 7",
        "SELECT id FROM affname WHERE br = '7'",
        "SELECT id FROM affname WHERE nt = 7",
        "SELECT id FROM affname WHERE dc = '2.5'",
        "SELECT id FROM affname WHERE dp = 0",
        "SELECT id,dp,dc FROM affname ORDER BY dp",
    ]),
    ("010_multi_condition", "affinity", [
        "SELECT id FROM aff WHERE i >= 0 AND i <= 10",
        "SELECT id FROM aff WHERE i > 0 AND r > 0 AND n IS NOT NULL",
        "SELECT id,i,r FROM aff WHERE i IS NOT NULL ORDER BY r DESC",
        "SELECT id FROM aff WHERE i > 100 AND i < 0",
        "SELECT id,t FROM aff WHERE t IS NOT NULL ORDER BY t",
    ]),
    ("011_errors", "people", [
        (E, "SELECT * FROM nosuch"),
        (E, "SELECT nope FROM people"),
        (E, "COUNT nosuch"),
        (E, "INDEX nosuchindex 1"),
        (E, "SELECT * FROM people WHERE"),
        (E, "SELECT * FROM people ORDER"),
        (E, "SELECT FROM people"),
        (E, "DROP TABLE people"),
        (E, ".dump"),
        (E, "SELECT * FROM people LIMIT x"),
        (E, "SELECT * FROM people WHERE age == 3"),
        ".schema nosuch",
        "SELECT * FROM people WHERE age = 999",
    ]),
    ("012_parse_edge_cases", "people", [
        (E, "SELECT name FROM people WHERE age <> 45"),
        (E, ".SCHEMA people"),
        (E, ".TABLES"),
        (E, ".tables extra"),
        (E, ".schema"),
        (E, ".schema people notes"),
        (E, "SELECT name FROM people EXTRA"),
        (E, "SELECT name, FROM people"),
        (E, "SELECT name FROM people LIMIT -1"),
        (E, "SELECT name FROM people WHERE name = 'abc"),
        (E, "SELECT name FROM people WHERE photo = X'0'"),
        (E, "SELECT name FROM people WHERE photo = X'zz'"),
        (E, "SELECT name FROM people WHERE age = 45 AND"),
        (E, "SELECT name FROM people WHERE height = .65"),
        (E, "SELECT name FROM people ORDER BY name ASC DESC"),
        (E, "INDEX people 'Ada'"),
        "select name from people where age = 45",
        "SELECT  name , age  FROM  people  WHERE  age  >=  45  ORDER  BY  age  DESC  LIMIT  2",
        "SELECT name,photo FROM people WHERE photo = x'00ff'",
        "SELECT NAME FROM PEOPLE WHERE AGE IS NOT NULL",
        "SELECT name FROM people WHERE height = 1.65",
        # Tokens need a separator only between two adjacent words.
        "SELECT*FROM people",
        "SELECT name,age FROM people WHERE age>=45",
        "SELECT id,name FROM people WHERE age>40 ORDER BY name DESC LIMIT 2",
        # A dot command's argument is a bare identifier.
        (E, ".schema 9bad"),
        (E, ".schema people;"),
        (E, ".schema people.notes"),
        # SQLite's other rowid spellings are not part of this language.
        (EX, "SELECT oid FROM people"),
        (EX, "SELECT _rowid_ FROM people"),
    ]),
    ("013_literal_forms", "affinity", [
        # Every legal numeral shape, and the text-to-number conversion that
        # affinity performs on a string literal.
        "SELECT id FROM aff WHERE i = +5",
        "SELECT id FROM aff WHERE i = 5.",
        "SELECT id FROM aff WHERE r = -3.25",
        "SELECT id FROM aff WHERE n = 1.05e1",
        "SELECT id,x FROM aff WHERE x > -2.5e-3",
        "SELECT id FROM aff WHERE r > '.5'",
        "SELECT id FROM aff WHERE i > '.5'",
        "SELECT id FROM aff WHERE n >= '-.5'",
        "SELECT id FROM aff WHERE i >= ' 5 '",
        "SELECT id FROM aff WHERE i > '5.'",
        "SELECT id FROM aff WHERE i = '+5'",
        "SELECT id FROM aff WHERE r = '5e0'",
        "SELECT id FROM aff WHERE n = '-3.0'",
        "SELECT id FROM aff WHERE i > '-'",
        "SELECT id FROM aff WHERE i > ''",
        "SELECT id FROM aff WHERE i > '5 x'",
        "SELECT id FROM aff WHERE t = -3",
        "SELECT id FROM aff WHERE t = 2",
        "SELECT id FROM aff WHERE t = 10.5",
        (E, "SELECT id FROM aff WHERE i = .5"),
        (E, "SELECT id FROM aff WHERE i = 1e"),
        (E, "SELECT id FROM aff WHERE i = 1.2.3"),
        (E, "SELECT id FROM aff WHERE i = 5 5"),
    ]),
    ("014_schema_shapes", "shapes", [
        ".tables",
        ".schema intpk",
        ".schema host",
        ".schema pair",
        ".schema descpk",
        ".schema intpk_label",
        ".schema host_touch",
        "SELECT * FROM intpk",
        "SELECT rowid,code,label,score FROM intpk",
        "SELECT * FROM descpk",
        "SELECT rowid,n,label FROM descpk ORDER BY n",
        "SELECT * FROM tdesc",
        "SELECT rowid,n,label FROM tdesc",
        "SELECT * FROM pair",
        "SELECT rowid,a,b,note FROM pair",
        "COUNT pair",
        "COUNT host",
        "INDEX intpk_label 'gamma'",
        "INDEX intpk_label 'delta'",
        (EX, "SELECT * FROM hostview"),
        (EX, "COUNT hostview"),
        (E, "INDEX hostview 'x'"),
        (E, "SELECT * FROM host_touch"),
    ]),
    ("015_alter_add_column", "alter", [
        ".schema item",
        "COUNT item",
        "SELECT * FROM item",
        "SELECT id,qty FROM item WHERE qty IS NULL",
        "SELECT id,qty,tag FROM item WHERE qty > 70 ORDER BY qty DESC",
        "SELECT id,tag FROM item WHERE tag = 'tag1'",
    ]),
    ("016_unicode", "unicode", [
        ".schema words",
        "SELECT * FROM words",
        "SELECT id,w FROM words ORDER BY w",
        "SELECT id,w FROM words ORDER BY w DESC LIMIT 5",
        "SELECT id FROM words WHERE w = '\u4f60\u597d'",
        "SELECT id,w,lang FROM words WHERE lang = 'fr' ORDER BY w",
        "INDEX words_w '\u00e9clair'",
        "INDEX words_lang 'emoji'",
        "INDEX words_w 'apple'",
        "INDEX words_w 'nothing here'",
    ]),
    ("017_index_lookup", "indexes", [
        ".tables",
        ".schema sqlite_sequence",
        ".schema seq",
        "COUNT emp",
        "COUNT seq",
        "INDEX emp_dept 'eng'",
        "INDEX emp_dept 'legal'",
        "INDEX emp_dept '\u00e9tudes'",
        "INDEX emp_dept NULL",
        "INDEX emp_manager 7",
        "INDEX emp_manager 39",
        "INDEX emp_manager 999",
        "INDEX emp_grade 2.5",
        (E, "INDEX emp_dept_salary 'eng'"),
        (E, "INDEX sqlite_autoindex_tag_1 'tag-001'"),
    ]),
    ("018_index_vs_scan", "indexes", [
        ".schema emp",
        "SELECT emp_id,dept,salary FROM emp WHERE dept = 'hr' ORDER BY salary DESC LIMIT 10",
        "SELECT emp_id FROM emp WHERE manager IS NULL LIMIT 20",
        "SELECT emp_id,grade FROM emp ORDER BY grade LIMIT 15",
        "SELECT emp_id,grade FROM emp ORDER BY grade DESC LIMIT 15",
        "SELECT emp_id,dept FROM emp WHERE dept IS NULL LIMIT 25",
        "SELECT name,weight FROM tag WHERE weight >= 150",
        "COUNT tag",
        "SELECT * FROM seq",
    ]),
    ("019_deep_index", "deep_index", [
        ".schema ping",
        "COUNT ping",
        # 'B' names 6400 of the 8000 entries, so the walk up the descent path
        # has to cover subtrees rooted at interior index pages, whose own
        # cells carry index entries.
        "INDEX ping_flag 'A'",
        "INDEX ping_flag 'B'",
        "INDEX ping_host 'h-000'",
        "INDEX ping_host 'h-249'",
        "INDEX ping_host 'h-999'",
        "SELECT id,flag FROM ping WHERE id > 7995",
        "SELECT id,host,ms FROM ping ORDER BY ms DESC LIMIT 10",
    ]),
    ("020_small_pages_scan", "small_pages", [
        ".schema reading",
        "COUNT reading",
        "SELECT * FROM reading LIMIT 5",
        "SELECT id,station,celsius FROM reading WHERE celsius > 44.9",
        "SELECT id,celsius FROM reading ORDER BY celsius LIMIT 10",
        "SELECT id,celsius FROM reading ORDER BY celsius DESC LIMIT 10",
        "SELECT id FROM reading WHERE id = 19999",
        "SELECT id,station FROM reading WHERE station = 'ST-0001' LIMIT 20",
    ]),
    ("021_small_pages_index", "small_pages", [
        "INDEX reading_station 'ST-0007'",
        "INDEX reading_station 'ST-0399'",
        "INDEX reading_station 'ST-9999'",
        "INDEX reading_quality 0",
        "SELECT id,quality FROM reading WHERE quality = 3 AND id < 200",
        "SELECT id,station,quality FROM reading WHERE station = 'ST-0123' ORDER BY quality",
    ]),
    ("022_big_pages", "big_pages", [
        ".tables",
        ".schema doc",
        "COUNT doc",
        "SELECT * FROM doc LIMIT 8",
        "SELECT id,words FROM doc WHERE words > 49900 ORDER BY words",
        "SELECT id,ratio FROM doc ORDER BY ratio LIMIT 6",
        "INDEX doc_words 25000",
        "SELECT id,title FROM doc WHERE id >= 5995",
    ]),
    ("023_overflow_blobs", "overflow", [
        ".schema blobs",
        "COUNT blobs",
        "SELECT id,n,label FROM blobs",
        "SELECT id,n,body FROM blobs WHERE n <= 200",
        "SELECT id,n FROM blobs WHERE n >= 1000 ORDER BY n DESC",
        "SELECT body FROM blobs WHERE id = 20",
        "INDEX blobs_n 8000",
    ]),
    ("024_overflow_boundary", "overflow", [
        "COUNT edge",
        "SELECT id FROM edge",
        "SELECT b FROM edge WHERE id = 472",
        "SELECT b FROM edge WHERE id = 473",
        "SELECT b FROM edge WHERE id = 474",
        "SELECT id,b FROM edge WHERE id >= 470 AND id <= 478",
        "COUNT ikey",
        "SELECT id,s FROM ikey WHERE id <= 92",
        "SELECT id FROM ikey ORDER BY s LIMIT 6",
        "INDEX ikey_s '" + IKEY(96) + "'",
        "INDEX ikey_s '" + IKEY(97) + "'",
        "INDEX ikey_s '" + IKEY(98) + "'",
        "INDEX ikey_s '" + IKEY(110) + "'",
    ]),
    ("025_overflow_text", "overflow", [
        "COUNT texts",
        "SELECT id FROM texts",
        "SELECT body FROM texts WHERE id = 1",
        "SELECT body FROM texts WHERE id = 3",
        "SELECT id,body FROM texts WHERE id = 5",
        "SELECT id FROM texts ORDER BY body",
    ]),
    ("026_overflow_index_keys", "long_keys", [
        ".schema k",
        "COUNT k",
        "SELECT id,payload FROM k WHERE id <= 3",
        "INDEX k_key 'key001-" + "z" * 700 + "'",
        "INDEX k_key 'key200-" + "z" * 700 + "'",
        "INDEX k_key 'missing'",
        "SELECT id FROM k ORDER BY key LIMIT 10",
    ]),
    ("027_freelist", "freelist", [
        ".schema ev",
        "COUNT ev",
        "SELECT * FROM ev LIMIT 6",
        "SELECT id,kind,amount FROM ev WHERE amount > 99000 ORDER BY amount DESC",
        "INDEX ev_kind 'kind-3'",
        "SELECT id FROM ev WHERE id > 29900",
        "SELECT id,amount FROM ev ORDER BY amount LIMIT 10",
    ]),
    ("028_chinook_schema", "chinook", [
        ".tables",
        ".schema Album",
        ".schema Track",
        ".schema Employee",
        ".schema PlaylistTrack",
        ".schema sqlite_sequence",
        "COUNT Album",
        "COUNT Artist",
        "COUNT Track",
        "COUNT InvoiceLine",
        "COUNT PlaylistTrack",
    ]),
    ("029_chinook_select", "chinook", [
        "SELECT * FROM Artist LIMIT 10",
        "SELECT AlbumId,Title FROM Album WHERE ArtistId = 90",
        "SELECT Name,Milliseconds,UnitPrice FROM Track WHERE Milliseconds > 3000000 ORDER BY Milliseconds DESC",
        "SELECT FirstName,LastName,Title FROM Employee ORDER BY LastName",
        "SELECT InvoiceId,Total FROM Invoice WHERE Total >= 15 ORDER BY Total DESC LIMIT 20",
        "SELECT CustomerId,Country,City FROM Customer WHERE Country = 'Brazil' ORDER BY City",
        "SELECT TrackId,Name FROM Track WHERE Composer IS NULL LIMIT 25",
        "SELECT Name FROM Genre ORDER BY Name",
        "SELECT * FROM MediaType",
    ]),
    ("030_chinook_index", "chinook", [
        "INDEX IFK_TrackAlbumId 89",
        "INDEX IFK_TrackGenreId 24",
        "INDEX IFK_AlbumArtistId 22",
        "INDEX IFK_InvoiceCustomerId 42",
        "INDEX IFK_PlaylistTrackPlaylistId 17",
        "INDEX IFK_EmployeeReportsTo 2",
        "INDEX IFK_TrackAlbumId NULL",
        "INDEX IFK_TrackAlbumId 100000",
        (E, "INDEX sqlite_autoindex_PlaylistTrack_1 1"),
    ]),
    ("031_chinook_wide", "chinook", [
        "SELECT * FROM Employee",
        "SELECT InvoiceLineId,InvoiceId,TrackId,UnitPrice,Quantity FROM InvoiceLine WHERE InvoiceId < 6",
        "SELECT * FROM Invoice WHERE BillingState IS NOT NULL AND Total > 13 ORDER BY Total DESC",
        "SELECT TrackId,Name,Bytes FROM Track WHERE Bytes > 300000000",
        "SELECT PlaylistId,Name FROM Playlist ORDER BY Name",
        "SELECT rowid,Name FROM Genre WHERE rowid > 20",
        "SELECT Title,AlbumId FROM Album ORDER BY Title LIMIT 30",
        "SELECT * FROM PlaylistTrack LIMIT 12",
        "SELECT rowid,PlaylistId,TrackId FROM PlaylistTrack WHERE PlaylistId = 5 LIMIT 10",
    ]),
    ("032_airports_scan", "airports", [
        ".tables",
        ".schema airport",
        ".schema runway",
        "COUNT airport",
        "COUNT runway",
        "SELECT * FROM airport LIMIT 5",
        "SELECT ident,name,elevation_ft FROM airport WHERE elevation_ft > 14000 ORDER BY elevation_ft DESC",
        "SELECT ident,name FROM airport WHERE type = 'large_airport' AND iso_country = 'JP' ORDER BY ident",
        "SELECT id,ident,municipality FROM airport WHERE municipality IS NULL LIMIT 20",
        "SELECT ident,latitude_deg,longitude_deg FROM airport ORDER BY latitude_deg LIMIT 15",
        "SELECT ident,latitude_deg FROM airport ORDER BY latitude_deg DESC LIMIT 15",
        "SELECT id,length_ft,surface FROM runway WHERE length_ft > 16000 ORDER BY length_ft DESC",
        "SELECT id,airport_ident,le_ident,he_ident FROM runway WHERE closed = 1 AND length_ft > 9000",
        "SELECT ident,name,iata_code FROM airport WHERE iata_code = 'LHR'",
        "SELECT ident,type,name FROM airport WHERE iso_country = 'IS' ORDER BY ident",
        "INDEX airport_ident 'KJFK'",
        "INDEX airport_ident 'EGLL'",
        "INDEX airport_ident 'ZZZZ'",
        "INDEX airport_country 'VA'",
        "INDEX airport_country 'AQ'",
        "INDEX airport_type 'balloonport'",
        "INDEX runway_ref 6523",
        "INDEX runway_ref 3622",
        (E, "SELECT count FROM airport LIMIT 1"),
    ]),
    ("033_us_airports_index", "us_airports", [
        ".tables",
        ".schema usap",
        "COUNT usap",
        "INDEX usap_region 'US-AK'",
        "INDEX usap_region 'US-DC'",
        "INDEX usap_region 'US-ZZ'",
        "INDEX usap_type 'large_airport'",
        "INDEX usap_type 'balloonport'",
        "INDEX usap_type NULL",
        (E, "INDEX usap_name 'x'"),
        (E, "INDEX usap 'x'"),
    ]),
    ("034_us_airports_bigpage", "us_airports", [
        "SELECT * FROM usap LIMIT 6",
        "SELECT id,ident,name,elevation_ft FROM usap WHERE elevation_ft > 11000 ORDER BY elevation_ft DESC",
        "SELECT ident,municipality FROM usap WHERE iso_region = 'US-HI' ORDER BY ident",
        "SELECT id,ident FROM usap ORDER BY ident LIMIT 20",
        "SELECT id,name FROM usap WHERE name > 'Zz' ORDER BY name",
        "SELECT id,ident,type FROM usap WHERE type = 'seaplane_base' AND elevation_ft > 4000",
        "SELECT id,elevation_ft FROM usap ORDER BY elevation_ft DESC LIMIT 12",
        "SELECT id,municipality FROM usap WHERE municipality IS NULL LIMIT 15",
        "SELECT rowid,ident FROM usap WHERE rowid < 6600",
    ]),
    ("035_mixed_edge_cases", "types", [
        ".tables",
        ".schema vals",
        "SELECT k,v FROM vals WHERE v IS NULL",
        "SELECT k,v FROM vals WHERE v = ''",
        "SELECT k,v FROM vals WHERE v = X''",
        "SELECT k,v FROM vals WHERE v = '007'",
        "SELECT k,v FROM vals WHERE v = 7",
        "SELECT k,v FROM vals WHERE v > X'00'",
        "SELECT k,v FROM vals WHERE v >= 'a'",
        "SELECT k,v FROM vals WHERE v = 0.1",
        "SELECT k,v FROM vals WHERE v = 1.0",
        "SELECT k,v FROM vals ORDER BY v DESC LIMIT 6",
        "SELECT rowid,k FROM vals LIMIT 4",
        "SELECT k,v FROM vals WHERE v >= 1e14 AND v <= 1e15",
        "SELECT k,v FROM vals WHERE v > 0 AND v < 0.001",
        "SELECT k,v FROM vals ORDER BY v LIMIT 8",
    ]),
]


# ---------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------


def check_db_invariants(db):
    """Enforce the guarantees SPEC.md makes about the test databases."""
    with open(db, "rb") as f:
        head = f.read(100)
    assert head[:16] == b"SQLite format 3\x00", db
    assert head[20] == 0, "%s: reserved space per page must be 0" % db
    assert int.from_bytes(head[52:56], "big") == 0, "%s: auto-vacuum must be off" % db
    assert int.from_bytes(head[56:60], "big") in (0, 1), "%s: must be UTF-8" % db

    con = sqlite3.connect(db)
    try:
        tables = [r[0] for r in con.execute(
            "SELECT name FROM sqlite_schema WHERE type='table'")]
        for t in tables:
            cols = [r[1] for r in con.execute('PRAGMA table_info(%s)' % ident(t))]
            for c in cols:
                expr = ident(c)
                # The oracle's TSV output would be ambiguous if a text value
                # held a tab or a newline.
                bad = con.execute(
                    'SELECT count(*) FROM %s WHERE typeof(%s)=\'text\' AND '
                    '(instr(%s, char(9)) OR instr(%s, char(10)) '
                    'OR instr(%s, char(13)))'
                    % (ident(t), expr, expr, expr, expr)).fetchone()[0]
                if bad:
                    raise SystemExit("%s.%s holds %d values with a tab or newline"
                                     % (t, c, bad))
                # Every REAL must round-trip through 15 significant digits, so
                # that rounding to 15 digits is never a tie.
                for (v,) in con.execute(
                        'SELECT DISTINCT %s FROM %s WHERE typeof(%s)=\'real\''
                        % (expr, ident(t), expr)):
                    if float("%.15g" % v) != v:
                        raise SystemExit("%s.%s holds %r, which does not "
                                         "round-trip through %%.15g" % (t, c, v))
    finally:
        con.close()


def run():
    only = os.environ.get("SQLITEFILE_ONLY")
    cases = [c for c in CASES if not only or any(c[0].startswith(x) for x in only.split(","))]
    needed = sorted({db for _n, db, _q in cases})
    built = {}
    for key in needed:
        sys.stderr.write("building %s ...\n" % key)
        built[key] = BUILDERS[key]()
        check_db_invariants(built[key])

    if os.path.isdir(TESTS):
        shutil.rmtree(TESTS)
    os.makedirs(TESTS)

    total_queries = 0
    for name, dbkey, queries in cases:
        case = os.path.join(TESTS, name)
        indir = os.path.join(case, "input")
        expdir = os.path.join(case, "expected")
        os.makedirs(indir)
        db_src = built[dbkey]
        db_dst = os.path.join(indir, os.path.basename(db_src))
        shutil.copyfile(db_src, db_dst)
        lines = [q[1] if isinstance(q, tuple) else q for q in queries]
        with open(os.path.join(indir, "queries.txt"), "w",
                  encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
        proc = subprocess.run([sys.executable, REFERENCE, indir, expdir],
                              capture_output=True, cwd=HERE)
        if proc.returncode != 0:
            raise SystemExit("reference failed on %s: %s"
                             % (name, proc.stderr.decode()))
        total_queries += len(lines)

        for i, q in enumerate(queries, 1):
            line = q[1] if isinstance(q, tuple) else q
            path = os.path.join(expdir, "%03d.txt" % i)
            with open(path, encoding="utf-8") as f:
                got = f.read()
            if isinstance(q, tuple) and q[0] in (E, EX):
                if normalize(got) != "error":
                    raise SystemExit("%s query %d (%r) should be an error, got %r"
                                     % (name, i, line, got[:120]))
                if q[0] == E and not oracle_rejects(db_dst, line):
                    raise SystemExit("%s query %d (%r) is rejected by the reference "
                                     "but accepted by sqlite3" % (name, i, line))
                continue
            want = oracle_output(db_dst, line)
            if want is None:
                raise SystemExit("%s query %d (%r) has no oracle translation"
                                 % (name, i, line))
            if normalize(got) != normalize(want):
                g, w = normalize(got), normalize(want)
                k = 0
                while k < min(len(g), len(w)) and g[k] == w[k]:
                    k += 1
                raise SystemExit(
                    "ORACLE MISMATCH %s query %d: %r\n  reference: %r\n  sqlite3:   %r"
                    % (name, i, line, g[max(0, k - 60):k + 120], w[max(0, k - 60):k + 120]))
        sys.stderr.write("ok %s (%d queries)\n" % (name, len(queries)))

    sys.stderr.write("%d cases, %d queries, all cross-checked against sqlite3\n"
                     % (len(cases), total_queries))
    size = sum(os.path.getsize(os.path.join(dp, f))
               for dp, _dn, fn in os.walk(TESTS) for f in fn)
    sys.stderr.write("tests/ is %.1f MB\n" % (size / 1e6))


def main():
    global WORK
    with tempfile.TemporaryDirectory(prefix="sqlitefile_gen_") as tmp:
        WORK = tmp
        run()


# tests/ is handed out without corpus/, so it carries the licences of its
# third-party data.
TEST_NOTICE = 'corpus/tests-notice.md'
TEST_LICENCES = [
    ('corpus/chinook/LICENSE.md', 'LICENSE-chinook.md'),
    ('corpus/ourairports/LICENSE.txt', 'LICENSE-ourairports.txt'),
]


def copy_licences():
    shutil.copyfile(os.path.join(HERE, TEST_NOTICE),
                    os.path.join(TESTS, 'THIRD_PARTY.md'))
    for src, name in TEST_LICENCES:
        shutil.copyfile(os.path.join(HERE, src), os.path.join(TESTS, name))


if __name__ == "__main__":
    main()
    copy_licences()
