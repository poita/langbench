// Legal move generation.
#pragma once

#include "chessperft/move.hpp"
#include "chessperft/position.hpp"

namespace chessperft {

/// Appends exactly the legal moves of `pos` to `out` (no pseudo-legal moves
/// are generated and later filtered).
///
/// The generator finds the king's checkers and the pieces pinned to it and
/// restricts every non-king move to the squares that resolve the check and
/// stay on the pin line. Only king moves and en passant captures are verified
/// by testing attacks on the resulting position. The position must contain one
/// king per side and the side not to move must not be in check.
void generateLegalMoves(const Position& pos, MoveList& out);

/// Convenience wrapper returning the legal moves of `pos`.
MoveList legalMoves(const Position& pos);

}  // namespace chessperft
