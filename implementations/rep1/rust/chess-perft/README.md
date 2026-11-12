# chess-perft

A legal chess move generator with **perft** and **divide**, written in Rust
using only the standard library. It ships as a reusable library
(`chess_perft`) and a thin command-line tool (`chess-perft`).

The search is a plain depth-first walk of the legal move tree (no
transposition table, no caching, single-threaded). Legality comes from
check and pin information computed per node; only king moves and en passant
captures are verified by testing whether the king would be attacked. At the
last ply moves are counted rather than played (bulk counting).

## Build

```sh
cargo build --release        # or ./build.sh
```

The binary is `target/release/chess-perft`; `./run.sh` runs it from any
directory.

## Command-line usage

The tool reads queries from stdin, one per line, and prints one result per
query to stdout.

```
<placement> <side> <castling> <ep> <halfmove> <fullmove> <depth>
<placement> <side> <castling> <ep> <halfmove> <fullmove> divide <depth>
```

The first six fields are a FEN record (the two move counters are ignored).

* A perft query prints `perft(depth)`.
* A divide query prints `<move> <count>` for every legal root move, sorted by
  the UCI move string, followed by `total <n>`.

Moves use UCI notation (`e2e4`, `e1g1` for castling, `a7a8q` for promotion).

```console
$ echo 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 4' | ./run.sh
197281
$ echo '8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1' | ./run.sh
a6a5 1
a6b5 1
a7a8b 1
a7a8n 1
a7a8q 1
a7a8r 1
total 6
```

Malformed input is reported on stderr with exit status 1.

## Library usage

```rust
use chess_perft::{divide, perft, Position};

let pos = Position::from_fen(
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
)
.unwrap();

assert_eq!(pos.legal_moves().len(), 48);
assert_eq!(perft(&pos, 3), 97_862);

// Per-move counts, and playing a move:
for (mv, nodes) in divide(&pos, 2) {
    println!("{mv} {nodes}");
}
let first = pos.legal_moves()[0];
let child = pos.make_move(first);
assert_eq!(child.side_to_move(), chess_perft::Color::Black);
```

### Modules

| Module | Responsibility |
|---|---|
| `types` | `Color`, `PieceKind`, `Square` |
| `bitboard` | `Bitboard` square set |
| `attacks` | compile-time knight/king/pawn/ray/between/line tables, slider attacks |
| `moves` | `Move`, `MoveList`, and the `MoveSink` trait (list or count) |
| `position` | `Position`: FEN parsing/printing, attack queries, `make_move` |
| `movegen` | legal move generation from checkers and pins |
| `perft` | `perft` and `divide` |
| `query` | the text query format used by the CLI |

## Tests

```sh
cargo test                         # unit, rule, perft and CLI tests
cargo test --release -- --ignored  # deeper reference perft values
```
