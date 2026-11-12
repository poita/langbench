# cardgame

A rules engine for **Spiremark**, an invented two-player duelling-card game,
written in Go with only the standard library. It reads a *match file* (a setup
block followed by a script of player actions and inspection directives),
simulates the match exactly, and writes a deterministic log with one line per
rules event. The card pool is data: cards are described in an s-expression
database that is parsed and validated once, then interpreted by the engine.

The project is a reusable library plus a thin command-line tool.

## Layout

| Package | Responsibility |
| --- | --- |
| `sexpr` | Lexer, parser and canonical printer for the database syntax |
| `prng` | The 64-bit xorshift\* generator (shuffles, `random-unit`) |
| `cards` | Typed card model, database parser/validator, `CARD` rendering |
| `engine` | Game state, layer system, effect interpreter, Chain and priority, triggers, combat, `DUMP`/`LEGAL`/`VAULT` views |
| `match` | Match-file parser and script runner (the program's I/O contract) |
| `cmd/cardgame` | The command-line tool: stdin in, stdout out |

## Build

Requires Go 1.27 or later and nothing else.

```sh
./build.sh          # builds bin/cardgame with plain `go build`
./run.sh < match.txt
```

`build.sh` and `run.sh` work from any directory. Without the scripts:
`go build -o bin/cardgame ./cmd/cardgame`.

## Command-line use

The program takes no arguments. It reads the whole match file from stdin and
writes everything to stdout; the exit status is 0 even for `FATAL` and `ERR`
cases.

```
CARDS data/cards.spire      # card database (path relative to the working dir)
SEED 1
OPENING 0
SHUFFLE off
HAND A CIN-003
FIELD B TOK-001
START
A PLAY 1 #2
A PASS
B PASS
DUMP
```

Setup lines (`CARDS`, `SEED`, `SPIRE`, `OPENING`, `MAXCAP`, `HANDMAX`,
`TURNLIMIT`, `FIRST`, `SHUFFLE`, `TRACE`, `CAP`, `DECK`, `HAND`, `FIELD`,
`ASH`, `RIFT`) end with `START`. After it, each script line is either a player
action (`A PASS`, `B CONCEDE`, `A PLAY <pos> [targets]`, `A ACT #<oid> <n>
[targets]`, `A ATTACK [#oid...]`, `B BLOCK [#blocker:#attacker...]`) or a
directive (`DUMP`, `LEGAL`, `VAULT`, `CARD <id>`). Output is numbered event
lines (`8 PLAY A ~1 #2 CIN-003 #4`), `ERR <line> <kind>` lines for rejected
actions, the blocks printed by directives, and finally exactly one
`RESULT ...` line. Setup problems print a single line: `FATAL bad-setup`,
`FATAL bad-database` or `FATAL unknown-card`.

The format is specified in full in `problems/cardgame/SPEC.md` of the task
this project implements; the packages' doc comments describe each part.

## Library use

```go
db, err := cards.Load("data/cards.spire") // or cards.Parse(text)
if err != nil { /* errors.Is(err, cards.ErrBadDatabase) */ }

cfg := engine.DefaultConfig()
cfg.Opening, cfg.Shuffle = 0, false
cfg.Hand[engine.A] = []engine.CardCount{{ID: "CIN-003", Count: 1}}

out := bufio.NewWriter(os.Stdout) // events are written here, one line each
defer out.Flush()
g, err := engine.New(cfg, db, out) // sets up and runs to the first decision
if err != nil { /* engine.ErrUnknownCard */ }

err = g.Do(engine.Action{
    Kind: engine.ActPlay, Player: engine.A, Pos: 1,
    Targets: []engine.TargetRef{{Kind: engine.RefPlayer, Player: engine.B}},
})
var rejected *engine.ActionError
if errors.As(err, &rejected) { fmt.Println("ERR", rejected.Kind) }

g.Do(engine.Action{Kind: engine.ActPass, Player: engine.A})
g.Do(engine.Action{Kind: engine.ActPass, Player: engine.B}) // the rite resolves

g.Dump(out)           // inspection views: Dump, Legal, Vault
who, kind := g.Decision() // who the engine waits for, and what it expects
_, _ = who, kind
```

`Game.Do` either rejects an action with an `*ActionError` (nothing changes) or
accepts it and runs the engine forward to the next decision point, so a `Game`
is always waiting for input or finished. `match.Run(in, out, match.Options{})`
runs a complete match file the way the command-line tool does.

## Design notes

* The database is parsed once into trees of effects, selectors, filters,
  amounts, conditions and statics, which a tree-walking interpreter evaluates.
* Current characteristics are derived for the whole board at once, layer by
  layer over the continuous-effect records in timestamp order (SPEC 14.3), and
  recomputed lazily only after a state change that could affect them.
* The engine is a single resumable state machine: it runs until it needs a
  decision, consumes one action, and continues. Nothing is replayed and the
  state is never copied to try an action; actions are validated directly.
* The Field is kept in entry order, which is canonical `(timestamp, oid)`
  order; objects are found by oid in O(1); Vaults are slices with O(1) draws,
  mills and bottom insertions.

## Tests

```sh
go test ./...
```

* unit tests for the lexer, PRNG, database validator and match-file parsing;
* engine scenario tests and an example (`ExampleNew`) written against the
  public API;
* `testdata/golden` holds the worked examples of the specification, run
  through the full program against a small fixture database;
* `TestConformanceSuite` runs every test of the original problem directory
  when it sits next to the project (`../problems/cardgame`, or set
  `CARDGAME_PROBLEM_DIR`); it is skipped otherwise.
