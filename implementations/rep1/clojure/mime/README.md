# mime

A MIME email parser in Clojure, written from scratch on the JDK alone (no
email, MIME, header, address, date, quoted-printable or base64 library is used).

It reads a mailbox — an mbox file or a directory of `.eml` files — parses every
message as RFC 5322 / RFC 2045–2047 / RFC 2231 mail, and writes a normalised text
dump of each message plus the decoded bytes of every attachment. The behaviour
is defined by `problems/mime/SPEC.md`.

It handles: header unfolding, RFC 2047 encoded words, structured headers with
RFC 2231 parameter continuations, lenient address lists (groups, comments,
quoted names), dates in closed form, quoted-printable and base64 bodies, nested
`multipart/*` and `message/rfc822` trees, and the character sets US-ASCII,
UTF-8 (maximal-subpart replacement), Latin-1 and cp1252.

## Requirements

Clojure 1.12.6 (the `clojure` CLI) on Java 27. The tests additionally use
`org.clojure/test.check` and the Cognitect test-runner.

## Build

```sh
./build.sh
```

This AOT-compiles the command-line tool into `classes/` and records the
classpath (from `deps.edn`) in `.classpath`.

## Command line

```sh
./run.sh <input path> <output directory>
```

`<input path>` is an mbox file or a directory; in a directory every regular file
whose name ends in `.eml` is one message, processed in byte order of the name.
The output directory is created if needed and receives:

```
summary.txt                 one line per message
messages/NNNN.txt           the dump of message NNNN
parts/NNNN/PPP.bin          the decoded content of attachment PPP of message NNNN
```

Exit status is 0 on success; a usage or I/O error prints a message to stderr
and exits non-zero. (`clojure -M:run <input> <output>` does the same without
building.)

## Library

The library lives under `src/mime/`, one namespace per responsibility:

| Namespace        | Responsibility                                                   |
|------------------|------------------------------------------------------------------|
| `mime.core`      | public facade: parse a message or mailbox, render, write output |
| `mime.message`   | one message as data: headers, addresses, date, parts, bodies     |
| `mime.part`      | MIME tree building, multipart delimiter scanning, part numbering |
| `mime.header`    | header block parsing and unfolding                               |
| `mime.params`    | `Content-Type`-style values and RFC 2231 parameters              |
| `mime.rfc2047`   | encoded words and unstructured/display text decoding             |
| `mime.address`   | address-list tokeniser and matcher                               |
| `mime.date`      | date parsing and calendar arithmetic                             |
| `mime.transfer`  | quoted-printable and base64                                      |
| `mime.charset`   | ASCII / Latin-1 / cp1252 / UTF-8 decoding                        |
| `mime.mailbox`   | mbox splitting and `.eml` directory listing                      |
| `mime.render`    | the text dump format and escaping                                |
| `mime.bytes`, `mime.text` | byte-array and string helpers                           |
| `mime.main`      | command-line entry point                                         |

Example:

```clojure
(require '[mime.core :as mime])

(def msg
  (mime/parse-message
   (.getBytes (str "From: Ann <ann@example.com>\n"
                   "Subject: =?utf-8?Q?Caf=C3=A9?=\n"
                   "Content-Type: text/plain; charset=utf-8\n"
                   "\n"
                   "hello\n")
              "UTF-8")))

(get-in msg [:addresses "from"])   ;=> [{:display "Ann", :spec "ann@example.com"}]
(:text msg)                        ;=> 0   (index of the text body part)
(mime.message/part-text (first (:parts msg)))  ;=> "hello\n"

;; Whole mailboxes:
(def entries (mime/parse-mailbox "inbox.mbox"))   ; [{:number 1 :source-id "mbox:1" :message ...}]
(mime/convert! "inbox.mbox" "out/")               ; what run.sh does
```

`parse-message` returns a plain map (`:size`, `:fields`, `:addresses`, `:date`,
`:parts`, `:text`, `:html`, `:attachments`); see the docstring of
`mime.message/parse`. Everything operates on bytes: input is never assumed to be
valid text.

## Tests

```sh
clojure -M:test
```

runs the unit tests, test.check properties and end-to-end fixtures under `test/`
with the Cognitect test-runner.
