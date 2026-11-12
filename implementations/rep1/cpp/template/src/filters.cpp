#include "jinjalite/filters.hpp"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <numeric>

#include "jinjalite/error.hpp"
#include "jinjalite/format.hpp"
#include "jinjalite/lexer.hpp"
#include "jinjalite/ops.hpp"
#include "jinjalite/utf8.hpp"

namespace jinjalite {
namespace {

using Args = std::vector<Value>;

[[noreturn]] void type_error(const char* what) { throw Error(ErrorKind::Type, what); }

Value upper(const Value& in, const Args&) {
  std::string s = to_display(in);
  for (char& c : s) {
    if (c >= 'a' && c <= 'z') c = static_cast<char>(c - 'a' + 'A');
  }
  return Value::string(std::move(s));
}

std::string ascii_lower(std::string s) {
  for (char& c : s) {
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
  }
  return s;
}

Value lower(const Value& in, const Args&) { return Value::string(ascii_lower(to_display(in))); }

Value trim(const Value& in, const Args&) {
  std::string s = to_display(in);
  size_t b = 0, e = s.size();
  while (b < e && is_template_space(s[b])) ++b;
  while (e > b && is_template_space(s[e - 1])) --e;
  return Value::string(s.substr(b, e - b));
}

Value escape(const Value& in, const Args&) {
  std::string s = to_display(in);
  std::string out;
  out.reserve(s.size());
  for (char c : s) {
    switch (c) {
      case '&': out += "&amp;"; break;
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      case '"': out += "&#34;"; break;
      case '\'': out += "&#39;"; break;
      default: out += c;
    }
  }
  return Value::string(std::move(out));
}

Value replace(const Value& in, const Args& args) {
  std::string s = to_display(in);
  std::string from = to_display(args[0]);
  std::string to = to_display(args[1]);
  if (from.empty()) return Value::string(std::move(s));
  std::string out;
  size_t pos = 0;
  for (;;) {
    size_t hit = s.find(from, pos);
    if (hit == std::string::npos) break;
    out.append(s, pos, hit - pos);
    out += to;
    pos = hit + from.size();
  }
  out.append(s, pos, std::string::npos);
  return Value::string(std::move(out));
}

Value length(const Value& in, const Args&) {
  switch (in.kind()) {
    case Value::Kind::String: return Value::integer(static_cast<int64_t>(utf8_length(in.as_string())));
    case Value::Kind::List: return Value::integer(static_cast<int64_t>(in.as_list().size()));
    case Value::Kind::Dict: return Value::integer(static_cast<int64_t>(in.as_dict().size()));
    default: type_error("length of a value without length");
  }
}

int64_t truncate_to_int(double d) {
  if (std::isnan(d)) return 0;
  if (d >= 9223372036854775807.0) return INT64_MAX;
  if (d <= -9223372036854775808.0) return INT64_MIN;
  return static_cast<int64_t>(d);
}

// Parses `[+-]?[0-9]+` entirely; returns false if `s` does not match.
bool parse_plain_int(std::string_view s, int64_t& out) {
  size_t i = 0;
  if (i < s.size() && (s[i] == '+' || s[i] == '-')) ++i;
  if (i == s.size()) return false;
  for (size_t k = i; k < s.size(); ++k) {
    if (s[k] < '0' || s[k] > '9') return false;
  }
  bool neg = s[0] == '-';
  std::string_view digits = s.substr(i);
  int64_t v = 0;
  auto res = std::from_chars(digits.data(), digits.data() + digits.size(), v);
  if (res.ec != std::errc()) {
    out = neg ? INT64_MIN : INT64_MAX;  // out of range: saturate
    return true;
  }
  out = neg ? -v : v;
  return true;
}

// Matches `[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?` entirely.
bool matches_decimal(std::string_view s) {
  size_t i = 0, n = s.size();
  auto digit = [&](size_t k) { return k < n && s[k] >= '0' && s[k] <= '9'; };
  if (i < n && (s[i] == '+' || s[i] == '-')) ++i;
  if (digit(i)) {
    while (digit(i)) ++i;
    if (i < n && s[i] == '.') {
      ++i;
      while (digit(i)) ++i;
    }
  } else if (i < n && s[i] == '.' && digit(i + 1)) {
    ++i;
    while (digit(i)) ++i;
  } else {
    return false;
  }
  if (i < n && (s[i] == 'e' || s[i] == 'E')) {
    ++i;
    if (i < n && (s[i] == '+' || s[i] == '-')) ++i;
    if (!digit(i)) return false;
    while (digit(i)) ++i;
  }
  return i == n;
}

Value to_int(const Value& in, const Args&) {
  switch (in.kind()) {
    case Value::Kind::Int: return in;
    case Value::Kind::Bool: return Value::integer(in.as_bool() ? 1 : 0);
    case Value::Kind::Float: return Value::integer(truncate_to_int(in.as_float()));
    case Value::Kind::String: {
      std::string_view s = in.as_string();
      size_t b = 0, e = s.size();
      while (b < e && is_template_space(s[b])) ++b;
      while (e > b && is_template_space(s[e - 1])) --e;
      s = s.substr(b, e - b);
      int64_t v;
      if (parse_plain_int(s, v)) return Value::integer(v);
      if (matches_decimal(s)) {
        std::string copy(s);
        return Value::integer(truncate_to_int(std::strtod(copy.c_str(), nullptr)));
      }
      return Value::integer(0);
    }
    default: return Value::integer(0);
  }
}

Value join(const Value& in, const Args& args) {
  ListPtr seq = sequence_view(in);
  std::string sep = args.empty() ? std::string() : to_display(args[0]);
  std::string out;
  bool first = true;
  for (const Value& v : *seq) {
    if (!first) out += sep;
    first = false;
    append_display(out, v);
  }
  return Value::string(std::move(out));
}

Value first(const Value& in, const Args&) {
  if (in.is_string()) {
    const std::string& s = in.as_string();
    if (s.empty()) return Value();
    return Value::string(s.substr(0, std::min(utf8_sequence_size(static_cast<unsigned char>(s[0])), s.size())));
  }
  ListPtr seq = sequence_view(in);
  return seq->empty() ? Value() : seq->front();
}

Value last(const Value& in, const Args&) {
  ListPtr seq = sequence_view(in);
  return seq->empty() ? Value() : seq->back();
}

Value reverse(const Value& in, const Args&) {
  if (in.is_string()) {
    std::string out;
    out.reserve(in.as_string().size());
    auto chars = utf8_split(in.as_string());
    for (auto it = chars.rbegin(); it != chars.rend(); ++it) out.append(*it);
    return Value::string(std::move(out));
  }
  ListPtr seq = sequence_view(in);
  return Value::list(List(seq->rbegin(), seq->rend()));
}

Value sort(const Value& in, const Args&) {
  ListPtr seq = sequence_view(in);
  const List& items = *seq;
  bool all_numbers = std::all_of(items.begin(), items.end(), [](const Value& v) { return v.is_number(); });
  bool all_strings = std::all_of(items.begin(), items.end(), [](const Value& v) { return v.is_string(); });
  if (!all_numbers && !all_strings) type_error("sort needs all numbers or all strings");

  std::vector<size_t> order(items.size());
  std::iota(order.begin(), order.end(), size_t{0});
  if (all_numbers) {
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) {
      const Value &x = items[a], &y = items[b];
      if (x.is_integral() && y.is_integral()) return x.integral() < y.integral();
      return x.number() < y.number();
    });
  } else {
    std::vector<std::string> keys;
    keys.reserve(items.size());
    for (const Value& v : items) keys.push_back(ascii_lower(v.as_string()));
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return keys[a] < keys[b]; });
  }
  List out;
  out.reserve(items.size());
  for (size_t i : order) out.push_back(items[i]);
  return Value::list(std::move(out));
}

Value default_filter(const Value& in, const Args& args) {
  if (!in.is_undefined()) return in;
  return args.empty() ? Value::string("") : args[0];
}

const FilterInfo kFilters[] = {
    {"upper", 0, 0, false, upper},
    {"lower", 0, 0, false, lower},
    {"trim", 0, 0, false, trim},
    {"escape", 0, 0, false, escape},
    {"replace", 2, 2, false, replace},
    {"length", 0, 0, false, length},
    {"int", 0, 0, false, to_int},
    {"join", 0, 1, false, join},
    {"first", 0, 0, false, first},
    {"last", 0, 0, false, last},
    {"reverse", 0, 0, false, reverse},
    {"sort", 0, 0, false, sort},
    {"default", 0, 1, true, default_filter},
};

}  // namespace

const FilterInfo* find_filter(std::string_view name) {
  for (const FilterInfo& f : kFilters) {
    if (name == f.name) return &f;
  }
  return nullptr;
}

}  // namespace jinjalite
