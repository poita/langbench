# mime-parser

A hand-written MIME email parser in Haskell, with a command-line tool that
dumps a mailbox as normalised text plus the decoded bytes of every attachment.

It parses RFC 5322 messages, RFC 2045 MIME structure, RFC 2047 encoded words
and RFC 2231 parameter continuations. Nothing is delegated to an email, MIME,
date, charset or base64/quoted-printable library: the only dependencies are
GHC's bundled `base`, `bytestring`, `containers`, `directory` and `filepath`
(plus `hspec` and `QuickCheck` for the tests).

## Build

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh          # cabal build, then copies the binary to bin/mime-dump
cabal test          # run the unit and property tests
```

## Command line

```sh
./run.sh <input path> <output directory>
```

The input is either an mbox file or a directory of `*.eml` files (processed in
byte order of their names). The output directory receives:

```
summary.txt                  one line per message
messages/NNNN.txt            [message] [headers] [addresses] [date]
                             [structure] [body] [attachments]
parts/NNNN/PPP.bin           decoded content of each attachment
```

The exit code is 0 on success. The exact format is defined in
`problems/mime/SPEC.md` of the task this project implements.

## Library

| Module              | Responsibility                                          |
|---------------------|---------------------------------------------------------|
| `Mime`              | Public API and `dumpMailbox`                            |
| `Mime.Mailbox`      | mbox splitting, directory listing                       |
| `Mime.Header`       | header block, unfolding, field lookup                   |
| `Mime.EncodedWord`  | RFC 2047 words, `decodeUnstructured`, `decodeDisplay`   |
| `Mime.Params`       | `Content-Type`-style values, RFC 2231                   |
| `Mime.Address`      | address-list tokeniser and matcher                      |
| `Mime.Date`         | `Date` parsing, calendar arithmetic                     |
| `Mime.Transfer`     | quoted-printable and base64                             |
| `Mime.Charset`      | ASCII, Latin-1, cp1252, UTF-8 (maximal subpart)         |
| `Mime.Part`         | MIME part tree                                          |
| `Mime.Message`      | body/attachment selection, addresses, date              |
| `Mime.Render`       | the text dump format                                    |
| `Mime.Bytes`        | line endings, Adler-32                                  |

Example:

```haskell
import qualified Data.ByteString.Char8 as B
import Mime

main :: IO ()
main = do
  let raw = B.pack "From: Ann <ann@example.com>\nSubject: =?utf-8?Q?Caf=C3=A9?=\n\nhi\n"
      msg = parseMessage raw
  print (map (\a -> (addrDisplay a, addrSpec a)) (messageAddresses' msg))
  putStr (renderMessage 1 "example" msg)
  where
    messageAddresses' m = concatMap (parseAddressList . fieldRaw) (msgHeaders m)
```

To process whole mailboxes use `readMailbox :: FilePath -> IO [Source]` and
`dumpSources :: FilePath -> [Source] -> IO ()`.

## Design notes

Each nesting level scans only its own body, so the part tree costs O(N·d);
every header value is tokenised once; dates use the closed-form
`days_from_civil` algorithm and its inverse.
