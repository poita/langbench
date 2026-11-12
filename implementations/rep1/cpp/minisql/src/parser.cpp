#include "minisql/parser.hpp"

#include <cstdint>
#include <limits>

#include "minisql/error.hpp"

namespace minisql {

namespace {

[[noreturn]] void syntax_error(const std::string& msg) {
  throw Error(ErrorKind::Syntax, msg);
}

ExprPtr make_expr(ExprKind kind) {
  auto e = std::make_unique<Expr>();
  e->kind = kind;
  return e;
}

class Parser {
 public:
  Parser(const Token* begin, const Token* end) : cur_(begin), end_(end) {}

  Statement parse() {
    Statement st = parse_top();
    if (cur_ != end_) syntax_error("unexpected token '" + cur_->text + "'");
    return st;
  }

 private:
  const Token* cur_;
  const Token* end_;

  // ---- token helpers ------------------------------------------------------
  bool at_end() const { return cur_ == end_; }
  const Token* peek(std::size_t ahead = 0) const {
    return (cur_ + ahead < end_) ? cur_ + ahead : nullptr;
  }
  bool is_kw(const char* kw, std::size_t ahead = 0) const {
    const Token* t = peek(ahead);
    return t && t->kind == TokenKind::Keyword && t->text == kw;
  }
  bool is_sym(const char* s, std::size_t ahead = 0) const {
    const Token* t = peek(ahead);
    return t && t->kind == TokenKind::Symbol && t->text == s;
  }
  bool accept_kw(const char* kw) {
    if (!is_kw(kw)) return false;
    ++cur_;
    return true;
  }
  bool accept_sym(const char* s) {
    if (!is_sym(s)) return false;
    ++cur_;
    return true;
  }
  void expect_kw(const char* kw) {
    if (!accept_kw(kw)) syntax_error(std::string("expected ") + kw);
  }
  void expect_sym(const char* s) {
    if (!accept_sym(s)) syntax_error(std::string("expected '") + s + "'");
  }
  bool at_name() const {
    const Token* t = peek();
    return t && t->kind == TokenKind::Identifier;
  }
  std::string expect_name() {
    if (!at_name()) syntax_error("expected a name");
    return (cur_++)->text;
  }
  std::int64_t expect_integer() {
    const Token* t = peek();
    if (!t || t->kind != TokenKind::Integer) syntax_error("expected an integer");
    ++cur_;
    return to_int(*t);
  }
  static std::int64_t to_int(const Token& t) {
    std::uint64_t v = 0;
    for (char c : t.text) {
      const unsigned d = static_cast<unsigned>(c - '0');
      if (v > (static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()) - d) / 10) {
        syntax_error("integer literal out of range");
      }
      v = v * 10 + d;
    }
    return static_cast<std::int64_t>(v);
  }

  // ---- statements ---------------------------------------------------------
  Statement parse_top() {
    if (accept_kw("SELECT")) return parse_select();
    if (accept_kw("INSERT")) return parse_insert();
    if (accept_kw("DELETE")) return parse_delete();
    if (accept_kw("UPDATE")) return parse_update();
    if (accept_kw("CREATE")) return parse_create();
    syntax_error("unsupported or malformed statement");
  }

  Statement parse_create() {
    expect_kw("TABLE");
    CreateTableStmt st;
    st.table = expect_name();
    expect_sym("(");
    do {
      st.columns.push_back(expect_name());
      if (!accept_kw("INTEGER") && !accept_kw("TEXT")) syntax_error("expected a column type");
    } while (accept_sym(","));
    expect_sym(")");
    return st;
  }

  Statement parse_insert() {
    expect_kw("INTO");
    InsertStmt st;
    st.table = expect_name();
    expect_kw("VALUES");
    do {
      expect_sym("(");
      std::vector<ExprPtr> row;
      do {
        row.push_back(parse_expr());
      } while (accept_sym(","));
      expect_sym(")");
      st.rows.push_back(std::move(row));
    } while (accept_sym(","));
    return st;
  }

  Statement parse_delete() {
    expect_kw("FROM");
    DeleteStmt st;
    st.table = expect_name();
    if (accept_kw("WHERE")) st.where = parse_expr();
    return st;
  }

  Statement parse_update() {
    UpdateStmt st;
    st.table = expect_name();
    expect_kw("SET");
    do {
      std::string col = expect_name();
      expect_sym("=");
      st.assignments.emplace_back(std::move(col), parse_expr());
    } while (accept_sym(","));
    if (accept_kw("WHERE")) st.where = parse_expr();
    return st;
  }

  TableRef parse_table_ref() {
    TableRef t;
    t.name = expect_name();
    if (accept_kw("AS")) {
      t.alias = expect_name();
    } else if (at_name()) {
      t.alias = expect_name();
    }
    return t;
  }

  ExprPtr parse_column_ref() {
    auto e = make_expr(ExprKind::Column);
    e->name = expect_name();
    if (accept_sym(".")) {
      e->qualifier = std::move(e->name);
      e->name = expect_name();
    }
    return e;
  }

  Statement parse_select() {
    SelectStmt st;
    do {
      SelectItem item;
      if (accept_sym("*")) {
        item.star = true;
      } else {
        item.expr = parse_expr();
        if (accept_kw("AS")) {
          item.alias = expect_name();
        } else if (at_name()) {
          item.alias = expect_name();
        }
      }
      st.items.push_back(std::move(item));
    } while (accept_sym(","));

    if (accept_kw("FROM")) {
      st.from.push_back(parse_table_ref());
      if (accept_sym(",")) {
        st.from.push_back(parse_table_ref());
      } else if (is_kw("INNER") || is_kw("JOIN")) {
        accept_kw("INNER");
        expect_kw("JOIN");
        st.from.push_back(parse_table_ref());
        expect_kw("ON");
        st.join_on = parse_expr();
      }
    }
    if (accept_kw("WHERE")) st.where = parse_expr();
    if (accept_kw("GROUP")) {
      expect_kw("BY");
      do {
        st.group_by.push_back(parse_column_ref());
      } while (accept_sym(","));
    }
    if (accept_kw("HAVING")) {
      if (st.group_by.empty()) syntax_error("HAVING requires GROUP BY");
      st.having = parse_expr();
    }
    if (accept_kw("ORDER")) {
      expect_kw("BY");
      do {
        const Token* first = cur_;
        OrderTerm term;
        term.expr = parse_expr();
        if (cur_ - first == 1) {
          if (first->kind == TokenKind::Identifier) term.bare_identifier = first->text;
          if (first->kind == TokenKind::Integer) term.ordinal = to_int(*first);
        }
        if (accept_kw("DESC")) term.descending = true;
        else accept_kw("ASC");
        st.order_by.push_back(std::move(term));
      } while (accept_sym(","));
    }
    if (accept_kw("LIMIT")) {
      st.limit = expect_integer();
      if (accept_kw("OFFSET")) st.offset = expect_integer();
    }
    return st;
  }

  // ---- expressions --------------------------------------------------------
  static ExprPtr binary(BinaryOp op, ExprPtr l, ExprPtr r) {
    auto e = make_expr(ExprKind::Binary);
    e->binary_op = op;
    e->lhs = std::move(l);
    e->rhs = std::move(r);
    return e;
  }

  ExprPtr parse_expr() {
    ExprPtr l = parse_and();
    while (accept_kw("OR")) l = binary(BinaryOp::Or, std::move(l), parse_and());
    return l;
  }

  ExprPtr parse_and() {
    ExprPtr l = parse_not();
    while (accept_kw("AND")) l = binary(BinaryOp::And, std::move(l), parse_not());
    return l;
  }

  ExprPtr parse_not() {
    if (accept_kw("NOT")) {
      auto e = make_expr(ExprKind::Unary);
      e->unary_op = UnaryOp::Not;
      e->lhs = parse_not();
      return e;
    }
    return parse_equality();
  }

  ExprPtr parse_equality() {
    ExprPtr l = parse_relational();
    for (;;) {
      BinaryOp op;
      if (accept_sym("=") || accept_sym("==")) op = BinaryOp::Eq;
      else if (accept_sym("!=") || accept_sym("<>")) op = BinaryOp::Ne;
      else if (accept_kw("IS")) {
        auto e = make_expr(ExprKind::IsNull);
        e->negated = accept_kw("NOT");
        expect_kw("NULL");
        e->lhs = std::move(l);
        l = std::move(e);
        continue;
      } else if (is_kw("LIKE") || (is_kw("NOT") && is_kw("LIKE", 1))) {
        auto e = make_expr(ExprKind::Like);
        e->negated = accept_kw("NOT");
        expect_kw("LIKE");
        e->lhs = std::move(l);
        e->rhs = parse_relational();
        l = std::move(e);
        continue;
      } else {
        return l;
      }
      l = binary(op, std::move(l), parse_relational());
    }
  }

  ExprPtr parse_relational() {
    ExprPtr l = parse_additive();
    for (;;) {
      BinaryOp op;
      if (accept_sym("<")) op = BinaryOp::Lt;
      else if (accept_sym("<=")) op = BinaryOp::Le;
      else if (accept_sym(">")) op = BinaryOp::Gt;
      else if (accept_sym(">=")) op = BinaryOp::Ge;
      else return l;
      l = binary(op, std::move(l), parse_additive());
    }
  }

  ExprPtr parse_additive() {
    ExprPtr l = parse_multiplicative();
    for (;;) {
      BinaryOp op;
      if (accept_sym("+")) op = BinaryOp::Add;
      else if (accept_sym("-")) op = BinaryOp::Sub;
      else return l;
      l = binary(op, std::move(l), parse_multiplicative());
    }
  }

  ExprPtr parse_multiplicative() {
    ExprPtr l = parse_unary();
    for (;;) {
      BinaryOp op;
      if (accept_sym("*")) op = BinaryOp::Mul;
      else if (accept_sym("/")) op = BinaryOp::Div;
      else if (accept_sym("%")) op = BinaryOp::Mod;
      else return l;
      l = binary(op, std::move(l), parse_unary());
    }
  }

  ExprPtr parse_unary() {
    if (accept_sym("-")) {
      auto e = make_expr(ExprKind::Unary);
      e->unary_op = UnaryOp::Negate;
      e->lhs = parse_unary();
      return e;
    }
    return parse_primary();
  }

  static bool aggregate_name(const std::string& n, AggFunc& f) {
    if (n == "count") f = AggFunc::Count;
    else if (n == "sum") f = AggFunc::Sum;
    else if (n == "min") f = AggFunc::Min;
    else if (n == "max") f = AggFunc::Max;
    else if (n == "avg") f = AggFunc::Avg;
    else return false;
    return true;
  }

  ExprPtr parse_primary() {
    const Token* t = peek();
    if (!t) syntax_error("unexpected end of statement");
    switch (t->kind) {
      case TokenKind::Integer: {
        auto e = make_expr(ExprKind::Literal);
        e->literal = Value::integer(to_int(*t));
        ++cur_;
        return e;
      }
      case TokenKind::String: {
        auto e = make_expr(ExprKind::Literal);
        e->literal = Value::text(t->text);
        ++cur_;
        return e;
      }
      case TokenKind::Keyword:
        if (t->text == "NULL") {
          ++cur_;
          return make_expr(ExprKind::Literal);
        }
        break;
      case TokenKind::Symbol:
        if (t->text == "(") {
          ++cur_;
          ExprPtr e = parse_expr();
          expect_sym(")");
          return e;
        }
        break;
      case TokenKind::Identifier: {
        if (is_sym("(", 1)) {
          AggFunc f;
          if (!aggregate_name(t->text, f)) syntax_error("unknown function " + t->text);
          cur_ += 2;
          auto e = make_expr(ExprKind::Aggregate);
          e->func = f;
          if (f == AggFunc::Count && accept_sym("*")) {
            e->star = true;
          } else {
            e->lhs = parse_expr();
          }
          expect_sym(")");
          return e;
        }
        return parse_column_ref();
      }
      default:
        break;
    }
    syntax_error("unexpected token '" + t->text + "'");
  }
};

}  // namespace

Statement parse_statement(const Token* begin, const Token* end) {
  return Parser(begin, end).parse();
}

Statement parse_statement(std::string_view sql) {
  const std::vector<Token> tokens = tokenize(sql);
  const Token* b = tokens.data();
  const Token* e = b + tokens.size();
  if (e != b && (e - 1)->kind == TokenKind::Semicolon) --e;
  return parse_statement(b, e);
}

}  // namespace minisql
