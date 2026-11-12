#include "chessperft/fen.hpp"

#include <array>
#include <cstddef>

#include "chessperft/types.hpp"

namespace chessperft {

namespace {

constexpr std::string_view kPieceChars = "PNBRQKpnbrqk";

std::optional<Piece> pieceFromChar(char c) {
  const std::size_t i = kPieceChars.find(c);
  if (i == std::string_view::npos) return std::nullopt;
  return static_cast<Piece>(i);
}

}  // namespace

std::optional<Position> parseFen(std::string_view fen) {
  // Split on single spaces.
  std::array<std::string_view, 6> fields;
  std::size_t count = 0;
  while (true) {
    const std::size_t space = fen.find(' ');
    if (count == fields.size()) return std::nullopt;
    fields[count++] = fen.substr(0, space);
    if (space == std::string_view::npos) break;
    fen.remove_prefix(space + 1);
  }
  if (count < 4) return std::nullopt;

  Position pos;

  // Placement, rank 8 first.
  int rank = 7, file = 0;
  for (const char c : fields[0]) {
    if (c == '/') {
      if (file != 8 || rank == 0) return std::nullopt;
      --rank;
      file = 0;
    } else if (c >= '1' && c <= '8') {
      file += c - '0';
      if (file > 8) return std::nullopt;
    } else {
      const auto piece = pieceFromChar(c);
      if (!piece || file >= 8) return std::nullopt;
      pos.setPiece(makeSquare(file++, rank), *piece);
    }
  }
  if (rank != 0 || file != 8) return std::nullopt;
  if (popcount(pos.pieces(Color::White, PieceType::King)) != 1 ||
      popcount(pos.pieces(Color::Black, PieceType::King)) != 1) {
    return std::nullopt;
  }

  // Side to move.
  if (fields[1] == "w") pos.setSideToMove(Color::White);
  else if (fields[1] == "b") pos.setSideToMove(Color::Black);
  else return std::nullopt;

  // Castling rights.
  std::uint8_t rights = 0;
  if (fields[2] != "-") {
    if (fields[2].empty()) return std::nullopt;
    for (const char c : fields[2]) {
      switch (c) {
        case 'K': rights |= kWhiteKingside; break;
        case 'Q': rights |= kWhiteQueenside; break;
        case 'k': rights |= kBlackKingside; break;
        case 'q': rights |= kBlackQueenside; break;
        default: return std::nullopt;
      }
    }
  }
  pos.setCastlingRights(rights);

  // En passant target.
  if (fields[3] != "-") {
    const auto ep = parseSquare(fields[3]);
    if (!ep) return std::nullopt;
    pos.setEnPassantSquare(*ep);
  }
  return pos;
}

std::string toFen(const Position& pos) {
  std::string out;
  for (int rank = 7; rank >= 0; --rank) {
    int empty = 0;
    for (int file = 0; file < 8; ++file) {
      const Piece p = pos.pieceAt(makeSquare(file, rank));
      if (p == Piece::None) {
        ++empty;
        continue;
      }
      if (empty) out += static_cast<char>('0' + empty);
      empty = 0;
      out += kPieceChars[static_cast<std::size_t>(p)];
    }
    if (empty) out += static_cast<char>('0' + empty);
    if (rank) out += '/';
  }
  out += pos.sideToMove() == Color::White ? " w " : " b ";
  const std::uint8_t r = pos.castlingRights();
  if (r == 0) out += '-';
  if (r & kWhiteKingside) out += 'K';
  if (r & kWhiteQueenside) out += 'Q';
  if (r & kBlackKingside) out += 'k';
  if (r & kBlackQueenside) out += 'q';
  out += ' ';
  out += squareName(pos.enPassantSquare());
  out += " 0 1";
  return out;
}

}  // namespace chessperft

namespace chessperft {

Position Position::startPosition() {
  return *parseFen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1");
}

}  // namespace chessperft
