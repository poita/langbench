# json

A strict RFC 8259 JSON parser and canonical serializer in Clojure, with no
dependencies beyond Clojure itself. It is a reusable library plus a thin
command-line tool.

The canonical form has no insignificant whitespace, sorts object members by
key in UTF-16 code unit order (duplicate keys collapse to the last
occurrence), escapes only what must be escaped, and echoes numbers as text
(never through floating point) with the exponent normalized (`1E+05` →
`1e5`). Integers of any size survive unchanged.

Parsing is strict: the input must be valid UTF-8 (no BOM), whitespace is
exactly space/tab/LF/CR, surrogate escapes must pair up, and nesting is
limited to 512 levels. Parsing and serializing are linear in the input size
apart from sorting object keys; no per-subtree output strings are built.

## Layout

| Namespace     | Responsibility                                                  |
|---------------|-----------------------------------------------------------------|
| `json.core`   | **Public API**: `parse`, `valid?`, `serialize`, `canonicalize`  |
| `json.tree`   | Tree representation (`Num`, `Obj`) and its accessors            |
| `json.utf8`   | Strict UTF-8 validation                                         |
| `json.parse`  | Recursive-descent parser over bytes                             |
| `json.write`  | Canonical serializer                                            |
| `json.cli`    | Command-line front end (stdin → stdout)                         |

## Requirements and build

Clojure 1.12 (via the `clojure` CLI) on a recent JDK.

```sh
./build.sh            # AOT-compiles the CLI and library into classes/
```

`build.sh` and `run.sh` work from any directory.

## Command-line use

`run.sh` reads one JSON document from stdin and prints one line: the canonical
serialization, or `invalid`. The exit status is 0 either way.

```sh
$ echo '{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }' | ./run.sh
{"a":"héllo/","b":null}
$ echo '[1, 2, ]' | ./run.sh
invalid
```

## Library use

Add the project as a dependency (`deps.edn`, local or git):

```clojure
{:deps {json/json {:local/root "path/to/json"}}}
```

```clojure
(require '[json.core :as json])

;; Canonicalize directly (input: String, byte[] or InputStream)
(json/canonicalize "{\"b\": 1E+3, \"a\": [true, null]}")
;;=> "{\"a\":[true,null],\"b\":1e3}"

;; Parse to a tree: nil/true/false, String, json.tree.Num, vector, json.tree.Obj
(def t (json/parse "{\"x\": [1.50, \"hi\"]}"))
(json/number-text (first (val (first (json/members t)))))
;;=> "1.50"

;; Invalid documents throw; valid? is the non-throwing check
(json/valid? "[1,]")           ;;=> false
(try (json/parse "[1,]")
     (catch Exception e (json/invalid? e)))   ;;=> true

;; Build and serialize a tree
(json/serialize (json/obj-node [["b" nil] ["a" [true]]]))
;;=> "{\"a\":[true],\"b\":null}"
```

Tree values: `null` → `nil`, booleans → `true`/`false`, strings → `String`,
numbers → `json.tree.Num` (canonical text), arrays → vectors, objects →
`json.tree.Obj` holding every `[key value]` member in input order, duplicates
included.

## Tests

```sh
clojure -M:test       # Cognitect test-runner; clojure.test + test.check
```

The suite covers UTF-8 validation (checked against the JDK decoder),
grammar acceptance/rejection, number normalization, key ordering and
duplicate handling, depth limits, the CLI contract, and generative
round-trip and ordering properties.
