#include "jq/json.hpp"

#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstdlib>

namespace jq {

namespace {

constexpr int kMaxDepth = 2000;

class Parser {
 public:
  explicit Parser(std::string_view t) : s_(t) {}

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

  Value parse_value(int depth) {
    if (pos_ >= s_.size()) fail("unexpected end of input");
    char c = s_[pos_];
    switch (c) {
      case '{': return parse_object(depth);
      case '[': return parse_array(depth);
      case '"': return Value::string(parse_string());
      case 't': literal("true"); return Value::boolean(true);
      case 'f': literal("false"); return Value::boolean(false);
      case 'n': literal("null"); return Value();
      default:
        if (c == '-' || (c >= '0' && c <= '9')) return parse_number();
        fail("unexpected character");
    }
  }

  void literal(const char* word) {
    std::size_t n = std::char_traits<char>::length(word);
    if (s_.compare(pos_, n, word) != 0) fail("invalid literal");
    pos_ += n;
  }

  Value parse_number() {
    std::size_t start = pos_;
    if (s_[pos_] == '-') ++pos_;
    auto digits = [&] {
      std::size_t b = pos_;
      while (pos_ < s_.size() && s_[pos_] >= '0' && s_[pos_] <= '9') ++pos_;
      if (pos_ == b) fail("invalid number");
    };
    digits();
    if (pos_ < s_.size() && s_[pos_] == '.') {
      ++pos_;
      digits();
    }
    if (pos_ < s_.size() && (s_[pos_] == 'e' || s_[pos_] == 'E')) {
      ++pos_;
      if (pos_ < s_.size() && (s_[pos_] == '+' || s_[pos_] == '-')) ++pos_;
      digits();
    }
    double d = 0;
    auto res = std::from_chars(s_.data() + start, s_.data() + pos_, d);
    if (res.ec == std::errc::result_out_of_range) {
      // from_chars leaves d untouched; fall back to strtod's inf/0 behaviour.
      std::string tmp(s_.substr(start, pos_ - start));
      d = std::strtod(tmp.c_str(), nullptr);
    } else if (res.ec != std::errc()) {
      fail("invalid number");
    }
    return Value::number(d);
  }

  static int hex(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  }

  unsigned parse_hex4() {
    if (pos_ + 4 > s_.size()) fail("truncated \\u escape");
    unsigned v = 0;
    for (int i = 0; i < 4; ++i) {
      int h = hex(s_[pos_ + i]);
      if (h < 0) fail("invalid \\u escape");
      v = v * 16 + static_cast<unsigned>(h);
    }
    pos_ += 4;
    return v;
  }

  static void append_utf8(std::string& out, unsigned cp) {
    if (cp < 0x80) {
      out += static_cast<char>(cp);
    } else if (cp < 0x800) {
      out += static_cast<char>(0xC0 | (cp >> 6));
      out += static_cast<char>(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
      out += static_cast<char>(0xE0 | (cp >> 12));
      out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
      out += static_cast<char>(0x80 | (cp & 0x3F));
    } else {
      out += static_cast<char>(0xF0 | (cp >> 18));
      out += static_cast<char>(0x80 | ((cp >> 12) & 0x3F));
      out += static_cast<char>(0x80 | ((cp >> 6) & 0x3F));
      out += static_cast<char>(0x80 | (cp & 0x3F));
    }
  }

  std::string parse_string() {
    ++pos_;  // opening quote
    std::string out;
    for (;;) {
      std::size_t run = pos_;
      while (run < s_.size() && s_[run] != '"' && s_[run] != '\\') ++run;
      if (run >= s_.size()) fail("unterminated string");
      out.append(s_.data() + pos_, run - pos_);
      pos_ = run;
      if (s_[pos_] == '"') {
        ++pos_;
        return out;
      }
      ++pos_;  // backslash
      if (pos_ >= s_.size()) fail("unterminated escape");
      char e = s_[pos_++];
      switch (e) {
        case '"': out += '"'; break;
        case '\\': out += '\\'; break;
        case '/': out += '/'; break;
        case 'b': out += '\b'; break;
        case 'f': out += '\f'; break;
        case 'n': out += '\n'; break;
        case 'r': out += '\r'; break;
        case 't': out += '\t'; break;
        case 'u': {
          unsigned cp = parse_hex4();
          if (cp >= 0xD800 && cp <= 0xDBFF && pos_ + 1 < s_.size() && s_[pos_] == '\\' &&
              s_[pos_ + 1] == 'u') {
            std::size_t save = pos_;
            pos_ += 2;
            unsigned lo = parse_hex4();
            if (lo >= 0xDC00 && lo <= 0xDFFF)
              cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            else
              pos_ = save;  // lone surrogate: leave the next escape alone
          }
          if (cp >= 0xD800 && cp <= 0xDFFF) cp = 0xFFFD;  // unpaired surrogate
          append_utf8(out, cp);
          break;
        }
        default: fail("invalid escape");
      }
    }
  }

  Value parse_array(int depth) {
    if (depth >= kMaxDepth) fail("nesting too deep");
    ++pos_;
    std::vector<Value> items;
    skip_ws();
    if (pos_ < s_.size() && s_[pos_] == ']') {
      ++pos_;
      return Value::array(std::move(items));
    }
    for (;;) {
      skip_ws();
      items.push_back(parse_value(depth + 1));
      skip_ws();
      if (pos_ >= s_.size()) fail("unterminated array");
      char c = s_[pos_++];
      if (c == ']') break;
      if (c != ',') fail("expected ',' or ']'");
    }
    return Value::array(std::move(items));
  }

  Value parse_object(int depth) {
    if (depth >= kMaxDepth) fail("nesting too deep");
    ++pos_;
    ObjectBuilder b;
    skip_ws();
    if (pos_ < s_.size() && s_[pos_] == '}') {
      ++pos_;
      return b.build();
    }
    for (;;) {
      skip_ws();
      if (pos_ >= s_.size() || s_[pos_] != '"') fail("expected string key");
      std::string key = parse_string();
      skip_ws();
      if (pos_ >= s_.size() || s_[pos_] != ':') fail("expected ':'");
      ++pos_;
      skip_ws();
      Value v = parse_value(depth + 1);
      b.set(std::move(key), std::move(v));
      skip_ws();
      if (pos_ >= s_.size()) fail("unterminated object");
      char c = s_[pos_++];
      if (c == '}') break;
      if (c != ',') fail("expected ',' or '}'");
    }
    return b.build();
  }

  std::string_view s_;
  std::size_t pos_ = 0;
};

void write_string(const std::string& s, std::string& out) {
  static const char kHex[] = "0123456789abcdef";
  out += '"';
  std::size_t run = 0;
  for (std::size_t i = 0; i < s.size(); ++i) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    if (c >= 0x20 && c != '"' && c != '\\' && c != 0x7F) continue;
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
        out += kHex[c >> 4];
        out += kHex[c & 15];
    }
  }
  out.append(s, run, s.size() - run);
  out += '"';
}

}  // namespace

void write_number(double d, std::string& out) {
  if (std::isnan(d)) {
    out += "null";
    return;
  }
  if (std::isinf(d)) {
    out += d < 0 ? "-1.7976931348623157e+308" : "1.7976931348623157e+308";
    return;
  }
  if (d == std::floor(d) && std::fabs(d) < 1e17) {
    if (d == 0 && std::signbit(d)) {
      out += "-0";
      return;
    }
    char buf[32];
    auto r = std::to_chars(buf, buf + sizeof buf, static_cast<long long>(d));
    out.append(buf, r.ptr);
    return;
  }
  char buf[40];
  for (int prec = 15; prec <= 17; ++prec) {
    std::snprintf(buf, sizeof buf, "%.*g", prec, d);
    if (prec == 17 || std::strtod(buf, nullptr) == d) break;
  }
  out += buf;
}

Value parse_json(std::string_view text) { return Parser(text).parse_document(); }

void write_json(const Value& v, std::string& out) {
  switch (v.type()) {
    case Type::Null: out += "null"; break;
    case Type::False: out += "false"; break;
    case Type::True: out += "true"; break;
    case Type::Number: write_number(v.as_number(), out); break;
    case Type::String: write_string(v.as_string(), out); break;
    case Type::Array: {
      out += '[';
      bool first = true;
      for (const Value& e : v.as_array()) {
        if (!first) out += ',';
        first = false;
        write_json(e, out);
      }
      out += ']';
      break;
    }
    case Type::Object: {
      out += '{';
      bool first = true;
      for (const Member& m : v.as_object().members()) {
        if (!first) out += ',';
        first = false;
        write_string(m.key, out);
        out += ':';
        write_json(m.value, out);
      }
      out += '}';
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
