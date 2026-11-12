# cmarkpy

A dependency-free Python converter from CommonMark to HTML. It follows the
design of the `cmark` reference implementation (0.31.2) and produces the same
output on the supported subset: thematic breaks, ATX and setext headings,
indented and fenced code blocks, paragraphs, block quotes, lists, backslash
escapes, entity references (`&amp; &lt; &gt; &quot;` and numeric ones), code
spans, emphasis, inline links and images, autolinks, and hard/soft line
breaks. Raw HTML, link reference definitions (and reference links) and
extensions are not supported.

The parser is two-phase, as in Appendix A of the CommonMark spec: a block
phase reads the input line by line and builds the block tree; an inline
phase parses each paragraph and heading with a delimiter stack, a bracket
stack and the `openers_bottom`-bounded "process emphasis" algorithm. A single
iterative walk renders the tree, so deeply nested input is handled without
recursion. Total running time is O(N + L·D).

## Layout

```
src/cmarkpy/
    nodes.py      tree node classes and type constants
    escaping.py   HTML escaping, entity decoding, URL encoding
    scanners.py   link destination / title / autolink scanners
    blocks.py     phase 1: block structure
    inlines.py    phase 2: inline parsing and emphasis
    render.py     HTML renderer
    api.py        parse() and convert()
    cli.py        command-line interface
tests/            pytest suite (including the CommonMark spec examples)
build.sh, run.sh  build and run scripts
```

## Building

There is nothing to install; the only build step byte-compiles the sources:

```
./build.sh
```

(`pip install .` also works and installs a `cmarkpy` command.) Python 3.11
or newer is required; the standard library is the only dependency.

## Command line

Markdown on stdin, HTML on stdout (UTF-8):

```
printf '# Hi *there*\n' | ./run.sh
./run.sh README.md            # or read from a file
python3 -m cmarkpy --help     # with PYTHONPATH=src
```

The exit status is 0 on success.

## Library

```python
from cmarkpy import convert, parse, render_html

html = convert("Hello *world*\n")
# '<p>Hello <em>world</em></p>\n'

doc = parse("# Title\n\n- a\n- b\n")      # a tree of cmarkpy.nodes.Node
for block in doc.children():
    print(block.type_name)                 # heading, list
print(render_html(doc))
```

Public API:

* `convert(text: str) -> str` – Markdown to HTML.
* `parse(text: str) -> Node` – build the document tree (blocks and inlines).
* `render_html(root: Node) -> str` – render a tree to HTML.
* `cmarkpy.nodes` – node type constants (`PARAGRAPH`, `EMPH`, ...) and the
  `Node` / `LinkNode` / `Block` classes (`type`, `literal`, `first_child`,
  `next`, `children()`; links and images also have `dest` and `title`).

## Tests

```
python3 -m pytest
```
