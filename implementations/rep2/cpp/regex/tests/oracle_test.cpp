// Differential test: the VM is compared against a direct, recursive
// transcription of the matching definition (SPEC section 3) on random small
// patterns and subjects.
#include <gtest/gtest.h>

#include <functional>
#include <optional>
#include <random>
#include <string>
#include <vector>

#include "rx/regex.hpp"

namespace {

using Cont = std::function<bool(int)>;
using Caps = std::vector<std::optional<std::pair<int, int>>>;

struct Oracle {
  const std::string& s;
  Caps caps;

  bool rep(const rx::Node& x, int min, int max, int i, int count, const Cont& k) {
    if (count < min) return m(x, i, [&, count](int j) { return rep(x, min, max, j, count + 1, k); });
    if (count == max) return k(i);
    if (m(x, i, [&, count, i](int j) { return j == i ? k(j) : rep(x, min, max, j, count + 1, k); }))
      return true;
    return k(i);
  }

  bool m(const rx::Node& n, int i, const Cont& k) {
    const int len = static_cast<int>(s.size());
    switch (n.kind) {
      case rx::NodeKind::Empty: return k(i);
      case rx::NodeKind::Literal: return i < len && static_cast<unsigned char>(s[i]) == n.ch && k(i + 1);
      case rx::NodeKind::Any: return i < len && k(i + 1);
      case rx::NodeKind::Set: return i < len && n.set.contains(static_cast<unsigned char>(s[i])) && k(i + 1);
      case rx::NodeKind::Bol: return i == 0 && k(i);
      case rx::NodeKind::Eol: return i == len && k(i);
      case rx::NodeKind::Concat: return seq(n, 0, i, k);
      case rx::NodeKind::Alternate:
        for (auto& c : n.children)
          if (m(*c, i, k)) return true;
        return false;
      case rx::NodeKind::Group:
        return m(*n.children[0], i, [&](int j) {
          auto old = caps[n.group - 1];
          caps[n.group - 1] = std::make_pair(i, j);
          if (k(j)) return true;
          caps[n.group - 1] = old;
          return false;
        });
      case rx::NodeKind::Repeat: return rep(*n.children[0], n.min, n.max, i, 0, k);
    }
    return false;
  }

  bool seq(const rx::Node& n, std::size_t idx, int i, const Cont& k) {
    if (idx == n.children.size()) return k(i);
    return m(*n.children[idx], i, [&, idx](int j) { return seq(n, idx + 1, j, k); });
  }
};

std::string oracle_result(const rx::ParsedPattern& p, const std::string& s) {
  for (int start = 0; start <= static_cast<int>(s.size()); ++start) {
    Oracle o{s, Caps(p.group_count)};
    int end = -1;
    if (o.m(*p.root, start, [&](int j) { end = j; return true; })) {
      std::string r = "match " + std::to_string(start) + " " + std::to_string(end);
      for (auto& c : o.caps)
        r += c ? "|" + std::to_string(c->first) + "," + std::to_string(c->second) : "|-";
      return r;
    }
  }
  return "no";
}

struct Gen {
  std::mt19937 rng;
  int pick(int n) { return static_cast<int>(rng() % static_cast<unsigned>(n)); }

  std::string atom(int depth) {
    static const char* simple[] = {"a", "b", "c", ".", "[ab]", "[^a]", "\\w", "\\d", "^", "$"};
    if (depth > 0 && pick(3) == 0) return "(" + regex(depth - 1) + ")";
    return simple[pick(10)];
  }

  std::string piece(int depth) {
    std::string a = atom(depth);
    if (a == "^" || a == "$") return a;
    static const char* q[] = {"", "", "", "*", "+", "?", "{2}", "{0}", "{1,2}", "{2,}", "{0,3}"};
    return a + q[pick(11)];
  }

  std::string branch(int depth) {
    std::string r;
    for (int n = pick(4); n > 0; --n) r += piece(depth);
    return r;
  }

  std::string regex(int depth) {
    std::string r = branch(depth);
    while (pick(4) == 0) r += "|" + branch(depth);
    return r;
  }

  std::string subject() {
    std::string s;
    for (int n = pick(8); n > 0; --n) s += "abc1"[pick(4)];
    return s;
  }
};

}  // namespace

TEST(Oracle, RandomPatternsAgreeWithDefinition) {
  Gen g{std::mt19937(12345)};
  int matched = 0, total = 0;
  for (int iter = 0; iter < 6000; ++iter) {
    std::string pat = g.regex(iter % 10 == 0 ? 3 : 2);
    rx::ParsedPattern parsed = rx::parse(pat);
    rx::Regex re(pat);
    rx::Matcher matcher(re.program());
    rx::Match m;
    for (int k = 0; k < 6; ++k) {
      std::string subj = g.subject();
      std::string expect = oracle_result(parsed, subj);
      std::string got = "no";
      if (matcher.search(subj, m)) {
        got = "match " + std::to_string(m.begin) + " " + std::to_string(m.end);
        for (auto& sp : m.groups)
          got += sp.matched() ? "|" + std::to_string(sp.begin) + "," + std::to_string(sp.end) : "|-";
      }
      ASSERT_EQ(got, expect) << "pattern: " << pat << " subject: " << subj;
      ++total;
      matched += expect != "no";
    }
  }
  EXPECT_GT(matched, total / 10);  // the generator should produce real matches
}
