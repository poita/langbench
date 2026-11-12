# chess-perft

A legal move generator for standard chess, with **perft** and **divide**,
written in pure Python (standard library only). Positions are bitboards;
legality comes from the king's checkers and pinned pieces rather than from
try-and-undo, and the last ply of a perft is counted with `int.bit_count`
instead of being played.

## Layout

```
src/chess_perft/
  constants.py  colours, piece types, castling bits, board masks, square names
  tables.py     knight/king/pawn attacks, BETWEEN, slider lookup tables
  moves.py      packed-int move encoding and UCI formatting
  position.py   Position: FEN in/out, make/unmake
  movegen.py    generate_legal_moves, count_legal_moves
  perft.py      perft, divide
  cli.py        stdin/stdout query interface (python -m chess_perft)
tests/          pytest suite
```

## Build

There is nothing to compile; `build.sh` byte-compiles the package:

```
./build.sh
```

Requires Python 3.12+ (developed on 3.14). Tests need `pytest`:

```
python3 -m pytest          # from this directory
```

## Command line

`run.sh` reads queries on stdin, one per line, and writes results to stdout:

```
<fen: 6 fields> <depth>            ->  perft(depth)
<fen: 6 fields> divide <depth>     ->  "<move> <count>" per legal move, then "total <n>"
```

Moves are UCI (`e2e4`, `e7e8q`, castling as the king move `e1g1`) and divide
lines are sorted by move text. The half-move/full-move fields are ignored.

```
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

Exit status is 0 on success; malformed input prints a message to stderr and exits 1.

## Library

```python
from chess_perft import START_FEN, Position, perft, divide, move_to_uci

pos = Position.from_fen(START_FEN)
print(perft(pos, 4))                    # 197281
print(divide(pos, 2)[:2])               # [('a2a3', 20), ('a2a4', 20)]

moves = pos.legal_moves()               # packed ints
print(sorted(move_to_uci(m) for m in moves)[:3])   # ['a2a3', 'a2a4', 'b1a3']

move = pos.parse_uci("e2e4")
undo = pos.make(move)                   # in place; returns an undo token
print(pos.to_fen())
pos.unmake(move, undo)                  # back to the start position
```

Public API (`chess_perft`):

| Name | Description |
|---|---|
| `Position.from_fen(fen)` / `.to_fen()` | parse / write FEN; raises `FenError` on bad input |
| `Position.legal_moves()` / `.legal_move_count()` | legal moves (packed ints) / their number |
| `Position.make(move)` / `.unmake(move, undo)` | play / take back a move in place |
| `Position.parse_uci(text)`, `.in_check()`, `.copy()` | helpers |
| `perft(pos, depth)` | leaf count; `pos` is restored afterwards |
| `divide(pos, depth)` | `[(uci, count), ...]` sorted by move text |
| `generate_legal_moves(pos)`, `count_legal_moves(pos)` | the generator itself |
| `move_to_uci(move)` | UCI text; field accessors are in `chess_perft.moves` |

Input positions are assumed legal (one king each, the side not to move not in
check). Castling rights without the king/rook on its home square, and an en
passant square inconsistent with a just-advanced pawn, are silently dropped.
No fifty-move, repetition or insufficient-material rule is applied.
