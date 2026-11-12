#include "kiln/parser.hpp"

#include <unordered_set>

#include "kiln/error.hpp"
#include "kiln/lexer.hpp"

namespace kiln {

namespace {

const std::unordered_set<std::string_view>& reservedWords() {
  static const std::unordered_set<std::string_view> words = {
      "abort", "after", "cmd",  "cost",    "default", "depfile", "each",
      "elsewhen", "false", "in", "include", "let",    "otherwise", "out",
      "phony", "rule",  "set",  "step",    "true",    "use",     "when"};
  return words;
}

ExprPtr makeConst(Value v) {
  auto e = std::make_unique<Expr>();
  e->kind = ExprKind::Const;
  e->value = std::move(v);
  return e;
}

class ExprParser {
 public:
  ExprParser(const std::vector<Token>& toks, std::size_t pos, std::size_t end)
      : t_(toks), pos_(pos), end_(end) {}

  std::size_t position() const noexcept { return pos_; }

  /// expr = pipe_expr
  ExprPtr parseExpr() { return parsePipe(); }

  /// Parses a comma separated list up to and including `close`; `(` or `[` has
  /// already been consumed.
  std::vector<ExprPtr> parseSequence(std::string_view close) {
    std::vector<ExprPtr> items;
    if (isSym(close)) {
      ++pos_;
      return items;
    }
    while (true) {
      items.push_back(parseExpr());
      if (isSym(",")) {
        ++pos_;
        if (isSym(close)) {
          ++pos_;
          break;
        }
        continue;
      }
      if (isSym(close)) {
        ++pos_;
        break;
      }
      throw SyntaxError{};
    }
    return items;
  }

  bool isSym(std::string_view s) const noexcept {
    return pos_ < end_ && t_[pos_].isSym(s);
  }

 private:
  const Token* cur() const noexcept { return pos_ < end_ ? &t_[pos_] : nullptr; }

  ExprPtr parsePipe() {
    ExprPtr lhs = parseBinary(0);
    while (isSym("|>")) {
      ++pos_;
      const Token* name = cur();
      if (!name || name->kind != Token::Ident) throw SyntaxError{};
      ++pos_;
      auto call = std::make_unique<Expr>();
      call->kind = ExprKind::Call;
      call->name = name->text;
      call->kids.push_back(std::move(lhs));
      if (isSym("(")) {
        ++pos_;
        for (auto& a : parseSequence(")")) call->kids.push_back(std::move(a));
      }
      lhs = std::move(call);
    }
    return lhs;
  }

  static constexpr int kUnaryLevel = 7;

  // Returns true and sets `op` if the current token is a binary operator of `level`.
  bool matchOp(int level, Op& op) const {
    const Token* t = cur();
    if (!t || t->kind != Token::Sym) return false;
    const std::string& s = t->text;
    switch (level) {
      case 0: if (s == "||") { op = Op::Or; return true; } break;
      case 1: if (s == "&&") { op = Op::And; return true; } break;
      case 2:
        if (s == "==") { op = Op::Eq; return true; }
        if (s == "!=") { op = Op::Ne; return true; }
        if (s == "<") { op = Op::Lt; return true; }
        if (s == "<=") { op = Op::Le; return true; }
        if (s == ">") { op = Op::Gt; return true; }
        if (s == ">=") { op = Op::Ge; return true; }
        break;
      case 3: if (s == "++") { op = Op::Concat; return true; } break;
      case 4: if (s == "~") { op = Op::Tilde; return true; } break;
      case 5:
        if (s == "+") { op = Op::Add; return true; }
        if (s == "-") { op = Op::Sub; return true; }
        break;
      case 6:
        if (s == "*") { op = Op::Mul; return true; }
        if (s == "/") { op = Op::Div; return true; }
        if (s == "%") { op = Op::Mod; return true; }
        break;
      default: break;
    }
    return false;
  }

  ExprPtr parseBinary(int level) {
    if (level == kUnaryLevel) return parseUnary();
    ExprPtr lhs = parseBinary(level + 1);
    Op op;
    while (matchOp(level, op)) {
      ++pos_;
      ExprPtr rhs = parseBinary(level + 1);
      auto e = std::make_unique<Expr>();
      e->kind = ExprKind::Binary;
      e->op = op;
      e->kids.push_back(std::move(lhs));
      e->kids.push_back(std::move(rhs));
      lhs = std::move(e);
    }
    return lhs;
  }

  ExprPtr parseUnary() {
    const Token* t = cur();
    if (t && t->kind == Token::Sym && (t->text == "!" || t->text == "-")) {
      ++pos_;
      auto e = std::make_unique<Expr>();
      e->kind = ExprKind::Unary;
      e->op = t->text == "!" ? Op::Not : Op::Neg;
      e->kids.push_back(parseUnary());
      return e;
    }
    return parsePostfix();
  }

  ExprPtr parsePostfix() {
    ExprPtr e = parsePrimary();
    while (isSym("[")) {
      ++pos_;
      ExprPtr idx = parseExpr();
      if (!isSym("]")) throw SyntaxError{};
      ++pos_;
      auto n = std::make_unique<Expr>();
      n->kind = ExprKind::Index;
      n->kids.push_back(std::move(e));
      n->kids.push_back(std::move(idx));
      e = std::move(n);
    }
    return e;
  }

  ExprPtr parsePrimary();

  const std::vector<Token>& t_;
  std::size_t pos_;
  std::size_t end_;
};

// Parses the raw content of a double-quoted literal.
ExprPtr parseDoubleQuoted(std::string_view raw) {
  std::vector<StrPart> parts;
  std::string lit;
  auto flush = [&] {
    if (!lit.empty()) {
      StrPart p;
      p.literal = std::move(lit);
      parts.push_back(std::move(p));
      lit.clear();
    }
  };
  std::size_t i = 0;
  while (i < raw.size()) {
    char c = raw[i];
    if (c == '\\') {
      if (i + 1 >= raw.size()) throw SyntaxError{};
      switch (raw[i + 1]) {
        case '\\': lit += '\\'; break;
        case '"': lit += '"'; break;
        case 'n': lit += '\n'; break;
        case 't': lit += '\t'; break;
        case 'r': lit += '\r'; break;
        case '0': lit += '\0'; break;
        default: throw SyntaxError{};
      }
      i += 2;
    } else if (c == '{') {
      if (i + 1 < raw.size() && raw[i + 1] == '{') {
        lit += '{';
        i += 2;
      } else {
        std::size_t after = skipInterpolation(raw, i + 1);
        std::string_view body = raw.substr(i + 1, after - 1 - (i + 1));
        std::vector<Token> toks = tokenize(body);
        if (toks.empty()) throw SyntaxError{};
        ExprParser p(toks, 0, toks.size());
        ExprPtr e = p.parseExpr();
        if (p.position() != toks.size()) throw SyntaxError{};
        flush();
        StrPart part;
        part.expr = std::move(e);
        parts.push_back(std::move(part));
        i = after;
      }
    } else if (c == '}') {
      if (i + 1 < raw.size() && raw[i + 1] == '}') {
        lit += '}';
        i += 2;
      } else {
        throw SyntaxError{};
      }
    } else {
      lit += c;
      ++i;
    }
  }
  if (parts.empty()) return makeConst(Value::string(std::move(lit)));
  flush();
  bool pure = true;
  for (auto& p : parts)
    if (p.expr) pure = false;
  if (pure && parts.size() == 1) return makeConst(Value::string(std::move(parts[0].literal)));
  auto e = std::make_unique<Expr>();
  e->kind = ExprKind::Interp;
  e->parts = std::move(parts);
  return e;
}

ExprPtr parseSingleQuoted(std::string_view raw) {
  std::string s;
  for (std::size_t i = 0; i < raw.size(); ++i) {
    s += raw[i];
    if (raw[i] == '\'' && i + 1 < raw.size() && raw[i + 1] == '\'') ++i;
  }
  return makeConst(Value::string(std::move(s)));
}

ExprPtr ExprParser::parsePrimary() {
  const Token* t = cur();
  if (!t) throw SyntaxError{};
  switch (t->kind) {
    case Token::Int: {
      ++pos_;
      std::uint64_t v = 0;
      for (char c : t->text) v = v * 10 + static_cast<std::uint64_t>(c - '0');
      return makeConst(Value::integer(static_cast<std::int64_t>(v)));
    }
    case Token::Str:
      ++pos_;
      return t->doubleQuoted ? parseDoubleQuoted(t->text) : parseSingleQuoted(t->text);
    case Token::Ident: {
      bool call = pos_ + 1 < end_ && t_[pos_ + 1].isSym("(");
      if (call) {
        pos_ += 2;
        auto e = std::make_unique<Expr>();
        e->kind = ExprKind::Call;
        e->name = t->text;
        e->kids = parseSequence(")");
        return e;
      }
      ++pos_;
      if (t->text == "true") return makeConst(Value::boolean(true));
      if (t->text == "false") return makeConst(Value::boolean(false));
      if (isReservedWord(t->text)) throw SyntaxError{};
      auto e = std::make_unique<Expr>();
      e->kind = ExprKind::Var;
      e->name = t->text;
      return e;
    }
    case Token::Sym:
      if (t->text == "(") {
        ++pos_;
        ExprPtr e = parseExpr();
        if (!isSym(")")) throw SyntaxError{};
        ++pos_;
        return e;
      }
      if (t->text == "[") {
        ++pos_;
        auto e = std::make_unique<Expr>();
        e->kind = ExprKind::List;
        e->kids = parseSequence("]");
        return e;
      }
      throw SyntaxError{};
  }
  throw SyntaxError{};
}

// Parses tokens [from, to) as exactly one expression.
ExprPtr parseWholeExpr(const std::vector<Token>& t, std::size_t from, std::size_t to) {
  if (from >= to) throw SyntaxError{};
  ExprParser p(t, from, to);
  ExprPtr e = p.parseExpr();
  if (p.position() != to) throw SyntaxError{};
  return e;
}

bool isNameToken(const Token& t) {
  return t.kind == Token::Ident && !isReservedWord(t.text);
}

struct Frame {
  enum Kind { StepBlock, WhenBlock, EachBlock, RuleBlock } kind;
  Stmt* stmt;
  Block* body;
  int headerLine;
  bool hasOtherwise = false;
};

class FileParser {
 public:
  explicit FileParser(ParsedFile& file) : file_(file) {}

  void handle(const LogicalLine& ll) {
    const auto& t = ll.tokens;
    if (t[0].isSym("}")) {
      terminator(ll);
    } else if (t.back().isSym("{")) {
      header(ll);
    } else if (!stack_.empty() && stack_.back().kind == Frame::StepBlock) {
      stepField(t);
    } else {
      simple(t);
    }
  }

  void finish() {
    if (!stack_.empty()) {
      throw Error("E_PARSE", file_.path + ":" + std::to_string(stack_.back().headerLine));
    }
  }

 private:
  Block& current() { return stack_.empty() ? file_.statements : *stack_.back().body; }

  Stmt* add(Stmt::Kind k) {
    auto s = std::make_unique<Stmt>();
    s->kind = k;
    Stmt* raw = s.get();
    current().push_back(std::move(s));
    return raw;
  }

  void terminator(const LogicalLine& ll) {
    const auto& t = ll.tokens;
    if (stack_.empty()) throw SyntaxError{};
    if (t.size() == 1) {
      stack_.pop_back();
      return;
    }
    Frame& f = stack_.back();
    if (f.kind != Frame::WhenBlock || f.hasOtherwise) throw SyntaxError{};
    if (!t.back().isSym("{") || t[1].kind != Token::Ident) throw SyntaxError{};
    if (t[1].isIdent("otherwise")) {
      if (t.size() != 3) throw SyntaxError{};
      f.stmt->branches.emplace_back();
      f.body = &f.stmt->branches.back().body;
      f.hasOtherwise = true;
      f.headerLine = ll.line;
    } else if (t[1].isIdent("elsewhen")) {
      if (t.size() < 4) throw SyntaxError{};
      ExprPtr cond = parseWholeExpr(t, 2, t.size() - 1);
      f.stmt->branches.emplace_back();
      f.stmt->branches.back().cond = std::move(cond);
      f.body = &f.stmt->branches.back().body;
      f.headerLine = ll.line;
    } else {
      throw SyntaxError{};
    }
  }

  void header(const LogicalLine& ll) {
    const auto& t = ll.tokens;
    const std::size_t n = t.size();
    if (!stack_.empty() && stack_.back().kind == Frame::StepBlock) throw SyntaxError{};
    if (t[0].isIdent("step")) {
      if (n != 2) throw SyntaxError{};
      Stmt* s = add(Stmt::Step);
      stack_.push_back({Frame::StepBlock, s, nullptr, ll.line});
    } else if (t[0].isIdent("when")) {
      ExprPtr cond = parseWholeExpr(t, 1, n - 1);
      Stmt* s = add(Stmt::When);
      s->branches.emplace_back();
      s->branches.back().cond = std::move(cond);
      stack_.push_back({Frame::WhenBlock, s, &s->branches.back().body, ll.line});
    } else if (t[0].isIdent("each")) {
      std::size_t i = 1;
      if (i >= n || !isNameToken(t[i])) throw SyntaxError{};
      std::string first = t[i++].text;
      std::string second;
      bool two = false;
      if (i < n && t[i].isSym(",")) {
        ++i;
        if (i >= n || !isNameToken(t[i])) throw SyntaxError{};
        second = t[i++].text;
        two = true;
      }
      if (i >= n || !t[i].isIdent("in")) throw SyntaxError{};
      ++i;
      if (two && first == second) throw SyntaxError{};
      ExprPtr subject = parseWholeExpr(t, i, n - 1);
      Stmt* s = add(Stmt::Each);
      if (two) {
        s->indexName = first;
        s->name = second;
      } else {
        s->name = first;
      }
      s->expr = std::move(subject);
      stack_.push_back({Frame::EachBlock, s, &s->body, ll.line});
    } else if (t[0].isIdent("rule")) {
      if (n < 5 || !isNameToken(t[1]) || !t[2].isSym("(") || !t[n - 2].isSym(")"))
        throw SyntaxError{};
      std::vector<Param> params;
      std::size_t i = 3;
      const std::size_t end = n - 2;
      bool sawDefault = false;
      while (i < end) {
        if (!isNameToken(t[i])) throw SyntaxError{};
        Param p;
        p.name = t[i++].text;
        for (const auto& q : params)
          if (q.name == p.name) throw SyntaxError{};
        if (i < end && t[i].isSym("=")) {
          ++i;
          ExprParser ep(t, i, end);
          p.defaultValue = ep.parseExpr();
          i = ep.position();
          sawDefault = true;
        } else if (sawDefault) {
          throw SyntaxError{};
        }
        params.push_back(std::move(p));
        if (i < end) {
          if (!t[i].isSym(",")) throw SyntaxError{};
          ++i;
        }
      }
      Stmt* s = add(Stmt::Rule);
      s->name = t[1].text;
      s->params = std::move(params);
      stack_.push_back({Frame::RuleBlock, s, &s->body, ll.line});
    } else {
      throw SyntaxError{};
    }
  }

  void stepField(const std::vector<Token>& t) {
    Stmt* step = stack_.back().stmt;
    const Token& k = t[0];
    StepField f;
    if (k.kind != Token::Ident) throw SyntaxError{};
    if (k.text == "out") f.kind = StepField::Out;
    else if (k.text == "in") f.kind = StepField::In;
    else if (k.text == "after") f.kind = StepField::After;
    else if (k.text == "cost") f.kind = StepField::Cost;
    else if (k.text == "depfile") f.kind = StepField::Depfile;
    else if (k.text == "cmd") f.kind = StepField::Cmd;
    else throw SyntaxError{};
    if (f.kind == StepField::Cmd) {
      if (t.size() < 4 || t[1].kind != Token::Ident || !t[2].isSym("(") ||
          !t.back().isSym(")"))
        throw SyntaxError{};
      f.cmdName = t[1].text;
      ExprParser p(t, 3, t.size());
      f.cmdArgs = p.parseSequence(")");
      if (p.position() != t.size()) throw SyntaxError{};
    } else {
      f.expr = parseWholeExpr(t, 1, t.size());
    }
    step->fields.push_back(std::move(f));
  }

  void simple(const std::vector<Token>& t) {
    const std::size_t n = t.size();
    const Token& k = t[0];
    if (k.kind != Token::Ident) throw SyntaxError{};
    const std::string& w = k.text;
    if (w == "let" || w == "set" || w == "phony") {
      if (n < 4 || !isNameToken(t[1]) || !t[2].isSym("=")) throw SyntaxError{};
      ExprPtr e = parseWholeExpr(t, 3, n);
      Stmt* s = add(w == "let" ? Stmt::Let : (w == "set" ? Stmt::Set : Stmt::Phony));
      s->name = t[1].text;
      s->expr = std::move(e);
    } else if (w == "include" || w == "abort" || w == "default") {
      ExprPtr e = parseWholeExpr(t, 1, n);
      Stmt* s = add(w == "include" ? Stmt::Include : (w == "abort" ? Stmt::Abort : Stmt::Default));
      s->expr = std::move(e);
    } else if (w == "use") {
      if (n < 4 || t[1].kind != Token::Ident || !t[2].isSym("(") || !t[n - 1].isSym(")"))
        throw SyntaxError{};
      std::vector<UseArg> args;
      std::size_t i = 3;
      const std::size_t end = n - 1;
      bool sawKeyword = false;
      while (i < end) {
        UseArg a;
        if (isNameToken(t[i]) && i + 1 < end && t[i + 1].isSym("=")) {
          a.keyword = t[i].text;
          i += 2;
          sawKeyword = true;
        } else if (sawKeyword) {
          throw SyntaxError{};
        }
        ExprParser ep(t, i, end);
        a.expr = ep.parseExpr();
        i = ep.position();
        args.push_back(std::move(a));
        if (i < end) {
          if (!t[i].isSym(",")) throw SyntaxError{};
          ++i;
        }
      }
      Stmt* s = add(Stmt::Use);
      s->name = t[1].text;
      s->args = std::move(args);
    } else {
      throw SyntaxError{};
    }
  }

  ParsedFile& file_;
  std::vector<Frame> stack_;
};

}  // namespace

bool isReservedWord(std::string_view word) noexcept {
  return reservedWords().count(word) != 0;
}

std::unique_ptr<ParsedFile> parseBuildFile(std::string_view source, const std::string& path) {
  std::vector<LogicalLine> lines = lexBuildFile(source, path);
  auto file = std::make_unique<ParsedFile>();
  file->path = path;
  FileParser parser(*file);
  for (const auto& ll : lines) {
    try {
      parser.handle(ll);
    } catch (const SyntaxError&) {
      throw Error("E_PARSE", path + ":" + std::to_string(ll.line));
    }
  }
  parser.finish();
  return file;
}

}  // namespace kiln
