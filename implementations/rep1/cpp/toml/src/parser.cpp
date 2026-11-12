#include "toml/parser.hpp"

#include <utility>
#include <vector>

#include "toml/datetime.hpp"
#include "toml/number.hpp"
#include "toml/utf8.hpp"

namespace toml {

namespace {

constexpr int kMaxDepth = 4000;

bool is_ws(char c) { return c == ' ' || c == '\t'; }
bool is_digit(char c) { return c >= '0' && c <= '9'; }
bool is_bare_key_char(char c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || is_digit(c) || c == '_' || c == '-';
}
// Bytes that may never appear raw inside strings or comments (C0 controls
// other than tab, and DEL). Non-ASCII bytes are fine: UTF-8 was validated.
bool is_forbidden_control(unsigned char c) { return (c < 0x20 && c != '\t') || c == 0x7F; }

class Parser {
 public:
  explicit Parser(std::string_view src) : s_(src) {}

  Value parse_document() {
    if (!is_valid_utf8(s_)) fail("invalid UTF-8", 0);
    if (s_.size() >= 3 && s_.compare(0, 3, "\xEF\xBB\xBF") == 0) fail("byte-order mark", 0);

    Value root = Value::table({}, Origin::Explicit);
    Value* current = &root;
    for (;;) {
      skip_ws();
      if (eof()) break;
      if (at_newline()) {
        skip_newline();
        continue;
      }
      if (peek() == '[') {
        current = parse_header(root);
      } else if (peek() != '#') {
        parse_key_value(*current);
      }
      end_of_line();
    }
    return root;
  }

 private:
  std::string_view s_;
  std::size_t pos_ = 0;
  int depth_ = 0;

  [[noreturn]] void fail(const char* msg) const { fail(msg, pos_); }
  [[noreturn]] void fail(const char* msg, std::size_t at) const {
    std::size_t line = 1, col = 1;
    for (std::size_t i = 0; i < at && i < s_.size(); ++i) {
      if (s_[i] == '\n') {
        ++line;
        col = 1;
      } else {
        ++col;
      }
    }
    throw ParseError(msg, line, col);
  }

  // ---- low-level cursor ----------------------------------------------------
  bool eof() const { return pos_ >= s_.size(); }
  char peek() const { return s_[pos_]; }
  char peek_at(std::size_t off) const { return pos_ + off < s_.size() ? s_[pos_ + off] : '\0'; }
  bool at_newline_at(std::size_t p) const {
    return p < s_.size() && (s_[p] == '\n' || (s_[p] == '\r' && p + 1 < s_.size() && s_[p + 1] == '\n'));
  }
  bool at_newline() const { return at_newline_at(pos_); }
  void skip_newline() { pos_ += s_[pos_] == '\r' ? 2 : 1; }
  void skip_ws() {
    while (!eof() && is_ws(peek())) ++pos_;
  }
  void expect(char c, const char* msg) {
    if (eof() || peek() != c) fail(msg);
    ++pos_;
  }

  // Consumes a comment starting at '#', stopping before the line break.
  void skip_comment() {
    ++pos_;
    while (!eof()) {
      unsigned char c = static_cast<unsigned char>(peek());
      if (c == '\n' || c == '\r') break;
      if (is_forbidden_control(c)) fail("control character in comment");
      ++pos_;
    }
  }

  // Whitespace, newlines and comments (inside arrays).
  void skip_trivia() {
    for (;;) {
      skip_ws();
      if (eof()) return;
      if (peek() == '#') {
        skip_comment();
      } else if (at_newline()) {
        skip_newline();
      } else {
        return;
      }
    }
  }

  // After a statement: optional whitespace and comment, then a line break.
  void end_of_line() {
    skip_ws();
    if (!eof() && peek() == '#') skip_comment();
    if (eof()) return;
    if (!at_newline()) fail("unexpected characters after statement");
    skip_newline();
  }

  // ---- keys ------------------------------------------------------------------
  std::string parse_simple_key() {
    if (eof()) fail("expected key");
    char c = peek();
    if (c == '"') {
      if (peek_at(1) == '"' && peek_at(2) == '"') fail("multi-line string as key");
      return parse_basic_string();
    }
    if (c == '\'') {
      if (peek_at(1) == '\'' && peek_at(2) == '\'') fail("multi-line string as key");
      return parse_literal_string();
    }
    std::size_t start = pos_;
    while (!eof() && is_bare_key_char(peek())) ++pos_;
    if (pos_ == start) fail("expected key");
    return std::string(s_.substr(start, pos_ - start));
  }

  std::vector<std::string> parse_key() {
    std::vector<std::string> parts;
    parts.push_back(parse_simple_key());
    for (;;) {
      std::size_t save = pos_;
      skip_ws();
      if (!eof() && peek() == '.') {
        ++pos_;
        skip_ws();
        parts.push_back(parse_simple_key());
      } else {
        pos_ = save;
        return parts;
      }
    }
  }

  // ---- tables ----------------------------------------------------------------

  // Resolves one intermediate segment of a [header].
  Value& descend_header(Value& table, std::string& key) {
    auto& m = table.members();
    auto it = m.find(key);
    if (it == m.end()) {
      it = m.emplace(std::move(key), Value::table({}, Origin::Implicit)).first;
      return it->second;
    }
    Value& child = it->second;
    if (child.is_table()) {
      if (child.origin() == Origin::Inline) fail("cannot extend an inline table");
      return child;
    }
    if (child.is_array() && child.origin() == Origin::ArrayOfTables) return child.items().back();
    fail("key is not a table");
  }

  Value* parse_header(Value& root) {
    ++pos_;  // '['
    bool is_array = false;
    if (!eof() && peek() == '[') {
      is_array = true;
      ++pos_;
    }
    skip_ws();
    std::vector<std::string> key = parse_key();
    skip_ws();
    expect(']', "expected ']'");
    if (is_array) expect(']', "expected ']]'");

    Value* t = &root;
    for (std::size_t i = 0; i + 1 < key.size(); ++i) t = &descend_header(*t, key[i]);

    auto& m = t->members();
    std::string& last = key.back();
    auto it = m.find(last);
    if (!is_array) {
      if (it == m.end()) {
        it = m.emplace(std::move(last), Value::table({}, Origin::Explicit)).first;
      } else if (it->second.is_table() && it->second.origin() == Origin::Implicit) {
        it->second.set_origin(Origin::Explicit);
      } else {
        fail("table redefined");
      }
      return &it->second;
    }
    if (it == m.end()) {
      it = m.emplace(std::move(last), Value::array({}, Origin::ArrayOfTables)).first;
    } else if (!(it->second.is_array() && it->second.origin() == Origin::ArrayOfTables)) {
      fail("not an array of tables");
    }
    auto& items = it->second.items();
    items.push_back(Value::table({}, Origin::Explicit));
    return &items.back();
  }

  // Parses `key = value` into `table`. Dotted keys create dotted tables.
  void parse_key_value(Value& table) {
    std::vector<std::string> key = parse_key();
    skip_ws();
    expect('=', "expected '='");
    skip_ws();

    Value* t = &table;
    for (std::size_t i = 0; i + 1 < key.size(); ++i) {
      auto& m = t->members();
      auto it = m.find(key[i]);
      if (it == m.end()) {
        it = m.emplace(std::move(key[i]), Value::table({}, Origin::Dotted)).first;
      } else if (!it->second.is_table() || it->second.origin() == Origin::Explicit ||
                 it->second.origin() == Origin::Inline) {
        fail("cannot extend table with a dotted key");
      }
      t = &it->second;
    }
    auto& m = t->members();
    if (m.find(key.back()) != m.end()) fail("duplicate key");
    Value v = parse_value();
    m.emplace(std::move(key.back()), std::move(v));
  }

  // ---- values ----------------------------------------------------------------
  Value parse_value() {
    if (eof()) fail("expected value");
    switch (peek()) {
      case '"':
        if (peek_at(1) == '"' && peek_at(2) == '"') return Value::string(parse_ml_basic_string());
        return Value::string(parse_basic_string());
      case '\'':
        if (peek_at(1) == '\'' && peek_at(2) == '\'') return Value::string(parse_ml_literal_string());
        return Value::string(parse_literal_string());
      case '[':
        return parse_array();
      case '{':
        return parse_inline_table();
      default:
        return parse_scalar_token();
    }
  }

  Value parse_scalar_token() {
    std::string_view rest = s_.substr(pos_);
    // Date-times: dddd- or dd:
    if ((rest.size() >= 5 && is_digit(rest[0]) && is_digit(rest[1]) && is_digit(rest[2]) &&
         is_digit(rest[3]) && rest[4] == '-') ||
        (rest.size() >= 3 && is_digit(rest[0]) && is_digit(rest[1]) && rest[2] == ':')) {
      auto dt = scan_datetime(rest);
      if (!dt) fail("invalid date or time");
      pos_ += dt->length;
      return Value::scalar(dt->type, std::move(dt->text));
    }
    std::size_t start = pos_;
    while (!eof()) {
      char c = peek();
      if (is_digit(c) || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c == '+' ||
          c == '-' || c == '.')
        ++pos_;
      else
        break;
    }
    std::string_view tok = s_.substr(start, pos_ - start);
    if (tok.empty()) fail("expected value");
    if (tok == "true") return Value::boolean(true);
    if (tok == "false") return Value::boolean(false);

    std::string_view body = (tok[0] == '+' || tok[0] == '-') ? tok.substr(1) : tok;
    bool prefixed = body.size() > 1 && body[0] == '0' && (body[1] == 'x' || body[1] == 'o' || body[1] == 'b');
    bool is_float = false;
    if (!prefixed) {
      for (char c : tok)
        if (c == '.' || c == 'e' || c == 'E') is_float = true;
      if (body == "inf" || body == "nan") is_float = true;
    }
    if (is_float) {
      if (auto f = canonical_float(tok)) return Value::scalar(Type::Float, std::move(*f));
      fail("invalid float", start);
    }
    if (auto i = canonical_integer(tok)) return Value::scalar(Type::Integer, std::move(*i));
    fail("invalid value", start);
  }

  struct DepthGuard {
    Parser& p;
    explicit DepthGuard(Parser& parser) : p(parser) {
      if (++p.depth_ > kMaxDepth) p.fail("nesting too deep");
    }
    ~DepthGuard() { --p.depth_; }
  };

  Value parse_array() {
    DepthGuard guard(*this);
    ++pos_;  // '['
    Value::Array items;
    for (;;) {
      skip_trivia();
      if (eof()) fail("unterminated array");
      if (peek() == ']') {
        ++pos_;
        break;
      }
      items.push_back(parse_value());
      skip_trivia();
      if (eof()) fail("unterminated array");
      if (peek() == ',') {
        ++pos_;
      } else if (peek() == ']') {
        ++pos_;
        break;
      } else {
        fail("expected ',' or ']'");
      }
    }
    return Value::array(std::move(items), Origin::Literal);
  }

  Value parse_inline_table() {
    DepthGuard guard(*this);
    ++pos_;  // '{'
    Value table = Value::table({}, Origin::Dotted);
    skip_ws();
    if (!eof() && peek() == '}') {
      ++pos_;
    } else {
      for (;;) {
        parse_key_value(table);
        skip_ws();
        if (eof()) fail("unterminated inline table");
        if (peek() == ',') {
          ++pos_;
          skip_ws();
        } else if (peek() == '}') {
          ++pos_;
          break;
        } else {
          fail("expected ',' or '}'");
        }
      }
    }
    table.set_origin(Origin::Inline);
    return table;
  }

  // ---- strings ---------------------------------------------------------------
  void append_hex_escape(std::string& out, int digits) {
    char32_t cp = 0;
    for (int k = 0; k < digits; ++k) {
      if (eof()) fail("truncated unicode escape");
      char c = peek();
      int d;
      if (c >= '0' && c <= '9') d = c - '0';
      else if (c >= 'a' && c <= 'f') d = c - 'a' + 10;
      else if (c >= 'A' && c <= 'F') d = c - 'A' + 10;
      else fail("bad hex digit in unicode escape");
      cp = (cp << 4) | static_cast<char32_t>(d);
      ++pos_;
    }
    if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) fail("invalid unicode scalar value");
    append_utf8(out, cp);
  }

  // Positioned just after the backslash.
  void parse_escape(std::string& out) {
    if (eof()) fail("unterminated escape");
    char c = peek();
    ++pos_;
    switch (c) {
      case 'b': out.push_back('\b'); break;
      case 't': out.push_back('\t'); break;
      case 'n': out.push_back('\n'); break;
      case 'f': out.push_back('\f'); break;
      case 'r': out.push_back('\r'); break;
      case '"': out.push_back('"'); break;
      case '\\': out.push_back('\\'); break;
      case 'u': append_hex_escape(out, 4); break;
      case 'U': append_hex_escape(out, 8); break;
      default: fail("invalid escape sequence", pos_ - 1);
    }
  }

  std::string parse_basic_string() {
    ++pos_;  // opening quote
    std::string out;
    for (;;) {
      if (eof()) fail("unterminated string");
      char c = peek();
      if (c == '"') {
        ++pos_;
        return out;
      }
      if (c == '\\') {
        ++pos_;
        parse_escape(out);
        continue;
      }
      if (is_forbidden_control(static_cast<unsigned char>(c))) fail("control character in string");
      out.push_back(c);
      ++pos_;
    }
  }

  std::string parse_literal_string() {
    ++pos_;
    std::string out;
    for (;;) {
      if (eof()) fail("unterminated string");
      char c = peek();
      if (c == '\'') {
        ++pos_;
        return out;
      }
      if (is_forbidden_control(static_cast<unsigned char>(c))) fail("control character in string");
      out.push_back(c);
      ++pos_;
    }
  }

  std::size_t quote_run(char q) const {
    std::size_t n = 0;
    while (pos_ + n < s_.size() && s_[pos_ + n] == q) ++n;
    return n;
  }

  std::string parse_ml_basic_string() {
    pos_ += 3;
    if (at_newline()) skip_newline();
    std::string out;
    for (;;) {
      if (eof()) fail("unterminated multi-line string");
      char c = peek();
      if (c == '"') {
        std::size_t n = quote_run('"');
        if (n >= 6) fail("too many quotes");
        pos_ += n;
        if (n >= 3) {
          out.append(n - 3, '"');
          return out;
        }
        out.append(n, '"');
      } else if (c == '\\') {
        ++pos_;
        std::size_t p = pos_;
        while (p < s_.size() && is_ws(s_[p])) ++p;
        if (at_newline_at(p)) {
          pos_ = p;
          for (;;) {
            if (!eof() && is_ws(peek())) ++pos_;
            else if (at_newline()) skip_newline();
            else break;
          }
        } else {
          parse_escape(out);
        }
      } else if (c == '\r') {
        if (!at_newline()) fail("bare carriage return");
        out.push_back('\n');
        pos_ += 2;
      } else if (c == '\n') {
        out.push_back('\n');
        ++pos_;
      } else {
        if (is_forbidden_control(static_cast<unsigned char>(c))) fail("control character in string");
        out.push_back(c);
        ++pos_;
      }
    }
  }

  std::string parse_ml_literal_string() {
    pos_ += 3;
    if (at_newline()) skip_newline();
    std::string out;
    for (;;) {
      if (eof()) fail("unterminated multi-line string");
      char c = peek();
      if (c == '\'') {
        std::size_t n = quote_run('\'');
        if (n >= 6) fail("too many quotes");
        pos_ += n;
        if (n >= 3) {
          out.append(n - 3, '\'');
          return out;
        }
        out.append(n, '\'');
      } else if (c == '\r') {
        if (!at_newline()) fail("bare carriage return");
        out.push_back('\n');
        pos_ += 2;
      } else if (c == '\n') {
        out.push_back('\n');
        ++pos_;
      } else {
        if (is_forbidden_control(static_cast<unsigned char>(c))) fail("control character in string");
        out.push_back(c);
        ++pos_;
      }
    }
  }
};

}  // namespace

Value parse(std::string_view document) { return Parser(document).parse_document(); }

}  // namespace toml
