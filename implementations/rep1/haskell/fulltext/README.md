# fulltext

A small full-text search engine in Haskell. It indexes a corpus of plain-text
documents, evaluates boolean and phrase queries against a positional inverted
index, ranks the matches with BM25 and returns a best-window snippet for each
hit. It is a library with a thin batch command-line tool on top.

- **Analysis**: Unicode-aware tokeniser (ASCII digits and letters, Latin,
  Greek, Cyrillic; apostrophes inside words are dropped), ASCII-only case
  folding, the original Porter stemmer (as in `porter.c`), 33 stop words.
- **Index**: term → document → sorted positions, stored in one flat array of
  `doc * 2^32 + position` keys, so phrases match by merging sorted lists.
- **Queries**: `AND`, `OR`, `NOT`, parentheses, `"quoted phrases"`;
  juxtaposition means `AND`; parsing never fails.
- **Ranking**: BM25 (`k1 = 1.2`, `b = 0.75`), ties broken by document id.
- **Snippets**: the 30-token window with the most distinct query atoms, then
  the most occurrences, then the earliest start, found in linear time.

Only GHC's bundled packages (`base`, `containers`, `array`, `text`,
`bytestring`, `directory`, `filepath`) are used by the library and tool;
`hspec` and `QuickCheck` are used by the tests.

## Build

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh          # cabal build, then copies the binary to bin/fulltext
cabal test          # run the test suite
```

## Command-line tool

```sh
./run.sh <input directory> <output directory>
# or: bin/fulltext <input directory> <output directory>
```

Input layout:

```
<input>/docs/<id>.txt     one document per file (docs/ may be missing)
<input>/queries.txt       one query per line
```

`queries.txt` lines are stripped of surrounding whitespace; blank lines and
lines starting with `#` are ignored; `%k N` sets the number of results (default
10) for the queries that follow; every other line is a query.

The tool writes two files into the output directory:

- `results.txt` — for each query, `QUERY <n> <text>`, `HITS <h>` and then `h`
  lines `rank<TAB>id<TAB>score<TAB>snippet`;
- `stats.txt` — `documents`, `tokens`, `terms` and `avgdl`.

Example: with `docs/note.txt` containing
`The quick brown fox jumps over the lazy dog.` and a `queries.txt` of

```
fox
"lazy dog"
cat
```

`results.txt` is

```
QUERY 1 fox
HITS 1
1	note	0.2877	The quick brown fox jumps over the lazy dog
QUERY 2 "lazy dog"
HITS 1
1	note	0.2877	The quick brown fox jumps over the lazy dog
QUERY 3 cat
HITS 0
```

## Library

```haskell
{-# LANGUAGE OverloadedStrings #-}
import Fulltext

main :: IO ()
main = do
  let ix = buildIndex
        [ ("a", "The quick brown fox jumps over the lazy dog.")
        , ("b", "A quick red fox and a slow red hen.") ]
  mapM_ print (runQuery ix 10 "quick AND (fox OR \"lazy dog\") NOT hen")
  -- Result {resultDocId = "a", resultScore = ..., resultSnippet = "The quick ... dog"}
```

| Module | Responsibility |
|---|---|
| `Fulltext` | facade: `buildIndex`, `runQuery`, `Result` |
| `Fulltext.Analysis` | tokeniser, folding, stop words, term of a token |
| `Fulltext.Porter` | the Porter stemmer |
| `Fulltext.Index` | positional inverted index and corpus statistics |
| `Fulltext.Query` | lexer, parser, atoms, positive atoms |
| `Fulltext.Search` | phrase matching, boolean evaluation, BM25, ranking |
| `Fulltext.Snippet` | best-window search and snippet text |
| `Fulltext.Corpus` | reading `docs/` and `queries.txt` |
| `Fulltext.Report` | rendering `results.txt` and `stats.txt` |

## Tests

`cabal test` runs an hspec suite: unit tests per module, QuickCheck properties
(tokeniser spans, the linear-time best window against a window-by-window
evaluation), the specification's worked examples, and Porter's 23 531-word
test vocabulary (`test/data/`).
