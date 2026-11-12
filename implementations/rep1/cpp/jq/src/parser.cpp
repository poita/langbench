#include "parser.hpp"

#include <charconv>
#include <cstdint>
#include <map>
#include <utility>

#include "jq/error.hpp"

namespace jq::detail {

namespace {

enum class Tok {
  End, Dot, Ident, Number, String, Var, LParen, RParen, LBracket, RBracket,
  LBrace, RBrace, Comma, Pipe, Colon, Semi, Question, Plus, Minus, Star,
  Slash, Percent, Eq, Ne, Lt, Le, Gt, Ge,
};

struct Token {
  Tok kind = Tok::End;
  std::string text;  // identifier / variable name / decoded string
  double num = 0;
  std::size_t pos = 0, end = 0;
};

void append_utf8(std::string& out, std::uint32_t cp) {
  if (cp < 0x80) {
    out.push_back(static_cast<char>(cp));
  } else if (cp < 0x800) {
    out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp < 0x10000) {
    out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else {
    out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  }
}

bool is_ident_start(char c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'; }
bool is_digit(char c) { return c >= '0' && c <= '9'; }
bool is_ident_char(char c) { return is_ident_start(c) || is_digit(c); }

class Lexer {
 public:
  explicit Lexer(std::string_view s) : s_(s) {}

  std::vector<Token> run() {
    std::vector<Token> out;
    while (true) {
      Token t = next();
      bool done = t.kind == Tok::End;
      out.push_back(std::move(t));
      if (done) break;
    }
    return out;
  }

 private:
  [[noreturn]] void fail(const std::string& msg) const {
    throw ParseError("syntax error: " + msg + " at offset " + std::to_string(pos_));
  }

  Token make(Tok k, std::size_t start) {
    Token t;
    t.kind = k;
    t.pos = start;
    t.end = pos_;
    return t;
  }

  std::uint32_t hex4() {
    if (pos_ + 4 > s_.size()) fail("truncated \\u escape");
    std::uint32_t v = 0;
    for (int i = 0; i < 4; ++i) {
      char c = s_[pos_++];
      v <<= 4;
      if (is_digit(c)) v |= static_cast<std::uint32_t>(c - '0');
      else if (c >= 'a' && c <= 'f') v |= static_cast<std::uint32_t>(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F') v |= static_cast<std::uint32_t>(c - 'A' + 10);
      else fail("bad \\u escape");
    }
    return v;
  }

  Token next() {
    while (pos_ < s_.size() &&
           (s_[pos_] == ' ' || s_[pos_] == '\t' || s_[pos_] == '\r' || s_[pos_] == '\n'))
      ++pos_;
    const std::size_t start = pos_;
    if (pos_ >= s_.size()) return make(Tok::End, start);
    char c = s_[pos_];
    if (is_ident_start(c)) {
      while (pos_ < s_.size() && is_ident_char(s_[pos_])) ++pos_;
      Token t = make(Tok::Ident, start);
      t.text = std::string(s_.substr(start, pos_ - start));
      return t;
    }
    if (is_digit(c)) {
      while (pos_ < s_.size() && is_digit(s_[pos_])) ++pos_;
      if (pos_ + 1 < s_.size() && s_[pos_] == '.' && is_digit(s_[pos_ + 1])) {
        ++pos_;
        while (pos_ < s_.size() && is_digit(s_[pos_])) ++pos_;
      }
      Token t = make(Tok::Number, start);
      std::from_chars(s_.data() + start, s_.data() + pos_, t.num);
      return t;
    }
    if (c == '$') {
      ++pos_;
      std::size_t b = pos_;
      if (pos_ >= s_.size() || !is_ident_start(s_[pos_])) fail("expected variable name");
      while (pos_ < s_.size() && is_ident_char(s_[pos_])) ++pos_;
      Token t = make(Tok::Var, start);
      t.text = std::string(s_.substr(b, pos_ - b));
      return t;
    }
    if (c == '"') return lex_string(start);
    ++pos_;
    auto two = [&](char nx, Tok yes, Tok no) {
      if (pos_ < s_.size() && s_[pos_] == nx) {
        ++pos_;
        return make(yes, start);
      }
      return make(no, start);
    };
    switch (c) {
      case '.': return make(Tok::Dot, start);
      case '(': return make(Tok::LParen, start);
      case ')': return make(Tok::RParen, start);
      case '[': return make(Tok::LBracket, start);
      case ']': return make(Tok::RBracket, start);
      case '{': return make(Tok::LBrace, start);
      case '}': return make(Tok::RBrace, start);
      case ',': return make(Tok::Comma, start);
      case '|': return make(Tok::Pipe, start);
      case ':': return make(Tok::Colon, start);
      case ';': return make(Tok::Semi, start);
      case '?': return make(Tok::Question, start);
      case '+': return make(Tok::Plus, start);
      case '-': return make(Tok::Minus, start);
      case '*': return make(Tok::Star, start);
      case '/': return make(Tok::Slash, start);
      case '%': return make(Tok::Percent, start);
      case '<': return two('=', Tok::Le, Tok::Lt);
      case '>': return two('=', Tok::Ge, Tok::Gt);
      case '=':
        if (pos_ < s_.size() && s_[pos_] == '=') {
          ++pos_;
          return make(Tok::Eq, start);
        }
        break;
      case '!':
        if (pos_ < s_.size() && s_[pos_] == '=') {
          ++pos_;
          return make(Tok::Ne, start);
        }
        break;
      default: break;
    }
    --pos_;
    fail(std::string("unexpected character '") + c + "'");
  }

  Token lex_string(std::size_t start) {
    ++pos_;  // opening quote
    std::string out;
    while (true) {
      if (pos_ >= s_.size()) fail("unterminated string");
      char c = s_[pos_++];
      if (c == '"') break;
      if (c != '\\') {
        out.push_back(c);
        continue;
      }
      if (pos_ >= s_.size()) fail("unterminated string");
      char e = s_[pos_++];
      switch (e) {
        case '"': out.push_back('"'); break;
        case '\\': out.push_back('\\'); break;
        case '/': out.push_back('/'); break;
        case 'b': out.push_back('\b'); break;
        case 'f': out.push_back('\f'); break;
        case 'n': out.push_back('\n'); break;
        case 'r': out.push_back('\r'); break;
        case 't': out.push_back('\t'); break;
        case 'u': {
          std::uint32_t cp = hex4();
          if (cp >= 0xD800 && cp <= 0xDBFF && pos_ + 1 < s_.size() && s_[pos_] == '\\' &&
              s_[pos_ + 1] == 'u') {
            std::size_t save = pos_;
            pos_ += 2;
            std::uint32_t lo = hex4();
            if (lo >= 0xDC00 && lo <= 0xDFFF)
              cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            else
              pos_ = save;
          }
          append_utf8(out, cp);
          break;
        }
        default: fail("bad escape in string");
      }
    }
    Token t = make(Tok::String, start);
    t.text = std::move(out);
    return t;
  }

  std::string_view s_;
  std::size_t pos_ = 0;
};

const std::map<std::pair<std::string, int>, Builtin>& builtin_table() {
  static const std::map<std::pair<std::string, int>, Builtin> table = {
      {{"empty", 0}, Builtin::Empty},     {{"error", 0}, Builtin::Error0},
      {{"error", 1}, Builtin::Error1},    {{"not", 0}, Builtin::Not},
      {{"length", 0}, Builtin::Length},   {{"keys", 0}, Builtin::Keys},
      {{"has", 1}, Builtin::Has},         {{"type", 0}, Builtin::Type},
      {{"add", 0}, Builtin::Add},         {{"select", 1}, Builtin::Select},
      {{"map", 1}, Builtin::Map},         {{"sort", 0}, Builtin::Sort},
      {{"sort_by", 1}, Builtin::SortBy},  {{"group_by", 1}, Builtin::GroupBy},
      {{"unique", 0}, Builtin::Unique},   {{"reverse", 0}, Builtin::Reverse},
      {{"min", 0}, Builtin::Min},         {{"max", 0}, Builtin::Max},
      {{"tostring", 0}, Builtin::ToString}, {{"tonumber", 0}, Builtin::ToNumber},
  };
  return table;
}

class Parser {
 public:
  explicit Parser(std::string_view src) : toks_(Lexer(src).run()) {}

  Program parse() {
    Program p;
    p.root = parse_pipe();
    if (cur().kind != Tok::End) fail("unexpected token");
    p.var_count = static_cast<int>(vars_.size());
    return p;
  }

 private:
  // ---- token helpers
  const Token& cur() const { return toks_[i_]; }
  const Token& peek() const { return toks_[i_ + 1 < toks_.size() ? i_ + 1 : i_]; }
  void advance() {
    if (i_ + 1 < toks_.size()) ++i_;
  }
  [[noreturn]] void fail(const std::string& msg) const {
    throw ParseError("syntax error: " + msg + " at offset " + std::to_string(cur().pos));
  }
  bool accept(Tok k) {
    if (cur().kind == k) {
      advance();
      return true;
    }
    return false;
  }
  void expect(Tok k, const char* what) {
    if (!accept(k)) fail(std::string("expected ") + what);
  }
  bool is_keyword(const char* kw) const { return cur().kind == Tok::Ident && cur().text == kw; }
  void expect_keyword(const char* kw) {
    if (!is_keyword(kw)) fail(std::string("expected '") + kw + "'");
    advance();
  }
  int intern(const std::string& name) {
    auto it = vars_.find(name);
    if (it != vars_.end()) return it->second;
    int id = static_cast<int>(vars_.size());
    vars_.emplace(name, id);
    return id;
  }

  static NodePtr make(NodeKind k) { return std::make_unique<Node>(k); }
  static NodePtr make2(NodeKind k, NodePtr a, NodePtr b) {
    auto n = make(k);
    n->a = std::move(a);
    n->b = std::move(b);
    return n;
  }
  static NodePtr literal(Value v) {
    auto n = make(NodeKind::Literal);
    n->literal = std::move(v);
    return n;
  }
  static NodePtr field_of_input(const std::string& name) {
    return make2(NodeKind::Index, make(NodeKind::Identity), literal(Value::string(name)));
  }

  // ---- grammar
  NodePtr parse_pipe() {
    if (++depth_ > 3000) fail("expression nested too deeply");
    struct Guard { int& d; ~Guard() { --d; } } guard{depth_};
    if (cur().kind != Tok::Minus) {
      NodePtr first = parse_postfix();
      if (is_keyword("as")) {
        advance();
        if (cur().kind != Tok::Var) fail("expected variable after 'as'");
        int var = intern(cur().text);
        advance();
        expect(Tok::Pipe, "'|' after binding");
        auto n = make(NodeKind::As);
        n->var = var;
        n->a = std::move(first);
        n->b = parse_pipe();
        return n;
      }
      pending_ = std::move(first);
    }
    NodePtr lhs = parse_comma();
    if (accept(Tok::Pipe)) return make2(NodeKind::Pipe, std::move(lhs), parse_pipe());
    return lhs;
  }

  NodePtr parse_comma() {
    NodePtr lhs = parse_or();
    while (accept(Tok::Comma)) lhs = make2(NodeKind::Comma, std::move(lhs), parse_or());
    return lhs;
  }

  NodePtr parse_or() {
    NodePtr lhs = parse_and();
    while (is_keyword("or")) {
      advance();
      lhs = make2(NodeKind::Or, std::move(lhs), parse_and());
    }
    return lhs;
  }

  NodePtr parse_and() {
    NodePtr lhs = parse_cmp();
    while (is_keyword("and")) {
      advance();
      lhs = make2(NodeKind::And, std::move(lhs), parse_cmp());
    }
    return lhs;
  }

  NodePtr binary(BinOp op, NodePtr a, NodePtr b) {
    auto n = make2(NodeKind::Binary, std::move(a), std::move(b));
    n->op = op;
    return n;
  }

  NodePtr parse_cmp() {
    NodePtr lhs = parse_add();
    BinOp op;
    switch (cur().kind) {
      case Tok::Eq: op = BinOp::Eq; break;
      case Tok::Ne: op = BinOp::Ne; break;
      case Tok::Lt: op = BinOp::Lt; break;
      case Tok::Le: op = BinOp::Le; break;
      case Tok::Gt: op = BinOp::Gt; break;
      case Tok::Ge: op = BinOp::Ge; break;
      default: return lhs;
    }
    advance();
    return binary(op, std::move(lhs), parse_add());
  }

  NodePtr parse_add() {
    NodePtr lhs = parse_mul();
    while (cur().kind == Tok::Plus || cur().kind == Tok::Minus) {
      BinOp op = cur().kind == Tok::Plus ? BinOp::Add : BinOp::Sub;
      advance();
      lhs = binary(op, std::move(lhs), parse_mul());
    }
    return lhs;
  }

  NodePtr parse_mul() {
    NodePtr lhs = parse_unary();
    while (cur().kind == Tok::Star || cur().kind == Tok::Slash || cur().kind == Tok::Percent) {
      BinOp op = cur().kind == Tok::Star ? BinOp::Mul
                 : cur().kind == Tok::Slash ? BinOp::Div : BinOp::Mod;
      advance();
      lhs = binary(op, std::move(lhs), parse_unary());
    }
    return lhs;
  }

  NodePtr parse_unary() {
    if (pending_) return std::move(pending_);
    if (accept(Tok::Minus)) {
      auto n = make(NodeKind::Neg);
      n->a = parse_unary();
      return n;
    }
    return parse_postfix();
  }

  bool field_follows(const Token& dot) const {
    const Token& n = peek();
    return (n.kind == Tok::Ident || n.kind == Tok::String) && n.pos == dot.end;
  }

  NodePtr parse_postfix() {
    primary_field_ = false;
    NodePtr node = parse_primary();
    // true right after a field/index/iterate/slice (`.foo` counts)
    bool last_is_suffix = primary_field_;
    primary_field_ = false;
    while (true) {
      switch (cur().kind) {
        case Tok::Dot: {
          const Token dot = cur();
          if (field_follows(dot)) {
            advance();
            node = make2(NodeKind::Index, std::move(node), literal(Value::string(cur().text)));
            advance();
          } else if (peek().kind == Tok::LBracket) {
            advance();
            node = parse_bracket(std::move(node));
          } else {
            return node;
          }
          last_is_suffix = true;
          break;
        }
        case Tok::LBracket:
          node = parse_bracket(std::move(node));
          last_is_suffix = true;
          break;
        case Tok::Question:
          advance();
          if (last_is_suffix && !node->optional) {
            node->optional = true;
          } else {
            auto t = make(NodeKind::Try);
            t->a = std::move(node);
            node = std::move(t);
            last_is_suffix = false;
          }
          break;
        default: return node;
      }
    }
  }

  // Current token is '['.
  NodePtr parse_bracket(NodePtr target) {
    expect(Tok::LBracket, "'['");
    if (accept(Tok::RBracket)) {
      auto n = make(NodeKind::Iterate);
      n->a = std::move(target);
      return n;
    }
    NodePtr from, to;
    bool slice = false;
    if (cur().kind == Tok::Colon) {
      slice = true;
    } else {
      from = parse_pipe();
      if (cur().kind == Tok::Colon) slice = true;
    }
    if (slice) {
      expect(Tok::Colon, "':'");
      if (cur().kind != Tok::RBracket) to = parse_pipe();
      expect(Tok::RBracket, "']'");
      auto n = make(NodeKind::Slice);
      n->a = std::move(target);
      n->b = std::move(from);
      n->c = std::move(to);
      return n;
    }
    expect(Tok::RBracket, "']'");
    return make2(NodeKind::Index, std::move(target), std::move(from));
  }

  NodePtr parse_primary() {
    const Token t = cur();
    switch (t.kind) {
      case Tok::Dot: {
        advance();
        if ((cur().kind == Tok::Ident || cur().kind == Tok::String) && cur().pos == t.end) {
          NodePtr n = field_of_input(cur().text);
          advance();
          primary_field_ = true;
          return n;
        }
        return make(NodeKind::Identity);
      }
      case Tok::Number:
        advance();
        return literal(Value::number(t.num));
      case Tok::String:
        advance();
        return literal(Value::string(t.text));
      case Tok::Var: {
        advance();
        auto n = make(NodeKind::Var);
        n->var = intern(t.text);
        return n;
      }
      case Tok::LParen: {
        advance();
        NodePtr n = parse_pipe();
        expect(Tok::RParen, "')'");
        return n;
      }
      case Tok::LBracket: {
        advance();
        auto n = make(NodeKind::Array);
        if (!accept(Tok::RBracket)) {
          n->a = parse_pipe();
          expect(Tok::RBracket, "']'");
        }
        return n;
      }
      case Tok::LBrace: return parse_object();
      case Tok::Ident: return parse_ident();
      default: fail("unexpected token");
    }
  }

  NodePtr parse_ident() {
    const std::string name = cur().text;
    if (name == "true" || name == "false" || name == "null") {
      advance();
      return literal(name == "null" ? Value::null() : Value::boolean(name == "true"));
    }
    if (name == "if") return parse_if();
    if (name == "reduce") {
      advance();
      auto n = make(NodeKind::Reduce);
      n->a = parse_postfix();
      expect_keyword("as");
      if (cur().kind != Tok::Var) fail("expected variable after 'as'");
      n->var = intern(cur().text);
      advance();
      expect(Tok::LParen, "'('");
      n->b = parse_pipe();
      expect(Tok::Semi, "';'");
      n->c = parse_pipe();
      expect(Tok::RParen, "')'");
      return n;
    }
    advance();
    auto n = make(NodeKind::Call);
    if (accept(Tok::LParen)) {
      n->args.push_back(parse_pipe());
      while (accept(Tok::Semi)) n->args.push_back(parse_pipe());
      expect(Tok::RParen, "')'");
    }
    auto it = builtin_table().find({name, static_cast<int>(n->args.size())});
    if (it == builtin_table().end())
      throw ParseError("unknown function " + name + "/" + std::to_string(n->args.size()));
    n->builtin = it->second;
    return n;
  }

  NodePtr parse_if() {
    advance();  // if
    auto n = make(NodeKind::If);
    n->a = parse_pipe();
    expect_keyword("then");
    n->b = parse_pipe();
    if (is_keyword("elif")) {
      // `elif` is a nested `if`; reuse the same code by pretending it is `if`.
      n->c = parse_if();  // consumes through the shared `end`
      return n;
    }
    if (is_keyword("else")) {
      advance();
      n->c = parse_pipe();
    }
    expect_keyword("end");
    return n;
  }

  NodePtr parse_objterm() {
    if (accept(Tok::Minus)) {
      auto n = make(NodeKind::Neg);
      n->a = parse_objterm();
      return n;
    }
    return parse_postfix();
  }

  NodePtr parse_objval() {
    NodePtr v = parse_objterm();
    while (accept(Tok::Pipe)) v = make2(NodeKind::Pipe, std::move(v), parse_objterm());
    return v;
  }

  NodePtr parse_object() {
    expect(Tok::LBrace, "'{'");
    auto n = make(NodeKind::Object);
    if (accept(Tok::RBrace)) return n;
    while (true) {
      ObjEntry e;
      const Token t = cur();
      if (t.kind == Tok::Ident || t.kind == Tok::String) {
        advance();
        e.literal_key = t.text;
        e.value = accept(Tok::Colon) ? parse_objval() : field_of_input(t.text);
      } else if (t.kind == Tok::Var) {
        advance();
        e.literal_key = t.text;
        auto v = make(NodeKind::Var);
        v->var = intern(t.text);
        e.value = std::move(v);
      } else if (t.kind == Tok::LParen) {
        advance();
        e.key = parse_pipe();
        expect(Tok::RParen, "')'");
        expect(Tok::Colon, "':'");
        e.value = parse_objval();
      } else {
        fail("bad object entry");
      }
      n->entries.push_back(std::move(e));
      if (accept(Tok::Comma)) continue;
      expect(Tok::RBrace, "'}'");
      return n;
    }
  }

  std::vector<Token> toks_;
  std::size_t i_ = 0;
  int depth_ = 0;
  bool primary_field_ = false;  // parse_primary just produced `.name`
  NodePtr pending_;  // an already-parsed postfix term waiting to be the leftmost operand
  std::map<std::string, int> vars_;
};

}  // namespace

Program parse_program(std::string_view source) { return Parser(source).parse(); }

}  // namespace jq::detail
