#include "parser.hpp"

#include <algorithm>
#include <cstdint>
#include <set>

#include "sitegen/template.hpp"
#include "sitegen/text.hpp"

namespace sitegen::tmpl {

int SymbolTable::intern(std::string_view name) {
  const auto it = ids_.find(name);
  if (it != ids_.end()) return it->second;
  const int id = static_cast<int>(names_.size());
  names_.emplace_back(name);
  ids_.emplace(std::string(name), id);
  return id;
}

namespace {

[[noreturn]] void syntax_error(const std::string& message) {
  throw TemplateError(TemplateErrorKind::Syntax, "syntax error: " + message);
}

// ---------------------------------------------------------------------------
// Lexing
// ---------------------------------------------------------------------------

struct Token {
  enum class Kind { Name, Int, Float, String, Op };
  Kind kind = Kind::Op;
  std::string text;  // name, string contents or operator
  std::int64_t int_value = 0;
  double float_value = 0;

  bool is_op(std::string_view op) const { return kind == Kind::Op && text == op; }
  bool is_name(std::string_view n) const { return kind == Kind::Name && text == n; }
};

struct Segment {
  enum class Kind { Text, Print, Statement };
  Kind kind = Kind::Text;
  std::string text;
  std::vector<Token> tokens;
};

bool is_name_start(char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
bool is_digit(char c) { return c >= '0' && c <= '9'; }
bool is_name_char(char c) { return is_name_start(c) || is_digit(c); }

bool is_keyword(std::string_view s) {
  return s == "and" || s == "or" || s == "not" || s == "in" || s == "is" || s == "true" ||
         s == "false" || s == "none";
}

class Splitter {
 public:
  explicit Splitter(std::string_view src) : src_(src) {}

  std::vector<Segment> run() {
    const std::size_t n = src_.size();
    std::size_t pos = 0;
    std::size_t text_start = 0;
    while (true) {
      std::size_t open = find_opener(pos);
      if (open == std::string_view::npos) {
        push_text(text_start, n, false);
        break;
      }
      const char type = src_[open + 1];
      std::size_t content = open + 2;
      bool trim_before = false;
      if (content < n && src_[content] == '-') {
        trim_before = true;
        ++content;
      }
      push_text(text_start, open, trim_before);

      if (type == '#') {
        const std::size_t end = src_.find("#}", content);
        if (end == std::string_view::npos) syntax_error("unclosed comment");
        lstrip_next_ = end > content && src_[end - 1] == '-';
        pos = text_start = end + 2;
        continue;
      }
      Segment seg;
      seg.kind = type == '{' ? Segment::Kind::Print : Segment::Kind::Statement;
      bool trim_after = false;
      pos = lex_tag(content, type == '{' ? "}}" : "%}", seg.tokens, trim_after);
      lstrip_next_ = trim_after;
      segments_.push_back(std::move(seg));
      text_start = pos;
    }
    return std::move(segments_);
  }

 private:
  std::size_t find_opener(std::size_t from) const {
    for (std::size_t i = from; i + 1 < src_.size(); ++i) {
      if (src_[i] == '{' && (src_[i + 1] == '{' || src_[i + 1] == '%' || src_[i + 1] == '#')) {
        return i;
      }
    }
    return std::string_view::npos;
  }

  void push_text(std::size_t begin, std::size_t end, bool rstrip) {
    std::string_view t = src_.substr(begin, end - begin);
    if (lstrip_next_) {
      while (!t.empty() && text::is_template_space(t.front())) t.remove_prefix(1);
    }
    if (rstrip) {
      while (!t.empty() && text::is_template_space(t.back())) t.remove_suffix(1);
    }
    lstrip_next_ = false;
    if (t.empty()) return;
    Segment seg;
    seg.kind = Segment::Kind::Text;
    seg.text.assign(t);
    segments_.push_back(std::move(seg));
  }

  /// Tokenizes tag content starting at `p` up to the closer. Returns the
  /// index just after the closer.
  std::size_t lex_tag(std::size_t p, std::string_view closer, std::vector<Token>& out,
                      bool& trim_after) const {
    const std::size_t n = src_.size();
    while (true) {
      while (p < n && text::is_template_space(src_[p])) ++p;
      if (p >= n) syntax_error("unclosed tag");
      if (src_.compare(p, 2, closer) == 0) {
        trim_after = false;
        return p + 2;
      }
      if (src_[p] == '-' && src_.compare(p + 1, 2, closer) == 0) {
        trim_after = true;
        return p + 3;
      }
      const char c = src_[p];
      Token tok;
      if (is_name_start(c)) {
        std::size_t q = p;
        while (q < n && is_name_char(src_[q])) ++q;
        tok.kind = Token::Kind::Name;
        tok.text.assign(src_.substr(p, q - p));
        p = q;
      } else if (is_digit(c)) {
        std::size_t q = p;
        while (q < n && is_digit(src_[q])) ++q;
        if (q + 1 < n && src_[q] == '.' && is_digit(src_[q + 1])) {
          std::size_t r = q + 1;
          while (r < n && is_digit(src_[r])) ++r;
          tok.kind = Token::Kind::Float;
          tok.float_value = std::stod(std::string(src_.substr(p, r - p)));
          p = r;
        } else {
          tok.kind = Token::Kind::Int;
          std::uint64_t v = 0;
          for (std::size_t i = p; i < q; ++i) v = v * 10 + static_cast<unsigned>(src_[i] - '0');
          tok.int_value = static_cast<std::int64_t>(v);
          p = q;
        }
      } else if (c == '"' || c == '\'') {
        tok.kind = Token::Kind::String;
        ++p;
        while (true) {
          if (p >= n) syntax_error("unterminated string");
          const char d = src_[p++];
          if (d == c) break;
          if (d != '\\') {
            tok.text.push_back(d);
            continue;
          }
          if (p >= n) syntax_error("unterminated string");
          const char e = src_[p++];
          switch (e) {
            case '\\': tok.text.push_back('\\'); break;
            case '"': tok.text.push_back('"'); break;
            case '\'': tok.text.push_back('\''); break;
            case 'n': tok.text.push_back('\n'); break;
            case 't': tok.text.push_back('\t'); break;
            default: syntax_error("invalid string escape");
          }
        }
      } else {
        static const char* const kTwo[] = {"**", "//", "==", "!=", "<=", ">="};
        bool matched = false;
        for (const char* op : kTwo) {
          if (src_.compare(p, 2, op) == 0) {
            tok.text = op;
            p += 2;
            matched = true;
            break;
          }
        }
        if (!matched) {
          static const std::string_view kOne = "~+-*/%<>()[],|.=";
          if (kOne.find(c) == std::string_view::npos) syntax_error("unexpected character in tag");
          tok.text.assign(1, c);
          ++p;
        }
        tok.kind = Token::Kind::Op;
      }
      out.push_back(std::move(tok));
    }
  }

  std::string_view src_;
  std::vector<Segment> segments_;
  bool lstrip_next_ = false;
};

// ---------------------------------------------------------------------------
// Expression parsing
// ---------------------------------------------------------------------------

bool filter_from_name(std::string_view name, FilterId& id) {
  static const struct {
    std::string_view name;
    FilterId id;
  } kFilters[] = {{"upper", FilterId::Upper},     {"lower", FilterId::Lower},
                  {"trim", FilterId::Trim},       {"escape", FilterId::Escape},
                  {"replace", FilterId::Replace}, {"length", FilterId::Length},
                  {"int", FilterId::Int},         {"join", FilterId::Join},
                  {"first", FilterId::First},     {"last", FilterId::Last},
                  {"reverse", FilterId::Reverse}, {"sort", FilterId::Sort},
                  {"default", FilterId::Default}};
  for (const auto& f : kFilters) {
    if (f.name == name) {
      id = f.id;
      return true;
    }
  }
  return false;
}

ExprPtr make_expr(ExprKind kind) {
  auto e = std::make_unique<Expr>();
  e->kind = kind;
  return e;
}

class ExprParser {
 public:
  ExprParser(const std::vector<Token>& tokens, std::size_t start, SymbolTable& symbols,
             bool& bad_filter)
      : t_(tokens), i_(start), symbols_(symbols), bad_filter_(bad_filter) {}

  ExprPtr parse_expression() { return parse_or(); }

  bool at_end() const { return i_ >= t_.size(); }
  void expect_end() const {
    if (!at_end()) syntax_error("unexpected token '" + t_[i_].text + "'");
  }
  std::size_t position() const { return i_; }

  // Helpers shared with the statement parser.
  const Token& peek() const {
    if (at_end()) syntax_error("unexpected end of tag");
    return t_[i_];
  }
  const Token& next() {
    const Token& t = peek();
    ++i_;
    return t;
  }
  bool accept_op(std::string_view op) {
    if (!at_end() && t_[i_].is_op(op)) {
      ++i_;
      return true;
    }
    return false;
  }
  void expect_op(std::string_view op) {
    if (!accept_op(op)) syntax_error("expected '" + std::string(op) + "'");
  }

 private:
  bool peek_name(std::string_view n) const { return !at_end() && t_[i_].is_name(n); }

  ExprPtr binary(ExprKind kind, ExprPtr l, ExprPtr r) {
    auto e = make_expr(kind);
    e->args.push_back(std::move(l));
    e->args.push_back(std::move(r));
    return e;
  }
  ExprPtr binop(BinOp op, ExprPtr l, ExprPtr r) {
    auto e = binary(ExprKind::Binary, std::move(l), std::move(r));
    e->bop = op;
    return e;
  }

  ExprPtr parse_or() {
    ExprPtr l = parse_and();
    while (peek_name("or")) {
      ++i_;
      l = binary(ExprKind::Or, std::move(l), parse_and());
    }
    return l;
  }
  ExprPtr parse_and() {
    ExprPtr l = parse_not();
    while (peek_name("and")) {
      ++i_;
      l = binary(ExprKind::And, std::move(l), parse_not());
    }
    return l;
  }
  ExprPtr parse_not() {
    if (peek_name("not")) {
      ++i_;
      auto e = make_expr(ExprKind::Not);
      e->args.push_back(parse_not());
      return e;
    }
    return parse_compare();
  }

  bool accept_cmp_op(CmpOp& op) {
    if (at_end()) return false;
    const Token& t = t_[i_];
    if (t.kind == Token::Kind::Op) {
      static const struct {
        std::string_view text;
        CmpOp op;
      } kOps[] = {{"==", CmpOp::Eq}, {"!=", CmpOp::Ne}, {"<", CmpOp::Lt},
                  {"<=", CmpOp::Le}, {">", CmpOp::Gt},  {">=", CmpOp::Ge}};
      for (const auto& o : kOps) {
        if (t.text == o.text) {
          op = o.op;
          ++i_;
          return true;
        }
      }
      return false;
    }
    if (t.is_name("in")) {
      op = CmpOp::In;
      ++i_;
      return true;
    }
    if (t.is_name("not") && i_ + 1 < t_.size() && t_[i_ + 1].is_name("in")) {
      op = CmpOp::NotIn;
      i_ += 2;
      return true;
    }
    return false;
  }

  ExprPtr parse_compare() {
    ExprPtr first = parse_additive();
    CmpOp op;
    if (!accept_cmp_op(op)) return first;
    auto e = make_expr(ExprKind::Compare);
    e->args.push_back(std::move(first));
    do {
      e->cmp_ops.push_back(op);
      e->args.push_back(parse_additive());
    } while (accept_cmp_op(op));
    return e;
  }

  ExprPtr parse_additive() {
    ExprPtr l = parse_concat();
    while (true) {
      if (accept_op("+")) l = binop(BinOp::Add, std::move(l), parse_concat());
      else if (accept_op("-")) l = binop(BinOp::Sub, std::move(l), parse_concat());
      else return l;
    }
  }
  ExprPtr parse_concat() {
    ExprPtr l = parse_term();
    while (accept_op("~")) l = binop(BinOp::Concat, std::move(l), parse_term());
    return l;
  }
  ExprPtr parse_term() {
    ExprPtr l = parse_power();
    while (true) {
      if (accept_op("*")) l = binop(BinOp::Mul, std::move(l), parse_power());
      else if (accept_op("//")) l = binop(BinOp::FloorDiv, std::move(l), parse_power());
      else if (accept_op("/")) l = binop(BinOp::Div, std::move(l), parse_power());
      else if (accept_op("%")) l = binop(BinOp::Mod, std::move(l), parse_power());
      else return l;
    }
  }
  ExprPtr parse_power() {
    ExprPtr l = parse_filtered();
    while (accept_op("**")) l = binop(BinOp::Pow, std::move(l), parse_filtered());
    return l;
  }

  ExprPtr parse_filtered() {
    ExprPtr e = parse_unary();
    while (true) {
      if (accept_op("|")) {
        const Token& name = next();
        if (name.kind != Token::Kind::Name) syntax_error("expected a filter name");
        auto f = make_expr(ExprKind::Filter);
        f->name = name.text;
        if (!filter_from_name(name.text, f->filter)) bad_filter_ = true;
        f->args.push_back(std::move(e));
        if (accept_op("(")) {
          if (!accept_op(")")) {
            do {
              f->args.push_back(parse_expression());
            } while (accept_op(","));
            expect_op(")");
          }
        }
        e = std::move(f);
      } else if (peek_name("is")) {
        ++i_;
        auto d = make_expr(ExprKind::IsDefined);
        if (peek_name("not")) {
          ++i_;
          d->negate = true;
        }
        if (!peek_name("defined")) syntax_error("unknown test");
        ++i_;
        d->args.push_back(std::move(e));
        e = std::move(d);
      } else {
        return e;
      }
    }
  }

  ExprPtr parse_unary() {
    if (accept_op("-")) {
      auto e = make_expr(ExprKind::Neg);
      e->args.push_back(parse_unary());
      return e;
    }
    return parse_postfix();
  }

  ExprPtr parse_postfix() {
    ExprPtr e = parse_primary();
    while (true) {
      if (accept_op(".")) {
        const Token& name = next();
        if (name.kind != Token::Kind::Name) syntax_error("expected an attribute name");
        auto a = make_expr(ExprKind::Attr);
        a->name = name.text;
        a->args.push_back(std::move(e));
        e = std::move(a);
      } else if (accept_op("[")) {
        auto ix = make_expr(ExprKind::Index);
        ix->args.push_back(std::move(e));
        ix->args.push_back(parse_expression());
        expect_op("]");
        e = std::move(ix);
      } else if (accept_op("(")) {
        auto call = make_expr(ExprKind::Call);
        call->args.push_back(std::move(e));
        if (!accept_op(")")) {
          do {
            if (!at_end() && t_[i_].kind == Token::Kind::Name && i_ + 1 < t_.size() &&
                t_[i_ + 1].is_op("=") && !is_keyword(t_[i_].text)) {
              const std::string key = t_[i_].text;
              i_ += 2;
              for (const auto& kw : call->kwargs) {
                if (kw.first == key) syntax_error("repeated keyword argument");
              }
              call->kwargs.emplace_back(key, parse_expression());
            } else {
              if (!call->kwargs.empty()) syntax_error("positional argument after keyword argument");
              call->args.push_back(parse_expression());
            }
          } while (accept_op(","));
          expect_op(")");
        }
        e = std::move(call);
      } else {
        return e;
      }
    }
  }

  ExprPtr parse_primary() {
    const Token& t = next();
    switch (t.kind) {
      case Token::Kind::Int: {
        auto e = make_expr(ExprKind::Literal);
        e->literal = Value::integer(t.int_value);
        return e;
      }
      case Token::Kind::Float: {
        auto e = make_expr(ExprKind::Literal);
        e->literal = Value::real(t.float_value);
        return e;
      }
      case Token::Kind::String: {
        auto e = make_expr(ExprKind::Literal);
        e->literal = Value::string(t.text);
        return e;
      }
      case Token::Kind::Name: {
        if (t.text == "true" || t.text == "false") {
          auto e = make_expr(ExprKind::Literal);
          e->literal = Value::boolean(t.text == "true");
          return e;
        }
        if (t.text == "none") {
          auto e = make_expr(ExprKind::Literal);
          e->literal = Value::none();
          return e;
        }
        if (is_keyword(t.text)) syntax_error("unexpected keyword '" + t.text + "'");
        auto e = make_expr(ExprKind::Name);
        e->name = t.text;
        e->sym = symbols_.intern(t.text);
        return e;
      }
      case Token::Kind::Op:
        if (t.text == "[") {
          auto e = make_expr(ExprKind::List);
          if (!accept_op("]")) {
            do {
              e->args.push_back(parse_expression());
            } while (accept_op(","));
            expect_op("]");
          }
          return e;
        }
        if (t.text == "(") {
          ExprPtr e = parse_expression();
          expect_op(")");
          return e;
        }
        break;
    }
    syntax_error("unexpected token '" + t.text + "'");
  }

  const std::vector<Token>& t_;
  std::size_t i_;
  SymbolTable& symbols_;
  bool& bad_filter_;
};

// ---------------------------------------------------------------------------
// Statement parsing
// ---------------------------------------------------------------------------

class TemplateParser {
 public:
  TemplateParser(std::vector<Segment> segments, SymbolTable& symbols)
      : segs_(std::move(segments)), symbols_(symbols) {}

  std::unique_ptr<Template> run() {
    auto tpl = std::make_unique<Template>();
    tpl_ = tpl.get();
    std::string terminator;
    tpl->body = parse_body({}, terminator);
    if (idx_ < segs_.size()) syntax_error("unexpected '" + terminator + "'");
    if (bad_filter_) throw TemplateError(TemplateErrorKind::Filter, "unknown filter");
    return tpl;
  }

 private:
  /// Parses statements until a statement tag whose keyword is one of
  /// `terminators` (left unconsumed, its keyword returned in `hit`) or the end
  /// of the template.
  Body parse_body(std::initializer_list<std::string_view> terminators, std::string& hit) {
    Body body;
    while (idx_ < segs_.size()) {
      Segment& seg = segs_[idx_];
      switch (seg.kind) {
        case Segment::Kind::Text: {
          auto s = std::make_unique<Stmt>();
          s->kind = StmtKind::Text;
          s->text = std::move(seg.text);
          body.push_back(std::move(s));
          ++idx_;
          break;
        }
        case Segment::Kind::Print: {
          ExprParser p(seg.tokens, 0, symbols_, bad_filter_);
          auto s = std::make_unique<Stmt>();
          s->kind = StmtKind::Print;
          s->expr = p.parse_expression();
          p.expect_end();
          body.push_back(std::move(s));
          ++idx_;
          break;
        }
        case Segment::Kind::Statement: {
          if (seg.tokens.empty() || seg.tokens[0].kind != Token::Kind::Name) {
            syntax_error("empty or invalid statement");
          }
          const std::string& kw = seg.tokens[0].text;
          for (const std::string_view t : terminators) {
            if (kw == t) {
              hit = kw;
              return body;
            }
          }
          body.push_back(parse_statement(seg, kw));
          break;
        }
      }
    }
    hit.clear();
    return body;
  }

  Body parse_nested(std::initializer_list<std::string_view> terminators, std::string& hit) {
    ++depth_;
    Body b = parse_body(terminators, hit);
    --depth_;
    if (hit.empty()) syntax_error("unexpected end of template");
    return b;
  }

  StmtPtr parse_statement(Segment& seg, const std::string& kw) {
    auto s = std::make_unique<Stmt>();
    ExprParser p(seg.tokens, 1, symbols_, bad_filter_);
    ++idx_;
    if (kw == "if") return parse_if(p);
    if (kw == "for") {
      s->kind = StmtKind::For;
      const Token& var = p.next();
      if (var.kind != Token::Kind::Name || is_keyword(var.text)) syntax_error("bad loop variable");
      s->sym = symbols_.intern(var.text);
      if (!p.peek().is_name("in")) syntax_error("expected 'in'");
      p.next();
      s->expr = p.parse_expression();
      p.expect_end();
      std::string hit;
      s->body = parse_nested({"else", "endfor"}, hit);
      consume_terminator_end(hit == "else" ? 1 : 0);
      if (hit == "else") {
        s->else_body = parse_nested({"endfor"}, hit);
        consume_terminator_end(0);
      }
      return s;
    }
    if (kw == "set") {
      s->kind = StmtKind::Set;
      const Token& name = p.next();
      if (name.kind != Token::Kind::Name || is_keyword(name.text)) syntax_error("bad variable name");
      s->sym = symbols_.intern(name.text);
      p.expect_op("=");
      s->expr = p.parse_expression();
      p.expect_end();
      return s;
    }
    if (kw == "macro") {
      s->kind = StmtKind::Macro;
      const Token& name = p.next();
      if (name.kind != Token::Kind::Name || is_keyword(name.text)) syntax_error("bad macro name");
      s->text = name.text;
      s->sym = symbols_.intern(name.text);
      p.expect_op("(");
      if (!p.accept_op(")")) {
        do {
          const Token& pn = p.next();
          if (pn.kind != Token::Kind::Name || is_keyword(pn.text)) syntax_error("bad parameter");
          Param param;
          param.name = pn.text;
          param.sym = symbols_.intern(pn.text);
          for (const Param& other : s->params) {
            if (other.name == param.name) syntax_error("duplicate parameter");
          }
          if (p.accept_op("=")) param.default_value = p.parse_expression();
          s->params.push_back(std::move(param));
        } while (p.accept_op(","));
        p.expect_op(")");
      }
      p.expect_end();
      std::string hit;
      s->body = parse_nested({"endmacro"}, hit);
      consume_terminator_end(0);
      return s;
    }
    if (kw == "include") {
      s->kind = StmtKind::Include;
      s->expr = p.parse_expression();
      p.expect_end();
      return s;
    }
    if (kw == "extends") {
      if (depth_ != 0 || seen_extends_) syntax_error("misplaced 'extends'");
      seen_extends_ = true;
      s->kind = StmtKind::Extends;
      s->expr = p.parse_expression();
      p.expect_end();
      return s;
    }
    if (kw == "block") {
      s->kind = StmtKind::Block;
      const Token& name = p.next();
      if (name.kind != Token::Kind::Name) syntax_error("bad block name");
      s->text = name.text;
      p.expect_end();
      if (tpl_->blocks.count(s->text) != 0) syntax_error("duplicate block '" + s->text + "'");
      tpl_->blocks.emplace(s->text, s.get());
      tpl_->block_order.push_back(s->text);
      std::string hit;
      s->body = parse_nested({"endblock"}, hit);
      // `{% endblock %}` or `{% endblock NAME %}`
      Segment& end = segs_[idx_];
      if (end.tokens.size() == 2) {
        if (!end.tokens[1].is_name(s->text)) syntax_error("endblock name mismatch");
      } else if (end.tokens.size() != 1) {
        syntax_error("unexpected token after endblock");
      }
      ++idx_;
      return s;
    }
    syntax_error("unknown statement '" + kw + "'");
  }

  /// Consumes the terminator tag at `idx_`, which must consist of its keyword
  /// only. `skip` is unused padding for readability at call sites.
  void consume_terminator_end(int /*skip*/) {
    Segment& seg = segs_[idx_];
    if (seg.tokens.size() != 1) syntax_error("unexpected token after '" + seg.tokens[0].text + "'");
    ++idx_;
  }

  StmtPtr parse_if(ExprParser& first) {
    auto s = std::make_unique<Stmt>();
    s->kind = StmtKind::If;
    Branch branch;
    branch.condition = first.parse_expression();
    first.expect_end();
    while (true) {
      std::string hit;
      branch.body = parse_nested({"elif", "else", "endif"}, hit);
      s->branches.push_back(std::move(branch));
      branch = Branch();
      Segment& seg = segs_[idx_];
      if (hit == "elif") {
        ExprParser p(seg.tokens, 1, symbols_, bad_filter_);
        ++idx_;
        branch.condition = p.parse_expression();
        p.expect_end();
        continue;
      }
      if (hit == "else") {
        if (seg.tokens.size() != 1) syntax_error("unexpected token after 'else'");
        ++idx_;
        std::string hit2;
        s->else_body = parse_nested({"endif"}, hit2);
        consume_terminator_end(0);
        return s;
      }
      consume_terminator_end(0);
      return s;
    }
  }

  std::vector<Segment> segs_;
  SymbolTable& symbols_;
  Template* tpl_ = nullptr;
  std::size_t idx_ = 0;
  int depth_ = 0;
  bool seen_extends_ = false;
  bool bad_filter_ = false;
};

}  // namespace

std::unique_ptr<Template> parse_template(std::string_view source, SymbolTable& symbols) {
  Splitter splitter(source);
  TemplateParser parser(splitter.run(), symbols);
  return parser.run();
}

}  // namespace sitegen::tmpl
