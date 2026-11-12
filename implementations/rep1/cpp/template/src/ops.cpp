#include "jinjalite/ops.hpp"

#include <algorithm>
#include <cmath>
#include <limits>

#include "jinjalite/error.hpp"
#include "jinjalite/format.hpp"
#include "jinjalite/utf8.hpp"

namespace jinjalite {

void require_defined(const Value& v) {
  if (v.is_undefined()) throw Error(ErrorKind::Undefined, "use of an undefined value");
}

bool is_truthy(const Value& v) {
  switch (v.kind()) {
    case Value::Kind::Undefined: require_defined(v); return false;
    case Value::Kind::None: return false;
    case Value::Kind::Bool: return v.as_bool();
    case Value::Kind::Int: return v.as_int() != 0;
    case Value::Kind::Float: return v.as_float() != 0.0;
    case Value::Kind::String: return !v.as_string().empty();
    case Value::Kind::List: return !v.as_list().empty();
    case Value::Kind::Dict: return v.as_dict().size() != 0;
    case Value::Kind::Callable: return true;
  }
  return false;
}

namespace {

[[noreturn]] void type_error(const char* what) { throw Error(ErrorKind::Type, what); }

int64_t wrap_add(int64_t a, int64_t b) {
  return static_cast<int64_t>(static_cast<uint64_t>(a) + static_cast<uint64_t>(b));
}
int64_t wrap_sub(int64_t a, int64_t b) {
  return static_cast<int64_t>(static_cast<uint64_t>(a) - static_cast<uint64_t>(b));
}
int64_t wrap_mul(int64_t a, int64_t b) {
  return static_cast<int64_t>(static_cast<uint64_t>(a) * static_cast<uint64_t>(b));
}

// Python's float floor division and modulo, reproduced exactly.
void float_divmod(double vx, double wx, double& floordiv, double& mod) {
  mod = std::fmod(vx, wx);
  double div = (vx - mod) / wx;
  if (mod != 0.0) {
    if ((wx < 0) != (mod < 0)) {
      mod += wx;
      div -= 1.0;
    }
  } else {
    mod = std::copysign(0.0, wx);
  }
  if (div != 0.0) {
    floordiv = std::floor(div);
    if (div - floordiv > 0.5) floordiv += 1.0;
  } else {
    floordiv = std::copysign(0.0, vx / wx);
  }
}

int64_t int_pow(int64_t base, int64_t exp) {
  uint64_t result = 1;
  uint64_t b = static_cast<uint64_t>(base);
  uint64_t e = static_cast<uint64_t>(exp);
  while (e) {
    if (e & 1) result *= b;
    b *= b;
    e >>= 1;
  }
  return static_cast<int64_t>(result);
}

Value arithmetic(BinaryOp op, const Value& a, const Value& b) {
  const bool both_int = a.is_integral() && b.is_integral();
  switch (op) {
    case BinaryOp::Add:
      if (both_int) return Value::integer(wrap_add(a.integral(), b.integral()));
      return Value::real(a.number() + b.number());
    case BinaryOp::Sub:
      if (both_int) return Value::integer(wrap_sub(a.integral(), b.integral()));
      return Value::real(a.number() - b.number());
    case BinaryOp::Mul:
      if (both_int) return Value::integer(wrap_mul(a.integral(), b.integral()));
      return Value::real(a.number() * b.number());
    case BinaryOp::Div:
      if (b.number() == 0.0) type_error("division by zero");
      return Value::real(a.number() / b.number());
    case BinaryOp::FloorDiv:
      if (both_int) {
        int64_t x = a.integral(), y = b.integral();
        if (y == 0) type_error("division by zero");
        if (y == -1) return Value::integer(wrap_sub(0, x));
        int64_t q = x / y;
        if ((x % y != 0) && ((x < 0) != (y < 0))) --q;
        return Value::integer(q);
      } else {
        double y = b.number();
        if (y == 0.0) type_error("division by zero");
        double q, m;
        float_divmod(a.number(), y, q, m);
        return Value::real(q);
      }
    case BinaryOp::Mod:
      if (both_int) {
        int64_t x = a.integral(), y = b.integral();
        if (y == 0) type_error("modulo by zero");
        if (y == -1) return Value::integer(0);
        int64_t r = x % y;
        if (r != 0 && ((r < 0) != (y < 0))) r += y;
        return Value::integer(r);
      } else {
        double y = b.number();
        if (y == 0.0) type_error("modulo by zero");
        double q, m;
        float_divmod(a.number(), y, q, m);
        return Value::real(m);
      }
    case BinaryOp::Pow:
      if (both_int) {
        int64_t x = a.integral(), y = b.integral();
        if (y >= 0) return Value::integer(int_pow(x, y));
        if (x == 0) type_error("zero to a negative power");
        return Value::real(std::pow(static_cast<double>(x), static_cast<double>(y)));
      } else {
        double x = a.number(), y = b.number();
        if (x == 0.0 && y < 0) type_error("zero to a negative power");
        return Value::real(std::pow(x, y));
      }
    case BinaryOp::Concat: break;
  }
  type_error("bad operands");
}

std::string repeat(const std::string& s, int64_t n) {
  std::string out;
  if (n <= 0) return out;
  out.reserve(s.size() * static_cast<size_t>(n));
  for (int64_t i = 0; i < n; ++i) out += s;
  return out;
}

bool order_less(const Value& a, const Value& b) {
  if (a.is_number() && b.is_number()) {
    if (a.is_integral() && b.is_integral()) return a.integral() < b.integral();
    return a.number() < b.number();
  }
  if (a.is_string() && b.is_string()) return a.as_string() < b.as_string();
  type_error("values cannot be ordered");
}

bool contains(const Value& container, const Value& item) {
  switch (container.kind()) {
    case Value::Kind::String:
      if (!item.is_string()) type_error("'in <string>' requires a string");
      return container.as_string().find(item.as_string()) != std::string::npos;
    case Value::Kind::Dict:
      return item.is_string() && container.as_dict().find(item.as_string()) != nullptr;
    case Value::Kind::List:
      for (const Value& e : container.as_list()) {
        if (values_equal(e, item)) return true;
      }
      return false;
    default:
      type_error("'in' needs a string, list or dict");
  }
}

}  // namespace

Value negate(const Value& v) {
  require_defined(v);
  if (v.is_integral()) return Value::integer(wrap_sub(0, v.integral()));
  if (v.is_float()) return Value::real(-v.as_float());
  type_error("cannot negate a non-number");
}

Value binary_op(BinaryOp op, const Value& a, const Value& b) {
  require_defined(a);
  require_defined(b);
  if (op == BinaryOp::Concat) {
    std::string out;
    append_display(out, a);
    append_display(out, b);
    return Value::string(std::move(out));
  }
  if (a.is_number() && b.is_number()) return arithmetic(op, a, b);
  if (op == BinaryOp::Add) {
    if (a.is_string() && b.is_string()) return Value::string(a.as_string() + b.as_string());
    if (a.is_list() && b.is_list()) {
      List out;
      out.reserve(a.as_list().size() + b.as_list().size());
      out.insert(out.end(), a.as_list().begin(), a.as_list().end());
      out.insert(out.end(), b.as_list().begin(), b.as_list().end());
      return Value::list(std::move(out));
    }
  } else if (op == BinaryOp::Mul) {
    if (a.is_string() && b.is_integral()) return Value::string(repeat(a.as_string(), b.integral()));
    if (a.is_integral() && b.is_string()) return Value::string(repeat(b.as_string(), a.integral()));
  }
  type_error("unsupported operand types");
}

bool values_equal(const Value& a, const Value& b) {
  if (a.is_number() && b.is_number()) {
    if (a.is_integral() && b.is_integral()) return a.integral() == b.integral();
    return a.number() == b.number();
  }
  if (a.kind() != b.kind()) return false;
  switch (a.kind()) {
    case Value::Kind::None: return true;
    case Value::Kind::String: return a.as_string() == b.as_string();
    case Value::Kind::List: {
      if (a.list_ptr() == b.list_ptr()) return true;
      const List &x = a.as_list(), &y = b.as_list();
      if (x.size() != y.size()) return false;
      for (size_t i = 0; i < x.size(); ++i) {
        if (!values_equal(x[i], y[i])) return false;
      }
      return true;
    }
    case Value::Kind::Dict: {
      const Dict &x = a.as_dict(), &y = b.as_dict();
      if (x.size() != y.size()) return false;
      for (const auto& e : x.entries()) {
        const Value* other = y.find(e.first);
        if (!other || !values_equal(e.second, *other)) return false;
      }
      return true;
    }
    case Value::Kind::Callable: return &a.as_callable() == &b.as_callable();
    default: return false;
  }
}

bool compare(CompareOp op, const Value& a, const Value& b) {
  require_defined(a);
  require_defined(b);
  switch (op) {
    case CompareOp::Eq: return values_equal(a, b);
    case CompareOp::Ne: return !values_equal(a, b);
    case CompareOp::Lt: return order_less(a, b);
    case CompareOp::Gt: return order_less(b, a);
    case CompareOp::Le: return !order_less(b, a);
    case CompareOp::Ge: return !order_less(a, b);
    case CompareOp::In: return contains(b, a);
    case CompareOp::NotIn: return !contains(b, a);
  }
  return false;
}

Value get_item(const Value& obj, const Value& key) {
  require_defined(obj);
  require_defined(key);
  if (obj.is_dict()) {
    if (!key.is_string()) return Value();
    const Value* v = obj.as_dict().find(key.as_string());
    return v ? *v : Value();
  }
  if (!key.is_integral()) return Value();
  int64_t i = key.integral();
  if (obj.is_list()) {
    const List& l = obj.as_list();
    int64_t n = static_cast<int64_t>(l.size());
    if (i < 0) i += n;
    if (i < 0 || i >= n) return Value();
    return l[static_cast<size_t>(i)];
  }
  if (obj.is_string()) {
    const std::string& s = obj.as_string();
    if (i < 0) i += static_cast<int64_t>(utf8_length(s));
    if (i < 0) return Value();
    size_t pos = 0;
    for (int64_t k = 0; k < i; ++k) {
      if (pos >= s.size()) return Value();
      pos += utf8_sequence_size(static_cast<unsigned char>(s[pos]));
    }
    if (pos >= s.size()) return Value();
    size_t n = std::min(utf8_sequence_size(static_cast<unsigned char>(s[pos])), s.size() - pos);
    return Value::string(s.substr(pos, n));
  }
  return Value();
}

ListPtr sequence_view(const Value& v) {
  switch (v.kind()) {
    case Value::Kind::Undefined: require_defined(v); break;
    case Value::Kind::List: return v.list_ptr();
    case Value::Kind::Dict: {
      List keys;
      keys.reserve(v.as_dict().size());
      for (const auto& e : v.as_dict().entries()) keys.push_back(Value::string(e.first));
      return std::make_shared<const List>(std::move(keys));
    }
    case Value::Kind::String: {
      List chars;
      for (std::string_view c : utf8_split(v.as_string())) chars.push_back(Value::string(std::string(c)));
      return std::make_shared<const List>(std::move(chars));
    }
    default: break;
  }
  type_error("value is not a sequence");
}

}  // namespace jinjalite
