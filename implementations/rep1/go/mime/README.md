# mime

A MIME email parser written in Go with no dependencies beyond the standard
library. It reads a mailbox (an mbox file or a directory of `.eml` files),
parses every message as RFC 5322 / RFC 2045–2047 mail, and writes a normalised
text dump of each message plus the decoded bytes of every attachment.

The parsing and decoding (headers, encoded words, RFC 2231 parameters,
addresses, dates, base64, quoted-printable, charsets, Adler-32) are all
implemented here by hand; no `net/mail`, `mime`, `encoding/base64`,
`hash/adler32` or similar package is used. The format is specified in
`problems/mime/SPEC.md` of the surrounding workspace.

## Build

Requires Go 1.27 or later.

```
./build.sh          # writes bin/mime
go test ./...       # unit tests
```

`build.sh` and `run.sh` can be run from any directory.

## Command line

```
run.sh <input path> <output directory>
```

`<input path>` is an mbox file, or a directory whose `*.eml` files are the
messages (processed in byte-wise name order). The output directory is created
if needed and receives:

```
summary.txt                  messages <count>, then one line per message
messages/NNNN.txt            the dump of message NNNN
parts/NNNN/PPP.bin           the decoded content of attachment PPP of message NNNN
```

Nothing is read from stdin. The exit status is 0 on success, 1 if the input
cannot be read or the output cannot be written, and 2 on a usage error.

Each `messages/NNNN.txt` has seven sections: `[message]`, `[headers]`,
`[addresses]`, `[date]`, `[structure]`, `[body]`, `[attachments]`.

## Library

Each package has one responsibility and is usable on its own:

| Package | Responsibility |
|---|---|
| `mailbox` | Open an mbox or a directory of `.eml` files; yields raw messages. |
| `lines` | CRLF normalisation and the LF/CRLF line model. |
| `header` | Split a message into header fields and body; unfolding; `Collapse`. |
| `rfc2047` | Encoded-word recognition and decoding; `DecodeUnstructured`, `DecodeDisplay`. |
| `params` | `Content-Type`-style values: parameters, quoted strings, RFC 2231. |
| `address` | Address-list tokeniser and mailbox/group parser. |
| `date` | `Date` header parser, `DaysFromCivil`/`CivilFromDays`, UTC and offset rendering. |
| `charset` | ASCII, UTF-8 (maximal-subpart replacement), Latin-1, windows-1252 decoding. |
| `transfer` | Base64 and quoted-printable decoding. |
| `checksum` | Adler-32. |
| `message` | Builds the MIME part tree; body and attachment selection. |
| `render` | Formats a parsed message as the text dump; escaping. |
| `export` | Writes a whole mailbox to an output directory. |

### Example

```go
package main

import (
	"fmt"

	"mimedump/address"
	"mimedump/date"
	"mimedump/message"
)

func main() {
	raw := []byte("From: Jörg <j@example.de>, bob@example.org\r\n" +
		"Date: Mon, 1 Sep 2025 12:30:00 +0200\r\n" +
		"Content-Type: multipart/mixed; boundary=X\r\n\r\n" +
		"--X\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nhello\r\n" +
		"--X\r\nContent-Type: application/pdf\r\n" +
		"Content-Disposition: attachment; filename=a.pdf\r\n" +
		"Content-Transfer-Encoding: base64\r\n\r\nJVBERg==\r\n--X--\r\n")

	m := message.Parse(raw)
	fmt.Println(m.Text.Text)                // hello
	fmt.Println(m.Attachments[0].Filename)  // a.pdf
	fmt.Printf("%x\n", m.Attachments[0].Content)

	for _, a := range address.ParseList(" Jörg <j@example.de>, bob@example.org") {
		fmt.Printf("%q %q\n", a.Display, a.Spec)
	}
	if d, ok := date.Parse("Mon, 1 Sep 2025 12:30:00 +0200"); ok {
		fmt.Println(d.UTC(), d.Offset(), d.Epoch) // 2025-09-01T10:30:00Z +0200 1756722600
	}
}
```

To dump a whole mailbox programmatically:

```go
mb, _ := mailbox.Open("inbox.mbox")
err := export.Write(mb, "out")
```

## Layout

```
cmd/mime/        the command-line tool (thin wrapper over export.Write)
internal/scan/   quoted-string / comment / literal scanners shared by parsers
<package>/       library packages listed above, each with *_test.go files
```
