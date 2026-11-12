#include "coordinates.hpp"

#include <algorithm>
#include <bit>
#include <numeric>
#include <stdexcept>

namespace rubiks::detail {

namespace {

constexpr std::uint16_t kInvalid = 0xFFFF;

// Slice membership of edge cubies (edge numbering as in cubie.hpp).
constexpr std::array<std::array<int, 4>, 3> kSlices = {{
    {1, 3, 5, 7},    // M: UF UB DF DB
    {0, 2, 4, 6},    // S: UR UL DR DL
    {8, 9, 10, 11},  // E: FR FL BL BR
}};

constexpr std::array<std::array<int, 4>, 3> kSlicePositions = kSlices;  // slices map to themselves

bool inPhase3(Move m) {
  return m.face() == Face::U || m.face() == Face::D || m.isHalfTurn();
}
// Rank of a permutation of n <= 8 values (Lehmer code, lexicographic order).
template <typename A>
std::size_t lehmer(const A& p, std::size_t n) {
  std::size_t r = 0;
  for (std::size_t i = 0; i < n; ++i) {
    std::size_t smaller = 0;
    for (std::size_t j = i + 1; j < n; ++j) smaller += p[j] < p[i];
    r = r * (n - i) + smaller;
  }
  return r;
}

CubieCube identity() { return CubieCube{}; }

}  // namespace

const Coordinates& Coordinates::instance() {
  static const Coordinates c;
  return c;
}

std::size_t Coordinates::cornerRank(const CubieCube& c) const { return lehmer(c.cp, 8); }

// ---- extraction -----------------------------------------------------------

std::size_t Coordinates::edgeOri(const CubieCube& c) const {
  std::size_t v = 0;
  for (int i = 0; i < 11; ++i) v |= static_cast<std::size_t>(c.eo[i]) << i;
  return v;
}

std::size_t Coordinates::cornerOri(const CubieCube& c) const {
  std::size_t v = 0;
  for (int i = 0; i < 7; ++i) v = v * 3 + c.co[i];
  return v;
}

std::size_t Coordinates::eSlice(const CubieCube& c) const {
  unsigned mask = 0;
  for (int p = 0; p < 12; ++p)
    if (c.ep[p] >= 8) mask |= 1u << p;
  return mask12ToIndex_[mask];
}

std::size_t Coordinates::cornerClass(const CubieCube& c) const { return classOfPerm_[cornerRank(c)]; }

std::size_t Coordinates::mSlice(const CubieCube& c) const {
  unsigned mask = 0;
  for (int p = 0; p < 8; ++p)
    if (c.ep[p] & 1) mask |= 1u << p;  // cubies 1,3,5,7 are the M-slice edges
  return mask8ToIndex_[mask];
}

std::size_t Coordinates::cornerPerm(const CubieCube& c) const {
  int g = groupIndexOfPerm_[cornerRank(c)];
  if (g < 0) throw std::logic_error("corner permutation outside the half-turn group");
  return static_cast<std::size_t>(g);
}

std::size_t Coordinates::slicePerm(const CubieCube& c, int slice) const {
  const auto& pos = kSlicePositions[slice];
  std::array<int, 4> local;
  for (int i = 0; i < 4; ++i) {
    int cubie = c.ep[pos[i]];
    auto it = std::find(kSlices[slice].begin(), kSlices[slice].end(), cubie);
    if (it == kSlices[slice].end()) throw std::logic_error("edge outside its slice");
    local[i] = static_cast<int>(it - kSlices[slice].begin());
  }
  return lehmer(local, 4);
}

// ---- construction ---------------------------------------------------------

Coordinates::Coordinates() {
  // Subset indices.
  mask12ToIndex_.fill(kInvalid);
  for (unsigned m = 0; m < 4096; ++m)
    if (std::popcount(m) == 4) {
      mask12ToIndex_[m] = static_cast<std::uint16_t>(indexToMask12_.size());
      indexToMask12_.push_back(static_cast<std::uint16_t>(m));
    }
  mask8ToIndex_.fill(kInvalid);
  for (unsigned m = 0; m < 256; ++m)
    if (std::popcount(m) == 4) {
      mask8ToIndex_[m] = static_cast<std::uint16_t>(indexToMask8_.size());
      indexToMask8_.push_back(static_cast<std::uint16_t>(m));
    }

  // Phase 1: edge orientation.
  edgeOriMove_.assign(kEdgeOriCount * kMoveCount, kInvalid);
  for (std::size_t i = 0; i < kEdgeOriCount; ++i) {
    CubieCube c = identity();
    int parity = 0;
    for (int e = 0; e < 11; ++e) {
      c.eo[e] = (i >> e) & 1;
      parity ^= c.eo[e];
    }
    c.eo[11] = static_cast<std::uint8_t>(parity);
    for (int m = 0; m < kMoveCount; ++m) {
      CubieCube d = c;
      d.apply(Move::fromIndex(m));
      edgeOriMove_[i * kMoveCount + m] = static_cast<std::uint16_t>(edgeOri(d));
    }
  }

  // Phase 2: corner orientation and E-slice positions.
  cornerOriMove_.assign(kCornerOriCount * kMoveCount, kInvalid);
  for (std::size_t i = 0; i < kCornerOriCount; ++i) {
    CubieCube c = identity();
    std::size_t v = i;
    int sum = 0;
    for (int k = 6; k >= 0; --k) {
      c.co[k] = v % 3;
      v /= 3;
      sum += c.co[k];
    }
    c.co[7] = static_cast<std::uint8_t>((3 - sum % 3) % 3);
    for (int m = 0; m < kMoveCount; ++m) {
      CubieCube d = c;
      d.apply(Move::fromIndex(m));
      cornerOriMove_[i * kMoveCount + m] = static_cast<std::uint16_t>(cornerOri(d));
    }
  }
  eSliceMove_.assign(kESliceCount * kMoveCount, kInvalid);
  for (std::size_t i = 0; i < kESliceCount; ++i) {
    CubieCube c = identity();
    unsigned mask = indexToMask12_[i];
    int slice = 8, other = 0;
    for (int p = 0; p < 12; ++p) c.ep[p] = (mask >> p & 1) ? slice++ : other++;
    for (int m = 0; m < kMoveCount; ++m) {
      CubieCube d = c;
      d.apply(Move::fromIndex(m));
      eSliceMove_[i * kMoveCount + m] = static_cast<std::uint16_t>(eSlice(d));
    }
  }
  eSliceSolved_ = eSlice(identity());

  // Corner permutations: the half-turn group (96 elements) and the 420
  // cosets G*p it induces (all 8! permutations enumerated in Lehmer order).
  std::vector<std::array<std::uint8_t, 8>> perms;
  {
    std::array<std::uint8_t, 8> p{0, 1, 2, 3, 4, 5, 6, 7};
    do perms.push_back(p); while (std::next_permutation(p.begin(), p.end()));
  }
  auto rankOf = [](const std::array<std::uint8_t, 8>& p) { return lehmer(p, 8); };
  auto cornerMove = [](const std::array<std::uint8_t, 8>& p, Move m) {
    CubieCube c;
    c.cp = p;
    c.apply(m);
    return c.cp;
  };

  groupIndexOfPerm_.assign(perms.size(), -1);
  std::vector<std::array<std::uint8_t, 8>> group;
  group.push_back(perms[0]);
  groupIndexOfPerm_[0] = 0;
  for (std::size_t head = 0; head < group.size(); ++head)
    for (int f = 0; f < kFaceCount; ++f) {
      auto q = cornerMove(group[head], Move(static_cast<Face>(f), 2));
      std::size_t r = rankOf(q);
      if (groupIndexOfPerm_[r] < 0) {
        groupIndexOfPerm_[r] = static_cast<std::int16_t>(group.size());
        group.push_back(q);
      }
    }
  if (group.size() != kCornerPermCount) throw std::logic_error("half-turn corner group size != 96");

  classOfPerm_.assign(perms.size(), -1);
  std::vector<std::array<std::uint8_t, 8>> classRep;
  for (const auto& p : perms) {
    if (classOfPerm_[rankOf(p)] >= 0) continue;
    auto id = static_cast<std::int16_t>(classRep.size());
    classRep.push_back(p);
    for (const auto& g : group) {  // right coset G*p = { g o p }
      std::array<std::uint8_t, 8> q;
      for (int i = 0; i < 8; ++i) q[i] = g[p[i]];
      classOfPerm_[rankOf(q)] = id;
    }
  }
  if (classRep.size() != kCornerClassCount) throw std::logic_error("corner class count != 420");

  // Phase 3: corner classes (defined for every move) and M-slice positions.
  cornerClassMove_.assign(kCornerClassCount * kMoveCount, kInvalid);
  for (std::size_t i = 0; i < kCornerClassCount; ++i)
    for (int m = 0; m < kMoveCount; ++m)
      cornerClassMove_[i * kMoveCount + m] =
          static_cast<std::uint16_t>(classOfPerm_[rankOf(cornerMove(classRep[i], Move::fromIndex(m)))]);
  cornerClassSolved_ = static_cast<std::size_t>(classOfPerm_[0]);

  mSliceMove_.assign(kMSliceCount * kMoveCount, kInvalid);
  for (std::size_t i = 0; i < kMSliceCount; ++i) {
    CubieCube c = identity();
    unsigned mask = indexToMask8_[i];
    int mi = 0, si = 0;
    for (int p = 0; p < 8; ++p) c.ep[p] = (mask >> p & 1) ? kSlices[0][mi++] : kSlices[1][si++];
    for (int m = 0; m < kMoveCount; ++m) {
      Move mv = Move::fromIndex(m);
      if (!inPhase3(mv)) continue;
      CubieCube d = c;
      d.apply(mv);
      mSliceMove_[i * kMoveCount + m] = static_cast<std::uint16_t>(mSlice(d));
    }
  }
  mSliceSolved_ = mSlice(identity());

  // Phase 4: corner permutation within the group, and slice permutations.
  cornerPermMove_.assign(kCornerPermCount * kMoveCount, kInvalid);
  for (std::size_t i = 0; i < kCornerPermCount; ++i)
    for (int m = 0; m < kMoveCount; ++m) {
      if (!Move::fromIndex(m).isHalfTurn()) continue;
      int g = groupIndexOfPerm_[rankOf(cornerMove(group[i], Move::fromIndex(m)))];
      cornerPermMove_[i * kMoveCount + m] = static_cast<std::uint16_t>(g);
    }
  cornerPermSolved_ = 0;

  // A slice permutation coordinate is shared by the three slices only if the
  // moves act identically on each; they don't (U2 touches M and S, not E), so
  // the table is indexed [(slice * 24 + perm) * 18 + move].
  slicePermMove_.assign(3 * kSlicePermCount * kMoveCount, kInvalid);
  for (int s = 0; s < 3; ++s) {
    std::array<int, 4> local{0, 1, 2, 3};
    std::size_t idx = 0;
    do {
      CubieCube c = identity();
      for (int i = 0; i < 4; ++i) c.ep[kSlicePositions[s][i]] = static_cast<std::uint8_t>(kSlices[s][local[i]]);
      for (int m = 0; m < kMoveCount; ++m) {
        if (!Move::fromIndex(m).isHalfTurn()) continue;
        CubieCube d = c;
        d.apply(Move::fromIndex(m));
        slicePermMove_[(s * kSlicePermCount + idx) * kMoveCount + m] = static_cast<std::uint16_t>(slicePerm(d, s));
      }
      ++idx;
    } while (std::next_permutation(local.begin(), local.end()));
  }
}

}  // namespace rubiks::detail
