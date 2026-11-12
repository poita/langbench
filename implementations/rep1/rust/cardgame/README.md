# cardgame

A deterministic rules engine for **Spiremark**, an invented two-player
duelling-card game. It reads a *match file* — a setup block followed by a
script of player actions and inspection directives — simulates the match, and
writes a log with one line per rules event.

The project is a reusable library (`cardgame`) plus a thin command-line tool
on top of it. It uses only the Rust standard library.

## Building

```sh
./build.sh            # or: cargo build --release
cargo test            # unit, integration and doc tests
```

The binary is `target/release/cardgame`; `./run.sh` runs it from any directory.

## Command-line use

The match file is read from standard input and the log is written to standard
output. The program takes no arguments and always exits with status 0 (fatal
setup problems are reported as a single `FATAL …` line).

```sh
./run.sh < match.txt
```

A match file looks like this (see `tests/cases/` for many more):

```
CARDS data/cards.spire      # card database; relative paths resolve against the CWD
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
DECK A CIN-001
DECK B CIN-001
HAND A CIN-003
FIELD B TOK-001
START
A PLAY 1 #4                 # play hand card 1, targeting object #4
A PASS
B PASS
DUMP                        # print the full game state
```

* **Setup lines** (`CARDS`, `SEED`, `SPIRE`, `OPENING`, `MAXCAP`, `HANDMAX`,
  `TURNLIMIT`, `FIRST`, `SHUFFLE`, `TRACE`, `CAP`, `DECK`/`HAND`/`FIELD`/`ASH`/`RIFT`)
  end with `START`.
* **Actions** are `A|B PASS`, `CONCEDE`, `PLAY <pos> [targets]`,
  `ACT #<oid> <index> [targets]`, `ATTACK [#oid…]` and `BLOCK [#blocker:#attacker…]`.
  Targets are `A`, `B`, `#<oid>` or `~<cid>`.
* **Directives** never change the game: `DUMP`, `LEGAL`, `VAULT`, `CARD <id>`.
* Rejected actions print `ERR <line> <kind>`; a bad setup prints
  `FATAL bad-setup`, `FATAL bad-database` or `FATAL unknown-card`.
* The output is `<seq> <EVENT> …` lines, interleaved with the blocks the
  directives print, and ends with `RESULT <winner|draw|pending> <reason>`.

The full rules, the card-database format and the output format are specified
in `SPEC.md` of the problem this project implements.

## Library use

```rust
use cardgame::{Database, Engine, Setup, run_match};

// 1. The whole pipeline, text in and text out (what the CLI does):
let log = run_match("CARDS data/cards.spire\nSEED 1\nOPENING 0\nSHUFFLE off\nSTART\nA PASS\n");
assert!(log.contains("PASS A"));

// 2. Step by step, driving the engine yourself:
use cardgame::matchfile::{parse_command, parse_setup, split_lines};
use std::rc::Rc;

let text = "CARDS data/cards.spire\nSEED 1\nOPENING 0\nSHUFFLE off\nSTART\n";
let lines = split_lines(text);
let (setup, _start): (Setup, usize) = parse_setup(&lines).unwrap();
let db = Database::load(&setup.cards_path).unwrap();
let mut engine = Engine::new(&setup, Rc::new(db)).unwrap();
engine.execute(7, parse_command("A PASS").unwrap());
engine.finish();
print!("{}", engine.take_output());
```

## Layout

| Module | Responsibility |
| --- | --- |
| `sexpr` | s-expression reader and canonical printer |
| `model` | typed cards, abilities, effects, selectors, filters |
| `database` | validation of the card database into the model |
| `matchfile` | setup block and script-line parsing |
| `rng` | the xorshift\* generator (shuffles, `random-unit`) |
| `state` | objects, players, zones, Chain entries, the `Engine` struct |
| `derive` | whole-board derivation of current characteristics (layers) |
| `eval` | selectors, filters, amounts, conditions |
| `effects` | the effect interpreter |
| `procedures` | damage, destruction, drawing and the other atomic state changes |
| `triggers`, `targets` | trigger collection/ordering; target legality |
| `chain` | playing cards, activating abilities, resolving entries |
| `turn`, `combat` | phases, priority rounds, state checks; attack/block/damage |
| `legal`, `dump` | the `LEGAL`, `DUMP`, `VAULT` and `CARD` blocks |
| `engine` | setup and command execution |

The engine is a single resumable state machine: it runs rules processing until
a decision point, then consumes the next script line. Derived characteristics
are recomputed for the whole board at once, only after a state change.

## Tests

* unit tests live next to the code (`cargo test --lib`);
* `tests/golden.rs` runs every match file in `tests/cases/` (including the
  worked examples of the specification) and compares the log;
* `tests/behaviour.rs` checks individual rules through the public API;
* the crate-level documentation example is run as a doc test.
