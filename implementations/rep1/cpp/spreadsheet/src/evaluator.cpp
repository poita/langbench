#include "spreadsheet/evaluator.h"

#include <cmath>
#include <optional>

namespace spreadsheet {
namespace {

using Kind = Value::Kind;

class Evaluator {
 public:
  explicit Evaluator(const CellLookup& cells) : cells_(cells) {}

  Value eval(const Expr& e) {
    switch (e.kind) {
      case Expr::Kind::Number: return Value::number(e.number);
      case Expr::Kind::String: return Value::string(e.text);
      case Expr::Kind::Ref: return cells_.value_at(e.ref);
      case Expr::Kind::Range: return Value::error(ErrorCode::Value);  // not reachable from the parser
      case Expr::Kind::Negate: {
        double x;
        if (auto err = number_operand(*e.args[0], x)) return *err;
        return Value::number(-x);
      }
      case Expr::Kind::Binary: return eval_binary(e);
      case Expr::Kind::If: return eval_if(e);
      case Expr::Kind::Aggregate: return eval_aggregate(e);
    }
    return Value::error(ErrorCode::Value);
  }

 private:
  // Evaluates `e` as an arithmetic operand: errors propagate, strings give
  // #VALUE!, empty is 0. On success stores the number in `out`.
  std::optional<Value> number_operand(const Expr& e, double& out) {
    Value v = eval(e);
    return coerce(v, out);
  }
  static std::optional<Value> coerce(const Value& v, double& out) {
    switch (v.kind()) {
      case Kind::Error: return v;
      case Kind::String: return Value::error(ErrorCode::Value);
      case Kind::Empty: out = 0; return std::nullopt;
      case Kind::Number: out = v.as_number(); return std::nullopt;
    }
    return Value::error(ErrorCode::Value);
  }

  Value eval_binary(const Expr& e) {
    switch (e.op) {
      case BinaryOp::Add: case BinaryOp::Sub: case BinaryOp::Mul: case BinaryOp::Div: {
        double a, b;
        if (auto err = number_operand(*e.args[0], a)) return *err;
        if (auto err = number_operand(*e.args[1], b)) return *err;
        double r = 0;
        switch (e.op) {
          case BinaryOp::Add: r = a + b; break;
          case BinaryOp::Sub: r = a - b; break;
          case BinaryOp::Mul: r = a * b; break;
          default:
            if (b == 0) return Value::error(ErrorCode::DivZero);
            r = a / b;
        }
        if (!std::isfinite(r)) return Value::error(ErrorCode::Value);
        return Value::number(r);
      }
      case BinaryOp::Concat: {
        Value a = eval(*e.args[0]);
        if (a.is_error()) return a;
        Value b = eval(*e.args[1]);
        if (b.is_error()) return b;
        std::string s = a.is_string() ? a.as_string() : a.display();
        if (b.is_string()) s += b.as_string();
        else s += b.display();
        return Value::string(std::move(s));
      }
      default: break;
    }
    Value a = eval(*e.args[0]);
    if (a.is_error()) return a;
    Value b = eval(*e.args[1]);
    if (b.is_error()) return b;
    return compare(e.op, std::move(a), std::move(b));
  }

  static Value compare(BinaryOp op, Value a, Value b) {
    if (a.is_empty() && b.is_empty()) {
      a = Value::number(0);
      b = Value::number(0);
    } else if (a.is_empty()) {
      a = b.is_number() ? Value::number(0) : Value::string("");
    } else if (b.is_empty()) {
      b = a.is_number() ? Value::number(0) : Value::string("");
    }
    int order;  // <0, 0, >0
    if (a.is_number() != b.is_number()) {
      if (op == BinaryOp::Eq) return Value::number(0);
      if (op == BinaryOp::Ne) return Value::number(1);
      return Value::error(ErrorCode::Value);
    }
    if (a.is_number()) {
      order = a.as_number() < b.as_number() ? -1 : (a.as_number() > b.as_number() ? 1 : 0);
    } else {
      int c = a.as_string().compare(b.as_string());  // byte-wise == code point order for UTF-8
      order = c < 0 ? -1 : (c > 0 ? 1 : 0);
    }
    bool r = false;
    switch (op) {
      case BinaryOp::Eq: r = order == 0; break;
      case BinaryOp::Ne: r = order != 0; break;
      case BinaryOp::Lt: r = order < 0; break;
      case BinaryOp::Gt: r = order > 0; break;
      case BinaryOp::Le: r = order <= 0; break;
      case BinaryOp::Ge: r = order >= 0; break;
      default: break;
    }
    return Value::number(r ? 1 : 0);
  }

  Value eval_if(const Expr& e) {
    double c;
    if (auto err = number_operand(*e.args[0], c)) return *err;
    return eval(*e.args[c != 0 ? 1 : 2]);
  }

  struct Accumulator {
    std::size_t count = 0;
    double sum = 0;
    double min = 0;
    double max = 0;
    void add(double x) {
      if (count == 0) min = max = x;
      else {
        if (x < min) min = x;
        if (x > max) max = x;
      }
      sum += x;
      ++count;
    }
  };

  Value eval_aggregate(const Expr& e) {
    Accumulator acc;
    for (const auto& arg : e.args) {
      if (arg->kind == Expr::Kind::Range) {
        const CellRange& rg = arg->range;
        for (std::uint16_t r = rg.first.row; r <= rg.last.row; ++r) {
          for (std::uint16_t c = rg.first.col; c <= rg.last.col; ++c) {
            const Value& v = cells_.value_at(CellRef{c, r});
            if (v.is_error()) return v;
            if (v.is_number()) acc.add(v.as_number());
          }
        }
      } else {
        Value v = eval(*arg);
        if (v.is_error()) return v;
        if (v.is_string()) return Value::error(ErrorCode::Value);
        if (v.is_number()) acc.add(v.as_number());
      }
    }
    switch (e.fn) {
      case AggregateFn::Count: return Value::number(static_cast<double>(acc.count));
      case AggregateFn::Min: return Value::number(acc.min);
      case AggregateFn::Max: return Value::number(acc.max);
      case AggregateFn::Sum:
        if (!std::isfinite(acc.sum)) return Value::error(ErrorCode::Value);
        return Value::number(acc.sum);
      case AggregateFn::Avg: {
        if (acc.count == 0) return Value::error(ErrorCode::DivZero);
        if (!std::isfinite(acc.sum)) return Value::error(ErrorCode::Value);
        return Value::number(acc.sum / static_cast<double>(acc.count));
      }
    }
    return Value::error(ErrorCode::Value);
  }

  const CellLookup& cells_;
};

}  // namespace

Value evaluate(const Formula& formula, const CellLookup& cells) {
  if (formula.has_invalid_reference()) return Value::error(ErrorCode::Ref);
  Value v = Evaluator(cells).eval(formula.root());
  if (v.is_empty()) return Value::number(0);
  return v;
}

}  // namespace spreadsheet
