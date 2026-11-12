#include "datalog/ast.h"

#include <utility>

namespace datalog {

Constant Constant::integer(std::int64_t value) {
  Constant c;
  c.is_integer_ = true;
  c.integer_ = value;
  return c;
}

Constant Constant::symbol(std::string name) {
  Constant c;
  c.is_integer_ = false;
  c.symbol_ = std::move(name);
  return c;
}

std::string Constant::to_string() const {
  return is_integer_ ? std::to_string(integer_) : symbol_;
}

bool operator==(const Constant& a, const Constant& b) {
  if (a.is_integer_ != b.is_integer_) return false;
  return a.is_integer_ ? a.integer_ == b.integer_ : a.symbol_ == b.symbol_;
}

bool operator<(const Constant& a, const Constant& b) {
  if (a.is_integer_ != b.is_integer_) return a.is_integer_;
  return a.is_integer_ ? a.integer_ < b.integer_ : a.symbol_ < b.symbol_;
}

Term Term::constant(Constant c) {
  Term t;
  t.kind_ = Kind::Constant;
  t.constant_ = std::move(c);
  return t;
}

Term Term::variable(std::string name) {
  Term t;
  t.kind_ = Kind::Variable;
  t.name_ = std::move(name);
  return t;
}

Term Term::anonymous() { return Term(); }

const char* to_string(CompareOp op) {
  switch (op) {
    case CompareOp::Lt: return "<";
    case CompareOp::Le: return "<=";
    case CompareOp::Gt: return ">";
    case CompareOp::Ge: return ">=";
    case CompareOp::Eq: return "=";
    case CompareOp::Ne: return "!=";
  }
  return "?";
}

Literal Literal::positive(Atom a) {
  Literal l;
  l.kind = Kind::Positive;
  l.atom = std::move(a);
  return l;
}

Literal Literal::negative(Atom a) {
  Literal l;
  l.kind = Kind::Negative;
  l.atom = std::move(a);
  return l;
}

Literal Literal::comparison(Term lhs, CompareOp op, Term rhs) {
  Literal l;
  l.kind = Kind::Comparison;
  l.op = op;
  l.lhs = std::move(lhs);
  l.rhs = std::move(rhs);
  return l;
}

std::string to_string(const Term& term) {
  switch (term.kind()) {
    case Term::Kind::Constant: return term.constant_value().to_string();
    case Term::Kind::Variable: return term.variable_name();
    case Term::Kind::Anonymous: return "_";
  }
  return "?";
}

std::string to_string(const Atom& atom) {
  std::string s = atom.predicate + "(";
  for (std::size_t i = 0; i < atom.args.size(); ++i) {
    if (i) s += ", ";
    s += to_string(atom.args[i]);
  }
  return s + ")";
}

}  // namespace datalog
