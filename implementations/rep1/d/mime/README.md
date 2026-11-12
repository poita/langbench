# mime

A MIME email parser written in D, with no dependencies beyond Phobos. It reads
a mailbox (an mbox file or a directory of `.eml` files), parses every message
as RFC 5322 / RFC 2045–2047 / RFC 2231 email, and writes a normalised text dump
of each message plus the decoded bytes of every attachment.

All the parsing is hand-written: header unfolding, encoded words, structured
header parameters with RFC 2231 continuations, address lists, dates,
quoted-printable and base64, and the UTF-8 / Latin-1 / cp1252 decoders. Nothing
from Phobos' (or anyone else's) email, MIME, date or codec support is used.

## Building

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh          # dub build -b release --compiler=ldc2  ->  bin/mime
dub test --compiler=ldc2
```

## Command-line use

```
bin/mime <input> <output-directory>     # or: ./run.sh <input> <output-directory>
```

`<input>` is an mbox file, or a directory whose `*.eml` files (sorted by
name) are the messages. The tool writes

```
<output>/summary.txt                  one line per message
<output>/messages/NNNN.txt            headers, addresses, date, MIME tree, body, attachments
<output>/parts/NNNN/PPP.bin           decoded bytes of each attachment
```

and exits 0 on success (1 on an I/O error, 2 on bad usage). The exact format
is defined in `SPEC.md` of the task this project implements.

## Library

`import mime;` re-exports every module. The modules, by responsibility:

| Module | Purpose |
|---|---|
| `mime.mailbox` | mbox splitting, `.eml` directories |
| `mime.lines` | line splitting, CRLF normalisation |
| `mime.header` | header block parsing and unfolding |
| `mime.charset` | ASCII / UTF-8 (maximal subpart) / Latin-1 / cp1252 |
| `mime.encodedword` | RFC 2047 encoded words, `decodeUnstructured`, `decodeDisplay` |
| `mime.params` | `Content-Type`-style values and RFC 2231 parameters |
| `mime.address` | address-list tokeniser and matcher |
| `mime.date` | `Date` parsing, `daysFromCivil` and its inverse |
| `mime.transfer` | quoted-printable, base64, Adler-32 |
| `mime.multipart` | boundary scanning |
| `mime.part` | `Message` / `Part` tree, body and attachment selection |
| `mime.escape` | the dump format's escaping |
| `mime.report` | rendering the dump and writing the output directory |

### Example

```d
import mime;
import std.stdio;

void main()
{
    auto raw = cast(const(ubyte)[]) (
        "From: =?utf-8?B?SsO2cmc=?= <j@example.de>\r\n"
      ~ "Date: Mon, 1 Sep 2025 12:30:00 +0200\r\n"
      ~ "Content-Type: multipart/mixed; boundary=X\r\n\r\n"
      ~ "--X\r\nContent-Type: text/plain; charset=iso-8859-1\r\n\r\ncaf\xe9\r\n"
      ~ "--X\r\nContent-Type: application/pdf; name=a.pdf\r\n"
      ~ "Content-Transfer-Encoding: base64\r\n\r\nJVBERg==\r\n--X--\r\n");

    auto msg = parseMessage(raw, "example");

    auto from = parseAddressList(msg.header("from").raw)[0];
    writeln(from.display, " <", from.spec, ">");    // Jörg <j@example.de>
    writeln(parseDate(msg.header("date").raw).utc);  // 2025-09-01T10:30:00Z
    writeln(msg.textBody.text);                      // café
    foreach (a; msg.attachments)
        writeln(a.filename, " ", a.content.length);  // a.pdf 4
}
```

To process a whole mailbox and produce the dump, use
`writeReport(readMailbox(path), outputDir)`.

## Layout

```
source/mime/   library modules (each with its own unittest blocks)
source/app.d   the command-line tool
dub.sdl        configurations: cli (default), library, unittest
build.sh, run.sh
```

## Tests

`dub test --compiler=ldc2` runs the `unittest` blocks of every module: the
examples from the specification for each decoder, plus a full dump of the
specification's worked example.
