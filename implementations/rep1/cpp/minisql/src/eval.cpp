#include <cstdint>

#include "internal.hpp"
#include "minisql/like.hpp"

namespace minisql::detail {

namespace {

enum class Tri { False, True, Unknown };

Tri truth(const Value& v) {
  switch (v.kind()) {
    case Value::Kind::Null: return Tri::Unknown;
    case Value::Kind::Integer: return v.as_integer() != 0 ? Tri::True : Tri::False;
    case Value::Kind::Real: return v.as_hundredths() != 0 ? Tri::True : Tri::False;
    case Value::Kind::Text: return Tri::False;  // not exercised
  }
  return Tri::Unknown;
}

Value from_tri(Tri t) {
  return t == Tri::Unknown ? Value::null() : Value::integer(t == Tri::True ? 1 : 0);
}

Value arithmetic(BinaryOp op, const Value& a, const Value& b) {
  if (!a.is_integer() || !b.is_integer()) return Value::null();  // NULL (or unspecified)
  const std::int64_t x = a.as_integer(), y = b.as_integer();
  const auto ux = static_cast<std::uint64_t>(x), uy = static_cast<std::uint64_t>(y);
  switch (op) {
    case BinaryOp::Add: return Value::integer(static_cast<std::int64_t>(ux + uy));
    case BinaryOp::Sub: return Value::integer(static_cast<std::int64_t>(ux - uy));
    case BinaryOp::Mul: return Value::integer(static_cast<std::int64_t>(ux * uy));
    case BinaryOp::Div:
      if (y == 0) return Value::null();
      if (y == -1) return Value::integer(static_cast<std::int64_t>(0 - ux));
      return Value::integer(x / y);
    case BinaryOp::Mod:
      if (y == 0) return Value::null();
      if (y == -1) return Value::integer(0);
      return Value::integer(x % y);
    default: return Value::null();
  }
}

Value comparison(BinaryOp op, const Value& a, const Value& b) {
  if (a.is_null() || b.is_null()) return Value::null();
  const int c = compare(a, b);
  bool r = false;
  switch (op) {
    case BinaryOp::Eq: r = c == 0; break;
    case BinaryOp::Ne: r = c != 0; break;
    case BinaryOp::Lt: r = c < 0; break;
    case BinaryOp::Le: r = c <= 0; break;
    case BinaryOp::Gt: r = c > 0; break;
    case BinaryOp::Ge: r = c >= 0; break;
    default: break;
  }
  return Value::integer(r ? 1 : 0);
}

std::string as_like_text(const Value& v) { return v.is_text() ? v.as_text() : to_string(v); }

}  // namespace

bool is_true(const Value& v) { return truth(v) == Tri::True; }

Value evaluate(const Expr& e, const EvalContext& ctx) {
  switch (e.kind) {
    case ExprKind::Literal:
      return e.literal;
    case ExprKind::Column:
      return (*ctx.rows[e.table])[static_cast<std::size_t>(e.column)];
    case ExprKind::Aggregate:
      return ctx.aggregates[e.agg_index];
    case ExprKind::Unary: {
      const Value v = evaluate(*e.lhs, ctx);
      if (e.unary_op == UnaryOp::Not) {
        const Tri t = truth(v);
        return from_tri(t == Tri::Unknown ? t : (t == Tri::True ? Tri::False : Tri::True));
      }
      if (!v.is_integer()) return Value::null();
      return Value::integer(static_cast<std::int64_t>(0 - static_cast<std::uint64_t>(v.as_integer())));
    }
    case ExprKind::IsNull: {
      const bool null = evaluate(*e.lhs, ctx).is_null();
      return Value::integer(null != e.negated ? 1 : 0);
    }
    case ExprKind::Like: {
      const Value s = evaluate(*e.lhs, ctx);
      const Value p = evaluate(*e.rhs, ctx);
      if (s.is_null() || p.is_null()) return Value::null();
      const bool m = like_match(as_like_text(s), as_like_text(p));
      return Value::integer(m != e.negated ? 1 : 0);
    }
    case ExprKind::Binary: {
      if (e.binary_op == BinaryOp::And || e.binary_op == BinaryOp::Or) {
        const bool is_and = e.binary_op == BinaryOp::And;
        const Tri l = truth(evaluate(*e.lhs, ctx));
        if (is_and && l == Tri::False) return Value::integer(0);
        if (!is_and && l == Tri::True) return Value::integer(1);
        const Tri r = truth(evaluate(*e.rhs, ctx));
        if (is_and) {
          if (r == Tri::False) return Value::integer(0);
          return from_tri(l == Tri::True && r == Tri::True ? Tri::True : Tri::Unknown);
        }
        if (r == Tri::True) return Value::integer(1);
        return from_tri(l == Tri::False && r == Tri::False ? Tri::False : Tri::Unknown);
      }
      const Value a = evaluate(*e.lhs, ctx);
      const Value b = evaluate(*e.rhs, ctx);
      switch (e.binary_op) {
        case BinaryOp::Add: case BinaryOp::Sub: case BinaryOp::Mul:
        case BinaryOp::Div: case BinaryOp::Mod:
          return arithmetic(e.binary_op, a, b);
        default:
          return comparison(e.binary_op, a, b);
      }
    }
  }
  return Value::null();
}

}  // namespace minisql::detail
