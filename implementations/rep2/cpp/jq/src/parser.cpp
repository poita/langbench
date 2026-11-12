#include "parser.hpp"

#include <charconv>
#include <cstring>
#include <unordered_map>

#include "jq/error.hpp"
#include "jq/json.hpp"

namespace jq::detail {

namespace {

enum class Tok {
  End, Num, Str, Ident, Var,
  Dot, LBrack, RBrack, LParen, RParen, LBrace, RBrace, Comma, Pipe, Colon, Semi, Quest,
  Plus, Minus, Star, Slash, Percent, Eq, Ne, Lt, Le, Gt, Ge,
};

struct Token {
  Tok kind = Tok::End;
  std::string text;  // identifier / variable name / decoded string
  double num = 0;
  bool space_before = false;
  std::size_t pos = 0;
};

class Lexer {
 public:
  explicit Lexer(std::string_view s) : s_(s) {}

  std::vector<Token> run() {
    std::vector<Token> out;
    for (;;) {
      Token t = next();
      bool end = t.kind == Tok::End;
      out.push_back(std::move(t));
      if (end) return out;
    }
  }

 private:
  [[noreturn]] void fail(const std::string& msg) const {
    throw SyntaxError(msg + " at offset " + std::to_string(pos_));
  }
  static bool ident_start(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
  static bool digit(char c) { return c >= '0' && c <= '9'; }

  Token next() {
    std::size_t before = pos_;
    while (pos_ < s_.size() && (s_[pos_] == ' ' || s_[pos_] == '\t' || s_[pos_] == '\n' || s_[pos_] == '\r'))
      ++pos_;
    Token t;
    t.space_before = pos_ > before;
    t.pos = pos_;
    if (pos_ >= s_.size()) return t;
    char c = s_[pos_];
    auto two = [&](char n) { return pos_ + 1 < s_.size() && s_[pos_ + 1] == n; };
    auto punct = [&](Tok k, std::size_t len) {
      t.kind = k;
      pos_ += len;
      return t;
    };
    if (ident_start(c)) {
      std::size_t b = pos_;
      while (pos_ < s_.size() && (ident_start(s_[pos_]) || digit(s_[pos_]))) ++pos_;
      t.kind = Tok::Ident;
      t.text.assign(s_.substr(b, pos_ - b));
      return t;
    }
    if (digit(c)) {
      std::size_t b = pos_;
      while (pos_ < s_.size() && digit(s_[pos_])) ++pos_;
      if (pos_ + 1 < s_.size() && s_[pos_] == '.' && digit(s_[pos_ + 1])) {
        ++pos_;
        while (pos_ < s_.size() && digit(s_[pos_])) ++pos_;
      }
      t.kind = Tok::Num;
      std::from_chars(s_.data() + b, s_.data() + pos_, t.num);
      return t;
    }
    switch (c) {
      case '"': {
        std::size_t b = pos_++;
        while (pos_ < s_.size() && s_[pos_] != '"') pos_ += s_[pos_] == '\\' ? 2 : 1;
        if (pos_ >= s_.size()) fail("unterminated string");
        ++pos_;
        try {
          t.text = parse_json(s_.substr(b, pos_ - b)).as_string();
        } catch (const JsonError& e) {
          fail(std::string("bad string literal: ") + e.what());
        }
        t.kind = Tok::Str;
        return t;
      }
      case '$': {
        ++pos_;
        std::size_t b = pos_;
        if (pos_ >= s_.size() || !ident_start(s_[pos_])) fail("expected variable name");
        while (pos_ < s_.size() && (ident_start(s_[pos_]) || digit(s_[pos_]))) ++pos_;
        t.kind = Tok::Var;
        t.text.assign(s_.substr(b, pos_ - b));
        return t;
      }
      case '.': return punct(Tok::Dot, 1);
      case '[': return punct(Tok::LBrack, 1);
      case ']': return punct(Tok::RBrack, 1);
      case '(': return punct(Tok::LParen, 1);
      case ')': return punct(Tok::RParen, 1);
      case '{': return punct(Tok::LBrace, 1);
      case '}': return punct(Tok::RBrace, 1);
      case ',': return punct(Tok::Comma, 1);
      case '|': return punct(Tok::Pipe, 1);
      case ':': return punct(Tok::Colon, 1);
      case ';': return punct(Tok::Semi, 1);
      case '?': return punct(Tok::Quest, 1);
      case '+': return punct(Tok::Plus, 1);
      case '-': return punct(Tok::Minus, 1);
      case '*': return punct(Tok::Star, 1);
      case '/': return punct(Tok::Slash, 1);
      case '%': return punct(Tok::Percent, 1);
      case '=':
        if (two('=')) return punct(Tok::Eq, 2);
        break;
      case '!':
        if (two('=')) return punct(Tok::Ne, 2);
        break;
      case '<': return two('=') ? punct(Tok::Le, 2) : punct(Tok::Lt, 1);
      case '>': return two('=') ? punct(Tok::Ge, 2) : punct(Tok::Gt, 1);
      default: break;
    }
    fail(std::string("unexpected character '") + c + "'");
  }

  std::string_view s_;
  std::size_t pos_ = 0;
};

const std::unordered_map<std::string, std::pair<Builtin, int>>& builtin_table() {
  static const std::unordered_map<std::string, std::pair<Builtin, int>> t = {
      {"empty", {Builtin::Empty, 0}},       {"error", {Builtin::Error, -1}},
      {"not", {Builtin::Not, 0}},           {"length", {Builtin::Length, 0}},
      {"keys", {Builtin::Keys, 0}},         {"has", {Builtin::Has, 1}},
      {"type", {Builtin::Type, 0}},         {"add", {Builtin::Add, 0}},
      {"select", {Builtin::Select, 1}},     {"map", {Builtin::Map, 1}},
      {"sort", {Builtin::Sort, 0}},         {"sort_by", {Builtin::SortBy, 1}},
      {"group_by", {Builtin::GroupBy, 1}},  {"unique", {Builtin::Unique, 0}},
      {"reverse", {Builtin::Reverse, 0}},   {"min", {Builtin::Min, 0}},
      {"max", {Builtin::Max, 0}},           {"tostring", {Builtin::ToString, 0}},
      {"tonumber", {Builtin::ToNumber, 0}},
  };
  return t;
}

class Parser {
 public:
  explicit Parser(std::string_view text) : toks_(Lexer(text).run()) {}

  NodePtr parse() {
    NodePtr n = parse_pipe();
    if (cur().kind != Tok::End) fail("unexpected token");
    return n;
  }

 private:
  const Token& cur() const { return toks_[i_]; }
  const Token& peek(std::size_t k = 1) const { return toks_[std::min(i_ + k, toks_.size() - 1)]; }
  bool at(Tok k) const { return cur().kind == k; }
  bool at_kw(const char* kw) const { return cur().kind == Tok::Ident && cur().text == kw; }
  void advance() {
    if (i_ + 1 < toks_.size()) ++i_;
  }
  bool accept(Tok k) {
    if (at(k)) {
      advance();
      return true;
    }
    return false;
  }
  bool accept_kw(const char* kw) {
    if (at_kw(kw)) {
      advance();
      return true;
    }
    return false;
  }
  [[noreturn]] void fail(const std::string& msg) const {
    throw SyntaxError(msg + " at offset " + std::to_string(cur().pos));
  }
  void expect(Tok k, const char* what) {
    if (!accept(k)) fail(std::string("expected ") + what);
  }
  void expect_kw(const char* kw) {
    if (!accept_kw(kw)) fail(std::string("expected '") + kw + "'");
  }

  static NodePtr make(Kind k) { return std::make_unique<Node>(k); }
  static NodePtr make(Kind k, NodePtr a, NodePtr b = nullptr, NodePtr c = nullptr) {
    auto n = make(k);
    n->a = std::move(a);
    n->b = std::move(b);
    n->c = std::move(c);
    return n;
  }
  static NodePtr literal(Value v) {
    auto n = make(Kind::Literal);
    n->lit = std::move(v);
    return n;
  }
  static NodePtr field(NodePtr target, std::string name) {
    return make(Kind::Index, std::move(target), literal(Value::string(std::move(name))));
  }

  // pipe := postfix "as" "$" IDENT "|" pipe | comma ["|" pipe]
  NodePtr parse_pipe() {
    if (!at(Tok::Minus)) {
      NodePtr p = parse_postfix();
      if (at_kw("as")) {
        advance();
        if (!at(Tok::Var)) fail("expected variable after 'as'");
        std::string name = cur().text;
        advance();
        expect(Tok::Pipe, "'|'");
        auto n = make(Kind::As, std::move(p), parse_pipe());
        n->name = std::move(name);
        return n;
      }
      pending_ = std::move(p);
    }
    NodePtr l = parse_comma();
    if (accept(Tok::Pipe)) return make(Kind::Pipe, std::move(l), parse_pipe());
    return l;
  }

  NodePtr parse_comma() {
    NodePtr l = parse_or();
    while (accept(Tok::Comma)) l = make(Kind::Comma, std::move(l), parse_or());
    return l;
  }
  NodePtr parse_or() {
    NodePtr l = parse_and();
    while (accept_kw("or")) l = make(Kind::Or, std::move(l), parse_and());
    return l;
  }
  NodePtr parse_and() {
    NodePtr l = parse_cmp();
    while (accept_kw("and")) l = make(Kind::And, std::move(l), parse_cmp());
    return l;
  }
  NodePtr parse_cmp() {
    NodePtr l = parse_add();
    BinOp op;
    switch (cur().kind) {
      case Tok::Eq: op = BinOp::Eq; break;
      case Tok::Ne: op = BinOp::Ne; break;
      case Tok::Lt: op = BinOp::Lt; break;
      case Tok::Le: op = BinOp::Le; break;
      case Tok::Gt: op = BinOp::Gt; break;
      case Tok::Ge: op = BinOp::Ge; break;
      default: return l;
    }
    advance();
    return binary(op, std::move(l), parse_add());
  }
  static NodePtr binary(BinOp op, NodePtr l, NodePtr r) {
    auto n = make(Kind::Binary, std::move(l), std::move(r));
    n->op = op;
    return n;
  }
  NodePtr parse_add() {
    NodePtr l = parse_mul();
    for (;;) {
      if (accept(Tok::Plus))
        l = binary(BinOp::Add, std::move(l), parse_mul());
      else if (accept(Tok::Minus))
        l = binary(BinOp::Sub, std::move(l), parse_mul());
      else
        return l;
    }
  }
  NodePtr parse_mul() {
    NodePtr l = parse_unary();
    for (;;) {
      if (accept(Tok::Star))
        l = binary(BinOp::Mul, std::move(l), parse_unary());
      else if (accept(Tok::Slash))
        l = binary(BinOp::Div, std::move(l), parse_unary());
      else if (accept(Tok::Percent))
        l = binary(BinOp::Mod, std::move(l), parse_unary());
      else
        return l;
    }
  }
  NodePtr parse_unary() {
    if (pending_) return std::move(pending_);
    if (accept(Tok::Minus)) return negate(parse_unary());
    return parse_postfix();
  }
  static NodePtr negate(NodePtr x) {
    if (x->kind == Kind::Literal && x->lit.is_number()) return literal(Value::number(-x->lit.as_number()));
    return make(Kind::Neg, std::move(x));
  }

  // postfix := primary { suffix }
  NodePtr parse_postfix() {
    bool path = false;  // true while the term so far ends in an un-marked path suffix
    NodePtr t = parse_primary(path);
    for (;;) {
      if (at(Tok::Dot)) {
        const Token& n = peek();
        if ((n.kind == Tok::Ident || n.kind == Tok::Str) && !n.space_before) {
          advance();
          t = field(std::move(t), cur().text);
          advance();
          path = true;
          continue;
        }
        if (n.kind == Tok::LBrack) {  // `.a.[0]`
          advance();
          continue;
        }
        break;
      }
      if (at(Tok::LBrack)) {
        t = parse_bracket(std::move(t));
        path = true;
        continue;
      }
      if (at(Tok::Quest)) {
        advance();
        if (path) {
          t->opt = true;
          path = false;
        } else {
          t = make(Kind::Try, std::move(t));
        }
        continue;
      }
      break;
    }
    return t;
  }

  NodePtr parse_bracket(NodePtr target) {
    expect(Tok::LBrack, "'['");
    if (accept(Tok::RBrack)) return make(Kind::Iterate, std::move(target));
    NodePtr from;
    if (!at(Tok::Colon)) {
      from = parse_pipe();
      if (accept(Tok::RBrack)) return make(Kind::Index, std::move(target), std::move(from));
    }
    expect(Tok::Colon, "':'");
    NodePtr to;
    if (!at(Tok::RBrack)) to = parse_pipe();
    expect(Tok::RBrack, "']'");
    return make(Kind::Slice, std::move(target), std::move(from), std::move(to));
  }

  NodePtr parse_primary(bool& path) {
    const Token& t = cur();
    switch (t.kind) {
      case Tok::Num: {
        NodePtr n = literal(Value::number(t.num));
        advance();
        return n;
      }
      case Tok::Str: {
        NodePtr n = literal(Value::string(t.text));
        advance();
        return n;
      }
      case Tok::Var: {
        auto n = make(Kind::Var);
        n->name = t.text;
        advance();
        return n;
      }
      case Tok::Dot: {
        advance();
        const Token& n = cur();
        if ((n.kind == Tok::Ident || n.kind == Tok::Str) && !n.space_before) {
          NodePtr f = field(make(Kind::Identity), n.text);
          advance();
          path = true;
          return f;
        }
        return make(Kind::Identity);
      }
      case Tok::LParen: {
        advance();
        NodePtr n = parse_pipe();
        expect(Tok::RParen, "')'");
        return n;
      }
      case Tok::LBrack: {
        advance();
        if (accept(Tok::RBrack)) return make(Kind::Array);
        NodePtr body = parse_pipe();
        expect(Tok::RBrack, "']'");
        return make(Kind::Array, std::move(body));
      }
      case Tok::LBrace: return parse_object();
      case Tok::Ident: return parse_ident();
      default: fail("unexpected token");
    }
  }

  NodePtr parse_ident() {
    std::string name = cur().text;
    if (name == "true" || name == "false" || name == "null") {
      advance();
      return literal(name == "null" ? Value() : Value::boolean(name == "true"));
    }
    if (name == "if") {
      advance();
      return parse_if_rest();
    }
    if (name == "reduce") {
      advance();
      NodePtr src = parse_postfix();
      expect_kw("as");
      if (!at(Tok::Var)) fail("expected variable after 'as'");
      std::string var = cur().text;
      advance();
      expect(Tok::LParen, "'('");
      NodePtr init = parse_pipe();
      expect(Tok::Semi, "';'");
      NodePtr update = parse_pipe();
      expect(Tok::RParen, "')'");
      auto n = make(Kind::Reduce, std::move(src), std::move(init), std::move(update));
      n->name = std::move(var);
      return n;
    }
    static const char* const kKeywords[] = {"then", "elif", "else", "end", "as", "and", "or"};
    for (const char* kw : kKeywords)
      if (name == kw) fail("unexpected keyword '" + name + "'");
    auto it = builtin_table().find(name);
    if (it == builtin_table().end()) fail("unknown function '" + name + "'");
    advance();
    auto n = make(Kind::Call);
    n->builtin = it->second.first;
    if (accept(Tok::LParen)) {
      n->args.push_back(parse_pipe());
      while (accept(Tok::Semi)) n->args.push_back(parse_pipe());
      expect(Tok::RParen, "')'");
    }
    int want = it->second.second;
    int have = static_cast<int>(n->args.size());
    if (want >= 0 ? have != want : have > 1) fail("wrong number of arguments to '" + name + "'");
    return n;
  }

  // After "if" or "elif": cond then body {elif ...} [else body] end
  NodePtr parse_if_rest() {
    NodePtr cond = parse_pipe();
    expect_kw("then");
    NodePtr then = parse_pipe();
    NodePtr other;
    if (accept_kw("elif")) {
      other = parse_if_rest();  // consumes the shared `end`
      return make(Kind::If, std::move(cond), std::move(then), std::move(other));
    }
    if (accept_kw("else")) other = parse_pipe();
    expect_kw("end");
    return make(Kind::If, std::move(cond), std::move(then), std::move(other));
  }

  NodePtr parse_obj_term() {
    if (accept(Tok::Minus)) return negate(parse_obj_term());
    return parse_postfix();
  }
  NodePtr parse_obj_val() {
    NodePtr v = parse_obj_term();
    while (accept(Tok::Pipe)) v = make(Kind::Pipe, std::move(v), parse_obj_term());
    return v;
  }

  NodePtr parse_object() {
    expect(Tok::LBrace, "'{'");
    auto n = make(Kind::Object);
    if (accept(Tok::RBrace)) return n;
    for (;;) {
      ObjEntry e;
      std::string shorthand;
      bool plain = false;
      if (at(Tok::Ident) || at(Tok::Str)) {
        shorthand = cur().text;
        e.key = literal(Value::string(shorthand));
        plain = true;
        advance();
      } else if (at(Tok::Var)) {
        shorthand = cur().text;
        e.key = literal(Value::string(shorthand));
        advance();
        if (at(Tok::Colon)) fail("variable cannot be an object key");
        auto v = make(Kind::Var);
        v->name = shorthand;
        e.value = std::move(v);
        n->entries.push_back(std::move(e));
        if (accept(Tok::Comma)) continue;
        break;
      } else if (accept(Tok::LParen)) {
        e.key = parse_pipe();
        expect(Tok::RParen, "')'");
      } else {
        fail("bad object key");
      }
      if (accept(Tok::Colon)) {
        e.value = parse_obj_val();
      } else if (plain) {
        e.value = field(make(Kind::Identity), shorthand);
      } else {
        fail("expected ':'");
      }
      n->entries.push_back(std::move(e));
      if (!accept(Tok::Comma)) break;
    }
    expect(Tok::RBrace, "'}'");
    return n;
  }

  std::vector<Token> toks_;
  std::size_t i_ = 0;
  NodePtr pending_;  // a postfix term already parsed by parse_pipe, to be used as the first operand
};

}  // namespace

NodePtr parse_program(std::string_view text) { return Parser(text).parse(); }

}  // namespace jq::detail
