#include "mdiff/myers.hpp"

#include <cstdint>

namespace mdiff {
namespace {

using Ptr = const LineId*;

class Solver {
public:
  Solver(Ptr a, std::size_t n, Ptr b, std::size_t m) : a_(a), b_(b) {
    // Diagonals k = x - y of any subproblem lie in [-(n+m), n+m].
    off_ = static_cast<std::int64_t>(n + m) + 2;
    vf_.assign(2 * static_cast<std::size_t>(off_) + 1, 0);
    vb_.assign(2 * static_cast<std::size_t>(off_) + 1, 0);
    out_.reserve(n + m);
  }

  EditScript run(std::size_t n, std::size_t m) {
    solve(0, n, 0, m);
    return std::move(out_);
  }

private:
  struct Snake {
    std::size_t x0, y0, x1, y1;  // from (x0,y0) to (x1,y1), relative to the subproblem
  };

  // Solves a[alo,ahi) vs b[blo,bhi), appending edits in order.
  void solve(std::size_t alo, std::size_t ahi, std::size_t blo, std::size_t bhi) {
    while (alo < ahi && blo < bhi && a_[alo] == b_[blo]) {
      out_.push_back({EditKind::Keep, alo});
      ++alo; ++blo;
    }
    std::size_t suffix = 0;
    while (alo < ahi && blo < bhi && a_[ahi - 1] == b_[bhi - 1]) {
      --ahi; --bhi; ++suffix;
    }

    if (alo == ahi) {
      for (std::size_t j = blo; j < bhi; ++j) out_.push_back({EditKind::Insert, j});
    } else if (blo == bhi) {
      for (std::size_t i = alo; i < ahi; ++i) out_.push_back({EditKind::Delete, i});
    } else {
      Snake s = middle_snake(alo, ahi - alo, blo, bhi - blo);
      solve(alo, alo + s.x0, blo, blo + s.y0);
      for (std::size_t i = s.x0; i < s.x1; ++i) out_.push_back({EditKind::Keep, alo + i});
      solve(alo + s.x1, ahi, blo + s.y1, bhi);
    }

    for (std::size_t i = 0; i < suffix; ++i) out_.push_back({EditKind::Keep, ahi + i});
  }

  // Finds the middle snake of a[alo, alo+n) vs b[blo, blo+m); n, m > 0 and the
  // ends differ, so the edit distance is at least 2 and both halves are
  // strictly cheaper than the whole.
  Snake middle_snake(std::size_t alo, std::size_t n_, std::size_t blo, std::size_t m_) {
    const std::int64_t n = static_cast<std::int64_t>(n_);
    const std::int64_t m = static_cast<std::int64_t>(m_);
    const std::int64_t delta = n - m;
    const bool odd = (delta & 1) != 0;
    const std::int64_t max_d = (n + m + 1) / 2;
    const Ptr a = a_ + alo;
    const Ptr b = b_ + blo;
    std::int64_t* vf = vf_.data() + off_;
    std::int64_t* vb = vb_.data() + off_;
    vf[1] = 0;
    vb[1] = 0;

    for (std::int64_t d = 0; d <= max_d; ++d) {
      // Forward search over diagonals -d..d.
      for (std::int64_t k = -d; k <= d; k += 2) {
        std::int64_t x = (k == -d || (k != d && vf[k - 1] < vf[k + 1])) ? vf[k + 1] : vf[k - 1] + 1;
        std::int64_t y = x - k;
        const std::int64_t x0 = x, y0 = y;
        while (x < n && y < m && a[x] == b[y]) { ++x; ++y; }
        vf[k] = x;
        if (odd && k >= delta - (d - 1) && k <= delta + (d - 1) && x + vb[delta - k] >= n)
          return {size_t_(x0), size_t_(y0), size_t_(x), size_t_(y)};
      }
      // Backward search (on the reversed sequences) over diagonals -d..d.
      for (std::int64_t k = -d; k <= d; k += 2) {
        std::int64_t x = (k == -d || (k != d && vb[k - 1] < vb[k + 1])) ? vb[k + 1] : vb[k - 1] + 1;
        std::int64_t y = x - k;
        const std::int64_t x0 = x, y0 = y;
        while (x < n && y < m && a[n - 1 - x] == b[m - 1 - y]) { ++x; ++y; }
        vb[k] = x;
        if (!odd && k >= delta - d && k <= delta + d && x + vf[delta - k] >= n)
          return {size_t_(n - x), size_t_(m - y), size_t_(n - x0), size_t_(m - y0)};
      }
    }
    // Unreachable: the searches always meet by d = ceil((n+m)/2).
    return {0, 0, 0, 0};
  }

  static std::size_t size_t_(std::int64_t v) { return static_cast<std::size_t>(v); }

  Ptr a_, b_;
  std::int64_t off_;
  std::vector<std::int64_t> vf_, vb_;
  EditScript out_;
};

}  // namespace

EditScript myers_diff(const std::vector<LineId>& a, const std::vector<LineId>& b) {
  Solver solver(a.data(), a.size(), b.data(), b.size());
  return solver.run(a.size(), b.size());
}

}  // namespace mdiff
