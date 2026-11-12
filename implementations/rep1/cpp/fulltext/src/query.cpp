#include "fulltext/query.hpp"

#include <algorithm>

#include "fulltext/analyzer.hpp"
#include "fulltext/utf8.hpp"

namespace fulltext {

namespace {

using NodePtr = std::unique_ptr<QueryNode>;

struct QToken {
  enum class Kind { LParen, RParen, And, Or, Not, Atom };
  Kind kind;
  Atom atom;  // empty for an empty atom
};

/// Builds the atom for a phrase body (see "Atoms" in SPEC.md).
Atom make_atom(std::string_view body) {
  const std::vector<Token> tokens = analyze(body);
  if (tokens.empty()) return {};
  if (tokens.size() == 1 && is_stop_word(tokens[0].text)) return {};
  Atom atom;
  atom.reserve(tokens.size());
  for (const Token& t : tokens) atom.push_back(t.term);
  return atom;
}

std::vector<QToken> lex(std::string_view s) {
  std::vector<QToken> out;
  std::size_t i = 0;
  while (i < s.size()) {
    if (const unsigned w = utf8::whitespace_length_at(s, i)) {
      i += w;
    } else if (s[i] == '(') {
      out.push_back({QToken::Kind::LParen, {}});
      ++i;
    } else if (s[i] == ')') {
      out.push_back({QToken::Kind::RParen, {}});
      ++i;
    } else if (s[i] == '"') {
      const std::size_t close = s.find('"', i + 1);
      const std::size_t end = close == std::string_view::npos ? s.size() : close;
      out.push_back({QToken::Kind::Atom, make_atom(s.substr(i + 1, end - i - 1))});
      i = close == std::string_view::npos ? s.size() : close + 1;
    } else {
      std::size_t j = i;
      while (j < s.size() && !utf8::whitespace_length_at(s, j) && s[j] != '(' && s[j] != ')' &&
             s[j] != '"') {
        ++j;
      }
      const std::string_view word = s.substr(i, j - i);
      if (word == "AND") {
        out.push_back({QToken::Kind::And, {}});
      } else if (word == "OR") {
        out.push_back({QToken::Kind::Or, {}});
      } else if (word == "NOT") {
        out.push_back({QToken::Kind::Not, {}});
      } else {
        out.push_back({QToken::Kind::Atom, make_atom(word)});
      }
      i = j;
    }
  }
  return out;
}

class Parser {
 public:
  explicit Parser(std::vector<QToken> tokens) : tokens_(std::move(tokens)) {}

  NodePtr parse() { return parse_or(); }  // trailing tokens are discarded

 private:
  using K = QToken::Kind;

  bool at(K kind) const { return pos_ < tokens_.size() && tokens_[pos_].kind == kind; }
  bool at_end() const { return pos_ >= tokens_.size(); }

  static NodePtr combine(QueryNode::Kind kind, std::vector<NodePtr>& parts) {
    std::vector<NodePtr> kept;
    for (NodePtr& p : parts) {
      if (p) kept.push_back(std::move(p));
    }
    if (kept.empty()) return nullptr;
    if (kept.size() == 1) return std::move(kept[0]);
    auto node = std::make_unique<QueryNode>();
    node->kind = kind;
    node->children = std::move(kept);
    return node;
  }

  NodePtr parse_or() {
    std::vector<NodePtr> parts;
    parts.push_back(parse_and());
    while (at(K::Or)) {
      ++pos_;
      parts.push_back(parse_and());
    }
    return combine(QueryNode::Kind::Or, parts);
  }

  NodePtr parse_and() {
    std::vector<NodePtr> parts;
    while (!at_end() && !at(K::RParen) && !at(K::Or)) {
      if (at(K::And)) {
        ++pos_;
        continue;
      }
      parts.push_back(parse_not());
    }
    return combine(QueryNode::Kind::And, parts);
  }

  NodePtr parse_not() {
    std::size_t nots = 0;
    while (at(K::Not)) {
      ++pos_;
      ++nots;
    }
    NodePtr node = parse_primary();
    if (!node) return nullptr;
    while (nots-- > 0) {
      auto wrap = std::make_unique<QueryNode>();
      wrap->kind = QueryNode::Kind::Not;
      wrap->children.push_back(std::move(node));
      node = std::move(wrap);
    }
    return node;
  }

  NodePtr parse_primary() {
    if (at_end() || at(K::RParen)) return nullptr;
    if (at(K::LParen)) {
      ++pos_;
      NodePtr inner = parse_or();
      if (at(K::RParen)) ++pos_;
      return inner;
    }
    QToken& tok = tokens_[pos_++];
    if (tok.kind == K::Atom && !tok.atom.empty()) {
      auto node = std::make_unique<QueryNode>();
      node->kind = QueryNode::Kind::Atom;
      node->atom = std::move(tok.atom);
      return node;
    }
    return nullptr;
  }

  std::vector<QToken> tokens_;
  std::size_t pos_ = 0;
};

void collect_positive(const QueryNode& node, bool positive, std::vector<Atom>& out) {
  switch (node.kind) {
    case QueryNode::Kind::Atom:
      if (positive && std::find(out.begin(), out.end(), node.atom) == out.end()) {
        out.push_back(node.atom);
      }
      break;
    case QueryNode::Kind::Not:
      collect_positive(*node.children[0], !positive, out);
      break;
    default:
      for (const auto& c : node.children) collect_positive(*c, positive, out);
  }
}

}  // namespace

Query parse_query(std::string_view text) {
  Query q;
  q.root = Parser(lex(text)).parse();
  if (q.root) collect_positive(*q.root, true, q.positive_atoms);
  return q;
}

}  // namespace fulltext
