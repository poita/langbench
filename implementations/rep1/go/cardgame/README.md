# cardgame

A rules engine for **Spiremark**, an invented two-player duelling-card game,
written in Go with the standard library only.

It reads a *match file* (a setup block followed by a script of player actions
and inspection directives), simulates the match exactly as specified, and
writes a deterministic log: one numbered line per rules event, interleaved
with the blocks requested by the inspection directives. The card pool is data,
not code: cards are written as s-expressions in a database file that the match
file names, and the engine interprets their effects, triggers and continuous
(layered) effects.

Requires Go 1.27.1.

## Build

```sh
./build.sh          # builds bin/cardgame
go test ./...       # unit tests
```

`build.sh` runs `go build -o bin/cardgame ./cmd/cardgame` and works from any
directory. `run.sh` runs the built binary.

## Command line

```sh
./run.sh < match.txt
```

The whole match file is read from stdin; the log is written to stdout. There
are no arguments. The exit status is 0 for every outcome the specification
describes, including `FATAL` and `ERR` lines. A relative `CARDS <path>` is
resolved against the current directory.

A minimal match file:

```
CARDS data/cards.spire
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
HAND A CIN-003
START
A PLAY 1 B
A PASS
B PASS
DUMP
```

Setup lines (`CARDS`, `SEED`, `SPIRE`, `OPENING`, `MAXCAP`, `HANDMAX`,
`TURNLIMIT`, `FIRST`, `SHUFFLE`, `TRACE`, `CAP`, `DECK`, `HAND`, `FIELD`,
`ASH`, `RIFT`) end with `START`. After it, each line is either an action —
`<A|B> PASS | CONCEDE | PLAY … | ACT … | ATTACK … | BLOCK …` — or a directive:
`DUMP` (full state), `LEGAL` (legal actions), `VAULT` (vault contents) or
`CARD <id>` (a card's definition). Rejected actions print `ERR <line> <kind>`;
fatal setup problems print one `FATAL bad-setup | bad-database | unknown-card`
line.

## Library

The project is a Go module named `cardgame`; the command is a thin wrapper
over the library.

| Package | Responsibility |
| --- | --- |
| `cardgame` | `Run` / `RunString`: match file in, log out (the CLI's whole job) |
| `cardgame/sexpr` | s-expression reader and canonical printer |
| `cardgame/rng` | the xorshift\* generator and the specified shuffle |
| `cardgame/cards` | typed card model, database validator, `CARD` rendering |
| `cardgame/match` | setup-block and script-line parsers |
| `cardgame/engine` | the rules engine: zones, layers, triggers, chain, combat |

Inside `engine`, the files split by concern: `game.go` (state, setup, zone
helpers), `derive.go` (layered derivation of current characteristics),
`eval.go` (selectors, filters, amounts, conditions), `effects.go` (effect
interpreter and state changes), `triggers.go` (collection, ordering, state
checks, `settle`), `chain.go` (targeting, playing, activating, resolving),
`turn.go` (turn structure, priority, the decision state machine), `combat.go`,
and `inspect.go` (`DUMP`, `LEGAL`, `VAULT`, `CARD` blocks).

The engine is a resumable state machine: `engine.New` runs the setup
procedure and stops at the first decision point; each accepted command is
applied and rules processing runs forward to the next decision point. The
match is simulated exactly once and state is never cloned. Current
characteristics come from one whole-board derivation pass that is cached and
invalidated only by changes that a live aura can observe.

### Example

```go
package main

import (
	"fmt"

	"cardgame/cards"
	"cardgame/engine"
	"cardgame/match"
)

const db = `
(card TST-001 (name "Bolt") (type rite) (cost 1) (keywords swift)
  (resolve (targets (any)) (damage 2 (t 1))))
`

func main() {
	cardDB, err := cards.Parse([]byte(db)) // or cards.Load(path)
	if err != nil {
		panic(err)
	}
	file, err := match.ParseFile("CARDS unused\nSEED 1\nOPENING 0\nSHUFFLE off\nHAND A TST-001\nSTART\n")
	if err != nil {
		panic(err)
	}
	game, err := engine.New(cardDB, file.Setup) // runs setup, stops at the first decision
	if err != nil {
		panic(err)
	}
	for i, line := range []string{"A PLAY 1 B", "A PASS", "B PASS"} {
		cmd, err := match.ParseCommand(line)
		if err != nil {
			game.Reject(i+1, "bad-syntax")
			continue
		}
		game.Exec(cmd, i+1) // validate and apply, or emit an ERR line
	}
	game.Finish() // RESULT pending none, if the match is still running
	fmt.Print(string(game.Output()))
}
```

To run a complete match file in one call use `cardgame.Run(os.Stdin, os.Stdout)`
or `cardgame.RunString`.

## Tests

`go test ./...` runs unit tests for every package (separate `_test.go` files),
testable examples, and — when the problem's `tests/` directory is present next
to this project — replays every case of that suite through `RunString`.

## Notes on the specification

* **Provoke (SPEC 19.4).** The text says a `BLOCK` command fails when a
  `provoke` attacker's "blocker list is empty". The suite (test 302) shows the
  list that counts is the one *after* the command: a provoke attacker that the
  command blocks is satisfied even if other defenders could also have blocked
  it. The engine implements that reading.
* **Multi-static auras.** Every shipped aura clause holds one static. The
  grammar allows several; the engine evaluates all of them inside one record
  (one `eid`, one timestamp), and `DUMP` prints the first.
* **`ally-dies` / `enemy-dies`** are collected only when the dying object is a
  unit, following the event table in SPEC 13.1.
