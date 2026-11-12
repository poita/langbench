// Forsyth-Edwards Notation parsing and printing.
#pragma once

#include <optional>
#include <string>
#include <string_view>

#include "chessperft/position.hpp"

namespace chessperft {

/// Parses a FEN record: placement, side, castling, en passant and optionally
/// the halfmove and fullmove counters (which are ignored). Fields are separated
/// by single spaces.
///
/// Returns `std::nullopt` if the text is malformed or the position lacks
/// exactly one king per side. It does not otherwise verify legality.
std::optional<Position> parseFen(std::string_view fen);

/// Formats a position as a six-field FEN (counters are written as "0 1").
std::string toFen(const Position& pos);

}  // namespace chessperft
