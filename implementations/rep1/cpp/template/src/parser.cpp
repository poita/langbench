#include "jinjalite/parser.hpp"

#include <set>

#include "jinjalite/error.hpp"
#include "jinjalite/lexer.hpp"

namespace jinjalite {
namespace {

[[noreturn]] void syntax(const char* msg) { throw Error(ErrorKind::Syntax, msg); }

bool is_reserved_word(const std::string& w) {
  return w == "and" || w == "or" || w == "not" || w == "in" || w == "is" || w == "true" || w == "false" ||
         w == "none";
}

class Parser {
 public:
  Parser(std::string name, std::vector<Item> items) : items_(std::move(items)) {
    tmpl_ = std::make_unique<Template>();
    tmpl_->name = std::move(name);
  }

  std::unique_ptr<Template> run() {
    tmpl_->body = parse_body({});
    if (unknown_filter_) throw Error(ErrorKind::Filter, "unknown filter");
    return std::move(tmpl_);
  }

 private:
  // ---- statement level ----------------------------------------------------

  /// Parses items until a statement whose keyword is in `stops` (left
  /// unconsumed). With no stops, parses to the end of the template.
  Body parse_body(std::initializer_list<std::string_view> stops) {
    Body body;
    while (item_pos_ < items_.size()) {
      const Item& item = items_[item_pos_];
      switch (item.kind) {
        case Item::Kind::Text:
          body.push_back(std::make_unique<TextStmt>(item.text));
          ++item_pos_;
          break;
        case Item::Kind::Print: {
          ++item_pos_;
          begin_tag(item);
          ExprPtr e = parse_expr();
          expect_end();
          body.push_back(std::make_unique<PrintStmt>(std::move(e)));
          break;
        }
        case Item::Kind::Statement: {
          if (item.tokens.empty() || item.tokens[0].kind != TokenKind::Name) syntax("bad statement");
          const std::string& kw = item.tokens[0].text;
          for (std::string_view s : stops) {
            if (kw == s) return body;
          }
          ++item_pos_;
          begin_tag(item);
          ++tok_pos_;  // keyword
          body.push_back(parse_statement(kw));
          break;
        }
      }
    }
    if (stops.size() != 0) syntax("unclosed block");
    return body;
  }

  /// Consumes the next item, which must be a statement tag, positioned after
  /// its keyword.
  void consume_tag() {
    const Item& item = items_[item_pos_++];
    begin_tag(item);
    ++tok_pos_;
  }

  /// Keyword of the statement at the cursor (parse_body returned there).
  const std::string& pending_keyword() const { return items_[item_pos_].tokens[0].text; }

  StmtPtr parse_statement(const std::string& kw) {
    if (kw == "if") return parse_if();
    if (kw == "for") return parse_for();
    if (kw == "set") return parse_set();
    if (kw == "macro") return parse_macro();
    if (kw == "include") {
      ExprPtr e = parse_expr();
      expect_end();
      return std::make_unique<IncludeStmt>(std::move(e));
    }
    if (kw == "extends") {
      if (depth_ > 0 || seen_extends_) syntax("misplaced extends");
      seen_extends_ = true;
      ExprPtr e = parse_expr();
      expect_end();
      return std::make_unique<ExtendsStmt>(std::move(e));
    }
    if (kw == "block") return parse_block();
    syntax("unknown statement");
  }

  StmtPtr parse_if() {
    auto stmt = std::make_unique<IfStmt>();
    ++depth_;
    ExprPtr cond = parse_expr();
    expect_end();
    Body body = parse_body({"elif", "else", "endif"});
    stmt->branches.emplace_back(std::move(cond), std::move(body));
    for (;;) {
      std::string kw = pending_keyword();
      consume_tag();
      if (kw == "elif") {
        ExprPtr c = parse_expr();
        expect_end();
        Body b = parse_body({"elif", "else", "endif"});
        stmt->branches.emplace_back(std::move(c), std::move(b));
      } else if (kw == "else") {
        expect_end();
        stmt->else_body = parse_body({"endif"});
      } else {  // endif
        expect_end();
        break;
      }
    }
    --depth_;
    return stmt;
  }

  std::string expect_name(const char* what) {
    if (tok_pos_ >= toks_->size() || (*toks_)[tok_pos_].kind != TokenKind::Name) syntax(what);
    return (*toks_)[tok_pos_++].text;
  }

  std::string expect_binding_name(const char* what) {
    std::string n = expect_name(what);
    if (is_reserved_word(n)) syntax("reserved word used as a name");
    return n;
  }

  StmtPtr parse_for() {
    auto stmt = std::make_unique<ForStmt>();
    stmt->var = expect_binding_name("expected loop variable");
    if (!accept_name("in")) syntax("expected 'in'");
    stmt->iterable = parse_expr();
    expect_end();
    ++depth_;
    stmt->body = parse_body({"else", "endfor"});
    consume_tag();
    if (items_[item_pos_ - 1].tokens[0].text == "else") {
      expect_end();
      stmt->else_body = parse_body({"endfor"});
      consume_tag();
    }
    expect_end();
    --depth_;
    return stmt;
  }

  StmtPtr parse_set() {
    auto stmt = std::make_unique<SetStmt>();
    stmt->name = expect_binding_name("expected variable name");
    if (!accept_op("=")) syntax("expected '='");
    stmt->value = parse_expr();
    expect_end();
    return stmt;
  }

  StmtPtr parse_macro() {
    auto stmt = std::make_unique<MacroStmt>();
    stmt->name = expect_binding_name("expected macro name");
    if (!accept_op("(")) syntax("expected '('");
    std::set<std::string> seen;
    if (!accept_op(")")) {
      for (;;) {
        MacroParam p;
        p.name = expect_binding_name("expected parameter name");
        if (!seen.insert(p.name).second) syntax("duplicate parameter");
        if (accept_op("=")) p.default_value = parse_expr();
        stmt->params.push_back(std::move(p));
        if (accept_op(",")) continue;
        if (accept_op(")")) break;
        syntax("expected ',' or ')'");
      }
    }
    expect_end();
    ++depth_;
    stmt->body = parse_body({"endmacro"});
    consume_tag();
    expect_end();
    --depth_;
    return stmt;
  }

  StmtPtr parse_block() {
    auto stmt = std::make_unique<BlockStmt>();
    stmt->name = expect_name("expected block name");
    expect_end();
    if (!block_names_.insert(stmt->name).second) syntax("duplicate block name");
    ++depth_;
    stmt->body = parse_body({"endblock"});
    consume_tag();
    if (tok_pos_ < toks_->size()) {
      if (expect_name("expected block name") != stmt->name) syntax("endblock name mismatch");
    }
    expect_end();
    --depth_;
    tmpl_->blocks.push_back(stmt.get());
    return stmt;
  }

  // ---- token helpers ------------------------------------------------------

  void begin_tag(const Item& item) {
    toks_ = &item.tokens;
    tok_pos_ = 0;
  }
  const Token* peek(size_t ahead = 0) const {
    return tok_pos_ + ahead < toks_->size() ? &(*toks_)[tok_pos_ + ahead] : nullptr;
  }
  void expect_end() const {
    if (tok_pos_ != toks_->size()) syntax("unexpected tokens");
  }
  bool accept_op(std::string_view op) {
    const Token* t = peek();
    if (t && t->is_op(op)) {
      ++tok_pos_;
      return true;
    }
    return false;
  }
  bool accept_name(std::string_view n) {
    const Token* t = peek();
    if (t && t->is_name(n)) {
      ++tok_pos_;
      return true;
    }
    return false;
  }
  void expect_op(std::string_view op) {
    if (!accept_op(op)) syntax("unexpected token");
  }

  // ---- expressions --------------------------------------------------------

  ExprPtr parse_expr() { return parse_or(); }

  ExprPtr parse_or() {
    ExprPtr lhs = parse_and();
    while (accept_name("or")) {
      lhs = std::make_unique<LogicalExpr>(ExprKind::Or, std::move(lhs), parse_and());
    }
    return lhs;
  }

  ExprPtr parse_and() {
    ExprPtr lhs = parse_not();
    while (accept_name("and")) {
      lhs = std::make_unique<LogicalExpr>(ExprKind::And, std::move(lhs), parse_not());
    }
    return lhs;
  }

  ExprPtr parse_not() {
    if (accept_name("not")) return std::make_unique<UnaryExpr>(ExprKind::Not, parse_not());
    return parse_compare();
  }

  bool accept_compare_op(CompareOp& op) {
    const Token* t = peek();
    if (!t) return false;
    if (t->kind == TokenKind::Op) {
      static const std::pair<const char*, CompareOp> table[] = {
          {"==", CompareOp::Eq}, {"!=", CompareOp::Ne}, {"<", CompareOp::Lt},
          {"<=", CompareOp::Le}, {">", CompareOp::Gt},  {">=", CompareOp::Ge}};
      for (const auto& e : table) {
        if (t->text == e.first) {
          op = e.second;
          ++tok_pos_;
          return true;
        }
      }
      return false;
    }
    if (t->is_name("in")) {
      op = CompareOp::In;
      ++tok_pos_;
      return true;
    }
    if (t->is_name("not")) {
      const Token* n = peek(1);
      if (n && n->is_name("in")) {
        op = CompareOp::NotIn;
        tok_pos_ += 2;
        return true;
      }
    }
    return false;
  }

  ExprPtr parse_compare() {
    ExprPtr first = parse_additive();
    CompareOp op;
    if (!accept_compare_op(op)) return first;
    auto cmp = std::make_unique<CompareExpr>();
    cmp->first = std::move(first);
    do {
      cmp->rest.emplace_back(op, parse_additive());
    } while (accept_compare_op(op));
    return cmp;
  }

  ExprPtr parse_additive() {
    ExprPtr lhs = parse_concat();
    for (;;) {
      BinaryOp op;
      if (accept_op("+")) op = BinaryOp::Add;
      else if (accept_op("-")) op = BinaryOp::Sub;
      else return lhs;
      lhs = std::make_unique<BinaryExpr>(op, std::move(lhs), parse_concat());
    }
  }

  ExprPtr parse_concat() {
    ExprPtr lhs = parse_term();
    while (accept_op("~")) {
      lhs = std::make_unique<BinaryExpr>(BinaryOp::Concat, std::move(lhs), parse_term());
    }
    return lhs;
  }

  ExprPtr parse_term() {
    ExprPtr lhs = parse_power();
    for (;;) {
      BinaryOp op;
      if (accept_op("*")) op = BinaryOp::Mul;
      else if (accept_op("/")) op = BinaryOp::Div;
      else if (accept_op("//")) op = BinaryOp::FloorDiv;
      else if (accept_op("%")) op = BinaryOp::Mod;
      else return lhs;
      lhs = std::make_unique<BinaryExpr>(op, std::move(lhs), parse_power());
    }
  }

  ExprPtr parse_power() {
    ExprPtr lhs = parse_filtered();
    while (accept_op("**")) {
      lhs = std::make_unique<BinaryExpr>(BinaryOp::Pow, std::move(lhs), parse_filtered());
    }
    return lhs;
  }

  ExprPtr parse_filtered() {
    ExprPtr e = parse_unary();
    for (;;) {
      if (accept_op("|")) {
        auto f = std::make_unique<FilterExpr>();
        std::string name = expect_name("expected filter name");
        f->filter = find_filter(name);
        if (!f->filter) unknown_filter_ = true;
        f->input = std::move(e);
        if (accept_op("(")) {
          if (!accept_op(")")) {
            for (;;) {
              f->args.push_back(parse_expr());
              if (accept_op(",")) continue;
              expect_op(")");
              break;
            }
          }
        }
        e = std::move(f);
      } else if (accept_name("is")) {
        bool negated = accept_name("not");
        if (!accept_name("defined")) syntax("unknown test");
        e = std::make_unique<IsDefinedExpr>(std::move(e), negated);
      } else {
        return e;
      }
    }
  }

  ExprPtr parse_unary() {
    if (accept_op("-")) return std::make_unique<UnaryExpr>(ExprKind::Negate, parse_unary());
    return parse_postfix();
  }

  ExprPtr parse_postfix() {
    ExprPtr e = parse_primary();
    for (;;) {
      if (accept_op(".")) {
        std::string name = expect_name("expected attribute name");
        e = std::make_unique<GetExpr>(std::move(e), std::make_unique<LiteralExpr>(Value::string(std::move(name))));
      } else if (accept_op("[")) {
        ExprPtr key = parse_expr();
        expect_op("]");
        e = std::make_unique<GetExpr>(std::move(e), std::move(key));
      } else if (accept_op("(")) {
        e = parse_call(std::move(e));
      } else {
        return e;
      }
    }
  }

  ExprPtr parse_call(ExprPtr callee) {
    auto call = std::make_unique<CallExpr>();
    call->callee = std::move(callee);
    if (accept_op(")")) return call;
    std::set<std::string> keywords;
    for (;;) {
      const Token* t = peek();
      const Token* n = peek(1);
      if (t && t->kind == TokenKind::Name && n && n->is_op("=") && !is_reserved_word(t->text)) {
        std::string name = t->text;
        tok_pos_ += 2;
        if (!keywords.insert(name).second) syntax("duplicate keyword argument");
        call->kwargs.emplace_back(std::move(name), parse_expr());
      } else {
        if (!call->kwargs.empty()) syntax("positional argument after keyword argument");
        call->args.push_back(parse_expr());
      }
      if (accept_op(",")) continue;
      expect_op(")");
      return call;
    }
  }

  ExprPtr parse_primary() {
    const Token* t = peek();
    if (!t) syntax("unexpected end of expression");
    ++tok_pos_;
    switch (t->kind) {
      case TokenKind::Int: return std::make_unique<LiteralExpr>(Value::integer(t->int_value));
      case TokenKind::Float: return std::make_unique<LiteralExpr>(Value::real(t->float_value));
      case TokenKind::String: return std::make_unique<LiteralExpr>(Value::string(t->text));
      case TokenKind::Name:
        if (t->text == "true" || t->text == "True") return std::make_unique<LiteralExpr>(Value::boolean(true));
        if (t->text == "false" || t->text == "False") return std::make_unique<LiteralExpr>(Value::boolean(false));
        if (t->text == "none" || t->text == "None") return std::make_unique<LiteralExpr>(Value::none());
        if (is_reserved_word(t->text)) syntax("reserved word in expression");
        return std::make_unique<NameExpr>(t->text);
      case TokenKind::Op:
        if (t->text == "[") {
          auto list = std::make_unique<ListExpr>();
          if (accept_op("]")) return list;
          for (;;) {
            list->items.push_back(parse_expr());
            if (accept_op(",")) continue;
            expect_op("]");
            return list;
          }
        }
        if (t->text == "(") {
          ExprPtr e = parse_expr();
          expect_op(")");
          return e;
        }
        break;
    }
    syntax("unexpected token in expression");
  }

  std::vector<Item> items_;
  size_t item_pos_ = 0;
  const std::vector<Token>* toks_ = nullptr;
  size_t tok_pos_ = 0;
  int depth_ = 0;
  bool seen_extends_ = false;
  bool unknown_filter_ = false;
  std::set<std::string> block_names_;
  std::unique_ptr<Template> tmpl_;
};

}  // namespace

std::unique_ptr<Template> parse_template(std::string name, std::string_view source) {
  return Parser(std::move(name), lex_template(source)).run();
}

}  // namespace jinjalite
