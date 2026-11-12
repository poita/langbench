#include "minisql/value.hpp"

#include <utility>

namespace minisql {

Value Value::integer(std::int64_t v) {
  Value r;
  r.kind_ = Kind::Integer;
  r.num_ = v;
  return r;
}

Value Value::text(std::string s) {
  Value r;
  r.kind_ = Kind::Text;
  r.text_ = std::move(s);
  return r;
}

Value Value::real_from_hundredths(std::int64_t hundredths) {
  Value r;
  r.kind_ = Kind::Real;
  r.num_ = hundredths;
  return r;
}

namespace {

int sign(int c) { return c < 0 ? -1 : (c > 0 ? 1 : 0); }

__int128 hundredths_of(const Value& v) {
  return v.is_integer() ? static_cast<__int128>(v.as_integer()) * 100
                        : static_cast<__int128>(v.as_hundredths());
}

}  // namespace

int compare(const Value& a, const Value& b) {
  if (a.is_null() || b.is_null()) {
    return (a.is_null() ? 0 : 1) - (b.is_null() ? 0 : 1);
  }
  const bool na = a.is_number();
  const bool nb = b.is_number();
  if (na && nb) {
    if (a.is_integer() && b.is_integer()) {
      return a.as_integer() < b.as_integer()
                 ? -1
                 : (a.as_integer() > b.as_integer() ? 1 : 0);
    }
    const __int128 x = hundredths_of(a);
    const __int128 y = hundredths_of(b);
    return x < y ? -1 : (x > y ? 1 : 0);
  }
  if (na != nb) return na ? -1 : 1;
  return sign(a.as_text().compare(b.as_text()));
}

std::string to_string(const Value& v) {
  switch (v.kind()) {
    case Value::Kind::Null:
      return "NULL";
    case Value::Kind::Integer:
      return std::to_string(v.as_integer());
    case Value::Kind::Text:
      return v.as_text();
    case Value::Kind::Real: {
      const std::int64_t h = v.as_hundredths();
      const std::uint64_t mag =
          h < 0 ? 0 - static_cast<std::uint64_t>(h) : static_cast<std::uint64_t>(h);
      std::string out = h < 0 ? "-" : "";
      out += std::to_string(mag / 100);
      out += '.';
      const std::uint64_t frac = mag % 100;
      out += static_cast<char>('0' + frac / 10);
      out += static_cast<char>('0' + frac % 10);
      return out;
    }
  }
  return "NULL";
}

}  // namespace minisql
