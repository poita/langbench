#include "sitegen/toml.hpp"

#include <limits>

#include "sitegen/text.hpp"

namespace sitegen::toml {

Value Value::string(std::string s) {
  Value v;
  v.type_ = Type::String;
  v.string_ = std::move(s);
  return v;
}
Value Value::integer(std::int64_t i) {
  Value v;
  v.type_ = Type::Integer;
  v.integer_ = i;
  return v;
}
Value Value::boolean(bool b) {
  Value v;
  v.type_ = Type::Boolean;
  v.boolean_ = b;
  return v;
}
Value Value::array(std::vector<std::string> items) {
  Value v;
  v.type_ = Type::Array;
  v.array_ = std::move(items);
  return v;
}

void Document::add(std::string key, Value value) {
  entries_.push_back(Entry{std::move(key), std::move(value)});
}

const Value* Document::find(std::string_view key) const {
  for (const Entry& e : entries_) {
    if (e.key == key) return &e.value;
  }
  return nullptr;
}

std::string Document::get_string(std::string_view key, std::string fallback) const {
  const Value* v = find(key);
  return v != nullptr && v->is_string() ? v->as_string() : fallback;
}
std::int64_t Document::get_integer(std::string_view key, std::int64_t fallback) const {
  const Value* v = find(key);
  return v != nullptr && v->is_integer() ? v->as_integer() : fallback;
}
bool Document::get_boolean(std::string_view key, bool fallback) const {
  const Value* v = find(key);
  return v != nullptr && v->is_boolean() ? v->as_boolean() : fallback;
}
std::vector<std::string> Document::get_array(std::string_view key) const {
  const Value* v = find(key);
  return v != nullptr && v->is_array() ? v->as_array() : std::vector<std::string>{};
}

namespace {

bool is_blank_char(char c) { return c == ' ' || c == '\t'; }
bool is_key_char(char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' ||
         c == '-';
}

class LineParser {
 public:
  LineParser(std::string_view line, std::size_t line_no) : s_(line), line_no_(line_no) {}

  /// Parses one line; returns false for blank and comment lines.
  bool parse(std::string& key, Value& value) {
    skip_blank();
    if (pos_ >= s_.size() || s_[pos_] == '#') return false;
    const std::size_t key_start = pos_;
    while (pos_ < s_.size() && is_key_char(s_[pos_])) ++pos_;
    if (pos_ == key_start) fail("expected a key");
    key.assign(s_.substr(key_start, pos_ - key_start));
    skip_blank();
    if (pos_ >= s_.size() || s_[pos_] != '=') fail("expected '='");
    ++pos_;
    skip_blank();
    value = parse_value();
    skip_blank();
    if (pos_ < s_.size() && s_[pos_] != '#') fail("unexpected text after value");
    return true;
  }

 private:
  [[noreturn]] void fail(const std::string& message) const { throw ParseError(message, line_no_); }

  void skip_blank() {
    while (pos_ < s_.size() && is_blank_char(s_[pos_])) ++pos_;
  }

  Value parse_value() {
    if (pos_ >= s_.size()) fail("missing value");
    const char c = s_[pos_];
    if (c == '"') return Value::string(parse_string());
    if (c == '[') return parse_array();
    if (s_.compare(pos_, 4, "true") == 0) {
      pos_ += 4;
      return Value::boolean(true);
    }
    if (s_.compare(pos_, 5, "false") == 0) {
      pos_ += 5;
      return Value::boolean(false);
    }
    return parse_integer();
  }

  Value parse_integer() {
    bool negative = false;
    if (pos_ < s_.size() && s_[pos_] == '-') {
      negative = true;
      ++pos_;
    }
    const std::size_t start = pos_;
    while (pos_ < s_.size() && s_[pos_] >= '0' && s_[pos_] <= '9') ++pos_;
    if (pos_ == start) fail("invalid value");
    if (s_[start] == '0' && pos_ - start > 1) fail("leading zero in integer");
    unsigned long long magnitude = 0;
    for (std::size_t i = start; i < pos_; ++i) {
      magnitude = magnitude * 10 + static_cast<unsigned>(s_[i] - '0');
    }
    std::int64_t value = static_cast<std::int64_t>(magnitude);
    if (negative) value = static_cast<std::int64_t>(0ULL - magnitude);
    return Value::integer(value);
  }

  static int hex_digit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  }

  std::string parse_string() {
    ++pos_;  // opening quote
    std::string out;
    while (true) {
      if (pos_ >= s_.size()) fail("unterminated string");
      const char c = s_[pos_++];
      if (c == '"') return out;
      if (c != '\\') {
        out.push_back(c);
        continue;
      }
      if (pos_ >= s_.size()) fail("unterminated escape");
      const char e = s_[pos_++];
      switch (e) {
        case '"': out.push_back('"'); break;
        case '\\': out.push_back('\\'); break;
        case 'n': out.push_back('\n'); break;
        case 't': out.push_back('\t'); break;
        case 'r': out.push_back('\r'); break;
        case 'u': {
          char32_t cp = 0;
          for (int i = 0; i < 4; ++i) {
            const int d = pos_ < s_.size() ? hex_digit(s_[pos_]) : -1;
            if (d < 0) fail("invalid \\u escape");
            cp = cp * 16 + static_cast<char32_t>(d);
            ++pos_;
          }
          text::append_utf8(out, cp);
          break;
        }
        default: fail("invalid escape sequence");
      }
    }
  }

  Value parse_array() {
    ++pos_;  // '['
    std::vector<std::string> items;
    skip_blank();
    while (true) {
      if (pos_ >= s_.size()) fail("unterminated array");
      if (s_[pos_] == ']') {
        ++pos_;
        return Value::array(std::move(items));
      }
      if (s_[pos_] != '"') fail("array elements must be strings");
      items.push_back(parse_string());
      skip_blank();
      if (pos_ < s_.size() && s_[pos_] == ',') {
        ++pos_;
        skip_blank();
      } else if (pos_ >= s_.size() || s_[pos_] != ']') {
        fail("expected ',' or ']'");
      }
    }
  }

  std::string_view s_;
  std::size_t line_no_;
  std::size_t pos_ = 0;
};

}  // namespace

Document parse(std::string_view text) {
  Document doc;
  std::size_t pos = 0;
  std::size_t line_no = 0;
  while (pos < text.size()) {
    std::size_t nl = text.find('\n', pos);
    if (nl == std::string_view::npos) nl = text.size();
    ++line_no;
    LineParser lp(text.substr(pos, nl - pos), line_no);
    std::string key;
    Value value = Value::boolean(false);
    if (lp.parse(key, value)) doc.add(std::move(key), std::move(value));
    pos = nl + 1;
  }
  return doc;
}

FrontMatter split_front_matter(std::string_view file) {
  constexpr std::string_view kOpen = "+++\n";
  if (file.substr(0, kOpen.size()) != kOpen) throw ParseError("missing '+++' front matter", 1);
  const std::string_view rest = file.substr(kOpen.size());
  std::size_t pos = 0;
  while (pos <= rest.size()) {
    std::size_t nl = rest.find('\n', pos);
    const bool has_nl = nl != std::string_view::npos;
    if (!has_nl) nl = rest.size();
    if (rest.substr(pos, nl - pos) == "+++") {
      FrontMatter fm;
      fm.meta = parse(rest.substr(0, pos));
      fm.body.assign(has_nl ? rest.substr(nl + 1) : std::string_view());
      return fm;
    }
    if (!has_nl) break;
    pos = nl + 1;
  }
  throw ParseError("front matter is not terminated by '+++'", 1);
}

}  // namespace sitegen::toml
