"""Font metric (.cfm) and hyphenation pattern (.chp) files.

Both formats share the same line rules: everything from the first '#' is
dropped, the remainder is trimmed, and empty lines are skipped.
"""

import os

def records(path):
    """Yield the whitespace-split fields of every content line of a data file."""
    with open(path, "r", encoding="utf-8") as fh:
        text = fh.read()
    for line in text.split("\n"):
        hash_at = line.find("#")
        if hash_at >= 0:
            line = line[:hash_at]
        line = line.strip(" \t")
        if not line:
            continue
        yield line.split()


def fdiv(a, b):
    """Floor division; Python's // already rounds towards negative infinity."""
    return a // b


def scale(units, size):
    """Convert a glyph-space quantity to millipoints at the given size."""
    return fdiv(units * size, 1000)


class Face:
    """One .cfm file: vertical metrics, inter-word glue and glyph advances."""

    def __init__(self, name):
        self.name = name
        self.ascent = 0
        self.descent = 0
        self.space = 0
        self.stretch = 0
        self.shrink = 0
        self.extra = 0
        self.default = 0
        self.adv = {}
        self.kern = {}

    def text_units(self, text):
        """Glyph-space width of a run: advances plus the kerns of adjacent pairs."""
        total = 0
        prev = -1
        for ch in text:
            cp = ord(ch)
            if prev >= 0:
                total += self.kern.get((prev, cp), 0)
            total += self.adv.get(cp, self.default)
            prev = cp
        return total

    def text_width(self, text, size):
        return scale(self.text_units(text), size)


def load_face(data_dir, name):
    face = Face(name)
    for fields in records(os.path.join(data_dir, "faces", name + ".cfm")):
        kind = fields[0]
        if kind == "glyph":
            face.adv[int(fields[1])] = int(fields[2])
        elif kind == "kern":
            face.kern[(int(fields[1]), int(fields[2]))] = int(fields[3])
        elif kind == "space":
            face.space = int(fields[1])
            face.stretch = int(fields[2])
            face.shrink = int(fields[3])
        elif kind == "ascent":
            face.ascent = int(fields[1])
        elif kind == "descent":
            face.descent = int(fields[1])
        elif kind == "extra":
            face.extra = int(fields[1])
        elif kind == "default":
            face.default = int(fields[1])
    return face


class PatternSet:
    """Liang patterns plus explicit exceptions, keyed by the pattern key."""

    def __init__(self, name):
        self.name = name
        self.left = 0
        self.right = 0
        self.patterns = {}
        self.exceptions = {}
        self.max_key = 0


def parse_pattern(text):
    """Split a Liang pattern into its key and its m+1 inter-letter values."""
    key = []
    values = [0]
    for ch in text:
        if ch.isdigit():
            values[-1] = int(ch)
        else:
            key.append(ch)
            values.append(0)
    return "".join(key), values


def load_patterns(data_dir, name):
    pset = PatternSet(name)
    for fields in records(os.path.join(data_dir, "hyphen", name + ".chp")):
        kind = fields[0]
        if kind == "pattern":
            key, values = parse_pattern(fields[1])
            pset.patterns[key] = values
            pset.max_key = max(pset.max_key, len(key))
        elif kind == "exception":
            word = fields[1]
            key = word.replace("-", "")
            breaks = []
            count = 0
            for ch in word:
                if ch == "-":
                    breaks.append(count)
                else:
                    count += 1
            pset.exceptions[key] = breaks
        elif kind == "left":
            pset.left = int(fields[1])
        elif kind == "right":
            pset.right = int(fields[1])
    return pset


class Metrics:
    """Lazily loaded face and pattern tables, read relative to the cwd."""

    def __init__(self, data_dir="data"):
        self.data_dir = data_dir
        self._faces = {}
        self._patterns = {}

    def face(self, name):
        face = self._faces.get(name)
        if face is None:
            face = load_face(self.data_dir, name)
            self._faces[name] = face
        return face

    def patterns(self, name):
        pset = self._patterns.get(name)
        if pset is None:
            pset = load_patterns(self.data_dir, name)
            self._patterns[name] = pset
        return pset


def face_name(family, bold, italic):
    """Resolve a (family, bold, italic) style triple to a face name."""
    if family == "mono":
        return "mono"
    suffix = ""
    if bold:
        suffix += "-bold"
    if italic:
        suffix += "-italic"
    return family + suffix


ROMAN_PAIRS = [
    (1000, "m"), (900, "cm"), (500, "d"), (400, "cd"),
    (100, "c"), (90, "xc"), (50, "l"), (40, "xl"),
    (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
]


def roman(n):
    """Lowercase roman numeral by greedy subtraction over the standard pairs."""
    out = []
    for value, text in ROMAN_PAIRS:
        while n >= value:
            out.append(text)
            n -= value
    return "".join(out)


def alpha_label(n):
    """Bijective base-26 lowercase label: 1 is 'a', 27 is 'aa'."""
    out = []
    while n > 0:
        n, rem = divmod(n - 1, 26)
        out.append(chr(ord("a") + rem))
    return "".join(reversed(out))
