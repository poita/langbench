/// Unit tests for bitboards, tables, moves and types.
module basics_test;

import chessperft.bitboard;
import chessperft.move;
import chessperft.tables;
import chessperft.types;

unittest // bitboard helpers
{
    assert(bit(0) == 1);
    assert(bit(63) == 0x8000000000000000UL);
    assert(lsb(0b1100) == 2);
    assert(msb(0b1100) == 3);
    assert(count(fileA) == 8);
    assert(fileOf(13) == 5 && rankOf(13) == 1);
    assert(shift!8(rank1) == 0xFF00);
    assert(shift!(-8)(0xFF00) == rank1);
}

unittest // square names
{
    assert(squareName(0) == "a1");
    assert(squareName(63) == "h8");
    assert(squareFromName("e4") == 28);
    assert(squareFromName("i1") == -1);
    assert(squareFromName("e") == -1);
    foreach (sq; 0 .. 64)
        assert(squareFromName(squareName(sq)) == sq);
}

unittest // piece packing
{
    foreach (c; [Color.white, Color.black])
        foreach (t; [PieceType.pawn, PieceType.knight, PieceType.bishop,
                PieceType.rook, PieceType.queen, PieceType.king])
        {
            immutable p = makePiece(c, t);
            assert(p != noPiece && typeOf(p) == t && colorOf(p) == c);
        }
    assert(opposite(Color.white) == Color.black);
}

unittest // leaper tables
{
    assert(count(knightAttacks[a1]) == 2);
    assert(count(knightAttacks[27]) == 8); // d4
    assert(count(kingAttacks[a1]) == 3);
    assert(count(kingAttacks[27]) == 8);
    assert(pawnAttacks[Color.white][4] == (bit(11) | bit(13))); // e1 -> d2, f2
    assert(pawnAttacks[Color.black][60] == (bit(51) | bit(53))); // e8 -> d7, f7
    assert(pawnAttacks[Color.white][0] == bit(9)); // a1 -> b2 only
    assert(pawnAttacks[Color.white][56] == 0); // no squares beyond rank 8
}

unittest // between / line
{
    assert(between[a1][h8] == (bit(9) | bit(18) | bit(27) | bit(36) | bit(45) | bit(54)));
    assert(between[a1][h1] == (bit(1) | bit(2) | bit(3) | bit(4) | bit(5) | bit(6)));
    assert(between[a1][b1] == 0);
    assert(between[a1][17] == 0); // a1, b3: not aligned
    assert(between[h8][a1] == between[a1][h8]);
    assert(line[a1][h8] == 0x8040201008040201UL);
    assert(line[a1][a8] == fileA);
    assert(line[a1][17] == 0);
}

unittest // slider attacks
{
    // Rook on an empty board sees 14 squares, bishop in the corner 7.
    assert(count(rookAttacks(27, 0)) == 14);
    assert(count(bishopAttacks(a1, 0)) == 7);
    assert(count(queenAttacks(27, 0)) == 27);
    // Blockers are included, squares behind them are not.
    immutable occ = bit(27 + 16) | bit(27 - 3) | bit(27 + 2);
    immutable att = rookAttacks(27, occ);
    assert(att & bit(27 + 16));
    assert(!(att & bit(27 + 24)));
    assert(att & bit(27 - 3));
    assert(!(att & bit(27 - 4)));
    assert(att & bit(27 + 2));
    assert(!(att & bit(27 + 3)));
    assert(att & bit(27 - 8) && att & bit(a1 + 3)); // south ray reaches d1
    // A blocker on the far edge is included.
    assert(rookAttacks(a1, bit(a8)) & bit(a8));
    assert(bishopAttacks(a1, bit(h8)) & bit(h8));
    // Compare against a naive square walk for all squares and a few occupancies.
    foreach (sq; 0 .. 64)
        foreach (occ2; [0UL, 0x00FF00000000FF00UL, 0x5555AAAA5555AAAAUL, 0xFFFFFFFFFFFFFFFFUL])
        {
            assert(rookAttacks(sq, occ2) == walk(sq, occ2, [[0, 1], [0, -1], [1, 0], [-1, 0]]));
            assert(bishopAttacks(sq, occ2) == walk(sq, occ2, [[1, 1], [1, -1], [-1, 1], [-1, -1]]));
        }
}

private Bitboard walk(int sq, Bitboard occ, int[][] dirs)
{
    Bitboard r = 0;
    foreach (d; dirs)
    {
        int f = (sq & 7) + d[0], rk = (sq >> 3) + d[1];
        while (f >= 0 && f < 8 && rk >= 0 && rk < 8)
        {
            r |= bit(rk * 8 + f);
            if (occ & bit(rk * 8 + f))
                break;
            f += d[0];
            rk += d[1];
        }
    }
    return r;
}

unittest // move packing and UCI output
{
    auto m = Move(12, 28, MoveFlag.doublePush);
    assert(m.from == 12 && m.to == 28 && m.flag == MoveFlag.doublePush);
    assert(m.toString() == "e2e4");
    assert(!m.isPromotion);

    auto c = Move(e1, g1, MoveFlag.castle);
    assert(c.toString() == "e1g1");

    foreach (flag, ch; [MoveFlag.promoteKnight: 'n', MoveFlag.promoteBishop: 'b',
            MoveFlag.promoteRook: 'r', MoveFlag.promoteQueen: 'q'])
    {
        auto p = Move(48, 56, flag);
        assert(p.isPromotion);
        assert(p.toString() == "a7a8" ~ ch);
    }
    assert(Move(48, 56, MoveFlag.promoteKnight).promotionType == PieceType.knight);
    assert(Move(48, 56, MoveFlag.promoteQueen).promotionType == PieceType.queen);
}
