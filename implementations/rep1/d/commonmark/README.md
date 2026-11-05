# commonmark

A CommonMark-to-HTML converter written in D, using only the standard library.
It implements the subset of CommonMark 0.31.2 described in
`problems/commonmark/SPEC.md` and produces the same output as the `cmark`
reference implementation for it:

- block level: thematic breaks, ATX and setext headings, indented and fenced
  code, paragraphs, block quotes, lists (tight/loose);
- inline level: backslash escapes, entity references (`&amp; &lt; &gt; &quot;`
  and numeric), code spans, emphasis/strong (full delimiter-run rules),
  inline links and images, autolinks, hard and soft line breaks.

Raw HTML, link reference definitions and extensions (tables, ...) are not
supported. The parser is written from scratch: no Markdown library is used.

## Design

Three stages over one in-memory copy of the input:

| module                | responsibility                                              |
|-----------------------|-------------------------------------------------------------|
| `commonmark.blocks`   | line-by-line block parser (container matching, block starts, lazy continuation, list tightness) |
| `commonmark.inlines`  | single-pass inline parser: backtick memo, delimiter stack, bracket stack, process-emphasis with `openers_bottom` |
| `commonmark.html`     | iterative HTML renderer, HTML/href escaping                 |
| `commonmark.scanners` | in-place scanners: autolinks, link destinations and titles  |
| `commonmark.entities` | entity decoding, backslash unescaping, UTF-8 encoding       |
| `commonmark.ast`      | `Block`, `BlockKind`, `Document` (index-linked block tree)  |
| `commonmark.buffer`   | growable output buffer                                      |
| `commonmark.chars`    | ASCII character classes                                     |
| `commonmark` (`package.d`) | public API                                             |

Block nodes and inline nodes are records in arrays linked by integer indices,
so wrapping nodes for emphasis and links is O(1) per node. Inlines are parsed
and rendered one block at a time, reusing the same arenas. Total cost is
O(N + L·D) time and O(N) memory.

## Building

Requires LDC 1.41 and dub 1.40.

```
./build.sh          # dub build -b release --compiler=ldc2  ->  bin/commonmark
dub test --compiler=ldc2   # run the unit tests
```

## Command-line use

```
./run.sh < input.md > output.html
```

The whole of stdin is the Markdown document (UTF-8, LF line endings); the HTML
is written to stdout in a single write. The exit status is 0 on success.

```
$ printf '# Hi\n\nSome *emphasis* and a [link](/x "t").\n' | ./run.sh
<h1>Hi</h1>
<p>Some <em>emphasis</em> and a <a href="/x" title="t">link</a>.</p>
```

## Using the library

Add the package as a dependency (use the `library` configuration):

```sdl
dependency "commonmark" path="../commonmark"
subConfiguration "commonmark" "library"
```

```d
import commonmark;

void main()
{
    import std.stdio : write;

    // Convert to a string ...
    write(toHtml("Hello *world*, see [D](https://dlang.org)\n"));

    // ... or append to a reusable buffer.
    Buffer out_;
    toHtml("- one\n- two\n", out_);
    write(out_.data);

    // The block structure can be inspected without rendering.
    auto doc = parseBlocks("# Title\n\ntext\n");
    assert(doc.blocks[doc.blocks[0].firstChild].kind == BlockKind.heading);
}
```

`toHtml` never throws on any input; it is linear in the input size for the
pathological cases (many unmatched brackets, delimiters or backticks).

## Tests

Unit tests live in `tests/commonmark_tests/` (separate from the library source):
block structure, inline constructs, scanners, entities, HTML escaping and all
473 examples of the CommonMark specification that fall inside the supported
subset. Run them with `dub test --compiler=ldc2`.

The end-to-end tests are run from the repository root:

```
commonmark/build.sh && python3 run_tests.py commonmark -- commonmark/run.sh
```
