# mime

A MIME email parser written in D. It reads a mailbox (an mbox file, or a
directory of `.eml` files), parses every message as RFC 5322 / RFC 2045–2047
email, and writes a normalised text dump of each message plus the decoded
bytes of every attachment.

All of the parsing is hand-written on top of Phobos' basic containers and file
I/O only: header unfolding, RFC 2047 encoded words, RFC 2231 parameters,
address lists, dates, charset decoding (ASCII, UTF-8 with the maximal-subpart
replacement rule, Latin-1, cp1252), quoted-printable and base64. There are no
dependencies, and no Phobos e-mail, date, base64 or UTF-8 decoding is used.

The behaviour is defined by `problems/mime/SPEC.md`; the design follows
`problems/mime/APPROACH.md` (single thread, one message at a time, byte slices
of one LF-normalised buffer, presized output buffers, one write per file).

## Building

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh          # dub build -b release --compiler=ldc2  → bin/mime
dub test --compiler=ldc2
```

## Command line

```sh
./run.sh <input path> <output directory>
# or: bin/mime <input path> <output directory>
```

`<input path>` is an mbox file or a directory; in a directory every regular
file whose name ends in `.eml` is one message, processed in byte order of the
names. The tool exits 0 on success, 1 on an I/O error, and 2 on bad usage.

It creates, inside the output directory:

```
summary.txt                  messages <count>, then one line per message
messages/NNNN.txt            [message] [headers] [addresses] [date]
                             [structure] [body] [attachments]
parts/NNNN/PPP.bin           decoded bytes of each attachment
```

Example:

```sh
$ ./run.sh inbox.mbox out
$ cat out/summary.txt
messages 1
0001 source="mbox:1" bytes=427 parts=3 attachments=1 text=1 html=-
$ sed -n '/\[structure\]/,/^$/p' out/messages/0001.txt
[structure]
0 multipart/mixed cte=7bit boundary="X" parts=2 preamble=9 epilogue=0
  1 text/plain charset=iso-8859-1 cte=7bit size=4 adler32=04680214 role=text
  2 application/octet-stream cte=base64 disposition=attachment filename="a.bin" size=4 adler32=000e0007 role=attachment
```

See SPEC.md for the exact format of every section.

## Library

`import mime;` pulls in the whole API; each module can also be imported alone.

| Module | Responsibility |
|---|---|
| `mime.mailbox` | `splitMbox`, `Mailbox` (mbox file or `.eml` directory) |
| `mime.message` | `parseMessage`, the `Message` / `Part` tree, body and attachment selection |
| `mime.header` | header block parsing, unfolding, `HeaderField` |
| `mime.params` | `Content-Type`-style values and RFC 2231 parameters |
| `mime.encodedword` | RFC 2047 words, `decodeUnstructured`, `decodeDisplay` |
| `mime.address` | address-list tokeniser and parser |
| `mime.date` | `Date` parsing, civil-date arithmetic |
| `mime.charset` | `decode(bytes, charset)` |
| `mime.transfer` | base64 / quoted-printable, `decodeBody` |
| `mime.adler32` | Adler-32 |
| `mime.render` | the text dump (`renderMessage`, `putEscaped`, ...) |
| `mime.convert` | `convertMailbox(input, outputDir)`, what the CLI calls |
| `mime.buffer`, `mime.ascii`, `mime.syntax` | shared helpers |

Parsing a message and looking inside it:

```d
import std.file : read;
import std.stdio : writeln;
import mime;

void main()
{
    auto msg = parseMessage(cast(const(ubyte)[]) read("message.eml"));

    foreach (ref f; msg.headers)
        if (f.name == "subject")
            writeln(f.displayValue());          // RFC 2047 words decoded

    foreach (ref a; parseAddressList(findHeader(msg.headers, "from").rawValue))
        writeln(a.display, " <", a.spec, ">");

    if (msg.textIndex != noPart)
        writeln(msg.text);                      // decoded text/plain body

    foreach (idx; msg.attachments)
    {
        auto p = msg.parts[idx];
        writeln(p.mediaType, " ", p.hasFilename ? p.filename : "-", " ", p.content.length);
    }
}
```

To use the library from another dub project, depend on this package; its
`library` configuration excludes the command-line entry point.

## Layout

```
dub.sdl            manifest (configurations: application, library, unittest)
build.sh run.sh    build and run wrappers
source/app.d       command-line tool
source/mime/       the library
tests/             unit tests (one file per library module), run by `dub test`
```
