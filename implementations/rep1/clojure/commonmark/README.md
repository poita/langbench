# commonmark

A CommonMark-to-HTML converter written in Clojure, with no dependencies beyond
Clojure itself. It produces the same HTML as the reference implementation
[cmark](https://github.com/commonmark/cmark) 0.31.2 (default options, safe mode)
for the following subset of [CommonMark 0.31.2](https://spec.commonmark.org/0.31.2/):

* thematic breaks, ATX and setext headings, indented and fenced code blocks,
  paragraphs, block quotes, bullet and ordered lists (tight and loose);
* backslash escapes, entities (`&amp;` `&lt;` `&gt;` `&quot;` and numeric
  references), code spans, emphasis and strong emphasis (the full
  delimiter-run rules), inline links and images, autolinks, hard and soft line
  breaks.

Raw HTML, link reference definitions (and so reference links) and all
extensions (tables, strikethrough, ...) are not supported; the input is assumed
not to use them. `SPEC.md` of the task describes the exact behaviour.

The implementation is the classic two-phase design: a line-by-line block parser
builds the block tree, then each paragraph and heading is parsed into inline
events with a delimiter stack, a bracket stack and the *process emphasis*
algorithm. Every scanner costs what it examines, so the whole run is linear in
the input (plus O(lines x depth) for the block phase); nesting thousands of
levels deep in the inlines needs no recursion.

## Requirements

* Java (developed with 27) and the [Clojure CLI](https://clojure.org/guides/install_clojure)
  (Clojure 1.12.6, fetched by `deps.edn`).

## Build

```sh
./build.sh
```

AOT-compiles the command-line tool into `target/classes`, which is on the
classpath declared in `deps.edn`, to cut start-up time. (The project also runs
without the build step, straight from the sources.)

## Command-line use

```sh
./run.sh < input.md > output.html
```

The whole of standard input is the Markdown document (UTF-8); the HTML is
written to standard output (UTF-8) and the exit code is 0. `run.sh` works from
any directory. Equivalent without the script:

```sh
clojure -M:run < input.md
```

## Library use

Add the project as a `deps.edn` dependency (a local checkout works with
`:local/root`) and require `commonmark.core`:

```clojure
(require '[commonmark.core :as cm])

(cm/markdown->html "# Hello\n\nSome *emphasis*, a [link](/url \"title\") and `code`.")
;; => "<h1>Hello</h1>\n<p>Some <em>emphasis</em>, a <a href=\"/url\" title=\"title\">link</a> and <code>code</code>.</p>\n"

;; The two phases are available separately:
(def doc (cm/parse "- a\n- b\n\n> quote"))
(:type doc)                        ;; => :document
(map :type (:children doc))        ;; => (:list :block-quote)
(cm/render doc)                    ;; => "<ul>\n<li>a</li>\n<li>b</li>\n</ul>\n<blockquote>\n<p>quote</p>\n</blockquote>\n"
```

### Public API

| function | description |
|---|---|
| `commonmark.core/markdown->html` | Markdown string to HTML string. |
| `commonmark.core/parse` | Markdown string to a document tree of plain maps (`:type`, `:children`, ...); paragraphs and headings carry their parsed `:inlines`. |
| `commonmark.core/render` | document tree to HTML string. |

### Modules

| namespace | responsibility |
|---|---|
| `commonmark.core` | the public API, tying the phases together |
| `commonmark.blocks` | phase 1: the block structure (containers, leaves, list tightness); documents the shape of the block tree |
| `commonmark.inlines` | phase 2: inline events (`[:text s]`, `[:start :emph]`, ...) with the delimiter and bracket stacks; documents the event format |
| `commonmark.scan` | scanners for autolinks, link destinations and titles |
| `commonmark.text` | character classes, entities and escapes, HTML escaping, URL encoding |
| `commonmark.html` | the HTML renderer |
| `commonmark.main` | the command-line entry point (`-main`) |

## Tests

```sh
clojure -M:test
```

runs the unit tests of every module, the 473 examples of the CommonMark
specification that fall in the supported subset (`test/golden/spec_examples.edn`),
golden input/output files produced by cmark (`test/golden/*.in` / `*.out`),
robustness tests (300-deep nesting, thousands of nested inlines, pathological
inputs) and property-based tests with `test.check`. They use `clojure.test` and
the Cognitect test-runner.

## Notes on cmark's behaviour

The code follows cmark where it differs from the letter of the specification,
for example the single `link_closed` flag that decides whether an enclosing `[`
can still become a link, the backtick-run memo of the code-span search, the
rule-of-three computed from the original delimiter run lengths, and the
memoised "ends with a blank line" test that decides whether a list is tight.
