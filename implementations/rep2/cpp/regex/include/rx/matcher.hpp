// The backtracking virtual machine.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string_view>
#include <vector>

#include "rx/program.hpp"

namespace rx {

/// Half-open interval [begin, end) of subject offsets.
struct Span {
  static constexpr std::size_t npos = static_cast<std::size_t>(-1);
  std::size_t begin = npos;
  std::size_t end = npos;
  bool matched() const { return begin != npos; }
  bool operator==(const Span& o) const { return begin == o.begin && end == o.end; }
};

/// The first match found in a subject.
struct Match {
  std::size_t begin = 0;
  std::size_t end = 0;
  /// groups[g-1] is capture group g; unmatched groups have matched() == false.
  std::vector<Span> groups;

  /// Capture group `g` (1-based).
  const Span& group(std::size_t g) const { return groups.at(g - 1); }
};

/// Runs a Program against subjects. A Matcher owns the (reusable) scratch
/// memory, so keep one per thread and reuse it across subjects. Backtracking
/// state lives on an explicit heap stack, so subject length is not limited by
/// the call stack.
class Matcher {
 public:
  /// `program` must outlive the Matcher.
  explicit Matcher(const Program& program);

  /// Finds the leftmost match in `subject` (Perl-style: ordered choice,
  /// greedy quantifiers). Returns false if there is none, leaving `out`
  /// unspecified. Subjects must be shorter than 2^31 characters.
  bool search(std::string_view subject, Match& out);

 private:
  struct Entry {
    // tag >= 0: choice point resuming at pc `tag` with position `value`.
    // tag <  0: undo record restoring register ~tag to `value`.
    std::int32_t tag;
    std::int32_t value;
  };

  bool run(const char* s, std::int32_t len, std::int32_t start, std::int32_t& end);

  const Program* prog_;
  std::vector<std::int32_t> regs_;
  std::vector<Entry> stack_;
};

}  // namespace rx
