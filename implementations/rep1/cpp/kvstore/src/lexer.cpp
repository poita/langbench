#include "tessera/lexer.hpp"

#include "tessera/error.hpp"

namespace tessera {
namespace {

bool is_digit(char c) { return c >= '0' && c <= '9'; }
bool is_word_start(char c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'; }
bool is_word_char(char c) { return is_word_start(c) || is_digit(c); }

int hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

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

// Lexes the string literal starting at line[i] == '"'; advances i past it.
Token lex_string(std::string_view line, std::size_t& i) {
  Token tok;
  tok.type = Token::Type::String;
  ++i;
  std::uint32_t pending_high = 0;  // a high surrogate awaiting its low half
  auto flush_pending = [&] {
    if (pending_high) {
      tok.bad_utf8 = true;
      pending_high = 0;
    }
  };
  while (true) {
    if (i >= line.size()) throw Error(ErrorKind::Syntax);
    unsigned char c = static_cast<unsigned char>(line[i]);
    if (c == '"') {
      ++i;
      break;
    }
    if (c < 0x20) throw Error(ErrorKind::Syntax);
    if (c != '\\') {
      flush_pending();
      tok.text.push_back(static_cast<char>(c));
      ++i;
      continue;
    }
    if (i + 1 >= line.size()) throw Error(ErrorKind::Syntax);
    char e = line[i + 1];
    if (e == 'u') {
      if (i + 6 > line.size()) throw Error(ErrorKind::Syntax);
      std::uint32_t unit = 0;
      for (int k = 0; k < 4; ++k) {
        int hv = hex_value(line[i + 2 + k]);
        if (hv < 0) throw Error(ErrorKind::Syntax);
        unit = unit * 16 + static_cast<std::uint32_t>(hv);
      }
      i += 6;
      if (pending_high) {
        if (unit >= 0xDC00 && unit <= 0xDFFF) {
          append_utf8(tok.text, 0x10000 + ((pending_high - 0xD800) << 10) + (unit - 0xDC00));
          pending_high = 0;
          continue;
        }
        flush_pending();
      }
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        pending_high = unit;
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        tok.bad_utf8 = true;
      } else {
        append_utf8(tok.text, unit);
      }
      continue;
    }
    flush_pending();
    switch (e) {
      case '"': tok.text.push_back('"'); break;
      case '\\': tok.text.push_back('\\'); break;
      case '/': tok.text.push_back('/'); break;
      case 'b': tok.text.push_back('\b'); break;
      case 'f': tok.text.push_back('\f'); break;
      case 'n': tok.text.push_back('\n'); break;
      case 'r': tok.text.push_back('\r'); break;
      case 't': tok.text.push_back('\t'); break;
      default: throw Error(ErrorKind::Syntax);
    }
    i += 2;
  }
  flush_pending();
  return tok;
}

}  // namespace

std::vector<Token> lex(std::string_view line) {
  std::vector<Token> out;
  std::size_t i = 0;
  while (i < line.size()) {
    char c = line[i];
    if (c == ' ' || c == '\t') {
      ++i;
      continue;
    }
    Token tok;
    if (is_word_start(c)) {
      std::size_t j = i + 1;
      while (j < line.size() && is_word_char(line[j])) ++j;
      tok.type = Token::Type::Word;
      tok.text = std::string(line.substr(i, j - i));
      i = j;
    } else if (is_digit(c) || c == '-') {
      std::size_t j = i;
      if (c == '-') ++j;
      std::size_t digits = j;
      while (j < line.size() && is_digit(line[j])) ++j;
      if (j == digits) throw Error(ErrorKind::Syntax);  // bare '-'
      // "0" or a run starting 1-9; "-0", "007" are rejected.
      if (line[digits] == '0' && (j - digits > 1 || c == '-')) throw Error(ErrorKind::Syntax);
      tok.type = Token::Type::Int;
      tok.text = std::string(line.substr(i, j - i));
      i = j;
    } else if (c == '"') {
      tok = lex_string(line, i);
    } else if (c == '{' || c == '}' || c == '[' || c == ']' || c == '(' || c == ')' || c == ',' ||
               c == ':' || c == '.') {
      tok.type = Token::Type::Punct;
      tok.text = std::string(1, c);
      ++i;
    } else if (c == '=' || c == '!' || c == '<' || c == '>') {
      bool eq = i + 1 < line.size() && line[i + 1] == '=';
      if ((c == '=' || c == '!') && !eq) throw Error(ErrorKind::Syntax);
      tok.type = Token::Type::Op;
      tok.text = eq ? std::string(line.substr(i, 2)) : std::string(1, c);
      i += eq ? 2 : 1;
    } else {
      throw Error(ErrorKind::Syntax);
    }
    out.push_back(std::move(tok));
  }
  return out;
}

}  // namespace tessera
