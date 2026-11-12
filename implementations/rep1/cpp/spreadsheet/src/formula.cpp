#include "spreadsheet/formula.h"

#include <algorithm>

namespace spreadsheet {
namespace {

void collect(const Expr& e, std::vector<CellRef>& out) {
  switch (e.kind) {
    case Expr::Kind::Ref:
      out.push_back(e.ref);
      break;
    case Expr::Kind::Range:
      for (std::uint16_t r = e.range.first.row; r <= e.range.last.row; ++r)
        for (std::uint16_t c = e.range.first.col; c <= e.range.last.col; ++c)
          out.push_back(CellRef{c, r});
      break;
    default:
      for (const auto& a : e.args) collect(*a, out);
  }
}

}  // namespace

std::vector<CellRef> Formula::dependencies() const {
  std::vector<CellRef> out;
  if (invalid_ref_) return out;
  collect(*root_, out);
  std::sort(out.begin(), out.end());
  out.erase(std::unique(out.begin(), out.end()), out.end());
  return out;
}

}  // namespace spreadsheet
