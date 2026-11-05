# fulltext

A small, dependency-free full-text search engine written in D. It builds an
in-memory positional inverted index over a directory of plain-text documents,
evaluates boolean and phrase queries, ranks matches with BM25 and returns a
snippet for each hit. Text analysis (tokeniser, stop words and the Porter
stemmer) is implemented from scratch on top of the D standard library only.

The code is split into a reusable library (`src/fulltext/`) and a thin
command-line tool (`app/main.d`).

## Building

Requires LDC (tested with 1.41.0) and dub (tested with 1.40.0).

```sh
./build.sh            # same as: dub build -b release --compiler=ldc2
```

This produces `bin/fulltext`. Run the unit tests with:

```sh
dub test --compiler=ldc2
```

## Command-line usage

```sh
./run.sh <input directory> <output directory>
```

The input directory contains:

```
docs/<id>.txt     one UTF-8 file per document (docs/ may be missing or empty)
queries.txt       one query per line
```

`queries.txt` lines are stripped of surrounding whitespace. Blank lines and
lines starting with `#` are ignored, and `%k <n>` sets the result limit for
all following queries (default 10).

The tool writes two files into the output directory (created if missing):

* `results.txt` — for each query a `QUERY <n> <text>` line, a `HITS <h>` line,
  and `h` lines `rank<TAB>doc id<TAB>BM25 score<TAB>snippet`.
* `stats.txt` — `documents`, `tokens`, `terms` and `avgdl` of the corpus.

### Query language

| Syntax            | Meaning                                                    |
|-------------------|------------------------------------------------------------|
| `cat dog`         | both words (juxtaposition is `AND`)                        |
| `cat OR dog`      | either word                                                |
| `cat NOT dog`     | `cat` but not `dog` (`NOT` binds tightest, then `AND`, `OR`)|
| `"lazy dog"`      | the terms adjacent and in order (a phrase)                 |
| `(a OR b) c`      | grouping                                                   |

`AND`, `OR` and `NOT` are operators only in upper case. A single stop word
(`the`, `of`, …) matches nothing and is dropped from the query; inside a
phrase stop words are kept. Malformed queries never fail — they are repaired
by dropping what cannot be parsed (an empty query matches no document).

Analysis: tokens are runs of ASCII alphanumerics, Latin, Greek and Cyrillic
letters, with inner apostrophes kept in the token and then deleted; ASCII
letters are lower-cased; purely `a`–`z` tokens are Porter-stemmed.

## Layout

| Module                | Responsibility                                          |
|-----------------------|---------------------------------------------------------|
| `fulltext.whitespace` | the seven whitespace code points; strip / collapse      |
| `fulltext.analysis`   | tokeniser, folding, stop words, term analysis           |
| `fulltext.stemmer`    | Porter stemmer (in place, allocation-free)              |
| `fulltext.index`      | `Index`: documents, token spans, postings, statistics   |
| `fulltext.query`      | lexer, recursive-descent parser, positive atoms         |
| `fulltext.matcher`    | phrase occurrences, document bitsets, tree evaluation   |
| `fulltext.ranking`    | BM25 and top-k selection                                |
| `fulltext.snippet`    | best 30-token window and snippet text                   |
| `fulltext.search`     | `SearchEngine`: ties the above together                 |
| `fulltext.queryfile`  | parsing `queries.txt`                                   |
| `fulltext.report`     | formatting `results.txt` and `stats.txt`                |
| `fulltext.corpus`     | loading `docs/*.txt` from disk                          |

`import fulltext;` re-exports all of them. Unit tests live in `tests/`.

## Library example

```d
import std.stdio : writefln;
import fulltext;

void main()
{
    auto index = new Index([
        Document.fromString("fox", "The quick brown fox jumps over the lazy dog."),
        Document.fromString("cat", "A cat sat on the mat."),
    ]);
    auto engine = new SearchEngine(index);

    foreach (i, hit; engine.search(`"lazy dog" OR cat`, 10))
        writefln("%d\t%s\t%.4f\t%s", i + 1, hit.docId, hit.score, hit.snippet);

    // Pieces are usable on their own:
    assert(stem("running") == "run");
    assert(analyzeText("Don't STOP") == ["dont", "stop"]);
}
```

Add it to a dub project with `"dependencies": { "fulltext": { "path": "../fulltext" } }`
and the `library` configuration (`"subConfigurations": { "fulltext": "library" }`).

## Design notes

* Documents are kept as UTF-8 bytes; the tokeniser records byte spans, so
  snippets are slices of the original text and no code-point arrays are built.
* Each document is tokenised once; folding and stemming run once per distinct
  surface form (memoised), and terms get dense integer ids.
* Postings are flat `uint` arrays (documents, offsets, positions) built by
  appending, so they come out sorted without a sort step.
* Phrase matching merges the rarest term's document list against the others,
  then intersects shifted position lists linearly.
* Document sets are bitsets; the top `k` hits are chosen by partial sort.
* The best snippet window is found with difference arrays in
  O(length + occurrences).
