#include "kiln/glob.hpp"

namespace kiln {

namespace {

// Parses a character class starting just after '['. On success returns the
// index just past the closing ']' and fills `set`.
bool parseClass(std::string_view p, std::size_t i, std::bitset<256>& set,
                std::size_t& next) {
  bool negate = false;
  if (i < p.size() && p[i] == '!') {
    negate = true;
    ++i;
  }
  std::bitset<256> items;
  bool any = false;
  while (true) {
    if (i >= p.size()) return false;
    unsigned char c = static_cast<unsigned char>(p[i]);
    if (c == ']') {
      if (!any) return false;
      ++i;
      break;
    }
    if (i + 2 < p.size() && p[i + 1] == '-' && p[i + 2] != ']') {
      unsigned char hi = static_cast<unsigned char>(p[i + 2]);
      if (c > hi) return false;
      for (unsigned b = c; b <= hi; ++b) items.set(b);
      i += 3;
    } else {
      items.set(c);
      i += 1;
    }
    any = true;
  }
  set = negate ? ~items : items;
  next = i;
  return true;
}

}  // namespace

std::optional<GlobPattern> GlobPattern::compile(std::string_view pattern) {
  if (pattern.empty()) return std::nullopt;
  GlobPattern g;
  std::size_t start = 0;
  while (true) {
    std::size_t end = pattern.find('/', start);
    std::string_view comp = pattern.substr(
        start, end == std::string_view::npos ? pattern.size() - start : end - start);
    if (comp.empty()) return std::nullopt;
    Component c;
    if (comp == "**") {
      c.doubleStar = true;
    } else {
      std::size_t i = 0;
      while (i < comp.size()) {
        Item item;
        char ch = comp[i];
        if (ch == '*') {
          item.kind = Item::Star;
          ++i;
        } else if (ch == '?') {
          item.kind = Item::Any;
          ++i;
        } else if (ch == '[') {
          item.kind = Item::Class;
          std::size_t next = 0;
          if (!parseClass(comp, i + 1, item.set, next)) return std::nullopt;
          i = next;
        } else {
          item.kind = Item::Literal;
          item.ch = ch;
          ++i;
        }
        c.items.push_back(std::move(item));
      }
    }
    g.comps_.push_back(std::move(c));
    if (end == std::string_view::npos) break;
    start = end + 1;
  }

  // Literal prefix: bytes before the first wildcard character.
  std::size_t w = pattern.find_first_of("*?[");
  g.prefix_ = std::string(pattern.substr(0, w == std::string_view::npos ? pattern.size() : w));
  // A trailing `**` component may match zero components, so `src/**` also
  // matches the path `src` itself, which lacks the trailing slash.
  if (pattern.size() >= 3 && pattern.substr(pattern.size() - 3) == "/**" &&
      g.prefix_.size() == pattern.size() - 2) {
    g.prefix_.pop_back();
  }
  return g;
}

bool GlobPattern::matchComponent(const Component& c, std::string_view s) {
  const auto& items = c.items;
  std::size_t pi = 0, si = 0;
  std::size_t starPi = std::string::npos, starSi = 0;
  auto single = [&](const Item& it, char ch) {
    switch (it.kind) {
      case Item::Any: return true;
      case Item::Class: return it.set.test(static_cast<unsigned char>(ch));
      case Item::Literal: return it.ch == ch;
      default: return false;
    }
  };
  while (si < s.size()) {
    if (pi < items.size() && items[pi].kind == Item::Star) {
      starPi = pi++;
      starSi = si;
    } else if (pi < items.size() && single(items[pi], s[si])) {
      ++pi;
      ++si;
    } else if (starPi != std::string::npos) {
      pi = starPi + 1;
      si = ++starSi;
    } else {
      return false;
    }
  }
  while (pi < items.size() && items[pi].kind == Item::Star) ++pi;
  return pi == items.size();
}

bool GlobPattern::matches(std::string_view candidate) const {
  std::vector<std::string_view> parts;
  std::size_t start = 0;
  while (true) {
    std::size_t end = candidate.find('/', start);
    if (end == std::string_view::npos) {
      parts.push_back(candidate.substr(start));
      break;
    }
    parts.push_back(candidate.substr(start, end - start));
    start = end + 1;
  }
  const std::size_t P = comps_.size(), C = parts.size();
  // dp[i][j]: pattern components i.. match candidate components j..
  std::vector<char> dp((P + 1) * (C + 1), 0);
  auto at = [&](std::size_t i, std::size_t j) -> char& { return dp[i * (C + 1) + j]; };
  at(P, C) = 1;
  for (std::size_t i = P; i-- > 0;) {
    for (std::size_t j = C + 1; j-- > 0;) {
      if (comps_[i].doubleStar) {
        at(i, j) = at(i + 1, j) || (j < C && at(i, j + 1));
      } else {
        at(i, j) = j < C && at(i + 1, j + 1) && matchComponent(comps_[i], parts[j]);
      }
    }
  }
  return at(0, 0) != 0;
}

}  // namespace kiln
