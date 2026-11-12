#include "fulltext/snippet.hpp"

#include <algorithm>

#include "fulltext/utf8.hpp"

namespace fulltext {

std::size_t best_window_start(std::size_t doc_len, std::span<const AtomOccurrences> atoms,
                              std::size_t window) {
  if (doc_len <= window) return 0;
  const std::int64_t max_start = static_cast<std::int64_t>(doc_len - window);
  const std::int64_t w = static_cast<std::int64_t>(window);

  // Difference arrays over window starts 0..max_start.
  std::vector<std::int32_t> distinct(static_cast<std::size_t>(max_start) + 2, 0);
  std::vector<std::int32_t> total(static_cast<std::size_t>(max_start) + 2, 0);

  for (const AtomOccurrences& atom : atoms) {
    const std::int64_t n = static_cast<std::int64_t>(atom.length);
    if (n > w) continue;  // never fits inside a window
    std::int64_t covered = -1;  // largest start already counted for this atom
    for (const std::uint32_t p : atom.starts) {
      // The occurrence is inside window s iff s <= p and p + n <= s + W.
      const std::int64_t lo = std::max<std::int64_t>(0, static_cast<std::int64_t>(p) + n - w);
      const std::int64_t hi = std::min<std::int64_t>(static_cast<std::int64_t>(p), max_start);
      if (lo > hi) continue;
      ++total[lo];
      --total[hi + 1];
      const std::int64_t from = std::max(lo, covered + 1);
      if (from <= hi) {
        ++distinct[from];
        --distinct[hi + 1];
      }
      covered = std::max(covered, hi);
    }
  }

  std::size_t best = 0;
  std::int64_t best_distinct = -1, best_total = -1, cur_distinct = 0, cur_total = 0;
  for (std::int64_t s = 0; s <= max_start; ++s) {
    cur_distinct += distinct[static_cast<std::size_t>(s)];
    cur_total += total[static_cast<std::size_t>(s)];
    if (cur_distinct > best_distinct || (cur_distinct == best_distinct && cur_total > best_total)) {
      best_distinct = cur_distinct;
      best_total = cur_total;
      best = static_cast<std::size_t>(s);
    }
  }
  return best;
}

std::string render_snippet(std::string_view text, std::span<const Span> tokens, std::size_t start,
                           std::size_t window) {
  if (tokens.empty()) return {};
  const std::size_t last = std::min(start + window, tokens.size()) - 1;
  const std::string_view raw = text.substr(tokens[start].begin, tokens[last].end - tokens[start].begin);

  std::string out;
  out.reserve(raw.size());
  for (std::size_t i = 0; i < raw.size();) {
    if (utf8::whitespace_length_at(raw, i) != 0) {
      while (i < raw.size()) {
        const unsigned m = utf8::whitespace_length_at(raw, i);
        if (m == 0) break;
        i += m;
      }
      out.push_back(' ');
    } else {
      out.push_back(raw[i++]);
    }
  }
  return out;
}

}  // namespace fulltext
