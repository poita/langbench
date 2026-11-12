#include "kiln/ast.hpp"

namespace kiln {

const char* opSpelling(Op op) noexcept {
  switch (op) {
    case Op::Or: return "||";
    case Op::And: return "&&";
    case Op::Eq: return "==";
    case Op::Ne: return "!=";
    case Op::Lt: return "<";
    case Op::Le: return "<=";
    case Op::Gt: return ">";
    case Op::Ge: return ">=";
    case Op::Concat: return "++";
    case Op::Tilde: return "~";
    case Op::Add: return "+";
    case Op::Sub: return "-";
    case Op::Mul: return "*";
    case Op::Div: return "/";
    case Op::Mod: return "%";
    case Op::Not: return "!";
    case Op::Neg: return "-";
  }
  return "?";
}

Stmt::Stmt() = default;
Stmt::~Stmt() = default;
Stmt::Stmt(Stmt&&) noexcept = default;
Stmt& Stmt::operator=(Stmt&&) noexcept = default;

}  // namespace kiln
