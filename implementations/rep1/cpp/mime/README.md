# mime

A small, dependency-free C++17 library and command-line tool that parses
RFC 5322 / RFC 2045–2047 email — an mbox file or a directory of `.eml` files —
and writes a normalised text dump of every message plus the decoded bytes of
every attachment.

Everything is implemented from scratch on the standard library: line and header
parsing, RFC 2047 encoded words, RFC 2231 parameters, address lists, dates,
quoted-printable and base64, Latin-1/cp1252/UTF-8 decoding and MIME tree
building. The exact behaviour (including all lenient-parsing rules) is defined
by the problem specification this project implements.

## Layout

| Path | Contents |
|---|---|
| `include/mime/` | public headers (`mime/mime.hpp` includes them all) |
| `src/` | library implementation, one module per header |
| `cli/main.cpp` | the `mime` command |
| `tests/` | GoogleTest unit tests |

Modules: `text` (lines, quoting, escaping), `charset`, `transfer`
(quoted-printable/base64), `rfc2047`, `header`, `params` (Content-Type & RFC
2231), `address`, `date`, `checksum` (Adler-32), `message` (part tree and body
selection), `mailbox` (mbox/directory input), `report` (the text dump).

## Build

Requires a C++17 compiler and CMake ≥ 3.20; GoogleTest is only needed for the tests.

```sh
./build.sh                 # Release build into build/
ctest --test-dir build     # run the unit tests
```

or, by hand: `cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build`.
Options: `-DMIME_BUILD_TESTS=OFF`, `-DMIME_BUILD_CLI=OFF`.

## Command line

```
mime <input path> <output directory>
./run.sh <input path> <output directory>      # same, from any directory
```

`<input path>` is an mbox file, or a directory whose `*.eml` files (sorted by
name) are the messages. The output directory receives:

```
summary.txt               one line per message
messages/NNNN.txt         [message] [headers] [addresses] [date] [structure] [body] [attachments]
parts/NNNN/PPP.bin        decoded bytes of each attachment
```

Exit status is 0 on success, 1 on I/O errors and 2 on bad usage.

## Library example

```cpp
#include <iostream>
#include "mime/mime.hpp"

int main() {
  mime::Message m = mime::parse_message(
      "From: Ann <ann@example.com>\r\n"
      "Subject: =?utf-8?Q?Caf=C3=A9?=\r\n"
      "Content-Type: text/plain; charset=utf-8\r\n"
      "\r\n"
      "hello\r\n",
      "example");

  for (const mime::HeaderField& f : m.root.headers)
    std::cout << f.key() << ": " << mime::display_value(f) << "\n";

  for (const mime::Address& a : mime::parse_address_list(m.root.headers[0].raw_value))
    std::cout << a.display << " <" << a.spec << ">\n";   // Ann <ann@example.com>

  if (m.text_index)
    std::cout << mime::part_text(*mime::flatten(m)[static_cast<std::size_t>(*m.text_index)]);

  // Or render the same dump the CLI writes:
  std::cout << mime::render_message(m, 1);
}
```

Link against the `mime::mimelib` CMake target (`add_subdirectory(mime)` then
`target_link_libraries(app PRIVATE mime::mimelib)`).

## API overview

- `mime::split_mbox`, `read_eml_directory`, `read_mailbox` → `std::vector<RawMessage>`
- `mime::parse_message(bytes, source_id)` → `Message` (a `Part` tree, text/html
  body indices and attachment indices)
- `mime::parse_headers`, `decode_unstructured`, `decode_display`,
  `parse_structured`, `parse_address_list`, `parse_date`
- `mime::decode(bytes, charset)`, `decode_base64`, `decode_quoted_printable`,
  `adler32`
- `mime::render_message`, `render_summary`, `write_output`, `process_mailbox`

All text produced by the library is valid UTF-8; input is treated as bytes.
