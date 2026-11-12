#pragma once

#include <algorithm>
#include <string>
#include <vector>

#include <gtest/gtest.h>

#include "chessperft/chessperft.hpp"

inline chessperft::Position mustParse(const std::string& fen) {
  auto pos = chessperft::parseFen(fen);
  EXPECT_TRUE(pos.has_value()) << fen;
  return pos.value_or(chessperft::Position{});
}

/// Sorted UCI strings of the legal moves of `fen`.
inline std::vector<std::string> uciMoves(const std::string& fen) {
  std::vector<std::string> out;
  for (const auto m : chessperft::legalMoves(mustParse(fen))) out.push_back(m.toUci());
  std::sort(out.begin(), out.end());
  return out;
}

inline bool hasMove(const std::string& fen, const std::string& uci) {
  const auto moves = uciMoves(fen);
  return std::find(moves.begin(), moves.end(), uci) != moves.end();
}
