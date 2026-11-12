#pragma once
/// \file matcher.hpp
/// The backtracking virtual machine that executes a Program.

#include <cstdint>
#include <optional>
#include <string_view>
#include <vector>

#include "regex/program.hpp"

namespace regex {

/// Half-open range [begin, end) of subject offsets.
struct Span {
  std::size_t begin = 0;
  std::size_t end = 0;
  bool operator==(const Span& o) const { return begin == o.begin && end == o.end; }
};

/// Result of a successful search.
struct Match {
  Span span;  ///< the whole match
  /// groups[g-1] is the span of capture group g, or nullopt if it did not
  /// take part in the match.
  std::vector<std::optional<Span>> groups;
};

/// Executes a Program against subjects. A Matcher owns scratch memory that is
/// reused between calls, so keep one around when matching many subjects. It
/// is not thread-safe; the Program it refers to must outlive it.
class Matcher {
 public:
  explicit Matcher(const Program& program);

  /// Finds the leftmost match (ordered-choice, greedy semantics) in
  /// \p subject. Returns false if there is none; otherwise fills \p out.
  bool search(std::string_view subject, Match& out);

 private:
  struct Frame {
    std::int32_t kind;
    std::int32_t pc;
    std::int32_t a;
    std::int32_t b;
  };
  bool run(const char* s, int n, int start, int& end);

  const Program* prog_;
  std::vector<std::int32_t> regs_;
  std::vector<Frame> stack_;
};

}  // namespace regex
