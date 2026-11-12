#include "rubiks/cubie.hpp"

#include <algorithm>

namespace rubiks {

namespace {

// Facelet triples/pairs of each position, from SPEC.md. The first entry is
// the "primary" facelet that defines orientation.
constexpr int F(char face, int n) {
  int f = face == 'U' ? 0 : face == 'R' ? 1 : face == 'F' ? 2 : face == 'D' ? 3 : face == 'L' ? 4 : 5;
  return f * 9 + n - 1;
}

constexpr int kCornerFacelets[8][3] = {
    {F('U', 9), F('R', 1), F('F', 3)}, {F('U', 7), F('F', 1), F('L', 3)},
    {F('U', 1), F('L', 1), F('B', 3)}, {F('U', 3), F('B', 1), F('R', 3)},
    {F('D', 3), F('F', 9), F('R', 7)}, {F('D', 1), F('L', 9), F('F', 7)},
    {F('D', 7), F('B', 9), F('L', 7)}, {F('D', 9), F('R', 9), F('B', 7)}};

constexpr int kEdgeFacelets[12][2] = {
    {F('U', 6), F('R', 2)}, {F('U', 8), F('F', 2)}, {F('U', 4), F('L', 2)}, {F('U', 2), F('B', 2)},
    {F('D', 6), F('R', 8)}, {F('D', 2), F('F', 8)}, {F('D', 4), F('L', 8)}, {F('D', 8), F('B', 8)},
    {F('F', 6), F('R', 4)}, {F('F', 4), F('L', 6)}, {F('B', 6), F('L', 4)}, {F('B', 4), F('R', 6)}};

Face homeColour(int facelet) { return static_cast<Face>(facelet / 9); }

// The 18 moves as cubie permutations, derived from the facelet model so the
// two views can never disagree.
const std::array<CubieCube, kMoveCount>& moveCubes() {
  static const std::array<CubieCube, kMoveCount> table = [] {
    std::array<CubieCube, kMoveCount> t;
    for (int i = 0; i < kMoveCount; ++i) {
      FaceletCube f;
      f.apply(Move::fromIndex(i));
      t[i] = *CubieCube::fromFacelets(f);
    }
    return t;
  }();
  return table;
}

}  // namespace

void CubieCube::apply(Move move) {
  const CubieCube& m = moveCubes()[move.index()];
  CubieCube r;
  for (int i = 0; i < 8; ++i) {
    r.cp[i] = cp[m.cp[i]];
    r.co[i] = static_cast<std::uint8_t>((co[m.cp[i]] + m.co[i]) % 3);
  }
  for (int i = 0; i < 12; ++i) {
    r.ep[i] = ep[m.ep[i]];
    r.eo[i] = static_cast<std::uint8_t>(eo[m.ep[i]] ^ m.eo[i]);
  }
  *this = r;
}

void CubieCube::apply(std::span<const Move> moves) {
  for (Move m : moves) apply(m);
}

bool CubieCube::isSolved() const { return *this == CubieCube{}; }

bool CubieCube::isValid() const {
  auto parity = [](auto const& p) {
    int swaps = 0;
    for (std::size_t i = 0; i < p.size(); ++i)
      for (std::size_t j = i + 1; j < p.size(); ++j) swaps += p[i] > p[j];
    return swaps & 1;
  };
  auto isPerm = [](auto const& p) {
    std::array<bool, 12> seen{};
    for (auto v : p) {
      if (v >= p.size() || seen[v]) return false;
      seen[v] = true;
    }
    return true;
  };
  if (!isPerm(cp) || !isPerm(ep)) return false;
  int twist = 0, flip = 0;
  for (auto v : co) {
    if (v > 2) return false;
    twist += v;
  }
  for (auto v : eo) {
    if (v > 1) return false;
    flip += v;
  }
  return twist % 3 == 0 && flip % 2 == 0 && parity(cp) == parity(ep);
}

FaceletCube CubieCube::toFacelets() const {
  std::string s(kFaceletCount, 'U');
  static constexpr char kChars[] = "URFDLB";
  for (int c = 0; c < 8; ++c)
    for (int k = 0; k < 3; ++k) {
      int home = (k + 3 - co[c]) % 3;  // sticker of cubie cp[c] shown at index k
      s[kCornerFacelets[c][k]] = kChars[static_cast<int>(homeColour(kCornerFacelets[cp[c]][home]))];
    }
  for (int e = 0; e < 12; ++e)
    for (int k = 0; k < 2; ++k) {
      int home = k ^ eo[e];
      s[kEdgeFacelets[e][k]] = kChars[static_cast<int>(homeColour(kEdgeFacelets[ep[e]][home]))];
    }
  for (int f = 0; f < kFaceCount; ++f) s[f * 9 + 4] = kChars[f];
  return *FaceletCube::fromString(s);
}

std::optional<CubieCube> CubieCube::fromFacelets(const FaceletCube& cube) {
  CubieCube r;
  for (int pos = 0; pos < 8; ++pos) {
    Face c[3];
    for (int k = 0; k < 3; ++k) c[k] = cube.at(kCornerFacelets[pos][k]);
    bool found = false;
    for (int j = 0; j < 8 && !found; ++j)
      for (int k = 0; k < 3 && !found; ++k) {
        bool ok = true;
        for (int m = 0; m < 3; ++m)
          ok = ok && c[(k + m) % 3] == homeColour(kCornerFacelets[j][m]);
        if (ok) { r.cp[pos] = j; r.co[pos] = k; found = true; }
      }
    if (!found) return std::nullopt;
  }
  for (int pos = 0; pos < 12; ++pos) {
    Face c[2] = {cube.at(kEdgeFacelets[pos][0]), cube.at(kEdgeFacelets[pos][1])};
    bool found = false;
    for (int j = 0; j < 12 && !found; ++j)
      for (int k = 0; k < 2 && !found; ++k)
        if (c[k] == homeColour(kEdgeFacelets[j][0]) && c[k ^ 1] == homeColour(kEdgeFacelets[j][1])) {
          r.ep[pos] = j; r.eo[pos] = k; found = true;
        }
    if (!found) return std::nullopt;
  }
  return r;
}

}  // namespace rubiks
