# commonmark

A CommonMark-to-HTML converter written in D, with no dependencies beyond the
standard library. It produces the same HTML as the reference implementation
[`cmark`](https://github.com/commonmark/cmark) 0.31.2 for a practical subset
of CommonMark:

- thematic breaks, ATX and setext headings, indented and fenced code blocks,
  paragraphs, block quotes, lists (tight and loose);
- backslash escapes, entities (numeric ones and `&amp;` `&lt;` `&gt;`
  `&quot;`), code spans, emphasis and strong emphasis, inline links and images
  (all destination and title forms), autolinks, hard and soft line breaks.

Not supported (they are outside the subset): raw HTML and HTML blocks, link
reference definitions and reference links, and extensions such as tables.

The implementation is a cmark-style two-phase parser: a line-by-line block
parser builds the block tree, then each paragraph and heading is parsed into
inlines with the delimiter-stack / bracket-stack / process-emphasis
algorithm, and one walk over the tree writes the HTML. The work is linear in
the input size (code spans use a backtick memo; emphasis uses `openers_bottom`
bounds), and inline nesting thousands of levels deep is handled iteratively.

## Layout

| Path | Contents |
| --- | --- |
| `source/commonmark/package.d` | public entry point, `toHtml` |
| `source/commonmark/ast.d` | the block tree (`Block`, `BlockKind`) |
| `source/commonmark/block.d` | phase 1: `parseBlocks` |
| `source/commonmark/inline.d` | phase 2: `InlineParser`, `InlineNode` |
| `source/commonmark/html.d` | `renderHtml` |
| `source/commonmark/text.d` | character classes, escaping, entity and URL helpers |
| `source/commonmark/conformance.d` | spec-example and stress tests |
| `cli/` | the command-line tool (dub sub-package `commonmark:cli`) |
| `tests/data/spec_examples.json` | CommonMark spec examples used by the tests |

## Building

Requires LDC and dub.

```sh
./build.sh          # dub build -b release --compiler=ldc2 :cli
```

This produces `bin/commonmark`. To build only the library, run
`dub build -b release --compiler=ldc2` in this directory.

## Command-line use

The tool reads a Markdown document (UTF-8) from standard input and writes the
HTML to standard output:

```sh
printf '# Hello\n\nSome *emphasis* and a [link](/url "title").\n' | ./run.sh
```

```html
<h1>Hello</h1>
<p>Some <em>emphasis</em> and a <a href="/url" title="title">link</a>.</p>
```

`run.sh` can be invoked from any directory. The exit code is 0 on success.

## Using the library

Add it to your `dub.sdl` (`dependency "commonmark" path="path/to/commonmark"`)
and call `toHtml`:

```d
import commonmark;
import std.stdio : write;

void main()
{
    write(toHtml("Hello, *world*! See <https://dlang.org>.\n"));
}
```

The stages are available separately: `parseBlocks(markdown)` returns the
`Block` tree (see `commonmark.ast`), `renderHtml(document)` renders a tree, and
`InlineParser.parse(content)` parses the raw text of a paragraph or heading
into an array of `InlineNode`s.

```d
import commonmark;

auto doc = parseBlocks("# Title\n\ntext\n");
assert(doc.firstChild.kind == BlockKind.heading);
assert(doc.firstChild.level == 1);
assert(renderHtml(doc) == "<h1>Title</h1>\n<p>text</p>\n");
```

## Tests

```sh
dub test --compiler=ldc2
```

The tests are `unittest` blocks: unit tests in each module, plus
`conformance.d`, which runs the CommonMark spec examples in
`tests/data/spec_examples.json` and some stress tests (deep nesting,
pathological delimiter and backtick input).
