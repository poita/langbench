#!/usr/bin/env python3
"""Generate the textbuffer performance benchmark inputs deterministically.

Writes bench/NNN_name.in (same layout as tests/) and bench/NNN_name.out via
reference/main.py. Commands are chosen against a live reference Buffer so the
generator can keep every input within the SPEC limits: at most 10,000 initial
lines of at most 200,000 characters, at most 100,000 commands, at most 2,000
cursors, a document of at most 1,000,000 characters, inputs under 2 MB and
print output of at most about 3 MB.
"""
import os
import random
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(PROBLEM, "reference"))
sys.path.insert(0, PROBLEM)

import main as ref  # noqa: E402
from gen_tests import check_limits, encode_text  # noqa: E402

REF = os.path.join(PROBLEM, "reference", "main.py")
MAX_COMMANDS = 100000
MAX_CURSORS = 2000
MAX_DOC = 1000000
DOC_SOFT_CAP = 900000
MAX_INPUT = 2000000
MAX_OUTPUT = 3200000

IDENTS = ["value", "count", "index", "buffer", "result", "node", "items", "config", "error",
          "offset", "length", "parser", "token", "state", "cache", "handle", "request", "data",
          "line", "cursor", "self", "next", "prev", "key", "map", "list", "size", "width"]
KEYWORDS = ["if", "for", "while", "return", "let", "const", "fn", "def", "else", "match", "struct"]
PUNCT = ["(", ")", "{", "}", "[", "]", ";", ",", ".", " = ", " + ", " - ", " * ", " == ", " < ",
         " && ", "->", "::", ": "]


def code_line(rng, indent_level, width=90):
    """A code-like line: indentation followed by identifiers, keywords and punctuation."""
    parts = ["    " * indent_level]
    target = rng.randint(10, width)
    n = len(parts[0])
    while n < target:
        r = rng.random()
        if r < 0.45:
            tok = rng.choice(IDENTS)
        elif r < 0.6:
            tok = rng.choice(KEYWORDS) + " "
        elif r < 0.7:
            tok = str(rng.randint(0, 99999))
        elif r < 0.75:
            tok = '"' + rng.choice(IDENTS) + " " + rng.choice(IDENTS) + '"'
        else:
            tok = rng.choice(PUNCT)
        parts.append(tok)
        n += len(tok)
    return "".join(parts)


def code_document(rng, n, width=90):
    lines = []
    indent = 0
    for _ in range(n):
        r = rng.random()
        if r < 0.08:
            lines.append("")
            continue
        if r < 0.2 and indent < 6:
            indent += 1
        elif r < 0.32 and indent > 0:
            indent -= 1
        lines.append(code_line(rng, indent, width))
    return lines


class Session:
    """Builds a command list while running it on a live reference Buffer."""

    def __init__(self, seed, lines, limit=MAX_COMMANDS):
        self.limit = limit
        self.rng = random.Random(seed)
        self.lines = list(lines)
        self.buf = ref.Buffer(list(lines))
        self.cmds = []
        self.doc_len = sum(map(len, lines)) + len(lines) - 1
        self.max_doc = self.doc_len
        self.max_cursors = 1

    def emit(self, cmd):
        self.cmds.append(cmd)
        self.buf.run(cmd)
        head = cmd.split(" ", 1)[0]
        if head in ("insert", "delete", "delete-forward", "undo", "redo"):
            doc = self.buf.doc
            self.doc_len = sum(map(len, doc)) + len(doc) - 1
            assert self.doc_len <= MAX_DOC, self.doc_len
            self.max_doc = max(self.max_doc, self.doc_len)
        self.max_cursors = max(self.max_cursors, len(self.buf.cursors))
        assert len(self.buf.cursors) <= MAX_CURSORS

    def remaining(self):
        return self.limit - len(self.cmds)

    def nlines(self):
        return len(self.buf.doc)

    def word(self):
        rng = self.rng
        r = rng.random()
        if r < 0.6:
            return rng.choice(IDENTS)
        if r < 0.75:
            return str(rng.randint(0, 9999))
        return rng.choice(PUNCT).strip() or "+"

    def text(self):
        return "\n".join([str(len(self.lines))] + self.lines + self.cmds) + "\n"


# ---------------------------------------------------------------------------
# Single-cursor building blocks
# ---------------------------------------------------------------------------

def navigate(s, near=True):
    rng = s.rng
    n = s.nlines()
    cl = s.buf.cursors[0].hl if s.buf.cursors else 0
    if near and rng.random() < 0.5:
        line = max(0, min(n - 1, cl + rng.randint(-60, 60)))
    else:
        line = rng.randrange(n)
    s.emit("goto %d %d" % (line, rng.randint(0, 60)))
    for _ in range(rng.randint(0, 8)):
        s.emit("move " + rng.choice(("up", "down", "down", "left", "right", "end", "home")))


def type_words(s, k):
    rng = s.rng
    for _ in range(k):
        r = rng.random()
        if r < 0.25:
            indent = " " * (4 * rng.randint(0, 4))
            s.emit("insert \\n" + indent)
            if rng.random() < 0.5:
                s.emit("insert " + s.word())
        elif r < 0.32:
            s.emit("insert " + rng.choice(PUNCT))
        else:
            sep = " " if rng.random() < 0.7 else ""
            s.emit("insert " + sep + s.word())


def paste_block(s):
    """Paste a multi-line snippet of code at the cursor."""
    rng = s.rng
    snippet = code_document(rng, rng.randint(3, 12))
    s.emit("insert " + encode_text("\n".join(snippet) + "\n"))


def backspace_run(s, k):
    rng = s.rng
    for _ in range(k):
        s.emit("delete" if rng.random() < 0.8 else "delete-forward")


def select_and_replace(s):
    rng = s.rng
    r = rng.random()
    if r < 0.4:
        for _ in range(rng.randint(1, 12)):
            s.emit("move %s select" % rng.choice(("left", "right")))
    elif r < 0.7:
        s.emit("move home")
        s.emit("move end select")
    else:
        for _ in range(rng.randint(1, 4)):
            s.emit("move down select")
    if rng.random() < 0.6:
        s.emit("insert " + encode_text(s.word() + ("\n" if rng.random() < 0.2 else "")))
    else:
        s.emit("delete")


def undo_redo(s, max_undo):
    rng = s.rng
    k = rng.randint(1, max_undo)
    for _ in range(k):
        s.emit("undo")
    for _ in range(rng.randint(0, k)):
        s.emit("redo")


def shrink(s):
    """Delete whole lines of text when the document grows near the cap."""
    rng = s.rng
    while s.doc_len > DOC_SOFT_CAP - 50000:
        s.emit("goto %d 0" % rng.randrange(s.nlines()))
        for _ in range(rng.randint(20, 80)):
            s.emit("move down select")
        s.emit("delete")


# ---------------------------------------------------------------------------
# Workload 1: a long single-cursor editing session on a 10,000-line file
# ---------------------------------------------------------------------------

def editing_session(n_cmds=MAX_COMMANDS):
    rng = random.Random(9101)
    lines = code_document(rng, 10000, 60)
    s = Session(9102, lines, n_cmds)
    print_at = {n_cmds * 33 // 100, n_cmds * 66 // 100}
    printed = set()
    while s.remaining() > 200:
        for p in print_at:
            if p not in printed and len(s.cmds) >= p:
                s.emit("print")
                printed.add(p)
        if s.doc_len > DOC_SOFT_CAP:
            shrink(s)
        r = rng.random()
        if r < 0.18:
            navigate(s)
        elif r < 0.26:
            paste_block(s)
        elif r < 0.55:
            type_words(s, rng.randint(1, 12))
        elif r < 0.7:
            backspace_run(s, rng.randint(1, 10))
        elif r < 0.85:
            select_and_replace(s)
        elif r < 0.95:
            for _ in range(rng.randint(1, 15)):
                s.emit("move " + rng.choice(("up", "down", "left", "right", "down", "up")))
        else:
            undo_redo(s, 30)
    s.emit("print")
    return s


# ---------------------------------------------------------------------------
# Workload 2: column edits with up to 2,000 cursors
# ---------------------------------------------------------------------------

MULTI_SCRIPTS = [
    ["move home", "insert // "],
    ["move end", "insert ;"],
    ["move end", "move left select", "move left select", "move left select", "insert ()"],
    ["move home", "move right select", "move right select", "move right select", "move right select",
     "delete"],
    ["move end", "insert \\n    ", "insert return", "insert  value;"],
    ["move home", "move right", "delete", "delete-forward"],
    ["move right", "move right", "insert _x", "move left", "delete"],
    ["move down", "move down", "insert #", "move up", "insert @"],
    ["move end select", "insert TODO"],
    ["undo", "undo", "redo"],
    ["move end", "insert  }", "move home", "insert {", "undo", "redo"],
    ["move end", "delete", "delete", "delete"],
    ["move home", "move right", "delete-forward", "delete-forward", "delete-forward"],
    ["move end", "move left select", "move left select", "move left select", "move left select",
     "delete"],
    ["move left select", "move left select", "insert x"],
]


def place_cursors(s, count, stride, start):
    rng = s.rng
    n = s.nlines()
    s.emit("goto %d %d" % (start, rng.randint(0, 8)))
    col = rng.randint(0, 12)
    for i in range(1, count):
        line = start + i * stride
        if line >= n:
            break
        jitter = col if rng.random() < 0.7 else rng.randint(0, 30)
        s.emit("add-cursor %d %d" % (line, jitter))


def column_editing(target_cmds, revert=0.0):
    """With revert > 0, that fraction of rounds ends by undoing every edit of
    the round (an abandoned experiment), which keeps the undo history and the
    document bounded however many rounds run."""
    rng = random.Random(9201)
    lines = code_document(rng, 10000)
    s = Session(9202, lines)
    rounds = 0
    while len(s.cmds) < target_cmds:
        n = s.nlines()
        count = MAX_CURSORS if rng.random() < 0.7 else rng.randint(500, MAX_CURSORS)
        stride = max(1, min(rng.randint(2, 5), (n - 1) // count))
        start = rng.randint(0, max(0, n - 1 - stride * (count - 1)))
        place_cursors(s, count, stride, start)
        undo_mark = len(s.buf.undo)
        for _ in range(rng.randint(150, 400)):
            if s.doc_len > DOC_SOFT_CAP - 150000:
                for c in ["move home", "move end select", "delete", "delete"]:
                    s.emit(c)
                continue
            for c in rng.choice(MULTI_SCRIPTS):
                s.emit(c)
        if revert and rng.random() < revert:
            for _ in range(len(s.buf.undo) - undo_mark):
                s.emit("undo")
        elif rounds % 2 == 1:
            for _ in range(rng.randint(2, 12)):
                s.emit("undo")
            for _ in range(rng.randint(0, 6)):
                s.emit("redo")
        s.emit("clear-cursors")
        rounds += 1
        if s.doc_len > DOC_SOFT_CAP - 150000:
            shrink(s)
        if rounds == 2:
            s.emit("print")
    s.emit("print")
    return s


# ---------------------------------------------------------------------------
# Workload 3: mixed session on a file with three 150k-character lines
# ---------------------------------------------------------------------------

def long_line(rng, length):
    chunk = []
    n = 0
    while n < length:
        tok = rng.choice(IDENTS + KEYWORDS + PUNCT + [str(rng.randint(0, 999))])
        chunk.append(tok)
        n += len(tok)
    return "".join(chunk)[:length]


def mixed_session(n_cmds=MAX_COMMANDS, long_len=150000):
    rng = random.Random(9301)
    lines = code_document(rng, 6000)  # trimmed to 2500 below
    long_at = sorted(rng.sample(range(2500), 3))
    lines = lines[:2500]
    for i in long_at:
        lines[i] = long_line(rng, long_len)
    s = Session(9302, lines, n_cmds)
    print_at = {n_cmds // 2}
    printed = set()

    def long_line_index():
        doc = s.buf.doc
        cands = [i for i in range(max(0, s.buf.cursors[0].hl - 3000), min(len(doc), s.buf.cursors[0].hl + 3000))
                 if len(doc[i]) > 20000]
        if not cands:
            cands = [i for i, l in enumerate(doc) if len(l) > 20000]
        return rng.choice(cands) if cands else rng.randrange(len(doc))

    def long_between(lo, hi):
        doc = s.buf.doc
        return any(len(doc[i]) > 20000 for i in range(max(0, lo), min(len(doc), hi + 1)))

    while s.remaining() > 3000:
        for p in print_at:
            if p not in printed and len(s.cmds) >= p:
                s.emit("print")
                printed.add(p)
        if s.doc_len > DOC_SOFT_CAP:
            shrink(s)
        r = rng.random()
        if r < 0.6:
            # Edit inside one of the long lines.
            li = long_line_index()
            s.emit("goto %d %d" % (li, rng.randint(0, len(s.buf.doc[li]))))
            for _ in range(rng.randint(3, 25)):
                q = rng.random()
                if q < 0.5:
                    s.emit("insert " + s.word())
                elif q < 0.75:
                    s.emit("delete")
                elif q < 0.9:
                    s.emit("move " + rng.choice(("left", "right", "right select", "left select")))
                else:
                    s.emit("insert ,")
        elif r < 0.78:
            # Ordinary edits on short lines; selections never swallow a long line.
            navigate(s)
            if long_between(s.buf.cursors[0].hl - 20, s.buf.cursors[0].hl + 20):
                continue
            for _ in range(rng.randint(1, 4)):
                q = rng.random()
                if q < 0.5:
                    type_words(s, rng.randint(1, 10))
                elif q < 0.75:
                    backspace_run(s, rng.randint(1, 8))
                else:
                    select_and_replace(s)
        elif r < 0.9:
            # Small multi-cursor edit on consecutive lines.
            n = s.nlines()
            count = rng.randint(5, 300)
            stride = rng.choice((1, 1, 2))
            for _ in range(20):
                start = rng.randint(0, max(0, n - 1 - stride * count))
                if not long_between(start - 12, start + stride * count + 12):
                    break
            else:
                continue
            place_cursors(s, count, stride, start)
            for _ in range(rng.randint(1, 4)):
                for c in rng.choice(MULTI_SCRIPTS):
                    s.emit(c)
            s.emit("clear-cursors")
        else:
            undo_redo(s, 120)
    s.emit("print")
    return s


def write(name, s, out_dir=HERE, max_input=MAX_INPUT, max_output=MAX_OUTPUT):
    text = s.text()
    ncmds = check_limits(name, text)
    data = text.encode()
    assert len(data) < max_input, (name, len(data))
    with open(os.path.join(out_dir, name + ".in"), "wb") as f:
        f.write(data)
    res = subprocess.run([sys.executable, REF], input=data, capture_output=True, check=True)
    assert len(res.stdout) <= max_output, (name, len(res.stdout))
    with open(os.path.join(out_dir, name + ".out"), "wb") as f:
        f.write(res.stdout)
    print("%-30s %6d cmds %8d in %8d out  max doc %7d  max cursors %4d"
          % (name, ncmds, len(data), len(res.stdout), s.max_doc, s.max_cursors))


def with_doc_cap(cap, fn):
    """Run a workload builder with a different document-size cap."""
    global MAX_DOC, DOC_SOFT_CAP
    saved = MAX_DOC, DOC_SOFT_CAP
    MAX_DOC, DOC_SOFT_CAP = cap, cap * 9 // 10
    try:
        return fn()
    finally:
        MAX_DOC, DOC_SOFT_CAP = saved


# Long tier (--long, written to ../bench-long): the same three workloads with
# more commands, column-editing rounds that are mostly abandoned and undone,
# and 3M-character long lines. Its limits are the raised ones in SPEC.md.
LONG_MAX_COMMANDS = 1000000
LONG_MAX_INPUT = 30000000
LONG_MAX_OUTPUT = 30000000
LONG_EDITING_CMDS = 990000
LONG_COLUMN_CMDS = 360000
LONG_COLUMN_REVERT = 0.95
LONG_MIXED_CMDS = 620000
LONG_LINE_LEN = 3000000
LONG_MAX_DOC = 12000000


def main():
    args = sys.argv[1:]
    long_tier = "--long" in args
    only = [a for a in args if a != "--long"]
    if long_tier:
        import gen_tests
        gen_tests.MAX_COMMANDS = LONG_MAX_COMMANDS
        out_dir = os.path.join(PROBLEM, "bench-long")
        os.makedirs(out_dir, exist_ok=True)
        limits = dict(out_dir=out_dir, max_input=LONG_MAX_INPUT, max_output=LONG_MAX_OUTPUT)
        jobs = [
            ("001_editing_session_100k", lambda: editing_session(LONG_EDITING_CMDS)),
            ("002_column_edits_2000_cursors",
             lambda: column_editing(LONG_COLUMN_CMDS, LONG_COLUMN_REVERT)),
            ("003_mixed_long_lines_undo",
             lambda: with_doc_cap(LONG_MAX_DOC, lambda: mixed_session(LONG_MIXED_CMDS, LONG_LINE_LEN))),
        ]
    else:
        limits = {}
        jobs = [
            ("001_editing_session_100k", editing_session),
            ("002_column_edits_2000_cursors", lambda: column_editing(COLUMN_CMDS)),
            ("003_mixed_long_lines_undo", mixed_session),
        ]
    for name, fn in jobs:
        if only and not any(name.startswith(o) for o in only):
            continue
        write(name, fn(), **limits)


COLUMN_CMDS = 6000

if __name__ == "__main__":
    main()
