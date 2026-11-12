#include "datalog/lexer.h"

#include <cctype>

#include "datalog/error.h"

namespace datalog {
namespace {

bool is_lower(char c) { return c >= 'a' && c <= 'z'; }
bool is_upper(char c) { return c >= 'A' && c <= 'Z'; }
bool is_digit(char c) { return c >= '0' && c <= '9'; }
bool is_word(char c) { return is_lower(c) || is_upper(c) || is_digit(c) || c == '_'; }

}  // namespace

std::vector<Token> tokenize(std::string_view s) {
  std::vector<Token> out;
  std::size_t i = 0;
  int line = 1;
  std::size_t line_start = 0;
  const std::size_t n = s.size();

  auto push = [&](TokenKind kind, std::size_t start, std::size_t len) -> Token& {
    Token t;
    t.kind = kind;
    t.line = line;
    t.column = static_cast<int>(start - line_start) + 1;
    out.push_back(std::move(t));
    i = start + len;
    return out.back();
  };

  while (i < n) {
    char c = s[i];
    if (c == '\n') {
      ++line;
      ++i;
      line_start = i;
    } else if (c == ' ' || c == '\t' || c == '\r') {
      ++i;
    } else if (c == '%') {
      while (i < n && s[i] != '\n') ++i;
    } else if (is_lower(c)) {
      std::size_t j = i;
      while (j < n && is_word(s[j])) ++j;
      std::string word(s.substr(i, j - i));
      if (word == "not") {
        push(TokenKind::Not, i, j - i);
      } else {
        push(TokenKind::Identifier, i, j - i).text = std::move(word);
      }
    } else if (is_upper(c) || c == '_') {
      std::size_t j = i;
      while (j < n && is_word(s[j])) ++j;
      if (j - i == 1 && c == '_') {
        push(TokenKind::Anonymous, i, 1);
      } else {
        push(TokenKind::Variable, i, j - i).text = std::string(s.substr(i, j - i));
      }
    } else if (is_digit(c) || (c == '-' && i + 1 < n && is_digit(s[i + 1]))) {
      std::size_t j = i + (c == '-' ? 1 : 0);
      std::int64_t v = 0;
      while (j < n && is_digit(s[j])) {
        v = v * 10 + (s[j] - '0');
        if (v > 4000000000000000000LL) throw ParseError("integer literal too large");
        ++j;
      }
      push(TokenKind::Integer, i, j - i).integer = (c == '-') ? -v : v;
    } else {
      char d = i + 1 < n ? s[i + 1] : '\0';
      switch (c) {
        case '(': push(TokenKind::LParen, i, 1); break;
        case ')': push(TokenKind::RParen, i, 1); break;
        case ',': push(TokenKind::Comma, i, 1); break;
        case '.': push(TokenKind::Dot, i, 1); break;
        case ':':
          if (d == '-') { push(TokenKind::Implies, i, 2); break; }
          throw ParseError("line " + std::to_string(line) + ": unexpected ':'");
        case '?':
          if (d == '-') { push(TokenKind::QueryMark, i, 2); break; }
          throw ParseError("line " + std::to_string(line) + ": unexpected '?'");
        case '<':
          if (d == '=') push(TokenKind::Le, i, 2); else push(TokenKind::Lt, i, 1);
          break;
        case '>':
          if (d == '=') push(TokenKind::Ge, i, 2); else push(TokenKind::Gt, i, 1);
          break;
        case '=': push(TokenKind::Eq, i, 1); break;
        case '!':
          if (d == '=') { push(TokenKind::Ne, i, 2); break; }
          throw ParseError("line " + std::to_string(line) + ": unexpected '!'");
        default:
          throw ParseError("line " + std::to_string(line) + ": unexpected character '" +
                           std::string(1, c) + "'");
      }
    }
  }
  Token end;
  end.kind = TokenKind::End;
  end.line = line;
  end.column = static_cast<int>(n - line_start) + 1;
  out.push_back(end);
  return out;
}

std::string describe(const Token& t) {
  switch (t.kind) {
    case TokenKind::Identifier: return "identifier '" + t.text + "'";
    case TokenKind::Variable: return "variable '" + t.text + "'";
    case TokenKind::Anonymous: return "'_'";
    case TokenKind::Integer: return "integer " + std::to_string(t.integer);
    case TokenKind::Not: return "'not'";
    case TokenKind::LParen: return "'('";
    case TokenKind::RParen: return "')'";
    case TokenKind::Comma: return "','";
    case TokenKind::Dot: return "'.'";
    case TokenKind::Implies: return "':-'";
    case TokenKind::QueryMark: return "'?-'";
    case TokenKind::Lt: return "'<'";
    case TokenKind::Le: return "'<='";
    case TokenKind::Gt: return "'>'";
    case TokenKind::Ge: return "'>='";
    case TokenKind::Eq: return "'='";
    case TokenKind::Ne: return "'!='";
    case TokenKind::End: return "end of input";
  }
  return "?";
}

}  // namespace datalog
