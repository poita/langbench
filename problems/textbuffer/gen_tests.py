#!/usr/bin/env python3
"""Generate tests/*.in deterministically and tests/*.out via reference/main.py.

Hand-written edge cases are embedded as literals. Generated workloads are
driven by FlatModel, an independent implementation of SPEC.md that keeps the
document as one flat string with cursors as character offsets and applies
every multi-cursor edit literally (one cursor at a time, shifting every later
cursor). Every expected output is cross-checked against FlatModel; any
disagreement between it and the reference aborts generation.
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
REF = os.path.join(HERE, "reference", "main.py")

MAX_COMMANDS = 100000
MAX_LINES = 10000
MAX_CURSORS = 2000

TEXT_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-.,;:!?()[]{}<>/\\'\"#$%&*+=@^~`|"


def encode_text(t):
    return t.replace("\\", "\\\\").replace("\n", "\\n")


# ---------------------------------------------------------------------------
# Flat-string model of the specification
# ---------------------------------------------------------------------------

class FCur:
    __slots__ = ("head", "anchor", "prim", "goal")

    def __init__(self, head, prim, anchor=None, goal=None):
        self.head = head
        self.anchor = anchor  # None when there is no selection
        self.prim = prim
        self.goal = goal

    def start(self):
        return self.head if self.anchor is None else min(self.head, self.anchor)

    def end(self):
        return self.head if self.anchor is None else max(self.head, self.anchor)

    def backward(self):
        return self.anchor is not None and self.anchor > self.head

    def snap(self):
        return (self.head, self.anchor, self.prim)


class FlatModel:
    def __init__(self, lines):
        self.text = "\n".join(lines)
        self.cursors = [FCur(0, True, None, 0)]
        self.undo = []
        self.redo = []
        self.out = []

    # --- position helpers --------------------------------------------------
    def line_start(self, off):
        return self.text.rfind("\n", 0, off) + 1

    def line_end(self, off):
        e = self.text.find("\n", off)
        return len(self.text) if e < 0 else e

    def to_pos(self, off):
        ls = self.line_start(off)
        return self.text.count("\n", 0, off), off - ls

    def line_count(self):
        return self.text.count("\n") + 1

    def line_offset(self, line):
        """Offset of the start of `line`, clamped to the last line."""
        off = 0
        while line > 0:
            e = self.text.find("\n", off)
            if e < 0:
                break
            off = e + 1
            line -= 1
        return off

    def to_off(self, line, col):
        if line < 0:
            line = 0
        ls = self.line_offset(line)
        le = self.line_end(ls)
        if col < 0:
            col = 0
        return ls + min(col, le - ls)

    def line_len_at(self, line):
        ls = self.line_offset(line)
        return self.line_end(ls) - ls

    # --- normalization -----------------------------------------------------
    def normalize(self):
        cs = sorted(self.cursors, key=lambda c: (c.start(), -c.end()))
        out = []
        for c in cs:
            if out:
                last = out[-1]
                if last.anchor is None or c.anchor is None:
                    merge = c.start() <= last.end()
                else:
                    merge = c.start() < last.end()
                if merge:
                    s = last.start()
                    e = max(last.end(), c.end())
                    if s == e:
                        last.head, last.anchor = s, None
                    elif last.backward():
                        last.head, last.anchor = s, e
                    else:
                        last.head, last.anchor = e, s
                    last.prim = last.prim or c.prim
                    continue
            out.append(c)
        self.cursors = out

    # --- edits -------------------------------------------------------------
    def replace(self, s, e, new):
        old = self.text[s:e]
        self.text = self.text[:s] + new + self.text[e:]
        return old

    def edit(self, kind, text=""):
        before = [c.snap() for c in self.cursors]
        edits = []
        cs = self.cursors
        for i, c in enumerate(cs):
            s, e = c.start(), c.end()
            if c.anchor is not None:
                new = text if kind == "insert" else ""
            elif kind == "insert":
                new = text
            elif kind == "delete":
                if s == 0:
                    continue
                s -= 1
                new = ""
            else:
                if e == len(self.text):
                    continue
                e += 1
                new = ""
            old = self.replace(s, e, new)
            edits.append((s, old, new))
            c.head, c.anchor = s + len(new), None
            delta = len(new) - (e - s)
            for later in cs[i + 1:]:
                if later.head >= e:
                    later.head += delta
                if later.anchor is not None and later.anchor >= e:
                    later.anchor += delta
        self.normalize()
        if edits:
            after = [c.snap() for c in self.cursors]
            self.undo.append((before, after, edits))
            self.redo = []

    def do_undo(self):
        if not self.undo:
            return
        entry = self.undo.pop()
        before, after, edits = entry
        for s, old, new in reversed(edits):
            self.replace(s, s + len(new), old)
        self.cursors = [FCur(h, True if p else False, a) for h, a, p in before]
        self.redo.append(entry)

    def do_redo(self):
        if not self.redo:
            return
        entry = self.redo.pop()
        before, after, edits = entry
        for s, old, new in edits:
            self.replace(s, s + len(old), new)
        self.cursors = [FCur(h, True if p else False, a) for h, a, p in after]
        self.undo.append(entry)

    # --- movement ----------------------------------------------------------
    def move(self, direction, select):
        t = self.text
        for c in self.cursors:
            if select:
                if c.anchor is None:
                    c.anchor = c.head
            elif c.anchor is not None:
                if direction == "left":
                    c.head, c.anchor = c.start(), None
                    continue
                if direction == "right":
                    c.head, c.anchor = c.end(), None
                    continue
                c.anchor = None
            p = c.head
            if direction == "left":
                if p > 0:
                    p -= 1
            elif direction == "right":
                if p < len(t):
                    p += 1
            elif direction == "home":
                p = self.line_start(p)
            elif direction == "end":
                p = self.line_end(p)
            elif direction == "up":
                ls = self.line_start(p)
                if ls == 0:
                    p = 0
                    c.goal = 0
                else:
                    pls = self.line_start(ls - 1)
                    p = pls + min(c.goal, ls - 1 - pls)
            else:
                le = self.line_end(p)
                if le == len(t):
                    p = le
                    c.goal = le - self.line_start(p)
                else:
                    nls = le + 1
                    nle = self.line_end(nls)
                    p = nls + min(c.goal, nle - nls)
            c.head = p
            if c.anchor == p:
                c.anchor = None
        self.normalize()

    # --- commands ----------------------------------------------------------
    def run(self, line):
        sp = line.find(" ")
        cmd = line if sp < 0 else line[:sp]
        if cmd == "insert":
            self.edit("insert", decode_text(line[sp + 1:]))
        elif cmd == "delete":
            self.edit("delete")
        elif cmd == "delete-forward":
            self.edit("delete-forward")
        elif cmd == "move":
            parts = line.split(" ")
            self.move(parts[1], len(parts) > 2)
            if parts[1] in ("up", "down"):
                return
        elif cmd == "goto":
            _, l, col = line.split(" ")
            self.cursors = [FCur(self.to_off(int(l), int(col)), True)]
        elif cmd == "add-cursor":
            _, l, col = line.split(" ")
            self.cursors.append(FCur(self.to_off(int(l), int(col)), False))
            self.normalize()
        elif cmd == "clear-cursors":
            self.cursors = [c for c in self.cursors if c.prim]
        elif cmd == "undo":
            self.do_undo()
        elif cmd == "redo":
            self.do_redo()
        elif cmd == "print":
            self.out.extend(self.text.split("\n"))
            for c in self.cursors:
                self.out.append("cursor %d %d" % self.to_pos(c.head))
            self.out.append("--")
            return
        else:
            raise ValueError("bad command: " + line)
        for c in self.cursors:
            c.goal = c.head - self.line_start(c.head)

    def output(self):
        return "\n".join(self.out) + ("\n" if self.out else "")


def decode_text(s):
    out = []
    i = 0
    while i < len(s):
        if s[i] == "\\":
            out.append("\n" if s[i + 1] == "n" else "\\")
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


# ---------------------------------------------------------------------------
# Test construction
# ---------------------------------------------------------------------------

def make_input(lines, cmds):
    return "%d\n%s" % (len(lines), "".join(l + "\n" for l in lines) + "".join(c + "\n" for c in cmds))


def hand_tests():
    t = {}
    t["001_empty_document"] = make_input([], ["print", "move left", "move up", "delete", "delete-forward", "print"])
    t["002_spec_example_1"] = make_input(
        ["hello world", "second line"],
        ["move end", "insert !", "move down", "insert  (edited)", "goto 0 5", "insert ,", "print",
         "delete", "delete", "print"])
    t["003_spec_example_2"] = make_input(
        ["alpha", "beta", "gamma"],
        ["add-cursor 1 0", "add-cursor 2 0", "insert - ", "print",
         "move end select", "insert X", "print",
         "goto 0 1", "move right select", "move right select", "delete", "print"])
    t["004_spec_example_3"] = make_input(
        ["abc"],
        ["move end", "insert d\\ne", "print", "delete", "delete", "print", "undo", "print", "undo", "print",
         "redo", "print", "insert Z", "redo", "print"])
    t["005_insert_escapes"] = make_input(
        ["x"],
        ["insert \\\\", "print", "insert \\n", "print", "insert a\\nb\\n\\nc", "print",
         "insert \\\\n", "print", "insert   two spaces  ", "print", "move end", "insert \\n\\n", "print",
         "goto 0 0", "insert \\\\\\\\", "print"])
    t["006_backspace"] = make_input(
        ["ab", "", "cd"],
        ["delete", "print", "goto 0 2", "delete", "print", "goto 2 0", "delete", "print",
         "delete", "print", "delete", "delete", "print", "goto 0 1", "delete", "delete", "print",
         "delete", "print"])
    t["007_delete_forward"] = make_input(
        ["ab", "", "cd"],
        ["delete-forward", "print", "goto 0 1", "delete-forward", "print", "delete-forward", "print",
         "delete-forward", "print", "goto 1 2", "delete-forward", "print", "delete-forward", "print",
         "delete-forward", "print", "delete-forward", "print"])
    t["008_move_left_right"] = make_input(
        ["ab", "", "c"],
        ["move left", "print", "move right", "move right", "print", "move right", "print", "move right",
         "print", "move right", "print", "move right", "move right", "print", "move left", "print",
         "move left", "print", "move left", "print", "move left", "move left", "move left", "print"])
    t["009_home_end"] = make_input(
        ["hello", "", "world!"],
        ["move end", "print", "move end", "print", "move home", "print", "move home", "print",
         "goto 1 0", "move end", "print", "goto 2 3", "move end", "print", "move home", "print",
         "move home select", "print", "move end select", "insert W", "print"])
    t["010_goal_column"] = make_input(
        ["0123456789", "ab", "", "0123456789abcdef", "xyz"],
        ["goto 0 7", "move down", "print", "move down", "print", "move down", "print", "move down",
         "print", "move down", "print", "move up", "print", "move up", "print", "move up", "print",
         "move up", "print", "move up", "print", "move down", "print",
         "goto 3 12", "move up", "print", "move left", "move down", "print", "move down", "print",
         "goto 0 5", "move down", "move down", "insert Q", "move up", "print", "move down", "move down",
         "print", "goto 3 9", "move up", "move up", "move right", "move down", "move down", "print",
         "goto 0 8", "move down", "move end", "move down", "print", "goto 0 9", "move down", "move home",
         "move down", "print", "goto 4 2", "move down", "move up", "print", "goto 0 6", "move up",
         "move down", "print",
         # Two cursors clamped onto the same position by `move down` merge; the
         # merged cursor keeps the goal column of the one that came first in
         # cursor order (the stable tie-break), until the document edge resets it.
         "goto 3 12", "add-cursor 4 1", "move down", "print", "move up", "print",
         "move down", "move down", "print", "move up", "print",
         "goto 3 12", "add-cursor 4 1", "move down", "move up", "move up", "move down", "print"])
    t["011_selection_moves"] = make_input(
        ["abcdef", "ghij", "klmnop"],
        ["goto 0 2", "move right select", "move right select", "print", "move left", "print",
         "move right select", "move right select", "move right", "print",
         "move left select", "move left select", "move left select", "print", "move right", "print",
         "goto 0 3", "move left select", "move left select", "move right select", "print",
         "move right select", "print", "move right select", "print", "move left", "print",
         "goto 0 3", "move down select", "print", "move down select", "move up", "print",
         "goto 1 2", "move home select", "move end", "print", "goto 1 2", "move end select", "move home",
         "print", "goto 1 2", "move end select", "move up", "print",
         "goto 1 2", "move home select", "move down", "print",
         "goto 0 4", "move up select", "print", "insert #", "print", "goto 2 1", "move down select",
         "print", "delete", "print"])
    t["012_selection_edits"] = make_input(
        ["one two three", "four five", "six"],
        ["goto 0 4", "move right select", "move right select", "move right select", "insert 2",
         "print", "goto 0 4", "move right select", "delete", "print", "move right select",
         "move right select", "delete-forward", "print", "goto 0 3", "move down select",
         "move down select", "print", "insert |", "print", "goto 0 2", "move down select",
         "move end select", "delete", "print", "move up select", "move up select", "delete-forward",
         "print", "goto 1 0", "move left select", "insert A\\nB", "print"])
    t["013_multicursor_lines"] = make_input(
        ["first", "second", "third", "fourth"],
        ["add-cursor 1 0", "add-cursor 2 0", "add-cursor 3 0", "insert // ", "print", "move end",
         "insert ;", "print", "move home", "delete-forward", "delete-forward", "delete-forward", "print",
         "move end", "delete", "print", "insert \\n", "print", "delete", "print"])
    t["014_multicursor_same_line"] = make_input(
        ["abcdefghij"],
        ["add-cursor 0 3", "add-cursor 0 6", "add-cursor 0 10", "insert XY", "print", "delete",
         "print", "delete-forward", "print", "insert 1\\n2", "print", "move up", "print",
         "move down", "print", "undo", "print", "goto 0 5", "add-cursor 0 2", "add-cursor 0 8",
         "move left select", "move left select", "insert -", "print"])
    t["015_cursor_merging"] = make_input(
        ["abcdef", "ghijkl"],
        ["add-cursor 0 0", "print", "add-cursor 0 3", "add-cursor 0 4", "delete", "print",
         "goto 0 3", "add-cursor 0 4", "delete", "print", "goto 0 1", "add-cursor 0 2", "delete-forward",
         "print", "goto 0 1", "add-cursor 0 2", "move left", "move left", "print", "insert q", "print",
         "goto 0 5", "add-cursor 1 5", "move right", "print", "goto 0 3", "add-cursor 1 3",
         "move up", "print", "goto 0 3", "add-cursor 1 3", "move down", "print",
         "goto 0 4", "add-cursor 1 2", "move end", "move down", "print"])
    t["016_selection_merging"] = make_input(
        ["abcdefgh", "ijklmnop", "qrstuvwx", "yz"],
        # Two forward selections growing into each other: touching ranges
        # stay separate, overlapping ranges merge into one forward selection.
        ["goto 0 1", "add-cursor 0 3", "move right select", "move right select", "print",
         "move right select", "print", "delete", "print", "undo", "print", "move left", "print",
         # The same with backward selections: the merged selection is backward.
         "goto 0 5", "add-cursor 0 3", "move left select", "move left select", "print",
         "move left select", "print", "insert Z", "print", "undo", "print", "move right", "print",
         # Point cursors inside or on the edge of a selection are absorbed and
         # the selection keeps its direction.
         "goto 0 4", "move left select", "move left select", "add-cursor 0 3", "print",
         "add-cursor 0 4", "print", "add-cursor 0 2", "print", "move right", "print",
         "goto 0 2", "move right select", "move right select", "add-cursor 0 3", "add-cursor 0 2",
         "add-cursor 0 4", "print", "move left", "print",
         # Selecting down from adjacent lines yields touching selections that
         # edit independently; selecting to the line end makes them overlap.
         "goto 0 0", "add-cursor 1 0", "add-cursor 2 0", "move down select", "print", "insert #",
         "print", "undo", "print", "move end select", "print", "delete", "print", "undo", "print",
         # A selection spanning lines absorbs a point cursor on a middle line.
         "goto 0 3", "move down select", "move down select", "add-cursor 1 4", "print",
         "add-cursor 2 3", "print", "add-cursor 2 4", "print", "delete-forward", "print", "undo",
         "print", "move up", "print",
         # Backward selections built with up-select merge when they overlap.
         "goto 1 2", "add-cursor 2 6", "move up select", "print", "move up select", "print",
         "move home select", "print", "insert Q", "print", "undo", "print"])
    t["017_primary_and_clear"] = make_input(
        ["aaa", "bbb", "ccc"],
        ["add-cursor 1 1", "add-cursor 2 2", "clear-cursors", "print", "goto 2 2", "add-cursor 0 0",
         "add-cursor 1 1", "print", "clear-cursors", "print", "goto 1 1", "add-cursor 1 1", "print",
         "add-cursor 0 0", "move right select", "clear-cursors", "print", "insert Q", "print",
         "goto 0 0", "add-cursor 0 2", "add-cursor 0 1", "move left", "move left", "print",
         "clear-cursors", "print", "goto 1 3", "add-cursor 1 2", "move left", "print",
         "clear-cursors", "print", "goto 0 0", "add-cursor 1 0", "add-cursor 2 0", "goto 2 1", "print",
         "add-cursor 0 0", "add-cursor 1 0", "undo", "print", "clear-cursors", "print",
         # The primary cursor is absorbed by a non-primary one that sorts first:
         # the merged cursor must be primary, so clear-cursors keeps it.
         "goto 0 3", "add-cursor 0 1", "move left", "move left", "move left", "print",
         "clear-cursors", "print",
         "goto 1 2", "add-cursor 1 0", "move right select", "move right select", "print",
         "move right select", "print", "clear-cursors", "print", "insert Q", "print", "undo",
         "clear-cursors", "print"])
    t["018_undo_redo_chain"] = make_input(
        ["base"],
        ["insert 1", "insert 2", "insert 3", "print", "undo", "print", "undo", "print", "redo", "print",
         "undo", "undo", "print", "undo", "print", "redo", "redo", "redo", "print", "redo", "print",
         "move end", "delete", "delete", "print", "undo", "print", "undo", "print", "redo", "print",
         "insert x", "redo", "print", "undo", "undo", "undo", "undo", "undo", "print",
         "redo", "redo", "redo", "redo", "redo", "redo", "print"])
    t["019_undo_multicursor"] = make_input(
        ["red", "green", "blue"],
        ["add-cursor 1 2", "add-cursor 2 4", "insert **", "print", "undo", "print", "redo", "print",
         "move end", "move left select", "move left select", "delete", "print", "undo", "print",
         "move down", "print", "redo", "print", "undo", "undo", "print", "goto 0 0",
         "move right select", "add-cursor 1 1", "add-cursor 2 2", "insert \\n", "print", "undo", "print",
         "clear-cursors", "redo", "print", "undo", "print"])
    t["020_undo_edge_cases"] = make_input(
        ["ab"],
        # No-op edits record nothing and do not clear the redo stack; cursor
        # commands never touch the stacks; undo restores cursors as they were.
        ["undo", "redo", "print", "insert x", "undo", "delete", "print", "redo", "print", "undo",
         "goto 0 2", "delete-forward", "print", "redo", "print", "undo", "move end", "move left",
         "add-cursor 0 0", "print", "redo", "print", "undo", "goto 0 1", "insert Q", "redo", "print",
         "undo", "undo", "print", "goto 0 2", "add-cursor 0 0", "delete", "print", "undo", "print",
         "redo", "print", "goto 0 0", "add-cursor 0 2", "delete-forward", "print", "undo", "print",
         "redo", "print", "insert a\\nb", "goto 1 0", "delete", "print", "undo", "print", "undo", "print",
         "redo", "print", "redo", "print"])
    t["021_goto_clamping"] = make_input(
        ["abc", "", "defgh"],
        ["goto 5 0", "print", "goto 0 99", "print", "goto 1 3", "print", "goto 2 1000000000", "print",
         "goto 1000000000 1000000000", "print", "add-cursor 7 7", "print", "add-cursor 0 50", "print",
         "add-cursor 1 50", "print", "insert +", "print", "goto 2 5", "add-cursor 2 6", "print"])
    t["022_document_content"] = make_input(
        ["insert x", "  leading and trailing  ", "\\n is literal here \\\\", "print", "", "goto 0 0",
         "--", "cursor 1 2"],
        ["print", "goto 2 0", "move end", "insert \\\\n", "print", "goto 4 0", "insert \\n", "print",
         "goto 1 0", "insert  ", "move end", "insert  ", "print"])
    return t


# ---------------------------------------------------------------------------
# Random workloads driven by the flat model
# ---------------------------------------------------------------------------

class Workload:
    def __init__(self, seed, lines, max_len=None):
        self.rng = random.Random(seed)
        self.lines = lines
        self.model = FlatModel(lines)
        self.cmds = []
        self.max_len = max_len or max(2000, 3 * len(self.model.text))
        self.prints = 0

    def emit(self, cmd):
        self.cmds.append(cmd)
        self.model.run(cmd)

    def rand_text(self, maxlen=8, newline_p=0.15, bs_p=0.1):
        rng = self.rng
        n = rng.randint(1, maxlen)
        chars = []
        for _ in range(n):
            r = rng.random()
            if r < newline_p:
                chars.append("\n")
            elif r < newline_p + bs_p:
                chars.append("\\")
            else:
                chars.append(rng.choice(TEXT_CHARS))
        return "".join(chars)

    def rand_pos(self):
        rng = self.rng
        m = self.model
        n = m.line_count()
        if rng.random() < 0.05:
            return rng.randint(0, 2 * n + 5), rng.randint(0, 400)
        line = rng.randrange(n)
        ll = m.line_len_at(line)
        if rng.random() < 0.15:
            col = ll + rng.randint(0, 3)
        else:
            col = rng.randint(0, ll)
        return line, col

    def step(self, weights):
        rng = self.rng
        m = self.model
        op = rng.choices(list(weights), weights=list(weights.values()))[0]
        if op == "insert":
            if len(m.text) > self.max_len:
                op = "delete"
            else:
                self.emit("insert " + encode_text(self.rand_text()))
                return
        if op == "delete":
            self.emit("delete" if rng.random() < 0.6 else "delete-forward")
        elif op == "move":
            d = rng.choice(("left", "right", "up", "down", "home", "end"))
            if rng.random() < 0.35:
                self.emit("move %s select" % d)
            else:
                self.emit("move " + d)
        elif op == "goto":
            self.emit("goto %d %d" % self.rand_pos())
        elif op == "add-cursor":
            if len(m.cursors) < MAX_CURSORS:
                self.emit("add-cursor %d %d" % self.rand_pos())
        elif op == "clear-cursors":
            self.emit("clear-cursors")
        elif op == "undo":
            self.emit("undo")
        elif op == "redo":
            self.emit("redo")
        elif op == "print":
            self.emit("print")

    def text(self):
        return make_input(self.lines, self.cmds)


SINGLE = {"insert": 30, "delete": 15, "move": 30, "goto": 8, "undo": 4, "redo": 3, "print": 4}
MULTI = {"insert": 22, "delete": 12, "move": 25, "goto": 5, "add-cursor": 12, "clear-cursors": 3,
         "undo": 5, "redo": 4, "print": 4}
UNDO_HEAVY = {"insert": 20, "delete": 10, "move": 15, "goto": 5, "add-cursor": 4, "clear-cursors": 1,
              "undo": 18, "redo": 14, "print": 3}


def rand_lines(rng, n, lo, hi, chars=TEXT_CHARS):
    return ["".join(rng.choice(chars) for _ in range(rng.randint(lo, hi))) for _ in range(n)]


def gen_random(seed, nlines, lo, hi, ncmds, weights, print_every=None, max_len=None):
    rng = random.Random(seed)
    lines = rand_lines(rng, nlines, lo, hi)
    w = Workload(seed, lines, max_len)
    ww = dict(weights)
    if print_every is not None:
        ww.pop("print", None)
    while len(w.cmds) < ncmds:
        if print_every is not None and len(w.cmds) % print_every == print_every - 1:
            w.emit("print")
        else:
            w.step(ww)
    if w.cmds[-1] != "print":
        w.emit("print")
    return w.text()


def gen_many_cursors(seed, nlines, ncursors):
    """Column editing: one cursor per line, then edits that hit every cursor."""
    rng = random.Random(seed)
    lines = rand_lines(rng, nlines, 5, 40)
    w = Workload(seed, lines)
    for i in range(1, ncursors):
        w.emit("add-cursor %d %d" % (i, rng.randint(0, 3)))
    w.emit("insert // ")
    w.emit("move end")
    w.emit("insert ;")
    w.emit("print")
    w.emit("move home")
    w.emit("move right select")
    w.emit("move right select")
    w.emit("delete")
    w.emit("delete")
    w.emit("print")
    w.emit("undo")
    w.emit("undo")
    w.emit("print")
    w.emit("redo")
    w.emit("move end")
    w.emit("insert \\n")
    w.emit("print")
    w.emit("delete")
    w.emit("delete")
    w.emit("delete-forward")
    w.emit("print")
    w.emit("undo")
    w.emit("undo")
    w.emit("undo")
    w.emit("undo")
    w.emit("print")
    w.emit("clear-cursors")
    w.emit("print")
    return w.text()


def gen_long_line(seed, length, ncmds):
    """A few very long lines with random in-line edits and occasional prints."""
    rng = random.Random(seed)
    lines = ["".join(rng.choice("abcdefghijklmnopqrstuvwxyz ") for _ in range(length)) for _ in range(3)]
    w = Workload(seed, lines, max_len=4 * length)
    weights = {"insert": 35, "delete": 25, "move": 20, "goto": 15, "undo": 3, "redo": 2}
    while len(w.cmds) < ncmds:
        if len(w.cmds) % (ncmds // 4) == (ncmds // 4) - 1:
            w.emit("print")
        else:
            w.step(weights)
    w.emit("print")
    return w.text()


def gen_undo_walk(seed, nlines, ncmds):
    """Long edit runs followed by long undo and redo runs."""
    rng = random.Random(seed)
    lines = rand_lines(rng, nlines, 10, 50)
    w = Workload(seed, lines)
    weights = {"insert": 40, "delete": 20, "move": 25, "goto": 8, "add-cursor": 5, "clear-cursors": 2}
    cycle = 0
    while len(w.cmds) < ncmds - 3:
        budget = ncmds - 3 - len(w.cmds)
        run = min(rng.randint(200, 3000), budget // 3)
        for _ in range(run):
            w.step(weights)
        k = min(rng.randint(run // 2, run + 50), budget - run)
        for _ in range(k):
            w.emit("undo")
        for _ in range(min(rng.randint(0, k), budget - run - k)):
            w.emit("redo")
        # A print after every cycle would make the output tens of megabytes.
        if cycle % 25 == 0:
            w.emit("print")
        cycle += 1
    w.emit("print")
    return w.text()


def gen_column_edit_large(seed, nlines, ncursors, stride):
    """Cursors on every `stride`-th line of a large document, then a mix of
    multi-cursor moves, selections, edits and undo/redo hitting all of them."""
    rng = random.Random(seed)
    lines = rand_lines(rng, nlines, 10, 60)
    w = Workload(seed, lines)
    for i in range(1, ncursors):
        w.emit("add-cursor %d %d" % (i * stride, rng.randint(0, 5)))
    script = ["move end", "move left select", "move left select", "insert <>", "print",
              "move home", "move right", "move right select", "move right select", "delete", "print",
              "undo", "undo", "print", "redo", "move down", "move down select", "insert |\\n|",
              "print", "undo", "move up", "move up", "move end", "insert \\n", "delete", "print",
              "move right", "delete", "undo", "undo", "undo", "print", "redo", "redo", "print",
              "clear-cursors", "print"]
    for c in script:
        w.emit(c)
    return w.text()


def generated_tests():
    t = {}
    t["023_random_single_small"] = gen_random(1, 5, 0, 12, 400, SINGLE)
    t["024_random_multi_small"] = gen_random(2, 6, 0, 10, 600, MULTI)
    t["025_random_undo_small"] = gen_random(3, 4, 0, 10, 800, UNDO_HEAVY)
    t["026_random_single_medium"] = gen_random(4, 60, 0, 40, 6000, SINGLE, print_every=500)
    t["027_random_multi_medium"] = gen_random(5, 80, 0, 30, 8000, MULTI, print_every=500)
    t["028_random_undo_medium"] = gen_random(6, 50, 0, 30, 8000, UNDO_HEAVY, print_every=500)
    t["029_many_cursors_2000"] = gen_many_cursors(7, 2000, 2000)
    t["030_long_lines_200k"] = gen_long_line(8, 200000, 20000)
    t["031_large_single_100k"] = gen_random(9, 10000, 20, 60, 100000, SINGLE, print_every=25000, max_len=800000)
    t["032_large_multi_100k"] = gen_random(10, 10000, 20, 60, 100000, MULTI, print_every=25000, max_len=800000)
    t["033_large_undo_walk_100k"] = gen_undo_walk(11, 10000, 100000)
    t["034_large_column_edit_10k"] = gen_column_edit_large(12, 10000, 2000, 5)
    return t


def check_limits(name, text):
    lines = text.split("\n")
    n = int(lines[0])
    assert 0 <= n <= MAX_LINES, (name, n)
    for l in lines[1:1 + n]:
        assert all(0x20 <= ord(ch) <= 0x7E for ch in l), (name, l[:40])
    cmds = [c for c in lines[1 + n:] if c != ""]
    assert len(cmds) <= MAX_COMMANDS, (name, len(cmds))
    for c in cmds:
        assert c and all(0x20 <= ord(ch) <= 0x7E for ch in c), (name, c[:40])
        head = c.split(" ")[0]
        assert head in ("insert", "delete", "delete-forward", "move", "goto", "add-cursor",
                        "clear-cursors", "undo", "redo", "print"), (name, c[:40])
        if head == "insert":
            assert c.startswith("insert ") and len(c) > 7, (name, c)
            body = c[7:]
            i = 0
            while i < len(body):
                if body[i] == "\\":
                    assert i + 1 < len(body) and body[i + 1] in "n\\", (name, c)
                    i += 2
                else:
                    i += 1
        elif head in ("goto", "add-cursor"):
            p = c.split(" ")
            assert len(p) == 3 and all(x.isdigit() and 0 <= int(x) <= 10**9 for x in p[1:]), (name, c)
        elif head == "move":
            p = c.split(" ")
            assert p[1] in ("left", "right", "up", "down", "home", "end"), (name, c)
            assert len(p) == 2 or (len(p) == 3 and p[2] == "select"), (name, c)
        else:
            assert c == head, (name, c)
    return len(cmds)


def model_output(text):
    lines = text.split("\n")
    n = int(lines[0])
    doc = lines[1:1 + n] if n > 0 else [""]
    m = FlatModel(doc)
    for c in lines[1 + n:]:
        if c != "":
            m.run(c)
    return m.output()


def check_spec_example(name, inp, out):
    with open(os.path.join(HERE, "SPEC.md")) as f:
        spec = f.read()

    def block(text):
        return "\n".join("    " + ln for ln in text.strip("\n").split("\n"))

    assert block(inp) in spec, ("input block missing from SPEC.md", name)
    assert block(out) in spec, ("output block missing from SPEC.md", name)


def main():
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        if f.endswith(".in") or f.endswith(".out"):
            os.remove(os.path.join(TESTS, f))
    tests = {}
    tests.update(hand_tests())
    tests.update(generated_tests())
    total = 0
    max_cursors = 0
    for name in sorted(tests):
        text = tests[name]
        ncmds = check_limits(name, text)
        data = text.encode()
        with open(os.path.join(TESTS, name + ".in"), "wb") as f:
            f.write(data)
        res = subprocess.run([sys.executable, REF], input=data, capture_output=True, check=True)
        expected = model_output(text)
        if res.stdout.decode() != expected:
            sys.exit("reference disagrees with flat model on " + name)
        with open(os.path.join(TESTS, name + ".out"), "wb") as f:
            f.write(res.stdout)
        total += len(data) + len(res.stdout)
        if name.startswith("00") and "spec_example" in name:
            check_spec_example(name, text, res.stdout.decode())
        print("%-32s %6d cmds %9d in %9d out" % (name, ncmds, len(data), len(res.stdout)))
    print("total bytes:", total)


if __name__ == "__main__":
    main()
