#include "depresolve/range.hpp"

#include <algorithm>

namespace depresolve {

Range Range::caret(Version v) {
  if (v.major > 0) return Range(v, Version{v.major + 1, 0, 0});
  if (v.minor > 0) return Range(v, Version{0, v.minor + 1, 0});
  return Range(v, Version{0, 0, v.patch + 1});
}

Range Range::tilde(Version v) { return Range(v, Version{v.major, v.minor + 1, 0}); }

Range Range::intersect(const Range& other) const noexcept {
  return Range(std::max(lower_, other.lower_), std::min(upper_, other.upper_));
}

namespace {

// Parses one comparator such as ">=1.2.3".
std::optional<Range> parse_comparator(std::string_view text) {
  if (text.empty()) return std::nullopt;
  const char first = text[0];
  if (first != '<' && first != '>') return std::nullopt;
  const bool or_equal = text.size() > 1 && text[1] == '=';
  const auto version = Version::parse(text.substr(or_equal ? 2 : 1));
  if (!version) return std::nullopt;
  if (first == '<') return or_equal ? Range::at_most(*version) : Range::less_than(*version);
  return or_equal ? Range::at_least(*version) : Range::greater_than(*version);
}

}  // namespace

std::optional<Range> Range::parse(std::string_view text) {
  if (text == "*") return Range::any();
  if (text.empty()) return std::nullopt;

  if (text[0] == '^' || text[0] == '~') {
    const auto version = Version::parse(text.substr(1));
    if (!version) return std::nullopt;
    return text[0] == '^' ? caret(*version) : tilde(*version);
  }

  if (text[0] != '<' && text[0] != '>') {
    const auto version = Version::parse(text);
    if (!version) return std::nullopt;
    return exact(*version);
  }

  // One or more comparators separated by single spaces; all must hold.
  Range result;
  std::size_t pos = 0;
  while (true) {
    const std::size_t space = text.find(' ', pos);
    const auto token = text.substr(pos, space == std::string_view::npos ? space : space - pos);
    const auto comparator = parse_comparator(token);
    if (!comparator) return std::nullopt;
    result = result.intersect(*comparator);
    if (space == std::string_view::npos) break;
    pos = space + 1;
  }
  return result;
}

}  // namespace depresolve
