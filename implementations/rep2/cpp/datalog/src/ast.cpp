#include "datalog/ast.h"

namespace datalog {

Constant Constant::integer(std::int64_t value) {
  Constant c;
  c.is_integer_ = true;
  c.number_ = value;
  return c;
}

Constant Constant::symbol(std::string name) {
  Constant c;
  c.is_integer_ = false;
  c.text_ = std::move(name);
  return c;
}

std::string Constant::to_string() const {
  return is_integer_ ? std::to_string(number_) : text_;
}

bool operator==(const Constant& a, const Constant& b) {
  if (a.is_integer_ != b.is_integer_) return false;
  return a.is_integer_ ? a.number_ == b.number_ : a.text_ == b.text_;
}

std::strong_ordering operator<=>(const Constant& a, const Constant& b) {
  if (a.is_integer_ != b.is_integer_) {
    return a.is_integer_ ? std::strong_ordering::less
                         : std::strong_ordering::greater;
  }
  if (a.is_integer_) return a.number_ <=> b.number_;
  int c = a.text_.compare(b.text_);
  return c < 0   ? std::strong_ordering::less
         : c > 0 ? std::strong_ordering::greater
                 : std::strong_ordering::equal;
}

Term Term::make_constant(Constant c) {
  Term t;
  t.kind = Kind::Constant;
  t.constant = std::move(c);
  return t;
}

Term Term::make_variable(std::string name) {
  Term t;
  t.kind = Kind::Variable;
  t.variable = std::move(name);
  return t;
}

Term Term::make_anonymous() { return Term{}; }

bool compare_holds(CompareOp op, const Constant& a, const Constant& b) {
  switch (op) {
    case CompareOp::Lt: return a < b;
    case CompareOp::Le: return a <= b;
    case CompareOp::Gt: return a > b;
    case CompareOp::Ge: return a >= b;
    case CompareOp::Eq: return a == b;
    case CompareOp::Ne: return a != b;
  }
  return false;
}

}  // namespace datalog
