#include "regex/parser.hpp"

#include <string>

namespace regex {
namespace {

bool is_alnum(char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

bool is_printable(char c) { return c >= 0x20 && c <= 0x7e; }

class Parser {
 public:
  explicit Parser(std::string_view p) : p_(p) {}

  ParseResult run() {
    NodePtr root = parse_regex();
    if (pos_ < p_.size()) fail("unmatched ')'");
    return {std::move(root), groups_};
  }

 private:
  [[noreturn]] void fail(const std::string& msg) const { throw ParseError(msg, pos_); }

  bool at_end() const { return pos_ >= p_.size(); }
  char peek() const { return p_[pos_]; }

  NodePtr parse_regex() {
    std::vector<NodePtr> branches;
    branches.push_back(parse_branch());
    while (!at_end() && peek() == '|') {
      ++pos_;
      branches.push_back(parse_branch());
    }
    if (branches.size() == 1) return std::move(branches[0]);
    auto alt = std::make_unique<Node>(NodeKind::Alternate);
    alt->children = std::move(branches);
    return alt;
  }

  NodePtr parse_branch() {
    auto seq = std::make_unique<Node>(NodeKind::Concat);
    while (!at_end() && peek() != '|' && peek() != ')') seq->children.push_back(parse_piece());
    return seq;
  }

  NodePtr parse_piece() {
    char c = peek();
    NodePtr atom;
    bool quantifiable = true;
    switch (c) {
      case '*': case '+': case '?': case '{':
        fail("quantifier with nothing to repeat");
      case '}': fail("unexpected '}'");
      case ']': fail("unexpected ']'");
      case '(': atom = parse_group(); break;
      case '[': atom = parse_class(); break;
      case '\\': atom = parse_escape(); break;
      case '.': {
        ++pos_;
        atom = std::make_unique<Node>(NodeKind::Set);
        atom->set = CharSet::all();
        break;
      }
      case '^': ++pos_; atom = std::make_unique<Node>(NodeKind::AssertBegin); quantifiable = false; break;
      case '$': ++pos_; atom = std::make_unique<Node>(NodeKind::AssertEnd); quantifiable = false; break;
      default:
        if (!is_printable(c)) fail("non-printable character in pattern");
        ++pos_;
        atom = std::make_unique<Node>(NodeKind::Literal);
        atom->ch = static_cast<unsigned char>(c);
    }
    if (at_end()) return atom;
    c = peek();
    if (c != '*' && c != '+' && c != '?' && c != '{') return atom;
    if (!quantifiable) fail("quantifier after an anchor");
    auto rep = std::make_unique<Node>(NodeKind::Repeat);
    parse_quantifier(rep->min, rep->max);
    rep->children.push_back(std::move(atom));
    if (!at_end() && (peek() == '*' || peek() == '+' || peek() == '?' || peek() == '{'))
      fail("quantifier follows a quantifier");
    return rep;
  }

  int parse_int() {
    if (at_end() || peek() < '0' || peek() > '9') fail("expected a number in quantifier");
    if (peek() == '0' && pos_ + 1 < p_.size() && p_[pos_ + 1] >= '0' && p_[pos_ + 1] <= '9')
      fail("leading zero in quantifier");
    long v = 0;
    while (!at_end() && peek() >= '0' && peek() <= '9') {
      v = v * 10 + (peek() - '0');
      if (v > kMaxRepeatBound) fail("repeat count too large");
      ++pos_;
    }
    return static_cast<int>(v);
  }

  void parse_quantifier(int& min, int& max) {
    char c = peek();
    ++pos_;
    if (c == '*') { min = 0; max = kUnbounded; return; }
    if (c == '+') { min = 1; max = kUnbounded; return; }
    if (c == '?') { min = 0; max = 1; return; }
    min = parse_int();
    max = min;
    if (!at_end() && peek() == ',') {
      ++pos_;
      if (!at_end() && peek() == '}') max = kUnbounded;
      else max = parse_int();
    }
    if (at_end() || peek() != '}') fail("unterminated '{' quantifier");
    ++pos_;
    if (max != kUnbounded && max < min) fail("quantifier maximum is below its minimum");
  }

  NodePtr parse_group() {
    ++pos_;  // '('
    auto g = std::make_unique<Node>(NodeKind::Group);
    g->group = ++groups_;
    g->children.push_back(parse_regex());
    if (at_end() || peek() != ')') fail("missing ')'");
    ++pos_;
    return g;
  }

  /// Set escape letter -> set; returns false if \p c is not one.
  static bool set_escape(char c, CharSet& out) {
    switch (c) {
      case 'd': out = CharSet::digits(); return true;
      case 'w': out = CharSet::word(); return true;
      case 's': out = CharSet::space(); return true;
      case 'D': out = CharSet::digits(); out.invert_ascii(); return true;
      case 'W': out = CharSet::word(); out.invert_ascii(); return true;
      case 'S': out = CharSet::space(); out.invert_ascii(); return true;
      default: return false;
    }
  }

  NodePtr parse_escape() {
    ++pos_;  // '\'
    if (at_end()) fail("pattern ends with a backslash");
    char c = peek();
    CharSet cs;
    NodePtr n;
    if (set_escape(c, cs)) {
      n = std::make_unique<Node>(NodeKind::Set);
      n->set = cs;
    } else if (is_alnum(c) || !is_printable(c)) {
      fail("unsupported escape");
    } else {
      n = std::make_unique<Node>(NodeKind::Literal);
      n->ch = static_cast<unsigned char>(c);
    }
    ++pos_;
    return n;
  }

  /// One single-character class item (after handling `\`): returns the byte,
  /// or sets \p is_set and \p set for a set escape.
  unsigned char class_atom(bool& is_set, CharSet& set) {
    char c = peek();
    ++pos_;
    is_set = false;
    if (c != '\\') {
      if (!is_printable(c)) fail("non-printable character in class");
      return static_cast<unsigned char>(c);
    }
    if (at_end()) fail("pattern ends with a backslash");
    c = peek();
    if (set_escape(c, set)) {
      is_set = true;
      ++pos_;
      return 0;
    }
    if (is_alnum(c) || !is_printable(c)) fail("unsupported escape in class");
    ++pos_;
    return static_cast<unsigned char>(c);
  }

  NodePtr parse_class() {
    ++pos_;  // '['
    CharSet set;
    bool negate = false;
    if (!at_end() && peek() == '^') { negate = true; ++pos_; }
    bool first = true;
    for (;;) {
      if (at_end()) fail("missing ']'");
      if (peek() == ']') {
        if (first) fail("empty character class");
        ++pos_;
        break;
      }
      first = false;
      bool is_set;
      CharSet esc;
      unsigned char lo = class_atom(is_set, esc);
      if (is_set) { set.add_all(esc); continue; }
      // A '-' followed by something other than ']' makes a range.
      if (pos_ + 1 < p_.size() && peek() == '-' && p_[pos_ + 1] != ']') {
        ++pos_;
        bool hi_is_set;
        CharSet dummy;
        unsigned char hi = class_atom(hi_is_set, dummy);
        if (hi_is_set) fail("set escape as range endpoint");
        if (hi < lo) fail("range out of order");
        set.add_range(lo, hi);
      } else {
        set.add(lo);
      }
    }
    if (negate) set.invert();
    auto n = std::make_unique<Node>(NodeKind::Set);
    n->set = set;
    return n;
  }

  std::string_view p_;
  std::size_t pos_ = 0;
  int groups_ = 0;
};

}  // namespace

ParseResult parse(std::string_view pattern) { return Parser(pattern).run(); }

}  // namespace regex
