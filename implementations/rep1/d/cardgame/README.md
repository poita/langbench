# cardgame

A rules engine and match-log simulator for **Spiremark**, an invented two-player
duelling-card game, written in D using only the standard library (Phobos).

The program reads a *match file* (a setup block followed by a script of player
actions and inspection directives), simulates the match exactly as the rules
specify, and prints a deterministic log: one numbered line per rules event,
interleaved with the blocks requested by the inspection directives. Cards are
**data**: they are read at run time from an s-expression card database, and the
engine interprets their abilities with a tree-walking evaluator.

It is organised as a reusable library (`source/cardgame/`) with a thin
command-line tool (`app/main.d`) on top.

## Requirements

* LDC 1.41.0 (`ldc2`) and dub 1.40.0 — other recent versions should work.
* No third-party dependencies.

## Building

```sh
./build.sh                                  # or:
dub build -b release --compiler=ldc2        # produces bin/cardgame
```

`build.sh` works from any directory. `run.sh` runs the built tool the same way.

## Command-line usage

```sh
./run.sh < match.txt          # match file on stdin, log on stdout
```

The tool takes no arguments, reads the whole match file from standard input,
writes the log to standard output, and exits with status 0 — including for
every `FATAL` and `ERR` case. The card database named by the match file's
`CARDS <path>` line is read from the file system, relative to the current
directory.

A match file looks like this:

```
CARDS data/cards.spire
SEED 1
SPIRE 10
OPENING 0
SHUFFLE off
DECK A CIN-001
DECK B CIN-001
HAND A CIN-003
FIELD B TOK-001
START
A PLAY 1 #4
A PASS
B PASS
DUMP
```

* **Setup lines** (before `START`): `CARDS`, `SEED`, `SPIRE`, `OPENING`,
  `MAXCAP`, `HANDMAX`, `TURNLIMIT`, `FIRST`, `SHUFFLE`, `TRACE`, `CAP`, and the
  zone lines `DECK`, `HAND`, `FIELD`, `ASH`, `RIFT` (entries are `CARD-ID` or
  `CARD-ID*count`). A bad setup prints `FATAL bad-setup`, an invalid database
  `FATAL bad-database`, and an unknown card id `FATAL unknown-card`.
* **Actions** (after `START`): `<A|B> PASS`, `CONCEDE`, `PLAY <pos> [targets]`,
  `ACT #<oid> <index> [targets]`, `ATTACK [#oid …]`, `BLOCK [#blocker:#attacker …]`.
  A rejected action prints `ERR <line> <kind>` and has no other effect.
* **Directives**: `DUMP` (full state), `LEGAL` (legal actions), `VAULT`
  (library order), `CARD <id>` (canonical card description).
* Lines starting with `#` and blank lines are comments.

The log ends with `RESULT <winner> <reason>`, or `RESULT pending none` when the
script ends before the match is decided. The complete rules, file formats and
output formats are defined in `problems/cardgame/SPEC.md` of the surrounding
repository.

## Library overview

`import cardgame;` brings in the whole public API. The modules, by
responsibility:

| Module | Responsibility |
| --- | --- |
| `cardgame.sexpr` | tokenising/parsing s-expressions; canonical printing |
| `cardgame.cards` | typed card model: `Card`, `Ability`, `Effect`, `Sel`, `Filter`, … |
| `cardgame.parser` | database validation: `parseDatabase`, `DatabaseError` |
| `cardgame.rng` | the specified 64-bit xorshift* generator and shuffle |
| `cardgame.game` | game state (`Game`, `Obj`, `Entry`, …) and the event log |
| `cardgame.derive` | the layer system: whole-board derivation of current characteristics |
| `cardgame.eval` | selectors, filters, amounts, conditions, target legality/enumeration |
| `cardgame.actions` | state-changing procedures (damage, destroy, draw, …) and trigger collection |
| `cardgame.effects` | the effect interpreter |
| `cardgame.engine` | Chain, priority, settling, state checks, turn machine, combat, player actions |
| `cardgame.report` | `DUMP`, `LEGAL`, `VAULT`, `CARD` blocks |
| `cardgame.match` | match-file parsing and the `simulate` entry point |

### Example

```d
import std.file : readText;
import std.stdio : write, writeln;

import cardgame;

void main()
{
    // 1. One call: simulate a whole match file and get the log back.
    immutable match = "CARDS data/cards.spire\nSEED 1\nSPIRE 10\nOPENING 0\nSHUFFLE off\n"
        ~ "HAND A CIN-003\nFIELD B TOK-001\nSTART\nA PLAY 1 #2\nA PASS\nB PASS\nDUMP\n";
    write(simulate(match, path => readText(path)));

    // 2. Inspect the card database directly.
    auto db = parseDatabase(readText("data/cards.spire"));   // throws DatabaseError if invalid
    auto bolt = db.find("CIN-003");
    writeln(bolt.name, " costs ", bolt.cost, " and has ", bolt.abilities.length, " ability");

    // 3. Reproduce the specified random-number stream.
    auto rng = Rng(7);
    writeln(rng.next());                                      // 15130880334998875822
}
```

`simulate(input, readFile)` takes the match-file text and a delegate that
loads the database for a path (so a library user can serve databases from
memory); it returns the complete log. Lower-level users can build a `Game`
from a `CardDb` and a `Config`, and drive it with `engine.doPlay`, `doPass`,
`doAct`, `doAttack`, `doBlock` and `doConcede`.

## Design notes

* **Typed card model.** The database is parsed once into enum-tagged trees;
  nothing compares strings while a match runs.
* **Resumable engine.** `advance` runs the turn machine to the next decision
  point (priority, attackers, blockers) and returns; every accepted action
  resumes it. The match is simulated exactly once.
* **Objects in a dense array indexed by oid**; the Field is kept in canonical
  `(timestamp, oid)` order by appending on entry and removing in place.
* **Whole-board derivation** (SPEC 14.3) computes controllers, keywords, edge
  and core for the Field in a single layered pass. The result is cached and
  only invalidated by structural changes, or by changes of a kind that some
  live aura actually reads (each aura carries a dependency bit mask computed at
  load time).
* Output is accumulated in one buffer and written at the end.

## Tests

Unit tests live in `tests/` (separate from the library sources) and cover the
s-expression reader, the PRNG, the database validator, match-file handling and
rules scenarios taken from the specification's worked examples:

```sh
dub test --compiler=ldc2
```

The end-to-end suite lives with the problem definition:

```sh
cd .. && cardgame/build.sh && python3 run_tests.py cardgame -- cardgame/run.sh
```

## Layout

```
dub.json            project manifest (configurations: cli, library, unittest)
build.sh, run.sh    build and run wrappers
app/main.d          command-line tool
source/cardgame/    the library
tests/              unit tests
```
