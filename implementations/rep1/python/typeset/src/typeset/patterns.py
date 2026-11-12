"""Liang hyphenation pattern files (``.chp``) and the hyphenation algorithm."""

from __future__ import annotations

import os

from .fonts import _clean_lines


class PatternSet:
    """A set of Liang patterns and explicit exceptions."""

    def __init__(self, left: int = 2, right: int = 3) -> None:
        self.left = left
        self.right = right
        self.patterns: dict[str, tuple[int, ...]] = {}
        self.exceptions: dict[str, tuple[int, ...]] = {}
        self.max_key = 0
        self._cache: dict[str, tuple[int, ...]] = {}

    def add_pattern(self, text: str) -> None:
        key: list[str] = []
        vals = [0]
        for ch in text:
            if "0" <= ch <= "9":
                vals[len(key)] = int(ch)
            else:
                key.append(ch)
                vals.append(0)
        k = "".join(key)
        self.patterns[k] = tuple(vals)
        self.max_key = max(self.max_key, len(k))

    def add_exception(self, text: str) -> None:
        positions = []
        letters = 0
        for ch in text:
            if ch == "-":
                positions.append(letters)
            else:
                letters += 1
        self.exceptions[text.replace("-", "")] = tuple(positions)

    def breaks(self, word: str) -> tuple[int, ...]:
        """Break positions ``q`` ("after q letters") of a lowercase *word*."""
        hit = self._cache.get(word)
        if hit is not None:
            return hit
        n = len(word)
        lo, hi = self.left, n - self.right
        exc = self.exceptions.get(word)
        if exc is not None:
            result = tuple(q for q in exc if lo <= q <= hi)
        else:
            t = "." + word + "."
            v = [0] * (n + 3)
            pats = self.patterns
            maxk = self.max_key
            for i in range(n + 2):
                for j in range(i + 1, min(n + 2, i + maxk) + 1):
                    vals = pats.get(t[i:j])
                    if vals is not None:
                        for k, x in enumerate(vals):
                            if x > v[i + k]:
                                v[i + k] = x
            result = tuple(q for q in range(max(1, lo), min(n - 1, hi) + 1) if v[1 + q] & 1)
        self._cache[word] = result
        return result


def parse_patterns(text: str) -> PatternSet:
    """Parse the contents of a ``.chp`` file."""
    ps = PatternSet()
    for rec in _clean_lines(text):
        key = rec[0]
        if key == "left":
            ps.left = int(rec[1])
        elif key == "right":
            ps.right = int(rec[1])
        elif key == "pattern":
            ps.add_pattern(rec[1])
        elif key == "exception":
            ps.add_exception(rec[1])
    return ps


class PatternLibrary:
    """Loads pattern sets lazily from ``<data_dir>/hyphen/<set>.chp``."""

    def __init__(self, data_dir: str = "data") -> None:
        self.data_dir = data_dir
        self._sets: dict[str, PatternSet] = {}

    def get(self, name: str) -> PatternSet:
        ps = self._sets.get(name)
        if ps is None:
            path = os.path.join(self.data_dir, "hyphen", name + ".chp")
            with open(path, "rb") as fh:
                ps = parse_patterns(fh.read().decode("utf-8"))
            self._sets[name] = ps
        return ps
