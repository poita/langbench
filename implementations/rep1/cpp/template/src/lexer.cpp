#include "jinjalite/lexer.hpp"

#include <charconv>
#include <cstdlib>

#include "jinjalite/error.hpp"

namespace jinjalite {
namespace {

[[noreturn]] void syntax(const char* msg) { throw Error(ErrorKind::Syntax, msg); }

bool is_name_start(char c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'; }
bool is_digit(char c) { return c >= '0' && c <= '9'; }

class Lexer {
 public:
  explicit Lexer(std::string_view src) : src_(src) {}

  std::vector<Item> run() {
    std::string text;       // text accumulated since the previous tag
    bool strip_next = false;  // previous tag ended with '-'
    size_t pos = 0;
    for (;;) {
      size_t open = find_opener(pos);
      if (open == std::string_view::npos) {
        text.append(src_.substr(pos));
        flush_text(text, strip_next, false);
        return std::move(items_);
      }
      text.append(src_.substr(pos, open - pos));
      char kind = src_[open + 1];
      size_t content = open + 2;
      bool strip_before = content < src_.size() && src_[content] == '-';
      if (strip_before) ++content;
      flush_text(text, strip_next, strip_before);
      strip_next = false;

      if (kind == '#') {
        size_t end = src_.find("#}", content);
        if (end == std::string_view::npos) syntax("unclosed comment");
        strip_next = end > content && src_[end - 1] == '-';
        pos = end + 2;
      } else {
        Item item;
        item.kind = kind == '{' ? Item::Kind::Print : Item::Kind::Statement;
        pos = lex_tag(content, kind == '{' ? '}' : '%', item.tokens, strip_next);
        items_.push_back(std::move(item));
      }
    }
  }

 private:
  // Position of the next "{{", "{%" or "{#" at or after `from`.
  size_t find_opener(size_t from) const {
    while (from < src_.size()) {
      size_t p = src_.find('{', from);
      if (p == std::string_view::npos || p + 1 >= src_.size()) return std::string_view::npos;
      char n = src_[p + 1];
      if (n == '{' || n == '%' || n == '#') return p;
      from = p + 1;
    }
    return std::string_view::npos;
  }

  // Emits the pending text as an item after applying whitespace control.
  void flush_text(std::string& text, bool strip_leading, bool strip_trailing) {
    size_t b = 0, e = text.size();
    if (strip_leading) {
      while (b < e && is_template_space(text[b])) ++b;
    }
    if (strip_trailing) {
      while (e > b && is_template_space(text[e - 1])) --e;
    }
    if (e > b) {
      Item item;
      item.kind = Item::Kind::Text;
      item.text.assign(text, b, e - b);
      items_.push_back(std::move(item));
    }
    text.clear();
  }

  // Tokenizes a tag body starting at `pos` until its closer; returns the
  // position after the closer.
  size_t lex_tag(size_t pos, char closer, std::vector<Token>& tokens, bool& strip_after) {
    const size_t n = src_.size();
    for (;;) {
      while (pos < n && is_template_space(src_[pos])) ++pos;
      if (pos >= n) syntax("unclosed tag");
      char c = src_[pos];
      if (c == '-' && pos + 2 < n && src_[pos + 1] == closer && src_[pos + 2] == '}') {
        strip_after = true;
        return pos + 3;
      }
      if (c == closer && pos + 1 < n && src_[pos + 1] == '}') {
        strip_after = false;
        return pos + 2;
      }
      Token tok;
      if (is_name_start(c)) {
        size_t s = pos;
        while (pos < n && (is_name_start(src_[pos]) || is_digit(src_[pos]))) ++pos;
        tok.kind = TokenKind::Name;
        tok.text.assign(src_.substr(s, pos - s));
      } else if (is_digit(c)) {
        size_t s = pos;
        while (pos < n && is_digit(src_[pos])) ++pos;
        if (pos + 1 < n && src_[pos] == '.' && is_digit(src_[pos + 1])) {
          ++pos;
          while (pos < n && is_digit(src_[pos])) ++pos;
          tok.kind = TokenKind::Float;
          tok.text.assign(src_.substr(s, pos - s));
          tok.float_value = std::strtod(tok.text.c_str(), nullptr);
        } else {
          tok.kind = TokenKind::Int;
          tok.text.assign(src_.substr(s, pos - s));
          auto res = std::from_chars(tok.text.data(), tok.text.data() + tok.text.size(), tok.int_value);
          if (res.ec != std::errc()) syntax("integer literal out of range");
        }
      } else if (c == '"' || c == '\'') {
        pos = lex_string(pos, tok);
      } else {
        tok.kind = TokenKind::Op;
        static const char* const two[] = {"**", "//", "==", "!=", "<=", ">="};
        bool matched = false;
        if (pos + 1 < n) {
          for (const char* op : two) {
            if (src_[pos] == op[0] && src_[pos + 1] == op[1]) {
              tok.text = op;
              pos += 2;
              matched = true;
              break;
            }
          }
        }
        if (!matched) {
          static const std::string_view singles = "~+-*/%<>()[],|.=";
          if (singles.find(c) == std::string_view::npos) syntax("unexpected character in tag");
          tok.text.assign(1, c);
          ++pos;
        }
      }
      tokens.push_back(std::move(tok));
    }
  }

  size_t lex_string(size_t pos, Token& tok) {
    const char quote = src_[pos++];
    tok.kind = TokenKind::String;
    for (;;) {
      if (pos >= src_.size()) syntax("unterminated string");
      char c = src_[pos++];
      if (c == quote) return pos;
      if (c != '\\') {
        tok.text += c;
        continue;
      }
      if (pos >= src_.size()) syntax("unterminated string");
      char e = src_[pos++];
      switch (e) {
        case '\\': tok.text += '\\'; break;
        case '"': tok.text += '"'; break;
        case '\'': tok.text += '\''; break;
        case 'n': tok.text += '\n'; break;
        case 't': tok.text += '\t'; break;
        default: syntax("bad string escape");
      }
    }
  }

  std::string_view src_;
  std::vector<Item> items_;
};

}  // namespace

std::vector<Item> lex_template(std::string_view source) { return Lexer(source).run(); }

}  // namespace jinjalite
