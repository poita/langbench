// Differential test: the compiled backtracking VM must agree with a direct,
// recursive transcription of the matching definition (SPEC section 3) on
// randomly generated patterns and subjects.
#include <gtest/gtest.h>

#include <functional>
#include <optional>
#include <random>
#include <string>
#include <vector>

#include "regex/parser.hpp"
#include "regex/regex.hpp"

using namespace regex;

namespace {

using Caps = std::vector<std::optional<Span>>;
using Cont = std::function<bool(int)>;

struct Reference {
  const std::string& s;
  Caps caps;
  int len;

  Reference(const std::string& subject, int groups)
      : s(subject), caps(groups), len(static_cast<int>(subject.size())) {}

  bool m(const Node& n, int i, const Cont& k) {
    switch (n.kind) {
      case NodeKind::Literal:
        return i < len && static_cast<unsigned char>(s[i]) == n.ch && k(i + 1);
      case NodeKind::Set:
        return i < len && n.set.contains(static_cast<unsigned char>(s[i])) && k(i + 1);
      case NodeKind::AssertBegin: return i == 0 && k(i);
      case NodeKind::AssertEnd: return i == len && k(i);
      case NodeKind::Concat: return seq(n, 0, i, k);
      case NodeKind::Alternate:
        for (const auto& c : n.children)
          if (m(*c, i, k)) return true;
        return false;
      case NodeKind::Group:
        return m(*n.children[0], i, [&](int j) {
          auto old = caps[n.group - 1];
          caps[n.group - 1] = Span{static_cast<size_t>(i), static_cast<size_t>(j)};
          if (k(j)) return true;
          caps[n.group - 1] = old;
          return false;
        });
      case NodeKind::Repeat: return rep(n, i, 0, k);
    }
    return false;
  }

  bool seq(const Node& n, size_t idx, int i, const Cont& k) {
    if (idx == n.children.size()) return k(i);
    return m(*n.children[idx], i, [&](int j) { return seq(n, idx + 1, j, k); });
  }

  bool rep(const Node& n, int i, int count, const Cont& k) {
    const Node& x = *n.children[0];
    if (count < n.min) return m(x, i, [&](int j) { return rep(n, j, count + 1, k); });
    if (count == n.max) return k(i);
    if (m(x, i, [&](int j) { return j == i ? k(j) : rep(n, j, count + 1, k); })) return true;
    return k(i);
  }
};

std::optional<Match> reference_search(const ParseResult& pr, const std::string& s) {
  for (int start = 0; start <= static_cast<int>(s.size()); ++start) {
    Reference ref(s, pr.group_count);
    int end = -1;
    if (ref.m(*pr.root, start, [&](int j) { end = j; return true; }))
      return Match{{static_cast<size_t>(start), static_cast<size_t>(end)}, ref.caps};
  }
  return std::nullopt;
}

// Random pattern generator over the alphabet {a, b, c}.
struct Gen {
  std::mt19937 rng;
  explicit Gen(unsigned seed) : rng(seed) {}
  int pick(int n) { return static_cast<int>(rng() % n); }

  std::string regex(int depth) {
    std::string out = branch(depth);
    while (pick(5) == 0) out += "|" + branch(depth);
    return out;
  }
  std::string branch(int depth) {
    std::string out;
    int n = pick(4);
    for (int i = 0; i < n; ++i) out += piece(depth);
    return out;
  }
  std::string piece(int depth) {
    int r = pick(14);
    if (r == 0) return "^";
    if (r == 1) return "$";
    std::string atom;
    switch (pick(8)) {
      case 0: atom = "."; break;
      case 1: atom = "[ab]"; break;
      case 2: atom = "[^a]"; break;
      case 3: atom = "\\w"; break;
      case 4: case 5:
        atom = depth > 0 ? "(" + regex(depth - 1) + ")" : "a";
        break;
      default: atom = std::string(1, static_cast<char>('a' + pick(3)));
    }
    static const char* quants[] = {"", "", "", "*", "+", "?", "{2}", "{0}", "{1,2}", "{2,}", "{0,2}"};
    return atom + quants[pick(11)];
  }
  std::string subject() {
    std::string s;
    int n = pick(7);
    for (int i = 0; i < n; ++i) s += static_cast<char>('a' + pick(3));
    return s;
  }
};

std::string show(const std::optional<Match>& m) {
  if (!m) return "no";
  std::string out = std::to_string(m->span.begin) + "-" + std::to_string(m->span.end);
  for (auto& g : m->groups)
    out += g ? "|" + std::to_string(g->begin) + "," + std::to_string(g->end) : "|-";
  return out;
}

}  // namespace

TEST(Reference, RandomPatternsAgreeWithDefinition) {
  Gen gen(12345);
  int matched = 0, total = 0;
  for (int t = 0; t < 3000; ++t) {
    std::string pattern = gen.regex(2);
    ParseResult pr = parse(pattern);
    Regex re(pattern);
    for (int k = 0; k < 8; ++k) {
      std::string subject = gen.subject();
      auto expected = reference_search(pr, subject);
      auto actual = re.search(subject);
      ASSERT_EQ(show(actual), show(expected)) << "pattern='" << pattern << "' subject='" << subject << "'";
      ++total;
      matched += expected.has_value();
    }
  }
  // Make sure the generator exercises both outcomes.
  EXPECT_GT(matched, total / 10);
  EXPECT_LT(matched, total - total / 10);
}
