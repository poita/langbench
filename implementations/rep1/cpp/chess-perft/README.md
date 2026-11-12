# chess-perft

A small C++20 library and command-line tool that generates the legal moves of
a chess position and answers **perft** and **divide** queries.

* Bitboard position with copy-make move execution.
* Legal move generation driven by the king's checkers and pinned pieces; only
  king moves and en passant captures are verified by testing attacks.
* Depth-1 nodes are counted from the generated move list (bulk counting); the
  rest of the tree is walked in full — no hash tables, no threads.
* Only the standard library is used (GoogleTest for the tests).

## Layout

| Path | Contents |
|---|---|
| `include/chessperft/` | public headers (`chessperft.hpp` includes everything) |
| `src/` | library implementation, one module per header |
| `cli/main.cpp` | the `chess-perft` command-line tool |
| `tests/` | GoogleTest unit tests |
| `build.sh`, `run.sh` | build and run helpers |

Modules: `types` (squares, pieces, bitboard helpers), `move` (`Move`,
`MoveList`), `attacks` (attack tables, `between`, `line`), `position` (board
state, `makeMove`, attack queries), `fen`, `movegen`, `perft`, `query` (the CLI
text format).

## Build

Requires a C++20 compiler and CMake ≥ 3.20; the tests need GoogleTest.

```sh
./build.sh            # Release build into ./build
# or manually:
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
ctest --test-dir build            # run the unit tests
cmake -S . -B build -DCHESSPERFT_BUILD_TESTS=OFF   # without GoogleTest
```

## Command-line use

`./run.sh` (or `build/chess-perft`) reads queries from stdin, one per line, and
writes one result per query to stdout:

```
<fen: placement side castling ep halfmove fullmove> <depth>
<fen: placement side castling ep halfmove fullmove> divide <depth>
```

The halfmove and fullmove counters are ignored. A perft query prints the leaf
count; a divide query prints `<move> <count>` for every legal root move in
ascending byte order of the UCI move string, then `total <n>`.

```sh
$ echo 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 3' | ./run.sh
8902
$ echo '8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1' | ./run.sh
a6a5 1
a6b5 1
a7a8b 1
a7a8n 1
a7a8q 1
a7a8r 1
total 6
```

Malformed lines are reported on stderr and make the exit status 1; all other
lines are still answered.

## Library example

```cpp
#include <iostream>
#include "chessperft/chessperft.hpp"

int main() {
  using namespace chessperft;

  auto pos = parseFen("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1");
  if (!pos) return 1;

  std::cout << perft(*pos, 3) << '\n';                  // 97862

  for (const Move m : legalMoves(*pos)) {               // list the legal moves
    Position next = *pos;                               // copy-make
    next.makeMove(m);
    std::cout << m.toUci() << ' ' << perft(next, 2) << '\n';
  }
  for (const DivideEntry& e : divide(*pos, 2)) {        // same, sorted
    std::cout << e.move.toUci() << ' ' << e.nodes << '\n';
  }
}
```

Link against the `chessperft::chessperft` target (`add_subdirectory` this
project, or `cmake --install` it and use the headers and `libchessperft.a`).

## Notes on the rules

Positions are assumed legal: one king per side, the side not to move not in
check. The en passant square given in a FEN is used as is; a capture there is
generated only if it is legal, including the case where removing both pawns
exposes the king along the rank.
