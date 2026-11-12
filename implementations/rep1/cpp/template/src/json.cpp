#include "jinjalite/json.hpp"

#include <charconv>
#include <cstdlib>

#include "jinjalite/utf8.hpp"

namespace jinjalite {
namespace {

class JsonParser {
 public:
  explicit JsonParser(std::string_view s) : s_(s) {}

  Value parse_document() {
    skip_ws();
    Value v = parse_value(0);
    skip_ws();
    if (pos_ != s_.size()) fail("trailing characters");
    return v;
  }

 private:
  static constexpr int kMaxDepth = 1000;

  [[noreturn]] void fail(const char* msg) const {
    throw JsonError(std::string("invalid JSON at offset ") + std::to_string(pos_) + ": " + msg);
  }

  void skip_ws() {
    while (pos_ < s_.size() && (s_[pos_] == ' ' || s_[pos_] == '\t' || s_[pos_] == '\n' || s_[pos_] == '\r')) ++pos_;
  }

  bool consume_literal(std::string_view lit) {
    if (s_.substr(pos_, lit.size()) == lit) {
      pos_ += lit.size();
      return true;
    }
    return false;
  }

  Value parse_value(int depth) {
    if (depth > kMaxDepth) fail("nesting too deep");
    if (pos_ >= s_.size()) fail("unexpected end");
    char c = s_[pos_];
    switch (c) {
      case '{': return parse_object(depth);
      case '[': return parse_array(depth);
      case '"': return Value::string(parse_string());
      case 't':
        if (consume_literal("true")) return Value::boolean(true);
        break;
      case 'f':
        if (consume_literal("false")) return Value::boolean(false);
        break;
      case 'n':
        if (consume_literal("null")) return Value::none();
        break;
      default:
        if (c == '-' || (c >= '0' && c <= '9')) return parse_number();
    }
    fail("unexpected character");
  }

  Value parse_object(int depth) {
    ++pos_;  // {
    auto dict = std::make_shared<Dict>();
    skip_ws();
    if (pos_ < s_.size() && s_[pos_] == '}') {
      ++pos_;
      return Value::dict(dict);
    }
    for (;;) {
      skip_ws();
      if (pos_ >= s_.size() || s_[pos_] != '"') fail("expected object key");
      std::string key = parse_string();
      skip_ws();
      if (pos_ >= s_.size() || s_[pos_] != ':') fail("expected ':'");
      ++pos_;
      skip_ws();
      dict->set(std::move(key), parse_value(depth + 1));
      skip_ws();
      if (pos_ >= s_.size()) fail("unterminated object");
      if (s_[pos_] == ',') {
        ++pos_;
        continue;
      }
      if (s_[pos_] == '}') {
        ++pos_;
        break;
      }
      fail("expected ',' or '}'");
    }
    return Value::dict(std::move(dict));
  }

  Value parse_array(int depth) {
    ++pos_;  // [
    List items;
    skip_ws();
    if (pos_ < s_.size() && s_[pos_] == ']') {
      ++pos_;
      return Value::list(std::move(items));
    }
    for (;;) {
      skip_ws();
      items.push_back(parse_value(depth + 1));
      skip_ws();
      if (pos_ >= s_.size()) fail("unterminated array");
      if (s_[pos_] == ',') {
        ++pos_;
        continue;
      }
      if (s_[pos_] == ']') {
        ++pos_;
        break;
      }
      fail("expected ',' or ']'");
    }
    return Value::list(std::move(items));
  }

  uint32_t parse_hex4() {
    if (pos_ + 4 > s_.size()) fail("bad \\u escape");
    uint32_t v = 0;
    for (int i = 0; i < 4; ++i) {
      char c = s_[pos_++];
      v <<= 4;
      if (c >= '0' && c <= '9') v |= static_cast<uint32_t>(c - '0');
      else if (c >= 'a' && c <= 'f') v |= static_cast<uint32_t>(c - 'a' + 10);
      else if (c >= 'A' && c <= 'F') v |= static_cast<uint32_t>(c - 'A' + 10);
      else fail("bad \\u escape");
    }
    return v;
  }

  std::string parse_string() {
    ++pos_;  // opening quote
    std::string out;
    for (;;) {
      if (pos_ >= s_.size()) fail("unterminated string");
      // Copy a run of plain characters at once.
      size_t start = pos_;
      while (pos_ < s_.size() && s_[pos_] != '"' && s_[pos_] != '\\' &&
             static_cast<unsigned char>(s_[pos_]) >= 0x20) {
        ++pos_;
      }
      out.append(s_.data() + start, pos_ - start);
      if (pos_ >= s_.size()) fail("unterminated string");
      char c = s_[pos_];
      if (c == '"') {
        ++pos_;
        return out;
      }
      if (c != '\\') fail("control character in string");
      ++pos_;
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
          uint32_t cp = parse_hex4();
          if (cp >= 0xD800 && cp < 0xDC00 && s_.substr(pos_, 2) == "\\u") {
            size_t save = pos_;
            pos_ += 2;
            uint32_t lo = parse_hex4();
            if (lo >= 0xDC00 && lo < 0xE000) {
              cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
            } else {
              pos_ = save;
            }
          }
          utf8_append(out, cp);
          break;
        }
        default: fail("bad escape");
      }
    }
  }

  Value parse_number() {
    size_t start = pos_;
    bool is_float = false;
    if (s_[pos_] == '-') ++pos_;
    if (pos_ >= s_.size()) fail("bad number");
    if (s_[pos_] == '0') {
      ++pos_;
    } else if (s_[pos_] >= '1' && s_[pos_] <= '9') {
      while (pos_ < s_.size() && s_[pos_] >= '0' && s_[pos_] <= '9') ++pos_;
    } else {
      fail("bad number");
    }
    if (pos_ < s_.size() && s_[pos_] == '.') {
      is_float = true;
      ++pos_;
      if (pos_ >= s_.size() || s_[pos_] < '0' || s_[pos_] > '9') fail("bad fraction");
      while (pos_ < s_.size() && s_[pos_] >= '0' && s_[pos_] <= '9') ++pos_;
    }
    if (pos_ < s_.size() && (s_[pos_] == 'e' || s_[pos_] == 'E')) {
      is_float = true;
      ++pos_;
      if (pos_ < s_.size() && (s_[pos_] == '+' || s_[pos_] == '-')) ++pos_;
      if (pos_ >= s_.size() || s_[pos_] < '0' || s_[pos_] > '9') fail("bad exponent");
      while (pos_ < s_.size() && s_[pos_] >= '0' && s_[pos_] <= '9') ++pos_;
    }
    std::string_view text = s_.substr(start, pos_ - start);
    if (!is_float) {
      int64_t i = 0;
      auto res = std::from_chars(text.data(), text.data() + text.size(), i);
      if (res.ec == std::errc()) return Value::integer(i);
      // Out of int64 range: fall back to a float.
    }
    std::string copy(text);
    return Value::real(std::strtod(copy.c_str(), nullptr));
  }

  std::string_view s_;
  size_t pos_ = 0;
};

}  // namespace

Value parse_json(std::string_view text) { return JsonParser(text).parse_document(); }

}  // namespace jinjalite
