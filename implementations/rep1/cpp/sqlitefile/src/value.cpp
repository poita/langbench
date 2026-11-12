#include "sqlitefile/value.hpp"

#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace sqlitefile {

Value Value::integer(std::int64_t v) {
  Value r;
  r.type_ = Type::Integer;
  r.int_ = v;
  return r;
}

Value Value::real(double v) {
  Value r;
  r.type_ = Type::Real;
  r.real_ = v;
  return r;
}

Value Value::text(std::string bytes) {
  Value r;
  r.type_ = Type::Text;
  r.bytes_ = std::move(bytes);
  return r;
}

Value Value::blob(std::string bytes) {
  Value r;
  r.type_ = Type::Blob;
  r.bytes_ = std::move(bytes);
  return r;
}

double Value::toDouble() const {
  return type_ == Type::Integer ? static_cast<double>(int_) : real_;
}

bool operator==(const Value& a, const Value& b) {
  if (a.type_ != b.type_) return false;
  switch (a.type_) {
    case Type::Null: return true;
    case Type::Integer: return a.int_ == b.int_;
    case Type::Real: return a.real_ == b.real_;
    default: return a.bytes_ == b.bytes_;
  }
}

namespace {

int rank(Type t) {
  switch (t) {
    case Type::Null: return 0;
    case Type::Integer:
    case Type::Real: return 1;
    case Type::Text: return 2;
    case Type::Blob: return 3;
  }
  return 0;
}

bool isDigit(char c) { return c >= '0' && c <= '9'; }

}  // namespace

int compare(const Value& a, const Value& b) {
  int ra = rank(a.type()), rb = rank(b.type());
  if (ra != rb) return ra < rb ? -1 : 1;
  switch (ra) {
    case 0: return 0;
    case 1: {
      if (a.type() == Type::Integer && b.type() == Type::Integer) {
        auto x = a.asInteger(), y = b.asInteger();
        return x < y ? -1 : (x > y ? 1 : 0);
      }
      double x = a.toDouble(), y = b.toDouble();
      return x < y ? -1 : (x > y ? 1 : 0);
    }
    default: {
      const std::string& x = a.bytes();
      const std::string& y = b.bytes();
      std::size_t n = x.size() < y.size() ? x.size() : y.size();
      int c = n ? std::memcmp(x.data(), y.data(), n) : 0;  // unsigned bytes
      if (c != 0) return c < 0 ? -1 : 1;
      return x.size() < y.size() ? -1 : (x.size() > y.size() ? 1 : 0);
    }
  }
}

Affinity affinityFromDeclaredType(std::string_view declared) {
  std::string t(declared);
  for (char& c : t)
    if (c >= 'a' && c <= 'z') c = static_cast<char>(c - 'a' + 'A');
  auto has = [&](const char* s) { return t.find(s) != std::string::npos; };
  if (has("INT")) return Affinity::Integer;
  if (has("CHAR") || has("CLOB") || has("TEXT")) return Affinity::Text;
  if (has("BLOB") || t.empty()) return Affinity::Blob;
  if (has("REAL") || has("FLOA") || has("DOUB")) return Affinity::Real;
  return Affinity::Numeric;
}

std::optional<Value> parseNumericConstant(std::string_view s) {
  while (!s.empty() && (s.front() == ' ' || s.front() == '\t')) s.remove_prefix(1);
  while (!s.empty() && (s.back() == ' ' || s.back() == '\t')) s.remove_suffix(1);
  std::size_t i = 0, n = s.size();
  if (i < n && (s[i] == '+' || s[i] == '-')) ++i;
  std::size_t int_start = i;
  while (i < n && isDigit(s[i])) ++i;
  bool real = false;
  if (i > int_start) {
    if (i < n && s[i] == '.') {
      real = true;
      ++i;
      while (i < n && isDigit(s[i])) ++i;
    }
  } else {
    if (i < n && s[i] == '.') {
      real = true;
      ++i;
      std::size_t frac = i;
      while (i < n && isDigit(s[i])) ++i;
      if (i == frac) return std::nullopt;
    } else {
      return std::nullopt;
    }
  }
  if (i < n && (s[i] == 'e' || s[i] == 'E')) {
    real = true;
    ++i;
    if (i < n && (s[i] == '+' || s[i] == '-')) ++i;
    std::size_t exp = i;
    while (i < n && isDigit(s[i])) ++i;
    if (i == exp) return std::nullopt;
  }
  if (i != n) return std::nullopt;
  if (!real) {
    const char* first = s.data();
    if (*first == '+') ++first;
    std::int64_t v = 0;
    auto r = std::from_chars(first, s.data() + n, v);
    if (r.ec == std::errc() && r.ptr == s.data() + n) return Value::integer(v);
    // Too large for 64 bits: fall through to a REAL.
  }
  std::string copy(s);
  return Value::real(std::strtod(copy.c_str(), nullptr));
}

Value applyAffinityToLiteral(const Value& lit, Affinity affinity) {
  switch (affinity) {
    case Affinity::Text:
      if (lit.isNumber()) return Value::text(format(lit));
      return lit;
    case Affinity::Integer:
    case Affinity::Real:
    case Affinity::Numeric:
      if (lit.type() == Type::Text) {
        if (auto n = parseNumericConstant(lit.bytes())) return *n;
      }
      return lit;
    case Affinity::Blob:
      return lit;
  }
  return lit;
}

std::string formatReal(double v) {
  if (v == 0) return "0.0";
  char buf[64];
  std::snprintf(buf, sizeof buf, "%.15g", v);
  std::string s(buf);
  if (!std::isfinite(v)) return s;
  std::size_t e = s.find('e');
  std::string mantissa = e == std::string::npos ? s : s.substr(0, e);
  std::string rest = e == std::string::npos ? "" : s.substr(e);
  if (mantissa.find('.') == std::string::npos) mantissa += ".0";
  return mantissa + rest;
}

void appendFormatted(std::string& out, const Value& v) {
  switch (v.type()) {
    case Type::Null: out += "NULL"; break;
    case Type::Integer: out += std::to_string(v.asInteger()); break;
    case Type::Real: out += formatReal(v.asReal()); break;
    case Type::Text: out += v.bytes(); break;
    case Type::Blob: {
      static const char* hex = "0123456789ABCDEF";
      for (unsigned char c : v.bytes()) {
        out.push_back(hex[c >> 4]);
        out.push_back(hex[c & 15]);
      }
      break;
    }
  }
}

std::string format(const Value& v) {
  std::string s;
  appendFormatted(s, v);
  return s;
}

}  // namespace sqlitefile
