# cardgame — a Spiremark rules engine in Clojure

`cardgame` is a complete rules engine for **Spiremark**, an invented
two-player duelling-card game (see `problems/cardgame/SPEC.md` in the task
repository for the rules).  It is packaged as

* a **library** (`cardgame.core` and friends) that loads a card database,
  creates a game, accepts player actions and produces the event log, and
* a thin **command-line tool** (`cardgame.cli`) that reads a *match file* on
  stdin and writes the log on stdout.

The engine is deterministic (a 64-bit xorshift\* PRNG seeded from the match
file), simulates the match once (it suspends at decision points and resumes
with the next action — nothing is replayed), and uses only Clojure's standard
library.

## Requirements

* Java 27 (any recent JDK works) and the [`clojure` CLI](https://clojure.org/guides/install_clojure)
* Clojure 1.12.6 (resolved from `deps.edn`)

## Building

```sh
./build.sh
```

`build.sh` resolves the dependencies, AOT-compiles the CLI into
`target/classes` (with the standard `compile` settings) and records the
classpath in `target/classpath`.  It can be run from any directory.

## Using the command-line tool

```sh
./run.sh < match.txt          # same as: clojure -M -m cardgame.cli < match.txt
```

The match file is a setup block, `START`, and then one script line per player
action or inspection directive:

```
CARDS data/cards.spire        # card database (path relative to the current directory)
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
DECK A CIN-001
DECK B CIN-001
HAND A CIN-003
FIELD B TOK-001
START
A PLAY 1 #4                   # play the card at hand position 1, targeting object #4
A PASS
B PASS
DUMP                          # print the full state
```

Output is one numbered line per rules event (`8 PLAY A ~1 #2 CIN-003 #4`),
interleaved with the blocks requested by `DUMP`, `LEGAL`, `VAULT` and
`CARD <id>`, `ERR <line> <kind>` lines for rejected actions, and a final
`RESULT` line.  Setup problems print a single `FATAL bad-setup`,
`FATAL bad-database` or `FATAL unknown-card` line.  The process always exits
with status 0 for a well-formed run.  The complete format is specified in
SPEC.md §3–§5, §22–§24.

## Using the library

```clojure
(require '[cardgame.core :as cg])

;; 1. load and validate a card database (throws if it is invalid)
(def db (cg/load-cards "data/cards.spire"))

;; 2. create a game; it runs forward to the first decision point
(def g (cg/new-game db {:seed 1 :spire 10 :opening 0 :shuffle false
                        :zones {:A {:deck [["CIN-001" 1]] :hand [["CIN-003" 1]]}
                                :B {:deck [["CIN-001" 1]] :field [["TOK-001" 1]]}}}))

;; 3. submit actions; nil means accepted, otherwise an error keyword
(cg/submit! g :A {:type :play :pos 1 :targets [4]})   ;=> nil
(cg/submit! g :A {:type :pass})
(cg/submit! g :B {:type :pass})
(cg/submit! g :B {:type :pass})                        ;=> :not-your-turn

;; 4. inspect, and read the log
(run! println (cg/inspect g :dump))      ; also :legal, :vault, [:card "CIN-003"]
(print (cg/output g))

;; or run a whole match file in one call
(cg/run-match (slurp "match.txt"))                     ;=> the full output string
```

Actions are plain maps: `{:type :pass}`, `{:type :concede}`,
`{:type :play :pos 1 :targets [...]}`, `{:type :act :oid 5 :index 2 :targets [...]}`,
`{:type :attack :oids [3 4]}`, `{:type :block :pairs [[blocker attacker] ...]}`.
Targets are `:A`/`:B`, an oid (long) or `[:c cid]` for a Chain entry.

## Project layout

| Namespace | Responsibility |
| --- | --- |
| `cardgame.core` | public API: `load-cards`, `new-game`, `submit!`, `inspect`, `output`, `run-match` |
| `cardgame.cli` | `-main`: stdin → `run-match` → stdout |
| `cardgame.sexpr` | tokenizer and reader for the card-database syntax; canonical printer |
| `cardgame.cards` | card model and validator; compiles abilities to a tree of tagged vectors; `CARD` rendering |
| `cardgame.matchfile` | setup block and script-line parser |
| `cardgame.prng` | the xorshift\* generator and shuffle |
| `cardgame.state` | game-state map, pure accessors and primitive mutators, event output |
| `cardgame.query` | selectors, filters, amounts and conditions (pure) |
| `cardgame.layers` | whole-board derivation of current characteristics (SPEC §14) |
| `cardgame.board` | cached derived characteristics and evaluation contexts |
| `cardgame.triggers` | trigger collection |
| `cardgame.targeting` | target legality and enumeration |
| `cardgame.rules` | atomic state changes of SPEC §17: damage, destruction, drawing, entering the Field, … |
| `cardgame.effects` | the effect interpreter |
| `cardgame.chain` | playing, activating, resolving, trigger pushing, state checks, `settle`/`drain` |
| `cardgame.combat` | attack/block legality, declaration, combat damage |
| `cardgame.engine` | setup, turn structure, priority, action handling (a resumable state machine) |
| `cardgame.inspect` | `DUMP`, `LEGAL`, `VAULT`, `CARD` blocks and the legal-action enumerator |

### Design notes

* The card database is parsed **once** into a tree of keyword-tagged vectors
  (effects, selectors, filters, amounts, conditions, statics) which the
  interpreter walks; nothing is re-parsed while the game runs.
* Current characteristics (controller, keywords, edge, core) come from a
  **whole-board derivation** (`cardgame.layers`), layer by layer over the
  continuous-effect records in timestamp order, evaluating each aura once.
  The result is cached; the cache is dropped by any state change an aura
  could depend on (`cardgame.state/upd-facets!` lists the finer-grained
  rules, e.g. wounds only matter when some aura on the Field reads wounds).
* Objects are found by oid in O(1) (a map); Vaults are persistent queues, so
  draws, mills and digs are O(1) per card.
* Scripted actions are validated directly (`chain/check-play`,
  `combat/check-block`, …), not by searching the `LEGAL` list.

## Tests

```sh
clojure -M:test
```

runs the unit, scenario, golden and property-based tests (Cognitect
test-runner + `test.check`).  The test alias sets `-Dcardgame.verify=true`,
which makes every cache hit of the derived-characteristics cache be checked
against a fresh derivation, so the fuzz tests also validate the invalidation
rules.  Golden match files live in `test/resources/golden`; the card pool they
use is `test/resources/mini.spire`.

To run the task's end-to-end suite (from the repository root):

```sh
cardgame/build.sh && python3 run_tests.py cardgame -- cardgame/run.sh
```
