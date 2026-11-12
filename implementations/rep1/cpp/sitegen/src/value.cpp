#include "sitegen/value.hpp"

#include <charconv>
#include <cmath>

namespace sitegen {

Value Value::none() {
  Value v;
  v.kind_ = Kind::None;
  return v;
}
Value Value::boolean(bool b) {
  Value v;
  v.kind_ = Kind::Bool;
  v.prim_.b = b;
  return v;
}
Value Value::integer(std::int64_t i) {
  Value v;
  v.kind_ = Kind::Int;
  v.prim_.i = i;
  return v;
}
Value Value::real(double d) {
  Value v;
  v.kind_ = Kind::Float;
  v.prim_.d = d;
  return v;
}
Value Value::string(std::string s) {
  Value v;
  v.kind_ = Kind::String;
  v.ptr_ = std::make_shared<const std::string>(std::move(s));
  return v;
}
Value Value::list(List items) {
  Value v;
  v.kind_ = Kind::List;
  v.ptr_ = std::make_shared<const List>(std::move(items));
  return v;
}
Value Value::dict(Dict d) {
  Value v;
  v.kind_ = Kind::Dict;
  v.ptr_ = std::make_shared<const Dict>(std::move(d));
  return v;
}
Value Value::callable(std::shared_ptr<const Callable> c) {
  Value v;
  v.kind_ = Kind::Callable;
  v.ptr_ = std::move(c);
  return v;
}

double Value::number_as_double() const {
  switch (kind_) {
    case Kind::Bool: return prim_.b ? 1.0 : 0.0;
    case Kind::Int: return static_cast<double>(prim_.i);
    case Kind::Float: return prim_.d;
    default: return 0.0;
  }
}

std::size_t Dict::find_index(std::string_view key) const {
  if (index_.empty()) {
    for (std::size_t i = 0; i < entries_.size(); ++i) {
      if (entries_[i].first == key) return i;
    }
    return kNotFound;
  }
  const auto it = index_.find(key);
  return it == index_.end() ? kNotFound : it->second;
}

void Dict::set(std::string key, Value value) {
  const std::size_t pos = find_index(key);
  if (pos != kNotFound) {
    entries_[pos].second = std::move(value);
    return;
  }
  entries_.emplace_back(std::move(key), std::move(value));
  if (index_.empty() && entries_.size() > kLinearLimit) {
    for (std::size_t i = 0; i < entries_.size(); ++i) index_.emplace(entries_[i].first, i);
  } else if (!index_.empty()) {
    index_.emplace(entries_.back().first, entries_.size() - 1);
  }
}

const Value* Dict::find(std::string_view key) const {
  const std::size_t pos = find_index(key);
  return pos == kNotFound ? nullptr : &entries_[pos].second;
}

std::string format_float(double d) {
  if (std::isnan(d)) return "nan";
  if (std::isinf(d)) return d < 0 ? "-inf" : "inf";
  if (d == 0) return std::signbit(d) ? "-0.0" : "0.0";
  char buf[64];
  const auto res = std::to_chars(buf, buf + sizeof buf, d, std::chars_format::scientific);
  std::string_view s(buf, static_cast<std::size_t>(res.ptr - buf));
  std::string out;
  if (s.front() == '-') {
    out.push_back('-');
    s.remove_prefix(1);
  }
  const std::size_t epos = s.find('e');
  std::string digits;
  for (const char c : s.substr(0, epos)) {
    if (c != '.') digits.push_back(c);
  }
  const int exp10 = std::atoi(std::string(s.substr(epos + 1)).c_str());
  if (exp10 >= -4 && exp10 < 16) {
    if (exp10 >= 0) {
      const std::size_t int_len = static_cast<std::size_t>(exp10) + 1;
      if (digits.size() <= int_len) {
        out += digits;
        out.append(int_len - digits.size(), '0');
        out += ".0";
      } else {
        out += digits.substr(0, int_len);
        out.push_back('.');
        out += digits.substr(int_len);
      }
    } else {
      out += "0.";
      out.append(static_cast<std::size_t>(-exp10 - 1), '0');
      out += digits;
    }
  } else {
    out.push_back(digits[0]);
    if (digits.size() > 1) {
      out.push_back('.');
      out += digits.substr(1);
    }
    out.push_back('e');
    out.push_back(exp10 < 0 ? '-' : '+');
    const int a = exp10 < 0 ? -exp10 : exp10;
    if (a < 10) out.push_back('0');
    out += std::to_string(a);
  }
  return out;
}

namespace {

std::string quote_string(const std::string& s) {
  const char quote = (s.find('\'') != std::string::npos && s.find('"') == std::string::npos) ? '"' : '\'';
  std::string out(1, quote);
  for (const char c : s) {
    if (c == '\\') out += "\\\\";
    else if (c == '\n') out += "\\n";
    else if (c == '\r') out += "\\r";
    else if (c == '\t') out += "\\t";
    else if (c == quote) {
      out += '\\';
      out += c;
    } else out += c;
  }
  out += quote;
  return out;
}

}  // namespace

std::string repr(const Value& v) {
  switch (v.kind()) {
    case Value::Kind::String:
      return quote_string(v.as_string());
    case Value::Kind::List: {
      std::string out = "[";
      bool first = true;
      for (const Value& item : v.as_list()) {
        if (!first) out += ", ";
        first = false;
        out += repr(item);
      }
      return out + "]";
    }
    case Value::Kind::Dict: {
      std::string out = "{";
      bool first = true;
      for (const auto& [key, value] : v.as_dict().entries()) {
        if (!first) out += ", ";
        first = false;
        out += quote_string(key);
        out += ": ";
        out += repr(value);
      }
      return out + "}";
    }
    default:
      return to_display_string(v);
  }
}

std::string to_display_string(const Value& v) {
  switch (v.kind()) {
    case Value::Kind::Undefined: return "";
    case Value::Kind::None: return "None";
    case Value::Kind::Bool: return v.as_bool() ? "True" : "False";
    case Value::Kind::Int: return std::to_string(v.as_int());
    case Value::Kind::Float: return format_float(v.as_float());
    case Value::Kind::String: return v.as_string();
    case Value::Kind::List:
    case Value::Kind::Dict: return repr(v);
    case Value::Kind::Callable: return "";
  }
  return "";
}

bool values_equal(const Value& a, const Value& b) {
  if (a.is_number() && b.is_number()) {
    if (a.is_float() || b.is_float()) return a.number_as_double() == b.number_as_double();
    const std::int64_t x = a.is_bool() ? a.as_bool() : a.as_int();
    const std::int64_t y = b.is_bool() ? b.as_bool() : b.as_int();
    return x == y;
  }
  if (a.kind() != b.kind()) return false;
  switch (a.kind()) {
    case Value::Kind::None: return true;
    case Value::Kind::String: return a.as_string() == b.as_string();
    case Value::Kind::List: {
      const List& x = a.as_list();
      const List& y = b.as_list();
      if (x.size() != y.size()) return false;
      for (std::size_t i = 0; i < x.size(); ++i) {
        if (!values_equal(x[i], y[i])) return false;
      }
      return true;
    }
    case Value::Kind::Dict: {
      const Dict& x = a.as_dict();
      const Dict& y = b.as_dict();
      if (x.size() != y.size()) return false;
      for (const auto& [key, value] : x.entries()) {
        const Value* other = y.find(key);
        if (other == nullptr || !values_equal(value, *other)) return false;
      }
      return true;
    }
    default: return false;
  }
}

}  // namespace sitegen
