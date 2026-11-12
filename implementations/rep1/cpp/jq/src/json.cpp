#include "jq/json.hpp"

#include <charconv>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace jq {

namespace {

constexpr int kMaxDepth = 2000;

void append_utf8(std::string& out, std::uint32_t cp) {
  if (cp < 0x80) {
    out.push_back(static_cast<char>(cp));
  } else if (cp < 0x800) {
    out.push_back(static_cast<char>(0xC0 | (cp >> 6)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else if (cp < 0x10000) {
    out.push_back(static_cast<char>(0xE0 | (cp >> 12)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  } else {
    out.push_back(static_cast<char>(0xF0 | (cp >> 18)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 12) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | ((cp >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (cp & 0x3F)));
  }
}

class Parser {
 public:
  explicit Parser(std::string_view s) : s_(s) {}

  Value parse_document() {
    skip_ws();
    Value v = parse_value(0);
    skip_ws();
    if (pos_ != s_.size()) fail("unexpected trailing characters");
    return v;
  }

 private:
  [[noreturn]] void fail(const char* msg) const {
    throw JsonError(std::string(msg) + " at offset " + std::to_string(pos_));
  }

  void skip_ws() {
    while (pos_ < s_.size()) {
      char c = s_[pos_];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
        ++pos_;
      else
        break;
    }
  }

  bool consume_literal(const char* lit) {
    std::size_t n = std::strlen(lit);
    if (s_.compare(pos_, n, lit) == 0) {
      pos_ += n;
      return true;
    }
    return false;
  }

  Value parse_value(int depth) {
    if (depth > kMaxDepth) fail("nesting too deep");
    if (pos_ >= s_.size()) fail("unexpected end of input");
    char c = s_[pos_];
    switch (c) {
      case '{': return parse_object(depth);
      case '[': return parse_array(depth);
      case '"': return Value::string(parse_string());
      case 't':
        if (consume_literal("true")) return Value::boolean(true);
        fail("invalid literal");
      case 'f':
        if (consume_literal("false")) return Value::boolean(false);
        fail("invalid literal");
      case 'n':
        if (consume_literal("null")) return Value::null();
        fail("invalid literal");
      default:
        if (c == '-' || (c >= '0' && c <= '9')) return parse_number();
        fail("unexpected character");
    }
  }

  Value parse_array(int depth) {
    ++pos_;  // [
    Value::Array items;
    skip_ws();
    if (pos_ < s_.size() && s_[pos_] == ']') {
      ++pos_;
      return Value::array(std::move(items));
    }
    while (true) {
      skip_ws();
      items.push_back(parse_value(depth + 1));
      skip_ws();
      if (pos_ >= s_.size()) fail("unterminated array");
      if (s_[pos_] == ',') {
        ++pos_;
      } else if (s_[pos_] == ']') {
        ++pos_;
        break;
      } else {
        fail("expected ',' or ']'");
      }
    }
    return Value::array(std::move(items));
  }

  Value parse_object(int depth) {
    ++pos_;  // {
    ObjectBuilder b;
    skip_ws();
    if (pos_ < s_.size() && s_[pos_] == '}') {
      ++pos_;
      return b.build_value();
    }
    while (true) {
      skip_ws();
      if (pos_ >= s_.size() || s_[pos_] != '"') fail("expected object key");
      std::string key = parse_string();
      skip_ws();
      if (pos_ >= s_.size() || s_[pos_] != ':') fail("expected ':'");
      ++pos_;
      skip_ws();
      Value v = parse_value(depth + 1);
      b.set(key, std::move(v));
      skip_ws();
      if (pos_ >= s_.size()) fail("unterminated object");
      if (s_[pos_] == ',') {
        ++pos_;
      } else if (s_[pos_] == '}') {
        ++pos_;
        break;
      } else {
        fail("expected ',' or '}'");
      }
    }
    return b.build_value();
  }

  std::uint32_t parse_hex4() {
    if (pos_ + 4 > s_.size()) fail("truncated \\u escape");
    std::uint32_t v = 0;
    for (int i = 0; i < 4; ++i) {
      char c = s_[pos_++];
      v <<= 4;
      if (c >= '0' && c <= '9') v |= static_cast<std::uint32_t>(c - '0');
      else if (c >= 'a' && c <= 'f') v |= static_cast<std::uint32_t>(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F') v |= static_cast<std::uint32_t>(c - 'A' + 10);
      else fail("invalid \\u escape");
    }
    return v;
  }

  std::string parse_string() {
    ++pos_;  // opening quote
    std::string out;
    while (true) {
      // Copy the longest run of ordinary bytes in one go.
      std::size_t start = pos_;
      while (pos_ < s_.size() && s_[pos_] != '"' && s_[pos_] != '\\') ++pos_;
      out.append(s_.data() + start, pos_ - start);
      if (pos_ >= s_.size()) fail("unterminated string");
      if (s_[pos_] == '"') {
        ++pos_;
        return out;
      }
      ++pos_;  // backslash
      if (pos_ >= s_.size()) fail("unterminated escape");
      char e = s_[pos_++];
      switch (e) {
        case '"': out.push_back('"'); break;
        case '\\': out.push_back('\\'); break;
        case '/': out.push_back('/'); break;
        case 'b': out.push_back('\b'); break;
        case 'f': out.push_back('\f'); break;
        case 'n': out.push_back('\n'); break;
        case 'r': out.push_back('\r'); break;
        case 't': out.push_back('\t'); break;
        case 'u': {
          std::uint32_t cp = parse_hex4();
          if (cp >= 0xD800 && cp <= 0xDBFF) {
            if (pos_ + 1 < s_.size() && s_[pos_] == '\\' && s_[pos_ + 1] == 'u') {
              std::size_t save = pos_;
              pos_ += 2;
              std::uint32_t lo = parse_hex4();
              if (lo >= 0xDC00 && lo <= 0xDFFF) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
              } else {
                pos_ = save;
                cp = 0xFFFD;
              }
            } else {
              cp = 0xFFFD;
            }
          } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
            cp = 0xFFFD;
          }
          append_utf8(out, cp);
          break;
        }
        default: fail("invalid escape");
      }
    }
  }

  Value parse_number() {
    const std::size_t start = pos_;
    if (s_[pos_] == '-') ++pos_;
    if (pos_ >= s_.size()) fail("invalid number");
    if (s_[pos_] == '0') {
      ++pos_;
    } else if (s_[pos_] >= '1' && s_[pos_] <= '9') {
      while (pos_ < s_.size() && s_[pos_] >= '0' && s_[pos_] <= '9') ++pos_;
    } else {
      fail("invalid number");
    }
    bool simple = true;
    if (pos_ < s_.size() && s_[pos_] == '.') {
      simple = false;
      ++pos_;
      std::size_t d = pos_;
      while (pos_ < s_.size() && s_[pos_] >= '0' && s_[pos_] <= '9') ++pos_;
      if (pos_ == d) fail("invalid number");
    }
    if (pos_ < s_.size() && (s_[pos_] == 'e' || s_[pos_] == 'E')) {
      simple = false;
      ++pos_;
      if (pos_ < s_.size() && (s_[pos_] == '+' || s_[pos_] == '-')) ++pos_;
      std::size_t d = pos_;
      while (pos_ < s_.size() && s_[pos_] >= '0' && s_[pos_] <= '9') ++pos_;
      if (pos_ == d) fail("invalid number");
    }
    const char* b = s_.data() + start;
    const char* e = s_.data() + pos_;
    // Fast path: integers of up to 15 digits are exact in a double.
    if (simple && e - b <= 15) {
      bool neg = *b == '-';
      std::int64_t acc = 0;
      for (const char* p = b + (neg ? 1 : 0); p < e; ++p) acc = acc * 10 + (*p - '0');
      return Value::number(neg ? -static_cast<double>(acc) : static_cast<double>(acc));
    }
    double d = 0;
    auto res = std::from_chars(b, e, d);
    if (res.ec == std::errc::result_out_of_range) {
      d = (*b == '-') ? -HUGE_VAL : HUGE_VAL;  // overflow; underflow yields 0 below
      if (std::memchr(b, 'e', e - b) || std::memchr(b, 'E', e - b)) {
        const char* p = b;
        while (p < e && *p != 'e' && *p != 'E') ++p;
        if (p + 1 < e && p[1] == '-') d = (*b == '-') ? -0.0 : 0.0;
      }
    } else if (res.ec != std::errc()) {
      fail("invalid number");
    }
    return Value::number(d);
  }

  std::string_view s_;
  std::size_t pos_ = 0;
};

void write_string(const std::string& s, std::string& out) {
  static const char hex[] = "0123456789abcdef";
  out.push_back('"');
  std::size_t run = 0;
  const std::size_t n = s.size();
  for (std::size_t i = 0; i < n; ++i) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    if (c >= 0x20 && c != '"' && c != '\\' && c != 0x7f) continue;
    out.append(s, run, i - run);
    run = i + 1;
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        out += "\\u00";
        out.push_back(hex[c >> 4]);
        out.push_back(hex[c & 15]);
    }
  }
  out.append(s, run, n - run);
  out.push_back('"');
}

}  // namespace

Value parse_json(std::string_view text) { return Parser(text).parse_document(); }

void write_number(double d, std::string& out) {
  char buf[64];
  if (std::isnan(d)) {
    out += "null";
    return;
  }
  if (std::isinf(d)) d = d > 0 ? 1.7976931348623157e308 : -1.7976931348623157e308;
  if (d == std::floor(d) && std::fabs(d) < 1e17) {
    if (d == 0 && std::signbit(d)) {
      out += "-0";
      return;
    }
    auto r = std::to_chars(buf, buf + sizeof buf, static_cast<std::int64_t>(d));
    out.append(buf, r.ptr);
    return;
  }
  double a = std::fabs(d);
  std::to_chars_result r;
  if (a >= 1e-5 && a < 1e17)
    r = std::to_chars(buf, buf + sizeof buf, d, std::chars_format::fixed);
  else
    r = std::to_chars(buf, buf + sizeof buf, d, std::chars_format::general);
  out.append(buf, r.ptr);
}

void write_json(const Value& v, std::string& out) {
  switch (v.type()) {
    case Type::Null: out += "null"; break;
    case Type::False: out += "false"; break;
    case Type::True: out += "true"; break;
    case Type::Number: write_number(v.number(), out); break;
    case Type::String: write_string(v.string(), out); break;
    case Type::Array: {
      out.push_back('[');
      bool first = true;
      for (const Value& e : v.array()) {
        if (!first) out.push_back(',');
        first = false;
        write_json(e, out);
      }
      out.push_back(']');
      break;
    }
    case Type::Object: {
      out.push_back('{');
      bool first = true;
      for (const auto& e : v.object()) {
        if (!first) out.push_back(',');
        first = false;
        write_string(e.key, out);
        out.push_back(':');
        write_json(e.value, out);
      }
      out.push_back('}');
      break;
    }
  }
}

std::string to_json(const Value& v) {
  std::string s;
  write_json(v, s);
  return s;
}

}  // namespace jq
