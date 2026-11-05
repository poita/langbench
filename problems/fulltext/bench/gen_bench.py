#!/usr/bin/env python3
"""Generates the performance benchmark inputs for the `fulltext` problem.

Writes bench/NNN_name/{input,expected} in the same directory-mode layout as
tests/, so the suite runs with

    python3 run_tests.py fulltext --tests-dir problems/fulltext/bench -- <cmd>

Every corpus is a deterministic slice of the vendored public-domain books in
corpus/, so re-running this script reproduces the inputs byte for byte.
Expected outputs come from reference/main.py, and every ranking is checked
with gen_tests.check_gaps so that no two neighbouring scores are close enough
for a one-ulp difference to reorder them.

The inputs stay within the sizes SPEC.md describes for its test suite (about
10MB of text, at most 25 queries, k at most 25) and get their weight from
corpus size and from query shape instead.

    python3 bench/gen_bench.py
"""
import os
import random
import re
import shutil
import sys
import time

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, PROBLEM)
sys.path.insert(0, os.path.join(PROBLEM, "reference"))
import gen_tests as gt  # noqa: E402
import main as ref  # noqa: E402


def build(number, name, docs, queries, out_root=HERE):
    case = os.path.join(out_root, "%03d_%s" % (number, name))
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
    start = time.time()
    ref.run(os.path.join(case, "input"), expected)
    elapsed = time.time() - start
    gt.check_gaps(name, os.path.join(case, "input"))
    size = sum(len(t.encode("utf-8")) for _, t in docs)
    nq = sum(1 for q in queries
             if q.strip() and not q.startswith("%k") and not q.startswith("#"))
    print("%03d_%s: %d docs, %d bytes, %d queries, reference %.1fs"
          % (number, name, len(docs), size, nq, elapsed))


# Paragraph-sized documents from eleven long novels (~8.6MB): the cost is
# dominated by tokenising, stemming and indexing, as for a typical
# search-engine ingest of many small records.
THROUGHPUT_BOOKS = ["jane-eyre", "great-expectations", "emma", "dracula",
                    "two-cities", "pride-and-prejudice", "odyssey",
                    "sense-and-sensibility", "wuthering-heights",
                    "zarathustra", "walden"]

THROUGHPUT_QUERIES = [
    "%k 10",
    "governess",
    '"my dear"',
    "marriage AND fortune",
    "vampire OR ghost OR spirit",
    "elizabeth darcy",
    "happiness NOT misery",
    "(ship OR boat) AND storm",
    "convict",
    "beauty AND youth",
    '"the old man"',
    "letter AND (sister OR brother)",
    "pond ice winter",
    "revolution AND paris",
    "%k 20",
    "heathcliff catherine",
    "ulysses OR odysseus",
    "superman",
    "count AND castle",
    '"i am sure"',
    "estella NOT havisham",
    "money OR wealth OR riches",
    "%k 5",
    "rochester",
    "knightley AND harriet",
    "night AND (fear OR terror)",
    '"in the morning"',
]

# Whole books as documents (~8.5MB): every document is long, every query
# combines many frequent terms and stop-word phrases, and k is 25, so the
# work is in walking long posting lists, positional phrase matching with
# thousands of occurrences per document, scoring, and the best-window search
# over very long documents with dense occurrence sets.
WHOLE_BOOKS = ["great-expectations", "dracula", "two-cities",
               "pride-and-prejudice", "odyssey", "wuthering-heights",
               "zarathustra", "walden", "the-prince", "peter-pan",
               "douglass", "heart-of-darkness", "wizard-of-oz",
               "time-machine", "call-of-the-wild", "looking-glass",
               "alice", "dolls-house", "jekyll-hyde", "christmas-carol",
               "being-earnest", "yellow-wallpaper", "modest-proposal"]

HEAVY_QUERIES = [
    "%k 25",
    "said OR would OR could OR one OR little OR man OR time OR upon OR like OR know",
    '"of the" OR "in the" OR "to the" OR "and the" OR "on the" OR "at the"',
    '"it was" AND "there was" AND "i had"',
    "man woman child house room door night day",
    '"i do not know" OR "i don\'t know" OR "i dont know"',
    "(man OR woman) AND (house OR room) AND NOT \"the sea\"",
    '"said the" OR "and then" OR "as if" OR "as though" OR "for a moment"',
    "hand OR eyes OR face OR head OR heart OR voice OR look OR thought",
    '"of the" AND "in the" AND NOT (vampire OR whale)',
    "good great old young long first last own other new",
    '"the old man" OR "the young man" OR "the little" OR "a great"',
    "(love OR hate) AND (life OR death) AND (friend OR enemy)",
    "come go see make take give get tell think say",
    '"i will" OR "you will" OR "he would" OR "she would" OR "we shall"',
    "NOT (zebra OR unicorn) AND (people OR men OR women)",
    "water OR sea OR river OR fire OR earth OR air OR sky OR sun OR moon",
    '"one of the" OR "out of the" OR "some of the" OR "all the"',
    "king queen prince princess lord lady master servant",
    '"at last" AND "at once" AND "at first"',
    "word OR words OR speak OR spoke OR told OR asked OR answered OR replied",
    '"it is" OR "it was" OR "that is" OR "this is" OR "there is"',
    "money AND (poor OR rich) AND work",
    "morning evening night day week year hour minute",
    '"the man" OR "of a" OR "and a"',
    "light dark white black red green blue",
]

# Chapter-sized documents (chapters of the books whose headings split
# cleanly, ~12KB paragraph groups otherwise; ~8.2MB): a mixed workload of
# names, phrases, nested boolean queries and NOT clauses with varying k, as
# an interactive search session would issue.
MIXED_BOOKS = ["dracula", "two-cities", "pride-and-prejudice", "huckleberry-finn",
               "tom-sawyer", "frankenstein", "dorian-gray",
               "treasure-island", "war-of-the-worlds", "alice",
               "looking-glass", "peter-pan", "wizard-of-oz",
               "call-of-the-wild", "time-machine", "the-prince",
               "douglass", "christmas-carol", "jekyll-hyde",
               "heart-of-darkness", "sherlock-holmes",
               "anne-of-green-gables"]

MIXED_QUERIES = [
    "%k 10",
    "rabbit",
    "island AND treasure",
    '"looking glass" OR "white queen"',
    "martian OR martians OR tripod",
    "%k 15",
    "(miss OR mrs) AND (letter OR note) AND NOT (london OR paris)",
    '"said the king" OR "said the queen"',
    "sherlock holmes watson",
    "monster NOT (doctor OR clerval)",
    "%k 25",
    "the house was very quiet",
    '"it was the best of times"',
    "(river OR raft) AND (jim OR huck) AND night",
    "slavery AND freedom",
    "peter pan wendy hook",
    "%k 5",
    "jekyll OR hyde OR utterson",
    '"i cannot"',
    "%k 20",
    "(love OR marriage) AND NOT (war OR battle)",
    "ship OR sea OR ocean OR voyage",
    '"in a moment"',
    "dorian portrait painting",
    "wolf OR dog OR sled OR buck",
    "prince AND (fortune OR virtue) AND NOT \"the people\"",
    '"once upon a time" OR "long ago"',
    "anne gilbert diana marilla",
    "%k 25",
    "time traveller future",
]


def throughput_docs(books):
    return [("%s-%05d" % (name, i), part)
            for name in books
            for i, part in enumerate(gt.paragraph_chunks(gt.book(name), 1500), 1)]


def chapter_docs(books):
    docs = []
    for name in books:
        parts = gt.chapters(gt.book(name))
        if parts is None:
            parts = gt.paragraph_chunks(gt.book(name), 12000)
        for i, part in enumerate(parts, 1):
            docs.append(("%s-%03d" % (name, i), part))
    return docs


# ---------------------------------------------------------------------------
# Long tier (--long, written to ../bench-long): the same three corpora (the
# paragraph corpus grown to every book in corpus/) with long generated query
# sessions of the same kinds as the hand-written ones above: broad
# frequent-phrase queries for 002, and for 001 and 003 an even blend of those
# with ordinary name/phrase/boolean queries. Every generated query is checked
# for reorder-safe score gaps before it is kept.
# ---------------------------------------------------------------------------

ALL_BOOKS = sorted(f[:-4] for f in os.listdir(gt.CORPUS) if f.endswith(".txt"))
LONG_QUERY_COUNTS = (6000, 4000, 16000)
LONG_BROAD_SHARE = 0.5
WORD_RE = re.compile(r"[A-Za-z]+(?:['’][A-Za-z]+)*")


class QueryForge:
    """Draws realistic queries from the words, names and phrases of a corpus."""

    def __init__(self, docs, seed):
        self.rng = random.Random(seed)
        self.index = ref.Index()
        for doc_id, text in docs:
            self.index.add(doc_id, text)
        self.index.finish()
        self.doc_words = [[w.replace("’", "'") for w in WORD_RE.findall(text)]
                          for _, text in docs]
        counts, caps, bigrams, trigrams = {}, {}, {}, {}
        for words in self.doc_words:
            low = [w.lower() for w in words]
            for i, w in enumerate(words):
                lw = low[i]
                counts[lw] = counts.get(lw, 0) + 1
                if w[0].isupper() and i > 0 and words[i - 1][-1:].islower():
                    caps[lw] = caps.get(lw, 0) + 1
            for i in range(len(low) - 2):
                b = low[i] + " " + low[i + 1]
                bigrams[b] = bigrams.get(b, 0) + 1
                t = b + " " + low[i + 2]
                trigrams[t] = trigrams.get(t, 0) + 1

        def top(table, n):
            return [w for w, _ in sorted(table.items(), key=lambda kv: (-kv[1], kv[0]))[:n]]

        # Proper names: frequent words that are almost always capitalised
        # mid-sentence. Content words: mid-frequency words of 5+ letters.
        self.names = sorted(w for w, c in counts.items()
                            if c >= 25 and len(w) >= 3 and caps.get(w, 0) >= 0.9 * c)
        self.content = sorted(w for w, c in counts.items() if 20 <= c <= 3000 and len(w) >= 5)
        self.frequent = top(counts, 150)
        self.common_phrases = top(bigrams, 250) + top(trigrams, 120)

    def word(self):
        return self.rng.choice(self.content)

    def name(self):
        return self.rng.choice(self.names)

    def text_phrase(self):
        rng = self.rng
        words = []
        while len(words) < 6:
            words = rng.choice(self.doc_words)
        n = rng.randint(2, 4)
        i = rng.randrange(len(words) - n)
        return '"%s"' % " ".join(w.lower() for w in words[i:i + n])

    def common_phrase(self):
        return '"%s"' % self.rng.choice(self.common_phrases)

    def ors(self, pick, lo, hi):
        return " OR ".join(pick() for _ in range(self.rng.randint(lo, hi)))

    def mixed(self):
        """A name/phrase/boolean query as an interactive user would type it."""
        rng, w, nm = self.rng, self.word, self.name
        shape = rng.randrange(12)
        if shape == 0:
            return nm()
        if shape == 1:
            return "%s %s" % (nm(), nm())
        if shape == 2:
            return self.text_phrase()
        if shape == 3:
            return "%s AND %s" % (w(), w())
        if shape == 4:
            return "%s OR %s OR %s" % (w(), w(), w())
        if shape == 5:
            return "%s NOT %s" % (nm(), nm())
        if shape == 6:
            return "(%s OR %s) AND %s" % (w(), w(), w())
        if shape == 7:
            return "%s AND (%s OR %s)" % (nm(), w(), w())
        if shape == 8:
            return "%s OR %s" % (self.text_phrase(), self.text_phrase())
        if shape == 9:
            return "(%s OR %s) AND (%s OR %s) AND NOT (%s OR %s)" % (
                w(), w(), w(), w(), w(), w())
        if shape == 10:
            return "%s %s %s" % (w(), w(), w())
        return "%s AND NOT %s" % (self.common_phrase(), w())

    def heavy(self):
        """A broad query combining many frequent terms and stop-word phrases."""
        rng, cp = self.rng, self.common_phrase
        shape = rng.randrange(6)
        if shape == 0:
            return self.ors(cp, 3, 7)
        if shape == 1:
            return " AND ".join(cp() for _ in range(rng.randint(2, 3)))
        if shape == 2:
            return "%s AND %s AND NOT (%s OR %s)" % (cp(), cp(), self.word(), self.word())
        if shape == 3:
            return self.ors(lambda: rng.choice(self.frequent), 6, 12)
        if shape == 4:
            return "(%s) AND %s" % (self.ors(cp, 2, 4), cp())
        return "%s OR %s" % (self.text_phrase(), self.ors(cp, 2, 4))

    def blend(self, heavy_share):
        """A session mixing ordinary queries with broad ones."""
        return lambda: self.heavy() if self.rng.random() < heavy_share else self.mixed()

    def gaps_ok(self, text):
        """The same reorder-safety rule as gen_tests.check_gaps, for one query."""
        index = self.index
        node = ref.parse_query(text)
        cache = {}
        matched = ref.evaluate(node, index, cache)
        scores = ref.score_documents(index, ref.positive_atoms(node), matched, cache)
        ranked = sorted(matched, key=lambda d: (-scores[d], d))
        return all(not (0 < scores[a] - scores[b] <= gt.SCORE_GAP)
                   for a, b in zip(ranked, ranked[1:]))

    def session(self, count, make, k_choices, k_every):
        lines, seen, kept = [], set(), 0
        while kept < count:
            if kept % k_every == 0 and k_choices:
                lines.append("%%k %d" % self.rng.choice(k_choices))
            q = make()
            if q in seen or not self.gaps_ok(q):
                continue
            seen.add(q)
            lines.append(q)
            kept += 1
        return lines


def main():
    long_tier = "--long" in sys.argv[1:]
    if not long_tier:
        build(1, "paragraph_corpus_throughput", throughput_docs(THROUGHPUT_BOOKS),
              THROUGHPUT_QUERIES)
        build(2, "whole_books_heavy_queries",
              [(name, gt.book(name)) for name in WHOLE_BOOKS],
              HEAVY_QUERIES)
        build(3, "chapters_mixed_session", chapter_docs(MIXED_BOOKS), MIXED_QUERIES)
        return
    out_root = os.path.join(PROBLEM, "bench-long")
    os.makedirs(out_root, exist_ok=True)
    n1, n2, n3 = LONG_QUERY_COUNTS

    docs = throughput_docs(ALL_BOOKS)
    forge = QueryForge(docs, 5101)
    build(1, "paragraph_corpus_throughput", docs,
          forge.session(n1, forge.blend(LONG_BROAD_SHARE), (5, 10, 15, 20), 6), out_root)

    docs = [(name, gt.book(name)) for name in WHOLE_BOOKS]
    forge = QueryForge(docs, 5102)
    build(2, "whole_books_heavy_queries", docs, forge.session(n2, forge.heavy, (25,), n2), out_root)

    docs = chapter_docs(MIXED_BOOKS)
    forge = QueryForge(docs, 5103)
    build(3, "chapters_mixed_session", docs,
          forge.session(n3, forge.blend(LONG_BROAD_SHARE), (5, 10, 15, 20, 25), 5), out_root)


if __name__ == "__main__":
    main()
