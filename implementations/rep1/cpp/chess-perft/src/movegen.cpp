#include "chessperft/movegen.hpp"

#include "chessperft/attacks.hpp"

namespace chessperft {

namespace {

constexpr Bitboard kAll = ~Bitboard{0};

void addPawnMove(MoveList& out, Square from, Square to) {
  if (rankOf(to) == 0 || rankOf(to) == 7) {
    out.push_back(Move(from, to, MoveKind::PromoQueen));
    out.push_back(Move(from, to, MoveKind::PromoRook));
    out.push_back(Move(from, to, MoveKind::PromoBishop));
    out.push_back(Move(from, to, MoveKind::PromoKnight));
  } else {
    out.push_back(Move(from, to));
  }
}

// Pieces of `us` that are pinned to the king on `ksq` by a slider of `them`.
Bitboard pinnedPieces(const Position& pos, Color us, Square ksq) {
  const Color them = ~us;
  const Bitboard occ = pos.occupied();
  const Bitboard ours = pos.pieces(us);
  const Bitboard queens = pos.pieces(them, PieceType::Queen);
  Bitboard snipers =
      (bishopAttacks(ksq, 0) & (pos.pieces(them, PieceType::Bishop) | queens)) |
      (rookAttacks(ksq, 0) & (pos.pieces(them, PieceType::Rook) | queens));
  Bitboard pinned = 0;
  while (snipers) {
    const Bitboard blockers = between(ksq, popLsb(snipers)) & occ;
    if (blockers && !(blockers & (blockers - 1))) pinned |= blockers & ours;
  }
  return pinned;
}

}  // namespace

void generateLegalMoves(const Position& pos, MoveList& out) {
  const Color us = pos.sideToMove();
  const Color them = ~us;
  const Square ksq = pos.kingSquare(us);
  const Bitboard occ = pos.occupied();
  const Bitboard ours = pos.pieces(us);
  const Bitboard theirs = pos.pieces(them);

  const Bitboard checkers = pos.attackersTo(ksq, them, occ);
  const Bitboard pinned = pinnedPieces(pos, us, ksq);

  // King moves: the destination must not be attacked once the king has left
  // its square (so sliders "see through" it).
  const Bitboard occWithoutKing = occ ^ bit(ksq);
  for (Bitboard dests = kingAttacks(ksq) & ~ours; dests;) {
    const Square to = popLsb(dests);
    if (!pos.isAttacked(to, them, occWithoutKing)) out.push_back(Move(ksq, to));
  }
  if (checkers & (checkers - 1)) return;  // double check: king moves only

  // Squares a non-king move may land on: anything but our own pieces, or,
  // when in check, the checker or a square between it and the king.
  const Bitboard target =
      checkers ? (between(ksq, lsb(checkers)) | checkers) : ~ours;

  // A pinned piece may only move along the line through king and pinner.
  auto pinMask = [&](Square from) {
    return (pinned & bit(from)) ? line(ksq, from) : kAll;
  };

  // Knights (a pinned knight can never move).
  for (Bitboard b = pos.pieces(us, PieceType::Knight) & ~pinned; b;) {
    const Square from = popLsb(b);
    for (Bitboard d = knightAttacks(from) & target & ~ours; d;) {
      out.push_back(Move(from, popLsb(d)));
    }
  }
  // Diagonal sliders.
  for (Bitboard b = pos.pieces(us, PieceType::Bishop) | pos.pieces(us, PieceType::Queen); b;) {
    const Square from = popLsb(b);
    for (Bitboard d = bishopAttacks(from, occ) & target & ~ours & pinMask(from); d;) {
      out.push_back(Move(from, popLsb(d)));
    }
  }
  // Straight sliders.
  for (Bitboard b = pos.pieces(us, PieceType::Rook) | pos.pieces(us, PieceType::Queen); b;) {
    const Square from = popLsb(b);
    for (Bitboard d = rookAttacks(from, occ) & target & ~ours & pinMask(from); d;) {
      out.push_back(Move(from, popLsb(d)));
    }
  }

  // Pawns.
  const int up = us == Color::White ? 8 : -8;
  const int startRank = us == Color::White ? 1 : 6;
  const Square ep = pos.enPassantSquare();
  for (Bitboard b = pos.pieces(us, PieceType::Pawn); b;) {
    const Square from = popLsb(b);
    const Bitboard allowed = target & pinMask(from);

    const Square one = from + up;
    if (!(occ & bit(one))) {
      if (allowed & bit(one)) addPawnMove(out, from, one);
      if (rankOf(from) == startRank) {
        const Square two = one + up;
        if (!(occ & bit(two)) && (allowed & bit(two))) {
          out.push_back(Move(from, two, MoveKind::DoublePush));
        }
      }
    }
    const Bitboard attacks = pawnAttacks(us, from);
    for (Bitboard c = attacks & theirs & allowed; c;) addPawnMove(out, from, popLsb(c));

    // En passant is verified by playing it: removing two pawns from one rank
    // can expose the king in ways pins and checkers do not capture.
    if (ep != kNoSquare && (attacks & bit(ep))) {
      const Move m(from, ep, MoveKind::EnPassant);
      Position next = pos;
      next.makeMove(m);
      if (!next.isAttacked(ksq, them)) out.push_back(m);
    }
  }

  // Castling (never out of check). The king may not cross or land on an
  // attacked square; the rook and b-file square may be attacked.
  if (!checkers) {
    const Square home = us == Color::White ? 4 : 60;
    const std::uint8_t kingside = us == Color::White ? kWhiteKingside : kBlackKingside;
    const std::uint8_t queenside = us == Color::White ? kWhiteQueenside : kBlackQueenside;
    const Bitboard rooks = pos.pieces(us, PieceType::Rook);
    const std::uint8_t rights = pos.castlingRights();
    if ((rights & kingside) && (rooks & bit(home + 3)) &&
        !(occ & (bit(home + 1) | bit(home + 2))) &&
        !pos.isAttacked(home + 1, them, occ) && !pos.isAttacked(home + 2, them, occ)) {
      out.push_back(Move(home, home + 2, MoveKind::Castle));
    }
    if ((rights & queenside) && (rooks & bit(home - 4)) &&
        !(occ & (bit(home - 1) | bit(home - 2) | bit(home - 3))) &&
        !pos.isAttacked(home - 1, them, occ) && !pos.isAttacked(home - 2, them, occ)) {
      out.push_back(Move(home, home - 2, MoveKind::Castle));
    }
  }
}

MoveList legalMoves(const Position& pos) {
  MoveList list;
  generateLegalMoves(pos, list);
  return list;
}

}  // namespace chessperft
