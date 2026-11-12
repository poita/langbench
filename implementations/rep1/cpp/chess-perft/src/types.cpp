#include "chessperft/types.hpp"

namespace chessperft {

std::optional<Square> parseSquare(std::string_view text) noexcept {
  if (text.size() != 2 || text[0] < 'a' || text[0] > 'h' || text[1] < '1' ||
      text[1] > '8') {
    return std::nullopt;
  }
  return makeSquare(text[0] - 'a', text[1] - '1');
}

std::string squareName(Square s) {
  if (s < 0 || s >= 64) return "-";
  return {static_cast<char>('a' + fileOf(s)), static_cast<char>('1' + rankOf(s))};
}

}  // namespace chessperft
