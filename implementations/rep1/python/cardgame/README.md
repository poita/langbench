# cardgame — a Spiremark rules engine

`cardgame` is a deterministic rules engine for **Spiremark**, an invented
two-player duelling-card game. It reads a *match file* (a setup block, then a
script of player actions and inspection directives), simulates the match
exactly, and prints a line-per-event log interleaved with the state dumps the
script asked for. Card data lives in an external s-expression database
(`*.spire`); nothing about any card is built into the program.

Pure Python (3.12+, developed on 3.14), standard library only. `pytest` is
needed only to run the tests.

## Building

```sh
./build.sh          # byte-compiles src/ (there is nothing else to build)
```

There is no install step. `run.sh` puts `src/` on `PYTHONPATH` and runs the
package with `python3`. If you prefer, `pip install .` also works (see
`pyproject.toml`) and provides a `cardgame` command.

## Command-line use

```sh
./run.sh < match.txt > log.txt
```

The match file arrives on stdin, everything is written to stdout, there are no
arguments, and the exit status is 0 even for `FATAL` and `ERR` cases. The card
database named by the `CARDS <path>` setup line is resolved against the current
directory.

```
CARDS data/cards.spire
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
DECK A CIN-001
DECK B CIN-001
HAND A CIN-003
START
A PLAY 1 B
A PASS
B PASS
DUMP
```

Setup lines are `CARDS`, `SEED`, `SPIRE`, `OPENING`, `MAXCAP`, `HANDMAX`,
`TURNLIMIT`, `FIRST`, `SHUFFLE`, `TRACE`, `CAP A|B`, and the zone lines `DECK`,
`HAND`, `FIELD`, `ASH`, `RIFT` (`<cardid>` or `<cardid>*<count>` entries),
ended by `START`. Script lines are player actions (`A PASS`, `A CONCEDE`,
`A PLAY <pos> [targets]`, `A ACT #<oid> <n> [targets]`, `A ATTACK [#oid…]`,
`B BLOCK [#blocker:#attacker…]`) or directives (`DUMP`, `LEGAL`, `VAULT`,
`CARD <id>`). A rejected action prints `ERR <line> <kind>`; a fatal setup
problem prints a single `FATAL bad-setup | bad-database | unknown-card` line.
The full rules and formats are in the problem's `SPEC.md`.

## Library use

```python
from cardgame import run_match

text = """\
CARDS data/cards.spire
SEED 1
SPIRE 2
OPENING 0
SHUFFLE off
DECK A CIN-001
DECK B CIN-001
HAND A CIN-003
START
A PLAY 1 B
A PASS
B PASS
"""
print(run_match(text))          # ... 14 SPIRE B -2 0 ... RESULT A spire
```

For finer control build a `Game` yourself:

```python
from cardgame import Game, load_database
from cardgame.matchfile import parse_setup, parse_script_line, split_lines

lines = split_lines(text)
config, first_script_line = parse_setup(lines)
game = Game(config, load_database(config.cards))
game.start()                          # runs to the first decision point
cmd = parse_script_line("A PASS")
error = game.submit(cmd.action)       # None if accepted, else an ERR kind
print("\n".join(game.out))            # event log so far
```

### Layout

| Module | Responsibility |
| --- | --- |
| `sexpr` | s-expression reader and canonical printer |
| `model`, `database` | typed cards; grammar validation; effect compilation |
| `prng` | the xorshift\* generator and shuffle |
| `config`, `matchfile` | setup block and script-line parsing |
| `state`, `core` | players, objects, chain entries, records; zones, timestamps, Field membership |
| `layers` | whole-board derivation of current characteristics (cached) |
| `interp` | selectors, filters, amounts, conditions, the effect interpreter |
| `changes` | damage, destruction, drawing and the other state changes |
| `targeting`, `triggers` | target legality and automatic choice; trigger collection and ordering |
| `legal` | action predicates and the `LEGAL` enumeration |
| `engine` | `Game`: setup, turn structure, priority/chain, combat, action validation |
| `dump`, `runner`, `cli` | inspection blocks, whole-match driver, command-line entry |

The engine is a single resumable generator: it runs rules processing until a
decision point, then waits for the next accepted action. Nothing is replayed
and no state is copied. Derived characteristics are cached and recomputed only
after a change they can depend on.

## Tests

```sh
python3 -m pytest
```

Unit tests cover the reader, the validator, the PRNG, setup/script parsing, the
engine and the CLI. `tests/test_conformance.py` additionally runs every case of
the problem's own suite when `../problems/cardgame/tests` exists (or the
directory named by `CARDGAME_PROBLEM_DIR`), and is skipped otherwise.
