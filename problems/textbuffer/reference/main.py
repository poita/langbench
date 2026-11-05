#!/usr/bin/env python3
"""Reference text buffer: a list of line strings, a list of cursors, and
undo/redo stacks of inverse edits.

Multi-cursor edits are applied one cursor at a time in cursor order. Instead
of shifting every later cursor after each edit, the composed shift of all
edits so far is kept as three numbers (line delta, the original line of the
last edit's end, and the column delta on that line), which is enough because
every later cursor lies at or after the last edit's end.
"""
import sys


class Cursor:
    __slots__ = ("hl", "hc", "al", "ac", "sel", "prim", "goal")

    def __init__(self, hl, hc, prim, al=0, ac=0, sel=False, goal=None):
        self.hl = hl
        self.hc = hc
        self.al = al
        self.ac = ac
        self.sel = sel
        self.prim = prim
        self.goal = hc if goal is None else goal

    def start(self):
        if self.sel and (self.al, self.ac) < (self.hl, self.hc):
            return (self.al, self.ac)
        return (self.hl, self.hc)

    def end(self):
        if self.sel and (self.al, self.ac) > (self.hl, self.hc):
            return (self.al, self.ac)
        return (self.hl, self.hc)

    def backward(self):
        return self.sel and (self.al, self.ac) > (self.hl, self.hc)

    def snapshot(self):
        return (self.hl, self.hc, self.al, self.ac, self.sel, self.prim)

    @staticmethod
    def restore(snap):
        hl, hc, al, ac, sel, prim = snap
        return Cursor(hl, hc, prim, al, ac, sel)


def splice(doc, sl, sc, el, ec, text):
    """Replace the text between (sl,sc) and (el,ec) with text. Returns the
    removed text and the position just after the inserted text."""
    if sl == el:
        line = doc[sl]
        old = line[sc:ec]
        head = line[:sc]
        tail = line[ec:]
    else:
        old = "\n".join([doc[sl][sc:]] + doc[sl + 1:el] + [doc[el][:ec]])
        head = doc[sl][:sc]
        tail = doc[el][ec:]
    if "\n" in text:
        parts = text.split("\n")
        parts[0] = head + parts[0]
        endc = len(parts[-1])
        parts[-1] += tail
        doc[sl:el + 1] = parts
        return old, sl + len(parts) - 1, endc
    doc[sl:el + 1] = [head + text + tail]
    return old, sl, sc + len(text)


def normalize(cursors):
    """Sort cursors by range start and merge colliding ones."""
    cursors.sort(key=lambda c: (c.start(), tuple(-x for x in c.end())))
    out = []
    for c in cursors:
        if out:
            last = out[-1]
            ls, le = last.start(), last.end()
            cs, ce = c.start(), c.end()
            if (not last.sel) or (not c.sel):
                merge = cs <= le
            else:
                merge = cs < le
            if merge:
                ne = max(le, ce)
                if ne == ls:
                    last.sel = False
                    last.hl, last.hc = ls
                elif last.backward():
                    last.hl, last.hc = ls
                    last.al, last.ac = ne
                else:
                    last.al, last.ac = ls
                    last.hl, last.hc = ne
                    last.sel = True
                last.prim = last.prim or c.prim
                continue
        out.append(c)
    cursors[:] = out


def clamp(doc, l, c):
    if l < 0:
        l = 0
    if l >= len(doc):
        l = len(doc) - 1
    if c < 0:
        c = 0
    n = len(doc[l])
    if c > n:
        c = n
    return l, c


def decode_text(s):
    out = []
    i = 0
    n = len(s)
    while i < n:
        ch = s[i]
        if ch == "\\":
            nxt = s[i + 1]
            out.append("\n" if nxt == "n" else "\\")
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


class Buffer:
    def __init__(self, lines):
        self.doc = lines
        self.cursors = [Cursor(0, 0, True)]
        self.undo = []
        self.redo = []
        self.out = []

    # --- edits ------------------------------------------------------------
    def edit_command(self, kind, text=None):
        doc = self.doc
        cursors = self.cursors
        before = [c.snapshot() for c in cursors]
        # Every cursor's range in the coordinates of the document before the
        # command; edits are applied in cursor order and later cursors are
        # mapped through the composed shift (dl, ref, dc).
        ranges = [(c.start(), c.end(), c.sel) for c in cursors]
        dl = 0
        ref = -1
        dc = 0
        edits = []
        for cur, ((sl, sc), (el, ec), sel) in zip(cursors, ranges):
            # Map original positions into the current document.
            csl = sl + dl
            csc = sc + dc if sl == ref else sc
            cel = el + dl
            cec = ec + dc if el == ref else ec
            if sel:
                new = text if kind == "insert" else ""
                eol, eoc = el, ec
            elif kind == "insert":
                new = text
                eol, eoc = el, ec
            elif kind == "delete":
                new = ""
                eol, eoc = el, ec
                if csc > 0:
                    csc -= 1
                elif csl > 0:
                    csl -= 1
                    csc = len(doc[csl])
                else:
                    cur.hl, cur.hc, cur.sel = cel, cec, False
                    continue
            else:  # delete-forward
                new = ""
                if cec < len(doc[cel]):
                    cec += 1
                    eol, eoc = el, ec + 1
                elif cel + 1 < len(doc):
                    cel += 1
                    cec = 0
                    eol, eoc = el + 1, 0
                else:
                    cur.hl, cur.hc, cur.sel = cel, cec, False
                    continue
            old, ql, qc = splice(doc, csl, csc, cel, cec, new)
            edits.append((csl, csc, old, new))
            cur.hl, cur.hc, cur.sel = ql, qc, False
            dl = ql - eol
            ref = eol
            dc = qc - eoc
        normalize(cursors)
        if edits:
            after = [c.snapshot() for c in cursors]
            self.undo.append((before, after, edits))
            self.redo = []

    def apply_undo(self):
        if not self.undo:
            return
        before, after, edits = self.undo.pop()
        doc = self.doc
        for sl, sc, old, new in reversed(edits):
            el, ec = end_of(sl, sc, new)
            splice(doc, sl, sc, el, ec, old)
        self.cursors = [Cursor.restore(s) for s in before]
        self.redo.append((before, after, edits))

    def apply_redo(self):
        if not self.redo:
            return
        before, after, edits = self.redo.pop()
        doc = self.doc
        for sl, sc, old, new in edits:
            el, ec = end_of(sl, sc, old)
            splice(doc, sl, sc, el, ec, new)
        self.cursors = [Cursor.restore(s) for s in after]
        self.undo.append((before, after, edits))

    # --- cursor movement ----------------------------------------------------
    def move(self, direction, select):
        doc = self.doc
        last = len(doc) - 1
        for c in self.cursors:
            if select:
                if not c.sel:
                    c.al, c.ac = c.hl, c.hc
                    c.sel = True
            elif c.sel:
                if direction == "left":
                    c.hl, c.hc = c.start()
                    c.sel = False
                    continue
                if direction == "right":
                    c.hl, c.hc = c.end()
                    c.sel = False
                    continue
                c.sel = False
            l, col = c.hl, c.hc
            if direction == "left":
                if col > 0:
                    col -= 1
                elif l > 0:
                    l -= 1
                    col = len(doc[l])
            elif direction == "right":
                if col < len(doc[l]):
                    col += 1
                elif l < last:
                    l += 1
                    col = 0
            elif direction == "home":
                col = 0
            elif direction == "end":
                col = len(doc[l])
            elif direction == "up":
                if l == 0:
                    col = 0
                    c.goal = 0
                else:
                    l -= 1
                    col = min(c.goal, len(doc[l]))
            else:  # down
                if l == last:
                    col = len(doc[l])
                    c.goal = col
                else:
                    l += 1
                    col = min(c.goal, len(doc[l]))
            c.hl, c.hc = l, col
            if c.sel and (c.al, c.ac) == (l, col):
                c.sel = False
        normalize(self.cursors)

    def goto(self, l, col):
        l, col = clamp(self.doc, l, col)
        self.cursors = [Cursor(l, col, True)]

    def add_cursor(self, l, col):
        l, col = clamp(self.doc, l, col)
        self.cursors.append(Cursor(l, col, False))
        normalize(self.cursors)

    def clear_cursors(self):
        self.cursors = [c for c in self.cursors if c.prim]

    def print_state(self):
        out = self.out
        out.extend(self.doc)
        for c in self.cursors:
            out.append("cursor %d %d" % (c.hl, c.hc))
        out.append("--")

    # --- dispatch -----------------------------------------------------------
    def run(self, line):
        sp = line.find(" ")
        cmd = line if sp < 0 else line[:sp]
        if cmd == "insert":
            self.edit_command("insert", decode_text(line[sp + 1:]))
        elif cmd == "delete":
            self.edit_command("delete")
        elif cmd == "delete-forward":
            self.edit_command("delete-forward")
        elif cmd == "move":
            parts = line.split(" ")
            direction = parts[1]
            self.move(direction, len(parts) > 2)
            if direction in ("up", "down"):
                return
        elif cmd == "goto":
            parts = line.split(" ")
            self.goto(int(parts[1]), int(parts[2]))
        elif cmd == "add-cursor":
            parts = line.split(" ")
            self.add_cursor(int(parts[1]), int(parts[2]))
        elif cmd == "clear-cursors":
            self.clear_cursors()
        elif cmd == "undo":
            self.apply_undo()
        elif cmd == "redo":
            self.apply_redo()
        elif cmd == "print":
            self.print_state()
            return
        for c in self.cursors:
            c.goal = c.hc


def end_of(sl, sc, text):
    """Position just after `text` when it starts at (sl, sc)."""
    nl = text.count("\n")
    if nl == 0:
        return sl, sc + len(text)
    return sl + nl, len(text) - text.rfind("\n") - 1


def main():
    data = sys.stdin.buffer.read().decode("utf-8")
    lines = data.split("\n")
    n = int(lines[0].strip())
    doc = lines[1:1 + n]
    while len(doc) < max(n, 1):
        doc.append("")
    buf = Buffer(doc)
    for line in lines[1 + n:]:
        if line == "":
            continue
        buf.run(line)
    sys.stdout.write("\n".join(buf.out) + ("\n" if buf.out else ""))


if __name__ == "__main__":
    main()
