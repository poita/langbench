#include "mdiff/diff.hpp"

#include "mdiff/myers.hpp"

namespace mdiff {

EditScript diff_lines(const Lines& a, const Lines& b) {
  Interner interner;
  const std::vector<LineId> ia = interner.intern_all(a);
  const std::vector<LineId> ib = interner.intern_all(b);
  return myers_diff(ia, ib);
}

}  // namespace mdiff
