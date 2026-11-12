#include "rx/parser.hpp"

#include <string>
#include <utility>

namespace rx {
namespace {

constexpr int kMaxNesting = 1000;

bool is_alnum(char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

// Set for \d \D \w \W \s \S; returns false if `c` is not one of d D w W s S.
bool class_escape(char c, CharSet& out) {
  CharSet s;
  switch (c) {
    case 'd': case 'D': s = CharSet::digits(); break;
    case 'w': case 'W': s = CharSet::word(); break;
    case 's': case 'S': s = CharSet::space(); break;
    default: return false;
  }
  if (c == 'D' || c == 'W' || c == 'S') s.invert();
  out = s;
  return true;
}

class Parser {
 public:
  explicit Parser(std::string_view p) : p_(p) {}

  ParsedPattern run() {
    auto root = parse_alternation(0);
    if (i_ < p_.size()) fail("unmatched ')'");
    ParsedPattern result;
    result.root = std::move(root);
    result.group_count = groups_;
    return result;
  }

 private:
  [[noreturn]] void fail(const std::string& msg) const { throw ParseError(msg, i_); }

  bool eof() const { return i_ >= p_.size(); }
  char peek() const { return p_[i_]; }

  static bool is_quantifier_start(char c) { return c == '*' || c == '+' || c == '?' || c == '{'; }

  static std::unique_ptr<Node> make(NodeKind k) { return std::make_unique<Node>(k); }

  static void finish_nullable(Node& n) {
    switch (n.kind) {
      case NodeKind::Literal: case NodeKind::Any: case NodeKind::Set:
        n.nullable = false;
        break;
      case NodeKind::Empty: case NodeKind::Bol: case NodeKind::Eol:
        n.nullable = true;
        break;
      case NodeKind::Concat:
        n.nullable = true;
        for (auto& c : n.children) n.nullable = n.nullable && c->nullable;
        break;
      case NodeKind::Alternate:
        n.nullable = false;
        for (auto& c : n.children) n.nullable = n.nullable || c->nullable;
        break;
      case NodeKind::Group:
        n.nullable = n.children[0]->nullable;
        break;
      case NodeKind::Repeat:
        n.nullable = n.min == 0 || n.children[0]->nullable;
        break;
    }
  }

  std::unique_ptr<Node> parse_alternation(int depth) {
    if (depth > kMaxNesting) fail("pattern nested too deeply");
    std::vector<std::unique_ptr<Node>> branches;
    branches.push_back(parse_concat(depth));
    while (!eof() && peek() == '|') {
      ++i_;
      branches.push_back(parse_concat(depth));
    }
    if (branches.size() == 1) return std::move(branches[0]);
    auto n = make(NodeKind::Alternate);
    n->children = std::move(branches);
    finish_nullable(*n);
    return n;
  }

  std::unique_ptr<Node> parse_concat(int depth) {
    std::vector<std::unique_ptr<Node>> pieces;
    while (!eof() && peek() != '|' && peek() != ')') pieces.push_back(parse_piece(depth));
    if (pieces.empty()) {
      auto n = make(NodeKind::Empty);
      finish_nullable(*n);
      return n;
    }
    if (pieces.size() == 1) return std::move(pieces[0]);
    auto n = make(NodeKind::Concat);
    n->children = std::move(pieces);
    finish_nullable(*n);
    return n;
  }

  std::unique_ptr<Node> parse_piece(int depth) {
    auto atom = parse_atom(depth);
    if (eof() || !is_quantifier_start(peek())) return atom;
    if (atom->kind == NodeKind::Bol || atom->kind == NodeKind::Eol)
      fail("quantifier cannot follow an anchor");
    int lo = 0, hi = 0;
    parse_quantifier(lo, hi);
    if (!eof() && is_quantifier_start(peek())) fail("quantifier cannot follow a quantifier");
    auto rep = make(NodeKind::Repeat);
    rep->min = lo;
    rep->max = hi;
    rep->children.push_back(std::move(atom));
    finish_nullable(*rep);
    return rep;
  }

  int read_count() {
    if (eof() || peek() < '0' || peek() > '9') fail("expected a number in quantifier");
    if (peek() == '0' && i_ + 1 < p_.size() && p_[i_ + 1] >= '0' && p_[i_ + 1] <= '9')
      fail("leading zero in quantifier");
    long v = 0;
    while (!eof() && peek() >= '0' && peek() <= '9') {
      v = v * 10 + (peek() - '0');
      if (v > kMaxRepeatCount) fail("repeat count too large");
      ++i_;
    }
    return static_cast<int>(v);
  }

  void parse_quantifier(int& lo, int& hi) {
    char c = peek();
    ++i_;
    switch (c) {
      case '*': lo = 0; hi = Node::kUnbounded; return;
      case '+': lo = 1; hi = Node::kUnbounded; return;
      case '?': lo = 0; hi = 1; return;
      default: break;
    }
    lo = read_count();
    if (!eof() && peek() == '}') {
      ++i_;
      hi = lo;
      return;
    }
    if (eof() || peek() != ',') fail("malformed quantifier");
    ++i_;
    if (!eof() && peek() == '}') {
      ++i_;
      hi = Node::kUnbounded;
      return;
    }
    hi = read_count();
    if (eof() || peek() != '}') fail("malformed quantifier");
    ++i_;
    if (hi < lo) fail("quantifier minimum exceeds maximum");
  }

  std::unique_ptr<Node> parse_atom(int depth) {
    char c = peek();
    switch (c) {
      case '(': return parse_group(depth);
      case '[': return parse_class();
      case '\\': return parse_escape();
      case '.': ++i_; return finished(make(NodeKind::Any));
      case '^': ++i_; return finished(make(NodeKind::Bol));
      case '$': ++i_; return finished(make(NodeKind::Eol));
      case '*': case '+': case '?': case '{': fail("quantifier has nothing to repeat");
      case '}': fail("unexpected '}'");
      case ']': fail("unexpected ']'");
      default: {
        auto n = make(NodeKind::Literal);
        n->ch = static_cast<unsigned char>(c);
        ++i_;
        return finished(std::move(n));
      }
    }
  }

  static std::unique_ptr<Node> finished(std::unique_ptr<Node> n) {
    finish_nullable(*n);
    return n;
  }

  std::unique_ptr<Node> parse_group(int depth) {
    ++i_;  // '('
    auto n = make(NodeKind::Group);
    n->group = ++groups_;
    n->children.push_back(parse_alternation(depth + 1));
    if (eof() || peek() != ')') fail("missing ')'");
    ++i_;
    return finished(std::move(n));
  }

  std::unique_ptr<Node> parse_escape() {
    ++i_;  // '\'
    if (eof()) fail("trailing backslash");
    char c = peek();
    auto n = make(NodeKind::Set);
    if (class_escape(c, n->set)) {
      ++i_;
      return finished(std::move(n));
    }
    if (is_alnum(c)) fail(std::string("unknown escape '\\") + c + "'");
    n = make(NodeKind::Literal);
    n->ch = static_cast<unsigned char>(c);
    ++i_;
    return finished(std::move(n));
  }

  // One class character: either a plain char or '\' + non-alphanumeric.
  unsigned char class_char() {
    char c = peek();
    if (c == '\\') {
      ++i_;
      if (eof()) fail("trailing backslash in class");
      c = peek();
      if (is_alnum(c)) fail(std::string("unknown escape '\\") + c + "' in class");
    } else if (c == ']') {
      fail("unexpected ']'");
    }
    ++i_;
    return static_cast<unsigned char>(c);
  }

  std::unique_ptr<Node> parse_class() {
    ++i_;  // '['
    auto n = make(NodeKind::Set);
    bool negate = false;
    if (!eof() && peek() == '^') {
      negate = true;
      ++i_;
    }
    bool any_item = false;
    while (true) {
      if (eof()) fail("missing ']'");
      if (peek() == ']') {
        if (!any_item) fail("empty character class");
        ++i_;
        break;
      }
      any_item = true;
      if (peek() == '\\' && i_ + 1 < p_.size()) {
        CharSet es;
        if (class_escape(p_[i_ + 1], es)) {
          n->set.add_all(es);
          i_ += 2;
          continue;
        }
      }
      unsigned char lo = class_char();
      // A '-' is a range operator unless it is the last character before ']'.
      if (!eof() && peek() == '-' && i_ + 1 < p_.size() && p_[i_ + 1] != ']') {
        ++i_;
        unsigned char hi = class_char();
        if (hi < lo) fail("range out of order in class");
        n->set.add_range(lo, hi);
      } else {
        n->set.add(lo);
      }
    }
    if (negate) n->set.invert();
    return finished(std::move(n));
  }

  std::string_view p_;
  std::size_t i_ = 0;
  std::size_t groups_ = 0;
};

}  // namespace

ParsedPattern parse(std::string_view pattern) { return Parser(pattern).run(); }

}  // namespace rx
