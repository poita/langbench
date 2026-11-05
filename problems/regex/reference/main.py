#!/usr/bin/env python3
"""Reference backtracking regex engine for the langbench "regex" problem.

The pattern is parsed into an AST, compiled to a small instruction program and
executed by an explicit-stack backtracking VM. Captures and loop registers are
written through an undo trail so that backtracking restores them exactly as
the SPEC's recursive definition requires. No use of the `re` module.
"""
import sys

# ---------------------------------------------------------------------------
# Character sets (bitmap over the 128 ASCII code points)
# ---------------------------------------------------------------------------

def make_set(chars):
    bm = [False] * 128
    for c in chars:
        bm[ord(c)] = True
    return bm


DIGIT = make_set("0123456789")
WORD = make_set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
SPACE = make_set(" \t\n\r\f\v")
CLASS_ESCAPES = {"d": DIGIT, "w": WORD, "s": SPACE}


def negate(bm):
    return [not b for b in bm]


# ---------------------------------------------------------------------------
# AST nodes: tuples tagged by their first element
#   ("lit", ch) ("any",) ("cls", bitmap) ("bol",) ("eol",)
#   ("seq", [nodes]) ("alt", [nodes]) ("group", index, node)
#   ("rep", node, min, max_or_None)
# ---------------------------------------------------------------------------

class Parser:
    def __init__(self, pat):
        self.p = pat
        self.i = 0
        self.ngroups = 0

    def peek(self):
        return self.p[self.i] if self.i < len(self.p) else None

    def parse(self):
        node = self.parse_alt()
        if self.i != len(self.p):
            raise ValueError("unexpected %r at %d" % (self.p[self.i], self.i))
        return node

    def parse_alt(self):
        branches = [self.parse_seq()]
        while self.peek() == "|":
            self.i += 1
            branches.append(self.parse_seq())
        return branches[0] if len(branches) == 1 else ("alt", branches)

    def parse_seq(self):
        items = []
        while True:
            c = self.peek()
            if c is None or c == "|" or c == ")":
                break
            atom = self.parse_atom()
            atom = self.parse_quant(atom)
            items.append(atom)
        return ("seq", items)

    def parse_atom(self):
        c = self.p[self.i]
        if c == "(":
            self.i += 1
            self.ngroups += 1
            idx = self.ngroups
            inner = self.parse_alt()
            if self.peek() != ")":
                raise ValueError("missing )")
            self.i += 1
            return ("group", idx, inner)
        if c == ".":
            self.i += 1
            return ("any",)
        if c == "^":
            self.i += 1
            return ("bol",)
        if c == "$":
            self.i += 1
            return ("eol",)
        if c == "[":
            return self.parse_class()
        if c == "\\":
            return self.parse_escape()
        if c in "*+?{":
            raise ValueError("quantifier with nothing to repeat at %d" % self.i)
        if c in ")]}|":
            raise ValueError("unexpected %r at %d" % (c, self.i))
        self.i += 1
        return ("lit", c)

    def parse_escape(self):
        self.i += 1
        c = self.peek()
        if c is None:
            raise ValueError("trailing backslash")
        self.i += 1
        if c in CLASS_ESCAPES:
            return ("cls", CLASS_ESCAPES[c])
        if c.lower() in CLASS_ESCAPES:
            return ("cls", negate(CLASS_ESCAPES[c.lower()]))
        if c.isalnum():
            raise ValueError("unsupported escape \\%s" % c)
        return ("lit", c)

    def parse_class(self):
        self.i += 1  # consume '['
        neg = False
        if self.peek() == "^":
            neg = True
            self.i += 1
        bm = [False] * 128
        first = True
        while True:
            c = self.peek()
            if c is None:
                raise ValueError("unterminated class")
            if c == "]" and not first:
                self.i += 1
                break
            first = False
            lo, lo_set = self.class_item()
            if lo_set is not None:
                for k in range(128):
                    if lo_set[k]:
                        bm[k] = True
                continue
            # A '-' forms a range only when followed by something other than ']'.
            if self.peek() == "-" and self.i + 1 < len(self.p) and self.p[self.i + 1] != "]":
                self.i += 1
                hi, hi_set = self.class_item()
                if hi_set is not None or ord(hi) < ord(lo):
                    raise ValueError("bad range")
                for k in range(ord(lo), ord(hi) + 1):
                    bm[k] = True
            else:
                bm[ord(lo)] = True
        if neg:
            bm = negate(bm)
        return ("cls", bm)

    def class_item(self):
        """Returns (char, None) for a single character or (None, bitmap) for a set escape."""
        c = self.p[self.i]
        self.i += 1
        if c == "\\":
            e = self.peek()
            if e is None:
                raise ValueError("trailing backslash")
            self.i += 1
            if e in CLASS_ESCAPES:
                return None, CLASS_ESCAPES[e]
            if e.lower() in CLASS_ESCAPES:
                return None, negate(CLASS_ESCAPES[e.lower()])
            if e.isalnum():
                raise ValueError("unsupported escape \\%s in class" % e)
            return e, None
        if c == "]":
            raise ValueError("empty class")
        return c, None

    def parse_quant(self, atom):
        c = self.peek()
        if c == "*":
            self.i += 1
            mn, mx = 0, None
        elif c == "+":
            self.i += 1
            mn, mx = 1, None
        elif c == "?":
            self.i += 1
            mn, mx = 0, 1
        elif c == "{":
            self.i += 1
            mn = self.parse_int()
            if self.peek() == ",":
                self.i += 1
                if self.peek() == "}":
                    mx = None
                else:
                    mx = self.parse_int()
            else:
                mx = mn
            if self.peek() != "}":
                raise ValueError("bad counted quantifier")
            self.i += 1
            if mx is not None and mx < mn:
                raise ValueError("bad counted quantifier")
        else:
            return atom
        if atom[0] in ("bol", "eol", "rep"):
            raise ValueError("cannot quantify this item")
        if self.peek() in ("*", "+", "?", "{"):
            raise ValueError("double quantifier")
        return ("rep", atom, mn, mx)

    def parse_int(self):
        j = self.i
        while self.peek() is not None and self.peek().isdigit():
            self.i += 1
        if j == self.i:
            raise ValueError("expected integer in quantifier")
        return int(self.p[j:self.i])


# ---------------------------------------------------------------------------
# Compiler: AST -> list of instruction tuples
#   ("char", c) ("any",) ("cls", bm) ("bol",) ("eol",) ("match",)
#   ("split", x, y)   try x first, y on backtrack
#   ("jmp", x)
#   ("save", slot)    caps[slot] = pos
#   ("mark", r)       regs[r] = pos
#   ("check", r, nonempty_target, empty_target)
#                     pc = nonempty_target if pos != regs[r] else empty_target
# ---------------------------------------------------------------------------

class Compiler:
    def __init__(self):
        self.code = []
        self.nregs = 0

    def emit(self, ins):
        self.code.append(ins)
        return len(self.code) - 1

    def compile(self, node):
        t = node[0]
        if t == "lit":
            self.emit(("char", node[1]))
        elif t == "any":
            self.emit(("any",))
        elif t == "cls":
            self.emit(("cls", node[1]))
        elif t == "bol":
            self.emit(("bol",))
        elif t == "eol":
            self.emit(("eol",))
        elif t == "seq":
            for n in node[1]:
                self.compile(n)
        elif t == "group":
            self.emit(("save", 2 * node[1]))
            self.compile(node[2])
            self.emit(("save", 2 * node[1] + 1))
        elif t == "alt":
            branches = node[1]
            jumps = []
            for k, b in enumerate(branches):
                if k < len(branches) - 1:
                    split = self.emit(None)
                    self.compile(b)
                    jumps.append(self.emit(None))
                    self.code[split] = ("split", split + 1, len(self.code))
                else:
                    self.compile(b)
            for j in jumps:
                self.code[j] = ("jmp", len(self.code))
        elif t == "rep":
            _, body, mn, mx = node
            for _ in range(mn):
                self.compile(body)
            if mx is None:
                r = self.nregs
                self.nregs += 1
                l1 = self.emit(None)
                self.emit(("mark", r))
                self.compile(body)
                chk = self.emit(None)
                l3 = len(self.code)
                self.code[l1] = ("split", l1 + 1, l3)
                self.code[chk] = ("check", r, l1, l3)
            else:
                patches = []
                for _ in range(mx - mn):
                    r = self.nregs
                    self.nregs += 1
                    split = self.emit(None)
                    self.emit(("mark", r))
                    self.compile(body)
                    chk = self.emit(None)
                    patches.append((split, chk, r))
                l3 = len(self.code)
                for split, chk, r in patches:
                    self.code[split] = ("split", split + 1, l3)
                    self.code[chk] = ("check", r, chk + 1, l3)
        else:
            raise ValueError("bad node")


def starts_anchored(node):
    """True when every match of the pattern must begin with ^ (only start 0 needs trying)."""
    t = node[0]
    if t == "bol":
        return True
    if t == "seq":
        return bool(node[1]) and starts_anchored(node[1][0])
    if t == "group":
        return starts_anchored(node[2])
    if t == "alt":
        return all(starts_anchored(b) for b in node[1])
    if t == "rep":
        return node[2] >= 1 and starts_anchored(node[1])
    return False


def first_chars(node):
    """Returns (bitmap_or_None, nullable): bitmap of characters a match can start
    with (None = unrestricted), and whether the node can match without consuming."""
    t = node[0]
    if t == "lit":
        return make_set(node[1]), False
    if t == "cls":
        return node[1], False
    if t == "any":
        return None, False
    if t in ("bol", "eol"):
        return [False] * 128, True
    if t == "group":
        return first_chars(node[2])
    if t == "seq":
        acc = [False] * 128
        for n in node[1]:
            bm, nullable = first_chars(n)
            if bm is None:
                return None, False
            acc = [a or b for a, b in zip(acc, bm)]
            if not nullable:
                return acc, False
        return acc, True
    if t == "alt":
        acc = [False] * 128
        nullable = False
        for b in node[1]:
            bm, nb = first_chars(b)
            if bm is None:
                return None, False
            acc = [a or c for a, c in zip(acc, bm)]
            nullable = nullable or nb
        return acc, nullable
    if t == "rep":
        bm, nb = first_chars(node[1])
        return bm, nb or node[2] == 0
    raise ValueError("bad node")


class BudgetExceeded(Exception):
    pass


class Regex:
    def __init__(self, pattern):
        p = Parser(pattern)
        ast = p.parse()
        self.ngroups = p.ngroups
        c = Compiler()
        c.compile(ast)
        c.emit(("match",))
        self.code = c.code
        self.nregs = c.nregs
        self.anchored = starts_anchored(ast)
        bm, nullable = first_chars(ast)
        # Start positions whose character is outside the first set cannot match,
        # unless the pattern can match empty (then any position may match).
        self.first = None if (bm is None or nullable) else bm
        # Number of backtracks taken by the most recent search(). The test
        # generator reads it, and sets `budget` to abort searches that would
        # take too long, so that every published test stays bounded.
        self.backtracks = 0
        self.budget = None

    def search(self, s):
        n = len(s)
        self.backtracks = 0
        starts = range(0, 1) if self.anchored else range(0, n + 1)
        first = self.first
        for start in starts:
            if first is not None:
                if start == n or not first[ord(s[start])]:
                    continue
            res = self.run(s, start)
            if res is not None:
                return start, res[0], res[1]
        return None

    def run(self, s, start):
        code = self.code
        n = len(s)
        caps = [-1] * (2 * self.ngroups + 2)
        regs = [-1] * self.nregs
        trail = []
        stack = []
        pc = 0
        pos = start
        while True:
            ins = code[pc]
            op = ins[0]
            if op == "char":
                if pos < n and s[pos] == ins[1]:
                    pos += 1
                    pc += 1
                    continue
            elif op == "cls":
                if pos < n and ins[1][ord(s[pos])]:
                    pos += 1
                    pc += 1
                    continue
            elif op == "any":
                if pos < n:
                    pos += 1
                    pc += 1
                    continue
            elif op == "split":
                stack.append((ins[2], pos, len(trail)))
                pc = ins[1]
                continue
            elif op == "jmp":
                pc = ins[1]
                continue
            elif op == "save":
                trail.append((0, ins[1], caps[ins[1]]))
                caps[ins[1]] = pos
                pc += 1
                continue
            elif op == "mark":
                trail.append((1, ins[1], regs[ins[1]]))
                regs[ins[1]] = pos
                pc += 1
                continue
            elif op == "check":
                pc = ins[2] if pos != regs[ins[1]] else ins[3]
                continue
            elif op == "bol":
                if pos == 0:
                    pc += 1
                    continue
            elif op == "eol":
                if pos == n:
                    pc += 1
                    continue
            elif op == "match":
                return pos, caps
            # Failure: backtrack to the most recent choice point.
            self.backtracks += 1
            if self.budget is not None and self.backtracks > self.budget:
                raise BudgetExceeded()
            if not stack:
                return None
            pc, pos, tl = stack.pop()
            while len(trail) > tl:
                kind, idx, old = trail.pop()
                if kind == 0:
                    caps[idx] = old
                else:
                    regs[idx] = old


def format_result(rx, res):
    if res is None:
        return "no"
    start, end, caps = res
    parts = ["match %d %d" % (start, end)]
    for g in range(1, rx.ngroups + 1):
        a, b = caps[2 * g], caps[2 * g + 1]
        if a < 0 or b < 0:
            parts.append("-")
        else:
            parts.append("%d,%d" % (a, b))
    return "|".join(parts)


def main():
    data = sys.stdin.buffer.read().decode("utf-8")
    lines = data.split("\n")
    # A trailing newline produces one final empty element that is not a line.
    if lines and lines[-1] == "":
        lines.pop()
    li = 0
    npat = int(lines[li].strip())
    li += 1
    out = []
    for _ in range(npat):
        pattern = lines[li]
        li += 1
        m = int(lines[li].strip())
        li += 1
        rx = Regex(pattern)
        for _ in range(m):
            subject = lines[li] if li < len(lines) else ""
            li += 1
            out.append(format_result(rx, rx.search(subject)))
    sys.stdout.write("\n".join(out) + ("\n" if out else ""))


if __name__ == "__main__":
    main()
