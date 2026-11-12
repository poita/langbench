#include "jinjalite/format.hpp"

#include <charconv>
#include <cmath>

#include "jinjalite/error.hpp"

namespace jinjalite {

std::string format_float(double d) {
  if (std::isnan(d)) return "nan";
  if (std::isinf(d)) return d > 0 ? "inf" : "-inf";
  if (d == 0) return std::signbit(d) ? "-0.0" : "0.0";

  char buf[64];
  auto res = std::to_chars(buf, buf + sizeof buf, d, std::chars_format::scientific);
  std::string_view s(buf, static_cast<size_t>(res.ptr - buf));
  bool negative = false;
  if (s.front() == '-') {
    negative = true;
    s.remove_prefix(1);
  }
  size_t epos = s.find('e');
  std::string digits;
  for (char c : s.substr(0, epos)) {
    if (c != '.') digits += c;
  }
  std::string_view exp_text = s.substr(epos + 1);
  bool exp_negative = exp_text.front() == '-';
  exp_text.remove_prefix(1);  // sign
  int exponent = 0;
  std::from_chars(exp_text.data(), exp_text.data() + exp_text.size(), exponent);
  if (exp_negative) exponent = -exponent;

  std::string out;
  if (negative) out += '-';
  if (exponent >= -4 && exponent < 16) {
    if (exponent >= 0) {
      size_t int_digits = static_cast<size_t>(exponent) + 1;
      if (digits.size() <= int_digits) {
        out += digits;
        out.append(int_digits - digits.size(), '0');
        out += ".0";
      } else {
        out.append(digits, 0, int_digits);
        out += '.';
        out.append(digits, int_digits, std::string::npos);
      }
    } else {
      out += "0.";
      out.append(static_cast<size_t>(-exponent - 1), '0');
      out += digits;
    }
  } else {
    out += digits[0];
    if (digits.size() > 1) {
      out += '.';
      out.append(digits, 1, std::string::npos);
    }
    out += 'e';
    out += exponent < 0 ? '-' : '+';
    int mag = exponent < 0 ? -exponent : exponent;
    if (mag < 10) out += '0';
    out += std::to_string(mag);
  }
  return out;
}

namespace {

void append_string_repr(std::string& out, const std::string& s) {
  bool has_single = s.find('\'') != std::string::npos;
  bool has_double = s.find('"') != std::string::npos;
  char quote = (has_single && !has_double) ? '"' : '\'';
  out += quote;
  for (char c : s) {
    switch (c) {
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c == quote) out += '\\';
        out += c;
    }
  }
  out += quote;
}

void append_value(std::string& out, const Value& v, bool repr) {
  switch (v.kind()) {
    case Value::Kind::Undefined:
      throw Error(ErrorKind::Undefined, "cannot print an undefined value");
    case Value::Kind::None: out += "None"; break;
    case Value::Kind::Bool: out += v.as_bool() ? "True" : "False"; break;
    case Value::Kind::Int: {
      char buf[32];
      auto res = std::to_chars(buf, buf + sizeof buf, v.as_int());
      out.append(buf, res.ptr);
      break;
    }
    case Value::Kind::Float: out += format_float(v.as_float()); break;
    case Value::Kind::String:
      if (repr) append_string_repr(out, v.as_string());
      else out += v.as_string();
      break;
    case Value::Kind::List: {
      out += '[';
      bool first = true;
      for (const Value& e : v.as_list()) {
        if (!first) out += ", ";
        first = false;
        append_value(out, e, true);
      }
      out += ']';
      break;
    }
    case Value::Kind::Dict: {
      out += '{';
      bool first = true;
      for (const auto& e : v.as_dict().entries()) {
        if (!first) out += ", ";
        first = false;
        append_string_repr(out, e.first);
        out += ": ";
        append_value(out, e.second, true);
      }
      out += '}';
      break;
    }
    case Value::Kind::Callable: out += "<macro>"; break;
  }
}

}  // namespace

void append_display(std::string& out, const Value& v) { append_value(out, v, false); }
void append_repr(std::string& out, const Value& v) { append_value(out, v, true); }

std::string to_display(const Value& v) {
  std::string out;
  append_display(out, v);
  return out;
}

}  // namespace jinjalite
