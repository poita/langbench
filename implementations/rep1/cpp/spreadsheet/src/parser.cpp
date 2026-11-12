#include "spreadsheet/parser.h"

#include <cstdlib>
#include <string>

namespace spreadsheet {
namespace {

class Parser {
 public:
  explicit Parser(std::string_view s) : s_(s) {}

  Formula run() {
    auto root = parse_cmp();
    skip_spaces();
    if (pos_ != s_.size()) fail("unexpected trailing input");
    return Formula(std::move(root), invalid_ref_);
  }

 private:
  using ExprPtr = std::unique_ptr<Expr>;

  [[noreturn]] void fail(const char* msg) const {
    throw ParseError(std::string(msg) + " at offset " + std::to_string(pos_));
  }

  void skip_spaces() {
    while (pos_ < s_.size() && s_[pos_] == ' ') ++pos_;
  }
  bool at_end() {
    skip_spaces();
    return pos_ >= s_.size();
  }
  char peek() {
    skip_spaces();
    return pos_ < s_.size() ? s_[pos_] : '\0';
  }
  bool eat(char c) {
    if (peek() == c) {
      ++pos_;
      return true;
    }
    return false;
  }
  void expect(char c) {
    if (!eat(c)) fail("unexpected character");
  }

  static ExprPtr make(Expr::Kind k) {
    auto e = std::make_unique<Expr>();
    e->kind = k;
    return e;
  }
  static ExprPtr binary(BinaryOp op, ExprPtr a, ExprPtr b) {
    auto e = make(Expr::Kind::Binary);
    e->op = op;
    e->args.push_back(std::move(a));
    e->args.push_back(std::move(b));
    return e;
  }

  ExprPtr parse_cmp() {
    auto lhs = parse_cat();
    for (;;) {
      char c = peek();
      BinaryOp op;
      if (c == '=') {
        op = BinaryOp::Eq;
        ++pos_;
      } else if (c == '<') {
        ++pos_;
        if (pos_ < s_.size() && s_[pos_] == '>') {
          op = BinaryOp::Ne;
          ++pos_;
        } else if (pos_ < s_.size() && s_[pos_] == '=') {
          op = BinaryOp::Le;
          ++pos_;
        } else {
          op = BinaryOp::Lt;
        }
      } else if (c == '>') {
        ++pos_;
        if (pos_ < s_.size() && s_[pos_] == '=') {
          op = BinaryOp::Ge;
          ++pos_;
        } else {
          op = BinaryOp::Gt;
        }
      } else {
        return lhs;
      }
      lhs = binary(op, std::move(lhs), parse_cat());
    }
  }

  ExprPtr parse_cat() {
    auto lhs = parse_add();
    while (eat('&')) lhs = binary(BinaryOp::Concat, std::move(lhs), parse_add());
    return lhs;
  }

  ExprPtr parse_add() {
    auto lhs = parse_mul();
    for (;;) {
      char c = peek();
      if (c != '+' && c != '-') return lhs;
      ++pos_;
      lhs = binary(c == '+' ? BinaryOp::Add : BinaryOp::Sub, std::move(lhs), parse_mul());
    }
  }

  ExprPtr parse_mul() {
    auto lhs = parse_unary();
    for (;;) {
      char c = peek();
      if (c != '*' && c != '/') return lhs;
      ++pos_;
      lhs = binary(c == '*' ? BinaryOp::Mul : BinaryOp::Div, std::move(lhs), parse_unary());
    }
  }

  ExprPtr parse_unary() {
    if (eat('-')) {
      auto e = make(Expr::Kind::Negate);
      e->args.push_back(parse_unary());
      return e;
    }
    return parse_primary();
  }

  static bool is_digit(char c) { return c >= '0' && c <= '9'; }
  static bool is_upper(char c) { return c >= 'A' && c <= 'Z'; }

  ExprPtr parse_primary() {
    char c = peek();
    if (is_digit(c)) return parse_number();
    if (c == '"') return parse_string();
    if (c == '(') {
      ++pos_;
      auto e = parse_cmp();
      expect(')');
      return e;
    }
    if (is_upper(c)) return parse_word();
    fail("unexpected token");
  }

  ExprPtr parse_number() {
    std::size_t start = pos_;
    while (pos_ < s_.size() && is_digit(s_[pos_])) ++pos_;
    if (pos_ + 1 < s_.size() && s_[pos_] == '.' && is_digit(s_[pos_ + 1])) {
      ++pos_;
      while (pos_ < s_.size() && is_digit(s_[pos_])) ++pos_;
    }
    auto e = make(Expr::Kind::Number);
    e->number = std::strtod(std::string(s_.substr(start, pos_ - start)).c_str(), nullptr);
    return e;
  }

  ExprPtr parse_string() {
    ++pos_;  // opening quote
    std::size_t end = s_.find('"', pos_);
    if (end == std::string_view::npos) fail("unterminated string");
    auto e = make(Expr::Kind::String);
    e->text = std::string(s_.substr(pos_, end - pos_));
    pos_ = end + 1;
    return e;
  }

  // Reads [A-Z]+ followed by optional [0-9]+. Letters+digits is a reference,
  // letters followed by '(' is a function name.
  ExprPtr parse_word() {
    std::size_t start = pos_;
    while (pos_ < s_.size() && is_upper(s_[pos_])) ++pos_;
    std::size_t mid = pos_;
    while (pos_ < s_.size() && is_digit(s_[pos_])) ++pos_;
    std::string_view letters = s_.substr(start, mid - start);
    std::string_view digits = s_.substr(mid, pos_ - mid);
    if (!digits.empty()) {
      auto e = make(Expr::Kind::Ref);
      e->ref = resolve(letters, digits);
      return e;
    }
    if (peek() != '(') fail("unknown identifier");
    ++pos_;
    return parse_call(letters);
  }

  CellRef resolve(std::string_view letters, std::string_view digits) {
    auto ref = make_cell_ref(letters, digits);
    if (!ref) {
      invalid_ref_ = true;
      return CellRef{1, 1};
    }
    return *ref;
  }

  ExprPtr parse_call(std::string_view name) {
    if (name == "IF") {
      auto e = make(Expr::Kind::If);
      e->args.push_back(parse_cmp());
      expect(',');
      e->args.push_back(parse_cmp());
      expect(',');
      e->args.push_back(parse_cmp());
      expect(')');
      return e;
    }
    auto e = make(Expr::Kind::Aggregate);
    if (name == "SUM") e->fn = AggregateFn::Sum;
    else if (name == "MIN") e->fn = AggregateFn::Min;
    else if (name == "MAX") e->fn = AggregateFn::Max;
    else if (name == "AVG") e->fn = AggregateFn::Avg;
    else if (name == "COUNT") e->fn = AggregateFn::Count;
    else fail("unknown function");
    do {
      e->args.push_back(parse_argument());
    } while (eat(','));
    expect(')');
    return e;
  }

  // arg := expr | REF ":" REF
  ExprPtr parse_argument() {
    skip_spaces();
    std::size_t save = pos_;
    if (is_upper(peek())) {
      std::size_t first_start = pos_;
      while (pos_ < s_.size() && is_upper(s_[pos_])) ++pos_;
      std::size_t mid = pos_;
      while (pos_ < s_.size() && is_digit(s_[pos_])) ++pos_;
      if (pos_ > mid && pos_ < s_.size() && s_[pos_] == ':') {
        auto a = resolve(s_.substr(first_start, mid - first_start), s_.substr(mid, pos_ - mid));
        ++pos_;
        std::size_t l = pos_;
        while (pos_ < s_.size() && is_upper(s_[pos_])) ++pos_;
        std::size_t m = pos_;
        while (pos_ < s_.size() && is_digit(s_[pos_])) ++pos_;
        if (l == m || m == pos_) fail("malformed range");
        auto b = resolve(s_.substr(l, m - l), s_.substr(m, pos_ - m));
        auto e = make(Expr::Kind::Range);
        e->range = CellRange::spanning(a, b);
        return e;
      }
      pos_ = save;
    }
    return parse_cmp();
  }

  std::string_view s_;
  std::size_t pos_ = 0;
  bool invalid_ref_ = false;
};

}  // namespace

Formula parse_formula(std::string_view expression) { return Parser(expression).run(); }

}  // namespace spreadsheet
