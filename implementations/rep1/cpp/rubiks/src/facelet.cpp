#include "rubiks/facelet.hpp"

#include <cstdlib>
#include <stdexcept>
#include <vector>

namespace rubiks {

namespace {

constexpr char kFaceChars[] = "URFDLB";

// The clockwise quarter turns, verbatim from SPEC.md: "(a b c d)" moves the
// sticker at a to b, b to c, c to d and d to a.
constexpr const char* kCycles[kFaceCount] = {
    /*U*/ "(U1 U3 U9 U7)(U2 U6 U8 U4)(F1 L1 B1 R1)(F2 L2 B2 R2)(F3 L3 B3 R3)",
    /*R*/ "(R1 R3 R9 R7)(R2 R6 R8 R4)(F3 U3 B7 D3)(F6 U6 B4 D6)(F9 U9 B1 D9)",
    /*F*/ "(F1 F3 F9 F7)(F2 F6 F8 F4)(U7 R1 D3 L9)(U8 R4 D2 L6)(U9 R7 D1 L3)",
    /*D*/ "(D1 D3 D9 D7)(D2 D6 D8 D4)(F7 R7 B7 L7)(F8 R8 B8 L8)(F9 R9 B9 L9)",
    /*L*/ "(L1 L3 L9 L7)(L2 L6 L8 L4)(F1 D1 B9 U1)(F4 D4 B6 U4)(F7 D7 B3 U7)",
    /*B*/ "(B1 B3 B9 B7)(B2 B6 B8 B4)(U3 L1 D7 R9)(U2 L4 D8 R6)(U1 L7 D9 R3)"};

using Perm = std::array<int, kFaceletCount>;

Perm quarterTurn(int face) {
  Perm src;
  for (int i = 0; i < kFaceletCount; ++i) src[i] = i;
  const char* p = kCycles[face];
  while (*p) {
    if (*p++ != '(') throw std::logic_error("bad cycle table");
    std::vector<int> cyc;
    while (*p != ')') {
      if (*p == ' ') { ++p; continue; }
      cyc.push_back(*faceletIndex(std::string_view(p, 2)));
      p += 2;
    }
    ++p;
    for (std::size_t k = 0; k < cyc.size(); ++k) src[cyc[(k + 1) % cyc.size()]] = cyc[k];
  }
  return src;
}

// Result of applying `a` and then `b`: sticker at position i comes from
// a-source of b-source.
Perm then(const Perm& a, const Perm& b) {
  Perm r;
  for (int i = 0; i < kFaceletCount; ++i) r[i] = a[b[i]];
  return r;
}

const std::array<Perm, kMoveCount>& allMoves() {
  static const std::array<Perm, kMoveCount> table = [] {
    std::array<Perm, kMoveCount> t;
    for (int f = 0; f < kFaceCount; ++f) {
      Perm q = quarterTurn(f);
      Perm q2 = then(q, q);
      Perm q3 = then(q2, q);
      t[f * 3] = q;
      t[f * 3 + 1] = q2;
      t[f * 3 + 2] = q3;
    }
    return t;
  }();
  return table;
}

}  // namespace

std::string faceletName(int index) {
  std::string s;
  s += kFaceChars[index / 9];
  s += static_cast<char>('1' + index % 9);
  return s;
}

std::optional<int> faceletIndex(std::string_view name) {
  if (name.size() != 2 || name[1] < '1' || name[1] > '9') return std::nullopt;
  for (int f = 0; f < kFaceCount; ++f)
    if (kFaceChars[f] == name[0]) return f * 9 + (name[1] - '1');
  return std::nullopt;
}

const std::array<int, kFaceletCount>& faceletSource(Move move) { return allMoves()[move.index()]; }

FaceletCube::FaceletCube() {
  for (int i = 0; i < kFaceletCount; ++i) stickers_[i] = static_cast<Face>(i / 9);
}

std::optional<FaceletCube> FaceletCube::fromString(std::string_view s) {
  if (s.size() != kFaceletCount) return std::nullopt;
  FaceletCube c;
  for (int i = 0; i < kFaceletCount; ++i) {
    int f = -1;
    for (int k = 0; k < kFaceCount; ++k)
      if (kFaceChars[k] == s[i]) f = k;
    if (f < 0) return std::nullopt;
    c.stickers_[i] = static_cast<Face>(f);
  }
  return c;
}

void FaceletCube::apply(Move move) {
  const auto& src = faceletSource(move);
  std::array<Face, kFaceletCount> old = stickers_;
  for (int i = 0; i < kFaceletCount; ++i) stickers_[i] = old[src[i]];
}

void FaceletCube::apply(std::span<const Move> moves) {
  for (Move m : moves) apply(m);
}

bool FaceletCube::isSolved() const {
  for (int i = 0; i < kFaceletCount; ++i)
    if (stickers_[i] != static_cast<Face>(i / 9)) return false;
  return true;
}

std::string FaceletCube::toString() const {
  std::string s;
  for (Face f : stickers_) s += kFaceChars[static_cast<int>(f)];
  return s;
}

}  // namespace rubiks
