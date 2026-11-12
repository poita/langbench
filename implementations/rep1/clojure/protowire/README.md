# protowire

A Protocol Buffers (proto3) wire-format codec in Clojure, driven by a tiny
schema language. It decodes hex-encoded wire bytes into a canonical text form
and encodes that text form back to hex, following the rules in
`problems/protowire/SPEC.md`. It is a from-scratch implementation using only the
Clojure standard library and the JDK: no protobuf libraries.

It is both a library (`protowire.core`) and a thin command-line tool
(`protowire.cli`) that reads a schema plus a list of requests on stdin.

## Requirements

* Clojure 1.12.6 (`clojure` CLI, `deps.edn` project)
* Java 27

## Build

```sh
./build.sh      # AOT-compiles the CLI into ./classes
```

## Command-line use

```sh
./run.sh < input.txt
```

Input is a schema, a line consisting of `--`, then one request per line:

```
message Inner { sint32 v = 1; }
message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }
--
encode Outer {a: 1, b: "x", c: [1, 2], d: {v: -5}}
decode Outer 08011201781a02010222020809
decode Outer 08ff
```

Output is one line per request: the hex for `encode`, the canonical text for
`decode`, or `error` for any malformed request (the exit code is always 0):

```
08011201781a02010222020809
{a: 1, b: "x", c: [1, 2], d: {v: -5}}
error
```

### Schema language

```
message <Name> { [repeated] <type> <name> = <number> ; ... }
```

`<type>` is a scalar (`int32 int64 uint32 uint64 sint32 sint64 bool fixed32
fixed64 sfixed32 sfixed64 string bytes`) or a message name (forward and recursive
references allowed). There are no other modifiers.

### Canonical text form

`{name: value, ...}` with fields in field-number order; integers in decimal,
`true`/`false`, strings as `"..."` (escapes `\" \\ \n \r \t` and `\xHH` for other
control characters), bytes as `x"00ff"`, sub-messages as `{...}` and repeated
fields as `[a, b]`. Default scalars and empty lists are omitted when decoding.
`encode` accepts any number of spaces between tokens, fields in any order and
explicit defaults, and rejects out-of-range numbers, wrong kinds of value,
duplicate or unknown fields and non-UTF-8 strings.

## Library use

```clojure
(require '[protowire.core :as pw])

(def schema
  (pw/parse-schema "message Inner { sint32 v = 1; }
                    message Outer { int32 a = 1; string b = 2;
                                    repeated int32 c = 3; Inner d = 4; }"))

;; data <-> bytes
(pw/encode-hex schema "Outer" {:a 1 :b "x" :c [1 2] :d {:v -5}})
;; => "08011201781a02010222020809"

(pw/decode-hex schema "Outer" "08011201781a02010222020809")
;; => {:a 1, :b "x", :c [1 2], :d {:v -5}}

;; text <-> data
(pw/format-text schema "Outer" {:a 1 :c [1 2]})   ;; => "{a: 1, c: [1, 2]}"
(pw/parse-text schema "Outer" "{ c: [1,2], a: 1 }") ;; => {:c [1 2], :a 1}

;; byte arrays
(pw/encode schema "Outer" {:a 150})   ;; => #object["[B" ...]
(pw/decode schema "Outer" (byte-array [0x08 0x96 0x01])) ;; => {:a 150}

;; malformed input throws an ex-info for which pw/error? is true
(try (pw/decode-hex schema "Outer" "08ff")
     (catch Exception e (pw/error? e)))   ;; => true
```

Messages are maps keyed by `(keyword field-name)`. Integers are `long`s (a
`uint64`/`fixed64` above 2^63-1 is a `BigInt`), `bool` is a boolean, `string` a
`String`, `bytes` a `byte[]`, repeated fields are vectors, sub-messages maps.
Decoded maps contain exactly the fields that appeared on the wire (including
those with default values); unknown fields are dropped. `encode` is canonical:
fields in number order, defaults omitted, repeated numeric fields packed.

`protowire.core/run-requests` runs a whole request document (what the CLI does).

### Modules

| namespace | responsibility |
|---|---|
| `protowire.core` | public API |
| `protowire.schema` | schema tokenizer/parser, message descriptors |
| `protowire.types` | scalar types, ranges, value conversions |
| `protowire.wire` | varints, fixed-width values, skipping fields/groups |
| `protowire.decode` | wire bytes -> data |
| `protowire.encode` | data -> wire bytes (size pass, then write pass) |
| `protowire.text` | canonical text printer and parser |
| `protowire.hex` | hex conversion |
| `protowire.protocol` | the stdin request protocol |
| `protowire.cli` | `-main` |
| `protowire.error` | error signalling |

Decoding and encoding are linear in payload/output size regardless of nesting
depth: decode reads each byte once and skips unknown fields and groups without
decoding them; encode computes every node's size once in a planning pass and then
writes into a pre-sized buffer.

## Tests

```sh
clojure -M:test      # Cognitect test-runner; includes test.check properties
```
