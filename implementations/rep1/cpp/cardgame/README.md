# spiremark

A rules engine for **Spiremark**, an invented two-player duelling-card game, written
in C++17 with no dependencies beyond the standard library. It is split into a
reusable library and a thin command-line tool.

The game is specified in `problems/cardgame/SPEC.md`. The engine reads a *match
file* (setup block plus a script of player actions and inspection directives),
simulates the match deterministically, and writes one log line per rules event.
Cards are data: they are read at run time from an s-expression database
(`.spire` file) and interpreted by a tree-walking effect interpreter.

## Building

Requirements: a C++17 compiler, CMake ≥ 3.20, and GoogleTest (only for the tests).

```sh
./build.sh            # Release build into ./build
# or, by hand:
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build        # run the unit tests
```

Pass `-DSPIREMARK_BUILD_TESTS=OFF` to build without GoogleTest.

## Command-line use

```sh
./run.sh < match.txt          # same as build/spiremark < match.txt
```

The tool takes no arguments: the whole match file arrives on stdin, the log goes
to stdout, and the exit status is always 0 (setup problems print a single
`FATAL bad-setup | bad-database | unknown-card` line; rejected actions print
`ERR <line> <kind>`). The `CARDS <path>` line of the match file names the card
database; relative paths resolve against the current directory.

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
```

produces

```
1 GAME-START A
2 TURN 1 A
...
8 PLAY A ~1 #2 CIN-003 #4
9 PAY A ember 1
...
15 DESTROY #4 TOK-001
```

Directives `DUMP`, `LEGAL`, `VAULT` and `CARD <id>` print inspection blocks without
changing the game; `TRACE legal|state` in the setup prints one after every
accepted action. See SPEC.md for the full format.

## Layout

| Path | Purpose |
| --- | --- |
| `include/spiremark/sexpr.hpp` | s-expression reader (`parse_sexprs`) |
| `include/spiremark/card.hpp` | typed card model: filters, selectors, effects, statics, abilities |
| `include/spiremark/database.hpp` | `Database`: parse + validate a `.spire` file, `CARD` rendering |
| `include/spiremark/script.hpp` | match-file setup block and script-line parsing |
| `include/spiremark/rng.hpp` | the xorshift* generator and shuffle |
| `include/spiremark/game.hpp` | `Game`: the rules engine |
| `include/spiremark/session.hpp` | `run_match`: whole-file driver used by the CLI |
| `src/game_state.cpp` | setup, zones, the layer system (derivation of current characteristics) |
| `src/game_effects.cpp` | selectors, filters, amounts, effect interpreter, state-change primitives |
| `src/game_chain.cpp` | triggers, `settle`, targeting, playing/activating, resolution |
| `src/game_turn.cpp` | turn structure, priority, combat, action dispatch |
| `src/game_report.cpp` | `DUMP`, `LEGAL`, `VAULT` blocks |
| `cli/main.cpp` | the command-line tool |
| `tests/` | GoogleTest unit and end-to-end tests |

The engine is a single resumable state machine: `Game` runs rules processing
until a decision point (priority, attackers, blockers) and `Game::apply`
consumes one action at a time; nothing is replayed or copied. Current
characteristics are derived for the whole board at once, layer by layer, and
cached until a state change invalidates them.

## Library example

```cpp
#include <iostream>
#include <sstream>

#include "spiremark/database.hpp"
#include "spiremark/game.hpp"
#include "spiremark/script.hpp"

int main() {
    using namespace spiremark;

    Database db = Database::load_file("data/cards.spire");

    MatchSetup setup;
    setup.cards_path = "data/cards.spire";
    setup.seed = 1;
    setup.opening = 0;
    setup.shuffle = false;
    setup.zones[0][0] = {{"CIN-001", 1}};   // DECK A
    setup.zones[0][1] = {{"CIN-001", 1}};   // DECK B
    setup.zones[1][0] = {{"CIN-003", 1}};   // HAND A: Searing Bolt

    GameSetup gs;
    if (!resolve_setup(setup, db, gs)) return 1;

    Game game(db, gs, std::cout);           // setup runs; events are printed to cout
    // A plays Searing Bolt at player B, then both pass so it resolves.
    for (const char* line : {"A PLAY 1 B", "A PASS", "B PASS"}) {
        ScriptLine sl = parse_script_line(line);
        if (auto err = game.apply(sl.action))
            std::cout << "rejected: " << err_name(*err) << "\n";
    }
    game.print_dump();
    game.finish();
}
```

Whole files can be run with `spiremark::run_match(text, std::cout)`.

## Tests

`ctest --test-dir build` runs the unit tests (reader, database validator, script
parser, PRNG) and end-to-end rules scenarios over a small inline card database.
The problem's own conformance suite is run from the repository root with
`python3 run_tests.py cardgame -- cardgame/run.sh`.
