// Line splitting and interning.
#pragma once

#include <cstdint>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace mdiff {

/// A line of text, without its terminating '\n'. Views point into caller-owned
/// storage, which must outlive them.
using Line = std::string_view;
using Lines = std::vector<Line>;

/// Integer id of an interned line. Equal ids <=> byte-identical lines.
using LineId = std::uint32_t;

/// Splits `text` on '\n'. A final line without a terminator is kept; a
/// trailing '\n' does not produce an extra empty line.
Lines split_lines(std::string_view text);

/// Maps distinct lines to dense integer ids, so that the diff search compares
/// lines in O(1). Interned views must outlive the interner.
class Interner {
public:
  /// Returns the id of `line`, assigning a fresh one on first sight.
  LineId intern(Line line);

  /// Interns every line, returning ids in order.
  std::vector<LineId> intern_all(const Lines& lines);

  /// Number of distinct lines seen so far.
  std::size_t size() const { return ids_.size(); }

private:
  std::unordered_map<Line, LineId> ids_;
};

}  // namespace mdiff
