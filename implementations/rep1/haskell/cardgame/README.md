# cardgame — a rules engine for Spiremark

Spiremark is an invented two-player duelling-card game. This package is a
complete, deterministic rules engine for it, written in Haskell:

* a **library** (`Spiremark.*`) that reads a card database, sets up a match,
  and simulates a script of player actions, producing a log with one line per
  rules event;
* a thin **command-line tool**, `cardgame`, that reads a match file on stdin and
  writes that log to stdout.

The game rules, the card-database language and the exact input/output formats
are specified in `problems/cardgame/SPEC.md` of the surrounding workspace; this
README only covers the Haskell project.

## Building

Requires GHC 9.14 and cabal 3.18 (only GHC's bundled packages are used; the
tests additionally use `hspec` and `QuickCheck`).

```sh
./build.sh          # cabal build exe:cardgame, binary copied to bin/cardgame
cabal test          # unit, property and golden tests
```

`build.sh` and `run.sh` work from any directory. The build uses cabal's
standard optimisation settings (`-O1`).

## Using the command-line tool

```sh
./run.sh < match.txt
```

The match file is a setup block terminated by `START`, followed by a script:

```
CARDS data/cards.spire      # card database (path relative to the cwd)
SEED 1                      # PRNG seed
SPIRE 10
OPENING 0
SHUFFLE off
DECK A CIN-001*3
HAND A CIN-003
FIELD B TOK-001
START
A PLAY 1 #4                 # A plays the card in hand position 1 at object #4
A PASS
B PASS
DUMP                        # print the full game state
```

Script lines are player actions (`PASS`, `CONCEDE`, `PLAY`, `ACT`, `ATTACK`,
`BLOCK`) or inspection directives (`DUMP`, `LEGAL`, `VAULT`, `CARD <id>`).
The tool prints numbered event lines (`8 PLAY A ~1 #2 CIN-003 #4`, …), the
blocks requested by directives, `ERR <line> <kind>` for rejected actions, and a
final `RESULT` line. Setup problems print a single `FATAL bad-setup`,
`FATAL bad-database` or `FATAL unknown-card` line. The exit status is always 0.

## Using the library

```haskell
import Spiremark

main :: IO ()
main = do
  -- Whole match file in, output lines out.
  out <- runMatchText $ unlines
    [ "CARDS data/cards.spire", "SEED 1", "SPIRE 10", "OPENING 0", "SHUFFLE off"
    , "DECK A CIN-001", "DECK B CIN-001", "HAND A CIN-003", "FIELD B TOK-001"
    , "START", "A PLAY 1 #4", "A PASS", "B PASS" ]
  mapM_ putStrLn out
```

For step-by-step control, build the pieces yourself — parse the setup, load the
database, create a `Game`, and feed it script lines; the engine runs forward to
the next decision point after each one:

```haskell
import Spiremark

drive :: IO ()
drive = do
  Right (setup, _) <- pure (parseMatch "CARDS data/cards.spire\nSEED 1\nSTART\n")
  Just db <- loadDatabase (suCards setup)
  case newGame setup db of
    Left UnknownCard -> putStrLn "unknown card in setup"
    Right g0 -> do
      let g1 = stepLine 1 (parseScriptLine "A PASS") g0
          (events, g2) = takeOutput g1
      mapM_ putStrLn events
      print (gameResult g2)
```

### Modules

| Module | Responsibility |
| --- | --- |
| `Spiremark` | public facade: `runMatchText`, `simulate`, re-exports |
| `Spiremark.SExpr` | tokenizer/parser for the database syntax, canonical printer |
| `Spiremark.Card.Types` | typed cards, abilities and the effect language |
| `Spiremark.Card.Parse` | database reader and validator (`FATAL bad-database` rules) |
| `Spiremark.Card.Print` | the `CARD` block |
| `Spiremark.Match` | match-file parser (setup block, script lines) |
| `Spiremark.Random` | the xorshift\* generator and shuffle |
| `Spiremark.Engine` | setup, turn structure, priority, action validation |
| `Spiremark.Engine.Types` | the game state record |
| `Spiremark.Engine.Eval` | selectors, filters, amounts, conditions |
| `Spiremark.Engine.Derive` | whole-board layer derivation (controllers, stats, keywords, auras) |
| `Spiremark.Engine.Core` | atomic procedures: damage, destroy, draw, triggers, state checks |
| `Spiremark.Engine.Effects` | the effect interpreter |
| `Spiremark.Engine.Target` | target legality, candidates, ordering |
| `Spiremark.Engine.Chain` | play/activate, trigger push, resolution, `settle`/`drain` |
| `Spiremark.Engine.Combat` | attack/block legality, declarations, combat damage |
| `Spiremark.Engine.Report` | `DUMP`, `LEGAL`, `VAULT` blocks |

## Design notes

* The card database is parsed and validated once into a tree of effects,
  selectors, filters, amounts and statics, which a tree-walking interpreter
  evaluates. Nothing about the card pool is built into the program.
* The match is simulated exactly once: the engine is a state machine
  (`Mode`) that stops at decision points and resumes with the next script line;
  state is never copied to try an action, and actions are validated directly.
* Current characteristics come from a single whole-board derivation that walks
  the continuous-effect records layer by layer. The result is cached and
  dropped only by changes it can depend on (the Field, counters, records, and —
  only when some aura reads them — zone contents, player totals or per-object
  Field state).
* Objects live in an `IntMap` by oid; Vaults, hands and piles are
  `Data.Sequence`, so draws, mills and digs are O(1) at the ends.

## Tests

`cabal test` runs an hspec suite:

* s-expression, PRNG, database-validation and match-parser unit tests, with
  QuickCheck properties (render/parse round trip, shuffle is a permutation,
  every random script yields consecutively numbered events and exactly one
  `RESULT`);
* golden tests: every match file in `test/golden` against its expected log
  (the worked examples of the specification and a selection of scenario and
  self-play matches), using the fixtures in `test/data`.

## Layout

```
cardgame.cabal   package manifest (library, executable, test suite)
src/             library
app/Main.hs      command-line tool
test/            hspec tests, fixtures (test/data) and golden files (test/golden)
build.sh run.sh  build and run scripts
```
