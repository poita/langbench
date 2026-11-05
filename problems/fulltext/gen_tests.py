#!/usr/bin/env python3
"""Generates tests/NNN_name/{input,expected} for the `fulltext` problem.

Every corpus is either an embedded literal, a deterministic construction from
a fixed pseudo-random sequence, or a slice of a vendored public-domain text in
corpus/, so re-running this script reproduces the suite byte for byte.

Expected outputs come from reference/main.py and are checked three ways
before they are written, any disagreement aborting the run:

  * the Porter stemmer is run over the official test vocabulary
    (corpus/porter/voc.txt) and must reproduce corpus/porter/output.txt
    word for word;
  * an independent implementation of everything else in this file --- a
    character-by-character tokeniser, a shunting-yard query parser, a
    brute-force positional matcher, a straight transcription of the BM25
    formula and a candidate-based snippet search --- recomputes results.txt
    and stats.txt from the same input and must produce the same bytes;
  * consecutive scores in every ranking are either bit-identical or more
    than 1e-9 apart, and the same holds across the top-k cut, so no ranking
    can be reordered by a one-ulp difference in another implementation's
    logarithm or division.

    python3 gen_tests.py
"""
import bisect
import math
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
CORPUS = os.path.join(HERE, "corpus")

sys.path.insert(0, os.path.join(HERE, "reference"))
import main as ref  # noqa: E402


# ---------------------------------------------------------------------------
# Independent implementation used as a cross-check
# ---------------------------------------------------------------------------

TOKEN_RANGES = ((0x30, 0x39), (0x41, 0x5A), (0x61, 0x7A), (0xC0, 0xD6),
                (0xD8, 0xF6), (0xF8, 0x24F), (0x370, 0x3FF), (0x400, 0x4FF))
WS = "\t\n\v\f\r  "
APOS = "'’"
STOPS = set("""a an and are as at be but by for if in into is it no not of on or
such that the their then there these they this to was will with""".split())
K1, B, WINDOW = 1.2, 0.75, 30


_CLASS = {}


def is_token_char(ch):
    known = _CLASS.get(ch)
    if known is None:
        cp = ord(ch)
        known = False
        for lo, hi in TOKEN_RANGES:
            if lo <= cp <= hi:
                known = True
                break
        _CLASS[ch] = known
    return known


def scan(text):
    """Tokenise by hand: maximal runs of token characters, apostrophes inside."""
    out = []
    i, n = 0, len(text)
    while i < n:
        if not is_token_char(text[i]):
            i += 1
            continue
        j = i + 1
        while j < n:
            if is_token_char(text[j]):
                j += 1
            elif text[j] in APOS and j + 1 < n and is_token_char(text[j + 1]):
                j += 1
            else:
                break
        out.append((text[i:j], i, j))
        i = j
    return out


def fold(raw):
    chars = []
    for ch in raw:
        if ch in APOS:
            continue
        chars.append(chr(ord(ch) + 32) if "A" <= ch <= "Z" else ch)
    return "".join(chars)


def to_term(token):
    for ch in token:
        if not ("a" <= ch <= "z"):
            return token
    return ref.porter_stem(token) if token else token


_WORDS = {}


def analyse(text):
    """Return (terms, tokens, starts, ends) for a document or query fragment."""
    terms, tokens, starts, ends = [], [], [], []
    for raw, s, e in scan(text):
        pair = _WORDS.get(raw)
        if pair is None:
            token = fold(raw)
            pair = _WORDS[raw] = (token, to_term(token))
        tokens.append(pair[0])
        terms.append(pair[1])
        starts.append(s)
        ends.append(e)
    return terms, tokens, starts, ends


def make_atom(source):
    terms, tokens, _s, _e = analyse(source)
    if not terms:
        return None
    if len(terms) == 1 and tokens[0] in STOPS:
        return None
    return tuple(terms)


def lex(text):
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in WS:
            i += 1
        elif c in "()":
            out.append((c, None))
            i += 1
        elif c == '"':
            j = text.find('"', i + 1)
            body = text[i + 1:] if j < 0 else text[i + 1:j]
            i = n if j < 0 else j + 1
            out.append(("atom", make_atom(body)))
        else:
            j = i
            while j < n and text[j] not in WS and text[j] not in '()"':
                j += 1
            word, i = text[i:j], j
            if word in ("AND", "OR", "NOT"):
                out.append(("op", word))
            else:
                out.append(("atom", make_atom(word)))
    return out


PREC = {"OR": 1, "AND": 2, "NOT": 3}


def clean(tokens):
    """Rewrite operators that stand where the grammar expects an operand.

    The grammar of SPEC.md never fails; it absorbs stray operators in three
    ways, each of which is a rewrite of the token stream:

      * a run of NOTs takes the next token as its primary, so when that token
        is AND or OR the primary is empty and both the NOTs and that one
        token vanish; a run of NOTs at the end of the input, or before `)`,
        vanishes on its own;
      * a run of adjacent AND/OR tokens is read by one *and* loop and the
        enclosing *or* loop, which between them consume the whole run; the
        run acts as OR when it contains one, and as AND otherwise;
      * an AND or OR with no operand on one side — at the start of the input
        or of a group, or at the end of one — is consumed with no effect.
    """
    toks = list(tokens)
    changed = True
    while changed:
        changed = False
        for i, tok in enumerate(toks):
            if tok != ("op", "NOT"):
                continue
            j = i
            while j < len(toks) and toks[j] == ("op", "NOT"):
                j += 1
            nxt = toks[j] if j < len(toks) else None
            if nxt is None or nxt[0] == ")":
                del toks[i:j]
            elif nxt[0] == "op":
                del toks[i:j + 1]
            else:
                continue
            changed = True
            break
        if changed:
            continue
        for i, tok in enumerate(toks):
            if tok[0] != "op" or tok[1] == "NOT":
                continue
            j = i
            while j < len(toks) and toks[j][0] == "op" and toks[j][1] != "NOT":
                j += 1
            prv = toks[i - 1] if i else None
            nxt = toks[j] if j < len(toks) else None
            if (prv is None or prv[0] == "(" or nxt is None or nxt[0] == ")"):
                del toks[i:j]
            elif j > i + 1:
                keep = "OR" if any(t[1] == "OR" for t in toks[i:j]) else "AND"
                toks[i:j] = [("op", keep)]
            else:
                continue
            changed = True
            break
    return toks


def truncate(tokens):
    """Cut the token list at the first `)` that closes nothing.

    Such a token ends the top-level expression, and everything from it on is
    discarded, so `cat ) dog` is the query `cat`.
    """
    depth = 0
    for i, (kind, _val) in enumerate(tokens):
        if kind == "(":
            depth += 1
        elif kind == ")":
            if depth == 0:
                return tokens[:i]
            depth -= 1
    return tokens


def parse(text):
    """Shunting-yard parse into ('atom'|'not'|'and'|'or', ...) or None."""
    rpn, ops, marks, prev_operand = [], [], [], False
    for kind, val in clean(truncate(lex(text))):
        if kind == "atom" or kind == "(":
            if prev_operand:
                while ops and ops[-1] != "(" and PREC[ops[-1]] >= PREC["AND"]:
                    rpn.append(ops.pop())
                ops.append("AND")
            if kind == "(":
                ops.append("(")
                marks.append(len(rpn))
                prev_operand = False
            else:
                rpn.append(("atom", val))
                prev_operand = True
        elif kind == ")":
            while ops and ops[-1] != "(":
                rpn.append(ops.pop())
            mark = None
            if ops:
                ops.pop()
                mark = marks.pop()
            # A group that produced nothing is still an operand, an empty one,
            # so a preceding NOT applies to it rather than to what came before.
            if mark is not None and len(rpn) == mark:
                rpn.append(("atom", None))
            prev_operand = True
        elif val == "NOT":
            if prev_operand:
                while ops and ops[-1] != "(" and PREC[ops[-1]] >= PREC["AND"]:
                    rpn.append(ops.pop())
                ops.append("AND")
            ops.append("NOT")
            prev_operand = False
        else:
            while ops and ops[-1] != "(" and PREC[ops[-1]] >= PREC[val]:
                rpn.append(ops.pop())
            ops.append(val)
            prev_operand = False
    while ops:
        op = ops.pop()
        if op == "(":
            # An unclosed group ends at the end of the input and is an operand
            # like any other, empty when nothing was parsed inside it.
            if len(rpn) == marks.pop():
                rpn.append(("atom", None))
        else:
            rpn.append(op)
    stack = []
    for item in rpn:
        if isinstance(item, tuple):
            stack.append(("atom", item[1]) if item[1] is not None else None)
        elif item == "NOT":
            a = stack.pop() if stack else None
            stack.append(("not", a) if a is not None else None)
        else:
            b = stack.pop() if stack else None
            a = stack.pop() if stack else None
            kids = [x for x in (a, b) if x is not None]
            if not kids:
                stack.append(None)
            elif len(kids) == 1:
                stack.append(kids[0])
            else:
                stack.append((item.lower(), kids))
    return stack[-1] if stack else None


def canonical(node, nary):
    """Flatten a parse tree so the two parsers can be compared directly."""
    if node is None:
        return None
    kind = node[0]
    if kind == "atom":
        return ("atom", node[1].terms if nary else node[1])
    if kind == "not":
        return ("not", canonical(node[1], nary))
    kids = []
    for child in node[1]:
        c = canonical(child, nary)
        if c is not None and c[0] == kind:
            kids.extend(c[1])
        elif c is not None:
            kids.append(c)
    return (kind, tuple(kids))


def occurrences(atom, terms):
    """Brute-force positions where the atom's terms appear consecutively."""
    out, m, first = [], len(atom), atom[0]
    start = 0
    target = list(atom)
    while True:
        try:
            i = terms.index(first, start)
        except ValueError:
            return out
        if terms[i:i + m] == target:
            out.append(i)
        start = i + 1


def positives(node, negated=False, seen=None, order=None):
    if seen is None:
        seen, order = set(), []
    if node is None:
        return order
    if node[0] == "atom":
        if not negated and node[1] not in seen:
            seen.add(node[1])
            order.append(node[1])
    elif node[0] == "not":
        positives(node[1], not negated, seen, order)
    else:
        for child in node[1]:
            positives(child, negated, seen, order)
    return order


def evaluate(node, occ, all_docs):
    if node is None:
        return set()
    if node[0] == "atom":
        return {d for d, v in occ[node[1]].items() if v}
    if node[0] == "not":
        return all_docs - evaluate(node[1], occ, all_docs)
    sets = [evaluate(c, occ, all_docs) for c in node[1]]
    result = sets[0]
    for s in sets[1:]:
        result = (result & s) if node[0] == "and" else (result | s)
    return result


WS_RUN = re.compile("[%s]+" % re.escape(WS))


def window_text(text, starts, ends, s, length):
    return WS_RUN.sub(" ", text[starts[s]:ends[min(s + WINDOW, length) - 1]]).strip(" ")


def pick_window(length, atom_starts):
    """Best window start, searching only the points where a match enters."""
    if length <= WINDOW:
        return 0
    last = length - WINDOW
    candidates = {0}
    for starts, span in atom_starts:
        for p in starts:
            candidates.add(max(0, p + span - WINDOW))
    best, best_key = 0, (-1, -1)
    for s in sorted(candidates):
        if s > last:
            continue
        end = s + WINDOW - 1
        hits = total = 0
        for starts, span in atom_starts:
            lo = bisect.bisect_left(starts, s)
            hi = bisect.bisect_right(starts, end - span + 1)
            if hi > lo:
                hits += 1
                total += hi - lo
        if (hits, total) > best_key:
            best_key, best = (hits, total), s
    return best


def recompute(input_dir):
    """Recompute results.txt and stats.txt from scratch."""
    docs = []
    docs_dir = os.path.join(input_dir, "docs")
    if os.path.isdir(docs_dir):
        for name in sorted(os.listdir(docs_dir)):
            path = os.path.join(docs_dir, name)
            if name.endswith(".txt") and os.path.isfile(path):
                with open(path, encoding="utf-8", newline="") as f:
                    docs.append((name[:-4], f.read()))
    parsed = {}
    lengths = {}
    vocabulary = set()
    total_tokens = 0
    for doc_id, text in docs:
        terms, _tokens, starts, ends = analyse(text)
        parsed[doc_id] = (text, terms, starts, ends)
        lengths[doc_id] = len(terms)
        vocabulary.update(terms)
        total_tokens += len(terms)
    n = len(docs)
    avgdl = total_tokens / n if n else 0.0
    all_docs = {d for d, _ in docs}

    queries, k = [], 10
    qpath = os.path.join(input_dir, "queries.txt")
    if os.path.isfile(qpath):
        with open(qpath, encoding="utf-8", newline="") as f:
            data = f.read()
        if data.endswith("\n"):
            data = data[:-1]
        for line in data.split("\n"):
            line = line.rstrip("\r").strip(WS)
            if not line or line.startswith("#"):
                continue
            m = re.fullmatch(r"%k[ \t]+([0-9]+)[ \t]*", line)
            if m:
                k = int(m.group(1))
            else:
                queries.append((k, line))

    lines = []
    for number, (limit, text) in enumerate(queries, 1):
        node = parse(text)
        atoms = positives(node)
        occ = {}
        for atom in _all_atoms(node):
            occ[atom] = {d: occurrences(atom, parsed[d][1]) for d in all_docs}
        matched = evaluate(node, occ, all_docs)
        weights = {}
        for atom in atoms:
            df = sum(1 for d in all_docs if occ[atom][d])
            weights[atom] = math.log((n - df + 0.5) / (df + 0.5) + 1.0)
        scores = {}
        for doc_id in matched:
            total = 0.0
            for atom in atoms:
                f = len(occ[atom][doc_id])
                if not f:
                    continue
                weight = weights[atom]
                norm = 1.0 - B + B * (lengths[doc_id] / avgdl if avgdl else 0.0)
                total += weight * (f * (K1 + 1.0)) / (f + K1 * norm)
            scores[doc_id] = total
        ranked = sorted(matched, key=lambda d: (-scores[d], d))[:limit]
        lines.append("QUERY %d %s" % (number, text))
        lines.append("HITS %d" % len(ranked))
        for rank, doc_id in enumerate(ranked, 1):
            text_, terms, starts, ends = parsed[doc_id]
            if not terms:
                snippet = ""
            else:
                atom_starts = [(occ[a][doc_id], len(a)) for a in atoms if occ[a][doc_id]]
                s = pick_window(len(terms), atom_starts)
                snippet = window_text(text_, starts, ends, s, len(terms))
            lines.append("%d\t%s\t%.4f\t%s" % (rank, doc_id, scores[doc_id], snippet))
    results = "\n".join(lines) + ("\n" if lines else "")
    stats = "documents %d\ntokens %d\nterms %d\navgdl %.4f\n" % (
        n, total_tokens, len(vocabulary), avgdl)
    return results, stats


def _all_atoms(node, out=None):
    if out is None:
        out = []
    if node is None:
        return out
    if node[0] == "atom":
        if node[1] not in out:
            out.append(node[1])
    elif node[0] == "not":
        _all_atoms(node[1], out)
    else:
        for child in node[1]:
            _all_atoms(child, out)
    return out


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def check_stemmer():
    with open(os.path.join(CORPUS, "porter", "voc.txt"), encoding="utf-8") as f:
        vocabulary = f.read().split()
    with open(os.path.join(CORPUS, "porter", "output.txt"), encoding="utf-8") as f:
        expected = f.read().split()
    if len(vocabulary) != len(expected):
        raise SystemExit("porter vectors: length mismatch")
    for word, want in zip(vocabulary, expected):
        got = ref.porter_stem(word)
        if got != want:
            raise SystemExit("porter %r -> %r, official output says %r" % (word, got, want))
    print("porter stemmer: %d words match the official output" % len(vocabulary))
    return vocabulary


SCORE_GAP = 1e-9


def check_gaps(name, input_dir):
    """Ranking must not hinge on differences smaller than a rounding wobble.

    The check runs on the full-precision scores, not on the four decimals that
    reach results.txt, and it covers every matched document rather than the
    emitted prefix, so the pair straddling the top-k cut is covered too.
    """
    index = ref.Index()
    for doc_id, text in ref.read_documents(os.path.join(input_dir, "docs")):
        index.add(doc_id, text)
    index.finish()
    queries = ref.read_queries(os.path.join(input_dir, "queries.txt"))
    for number, (_k, text) in enumerate(queries, 1):
        node = ref.parse_query(text)
        cache = {}
        matched = ref.evaluate(node, index, cache)
        scores = ref.score_documents(index, ref.positive_atoms(node), matched, cache)
        ranked = sorted(matched, key=lambda d: (-scores[d], d))
        for hi, lo in zip(ranked, ranked[1:]):
            gap = scores[hi] - scores[lo]
            if 0 < gap <= SCORE_GAP:
                raise SystemExit(
                    "%s: query %d %r ranks %s (%.17g) above %s (%.17g); the gap "
                    "%g is too small to order reliably"
                    % (name, number, text, hi, scores[hi], lo, scores[lo], gap))


def build(number, name, docs, queries):
    """Write one test case and validate its expected output."""
    case = os.path.join(TESTS, "%03d_%s" % (number, name))
    shutil.rmtree(case, ignore_errors=True)
    docs_dir = os.path.join(case, "input", "docs")
    os.makedirs(docs_dir)
    for doc_id, text in docs:
        with open(os.path.join(docs_dir, doc_id + ".txt"), "w",
                  encoding="utf-8", newline="") as f:
            f.write(text)
    with open(os.path.join(case, "input", "queries.txt"), "w",
              encoding="utf-8", newline="") as f:
        f.write("\n".join(queries) + "\n")

    expected = os.path.join(case, "expected")
    os.makedirs(expected)
    ref.run(os.path.join(case, "input"), expected)
    with open(os.path.join(expected, "results.txt"), encoding="utf-8") as f:
        results = f.read()
    with open(os.path.join(expected, "stats.txt"), encoding="utf-8") as f:
        stats = f.read()

    want_results, want_stats = recompute(os.path.join(case, "input"))
    if results != want_results:
        for a, b in zip(results.split("\n"), want_results.split("\n")):
            if a != b:
                raise SystemExit("%s: reference %r, cross-check %r" % (name, a, b))
        raise SystemExit("%s: results length mismatch" % name)
    if stats != want_stats:
        raise SystemExit("%s: stats %r vs %r" % (name, stats, want_stats))

    for query in queries:
        line = query.strip(WS)
        if not line or line.startswith("#") or re.fullmatch(r"%k[ \t]+[0-9]+[ \t]*", line):
            continue
        a = canonical(ref.parse_query(line), True)
        b = canonical(parse(line), False)
        if a != b:
            raise SystemExit("%s: parse of %r differs: %r vs %r" % (name, line, a, b))
    check_gaps(name, os.path.join(case, "input"))
    hits = sum(1 for ln in results.split("\n") if ln.startswith("HITS "))
    print("%03d_%s: %d docs, %d queries, %d bytes of results"
          % (number, name, len(docs), hits, len(results)))


# ---------------------------------------------------------------------------
# Corpora
# ---------------------------------------------------------------------------

def lcg(seed):
    state = seed
    while True:
        state = (state * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        yield (state >> 33) % (1 << 31)


def book(name):
    with open(os.path.join(CORPUS, name + ".txt"), encoding="utf-8") as f:
        return f.read()


def chapters(text):
    """Split a book at its chapter headings, keeping the heading with the body."""
    heading = re.compile(
        r"\A\s*(?:CHAPTER|Chapter|LETTER|Letter|ACT|Act|BOOK|Book|PART|Part)"
        r"\s+[IVXLCDM0-9]")
    lines = text.split("\n")
    cuts = [i for i, line in enumerate(lines)
            if heading.match(line) and len(line.strip()) < 70]
    # The first occurrences are usually a table of contents: keep only cuts
    # that are far enough apart to be real chapter openings.
    kept = []
    for i in cuts:
        if not kept or i - kept[-1] >= 40:
            kept.append(i)
    if len(kept) < 3:
        return None
    parts = []
    for n, start in enumerate(kept):
        end = kept[n + 1] if n + 1 < len(kept) else len(lines)
        body = "\n".join(lines[start:end]).strip("\n")
        if body:
            parts.append(body + "\n")
    return parts


def paragraph_chunks(text, target):
    parts, current, size = [], [], 0
    for paragraph in text.split("\n\n"):
        current.append(paragraph)
        size += len(paragraph) + 2
        if size >= target:
            parts.append("\n\n".join(current).strip("\n") + "\n")
            current, size = [], 0
    if current and "".join(current).strip():
        parts.append("\n\n".join(current).strip("\n") + "\n")
    return parts


WHOLE_BOOKS = ["dubliners", "grimms-fairy-tales", "heart-of-darkness",
               "jekyll-hyde", "christmas-carol", "modest-proposal",
               "sherlock-holmes", "time-machine", "walden", "yellow-wallpaper"]
CHAPTER_BOOKS = ["alice", "being-earnest", "call-of-the-wild", "dolls-house",
                 "douglass", "frankenstein", "looking-glass", "peter-pan",
                 "the-prince", "treasure-island", "war-of-the-worlds",
                 "wizard-of-oz"]
CHUNK_BOOKS = ["anne-of-green-gables", "dorian-gray", "dracula", "emma",
               "great-expectations", "huckleberry-finn", "jane-eyre",
               "odyssey", "pride-and-prejudice", "sense-and-sensibility",
               "tom-sawyer", "two-cities", "wuthering-heights", "zarathustra"]


# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

ANIMALS = [
    ("cats", "The cat sat on the mat.\nCats are running, and the running cat runs.\n"),
    ("dogs", "A dog barks at noon.\nDogs bark loudly; the barking dog ran away.\n"),
    ("both", "The cat and the dog met.\nA dog chased the cat while cats watched dogs.\n"),
    ("birds", "Birds fly over the quiet lake at dawn, and the lake is still.\n"),
]


def main():
    vocabulary = check_stemmer()
    os.makedirs(TESTS, exist_ok=True)

    build(1, "empty_corpus", [], ["cat", "NOT cat", '"a b"'])

    build(2, "single_document", [
        ("note", "The quick brown fox jumps over the lazy dog.\n"),
    ], ["fox", "dog", "quick brown", "cat", '"lazy dog"'])

    build(3, "empty_document", [
        ("blank", ""),
        ("hello", "Hello world.\n"),
        ("spaces", "   \n\n\t\n"),
    ], ["hello", "NOT zebra", "world OR hello"])

    build(4, "case_folding", [
        ("shout", "HELLO hello HeLLo WORLD world.\n"),
        ("mixed", "Hello There. THERE hello.\n"),
    ], ["hello", "HELLO", "world", '"hello world"'])

    build(5, "apostrophes", [
        ("talk", "Don't stop. It's John's book, isn't it?\n"),
        ("clock", "At six o'clock the ship's bell rang; the bells ring.\n"),
        ("quote", "'quoted' and ''double'' and rock'n'roll.\n"),
        ("curly", "Don’t stop. It’s John’s book.\n"),
    ], ["dont", "johns", "oclock", "quoted", "rocknroll", '"johns book"'])

    build(6, "stop_words", [
        ("first", "The cat is on the mat and the mat is red.\n"),
        ("second", "A dog is in the house, but the house is not a home.\n"),
    ], ["the", "the of and", "the cat", "cat OR the", "NOT the", '"the cat"'])

    build(7, "phrase_basic", [
        ("a", "the red fox and the blue fox\n"),
        ("b", "the blue fox and the red fox\n"),
        ("c", "red and blue, fox and hound\n"),
    ], ['"red fox"', '"blue fox"', 'red fox', '"fox and hound"', '"red fox" OR "blue fox"'])

    build(8, "phrase_stop_words", [
        ("hamlet", "To be or not to be, that is the question.\n"),
        ("other", "Be that as it may, the question is open.\n"),
    ], ['"to be or not to be"', '"that is the question"', '"the question"', "question"])

    build(9, "phrase_across_sentences", [
        ("split", "He looked at the river. Bank robbers were waiting.\n"),
        ("joined", "He walked along the river bank robbers avoided.\n"),
        ("none", "The river was wide and the bank was closed.\n"),
    ], ['"river bank"', '"bank robbers"', '"river bank robbers"'])

    build(10, "phrase_overlapping", [
        ("run", "aa aa aa aa aa\n"),
        ("pair", "aa aa bb aa aa\n"),
        ("once", "aa bb aa bb aa\n"),
    ], ['"aa aa"', '"aa aa aa"', "aa"])

    build(11, "boolean_and", ANIMALS,
          ["cat dog", "cat AND dog", "cat AND dog AND bird", "cat AND lake"])

    build(12, "boolean_or", ANIMALS,
          ["cat OR dog", "cat OR bird", "cat OR dog OR lake", "unicorn OR cat"])

    build(13, "boolean_not", ANIMALS,
          ["cat NOT dog", "NOT cat", "NOT unicorn", "cat AND NOT dog", "NOT NOT cat"])

    build(14, "precedence", ANIMALS,
          ["cat OR dog AND bird", "cat AND dog OR bird", "NOT cat OR dog",
           "cat OR NOT dog", "bird OR cat NOT dog"])

    build(15, "parentheses_and_recovery", ANIMALS,
          ["(cat OR dog) AND bird", "cat OR (dog AND bird)", "((cat))",
           "()", "cat ()", "cat AND", "NOT", '"cat', "OR cat",
           "cat ) dog", "bird ) ) cat", "cat NOT ()", "cat NOT (",
           "(dog", "cat OR AND dog", "cat AND OR dog", "dog NOT ( cat",
           "NOT () dog"])

    # The last three documents turn stemming mistakes into visible collisions:
    # each pair stems to one term only when the rules of steps 1a, 1b, 4 and 5
    # are selected the way SPEC.md says, so a wrong chain changes the distinct
    # term count in stats.txt as well as the rankings.
    build(16, "stemming", [
        ("running", "He was running; the runner runs and had run.\n"),
        ("connect", "connection connections connected connecting connect\n"),
        ("relate", "relational relate related relativity relativistic\n"),
        ("happy", "happy happiness happier happily unhappy\n"),
        ("chains", "feed feeding; need needed; bleed bleeding; deed deeded.\n"),
        ("finals", "ice iced; cease ceased; rate rated; probate probated.\n"),
        ("doubles", "hopping hopped hop; falling fall; fizzed fizz; tanned tan.\n"),
    ], ["run", "running", "connect", "connections", "relational", "relativity",
        "happy", "happiness", "happier", "feeding", "needed", "bleed",
        "iced", "cease", "rated", "hopping", "falling", "fizz",
        '"feed feeding"'])

    # A vocabulary test whose documents are slices of the official Porter
    # word list, so any stemming error changes the ranking.
    vocab_docs = []
    step = len(vocabulary) // 8
    for i in range(8):
        words = vocabulary[i * step:(i + 1) * step:11]
        vocab_docs.append(("voc%d" % (i + 1), " ".join(words) + "\n"))
    build(17, "porter_vocabulary", vocab_docs,
          ["%k 5", "national", "rational OR relational", "conditioning",
           "feudalism AND capitalism", "sensibility", "communication",
           '"abandoned by"', "controlled"])

    # "ranges" sits on every boundary of the token-character table: ¿, ×, ÷,
    # U+0250 and U+0500 are separators, the code points on either side of them
    # are token characters.  "cyrillic" pins the ASCII-only case fold, which
    # leaves Привет and ПРИВЕТ as two different terms.
    build(18, "unicode", [
        ("cyrillic", "Привет мир ПРИВЕТ Мир привет.\n"),
        ("french", "Le café est ouvert. Cafés et crèmes à la crème.\n"),
        ("greek", "αλφα βήτα γάμμα alpha beta gamma\n"),
        ("dash", "well—known “quoted” words — and more\n"),
        ("ranges", "¿À Ö×Ø ö÷ø ɏɐ ͰϿ ЀӿԀ\n"),
        ("upper", "CAFÉ café Café\n"),
    ], ["café", "crème", "αλφα", "alpha", "well", "known",
        '"well known"', "quoted", "Привет", "ПРИВЕТ", "мир",
        "À", "Ö", "Ø", "ø", "ɏ", '"ͰϿ"', "ͰϿ", "Ѐӿ"])

    build(19, "digits_and_mixed", [
        ("versions", "Version 1.2.3 released in 2024; build 42 and 007.\n"),
        ("codes", "Model X1 and model x1 and X 1 differ from XY2Z.\n"),
        ("years", "In 1984 and in 2024 the numbers 42 and 1984 recur.\n"),
    ], ["1984", "42", "x1", '"1 2 3"', "version", "xy2z"])

    build(20, "hyphenated", [
        ("hyphen", "A well-known state-of-the-art system.\n"),
        ("spaced", "A well known state of the art system.\n"),
        ("apart", "The art is well hidden; the state is known.\n"),
    ], ["well-known", '"well known"', "state-of-the-art", "art", "well known"])

    filler = "alpha beta gamma delta epsilon zeta eta theta iota kappa"
    build(21, "snippet_window", [
        ("early", ("target " + filler + " " + filler + " " + filler + " " + filler).strip() + "\n"),
        ("late", (filler + " " + filler + " " + filler + " " + filler + " target").strip() + "\n"),
        ("twice", (filler + " target " + filler + " " + filler + " target " + filler).strip() + "\n"),
    ], ["target", "%k 3", "target OR alpha"])

    build(22, "snippet_multiple_atoms", [
        ("spread", ("apple " + filler + " " + filler + " " + filler + " banana cherry").strip() + "\n"),
        ("close", (filler + " apple banana cherry " + filler + " " + filler).strip() + "\n"),
        ("dense", ("apple apple apple " + filler + " " + filler + " " + filler + " banana cherry").strip() + "\n"),
    ], ["apple OR banana OR cherry", "apple banana cherry", '"apple banana"', "apple"])

    # "long" holds a 34-term phrase, longer than the 30-token window, so that
    # occurrence fits in no window at all and only the later "needle" can move
    # the snippet.  "spaced" uses all seven whitespace code points, including
    # U+000B, U+000C and U+00A0, both as separators and inside the runs the
    # snippet has to collapse.
    long_phrase = " ".join("q%02d" % i for i in range(34))
    long_doc = (" ".join("f%02d" % i for i in range(19)) + " " + long_phrase
                + " needle " + " ".join("g%02d" % i for i in range(20)) + "\n")
    build(23, "snippet_boundaries", [
        ("tiny", "one two three\n"),
        ("exact", " ".join("w%d" % i for i in range(30)) + " needle\n"),
        ("long", long_doc),
        ("padded", "needle " + " ".join("w%d" % i for i in range(60)) + "\n"),
        ("spaced", "alpha\u00a0\u00a0beta\tgamma\u000bdelta\u000cepsilon \u00a0 needle\u00a0omega\n"),
        ("wrapped", "line one\nline two\n\n   line three   \n\tline four\n"),
    ], ["needle", "three", "line", '"line two"', "omega",
        '"%s"' % long_phrase, '"%s" OR needle' % long_phrase])

    build(24, "score_ties", [
        ("copy1", "alpha beta gamma\n"),
        ("copy2", "alpha beta gamma\n"),
        ("copy3", "alpha beta gamma\n"),
        ("other", "alpha alpha beta\n"),
    ], ["alpha", "beta", "alpha beta", "gamma"])

    build(25, "k_directive", ANIMALS,
          ["%k 1", "cat OR dog OR bird OR lake", "%k 2",
           "cat OR dog OR bird OR lake", "%k 100",
           "cat OR dog OR bird OR lake"])

    # The U+00A0/U+000B/U+000C lines check that a query line is stripped with
    # all seven whitespace code points: one of them is blank, one is a query
    # whose echoed text is just "cat", one is a %k directive.
    build(26, "comments_and_blanks", ANIMALS,
          ["# leading comment", "", "   ", "\u00a0\u000b\u000c", "cat",
           "\t# indented comment", "\u00a0\u000b cat \u000c\u00a0",
           "%k 2", "   dog   ", "\u00a0%k 1\u00a0", "bird",
           "# trailing comment"])

    long_doc = ("lorem ipsum dolor sit amet " * 60).strip()
    build(27, "length_normalisation", [
        ("short", "rare term here\n"),
        ("medium", "rare term here " + ("filler word " * 20).strip() + "\n"),
        ("long", "rare term here " + long_doc + "\n"),
        ("common1", "term only\n"),
        ("common2", "term only again\n"),
    ], ["rare", "term", "rare term", "here"])

    build(28, "term_saturation", [
        ("one", "signal " + ("noise " * 40).strip() + "\n"),
        ("two", "signal signal " + ("noise " * 39).strip() + "\n"),
        ("five", "signal signal signal signal signal " + ("noise " * 36).strip() + "\n"),
        ("twenty", ("signal " * 20).strip() + " " + ("noise " * 21).strip() + "\n"),
    ], ["signal", "noise", "signal noise"])

    # 400 synthetic documents drawn from a fixed pseudo-random sequence.
    words = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta",
             "theta", "iota", "kappa", "lambda", "mu", "nu", "xi", "omicron",
             "pi", "rho", "sigma", "tau", "upsilon", "phi", "chi", "psi",
             "omega", "running", "connection", "relational", "happiness",
             "the", "of", "and", "to"]
    rnd = lcg(20240921)
    synthetic = []
    for i in range(400):
        count = 20 + next(rnd) % 60
        body = " ".join(words[next(rnd) % len(words)] for _ in range(count))
        synthetic.append(("doc%03d" % i, body + "\n"))
    build(29, "synthetic_corpus", synthetic,
          ["%k 5", "alpha", "alpha beta", "alpha OR beta", "alpha NOT beta",
           '"alpha beta"', '"the alpha"', "run connect", "happiness",
           "(alpha OR beta) AND NOT gamma", "%k 20", "omega"])

    build(30, "books_whole", [(name, book(name)) for name in WHOLE_BOOKS],
          ["%k 5", "sherlock holmes", "ghost OR spirit", '"the moon"',
           "pond AND ice", "transformation", "adventure NOT holmes",
           "wallpaper", '"once upon a time"', "king AND queen AND daughter",
           "%k 10", "the sea"])

    chapter_docs = []
    for name in CHAPTER_BOOKS:
        parts = chapters(book(name))
        if parts is None:
            parts = paragraph_chunks(book(name), 12000)
        for i, part in enumerate(parts, 1):
            chapter_docs.append(("%s-%03d" % (name, i), part))
    build(31, "book_chapters", chapter_docs,
          ["%k 8", "rabbit", "island AND treasure", '"looking glass"',
           "martian OR martians", "wizard emerald", "prince AND fortune",
           "monster NOT doctor", '"the white rabbit"', "slavery AND freedom",
           "%k 15", "peter pan wendy", "ship OR sea OR ocean"])

    chunk_docs = []
    for name in CHUNK_BOOKS:
        for i, part in enumerate(paragraph_chunks(book(name), 3000), 1):
            chunk_docs.append(("%s-%04d" % (name, i), part))
    build(32, "library_chunks", chunk_docs,
          ["%k 10", '"the sea"', "marriage AND fortune", "vampire OR ghost",
           "elizabeth darcy", '"my dear"', "happiness NOT misery",
           "(ship OR boat) AND storm", "convict", "beauty AND youth",
           "zarathustra", "%k 25", "love"])


# tests/ is handed out without corpus/, so it carries the licences of its
# third-party data.
TEST_NOTICE = 'corpus/tests-notice.md'
TEST_LICENCES = [
    ('corpus/LICENSE',
     'LICENSE-corpus.txt'),
]


def copy_licences():
    shutil.copyfile(os.path.join(HERE, TEST_NOTICE),
                    os.path.join(TESTS, 'THIRD_PARTY.md'))
    for src, name in TEST_LICENCES:
        shutil.copyfile(os.path.join(HERE, src), os.path.join(TESTS, name))


if __name__ == "__main__":
    main()
    copy_licences()
