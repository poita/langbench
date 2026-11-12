#include "scheme/numeric.hpp"

namespace scheme::num {

Value from_bigint(BigInt v) {
  if (v.fits_int64()) return Value::integer(v.to_int64());
  return Value(new BigIntObject(std::move(v)));
}

BigInt to_bigint(const Value& v) {
  if (v.is_fixnum()) return BigInt(v.as_fixnum());
  return v.as<BigIntObject>()->value;
}

Value parse(std::string_view digits) {
  size_t start = (!digits.empty() && (digits[0] == '+' || digits[0] == '-')) ? 1 : 0;
  if (digits.size() - start <= 18) {
    int64_t v = 0;
    for (size_t i = start; i < digits.size(); ++i) v = v * 10 + (digits[i] - '0');
    return Value::integer(digits[0] == '-' ? -v : v);
  }
  return from_bigint(BigInt::from_decimal(digits));
}

std::string to_string(const Value& v) {
  if (v.is_fixnum()) return std::to_string(v.as_fixnum());
  return v.as<BigIntObject>()->value.to_string();
}

Value add(const Value& a, const Value& b) {
  if (a.is_fixnum() && b.is_fixnum()) {
    int64_t r;
    if (!__builtin_add_overflow(a.as_fixnum(), b.as_fixnum(), &r)) return Value::integer(r);
  }
  return from_bigint(to_bigint(a) + to_bigint(b));
}

Value sub(const Value& a, const Value& b) {
  if (a.is_fixnum() && b.is_fixnum()) {
    int64_t r;
    if (!__builtin_sub_overflow(a.as_fixnum(), b.as_fixnum(), &r)) return Value::integer(r);
  }
  return from_bigint(to_bigint(a) - to_bigint(b));
}

Value mul(const Value& a, const Value& b) {
  if (a.is_fixnum() && b.is_fixnum()) {
    int64_t r;
    if (!__builtin_mul_overflow(a.as_fixnum(), b.as_fixnum(), &r)) return Value::integer(r);
  }
  return from_bigint(to_bigint(a) * to_bigint(b));
}

Value negate(const Value& a) { return sub(Value::integer(0), a); }

bool is_zero(const Value& a) { return a.is_fixnum() && a.as_fixnum() == 0; }

Value quotient(const Value& a, const Value& b) {
  if (a.is_fixnum() && b.is_fixnum() && !(a.as_fixnum() == INT64_MIN && b.as_fixnum() == -1))
    return Value::integer(a.as_fixnum() / b.as_fixnum());
  BigInt q, r;
  BigInt::divmod(to_bigint(a), to_bigint(b), q, r);
  return from_bigint(std::move(q));
}

Value remainder(const Value& a, const Value& b) {
  if (a.is_fixnum() && b.is_fixnum()) {
    if (b.as_fixnum() == -1) return Value::integer(0);
    return Value::integer(a.as_fixnum() % b.as_fixnum());
  }
  BigInt q, r;
  BigInt::divmod(to_bigint(a), to_bigint(b), q, r);
  return from_bigint(std::move(r));
}

int compare(const Value& a, const Value& b) {
  if (a.is_fixnum() && b.is_fixnum()) {
    int64_t x = a.as_fixnum(), y = b.as_fixnum();
    return x < y ? -1 : (x > y ? 1 : 0);
  }
  return BigInt::compare(to_bigint(a), to_bigint(b));
}

}  // namespace scheme::num
