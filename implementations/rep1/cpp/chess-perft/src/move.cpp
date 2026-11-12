#include "chessperft/move.hpp"

namespace chessperft {

std::string Move::toUci() const {
  std::string s = squareName(from()) + squareName(to());
  if (isPromotion()) {
    switch (promotionType()) {
      case PieceType::Knight: s += 'n'; break;
      case PieceType::Bishop: s += 'b'; break;
      case PieceType::Rook: s += 'r'; break;
      default: s += 'q'; break;
    }
  }
  return s;
}

}  // namespace chessperft
