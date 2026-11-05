#!/usr/bin/env python3
"""Reference implementation of the sqlitefile problem.

Reads a SQLite 3 database file byte by byte (no sqlite3 module) and answers
the queries listed in the input directory's queries.txt.
"""
import os
import struct
import sys

# ---------------------------------------------------------------------------
# value formatting
# ---------------------------------------------------------------------------


def format_real(x):
    """Render a REAL the way the sqlite3 shell's "%!.15g" conversion does."""
    if x == 0.0:
        return "0.0"
    s = "%.15g" % x
    if "e" in s:
        mant, exp = s.split("e")
        if "." not in mant:
            mant += ".0"
        return mant + "e" + exp
    if "." not in s:
        s += ".0"
    return s


def format_value(v):
    if v is None:
        return "NULL"
    if isinstance(v, bool):
        return "1" if v else "0"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return format_real(v)
    if isinstance(v, bytes):
        return v.hex().upper()
    return v


# ---------------------------------------------------------------------------
# SQLite value ordering
# ---------------------------------------------------------------------------


def class_rank(v):
    if v is None:
        return 0
    if isinstance(v, (int, float)):
        return 1
    if isinstance(v, str):
        return 2
    return 3


def sort_key(v):
    r = class_rank(v)
    if r == 0:
        return (0, 0)
    if r == 1:
        return (1, v)
    if r == 2:
        return (2, v.encode("utf-8"))
    return (3, v)


def compare(a, b):
    ka, kb = sort_key(a), sort_key(b)
    if ka[0] != kb[0]:
        return -1 if ka[0] < kb[0] else 1
    if ka[1] == kb[1]:
        return 0
    return -1 if ka[1] < kb[1] else 1


# ---------------------------------------------------------------------------
# varints and records
# ---------------------------------------------------------------------------


def read_varint(buf, pos):
    """Decode a SQLite variable length integer; return (signed value, next pos)."""
    val = 0
    for i in range(8):
        byte = buf[pos + i]
        if byte & 0x80:
            val = (val << 7) | (byte & 0x7F)
        else:
            val = (val << 7) | byte
            n = i + 1
            break
    else:
        val = (val << 8) | buf[pos + 8]
        n = 9
    if val >= 1 << 63:
        val -= 1 << 64
    return val, pos + n


SERIAL_SIZES = {0: 0, 1: 1, 2: 2, 3: 3, 4: 4, 5: 6, 6: 8, 7: 8, 8: 0, 9: 0}


def serial_size(t):
    if t < 12:
        return SERIAL_SIZES.get(t, 0)
    return (t - 12) // 2


def decode_int(data):
    v = int.from_bytes(data, "big")
    bits = len(data) * 8
    if v >= 1 << (bits - 1):
        v -= 1 << bits
    return v


def parse_record(payload):
    """Split a record payload into a list of values."""
    hdr_size, pos = read_varint(payload, 0)
    types = []
    while pos < hdr_size:
        t, pos = read_varint(payload, pos)
        types.append(t)
    values = []
    body = hdr_size
    for t in types:
        n = serial_size(t)
        chunk = payload[body:body + n]
        body += n
        if t == 0:
            values.append(None)
        elif 1 <= t <= 6:
            values.append(decode_int(chunk))
        elif t == 7:
            values.append(struct.unpack(">d", chunk)[0])
        elif t == 8:
            values.append(0)
        elif t == 9:
            values.append(1)
        elif t >= 12 and t % 2 == 0:
            values.append(bytes(chunk))
        elif t >= 13:
            values.append(chunk.decode("utf-8", "replace"))
        else:
            values.append(None)
    return values


# ---------------------------------------------------------------------------
# pager and B-tree traversal
# ---------------------------------------------------------------------------


class Database:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.data = f.read()
        hdr = self.data[:100]
        if hdr[:16] != b"SQLite format 3\x00":
            raise ValueError("not a SQLite database")
        ps = struct.unpack(">H", hdr[16:18])[0]
        self.page_size = 65536 if ps == 1 else ps
        self.reserved = hdr[20]
        self.usable = self.page_size - self.reserved
        self.encoding = struct.unpack(">I", hdr[56:60])[0] or 1

    def page(self, n):
        off = (n - 1) * self.page_size
        return self.data[off:off + self.page_size]

    # -- payload assembly ---------------------------------------------------

    def payload(self, page, start, total, index_page):
        """Read `total` payload bytes starting at `start` in `page`, following
        the overflow chain when the payload does not fit on one page."""
        u = self.usable
        if index_page:
            x = ((u - 12) * 64 // 255) - 23
        else:
            x = u - 35
        if total <= x:
            return page[start:start + total]
        m = ((u - 12) * 32 // 255) - 23
        k = m + ((total - m) % (u - 4))
        local = k if k <= x else m
        out = bytearray(page[start:start + local])
        nxt = struct.unpack(">I", page[start + local:start + local + 4])[0]
        remaining = total - local
        while remaining > 0 and nxt:
            ov = self.page(nxt)
            nxt = struct.unpack(">I", ov[0:4])[0]
            take = min(remaining, u - 4)
            out += ov[4:4 + take]
            remaining -= take
        return bytes(out)

    # -- table B-tree -------------------------------------------------------

    def table_rows(self, root):
        """Yield (rowid, values) for every row of a table B-tree, rowid ascending."""
        stack = [root]
        while stack:
            pgno = stack.pop()
            page = self.page(pgno)
            base = 100 if pgno == 1 else 0
            ptype = page[base]
            ncells = struct.unpack(">H", page[base + 3:base + 5])[0]
            if ptype == 0x0D:
                ptr = base + 8
                for i in range(ncells):
                    off = struct.unpack(">H", page[ptr + 2 * i:ptr + 2 * i + 2])[0]
                    total, p = read_varint(page, off)
                    rowid, p = read_varint(page, p)
                    yield rowid, parse_record(self.payload(page, p, total, False))
            elif ptype == 0x05:
                ptr = base + 12
                children = []
                for i in range(ncells):
                    off = struct.unpack(">H", page[ptr + 2 * i:ptr + 2 * i + 2])[0]
                    children.append(struct.unpack(">I", page[off:off + 4])[0])
                children.append(struct.unpack(">I", page[base + 8:base + 12])[0])
                stack.extend(reversed(children))
            else:
                raise ValueError("page %d is not a table B-tree page" % pgno)

    def table_row_count(self, root):
        n = 0
        stack = [root]
        while stack:
            pgno = stack.pop()
            page = self.page(pgno)
            base = 100 if pgno == 1 else 0
            ptype = page[base]
            ncells = struct.unpack(">H", page[base + 3:base + 5])[0]
            if ptype == 0x0D:
                n += ncells
            elif ptype == 0x05:
                ptr = base + 12
                for i in range(ncells):
                    off = struct.unpack(">H", page[ptr + 2 * i:ptr + 2 * i + 2])[0]
                    stack.append(struct.unpack(">I", page[off:off + 4])[0])
                stack.append(struct.unpack(">I", page[base + 8:base + 12])[0])
            else:
                raise ValueError("page %d is not a table B-tree page" % pgno)
        return n

    def find_row(self, root, rowid):
        """Descend a table B-tree to one rowid; return its values or None."""
        pgno = root
        while True:
            page = self.page(pgno)
            base = 100 if pgno == 1 else 0
            ptype = page[base]
            ncells = struct.unpack(">H", page[base + 3:base + 5])[0]
            if ptype == 0x0D:
                ptr = base + 8
                lo, hi = 0, ncells - 1
                while lo <= hi:
                    mid = (lo + hi) // 2
                    off = struct.unpack(">H", page[ptr + 2 * mid:ptr + 2 * mid + 2])[0]
                    total, p = read_varint(page, off)
                    key, p = read_varint(page, p)
                    if key == rowid:
                        return parse_record(self.payload(page, p, total, False))
                    if key < rowid:
                        lo = mid + 1
                    else:
                        hi = mid - 1
                return None
            if ptype != 0x05:
                raise ValueError("page %d is not a table B-tree page" % pgno)
            ptr = base + 12
            child = struct.unpack(">I", page[base + 8:base + 12])[0]
            lo, hi = 0, ncells - 1
            while lo <= hi:
                mid = (lo + hi) // 2
                off = struct.unpack(">H", page[ptr + 2 * mid:ptr + 2 * mid + 2])[0]
                left = struct.unpack(">I", page[off:off + 4])[0]
                key, _ = read_varint(page, off + 4)
                if rowid <= key:
                    child = left
                    hi = mid - 1
                else:
                    lo = mid + 1
            pgno = child

    # -- index B-tree -------------------------------------------------------

    def index_cell(self, page, base, ptype, i):
        """Return (record values, left child page) for cell i of an index page."""
        ptr = base + (12 if ptype == 0x02 else 8)
        off = struct.unpack(">H", page[ptr + 2 * i:ptr + 2 * i + 2])[0]
        left = 0
        if ptype == 0x02:
            left = struct.unpack(">I", page[off:off + 4])[0]
            off += 4
        total, p = read_varint(page, off)
        return parse_record(self.payload(page, p, total, True)), left

    def index_lookup(self, root, key):
        """Return the rowids of every index entry whose first key column equals
        `key`, in ascending rowid order.  Descends to the leftmost match, then
        walks forward in key order."""
        if key is None:
            return []
        path = []  # (pgno, cell index just past the descent point)
        pgno = root
        while True:
            page = self.page(pgno)
            base = 100 if pgno == 1 else 0
            ptype = page[base]
            ncells = struct.unpack(">H", page[base + 3:base + 5])[0]
            if ptype == 0x0A:
                lo, hi = 0, ncells - 1
                while lo <= hi:
                    mid = (lo + hi) // 2
                    rec, _ = self.index_cell(page, base, ptype, mid)
                    if compare(rec[0], key) < 0:
                        lo = mid + 1
                    else:
                        hi = mid - 1
                path.append((pgno, lo))
                break
            if ptype != 0x02:
                raise ValueError("page %d is not an index B-tree page" % pgno)
            lo, hi = 0, ncells - 1
            while lo <= hi:
                mid = (lo + hi) // 2
                rec, _ = self.index_cell(page, base, ptype, mid)
                if compare(rec[0], key) < 0:
                    lo = mid + 1
                else:
                    hi = mid - 1
            if lo == ncells:
                child = struct.unpack(">I", page[base + 8:base + 12])[0]
            else:
                _, child = self.index_cell(page, base, ptype, lo)
            path.append((pgno, lo))
            pgno = child

        rowids = []
        stop = [False]

        def visit_subtree(p):
            """Walk an entire subtree in key order, collecting matches."""
            if stop[0]:
                return
            page = self.page(p)
            base = 100 if p == 1 else 0
            ptype = page[base]
            ncells = struct.unpack(">H", page[base + 3:base + 5])[0]
            if ptype == 0x0A:
                for i in range(ncells):
                    rec, _ = self.index_cell(page, base, ptype, i)
                    if compare(rec[0], key) != 0:
                        stop[0] = True
                        return
                    rowids.append(rec[-1])
                return
            for i in range(ncells):
                rec, left = self.index_cell(page, base, ptype, i)
                visit_subtree(left)
                if stop[0]:
                    return
                if compare(rec[0], key) != 0:
                    stop[0] = True
                    return
                rowids.append(rec[-1])
            visit_subtree(struct.unpack(">I", page[base + 8:base + 12])[0])

        # Resume the in-order walk from the descent point upwards.
        leaf_pgno, leaf_idx = path[-1]
        page = self.page(leaf_pgno)
        base = 100 if leaf_pgno == 1 else 0
        ncells = struct.unpack(">H", page[base + 3:base + 5])[0]
        for i in range(leaf_idx, ncells):
            rec, _ = self.index_cell(page, base, 0x0A, i)
            if compare(rec[0], key) != 0:
                stop[0] = True
                break
            rowids.append(rec[-1])
        for pg, idx in reversed(path[:-1]):
            if stop[0]:
                break
            page = self.page(pg)
            base = 100 if pg == 1 else 0
            ncells = struct.unpack(">H", page[base + 3:base + 5])[0]
            for i in range(idx, ncells):
                rec, left = self.index_cell(page, base, 0x02, i)
                if compare(rec[0], key) != 0:
                    stop[0] = True
                    break
                rowids.append(rec[-1])
                nxt = self.index_cell(page, base, 0x02, i + 1)[1] if i + 1 < ncells \
                    else struct.unpack(">I", page[base + 8:base + 12])[0]
                visit_subtree(nxt)
                if stop[0]:
                    break
        rowids.sort()
        return rowids


# ---------------------------------------------------------------------------
# DDL parsing
# ---------------------------------------------------------------------------

QUOTE_PAIRS = {'"': '"', "[": "]", "`": "`", "'": "'"}


def ddl_tokens(sql):
    """Split DDL into tokens: identifiers/keywords, quoted names, punctuation."""
    toks = []
    i, n = 0, len(sql)
    while i < n:
        c = sql[i]
        if c.isspace():
            i += 1
            continue
        if c == "-" and i + 1 < n and sql[i + 1] == "-":
            while i < n and sql[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and sql[i + 1] == "*":
            j = sql.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if c in QUOTE_PAIRS:
            close = QUOTE_PAIRS[c]
            j = i + 1
            buf = []
            while j < n:
                if sql[j] == close:
                    if j + 1 < n and sql[j + 1] == close and c != "[":
                        buf.append(close)
                        j += 2
                        continue
                    break
                buf.append(sql[j])
                j += 1
            toks.append(("name", "".join(buf)))
            i = j + 1
            continue
        if c.isalnum() or c == "_" or c == "$":
            j = i
            while j < n and (sql[j].isalnum() or sql[j] in "_$"):
                j += 1
            toks.append(("word", sql[i:j]))
            i = j
            continue
        toks.append(("punct", c))
        i += 1
    return toks


def split_top_level(toks):
    """Split a token list on top-level commas."""
    items, cur, depth = [], [], 0
    for t in toks:
        if t[0] == "punct":
            if t[1] == "(":
                depth += 1
            elif t[1] == ")":
                depth -= 1
            elif t[1] == "," and depth == 0:
                items.append(cur)
                cur = []
                continue
        cur.append(t)
    if cur:
        items.append(cur)
    return items


TABLE_CONSTRAINT_STARTS = {"CONSTRAINT", "PRIMARY", "UNIQUE", "CHECK", "FOREIGN"}


class TableDef:
    def __init__(self, name, columns, types, ipk):
        self.name = name
        self.columns = columns
        self.types = types
        self.ipk = ipk  # index of the INTEGER PRIMARY KEY column, or -1
        self.affinities = []


def parse_create_table(sql):
    toks = ddl_tokens(sql)
    # CREATE [TEMP] TABLE [IF NOT EXISTS] [schema .] name ( ... )
    i = 0
    while i < len(toks) and not (toks[i][0] == "word" and toks[i][1].upper() == "TABLE"):
        i += 1
    i += 1
    if i < len(toks) + 2 and [t[1].upper() for t in toks[i:i + 3] if t[0] == "word"][:3] == ["IF", "NOT", "EXISTS"]:
        i += 3
    name = toks[i][1]
    i += 1
    if i < len(toks) and toks[i] == ("punct", "."):
        name = toks[i + 1][1]
        i += 2
    while i < len(toks) and toks[i] != ("punct", "("):
        i += 1
    depth = 0
    j = i
    while j < len(toks):
        if toks[j] == ("punct", "("):
            depth += 1
        elif toks[j] == ("punct", ")"):
            depth -= 1
            if depth == 0:
                break
        j += 1
    body = toks[i + 1:j]

    columns, types = [], []
    col_pk = []      # per-column: 0 none, 1 PRIMARY KEY ascending, 2 PK with DESC
    table_pk = None  # column name of a single-column table-level PRIMARY KEY
    for item in split_top_level(body):
        if not item:
            continue
        head = item[0]
        if head[0] == "word" and head[1].upper() in TABLE_CONSTRAINT_STARTS:
            words = [t[1].upper() for t in item if t[0] == "word"]
            if head[1].upper() == "CONSTRAINT":
                rest = item[2:] if len(item) > 1 else []
            else:
                rest = item
            rw = [t for t in rest if not (t[0] == "word" and t[1].upper() == "CONSTRAINT")]
            if len(rw) >= 2 and rw[0][0] == "word" and rw[0][1].upper() == "PRIMARY" \
                    and rw[1][0] == "word" and rw[1][1].upper() == "KEY":
                inner = rw[2:]
                if inner and inner[0] == ("punct", "("):
                    # collect up to the matching close paren
                    d, k = 0, 0
                    while k < len(inner):
                        if inner[k] == ("punct", "("):
                            d += 1
                        elif inner[k] == ("punct", ")"):
                            d -= 1
                            if d == 0:
                                break
                        k += 1
                    cols = split_top_level(inner[1:k])
                    if len(cols) == 1 and cols[0]:
                        # A table-level PRIMARY KEY(col DESC) still aliases the
                        # rowid; only a column-level PRIMARY KEY DESC does not.
                        table_pk = cols[0][0][1]
            del words
            continue
        cname = head[1]
        rest = item[1:]
        # The declared type is the run of words before the first constraint
        # keyword, including any parenthesised size.
        tparts = []
        k = 0
        while k < len(rest):
            t = rest[k]
            if t[0] == "word" and t[1].upper() in COLUMN_CONSTRAINT_STARTS:
                break
            if t == ("punct", "("):
                d = 0
                seg = []
                while k < len(rest):
                    seg.append(rest[k])
                    if rest[k] == ("punct", "("):
                        d += 1
                    elif rest[k] == ("punct", ")"):
                        d -= 1
                        if d == 0:
                            break
                    k += 1
                tparts.append("(" + ",".join(x[1] for x in seg[1:-1]) + ")")
                k += 1
                continue
            if t[0] in ("word", "name"):
                tparts.append(t[1])
            k += 1
        decl = " ".join(tparts)
        cons = rest[k:]
        pk = 0
        for c in range(len(cons) - 1):
            if cons[c][0] == "word" and cons[c][1].upper() == "PRIMARY" \
                    and cons[c + 1][0] == "word" and cons[c + 1][1].upper() == "KEY":
                pk = 1
                for t in cons[c + 2:]:
                    if t[0] == "word" and t[1].upper() == "DESC":
                        pk = 2
                    if t[0] == "word" and t[1].upper() in ("NOT", "UNIQUE", "CHECK", "DEFAULT",
                                                           "COLLATE", "REFERENCES", "GENERATED", "AS"):
                        break
                break
        columns.append(cname)
        types.append(decl)
        col_pk.append(pk)

    ipk = -1
    for idx, pk in enumerate(col_pk):
        if pk == 1 and types[idx].strip().upper() == "INTEGER":
            ipk = idx
    if ipk < 0 and table_pk:
        for idx, cname in enumerate(columns):
            if cname.lower() == table_pk.lower() and types[idx].strip().upper() == "INTEGER":
                ipk = idx
    return TableDef(name, columns, types, ipk)


COLUMN_CONSTRAINT_STARTS = {
    "CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT",
    "COLLATE", "REFERENCES", "GENERATED", "AS", "AUTOINCREMENT",
}


def parse_create_index(sql):
    """Return (index name, table name, [column names])."""
    toks = ddl_tokens(sql)
    i = 0
    while i < len(toks) and not (toks[i][0] == "word" and toks[i][1].upper() == "INDEX"):
        i += 1
    i += 1
    if [t[1].upper() for t in toks[i:i + 3] if t[0] == "word"][:3] == ["IF", "NOT", "EXISTS"]:
        i += 3
    iname = toks[i][1]
    i += 1
    if i < len(toks) and toks[i] == ("punct", "."):
        iname = toks[i + 1][1]
        i += 2
    while i < len(toks) and not (toks[i][0] == "word" and toks[i][1].upper() == "ON"):
        i += 1
    i += 1
    tname = toks[i][1]
    i += 1
    while i < len(toks) and toks[i] != ("punct", "("):
        i += 1
    d, j = 0, i
    while j < len(toks):
        if toks[j] == ("punct", "("):
            d += 1
        elif toks[j] == ("punct", ")"):
            d -= 1
            if d == 0:
                break
        j += 1
    cols = []
    for item in split_top_level(toks[i + 1:j]):
        if item:
            cols.append(item[0][1])
    return iname, tname, cols


def affinity(decl):
    d = decl.upper()
    if "INT" in d:
        return "INTEGER"
    if "CHAR" in d or "CLOB" in d or "TEXT" in d:
        return "TEXT"
    if "BLOB" in d or d.strip() == "":
        return "BLOB"
    if "REAL" in d or "FLOA" in d or "DOUB" in d:
        return "REAL"
    return "NUMERIC"


# ---------------------------------------------------------------------------
# schema
# ---------------------------------------------------------------------------


class Schema:
    def __init__(self, db):
        self.db = db
        self.entries = []  # (type, name, tbl_name, rootpage, sql)
        for _rowid, rec in db.table_rows(1):
            rec = (rec + [None] * 5)[:5]
            self.entries.append(tuple(rec))
        self.tables = {}
        self.roots = {}
        self.indexes = {}
        for typ, name, tbl, root, sql in self.entries:
            if typ == "table" and sql:
                td = parse_create_table(sql)
                td.name = name
                td.affinities = [affinity(t) for t in td.types]
                self.tables[name.lower()] = td
                self.roots[name.lower()] = root
            elif typ == "index" and sql:
                iname, tname, cols = parse_create_index(sql)
                self.indexes[name.lower()] = (name, tname, cols, root)

    def table(self, name):
        return self.tables.get(name.lower())

    def root(self, name):
        return self.roots.get(name.lower())


# ---------------------------------------------------------------------------
# query parsing
# ---------------------------------------------------------------------------


class QueryError(Exception):
    pass


def is_digit(c):
    return "0" <= c <= "9"


def is_word_char(c):
    return is_digit(c) or "a" <= c <= "z" or "A" <= c <= "Z" or c == "_"


def is_identifier(s):
    """True for a bare identifier: [A-Za-z_][A-Za-z0-9_]*."""
    if not s:
        return False
    if is_digit(s[0]) or not is_word_char(s[0]):
        return False
    return all(is_word_char(c) for c in s[1:])


class Lexer:
    def __init__(self, text):
        self.s = text
        self.i = 0

    def skip(self):
        while self.i < len(self.s) and self.s[self.i] in " \t":
            self.i += 1

    def eof(self):
        self.skip()
        return self.i >= len(self.s)

    def peek_word(self):
        self.skip()
        j = self.i
        while j < len(self.s) and is_word_char(self.s[j]):
            j += 1
        return self.s[self.i:j]

    def take_word(self):
        w = self.peek_word()
        if not w:
            raise QueryError("expected a name")
        self.i += len(w)
        return w

    def expect_kw(self, kw):
        self.skip()
        w = self.peek_word()
        if w.upper() != kw:
            raise QueryError("expected %s" % kw)
        self.i += len(w)

    def at_kw(self, kw):
        return self.peek_word().upper() == kw

    def take_char(self, ch):
        self.skip()
        if self.i < len(self.s) and self.s[self.i] == ch:
            self.i += 1
            return True
        return False

    def take_operator(self):
        self.skip()
        for op in ("<=", ">=", "!=", "=", "<", ">"):
            if self.s.startswith(op, self.i):
                self.i += len(op)
                return op
        w = self.peek_word().upper()
        if w == "IS":
            self.i += 2
            save = self.i
            self.skip()
            if self.peek_word().upper() == "NOT":
                self.i += 3
                return "IS NOT"
            self.i = save
            return "IS"
        raise QueryError("expected an operator")

    def take_literal(self):
        self.skip()
        if self.i >= len(self.s):
            raise QueryError("expected a literal")
        c = self.s[self.i]
        if c == "'":
            j = self.i + 1
            buf = []
            while True:
                if j >= len(self.s):
                    raise QueryError("unterminated string")
                if self.s[j] == "'":
                    if j + 1 < len(self.s) and self.s[j + 1] == "'":
                        buf.append("'")
                        j += 2
                        continue
                    break
                buf.append(self.s[j])
                j += 1
            self.i = j + 1
            return "".join(buf)
        if c in "Xx" and self.i + 1 < len(self.s) and self.s[self.i + 1] == "'":
            j = self.s.find("'", self.i + 2)
            if j < 0:
                raise QueryError("unterminated blob")
            hexs = self.s[self.i + 2:j]
            if len(hexs) % 2 or any(ch not in "0123456789abcdefABCDEF" for ch in hexs):
                raise QueryError("bad blob literal")
            self.i = j + 1
            return bytes.fromhex(hexs)
        if c.isalpha():
            w = self.take_word()
            if w.upper() == "NULL":
                return None
            raise QueryError("bad literal %r" % w)
        j = self.i
        if self.s[j] in "+-":
            j += 1
        start = j
        while j < len(self.s) and is_digit(self.s[j]):
            j += 1
        if j == start:
            raise QueryError("expected a literal")
        isreal = False
        if j < len(self.s) and self.s[j] == ".":
            isreal = True
            j += 1
            while j < len(self.s) and is_digit(self.s[j]):
                j += 1
        if j < len(self.s) and self.s[j] in "eE":
            k = j + 1
            if k < len(self.s) and self.s[k] in "+-":
                k += 1
            if k < len(self.s) and is_digit(self.s[k]):
                isreal = True
                while k < len(self.s) and is_digit(self.s[k]):
                    k += 1
                j = k
        text = self.s[self.i:j]
        self.i = j
        return float(text) if isreal else int(text)


def parse_query(line):
    """Return a dict describing the query, or raise QueryError."""
    if line.startswith("."):
        parts = line.split()
        if parts[0] == ".tables":
            if len(parts) != 1:
                raise QueryError("bad .tables")
            return {"kind": "tables"}
        if parts[0] == ".schema":
            if len(parts) != 2 or not is_identifier(parts[1]):
                raise QueryError("bad .schema")
            return {"kind": "schema", "table": parts[1]}
        raise QueryError("unknown dot command")
    lx = Lexer(line)
    head = lx.peek_word().upper()
    if head == "COUNT":
        lx.take_word()
        t = lx.take_word()
        if not lx.eof():
            raise QueryError("trailing text")
        return {"kind": "count", "table": t}
    if head == "INDEX":
        lx.take_word()
        name = lx.take_word()
        val = lx.take_literal()
        if not lx.eof():
            raise QueryError("trailing text")
        return {"kind": "index", "index": name, "value": val}
    if head != "SELECT":
        raise QueryError("unknown command")
    lx.take_word()
    lx.skip()
    if lx.take_char("*"):
        cols = None
    else:
        cols = [lx.take_word()]
        while lx.take_char(","):
            cols.append(lx.take_word())
    lx.expect_kw("FROM")
    table = lx.take_word()
    where = []
    if not lx.eof() and lx.at_kw("WHERE"):
        lx.take_word()
        while True:
            col = lx.take_word()
            op = lx.take_operator()
            val = lx.take_literal()
            where.append((col, op, val))
            if lx.eof() or not lx.at_kw("AND"):
                break
            lx.take_word()
    order = None
    if not lx.eof() and lx.at_kw("ORDER"):
        lx.take_word()
        lx.expect_kw("BY")
        ocol = lx.take_word()
        desc = False
        if not lx.eof() and lx.at_kw("DESC"):
            lx.take_word()
            desc = True
        elif not lx.eof() and lx.at_kw("ASC"):
            lx.take_word()
        order = (ocol, desc)
    limit = None
    if not lx.eof() and lx.at_kw("LIMIT"):
        lx.take_word()
        lx.skip()
        j = lx.i
        while j < len(lx.s) and is_digit(lx.s[j]):
            j += 1
        if j == lx.i:
            raise QueryError("bad LIMIT")
        limit = int(lx.s[lx.i:j])
        lx.i = j
    if not lx.eof():
        raise QueryError("trailing text")
    return {"kind": "select", "cols": cols, "table": table,
            "where": where, "order": order, "limit": limit}


# ---------------------------------------------------------------------------
# execution
# ---------------------------------------------------------------------------


def looks_numeric(s):
    """Parse a TEXT value as a numeric constant, or return None.

    Leading and trailing spaces and tabs are ignored and the digits may start
    after the decimal point, so ".5" is numeric here even though it is not a
    legal query numeral.
    """
    t = s.strip(" \t")
    if not t:
        return None
    i = 0
    if t[i] in "+-":
        i += 1
    digits = 0
    start = i
    while i < len(t) and is_digit(t[i]):
        i += 1
    digits += i - start
    isreal = False
    if i < len(t) and t[i] == ".":
        isreal = True
        i += 1
        start = i
        while i < len(t) and is_digit(t[i]):
            i += 1
        digits += i - start
    if digits == 0:
        return None
    if i < len(t) and t[i] in "eE":
        j = i + 1
        if j < len(t) and t[j] in "+-":
            j += 1
        k = j
        while k < len(t) and is_digit(t[k]):
            k += 1
        if k > j:
            isreal = True
            i = k
    if i != len(t):
        return None
    if isreal:
        return float(t)
    v = int(t)
    if -(1 << 63) <= v < (1 << 63):
        return v
    return float(t)


def apply_affinity(value, aff):
    if value is None or isinstance(value, bytes):
        return value
    if aff == "TEXT":
        if isinstance(value, (int, float)):
            return format_value(value)
        return value
    if aff in ("INTEGER", "REAL", "NUMERIC"):
        if isinstance(value, str):
            n = looks_numeric(value)
            return value if n is None else n
        return value
    return value


def column_index(td, name):
    low = name.lower()
    for i, c in enumerate(td.columns):
        if c.lower() == low:
            return i
    if low == "rowid":
        return -1
    raise QueryError("no such column: %s" % name)


def column_affinity(td, idx):
    return "INTEGER" if idx < 0 else affinity(td.types[idx])


def test_condition(value, op, key):
    if op == "IS":
        return compare(value, key) == 0
    if op == "IS NOT":
        return compare(value, key) != 0
    if value is None or key is None:
        return False
    c = compare(value, key)
    return {"=": c == 0, "!=": c != 0, "<": c < 0,
            "<=": c <= 0, ">": c > 0, ">=": c >= 0}[op]


class Engine:
    def __init__(self, db):
        self.db = db
        self.schema = Schema(db)

    def row_values(self, td, rowid, rec):
        vals = list(rec) + [None] * (len(td.columns) - len(rec))
        vals = vals[:len(td.columns)]
        # A REAL-affinity column may hold an integer on disk: SQLite writes a
        # float with no fractional part as an integer and widens it on read.
        for i, aff in enumerate(td.affinities):
            if aff == "REAL" and type(vals[i]) is int:
                vals[i] = float(vals[i])
        if td.ipk >= 0:
            vals[td.ipk] = rowid
        return vals

    def run(self, q):
        kind = q["kind"]
        if kind == "tables":
            names = sorted((n for t, n, _tb, _r, _s in self.schema.entries
                            if t == "table" and not n.lower().startswith("sqlite_")),
                           key=lambda s: s.encode("utf-8"))
            return list(names)
        if kind == "schema":
            want = q["table"].lower()
            out = []
            for typ, _n, tbl, _r, sql in self.schema.entries:
                if tbl and tbl.lower() == want and sql:
                    out.extend((sql + ";").split("\n"))
            return out
        if kind == "count":
            td = self.schema.table(q["table"])
            if td is None:
                raise QueryError("no such table")
            return [str(self.db.table_row_count(self.schema.root(td.name)))]
        if kind == "index":
            ent = self.schema.indexes.get(q["index"].lower())
            if ent is None:
                raise QueryError("no such index")
            _name, tname, icols, iroot = ent
            td = self.schema.table(tname)
            if td is None or len(icols) != 1:
                raise QueryError("unusable index")
            ci = column_index(td, icols[0])
            key = apply_affinity(q["value"], column_affinity(td, ci))
            rowids = self.db.index_lookup(iroot, key)
            root = self.schema.root(td.name)
            lines = []
            for rid in rowids:
                rec = self.db.find_row(root, rid)
                if rec is None:
                    continue
                vals = self.row_values(td, rid, rec)
                lines.append("\t".join(format_value(v) for v in vals))
            return lines
        return self.run_select(q)

    def run_select(self, q):
        td = self.schema.table(q["table"])
        if td is None:
            raise QueryError("no such table")
        out_idx = ([column_index(td, c) for c in q["cols"]]
                   if q["cols"] is not None else list(range(len(td.columns))))
        conds = []
        for col, op, val in q["where"]:
            ci = column_index(td, col)
            conds.append((ci, op, apply_affinity(val, column_affinity(td, ci))))
        order = None
        if q["order"]:
            order = (column_index(td, q["order"][0]), q["order"][1])
        limit = q["limit"]
        root = self.schema.root(td.name)

        rows = []
        for rowid, rec in self.db.table_rows(root):
            vals = self.row_values(td, rowid, rec)
            ok = True
            for ci, op, key in conds:
                v = rowid if ci < 0 else vals[ci]
                if not test_condition(v, op, key):
                    ok = False
                    break
            if not ok:
                continue
            if order is None and limit is not None:
                rows.append((rowid, vals))
                if len(rows) >= limit:
                    break
            else:
                rows.append((rowid, vals))
        if order is not None:
            oi, desc = order
            if desc:
                rows.sort(key=lambda r: r[0])
                rows.sort(key=lambda r: sort_key(r[0] if oi < 0 else r[1][oi]), reverse=True)
            else:
                rows.sort(key=lambda r: (sort_key(r[0] if oi < 0 else r[1][oi]), r[0]))
        if limit is not None:
            rows = rows[:limit]
        lines = []
        for rowid, vals in rows:
            lines.append("\t".join(format_value(rowid if i < 0 else vals[i])
                                   for i in out_idx))
        return lines


# ---------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: main.py <input dir> <output dir>\n")
        return 2
    in_dir, out_dir = sys.argv[1], sys.argv[2]
    dbs = sorted(f for f in os.listdir(in_dir) if f.endswith(".sqlite"))
    db = Database(os.path.join(in_dir, dbs[0]))
    with open(os.path.join(in_dir, "queries.txt"), encoding="utf-8") as f:
        lines = f.read().split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    engine = Engine(db)
    os.makedirs(out_dir, exist_ok=True)
    for n, line in enumerate(lines, 1):
        try:
            result = engine.run(parse_query(line))
        except QueryError:
            result = ["error"]
        except (IndexError, ValueError, KeyError, struct.error):
            result = ["error"]
        path = os.path.join(out_dir, "%03d.txt" % n)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            for row in result:
                f.write(row + "\n")
    return 0


if __name__ == "__main__":
    sys.setrecursionlimit(10000)
    sys.exit(main())
