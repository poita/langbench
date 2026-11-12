# commonmark-lite

A from-scratch **CommonMark → HTML** converter in Haskell, written as a
reusable library plus a thin command-line tool. It implements the subset of
CommonMark 0.31.2 with no raw HTML, no link reference definitions and no
extensions, and reproduces the output of the `cmark` reference implementation
on that subset byte for byte.

Supported: thematic breaks, ATX and setext headings, indented and fenced code
blocks, paragraphs, block quotes, (nested, tight/loose) lists, backslash
escapes, entities (numeric, plus `&amp; &lt; &gt; &quot;`), code spans,
emphasis and strong emphasis (full delimiter-run rules), inline links and
images, autolinks, hard and soft line breaks.

The implementation follows `cmark`'s design:

1. **Blocks** (`Commonmark.Block`): a line-by-line parser matches each line
   against the chain of open blocks, opens new blocks and adds text to the
   innermost leaf. O(N + L·D) for N bytes, L lines and nesting depth D.
2. **Inlines** (`Commonmark.Inline`): paragraph/heading content is parsed
   left to right with a delimiter stack, a bracket stack and the
   process-emphasis algorithm (with `openers_bottom` bounds and cmark's
   backtick memo). Inline nodes are kept in arrays as a doubly linked list, so
   removing delimiters and wrapping nodes in emphasis/links costs O(1) per
   entry. Linear time per block, and no recursion in the parser, so thousands
   of nested brackets or emphasis levels are fine.
3. **Rendering** (`Commonmark.Html`): one walk over the tree producing a
   `Builder`.

Only GHC's bundled libraries (`base`, `bytestring`, `array`) are used.

## Building

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh          # cabal build; copies the binary to bin/commonmark
```

or simply `cabal build`.

## Command-line usage

Markdown (UTF-8, LF line endings) on stdin, HTML on stdout:

```sh
printf '# Hi\n\nSome *emphasis* and a [link](/url "title").\n' | ./run.sh
```

```html
<h1>Hi</h1>
<p>Some <em>emphasis</em> and a <a href="/url" title="title">link</a>.</p>
```

`run.sh` takes no arguments and works from any directory.

## Library usage

```haskell
import qualified Data.ByteString.Char8 as BC
import Commonmark

main :: IO ()
main = do
  let md = BC.pack "- one\n- two *2*\n"
  -- straight to HTML
  BC.putStr (commonmarkToHtml md)
  -- or work with the document tree
  print (parseDocument md)
  -- [List BulletList True [[Paragraph [Text "one"]],
  --                        [Paragraph [Text "two ",Emph [Text "2"]]]]]
```

Modules:

| Module                     | Contents                                              |
|----------------------------|-------------------------------------------------------|
| `Commonmark`               | `commonmarkToHtml`, `parseDocument`, re-exports       |
| `Commonmark.Types`         | `Block`, `Inline`, `ListType`                         |
| `Commonmark.Block`         | `parseBlocks :: ByteString -> [Block ByteString]`     |
| `Commonmark.Inline`        | `parseInlines :: ByteString -> [Inline]`              |
| `Commonmark.Html`          | `renderHtml`, `renderInlines`, `escapeHtml`, `escapeHref` |
| `Commonmark.Internal.Text` | byte-level helpers (character classes, entities)      |

Input and output are strict UTF-8 `ByteString`s; the converter works on bytes
because all CommonMark syntax is ASCII.

## Tests

```sh
cabal test
```

The `hspec` suite contains the 473 CommonMark specification examples that fall
in the supported subset, unit tests for each stage and QuickCheck properties
(totality and well-formedness on random Markdown-like input).
