"""A small ECMA-262 style regular-expression engine for membership tests.

Only the question "does the pattern match anywhere in this string?" is
answered.  Patterns are parsed into a syntax tree, compiled into a Thompson
NFA program (counted repetition is expanded) and run with a lock-step
simulation, so a search costs O(len(pattern) * len(subject)) and can never
backtrack exponentially.

Supported syntax: alternation, ``(...)`` / ``(?:...)`` grouping, the
quantifiers ``* + ? {n} {n,} {n,m}`` (optionally lazy, which makes no
difference for membership), ``.``, ``^``, ``$``, ``\\b``, ``\\B``, character
classes with ranges, ``\\d \\w \\s`` and their negations, and the usual
character escapes.  Matching is over Unicode code points, with no flags.
"""

from __future__ import annotations

from bisect import bisect_right
from typing import List, Optional, Tuple

__all__ = ["Pattern", "RegexError", "compile_pattern", "search"]


class RegexError(ValueError):
    """The pattern is malformed or uses unsupported syntax."""


# --------------------------------------------------------------------------
# Character sets
# --------------------------------------------------------------------------

_DIGIT = [(0x30, 0x39)]
_WORD = [(0x30, 0x39), (0x41, 0x5A), (0x5F, 0x5F), (0x61, 0x7A)]
_SPACE = [
    (0x09, 0x0D),
    (0x20, 0x20),
    (0xA0, 0xA0),
    (0x1680, 0x1680),
    (0x2000, 0x200A),
    (0x2028, 0x2029),
    (0x202F, 0x202F),
    (0x205F, 0x205F),
    (0x3000, 0x3000),
    (0xFEFF, 0xFEFF),
]
_MAX_CP = 0x10FFFF
_LINE_TERMINATORS = (0x0A, 0x0D, 0x2028, 0x2029)


def _normalize_ranges(ranges: List[Tuple[int, int]]) -> List[Tuple[int, int]]:
    out: List[Tuple[int, int]] = []
    for lo, hi in sorted(ranges):
        if out and lo <= out[-1][1] + 1:
            if hi > out[-1][1]:
                out[-1] = (out[-1][0], hi)
        else:
            out.append((lo, hi))
    return out


def _invert(ranges: List[Tuple[int, int]]) -> List[Tuple[int, int]]:
    out = []
    prev = 0
    for lo, hi in _normalize_ranges(ranges):
        if lo > prev:
            out.append((prev, lo - 1))
        prev = hi + 1
    if prev <= _MAX_CP:
        out.append((prev, _MAX_CP))
    return out


class CharSet:
    """An immutable set of code points with a fast membership test."""

    __slots__ = ("ranges", "_starts", "_ends", "_ascii")

    def __init__(self, ranges: List[Tuple[int, int]], negated: bool = False) -> None:
        ranges = _normalize_ranges(ranges)
        if negated:
            ranges = _invert(ranges)
        self.ranges = ranges
        self._starts = [lo for lo, _ in ranges]
        self._ends = [hi for _, hi in ranges]
        self._ascii = bytes(1 if self._lookup(c) else 0 for c in range(128))

    def _lookup(self, cp: int) -> bool:
        i = bisect_right(self._starts, cp) - 1
        return i >= 0 and cp <= self._ends[i]

    def __contains__(self, ch: str) -> bool:
        cp = ord(ch)
        if cp < 128:
            return self._ascii[cp] == 1
        return self._lookup(cp)


# --------------------------------------------------------------------------
# Syntax tree.  Nodes are tuples:
#   ("char", cp) ("set", CharSet) ("any",) ("bol",) ("eol",) ("wordb", bool)
#   ("cat", [nodes]) ("alt", [nodes]) ("rep", node, min, max|None)
# --------------------------------------------------------------------------

_Node = tuple


class _Parser:
    def __init__(self, pattern: str) -> None:
        self.src = pattern
        self.pos = 0
        self.n = len(pattern)

    def error(self, message: str) -> RegexError:
        return RegexError(f"{message} at offset {self.pos} in pattern {self.src!r}")

    def parse(self) -> _Node:
        node = self.parse_alternation()
        if self.pos < self.n:
            # Only an unmatched ")" can stop the alternation early.
            raise self.error("unmatched ')'")
        return node

    def parse_alternation(self) -> _Node:
        branches = [self.parse_concat()]
        while self.pos < self.n and self.src[self.pos] == "|":
            self.pos += 1
            branches.append(self.parse_concat())
        return branches[0] if len(branches) == 1 else ("alt", branches)

    def parse_concat(self) -> _Node:
        items: List[_Node] = []
        while self.pos < self.n and self.src[self.pos] not in "|)":
            items.append(self.parse_term())
        return ("cat", items)

    def parse_term(self) -> _Node:
        src = self.src
        ch = src[self.pos]
        if ch == "^":
            self.pos += 1
            return ("bol",)
        if ch == "$":
            self.pos += 1
            return ("eol",)
        if ch == "\\" and self.pos + 1 < self.n and src[self.pos + 1] in "bB":
            self.pos += 2
            return ("wordb", src[self.pos - 1] == "b")
        atom = self.parse_atom()
        return self.parse_quantifier(atom)

    def parse_quantifier(self, atom: _Node) -> _Node:
        src = self.src
        while self.pos < self.n:
            ch = src[self.pos]
            if ch == "*":
                lo, hi = 0, None
                self.pos += 1
            elif ch == "+":
                lo, hi = 1, None
                self.pos += 1
            elif ch == "?":
                lo, hi = 0, 1
                self.pos += 1
            elif ch == "{":
                braces = self.try_braces()
                if braces is None:
                    break
                lo, hi = braces
            else:
                break
            if self.pos < self.n and src[self.pos] == "?":
                self.pos += 1  # lazy: irrelevant for membership
            if atom[0] in ("bol", "eol", "wordb"):
                raise self.error("nothing to repeat")
            atom = ("rep", atom, lo, hi)
            # A quantified atom may not be quantified again in ECMA-262.
            if self.pos < self.n and src[self.pos] in "*+?":
                raise self.error("nothing to repeat")
            break
        return atom

    def try_braces(self) -> Optional[Tuple[int, Optional[int]]]:
        """Parse ``{n}``, ``{n,}`` or ``{n,m}`` at pos; None if not a quantifier."""
        src = self.src
        i = self.pos + 1
        j = i
        while j < self.n and src[j] in "0123456789":
            j += 1
        if j == i:
            return None
        lo = int(src[i:j])
        hi: Optional[int] = lo
        if j < self.n and src[j] == ",":
            j += 1
            k = j
            while k < self.n and src[k] in "0123456789":
                k += 1
            hi = int(src[j:k]) if k > j else None
            j = k
        if j >= self.n or src[j] != "}":
            return None
        if hi is not None and hi < lo:
            raise self.error("numbers out of order in {} quantifier")
        self.pos = j + 1
        return lo, hi

    def parse_atom(self) -> _Node:
        src = self.src
        ch = src[self.pos]
        if ch == "(":
            self.pos += 1
            if src.startswith("?", self.pos):
                if src.startswith("?:", self.pos):
                    self.pos += 2
                else:
                    raise self.error("unsupported group syntax")
            node = self.parse_alternation()
            if self.pos >= self.n or src[self.pos] != ")":
                raise self.error("missing ')'")
            self.pos += 1
            return node
        if ch == "[":
            return self.parse_class()
        if ch == ".":
            self.pos += 1
            return ("set", CharSet([(c, c) for c in _LINE_TERMINATORS], negated=True))
        if ch == "\\":
            return self.parse_escape(in_class=False)
        if ch in "*+?":
            raise self.error("nothing to repeat")
        self.pos += 1
        return ("char", ord(ch))

    def parse_escape(self, in_class: bool) -> _Node:
        """Parse an escape; returns ("char", cp) or ("set", CharSet)."""
        src = self.src
        self.pos += 1  # the backslash
        if self.pos >= self.n:
            raise self.error("pattern ends with a backslash")
        ch = src[self.pos]
        self.pos += 1
        if ch == "d":
            return ("set", CharSet(_DIGIT))
        if ch == "D":
            return ("set", CharSet(_DIGIT, negated=True))
        if ch == "w":
            return ("set", CharSet(_WORD))
        if ch == "W":
            return ("set", CharSet(_WORD, negated=True))
        if ch == "s":
            return ("set", CharSet(_SPACE))
        if ch == "S":
            return ("set", CharSet(_SPACE, negated=True))
        simple = {"n": 0x0A, "r": 0x0D, "t": 0x09, "f": 0x0C, "v": 0x0B}
        if ch in simple:
            return ("char", simple[ch])
        if ch == "b" and in_class:
            return ("char", 0x08)
        if ch == "0":
            if self.pos < self.n and src[self.pos] in "01234567":
                return ("char", self.parse_octal(0))
            return ("char", 0)
        if ch in "1234567":
            self.pos -= 1
            return ("char", self.parse_octal(0))
        if ch == "x":
            digits = src[self.pos : self.pos + 2]
            if len(digits) == 2 and all(c in _HEXDIGITS for c in digits):
                self.pos += 2
                return ("char", int(digits, 16))
            return ("char", ord("x"))
        if ch == "u":
            cp = self.parse_unicode_escape()
            if cp is not None:
                return ("char", cp)
            return ("char", ord("u"))
        if ch == "c":
            if self.pos < self.n and src[self.pos].isascii() and src[self.pos].isalpha():
                cp = ord(src[self.pos]) % 32
                self.pos += 1
                return ("char", cp)
            self.pos -= 1  # a lone backslash; the "c" is re-read as a literal
            return ("char", ord("\\"))
        return ("char", ord(ch))

    def parse_octal(self, value: int) -> int:
        src = self.src
        count = 0
        while self.pos < self.n and src[self.pos] in "01234567" and count < 3:
            nxt = value * 8 + int(src[self.pos])
            if nxt > 0o377:
                break
            value = nxt
            self.pos += 1
            count += 1
        return value

    def parse_unicode_escape(self) -> Optional[int]:
        src = self.src
        digits = src[self.pos : self.pos + 4]
        if len(digits) != 4 or any(c not in _HEXDIGITS for c in digits):
            return None
        self.pos += 4
        cp = int(digits, 16)
        if 0xD800 <= cp < 0xDC00 and src.startswith("\\u", self.pos):
            low_digits = src[self.pos + 2 : self.pos + 6]
            if len(low_digits) == 4 and all(c in _HEXDIGITS for c in low_digits):
                low = int(low_digits, 16)
                if 0xDC00 <= low < 0xE000:
                    self.pos += 6
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)
        return cp

    def parse_class(self) -> _Node:
        src = self.src
        self.pos += 1  # [
        negated = False
        if self.pos < self.n and src[self.pos] == "^":
            negated = True
            self.pos += 1
        ranges: List[Tuple[int, int]] = []
        while True:
            if self.pos >= self.n:
                raise self.error("unterminated character class")
            if src[self.pos] == "]":
                self.pos += 1
                break
            lo = self.parse_class_atom()
            if (
                self.pos + 1 < self.n
                and src[self.pos] == "-"
                and src[self.pos + 1] != "]"
            ):
                save = self.pos
                self.pos += 1
                hi = self.parse_class_atom()
                if lo[0] == "char" and hi[0] == "char":
                    if hi[1] < lo[1]:
                        raise self.error("range out of order in character class")
                    ranges.append((lo[1], hi[1]))
                    continue
                # A class escape on either side: "-" is a literal (Annex B).
                self.add_class_item(ranges, lo)
                ranges.append((0x2D, 0x2D))
                self.add_class_item(ranges, hi)
                continue
            self.add_class_item(ranges, lo)
        return ("set", CharSet(ranges, negated))

    @staticmethod
    def add_class_item(ranges: List[Tuple[int, int]], item: _Node) -> None:
        if item[0] == "char":
            ranges.append((item[1], item[1]))
        else:
            ranges.extend(item[1].ranges)

    def parse_class_atom(self) -> _Node:
        if self.src[self.pos] == "\\":
            return self.parse_escape(in_class=True)
        ch = self.src[self.pos]
        self.pos += 1
        return ("char", ord(ch))


_HEXDIGITS = frozenset("0123456789abcdefABCDEF")


# --------------------------------------------------------------------------
# Compilation to an NFA program
# --------------------------------------------------------------------------

_CHAR, _SET, _SPLIT, _JMP, _BOL, _EOL, _WORDB, _NWORDB, _MATCH = range(9)
_CONSUMING = (_CHAR, _SET)


class _Compiler:
    def __init__(self) -> None:
        self.ops: List[int] = []
        self.args: List[object] = []

    def emit(self, op: int, arg: object = None) -> int:
        self.ops.append(op)
        self.args.append(arg)
        return len(self.ops) - 1

    def gen(self, node: _Node) -> None:
        kind = node[0]
        if kind == "char":
            self.emit(_CHAR, chr(node[1]))
        elif kind == "set":
            self.emit(_SET, node[1])
        elif kind == "bol":
            self.emit(_BOL)
        elif kind == "eol":
            self.emit(_EOL)
        elif kind == "wordb":
            self.emit(_WORDB if node[1] else _NWORDB)
        elif kind == "cat":
            for child in node[1]:
                self.gen(child)
        elif kind == "alt":
            jumps = []
            branches = node[1]
            for index, child in enumerate(branches):
                if index < len(branches) - 1:
                    split = self.emit(_SPLIT)
                    self.gen(child)
                    jumps.append(self.emit(_JMP))
                    self.args[split] = (split + 1, len(self.ops))
                else:
                    self.gen(child)
            for j in jumps:
                self.args[j] = len(self.ops)
        elif kind == "rep":
            self.gen_repeat(node[1], node[2], node[3])
        else:  # pragma: no cover
            raise AssertionError(kind)

    def gen_repeat(self, child: _Node, lo: int, hi: Optional[int]) -> None:
        for _ in range(lo):
            self.gen(child)
        if hi is None:
            # child* : L1: split L2, L3; L2: child; jmp L1; L3:
            split = self.emit(_SPLIT)
            self.gen(child)
            self.emit(_JMP, split)
            self.args[split] = (split + 1, len(self.ops))
        else:
            # (child (child (child)?)?)? : every optional copy skips to the end.
            splits = []
            for _ in range(hi - lo):
                splits.append(self.emit(_SPLIT))
                self.gen(child)
            for s in splits:
                self.args[s] = (s + 1, len(self.ops))


def _is_word(ch: str) -> bool:
    return ch.isascii() and (ch.isalnum() or ch == "_")


def _anchored_start(node: _Node) -> bool:
    """True when every match must begin at position 0."""
    kind = node[0]
    if kind == "bol":
        return True
    if kind == "cat":
        return bool(node[1]) and _anchored_start(node[1][0])
    if kind == "alt":
        return all(_anchored_start(c) for c in node[1])
    return False


def _literal_form(node: _Node) -> Optional[Tuple[bool, str, bool]]:
    """If the pattern is ``^? literal $?`` return (bol, literal, eol)."""
    if node[0] != "cat":
        return None
    items = list(node[1])
    bol = bool(items) and items[0][0] == "bol"
    if bol:
        items.pop(0)
    eol = bool(items) and items[-1][0] == "eol"
    if eol:
        items.pop()
    if any(item[0] != "char" for item in items):
        return None
    return bol, "".join(chr(item[1]) for item in items), eol


class Pattern:
    """A compiled regular expression.  Create it with :func:`compile_pattern`."""

    __slots__ = ("source", "_literal", "_ops", "_args", "_anchored", "_memo")

    def __init__(self, source: str) -> None:
        self.source = source
        tree = _Parser(source).parse()
        self._literal = _literal_form(tree)
        comp = _Compiler()
        comp.gen(tree)
        comp.emit(_MATCH)
        self._ops = comp.ops
        self._args = comp.args
        self._anchored = _anchored_start(tree)
        self._memo: dict = {}

    def search(self, text: str) -> bool:
        """True when the pattern matches somewhere in *text*."""
        lit = self._literal
        if lit is not None:
            bol, body, eol = lit
            if bol and eol:
                return text == body
            if bol:
                return text.startswith(body)
            if eol:
                return text.endswith(body)
            return body in text
        return self._simulate(text)

    def search_cached(self, text: str) -> bool:
        """Like :meth:`search`, but remembers answers (bounded), for patterns
        applied repeatedly to the same member names."""
        memo = self._memo
        try:
            return memo[text]
        except KeyError:
            if len(memo) >= 50_000:
                memo.clear()
            result = memo[text] = self.search(text)
            return result

    def _simulate(self, text: str) -> bool:
        ops, args = self._ops, self._args
        n = len(text)
        size = len(ops)
        seen = [-1] * size
        anchored = self._anchored
        seeds: List[int] = []
        for i in range(n + 1):
            if i == 0 or not anchored:
                seeds.append(0)
            elif not seeds:
                return False
            # --- epsilon closure at position i
            prev_word = i > 0 and _is_word(text[i - 1])
            next_word = i < n and _is_word(text[i])
            threads: List[int] = []
            stack = seeds
            while stack:
                pc = stack.pop()
                if seen[pc] == i:
                    continue
                seen[pc] = i
                op = ops[pc]
                if op == _CHAR or op == _SET:
                    threads.append(pc)
                elif op == _SPLIT:
                    a, b = args[pc]
                    stack.append(b)
                    stack.append(a)
                elif op == _JMP:
                    stack.append(args[pc])
                elif op == _MATCH:
                    return True
                elif op == _BOL:
                    if i == 0:
                        stack.append(pc + 1)
                elif op == _EOL:
                    if i == n:
                        stack.append(pc + 1)
                elif op == _WORDB:
                    if prev_word != next_word:
                        stack.append(pc + 1)
                else:  # _NWORDB
                    if prev_word == next_word:
                        stack.append(pc + 1)
            if i == n:
                return False
            ch = text[i]
            seeds = []
            for pc in threads:
                if ops[pc] == _CHAR:
                    if args[pc] == ch:
                        seeds.append(pc + 1)
                elif ch in args[pc]:
                    seeds.append(pc + 1)
        return False


_cache: dict = {}


def compile_pattern(source: str) -> Pattern:
    """Compile *source*, caching the result.  Raises :class:`RegexError`."""
    pattern = _cache.get(source)
    if pattern is None:
        pattern = _cache[source] = Pattern(source)
    return pattern


def search(source: str, text: str) -> bool:
    """Convenience: does *source* match anywhere in *text*?"""
    return compile_pattern(source).search(text)
