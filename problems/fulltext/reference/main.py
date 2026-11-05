#!/usr/bin/env python3
"""Reference implementation of the `fulltext` problem.

Usage: main.py <input directory> <output directory>

Builds a positional inverted index over <input>/docs/*.txt, evaluates the
queries in <input>/queries.txt and writes <output>/results.txt and
<output>/stats.txt.  See SPEC.md for the exact contract.
"""
import array
import math
import os
import re
import sys

# ---------------------------------------------------------------------------
# Porter stemmer (1980), with the two departures of the canonical porter.c:
# step 2 maps "bli" to "ble" rather than "abli" to "able", and adds
# "logi" -> "log".
# ---------------------------------------------------------------------------


def porter_stem(word):
    b = word
    k = len(b) - 1
    if k <= 1:
        return b
    j = k

    def cons(i):
        c = b[i]
        if c in "aeiou":
            return False
        if c == "y":
            return i == 0 or not cons(i - 1)
        return True

    def measure():
        """Number of vowel-consonant sequences in b[0..j]."""
        n = 0
        i = 0
        while True:
            if i > j:
                return n
            if not cons(i):
                break
            i += 1
        i += 1
        while True:
            while True:
                if i > j:
                    return n
                if cons(i):
                    break
                i += 1
            i += 1
            n += 1
            while True:
                if i > j:
                    return n
                if not cons(i):
                    break
                i += 1
            i += 1

    def vowel_in_stem():
        for i in range(j + 1):
            if not cons(i):
                return True
        return False

    def doublec(i):
        return i >= 1 and b[i] == b[i - 1] and cons(i)

    def cvc(i):
        if i < 2 or not cons(i) or cons(i - 1) or not cons(i - 2):
            return False
        return b[i] not in "wxy"

    def ends(s):
        """Set j to the end of the stem and return True when b ends with s."""
        nonlocal j
        n = len(s)
        if n > k + 1:
            return False
        if b[k - n + 1:k + 1] != s:
            return False
        j = k - n
        return True

    def setto(s):
        nonlocal b, k
        b = b[:j + 1] + s
        k = j + len(s)

    def r(s):
        if measure() > 0:
            setto(s)

    # Step 1a: plural suffixes.
    if b[k] == "s":
        if ends("sses"):
            k -= 2
        elif ends("ies"):
            setto("i")
        elif b[k - 1] != "s":
            k -= 1

    # Step 1b: past participles and gerunds.
    if ends("eed"):
        if measure() > 0:
            k -= 1
    elif (ends("ed") or ends("ing")) and vowel_in_stem():
        k = j
        if ends("at"):
            setto("ate")
        elif ends("bl"):
            setto("ble")
        elif ends("iz"):
            setto("ize")
        elif doublec(k):
            k -= 1
            if b[k] in "lsz":
                k += 1
        elif measure() == 1 and cvc(k):
            setto("e")

    # Step 1c: terminal y to i.
    if ends("y") and vowel_in_stem():
        b = b[:k] + "i"

    # Step 2: double suffixes.
    if k >= 1:
        ch = b[k - 1]
        if ch == "a":
            if ends("ational"):
                r("ate")
            elif ends("tional"):
                r("tion")
        elif ch == "c":
            if ends("enci"):
                r("ence")
            elif ends("anci"):
                r("ance")
        elif ch == "e":
            if ends("izer"):
                r("ize")
        elif ch == "l":
            if ends("bli"):
                r("ble")
            elif ends("alli"):
                r("al")
            elif ends("entli"):
                r("ent")
            elif ends("eli"):
                r("e")
            elif ends("ousli"):
                r("ous")
        elif ch == "o":
            if ends("ization"):
                r("ize")
            elif ends("ation"):
                r("ate")
            elif ends("ator"):
                r("ate")
        elif ch == "s":
            if ends("alism"):
                r("al")
            elif ends("iveness"):
                r("ive")
            elif ends("fulness"):
                r("ful")
            elif ends("ousness"):
                r("ous")
        elif ch == "t":
            if ends("aliti"):
                r("al")
            elif ends("iviti"):
                r("ive")
            elif ends("biliti"):
                r("ble")
        elif ch == "g":
            if ends("logi"):
                r("log")

    # Step 3: more suffixes.
    ch = b[k]
    if ch == "e":
        if ends("icate"):
            r("ic")
        elif ends("ative"):
            r("")
        elif ends("alize"):
            r("al")
    elif ch == "i":
        if ends("iciti"):
            r("ic")
    elif ch == "l":
        if ends("ical"):
            r("ic")
        elif ends("ful"):
            r("")
    elif ch == "s":
        if ends("ness"):
            r("")

    # Step 4: residual suffixes on stems of measure greater than one.
    if k >= 1:
        ch = b[k - 1]
        hit = False
        if ch == "a":
            hit = ends("al")
        elif ch == "c":
            hit = ends("ance") or ends("ence")
        elif ch == "e":
            hit = ends("er")
        elif ch == "i":
            hit = ends("ic")
        elif ch == "l":
            hit = ends("able") or ends("ible")
        elif ch == "n":
            hit = ends("ant") or ends("ement") or ends("ment") or ends("ent")
        elif ch == "o":
            hit = (ends("ion") and j >= 0 and b[j] in "st") or ends("ou")
        elif ch == "s":
            hit = ends("ism")
        elif ch == "t":
            hit = ends("ate") or ends("iti")
        elif ch == "u":
            hit = ends("ous")
        elif ch == "v":
            hit = ends("ive")
        elif ch == "z":
            hit = ends("ize")
        if hit and measure() > 1:
            k = j

    # Step 5: terminal e and doubled l.
    j = k
    if b[k] == "e":
        a = measure()
        if a > 1 or (a == 1 and not cvc(k - 1)):
            k -= 1
    if b[k] == "l" and doublec(k) and measure() > 1:
        k -= 1
    return b[:k + 1]


# ---------------------------------------------------------------------------
# Analysis
# ---------------------------------------------------------------------------

TOKEN_CHARS = (
    "0-9A-Za-z"
    "À-ÖØ-öø-ɏ"
    "Ͱ-ϿЀ-ӿ"
)
TOKEN_RE = re.compile("[%s]+(?:['’][%s]+)*" % (TOKEN_CHARS, TOKEN_CHARS))
APOSTROPHES = str.maketrans("", "", "'’")
ASCII_LOWER = re.compile(r"\A[a-z]+\Z")
WHITESPACE = "\t\n\v\f\r  "
WS_RUN = re.compile("[%s]+" % re.escape(WHITESPACE))

STOP_WORDS = frozenset("""
a an and are as at be but by for if in into is it no not of on or such
that the their then there these they this to was will with
""".split())

_ANALYSIS_CACHE = {}


def analyze_token(raw):
    """Return (token, term) for one raw token as it appears in the text."""
    token = raw.translate(APOSTROPHES).lower() if raw.isascii() else _fold(raw)
    term = porter_stem(token) if ASCII_LOWER.match(token) else token
    return token, term


def _fold(raw):
    """Lowercase ASCII letters only and drop apostrophes."""
    out = []
    for ch in raw:
        if ch in "'’":
            continue
        if "A" <= ch <= "Z":
            out.append(chr(ord(ch) + 32))
        else:
            out.append(ch)
    return "".join(out)


def analyze(text):
    """Return the list of (token, term) pairs of a text, in order."""
    cache = _ANALYSIS_CACHE
    out = []
    append = out.append
    for m in TOKEN_RE.finditer(text):
        raw = m.group()
        pair = cache.get(raw)
        if pair is None:
            pair = cache[raw] = analyze_token(raw)
        append(pair)
    return out


def token_spans(text):
    """Return the (start, end) character offsets of every token of a text."""
    starts = array.array("l")
    ends = array.array("l")
    for m in TOKEN_RE.finditer(text):
        starts.append(m.start())
        ends.append(m.end())
    return starts, ends


# ---------------------------------------------------------------------------
# Index
# ---------------------------------------------------------------------------

class Index:
    def __init__(self):
        self.doc_ids = []            # sorted document ids
        self.texts = {}              # id -> original text
        self.lengths = {}            # id -> token count
        self.postings = {}           # term -> {doc id: [positions]}
        self.total_tokens = 0
        self._spans = {}             # id -> token (start, end) offsets

    def spans(self, doc_id):
        s = self._spans.get(doc_id)
        if s is None:
            s = self._spans[doc_id] = token_spans(self.texts[doc_id])
        return s

    def add(self, doc_id, text):
        pairs = analyze(text)
        local = {}
        for pos, (_token, term) in enumerate(pairs):
            lst = local.get(term)
            if lst is None:
                local[term] = [pos]
            else:
                lst.append(pos)
        postings = self.postings
        for term, positions in local.items():
            docs = postings.get(term)
            if docs is None:
                postings[term] = {doc_id: positions}
            else:
                docs[doc_id] = positions
        self.doc_ids.append(doc_id)
        self.texts[doc_id] = text
        self.lengths[doc_id] = len(pairs)
        self.total_tokens += len(pairs)

    def finish(self):
        self.doc_ids.sort()
        self.all_docs = set(self.doc_ids)
        n = len(self.doc_ids)
        self.avgdl = self.total_tokens / n if n else 0.0

    def positions(self, term, doc_id):
        docs = self.postings.get(term)
        if docs is None:
            return None
        return docs.get(doc_id)


# ---------------------------------------------------------------------------
# Query parsing
# ---------------------------------------------------------------------------

class Atom:
    """A sequence of one or more terms that must occur consecutively."""

    __slots__ = ("terms",)

    def __init__(self, terms):
        self.terms = tuple(terms)


def lex_query(text):
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c in WHITESPACE:
            i += 1
        elif c == "(" or c == ")":
            out.append((c, None))
            i += 1
        elif c == '"':
            j = text.find('"', i + 1)
            if j < 0:
                body, i = text[i + 1:], n
            else:
                body, i = text[i + 1:j], j + 1
            out.append(("phrase", body))
        else:
            j = i
            while j < n and text[j] not in WHITESPACE and text[j] not in '()"':
                j += 1
            word, i = text[i:j], j
            if word in ("AND", "OR", "NOT"):
                out.append(("op", word))
            else:
                out.append(("phrase", word))
    return out


def make_atom(source):
    """Analyse a phrase body or bare word into an atom, or None if empty."""
    pairs = analyze(source)
    if not pairs:
        return None
    if len(pairs) == 1 and pairs[0][0] in STOP_WORDS:
        return None
    return Atom([term for _token, term in pairs])


class Parser:
    def __init__(self, tokens):
        self.toks = tokens
        self.i = 0

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else None

    def parse(self):
        node = self.parse_or()
        while self.peek() is not None:      # stray ')' tokens
            self.i += 1
        return node

    def parse_or(self):
        nodes = []
        first = self.parse_and()
        if first is not None:
            nodes.append(first)
        while True:
            t = self.peek()
            if t is not None and t[0] == "op" and t[1] == "OR":
                self.i += 1
                nxt = self.parse_and()
                if nxt is not None:
                    nodes.append(nxt)
            else:
                break
        return combine("or", nodes)

    def parse_and(self):
        nodes = []
        while True:
            t = self.peek()
            if t is None or t[0] == ")":
                break
            if t[0] == "op":
                if t[1] == "OR":
                    break
                if t[1] == "AND":
                    self.i += 1
                    continue
            node = self.parse_not()
            if node is not None:
                nodes.append(node)
        return combine("and", nodes)

    def parse_not(self):
        negations = 0
        while True:
            t = self.peek()
            if t is not None and t[0] == "op" and t[1] == "NOT":
                self.i += 1
                negations += 1
            else:
                break
        node = self.parse_primary()
        if node is None:
            return None
        for _ in range(negations):
            node = ("not", node)
        return node

    def parse_primary(self):
        t = self.peek()
        if t is None:
            return None
        if t[0] == "(":
            self.i += 1
            node = self.parse_or()
            nxt = self.peek()
            if nxt is not None and nxt[0] == ")":
                self.i += 1
            return node
        if t[0] == ")":
            return None
        if t[0] == "phrase":
            self.i += 1
            atom = make_atom(t[1])
            return ("atom", atom) if atom is not None else None
        self.i += 1                          # a stray operator
        return None


def combine(kind, nodes):
    if not nodes:
        return None
    if len(nodes) == 1:
        return nodes[0]
    return (kind, nodes)


def parse_query(text):
    return Parser(lex_query(text)).parse()


def positive_atoms(node):
    """Atoms under an even number of NOTs, in order of first appearance."""
    seen = {}
    order = []

    def walk(n, negated):
        if n is None:
            return
        kind = n[0]
        if kind == "atom":
            if not negated:
                key = n[1].terms
                if key not in seen:
                    seen[key] = True
                    order.append(n[1])
        elif kind == "not":
            walk(n[1], not negated)
        else:
            for child in n[1]:
                walk(child, negated)

    walk(node, False)
    return order


# ---------------------------------------------------------------------------
# Matching and scoring
# ---------------------------------------------------------------------------

def atom_occurrences(index, atom, doc_id):
    """Return the sorted start positions of the atom's occurrences in a doc."""
    terms = atom.terms
    first = index.positions(terms[0], doc_id)
    if not first:
        return []
    if len(terms) == 1:
        return first
    sets = []
    for t in terms[1:]:
        p = index.positions(t, doc_id)
        if not p:
            return []
        sets.append(set(p))
    out = []
    for start in first:
        ok = True
        for offset, s in enumerate(sets, 1):
            if start + offset not in s:
                ok = False
                break
        if ok:
            out.append(start)
    return out


def atom_frequencies(index, atom):
    """Return {doc id: occurrence count} for every document containing atom."""
    terms = atom.terms
    docs = index.postings.get(terms[0])
    if not docs:
        return {}
    candidates = set(docs)
    for t in terms[1:]:
        other = index.postings.get(t)
        if not other:
            return {}
        candidates &= set(other)
        if not candidates:
            return {}
    freqs = {}
    for doc_id in candidates:
        n = len(atom_occurrences(index, atom, doc_id))
        if n:
            freqs[doc_id] = n
    return freqs


def evaluate(node, index, freq_cache):
    if node is None:
        return set()
    kind = node[0]
    if kind == "atom":
        return set(atom_freqs(index, node[1], freq_cache))
    if kind == "not":
        return index.all_docs - evaluate(node[1], index, freq_cache)
    if kind == "and":
        result = None
        for child in node[1]:
            s = evaluate(child, index, freq_cache)
            result = s if result is None else (result & s)
        return result if result is not None else set()
    result = set()
    for child in node[1]:
        result |= evaluate(child, index, freq_cache)
    return result


def atom_freqs(index, atom, cache):
    key = atom.terms
    f = cache.get(key)
    if f is None:
        f = cache[key] = atom_frequencies(index, atom)
    return f


K1 = 1.2
B = 0.75


def idf(n_docs, df):
    return math.log((n_docs - df + 0.5) / (df + 0.5) + 1.0)


def score_documents(index, atoms, docs, freq_cache):
    n = len(index.doc_ids)
    scores = {d: 0.0 for d in docs}
    avgdl = index.avgdl
    for atom in atoms:
        freqs = atom_freqs(index, atom, freq_cache)
        if not freqs:
            continue
        weight = idf(n, len(freqs))
        for doc_id in docs:
            f = freqs.get(doc_id)
            if not f:
                continue
            norm = 1.0 - B + B * (index.lengths[doc_id] / avgdl if avgdl else 0.0)
            scores[doc_id] += weight * (f * (K1 + 1.0)) / (f + K1 * norm)
    return scores


# ---------------------------------------------------------------------------
# Snippets
# ---------------------------------------------------------------------------

WINDOW = 30


def best_window(length, occurrences):
    """Index of the best snippet window.

    `occurrences` maps an atom index to the sorted start positions of its
    occurrences, paired with the atom's term count.  A window [s, s+W-1] is
    ranked by the number of distinct atoms with an occurrence fully inside
    it, then by the total number of such occurrences, then by earliest s.
    """
    if length <= WINDOW or not occurrences:
        return 0
    last = length - WINDOW
    atom_hits = [0] * (last + 2)
    total = [0] * (last + 2)
    for starts, span in occurrences:
        merged = []
        for p in starts:
            lo = p + span - WINDOW
            if lo < 0:
                lo = 0
            hi = p if p < last else last
            if lo > hi:
                continue
            total[lo] += 1
            total[hi + 1] -= 1
            if merged and lo <= merged[-1][1] + 1:
                if hi > merged[-1][1]:
                    merged[-1][1] = hi
            else:
                merged.append([lo, hi])
        for lo, hi in merged:
            atom_hits[lo] += 1
            atom_hits[hi + 1] -= 1
    best_start, best_key = 0, (-1, -1)
    a = t = 0
    for s in range(last + 1):
        a += atom_hits[s]
        t += total[s]
        if (a, t) > best_key:
            best_key = (a, t)
            best_start = s
    return best_start


def snippet(index, atoms, doc_id):
    length = index.lengths[doc_id]
    if length == 0:
        return ""
    occurrences = []
    for atom in atoms:
        starts = atom_occurrences(index, atom, doc_id)
        if starts:
            occurrences.append((starts, len(atom.terms)))
    start_index = best_window(length, occurrences)
    starts, ends = index.spans(doc_id)
    lo = starts[start_index]
    hi = ends[min(start_index + WINDOW, length) - 1]
    return WS_RUN.sub(" ", index.texts[doc_id][lo:hi]).strip(" ")


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def read_documents(docs_dir):
    docs = []
    if not os.path.isdir(docs_dir):
        return docs
    for name in sorted(os.listdir(docs_dir)):
        path = os.path.join(docs_dir, name)
        if not name.endswith(".txt") or not os.path.isfile(path):
            continue
        with open(path, "r", encoding="utf-8", newline="") as f:
            text = f.read()
        docs.append((name[:-4], text))
    return docs


K_DIRECTIVE = re.compile(r"\A%k[ \t]+([0-9]+)[ \t]*\Z")


def read_queries(path):
    """Return a list of (k, raw query text)."""
    out = []
    k = 10
    if not os.path.isfile(path):
        return out
    with open(path, "r", encoding="utf-8", newline="") as f:
        data = f.read()
    if data.endswith("\n"):
        data = data[:-1]
    for line in data.split("\n"):
        line = line.rstrip("\r")
        stripped = line.strip("".join(WHITESPACE))
        if not stripped:
            continue
        if stripped.startswith("#"):
            continue
        m = K_DIRECTIVE.match(stripped)
        if m:
            k = int(m.group(1))
            continue
        out.append((k, stripped))
    return out


def run(input_dir, output_dir):
    index = Index()
    for doc_id, text in read_documents(os.path.join(input_dir, "docs")):
        index.add(doc_id, text)
    index.finish()

    queries = read_queries(os.path.join(input_dir, "queries.txt"))
    lines = []
    for number, (k, text) in enumerate(queries, 1):
        node = parse_query(text)
        freq_cache = {}
        matched = evaluate(node, index, freq_cache)
        atoms = positive_atoms(node)
        scores = score_documents(index, atoms, matched, freq_cache)
        ranked = sorted(matched, key=lambda d: (-scores[d], d))[:k]
        lines.append("QUERY %d %s" % (number, text))
        lines.append("HITS %d" % len(ranked))
        for rank, doc_id in enumerate(ranked, 1):
            lines.append("%d\t%s\t%.4f\t%s"
                         % (rank, doc_id, scores[doc_id], snippet(index, atoms, doc_id)))

    os.makedirs(output_dir, exist_ok=True)
    write(os.path.join(output_dir, "results.txt"), "\n".join(lines) + ("\n" if lines else ""))
    n = len(index.doc_ids)
    stats = [
        "documents %d" % n,
        "tokens %d" % index.total_tokens,
        "terms %d" % len(index.postings),
        "avgdl %.4f" % index.avgdl,
    ]
    write(os.path.join(output_dir, "stats.txt"), "\n".join(stats) + "\n")


def write(path, data):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(data)


def main(argv):
    if len(argv) != 3:
        print("usage: main.py <input dir> <output dir>", file=sys.stderr)
        return 2
    sys.setrecursionlimit(10000)
    run(argv[1], argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
