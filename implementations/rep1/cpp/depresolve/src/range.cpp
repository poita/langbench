#include "depresolve/range.hpp"

#include <algorithm>

namespace depresolve {

namespace {

constexpr Version kUnbounded{0xFFFFFFFFu, 0, 0};

Version successor(const Version& v) { return Version{v.major, v.minor, v.patch + 1}; }

}  // namespace

Range Range::any() { return Range(Version{}, kUnbounded); }

Range Range::exact(const Version& v) { return Range(v, successor(v)); }

Range Range::caret(const Version& v) {
  if (v.major > 0) return Range(v, Version{v.major + 1, 0, 0});
  if (v.minor > 0) return Range(v, Version{0, v.minor + 1, 0});
  return exact(v);
}

Range Range::tilde(const Version& v) { return Range(v, Version{v.major, v.minor + 1, 0}); }

Range Range::between(const Version& lo, const Version& hi) { return Range(lo, hi); }

std::optional<Range> Range::parse(std::string_view text) {
  if (text.empty()) return std::nullopt;
  if (text == "*") return any();
  if (text[0] == '^' || text[0] == '~') {
    auto v = Version::parse(text.substr(1));
    if (!v) return std::nullopt;
    return text[0] == '^' ? caret(*v) : tilde(*v);
  }
  if (text[0] >= '0' && text[0] <= '9') {
    auto v = Version::parse(text);
    if (!v) return std::nullopt;
    return exact(*v);
  }

  // One or more space-separated comparators; the range is their intersection.
  Version lo{};
  Version hi = kUnbounded;
  while (true) {
    std::size_t end = text.find(' ');
    std::string_view comp = text.substr(0, end);
    bool strict_or_eq = false;  // second char is '='
    if (comp.size() < 2 || (comp[0] != '<' && comp[0] != '>')) return std::nullopt;
    std::size_t op_len = 1;
    if (comp[1] == '=') {
      strict_or_eq = true;
      op_len = 2;
    }
    auto v = Version::parse(comp.substr(op_len));
    if (!v) return std::nullopt;
    if (comp[0] == '<') {
      hi = std::min(hi, strict_or_eq ? successor(*v) : *v);
    } else {
      lo = std::max(lo, strict_or_eq ? *v : successor(*v));
    }
    if (end == std::string_view::npos) break;
    text.remove_prefix(end + 1);
  }
  return Range(lo, hi);
}

}  // namespace depresolve
