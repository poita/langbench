// The text query format: one FEN plus a depth, optionally "divide".
#pragma once

#include <optional>
#include <string>
#include <string_view>

#include "chessperft/position.hpp"

namespace chessperft {

/// A parsed query line.
struct Query {
  Position position;
  int depth = 0;
  bool divide = false;
};

/// Parses `"<fen, six fields> <depth>"` or `"<fen> divide <depth>"`.
/// Returns `std::nullopt` if the line is malformed.
std::optional<Query> parseQuery(std::string_view line);

/// Evaluates a query and renders its output: a single count line for perft,
/// or sorted `<move> <count>` lines followed by `total <n>` for divide. Every
/// line, including the last, ends with '\n'.
std::string answerQuery(const Query& query);

}  // namespace chessperft
