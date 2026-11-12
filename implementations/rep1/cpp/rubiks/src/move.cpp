#include "rubiks/move.hpp"

#include <algorithm>

namespace rubiks {

namespace {
constexpr char kFaceChars[] = {'U', 'R', 'F', 'D', 'L', 'B'};
constexpr std::string_view kNames[kMoveCount] = {
    "U", "U2", "U'", "R", "R2", "R'", "F", "F2", "F'",
    "D", "D2", "D'", "L", "L2", "L'", "B", "B2", "B'"};

int faceFromChar(char c) {
  for (int i = 0; i < kFaceCount; ++i)
    if (kFaceChars[i] == c) return i;
  return -1;
}
}  // namespace

std::string_view Move::str() const { return kNames[index_]; }

std::optional<Move> parseMove(std::string_view token) {
  if (token.empty() || token.size() > 2) return std::nullopt;
  int f = faceFromChar(token[0]);
  if (f < 0) return std::nullopt;
  int turns = 1;
  if (token.size() == 2) {
    if (token[1] == '2') turns = 2;
    else if (token[1] == '\'') turns = 3;
    else return std::nullopt;
  }
  return Move(static_cast<Face>(f), turns);
}

bool parseMovesInto(std::string_view text, std::vector<Move>& out) {
  auto isSpace = [](char c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; };
  std::size_t i = 0;
  while (i < text.size()) {
    while (i < text.size() && isSpace(text[i])) ++i;
    std::size_t j = i;
    while (j < text.size() && !isSpace(text[j])) ++j;
    if (j > i) {
      auto m = parseMove(text.substr(i, j - i));
      if (!m) return false;
      out.push_back(*m);
    }
    i = j;
  }
  return true;
}

std::optional<std::vector<Move>> parseMoves(std::string_view text) {
  std::vector<Move> out;
  if (!parseMovesInto(text, out)) return std::nullopt;
  return out;
}

std::string toString(std::span<const Move> moves) {
  std::string s;
  for (Move m : moves) {
    if (!s.empty()) s += ' ';
    s += m.str();
  }
  return s;
}

std::vector<Move> inverse(std::span<const Move> moves) {
  std::vector<Move> r;
  r.reserve(moves.size());
  for (auto it = moves.rbegin(); it != moves.rend(); ++it) r.push_back(it->inverse());
  return r;
}

}  // namespace rubiks
