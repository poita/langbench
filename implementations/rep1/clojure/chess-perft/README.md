# chess-perft

A legal chess move generator in Clojure with **perft** and **divide**, packaged
as a small library plus a command-line tool that answers perft/divide queries
read from stdin.

* Standard chess rules: castling, en passant (including the rank-pin case),
  promotions, check, pins, stalemate and checkmate.
* Legal moves come from check and pin information; only king moves and en
  passant captures are verified by test-playing. The last ply of a search is
  counted in bulk (moves are generated, not played).
* No dependencies beyond Clojure itself. The whole tree is walked: no
  transposition table, caching or parallelism.

Requires Clojure 1.12 (the `clojure` CLI) on a recent JDK.

## Build

```sh
./build.sh
```

AOT-compiles the command-line entry point into `classes/` (it can be run
without building, only more slowly to start).

## Command-line use

```sh
./run.sh < queries.txt
```

Each input line is one query: a FEN record (six fields) followed by a depth,
or by `divide` and a depth. The halfmove and fullmove fields are ignored.

```
$ printf '%s\n' \
    'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1 3' \
    '8/P1k5/K7/8/8/8/8/8 w - - 0 1 divide 1' | ./run.sh
8902
a6a5 1
a6b5 1
a7a8b 1
a7a8n 1
a7a8q 1
a7a8r 1
total 6
```

A perft query prints one number. A divide query prints `<move> <count>` for
each legal move, sorted by the UCI move string, then `total <n>`
(`total 0` if there are no legal moves). Moves are in UCI notation (`e2e4`,
`e1g1` for castling, `a7a8q` for promotion). See `SPEC.md` in the problem
directory for the full contract.

## Library use

```clojure
(require '[chess-perft.core :as chess])

(def pos (chess/parse-fen "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"))

(chess/perft pos 3)                         ;=> 97862
(chess/count-legal-moves pos)               ;=> 48
(map chess/move->uci (chess/legal-moves pos))
(take 3 (chess/divide pos 2))               ;=> (["a1b1" 43] ["a1c1" 43] ["a1d1" 43])

;; play moves, inspect the result
(-> (chess/start-position)
    (chess/play "e2e4")
    (chess/play "c7c5")
    chess/to-fen)
;=> "rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq c6 0 1"
```

Positions are immutable values; nothing in the library modifies a position you
pass in. `chess-perft.core` is the public API; the modules behind it are

| namespace              | responsibility                                          |
|------------------------|---------------------------------------------------------|
| `chess-perft.board`    | piece/square encodings, the `Position` record, FEN      |
| `chess-perft.attacks`  | ray/knight/king/pawn tables, `attacked?`                |
| `chess-perft.move`     | move encoding, UCI text, `make-move`                    |
| `chess-perft.movegen`  | check/pin analysis and legal move generation            |
| `chess-perft.perft`    | `perft` and `divide`                                    |
| `chess-perft.cli`      | the stdin/stdout tool (`-main`)                         |

## Tests

```sh
clojure -X:test
```

Runs the Cognitect test-runner over `test/`: unit tests for each module,
reference perft counts, CLI tests, and `test.check` properties over positions
reached by random play (e.g. `divide` totals equal `perft`).
