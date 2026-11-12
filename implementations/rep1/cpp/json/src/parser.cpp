#include "jsoncanon/parser.hpp"

#include <utility>

#include "jsoncanon/utf8.hpp"

namespace jsoncanon {

namespace {

class Parser {
 public:
  Parser(std::string_view in, std::size_t max_depth) : in_(in), max_depth_(max_depth) {}

  Value parse_document() {
    skip_ws();
    Value v = parse_value(0);
    skip_ws();
    if (pos_ != in_.size()) fail("unexpected data after document");
    return v;
  }

 private:
  [[noreturn]] void fail(const char* msg) const { throw ParseError(msg, pos_); }

  bool at_end() const { return pos_ >= in_.size(); }
  char peek() const { return in_[pos_]; }

  void skip_ws() {
    while (pos_ < in_.size()) {
      const char c = in_[pos_];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        ++pos_;
      } else {
        break;
      }
    }
  }

  void expect_literal(std::string_view lit) {
    if (in_.substr(pos_, lit.size()) != lit) fail("invalid literal");
    pos_ += lit.size();
  }

  Value parse_value(std::size_t depth) {
    if (at_end()) fail("unexpected end of input");
    switch (peek()) {
      case '{': return parse_object(depth + 1);
      case '[': return parse_array(depth + 1);
      case '"': return Value(parse_string());
      case 't': expect_literal("true"); return Value(true);
      case 'f': expect_literal("false"); return Value(false);
      case 'n': expect_literal("null"); return Value(nullptr);
      default: return parse_number();
    }
  }

  Value parse_array(std::size_t depth) {
    if (depth > max_depth_) fail("nesting too deep");
    ++pos_;  // '['
    Value::Array items;
    skip_ws();
    if (!at_end() && peek() == ']') {
      ++pos_;
      return Value(std::move(items));
    }
    for (;;) {
      skip_ws();
      items.push_back(parse_value(depth));
      skip_ws();
      if (at_end()) fail("unterminated array");
      const char c = in_[pos_++];
      if (c == ']') break;
      if (c != ',') {
        --pos_;
        fail("expected ',' or ']'");
      }
    }
    return Value(std::move(items));
  }

  Value parse_object(std::size_t depth) {
    if (depth > max_depth_) fail("nesting too deep");
    ++pos_;  // '{'
    Value::Object members;
    skip_ws();
    if (!at_end() && peek() == '}') {
      ++pos_;
      return Value(std::move(members));
    }
    for (;;) {
      skip_ws();
      if (at_end() || peek() != '"') fail("expected string key");
      std::string key = parse_string();
      skip_ws();
      if (at_end() || peek() != ':') fail("expected ':'");
      ++pos_;
      skip_ws();
      Value v = parse_value(depth);
      members.push_back(Member{std::move(key), std::move(v)});
      skip_ws();
      if (at_end()) fail("unterminated object");
      const char c = in_[pos_++];
      if (c == '}') break;
      if (c != ',') {
        --pos_;
        fail("expected ',' or '}'");
      }
    }
    return Value(std::move(members));
  }

  static int hex_value(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  }

  // Reads four hex digits at pos_ (after "\u"); advances past them.
  char32_t parse_hex4() {
    if (in_.size() - pos_ < 4) fail("truncated \\u escape");
    char32_t v = 0;
    for (int k = 0; k < 4; ++k) {
      const int h = hex_value(in_[pos_ + k]);
      if (h < 0) fail("invalid hex digit in \\u escape");
      v = (v << 4) | static_cast<char32_t>(h);
    }
    pos_ += 4;
    return v;
  }

  std::string parse_string() {
    ++pos_;  // opening quote
    std::string out;
    for (;;) {
      // Copy the longest run of ordinary bytes in one go.
      std::size_t run = pos_;
      while (run < in_.size()) {
        const auto c = static_cast<unsigned char>(in_[run]);
        if (c == '"' || c == '\\' || c < 0x20) break;
        ++run;
      }
      out.append(in_.data() + pos_, run - pos_);
      pos_ = run;
      if (at_end()) fail("unterminated string");
      const auto c = static_cast<unsigned char>(in_[pos_]);
      if (c == '"') {
        ++pos_;
        return out;
      }
      if (c < 0x20) fail("control character in string");
      ++pos_;  // backslash
      if (at_end()) fail("unterminated string");
      const char e = in_[pos_++];
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
          char32_t cp = parse_hex4();
          if (cp >= 0xD800 && cp <= 0xDBFF) {
            if (in_.size() - pos_ < 2 || in_[pos_] != '\\' || in_[pos_ + 1] != 'u')
              fail("unpaired high surrogate");
            pos_ += 2;
            const char32_t lo = parse_hex4();
            if (lo < 0xDC00 || lo > 0xDFFF) fail("invalid low surrogate");
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
          } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
            fail("unpaired low surrogate");
          }
          utf8::append_code_point(out, cp);
          break;
        }
        default:
          --pos_;
          fail("invalid escape");
      }
    }
  }

  static bool is_digit(char c) { return c >= '0' && c <= '9'; }

  Value parse_number() {
    const std::size_t start = pos_;
    if (!at_end() && peek() == '-') ++pos_;
    if (at_end() || !is_digit(peek())) fail("invalid value");
    if (peek() == '0') {
      ++pos_;
      if (!at_end() && is_digit(peek())) fail("leading zero");
    } else {
      while (!at_end() && is_digit(peek())) ++pos_;
    }
    if (!at_end() && peek() == '.') {
      ++pos_;
      if (at_end() || !is_digit(peek())) fail("digits expected after '.'");
      while (!at_end() && is_digit(peek())) ++pos_;
    }
    std::string text(in_.substr(start, pos_ - start));
    if (!at_end() && (peek() == 'e' || peek() == 'E')) {
      ++pos_;
      bool negative = false;
      if (!at_end() && (peek() == '+' || peek() == '-')) {
        negative = peek() == '-';
        ++pos_;
      }
      if (at_end() || !is_digit(peek())) fail("digits expected in exponent");
      const std::size_t d0 = pos_;
      while (!at_end() && is_digit(peek())) ++pos_;
      // Normalise: strip leading zeros; sign only when negative and nonzero.
      std::size_t nz = d0;
      while (nz < pos_ && in_[nz] == '0') ++nz;
      text.push_back('e');
      if (nz == pos_) {
        text.push_back('0');
      } else {
        if (negative) text.push_back('-');
        text.append(in_.data() + nz, pos_ - nz);
      }
    }
    return Value::number(std::move(text));
  }

  std::string_view in_;
  std::size_t max_depth_;
  std::size_t pos_ = 0;
};

}  // namespace

Value parse(std::string_view input, const ParseOptions& options) {
  if (!utf8::is_valid(input)) throw ParseError("invalid UTF-8", 0);
  if (input.substr(0, 3) == "\xEF\xBB\xBF") throw ParseError("byte-order mark not allowed", 0);
  return Parser(input, options.max_depth).parse_document();
}

std::optional<Value> try_parse(std::string_view input, const ParseOptions& options) {
  try {
    return parse(input, options);
  } catch (const ParseError&) {
    return std::nullopt;
  }
}

}  // namespace jsoncanon
