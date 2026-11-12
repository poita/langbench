# toml

A TOML 1.0.0 reader and writer for Clojure, written from scratch with no
dependencies beyond Clojure itself, plus a small command-line tool that speaks
the tagged-JSON format of the [toml-test](https://github.com/toml-lang/toml-test)
suite.

* Strict, complete TOML 1.0.0 parsing (every invalid document is rejected).
* Lossless: scalars are kept as canonical text, floats are rounded correctly,
  dates and times are validated and canonicalised without a date library.
* Linear time reading and writing; deeply nested documents are fine.
* A canonical writer whose output always re-reads to the same data.

Requires Clojure 1.12 on a recent JDK.

## Layout

| Namespace        | Responsibility                                                   |
|------------------|------------------------------------------------------------------|
| `toml.core`      | **Public API**: parse and generate                               |
| `toml.convert`   | Tagged trees ⇄ ordinary Clojure data (`java.time` for dates)     |
| `toml.parser`    | Recursive-descent reader                                         |
| `toml.table`     | Table tree and the explicit/implicit/dotted/inline rules         |
| `toml.number`    | Integer and float syntax, `%.16e` float text                     |
| `toml.datetime`  | Date/time validation and canonical text                          |
| `toml.encoder`   | Canonical TOML writer                                            |
| `toml.json`      | Tagged JSON reader and writer                                    |
| `toml.data`      | The tagged data model (`Scalar` record)                          |
| `toml.error`     | Parse errors with line/column                                    |
| `toml.cli`       | The command-line tool                                            |

## Build

```
./build.sh          # AOT-compiles the CLI into classes/ for fast startup
```

## Command line

`run.sh` reads standard input. The first line is the mode, `decode` or
`encode`; everything after it is the document.

```
$ printf 'decode\nname = "Tom"\nports = [8001, 8002]\n' | ./run.sh
{"name":{"type":"string","value":"Tom"},"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]}

$ printf 'encode\n{"a":{"type":"integer","value":"1"}}' | ./run.sh
a = 1
```

* `decode` parses TOML and prints it as compact, key-sorted tagged JSON: tables
  are objects, arrays are arrays, and every scalar is
  `{"type": ..., "value": "<text>"}`. An invalid document prints `error`.
  Floats print as 17 significant digits (`1.0000000000000000e+00`), integers
  in decimal, date-times in canonical text.
* `encode` reads tagged JSON and prints the canonical TOML document.

The exit code is always 0.

## Library

Add the project as a dependency (`deps.edn`, `:local/root` or `:git/url`) and:

```clojure
(require '[toml.core :as toml]
         '[toml.json :as json])

;; Ordinary Clojure data
(toml/parse-string "title = \"Example\"\n[server]\nports = [80, 443]\nsince = 2020-01-02")
;=> {"title" "Example"
;    "server" {"ports" [80 443] "since" #object[java.time.LocalDate 2020-01-02]}}

(toml/parse-string "a.b = 1" {:key-fn keyword})
;=> {:a {:b 1}}

;; Writing (keywords are accepted as keys)
(toml/generate-string {:title "Example" :ports [80 443] :server {:host "x"}})
;=> "ports = [80, 443]\ntitle = \"Example\"\n\n[server]\nhost = \"x\"\n"

;; The lossless tagged tree, and its JSON form
(json/write-tagged (toml/parse-tagged "x = 1.5"))
;=> "{\"x\":{\"type\":\"float\",\"value\":\"1.5000000000000000e+00\"}}"

;; Errors
(try (toml/parse-string "a = 1\na = 2")
     (catch clojure.lang.ExceptionInfo e (ex-data e)))
;=> {:toml/error true, :reason "duplicate key `a`", :pos 6, :line 2, :column 1}
```

`toml.core` functions: `parse-string`, `parse-bytes` (strict UTF-8),
`parse-tagged`, `parse-bytes-tagged`, `generate-string`.

Type mapping for `parse-string`: strings, `Long`, `Double`, `Boolean`,
`OffsetDateTime`, `LocalDateTime`, `LocalDate`, `LocalTime`, vectors and maps.
Integers outside 64 bits and invalid TOML throw.

## Tests

```
clojure -X:test
```

Runs the unit tests and the `test.check` round-trip properties with the
Cognitect test-runner.

The project is also checked against the toml-test corpus by
`python3 run_tests.py toml -- toml/run.sh` from the repository root.
