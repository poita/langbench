// Shared helpers for tests: an O(NM) LCS oracle and script validation.
#pragma once

#include <string>
#include <vector>

#include "mdiff/lines.hpp"
#include "mdiff/script.hpp"

namespace testutil {

template <class T>
std::size_t lcs_length(const std::vector<T>& a, const std::vector<T>& b) {
  std::vector<std::size_t> prev(b.size() + 1, 0), cur(b.size() + 1, 0);
  for (std::size_t i = 1; i <= a.size(); ++i) {
    for (std::size_t j = 1; j <= b.size(); ++j)
      cur[j] = a[i - 1] == b[j - 1] ? prev[j - 1] + 1 : std::max(prev[j], cur[j - 1]);
    std::swap(prev, cur);
  }
  return prev[b.size()];
}

/// True when the script reproduces exactly a (keeps+deletes) and b (keeps+inserts).
template <class T>
bool script_valid(const mdiff::EditScript& s, const std::vector<T>& a, const std::vector<T>& b) {
  std::size_t ia = 0, ib = 0;
  for (const auto& e : s) {
    using mdiff::EditKind;
    if (e.kind == EditKind::Insert) {
      if (e.index != ib || ib >= b.size()) return false;
      ++ib;
    } else {
      if (e.index != ia || ia >= a.size()) return false;
      if (e.kind == EditKind::Keep) {
        if (ib >= b.size() || !(a[ia] == b[ib])) return false;
        ++ib;
      }
      ++ia;
    }
  }
  return ia == a.size() && ib == b.size();
}

}  // namespace testutil
