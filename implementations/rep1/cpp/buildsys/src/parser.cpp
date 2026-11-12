#include "kiln/parser.hpp"

#include "kiln/error.hpp"
#include "kiln/lexer.hpp"

namespace kiln {

const char* op_spelling(BinaryOp op) {
  switch (op) {
    case BinaryOp::Or: return "||";
    case BinaryOp::And: return "&&";
    case BinaryOp::Eq: return "==";
    case BinaryOp::Ne: return "!=";
    case BinaryOp::Lt: return "<";
    case BinaryOp::Le: return "<=";
    case BinaryOp::Gt: return ">";
    case BinaryOp::Ge: return ">=";
    case BinaryOp::ListConcat: return "++";
    case BinaryOp::StrConcat: return "~";
    case BinaryOp::Add: return "+";
    case BinaryOp::Sub: return "-";
    case BinaryOp::Mul: return "*";
    case BinaryOp::Div: return "/";
    case BinaryOp::Mod: return "%";
  }
  return "?";
}

const char* op_spelling(UnaryOp op) { return op == UnaryOp::Not ? "!" : "-"; }

namespace {

using Tokens = std::vector<Token>;

/// A cursor over a token vector with a one-past-the-end limit.
class Cursor {
 public:
  Cursor(const Tokens& t, std::size_t begin, std::size_t end) : t_(t), i_(begin), end_(end) {}
  explicit Cursor(const Tokens& t) : Cursor(t, 0, t.size()) {}

  bool done() const { return i_ >= end_; }
  const Token& peek(std::size_t ahead = 0) const {
    if (i_ + ahead >= end_) throw SyntaxError{};
    return t_[i_ + ahead];
  }
  bool has(std::size_t ahead = 0) const { return i_ + ahead < end_; }
  const Token& next() {
    const Token& t = peek();
    ++i_;
    return t;
  }
  bool at_punct(std::string_view s, std::size_t ahead = 0) const {
    return has(ahead) && t_[i_ + ahead].is_punct(s);
  }
  bool at_op(std::string_view s) const { return has() && t_[i_].is_op(s); }
  void expect_punct(std::string_view s) {
    if (!at_punct(s)) throw SyntaxError{};
    ++i_;
  }
  void expect_done() const {
    if (!done()) throw SyntaxError{};
  }

 private:
  const Tokens& t_;
  std::size_t i_;
  std::size_t end_;
};

ExprPtr make_expr(Expr::Kind k) {
  auto e = std::make_unique<Expr>();
  e->kind = k;
  return e;
}

ExprPtr parse_expr(Cursor& c);

ExprPtr parse_string_literal(const std::string& raw);

/// Parses `expr { , expr } [ , ]` up to and including the closing ')'.
std::vector<ExprPtr> parse_call_args(Cursor& c) {
  std::vector<ExprPtr> args;
  c.expect_punct("(");
  while (!c.at_punct(")")) {
    args.push_back(parse_expr(c));
    if (c.at_punct(",")) {
      c.next();
    } else if (!c.at_punct(")")) {
      throw SyntaxError{};
    }
  }
  c.next();
  return args;
}

ExprPtr parse_primary(Cursor& c) {
  const Token& t = c.next();
  switch (t.kind) {
    case TokenKind::Int: {
      auto e = make_expr(Expr::Kind::Literal);
      e->literal = Value::integer(t.int_value);
      return e;
    }
    case TokenKind::Str: return parse_string_literal(t.text);
    case TokenKind::Ident: {
      if (c.at_punct("(")) {  // a call; the name may be any identifier
        auto e = make_expr(Expr::Kind::Call);
        e->name = t.text;
        e->args = parse_call_args(c);
        return e;
      }
      if (t.text == "true" || t.text == "false") {
        auto e = make_expr(Expr::Kind::Literal);
        e->literal = Value::boolean(t.text == "true");
        return e;
      }
      if (is_reserved_word(t.text)) throw SyntaxError{};
      auto e = make_expr(Expr::Kind::Var);
      e->name = t.text;
      return e;
    }
    case TokenKind::Punct: {
      if (t.text == "(") {
        auto e = parse_expr(c);
        c.expect_punct(")");
        return e;
      }
      if (t.text == "[") {
        auto e = make_expr(Expr::Kind::List);
        while (!c.at_punct("]")) {
          e->args.push_back(parse_expr(c));
          if (c.at_punct(",")) {
            c.next();
          } else if (!c.at_punct("]")) {
            throw SyntaxError{};
          }
        }
        c.next();
        return e;
      }
      throw SyntaxError{};
    }
    case TokenKind::Op: throw SyntaxError{};
  }
  throw SyntaxError{};
}

ExprPtr parse_postfix(Cursor& c) {
  ExprPtr e = parse_primary(c);
  while (true) {
    if (c.at_punct("[")) {
      c.next();
      auto idx = make_expr(Expr::Kind::Index);
      idx->args.push_back(std::move(e));
      idx->args.push_back(parse_expr(c));
      c.expect_punct("]");
      e = std::move(idx);
    } else if (c.at_punct("(")) {
      throw SyntaxError{};  // calls apply only to a bare identifier, handled in parse_primary
    } else {
      return e;
    }
  }
}

ExprPtr parse_unary(Cursor& c) {
  if (c.at_op("!") || c.at_op("-")) {
    auto e = make_expr(Expr::Kind::Unary);
    e->unary_op = c.next().text == "!" ? UnaryOp::Not : UnaryOp::Neg;
    e->args.push_back(parse_unary(c));
    return e;
  }
  return parse_postfix(c);
}

struct OpSpec {
  const char* text;
  BinaryOp op;
};

template <std::size_t N, typename Next>
ExprPtr parse_binary_level(Cursor& c, const OpSpec (&ops)[N], Next next) {
  ExprPtr left = next(c);
  while (true) {
    const OpSpec* found = nullptr;
    for (const auto& o : ops) {
      if (c.at_op(o.text)) {
        found = &o;
        break;
      }
    }
    if (!found) return left;
    c.next();
    auto e = make_expr(Expr::Kind::Binary);
    e->binary_op = found->op;
    e->args.push_back(std::move(left));
    e->args.push_back(next(c));
    left = std::move(e);
  }
}

ExprPtr parse_mul(Cursor& c) {
  static const OpSpec ops[] = {{"*", BinaryOp::Mul}, {"/", BinaryOp::Div}, {"%", BinaryOp::Mod}};
  return parse_binary_level(c, ops, parse_unary);
}
ExprPtr parse_add(Cursor& c) {
  static const OpSpec ops[] = {{"+", BinaryOp::Add}, {"-", BinaryOp::Sub}};
  return parse_binary_level(c, ops, parse_mul);
}
ExprPtr parse_str_concat(Cursor& c) {
  static const OpSpec ops[] = {{"~", BinaryOp::StrConcat}};
  return parse_binary_level(c, ops, parse_add);
}
ExprPtr parse_list_concat(Cursor& c) {
  static const OpSpec ops[] = {{"++", BinaryOp::ListConcat}};
  return parse_binary_level(c, ops, parse_str_concat);
}
ExprPtr parse_cmp(Cursor& c) {
  static const OpSpec ops[] = {{"==", BinaryOp::Eq}, {"!=", BinaryOp::Ne}, {"<=", BinaryOp::Le},
                               {">=", BinaryOp::Ge}, {"<", BinaryOp::Lt},  {">", BinaryOp::Gt}};
  return parse_binary_level(c, ops, parse_list_concat);
}
ExprPtr parse_and(Cursor& c) {
  static const OpSpec ops[] = {{"&&", BinaryOp::And}};
  return parse_binary_level(c, ops, parse_cmp);
}
ExprPtr parse_or(Cursor& c) {
  static const OpSpec ops[] = {{"||", BinaryOp::Or}};
  return parse_binary_level(c, ops, parse_and);
}

ExprPtr parse_expr(Cursor& c) {
  ExprPtr left = parse_or(c);
  while (c.at_op("|>")) {
    c.next();
    const Token& target = c.next();
    if (target.kind != TokenKind::Ident) throw SyntaxError{};
    auto call = make_expr(Expr::Kind::Call);
    call->name = target.text;
    call->args.push_back(std::move(left));
    if (c.at_punct("(")) {
      for (auto& a : parse_call_args(c)) call->args.push_back(std::move(a));
    }
    left = std::move(call);
  }
  return left;
}

/// Parses a complete expression from a token vector (all tokens consumed).
ExprPtr parse_whole_expr(const Tokens& toks) {
  Cursor c(toks);
  ExprPtr e = parse_expr(c);
  c.expect_done();
  return e;
}

ExprPtr parse_string_literal(const std::string& raw) {
  auto lit = make_expr(Expr::Kind::Literal);
  if (raw[0] == '\'') {
    std::string out;
    for (std::size_t i = 1; i + 1 < raw.size(); ++i) {
      out.push_back(raw[i]);
      if (raw[i] == '\'') ++i;  // '' denotes one '
    }
    lit->literal = Value::string(std::move(out));
    return lit;
  }
  std::string_view body(raw);
  body = body.substr(1, body.size() - 2);
  std::vector<InterpPart> parts;
  std::string cur;
  bool interpolated = false;
  for (std::size_t i = 0; i < body.size();) {
    char ch = body[i];
    if (ch == '\\') {
      char n = body[i + 1];
      switch (n) {
        case '\\': cur.push_back('\\'); break;
        case '"': cur.push_back('"'); break;
        case 'n': cur.push_back('\n'); break;
        case 't': cur.push_back('\t'); break;
        case 'r': cur.push_back('\r'); break;
        case '0': cur.push_back('\0'); break;
        default: throw SyntaxError{};
      }
      i += 2;
    } else if (ch == '{') {
      if (i + 1 < body.size() && body[i + 1] == '{') {
        cur.push_back('{');
        i += 2;
        continue;
      }
      std::size_t end = scan_interpolation(body, i);
      if (end == std::string_view::npos) throw SyntaxError{};
      Tokens toks = tokenize(body.substr(i + 1, end - i - 1));
      if (toks.empty()) throw SyntaxError{};
      InterpPart lit_part;
      lit_part.literal = std::move(cur);
      cur.clear();
      parts.push_back(std::move(lit_part));
      InterpPart expr_part;
      expr_part.expr = parse_whole_expr(toks);
      parts.push_back(std::move(expr_part));
      interpolated = true;
      i = end + 1;
    } else if (ch == '}') {
      if (i + 1 < body.size() && body[i + 1] == '}') {
        cur.push_back('}');
        i += 2;
      } else {
        throw SyntaxError{};
      }
    } else {
      cur.push_back(ch);
      ++i;
    }
  }
  if (!interpolated) {
    lit->literal = Value::string(std::move(cur));
    return lit;
  }
  InterpPart tail;
  tail.literal = std::move(cur);
  parts.push_back(std::move(tail));
  auto e = make_expr(Expr::Kind::Interp);
  e->parts = std::move(parts);
  return e;
}

// ---------------------------------------------------------------------------
// Statements

const std::string& expect_name(Cursor& c) {
  const Token& t = c.next();
  if (t.kind != TokenKind::Ident || is_reserved_word(t.text)) throw SyntaxError{};
  return t.text;
}

/// Parses `IDENT = expr` forms; `c` is positioned after the keyword.
StmtPtr parse_binding(Stmt::Kind kind, Cursor& c) {
  auto s = std::make_unique<Stmt>();
  s->kind = kind;
  s->name = expect_name(c);
  c.expect_punct("=");
  s->expr = parse_expr(c);
  c.expect_done();
  return s;
}

StmtPtr parse_use(Cursor& c) {
  auto s = std::make_unique<Stmt>();
  s->kind = Stmt::Kind::Use;
  const Token& name = c.next();
  if (name.kind != TokenKind::Ident) throw SyntaxError{};  // reserved words allowed: E_UNKNOWN_RULE later
  s->name = name.text;
  c.expect_punct("(");
  while (!c.at_punct(")")) {
    const Token& first = c.peek();
    bool is_kw = first.kind == TokenKind::Ident && !is_reserved_word(first.text) && c.at_punct("=", 1);
    if (is_kw) {
      KeywordArg kw;
      kw.name = c.next().text;
      c.next();  // '='
      kw.value = parse_expr(c);
      s->keywords.push_back(std::move(kw));
    } else {
      if (!s->keywords.empty()) throw SyntaxError{};
      s->positional.push_back(parse_expr(c));
    }
    if (c.at_punct(",")) {
      c.next();
    } else if (!c.at_punct(")")) {
      throw SyntaxError{};
    }
  }
  c.next();
  c.expect_done();
  return s;
}

StepField parse_step_field(const Token& keyword, Cursor& c) {
  StepField f;
  const std::string& k = keyword.text;
  if (k == "cmd") {
    f.kind = StepField::Kind::Cmd;
    const Token& name = c.next();
    if (name.kind != TokenKind::Ident) throw SyntaxError{};
    f.command = name.text;
    f.args = parse_call_args(c);
    c.expect_done();
    return f;
  }
  if (k == "out") f.kind = StepField::Kind::Out;
  else if (k == "in") f.kind = StepField::Kind::In;
  else if (k == "after") f.kind = StepField::Kind::After;
  else if (k == "cost") f.kind = StepField::Kind::Cost;
  else if (k == "depfile") f.kind = StepField::Kind::Depfile;
  else throw SyntaxError{};
  f.expr = parse_expr(c);
  c.expect_done();
  return f;
}

struct Frame {
  enum class Kind { Top, When, Each, Rule, Step } kind = Kind::Top;
  StmtPtr stmt;
  Block body;
  ExprPtr cond;           // When: condition of the branch being collected
  bool in_otherwise = false;
  int line = 0;           // header line (updated by elsewhen/otherwise)
};

class Parser {
 public:
  explicit Parser(std::string_view file) : file_(file) { stack_.emplace_back(); }

  void feed(const LogicalLine& ll) {
    try {
      handle(ll.tokens);
    } catch (const SyntaxError&) {
      fail(ll.line);
    }
  }

  Block finish() {
    if (stack_.size() > 1) fail(stack_.back().line);
    return std::move(stack_.front().body);
  }

 private:
  [[noreturn]] void fail(int line) const {
    throw Error(ErrorKind::Parse, std::string(file_) + ":" + std::to_string(line));
  }

  Frame& top() { return stack_.back(); }

  void handle(const Tokens& toks) {
    if (toks[0].is_punct("}")) return terminator(toks);
    if (toks.back().is_punct("{")) return header(toks);
    simple(toks);
  }

  void add(StmtPtr s) { top().body.push_back(std::move(s)); }

  void simple(const Tokens& toks) {
    Cursor c(toks);
    const Token& kw = c.next();
    if (top().kind == Frame::Kind::Step) {
      top().stmt->fields.push_back(parse_step_field(kw, c));
      return;
    }
    if (kw.kind != TokenKind::Ident) throw SyntaxError{};
    const std::string& k = kw.text;
    if (k == "let") return add(parse_binding(Stmt::Kind::Let, c));
    if (k == "set") return add(parse_binding(Stmt::Kind::Set, c));
    if (k == "phony") return add(parse_binding(Stmt::Kind::Phony, c));
    if (k == "use") return add(parse_use(c));
    Stmt::Kind kind;
    if (k == "include") kind = Stmt::Kind::Include;
    else if (k == "abort") kind = Stmt::Kind::Abort;
    else if (k == "default") kind = Stmt::Kind::Default;
    else throw SyntaxError{};
    auto s = std::make_unique<Stmt>();
    s->kind = kind;
    s->expr = parse_expr(c);
    c.expect_done();
    add(std::move(s));
  }

  void header(const Tokens& toks) {
    if (top().kind == Frame::Kind::Step) throw SyntaxError{};
    Cursor c(toks, 0, toks.size() - 1);  // without the trailing '{'
    const Token& kw = c.next();
    if (kw.kind != TokenKind::Ident) throw SyntaxError{};
    Frame f;
    f.line = line_;
    auto s = std::make_unique<Stmt>();
    if (kw.text == "step") {
      c.expect_done();
      s->kind = Stmt::Kind::Step;
      f.kind = Frame::Kind::Step;
    } else if (kw.text == "when") {
      s->kind = Stmt::Kind::When;
      f.kind = Frame::Kind::When;
      f.cond = parse_expr(c);
      c.expect_done();
    } else if (kw.text == "each") {
      s->kind = Stmt::Kind::Each;
      f.kind = Frame::Kind::Each;
      std::string first = expect_name(c);
      if (c.at_punct(",")) {
        c.next();
        std::string second = expect_name(c);
        if (first == second) throw SyntaxError{};
        s->index_name = first;
        s->name = second;
      } else {
        s->name = first;
      }
      if (!c.has() || !c.next().is_ident("in")) throw SyntaxError{};
      s->expr = parse_expr(c);
      c.expect_done();
    } else if (kw.text == "rule") {
      s->kind = Stmt::Kind::Rule;
      f.kind = Frame::Kind::Rule;
      s->name = expect_name(c);
      c.expect_punct("(");
      bool seen_default = false;
      while (!c.at_punct(")")) {
        Param p;
        p.name = expect_name(c);
        for (const auto& q : s->params) {
          if (q.name == p.name) throw SyntaxError{};
        }
        if (c.at_punct("=")) {
          c.next();
          p.default_value = parse_expr(c);
          seen_default = true;
        } else if (seen_default) {
          throw SyntaxError{};
        }
        s->params.push_back(std::move(p));
        if (c.at_punct(",")) {
          c.next();
        } else if (!c.at_punct(")")) {
          throw SyntaxError{};
        }
      }
      c.next();
      c.expect_done();
    } else {
      throw SyntaxError{};
    }
    f.stmt = std::move(s);
    stack_.push_back(std::move(f));
  }

  void close_when_branch(Frame& f) {
    WhenBranch b;
    b.condition = std::move(f.cond);
    b.body = std::move(f.body);
    f.body.clear();
    f.stmt->branches.push_back(std::move(b));
  }

  void terminator(const Tokens& toks) {
    if (stack_.size() < 2) throw SyntaxError{};
    Frame& f = top();
    if (toks.size() == 1) {
      if (f.kind == Frame::Kind::When) {
        if (f.in_otherwise) {
          f.stmt->has_otherwise = true;
          f.stmt->otherwise = std::move(f.body);
        } else {
          close_when_branch(f);
        }
      } else if (f.kind == Frame::Kind::Each || f.kind == Frame::Kind::Rule) {
        f.stmt->body = std::move(f.body);
      }
      StmtPtr done = std::move(f.stmt);
      stack_.pop_back();
      add(std::move(done));
      return;
    }
    if (f.kind != Frame::Kind::When || f.in_otherwise) throw SyntaxError{};
    if (!toks.back().is_punct("{") || toks.size() < 3) throw SyntaxError{};
    if (toks[1].is_ident("otherwise")) {
      if (toks.size() != 3) throw SyntaxError{};
      close_when_branch(f);
      f.in_otherwise = true;
      f.line = line_;
      return;
    }
    if (!toks[1].is_ident("elsewhen")) throw SyntaxError{};
    Cursor c(toks, 2, toks.size() - 1);
    ExprPtr cond = parse_expr(c);
    c.expect_done();
    close_when_branch(f);
    f.cond = std::move(cond);
    f.line = line_;
  }

 public:
  int line_ = 0;

 private:
  std::string_view file_;
  std::vector<Frame> stack_;
};

}  // namespace

std::shared_ptr<Program> parse_program(std::string_view source, std::string_view file) {
  std::vector<LogicalLine> lines = lex(source, file);  // lexical errors first
  Parser parser(file);
  for (const auto& ll : lines) {
    parser.line_ = ll.line;
    parser.feed(ll);
  }
  auto program = std::make_shared<Program>();
  program->path = std::string(file);
  program->statements = parser.finish();
  return program;
}

}  // namespace kiln
