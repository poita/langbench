# commonmark

A small, dependency-free CommonMark-to-HTML converter written in Rust. It
reproduces the output of the reference implementation
[`cmark`](https://github.com/commonmark/cmark) 0.31.2 (default options, no
`--unsafe`) for a subset of CommonMark 0.31.2:

* blocks: thematic breaks, ATX and setext headings, indented and fenced code
  blocks, paragraphs, block quotes, lists (tight and loose);
* inlines: backslash escapes, numeric entities and `&amp; &lt; &gt; &quot;`,
  code spans, emphasis and strong emphasis (full delimiter-run rules), inline
  links and images, autolinks, hard and soft line breaks.

Not supported (the input is assumed not to use them): raw HTML and HTML blocks,
link reference definitions and reference links, other named entities, and all
extensions. See `SPEC.md` of the task for the precise contract.

The implementation follows `cmark`'s design: a line-by-line block phase builds
a tree of blocks, a second phase parses the text of each paragraph and heading
into inlines (delimiter stack, bracket stack, `process emphasis` with
`openers_bottom` bounds, backtick-run memo), and one iterative walk renders
HTML. Everything is linear-time and non-recursive on document structure, so
very deep nesting is fine.

## Building

```sh
./build.sh            # or: cargo build --release
```

This produces `target/release/commonmark`. Only the Rust standard library is
used.

## Command-line use

The CLI reads the whole document from standard input and writes the HTML to
standard output. It takes no arguments and exits 0 on success.

```sh
printf '# Hello\n\nSome *emphasis* and a [link](/url).\n' | ./run.sh
# <h1>Hello</h1>
# <p>Some <em>emphasis</em> and a <a href="/url">link</a>.</p>
```

`run.sh` can be invoked from any directory.

## Library use

Add the crate as a dependency (e.g. `commonmark = { path = "../commonmark" }`) and
call [`to_html`]:

```rust
let html = commonmark::to_html("# Hello\n\nSome *emphasis* and a [link](/url).\n");
assert_eq!(
    html,
    "<h1>Hello</h1>\n<p>Some <em>emphasis</em> and a <a href=\"/url\">link</a>.</p>\n"
);
```

To work with the parsed tree, use `Document`:

```rust
use commonmark::{Document, NodeKind};

let doc = Document::parse("> quote");
let quote = doc.children(doc.root()).next().unwrap();
assert_eq!(doc.node(quote).kind(), &NodeKind::BlockQuote);
println!("{}", doc.to_html());
```

### Layout

| Module          | Responsibility                                              |
|-----------------|-------------------------------------------------------------|
| `src/node.rs`   | Arena-based document tree (`Tree`, `Node`, `NodeKind`)      |
| `src/block.rs`  | Phase 1: line-by-line block structure                       |
| `src/inline.rs` | Phase 2: inline parsing, emphasis, links, code spans        |
| `src/scan.rs`   | Hand-written scanners (block starts, autolinks, titles, …)  |
| `src/text.rs`   | Character classes, entities, escapes, HTML/URL encoding     |
| `src/html.rs`   | HTML renderer                                               |
| `src/main.rs`   | The command-line tool                                       |

## Testing

```sh
cargo test --release
```

The suite has unit tests for the scanners and text helpers, behaviour tests,
CLI tests, the CommonMark spec examples that lie inside the supported subset
(`tests/data/spec_examples.json`) and golden input/output pairs produced by
`cmark` (`tests/cases/`).
