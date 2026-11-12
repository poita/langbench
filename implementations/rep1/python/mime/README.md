# mimedump

A from-scratch MIME email parser. It reads a mailbox (an mbox file, or a
directory of `.eml` files), parses every message as RFC 5322 / RFC 2045–2047 /
RFC 2231 email, and writes a normalised text dump of each message together with
the decoded bytes of every attachment.

Everything is hand-written on top of the Python standard library: header and
address parsing, RFC 2047 encoded words, RFC 2231 parameters, dates, charset
decoding, quoted-printable and base64, MIME tree building and Adler-32. The
`email`, `mailbox`, `quopri`, `base64`, `binascii`, `zlib` modules and friends
are not used by the package (the tests use `binascii`/`zlib` as oracles).

## Building

No dependencies and no install step. `build.sh` byte-compiles the sources;
`pyproject.toml` (setuptools, `src/` layout) allows `pip install .` as usual.

```sh
./build.sh
```

Requires Python 3.12 or newer (developed on 3.14).

## Command-line use

```sh
./run.sh <input path> <output directory>
# or, when installed:   mimedump <input path> <output directory>
# or, from the source tree:   PYTHONPATH=src python3 -m mimedump <in> <out>
```

* `<input path>` is an mbox file, or a directory whose `*.eml` files (sorted by
  name) are the messages.
* The output directory is created if needed and receives:

```
summary.txt                  one line per message
messages/NNNN.txt            seven-section dump: message, headers, addresses,
                             date, structure, body, attachments
parts/NNNN/PPP.bin           decoded bytes of each attachment
```

The exit status is 0 on success, 1 on an I/O error and 2 on bad usage.
The exact formats are specified in `problems/mime/SPEC.md` of the surrounding
repository; the main rules are summarised in the module docstrings.

## Library use

```python
from mimedump import parse_message, read_mailbox, render_message

raw = (
    b"From: Ann <ann@example.com>\r\n"
    b"Subject: =?utf-8?Q?Caf=C3=A9?=\r\n"
    b"Date: Mon, 1 Sep 2025 12:30:00 +0200\r\n"
    b"Content-Type: multipart/mixed; boundary=X\r\n"
    b"\r\n"
    b"--X\r\nContent-Type: text/plain; charset=iso-8859-1\r\n\r\ncaf\xe9\r\n"
    b"--X\r\nContent-Type: application/octet-stream\r\n"
    b"Content-Disposition: attachment; filename=a.bin\r\n"
    b"Content-Transfer-Encoding: base64\r\n\r\nAAECAw==\r\n--X--\r\n"
)

msg = parse_message(raw)
print(msg.addresses("from"))        # [Address(display='Ann', spec='ann@example.com')]
print(msg.date.utc)                 # 2025-09-01T10:30:00Z
print(msg.text_part.text)           # café
for part in msg.attachments:
    print(part.index, part.content_type, part.filename, part.content)
    # 2 application/octet-stream a.bin b'\x00\x01\x02\x03'

# Whole mailboxes, and the dump format used by the CLI:
for number, item in enumerate(read_mailbox("archive.mbox"), 1):
    print(render_message(parse_message(item.data), number, item.source_id))
```

### Modules

| Module | Responsibility |
|---|---|
| `mailbox` | mbox splitting, `.eml` directory listing |
| `headers` | header block parsing, unfolding, `Header` |
| `charsets` | ASCII / UTF-8 (maximal-subpart) / Latin-1 / cp1252 decoding |
| `rfc2047` | encoded words, `decode_unstructured`, `decode_display` |
| `structured` | `Content-Type`-style values and RFC 2231 parameters |
| `addresses` | address-list tokeniser and parser |
| `dates` | `Date` parsing, `days_from_civil` and its inverse |
| `transfer` | quoted-printable and base64 |
| `parts` | MIME part tree (boundaries, preamble/epilogue, `message/rfc822`) |
| `selection` | text/HTML body choice and attachment list |
| `message` | `Message` / `parse_message`, the top-level API |
| `report` | escaping and the text dump; `dump_mailbox` |
| `cli` | the command-line tool |

## Tests

```sh
python3 -m pytest          # from this directory; configured via pyproject.toml
```

`tests/test_conformance.py` additionally runs the repository's example suite
(`problems/mime/tests`) when it is found next to this project, and is skipped
otherwise.
