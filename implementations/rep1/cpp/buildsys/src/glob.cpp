#include "kiln/glob.hpp"

namespace kiln {

namespace {

// Parses a character class starting just after '[' at position `i` of `comp`.
// On success advances `i` past the closing ']'.
bool parse_class(std::string_view comp, std::size_t& i, bool& negate,
                 std::vector<std::pair<unsigned char, unsigned char>>& ranges) {
  negate = false;
  if (i < comp.size() && comp[i] == '!') {
    negate = true;
    ++i;
  }
  while (true) {
    if (i >= comp.size()) return false;  // unterminated
    if (comp[i] == ']') {
      ++i;
      return !ranges.empty();
    }
    if (i + 2 < comp.size() && comp[i + 1] == '-' && comp[i + 2] != ']') {
      auto lo = static_cast<unsigned char>(comp[i]);
      auto hi = static_cast<unsigned char>(comp[i + 2]);
      if (lo > hi) return false;
      ranges.emplace_back(lo, hi);
      i += 3;
    } else {
      auto c = static_cast<unsigned char>(comp[i]);
      ranges.emplace_back(c, c);
      i += 1;
    }
  }
}

}  // namespace

std::optional<GlobPattern> GlobPattern::compile(std::string_view pattern) {
  if (pattern.empty()) return std::nullopt;
  GlobPattern g;
  std::size_t start = 0;
  while (true) {
    std::size_t end = pattern.find('/', start);
    std::string_view comp = pattern.substr(start, end == std::string_view::npos ? end : end - start);
    if (comp.empty()) return std::nullopt;
    Component c;
    if (comp == "**") {
      c.double_star = true;
    } else {
      std::size_t i = 0;
      while (i < comp.size()) {
        char ch = comp[i];
        Item item;
        if (ch == '*') {
          item.kind = Item::AnyRun;
          ++i;
        } else if (ch == '?') {
          item.kind = Item::AnyOne;
          ++i;
        } else if (ch == '[') {
          item.kind = Item::Class;
          ++i;
          if (!parse_class(comp, i, item.negate, item.ranges)) return std::nullopt;
        } else {
          item.kind = Item::Literal;
          item.ch = ch;
          ++i;
        }
        c.items.push_back(std::move(item));
      }
    }
    g.components_.push_back(std::move(c));
    if (end == std::string_view::npos) break;
    start = end + 1;
  }
  std::size_t w = pattern.find_first_of("*?[");
  std::string prefix(pattern.substr(0, w));
  if (!prefix.empty() && prefix.back() == '/') prefix.pop_back();
  g.prefix_ = std::move(prefix);
  return g;
}

bool GlobPattern::match_component(const std::vector<Item>& items, std::string_view s) {
  auto single = [](const Item& it, char c) {
    switch (it.kind) {
      case Item::Literal: return it.ch == c;
      case Item::AnyOne: return true;
      case Item::Class: {
        bool in = false;
        auto u = static_cast<unsigned char>(c);
        for (const auto& [lo, hi] : it.ranges) {
          if (u >= lo && u <= hi) {
            in = true;
            break;
          }
        }
        return in != it.negate;
      }
      case Item::AnyRun: return false;
    }
    return false;
  };
  // Classic two-pointer wildcard match with backtracking to the last '*'.
  std::size_t p = 0, i = 0, star = std::string::npos, mark = 0;
  while (i < s.size()) {
    if (p < items.size() && items[p].kind == Item::AnyRun) {
      star = p++;
      mark = i;
    } else if (p < items.size() && single(items[p], s[i])) {
      ++p;
      ++i;
    } else if (star != std::string::npos) {
      p = star + 1;
      i = ++mark;
    } else {
      return false;
    }
  }
  while (p < items.size() && items[p].kind == Item::AnyRun) ++p;
  return p == items.size();
}

bool GlobPattern::matches(std::string_view candidate) const {
  std::vector<std::string_view> parts;
  std::size_t start = 0;
  while (true) {
    std::size_t end = candidate.find('/', start);
    parts.push_back(candidate.substr(start, end == std::string_view::npos ? end : end - start));
    if (end == std::string_view::npos) break;
    start = end + 1;
  }
  const std::size_t P = components_.size(), C = parts.size();
  // ok[i][j]: pattern components i.. match candidate components j..
  std::vector<char> ok((P + 1) * (C + 1), 0);
  auto at = [&](std::size_t i, std::size_t j) -> char& { return ok[i * (C + 1) + j]; };
  at(P, C) = 1;
  for (std::size_t i = P; i-- > 0;) {
    for (std::size_t j = C + 1; j-- > 0;) {
      if (components_[i].double_star) {
        at(i, j) = at(i + 1, j) || (j < C && at(i, j + 1));
      } else {
        at(i, j) = j < C && at(i + 1, j + 1) && match_component(components_[i].items, parts[j]);
      }
    }
  }
  return at(0, 0) != 0;
}

}  // namespace kiln
