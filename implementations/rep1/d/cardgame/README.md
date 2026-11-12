# cardgame

`cardgame` is a deterministic rules engine for **Spiremark**, an invented
two-player duelling-card game, written in D using only the standard library.
It reads a *match file* (a setup block followed by a script of player actions
and inspection directives), plays the match exactly as the rules specify, and
prints a one-line-per-event log interleaved with the blocks the directives ask
for. Card definitions are data, read at run time from an s-expression
database; nothing about any card is compiled in.

The project is a reusable library (`source/cardgame/`) plus a thin
command-line tool (`app/main.d`).

## Building

Requires LDC (tested with 1.41.0) and dub (tested with 1.40.0).

```sh
./build.sh                                # or: dub build -b release --compiler=ldc2
```

This produces `bin/cardgame`. `./run.sh` runs it from any directory.

## Using the command line tool

The tool takes no arguments. It reads the match file on stdin and writes the
log to stdout; it always exits 0 (setup problems print a single `FATAL ...`
line). The card database named by the `CARDS` line is resolved against the
current working directory.

```
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
A PASS
```

```sh
./run.sh < match.txt
```

```
1 GAME-START A
2 TURN 1 A
...
12 RESOLVE ~1
13 DAMAGE #2 B 2
14 SPIRE B -2 0
15 SPENT #2 CIN-003
16 LOSE B spire
17 RESULT A spire
ERR 13 game-over
```

Setup lines (`CARDS`, `SEED`, `SPIRE`, `OPENING`, `MAXCAP`, `HANDMAX`,
`TURNLIMIT`, `FIRST`, `SHUFFLE`, `TRACE`, `CAP`, `DECK`, `HAND`, `FIELD`,
`ASH`, `RIFT`, `START`) configure the match; script lines are player actions
(`A PASS`, `B PLAY 2 #7`, `A ACT #4 1`, `A ATTACK #4`, `B BLOCK #9:#4`,
`A CONCEDE`) and the directives `DUMP`, `LEGAL`, `VAULT` and `CARD <id>`. The
complete rules, formats and error kinds are in the problem's `SPEC.md`.

## Layout

| Module | Responsibility |
| --- | --- |
| `cardgame.sexpr` | s-expression reader and canonical printer |
| `cardgame.model` | typed cards, abilities, effects, selectors, filters |
| `cardgame.database` | converts and validates a card database |
| `cardgame.matchfile` | setup block and script-line parsing |
| `cardgame.game` | game state: objects, zones, Chain, records, event log |
| `cardgame.layers` | whole-board derivation of current characteristics |
| `cardgame.select` | filters, selectors, amounts, conditions, targeting |
| `cardgame.effects` | the effect interpreter |
| `cardgame.procs` | atomic state changes: damage, destroy, draw, ... |
| `cardgame.triggers` | trigger collection and ordered pushing |
| `cardgame.chain` | playing, activating and resolving Chain entries |
| `cardgame.combat` | attack/block legality, declaration, combat damage |
| `cardgame.settle` | state checks, `settle`, `drain`, match end |
| `cardgame.engine` | the resumable engine (turn flow, priority) on a fiber |
| `cardgame.legal`, `cardgame.dump` | `LEGAL`, `DUMP`, `VAULT`, `CARD` output |
| `cardgame.session` | `runMatch`: the library entry point |
| `cardgame.rng` | the xorshift* generator |

The engine simulates a match once: rules processing runs on a fiber that
suspends at each decision point and resumes with the next validated action.
Current characteristics are derived for the whole Field at once, and only when
something they can depend on has changed.

## Using the library

```d
import cardgame.session : runMatch;
import std.file : readText;
import std.stdio : write;

void main()
{
    immutable match = "CARDS cards.spire\nSEED 7\nOPENING 0\nSHUFFLE off\nSTART\nA PASS\nB PASS\n";
    // The second argument tells the engine how to read the card database.
    write(runMatch(match, (string path) => readText(path)));
}
```

`runMatch` returns exactly what the command-line tool prints. The lower-level
pieces (`parseDatabase`, `parseSetup`, `buildGame`, `Engine`, `processLine`)
are public too, for embedding the engine in a different front end.

## Tests

```sh
dub test --compiler=ldc2
```

The tests are D `unittest` blocks: unit tests for the reader, validator,
generator and match-file parser, and golden scenarios (the worked examples of
the specification, in `source/cardgame/scenarios.d`) that run whole matches
against a small in-memory database.
