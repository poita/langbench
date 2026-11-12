# mime

A from-scratch MIME email parser written in Rust, using only the standard
library. It reads a mailbox (an mbox file or a directory of `.eml` files),
parses every message as RFC 5322 / RFC 2045–2047 / RFC 2231 email, and writes
a normalised text dump of each message plus the decoded bytes of every
attachment.

Everything is implemented in this crate: line and header parsing, RFC 2047
encoded words, RFC 2231 parameters, address lists, dates, quoted-printable and
base64, the UTF-8 / Latin-1 / windows-1252 decoders and the MIME part tree.
No email, MIME, date or transfer-encoding library is used.

## Building

```sh
./build.sh            # or: cargo build --release
```

The binary is `target/release/mime`; `./run.sh` runs it from any directory.

## Command line

```
mime <input path> <output directory>
```

* `<input path>` is either an mbox file or a directory. In a directory every
  regular file whose name ends in `.eml` is one message, processed in
  byte-wise name order.
* `<output directory>` receives the results (it is created if missing):

```
summary.txt                  one line per message
messages/NNNN.txt            header, address, date, structure and body dump
parts/NNNN/PPP.bin           decoded bytes of each attachment
```

Messages are numbered from 1 and parts from 0 in depth-first pre-order.
Text output is UTF-8 with LF line endings. The exact formats are defined in
`problems/mime/SPEC.md`.

```sh
./run.sh mailbox.mbox out/
cat out/summary.txt
```

## Library

```rust
use mime::Message;

let raw = b"From: Ann <ann@example.com>\r\n\
            Subject: =?utf-8?Q?Caf=C3=A9?=\r\n\
            Content-Type: text/plain; charset=utf-8\r\n\
            \r\n\
            hello\r\n";
let msg = Message::parse(raw);

assert_eq!(msg.addresses("from")[0].spec, "ann@example.com");
assert_eq!(msg.header("subject").unwrap().display_value(), "Café");
let body = msg.text_body.unwrap();
assert_eq!(msg.parts[body].text.as_deref(), Some("hello\n"));
```

To process a whole mailbox and write the dump tree:

```rust
mime::convert(std::path::Path::new("mailbox.mbox"), std::path::Path::new("out"))?;
```

### Modules

| Module | Responsibility |
|---|---|
| `mailbox` | mbox splitting, directory listing |
| `message` | `Message`: parts, selected bodies, attachments, addresses, date |
| `part` | MIME tree construction (multipart, `message/rfc822`, leaves) |
| `header` | header block parsing and unfolding |
| `rfc2047` | encoded words, `decode_unstructured`, `decode_display` |
| `params` | `Content-Type`-style values and RFC 2231 parameters |
| `address` | address-list tokeniser and parser |
| `date` | `Date` parsing and calendar arithmetic |
| `charset`, `transfer`, `checksum` | charset decoding, quoted-printable/base64, Adler-32 |
| `output` | escaping, dump rendering, writing the output tree |

## Tests

```sh
cargo test
```

Unit tests live next to the code, `tests/` holds end-to-end and library-level
tests, and the crate's doc example is tested too. The problem's own suite is
run with `python3 run_tests.py mime -- mime/run.sh` from the workspace root.

## Complexity

Each nesting level scans only its own body, so the part tree costs O(N·d)
for a message of N bytes nested d levels deep; header values are tokenised
once, and dates use closed-form calendar arithmetic.
