# mime

A MIME email parser in Go with no dependencies beyond the standard library.
It reads a mailbox (an mbox file or a directory of `.eml` files), parses every
message as RFC 5322 / RFC 2045–2047 email, and writes a normalised text dump of
each message plus the decoded bytes of every attachment.

All the parsing and decoding is written from scratch: header unfolding,
RFC 2047 encoded words, RFC 2231 parameters, address lists, dates,
quoted-printable and base64, and the character sets (US-ASCII, UTF-8 with
maximal-subpart replacement, ISO-8859-1, windows-1252). The standard library's
`net/mail`, `mime`, `encoding/base64` and friends are deliberately not used.

The exact input and output formats are specified in `problems/mime/SPEC.md`.

## Build

Requires Go 1.27.1.

```sh
./build.sh          # builds bin/mime
go test ./...       # runs the unit tests
```

## Command line

```
mime <input path> <output directory>
```

`<input path>` is an mbox file or a directory; in a directory every regular
`*.eml` file is one message, processed in byte order of file name. The output
directory must exist (it is created if missing) and receives:

```
summary.txt                  one line per message
messages/NNNN.txt            [message] [headers] [addresses] [date] [structure] [body] [attachments]
parts/NNNN/PPP.bin           the decoded bytes of each attachment
```

`run.sh <input> <output>` runs the built binary from any directory. The exit
status is 0 on success and non-zero on I/O errors or bad usage.

## Library

Package layout (import path prefix `example.com/mime`):

| Package | Responsibility |
|---|---|
| `charset` | decode bytes in a named charset; hand-written UTF-8 decoder |
| `transfer` | quoted-printable and base64 decoding |
| `rfc2047` | encoded words; unstructured and display-name decoding |
| `header` | header block splitting, unfolding, field lookup, `Content-Type`-style parameters with RFC 2231 |
| `address` | address-list tokeniser and parser |
| `date` | `Date` header parsing, closed-form calendar arithmetic |
| `checksum` | Adler-32 |
| `mailbox` | mbox splitting and `.eml` directory loading |
| `message` | MIME part tree, body selection, attachments |
| `dump` | the text dump and writing the output directory |
| `cmd/mime` | the command-line tool |

Example:

```go
package main

import (
	"fmt"

	"example.com/mime/message"
)

func main() {
	raw := []byte("From: Ann <ann@example.com>\r\n" +
		"Subject: =?utf-8?Q?Caf=C3=A9?=\r\n" +
		"Date: Mon, 1 Sep 2025 12:30:00 +0200\r\n" +
		"Content-Type: text/plain; charset=iso-8859-1\r\n\r\n" +
		"caf\xe9\r\n")

	m := message.Parse(raw)
	for _, a := range m.Addresses("from") {
		fmt.Printf("%q <%s>\n", a.Display, a.Spec) // "Ann" <ann@example.com>
	}
	if _, ok := m.Fields().Get("subject"); ok {
		f, _ := m.Fields().Get("subject")
		fmt.Println(f.Display()) // Café
	}
	if _, _, d, valid := m.Date(); valid {
		fmt.Println(d.UTC()) // 2025-09-01T10:30:00Z
	}
	fmt.Printf("%q\n", m.TextBody.Text()) // "café\n"
}
```

To process a whole mailbox and write the dump, use `mailbox.Load` and
`dump.WriteAll`.

## Design notes

* Each message has its CRLFs normalised once; a multipart body is scanned only
  for its own delimiter lines, so building the part tree costs O(N·depth).
* Header values are tokenised in a single pass; dates use `days_from_civil`
  and its inverse, so each date costs O(1).
