# chess-perft: required implementation approach

SPEC.md defines what the program must output. This note defines how it computes
it.

## Overall approach

Read all queries, and for each one parse the FEN into a bitboard position and run
a recursive perft over a **fully legal** move generator with **make/unmake**.
The generator uses precomputed attack tables and classical ray lookups for
sliders. It produces only legal moves by using a checkers set, a check-evasion
mask and pin masks, so no move needs to be played to find out whether it is
legal. At depth 1 the count is the number of legal moves, with no move played
("bulk counting"). A divide query runs the same search under each root move,
formats the root moves as UCI strings, sorts them and prints them. All output is
collected and written once.

## Required choices

1. **Bitboard position with a mailbox.** Store one 64-bit set per piece type and
   colour (or per type plus per colour), the occupancy of each colour and of
   the whole board, a 64-entry square-to-piece array, the side to move,
   castling rights as a 4-bit mask and the ep square. Square index =
   rank * 8 + file. Bitboards make attack tests and move generation set
   operations instead of square-by-square scans; the mailbox gives constant-time
   "what is on this square" for captures and unmake.
2. **Precomputed tables, built once at startup.** Knight, king and pawn attack
   sets per square (pawn per colour), and for sliders one ray set per square for
   each of the 8 directions. A "between" set (squares strictly between two
   aligned squares) and a "line" set (the full line through two aligned
   squares) may be precomputed as 64x64 tables or derived from the rays.
3. **Classical ray attacks for sliders.** A slider's attacks in one direction
   are the direction's ray masked by the first blocker: take ray & occupancy,
   find the nearest blocker with lowest-set-bit (directions that increase the
   index) or highest-set-bit (directions that decrease it), and remove the ray
   beyond it. Bishop = 4 diagonal rays, rook = 4 orthogonal rays, queen = both.
   Do not use magic, PEXT or rotated bitboards and do not walk squares one at a
   time. This keeps the slider cost to a few table loads and one bit-scan per
   direction.
4. **Fully legal generation using checks and pins.** At each node:
   - Compute the king square and the set of enemy pieces attacking it
     (checkers), using the tables in reverse from the king square.
   - Two or more checkers: generate king moves only.
   - One checker: non-king moves must land in the evasion mask, which is the
     checker's square plus, for a sliding checker, the squares between it and
     the king. No checker: the mask is all squares not occupied by the mover.
   - Pins: for each enemy slider on a line with the king (found by intersecting
     enemy rooks/queens and bishops/queens with the king's empty-board rook and
     bishop rays), if exactly one piece lies between them and it is the mover's,
     that piece is pinned and may only move along the line through king and
     pinner. A pinned knight never moves.
   - King moves: a destination is legal iff it is not attacked by the opponent
     with the king removed from the occupancy, so sliders x-ray through the
     king's current square.
   - Castling: the right is present, the squares between king and rook are
     empty, the king is not in check, and the transit and landing squares are
     not attacked.
   - En passant (at most two candidates per node): do not apply the evasion
     or pin masks, because capturing a checking pawn lands outside the
     evasion mask. Instead test the king directly on the occupancy after the
     capture (both pawns removed, capturer on the target square), with the
     captured pawn excluded from the attackers. This one test covers check
     evasion, diagonal pins and the horizontal discovered check along the
     rank vacated by both pawns.
   An attack query tests pawns, knights and king by table lookup and computes
   slider rays only when the matching enemy slider set is non-empty. Each node
   costs one pass over the mover's pieces with set operations and one attack
   query per king destination and castling square. No move is played to test
   legality.
5. **Bulk counting at depth 1.** `perft(0) = 1`. For depth 1, generate the legal
   moves and return how many there are. Do not play them and do not recurse.
   Interior nodes generate the legal moves, then for each one make it, recurse
   with depth - 1 and unmake it.
6. **Make/unmake in place with a small undo record.** Keep one position per
   query and mutate it. The undo record holds the captured piece (and its
   square for en passant), the previous castling rights and the previous ep
   square. Update castling rights by ANDing with a per-square mask for both the
   origin and destination squares, which handles king moves, rook moves and
   captures on corners in one step. Do not copy the whole position for each
   child.
7. **Compact moves and preallocated move storage.** A move is a small integer
   packing origin, destination, promotion piece and a flag (double push, en
   passant, castle). Moves are stored in a fixed-capacity buffer per ply (256
   entries are enough) or in one preallocated move stack shared by the whole
   search. Nothing is allocated per move. Where the language makes every list a
   heap object, one list per interior node is the accepted cost.
8. **Pawns generated set-wise.** Single pushes, double pushes and the two
   capture directions are each one shift-and-mask over the whole pawn set,
   intersected with the evasion mask. Origins are recovered from the
   destination by subtracting the shift. Pinned pawns are either taken out of
   the set and handled one by one, or each destination of a pinned origin is
   checked against the line through king and origin. Destinations on the last
   rank expand into four promotion moves, all generated (and counted) as
   distinct moves.
9. **Divide.** Generate the root's legal moves, run perft(depth - 1) under each
   (no recursion at depth 1, where every count is 1), convert only the root
   moves to UCI strings, sort the at most a few hundred (string, count) pairs
   by byte order and sum the counts for the `total` line.
10. **I/O.** Read stdin in bulk or through a buffered reader, split each line on
    single spaces, ignore the halfmove and fullmove fields, and build output in
    one buffer (or a buffered writer) flushed once at the end. Counters are
    64-bit integers.
11. **Plain single-threaded search.** No transposition table, hashing,
    memoisation of subtrees, threads or parallelism. The count comes from
    walking the tree.

## Left to the implementer

- Per-type-and-colour versus per-type plus per-colour bitboards. Whether the
  mailbox stores colour and type together. The exact bit layout of a move and
  of the undo record.
- Whether between and line sets are 64x64 tables or computed from rays. Whether
  the generator is one function or split per piece and per colour.
- The order in which moves are generated (divide output is sorted anyway).
- Recursion style, whether the depth-1 branch sits in the caller or the callee,
  and how move buffers are owned (stack array per ply or one shared stack).
- Struct layout, naming, module structure, inlining hints, branch layout and
  similar micro-optimisations that do not change the algorithm.
- How the bit-scan is written (compiler intrinsic, standard library helper,
  or for arbitrary-precision integers `(b & -b)` with a bit-length).

## Pitfalls

- **Pseudo-legal generation plus make-and-test for every move**, including at
  depth 1. Each leaf then costs a make, a full king-attack query and an unmake
  instead of one increment, which is several times slower on the wide trees
  that dominate the leaf count. Make/unmake is only for descending into
  interior nodes.
- **Copy-make**: duplicating the board array or the position for every child.
  Every child then pays for a full position copy, and often an allocation,
  instead of a few field updates.
- **Mailbox ray walks** (0x88, 10x12 or 8x8 square stepping) for slider moves
  or attack tests instead of ray-mask lookups. They visit every empty square
  on the ray.
- **King-move legality tested with the king still on its square.** A slider
  checking along the line then appears blocked by the king, and squares behind
  the king are wrongly accepted. Remove the king from the occupancy for this
  test.
- **En passant through the normal masks.** Filtering it by the evasion mask
  rejects the legal capture of a checking pawn, and the pin masks miss the
  rank pin where both pawns leave the king's rank. Use the explicit king test.
- **Bulk counting a pseudo-legal list.** The depth-1 count is only correct
  when every generated move is legal, so all legality rules (pins, evasions,
  king destinations, castling squares, en passant) must hold in the generator.
- **Allocating per node or per move**: a fresh growable list per node in a
  language that can avoid it, building UCI strings or move objects inside the
  search, or boxing moves. Strings are only needed for divide's root moves.
- **Arbitrary-precision integers left unmasked.** Where integers are unbounded,
  mask left shifts to 64 bits, or bitboards grow beyond 64 bits and every
  operation slows down.
- **Unbuffered output** (one write or flush per line) and re-parsing or
  re-splitting the line once per field.
- **Caching or parallelising the search** (hash tables of subtree counts,
  threads). This makes the result measure something other than move generation
  and is not allowed.
