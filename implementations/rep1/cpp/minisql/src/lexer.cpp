#include "minisql/lexer.hpp"

#include <cctype>
#include <unordered_set>

namespace minisql {

namespace {

bool is_ident_start(char c) {
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}
bool is_digit(char c) { return c >= '0' && c <= '9'; }
bool is_space(char c) {
  return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' ||
         c == '\v';
}

}  // namespace

bool is_keyword(const std::string& w) {
  static const std::unordered_set<std::string> kKeywords = {
      "SELECT", "FROM",  "WHERE", "AND",   "OR",    "NOT",   "NULL",  "IS",
      "LIKE",   "AS",    "INSERT", "INTO", "VALUES", "DELETE", "UPDATE", "SET",
      "CREATE", "TABLE", "INTEGER", "TEXT", "INNER", "JOIN", "ON",    "GROUP",
      "BY",     "HAVING", "ORDER", "ASC",  "DESC",  "LIMIT", "OFFSET", "LEFT",
      "RIGHT",  "FULL",  "OUTER", "CROSS", "NATURAL"};
  return kKeywords.count(w) != 0;
}

std::vector<Token> tokenize(std::string_view in) {
  std::vector<Token> out;
  std::size_t i = 0;
  const std::size_t n = in.size();
  while (i < n) {
    const char c = in[i];
    if (is_space(c)) {
      ++i;
    } else if (c == '-' && i + 1 < n && in[i + 1] == '-') {
      while (i < n && in[i] != '\n') ++i;
    } else if (is_ident_start(c)) {
      const std::size_t start = i;
      std::string upper, lower;
      while (i < n && (is_ident_start(in[i]) || is_digit(in[i]))) {
        const char ch = in[i++];
        upper += static_cast<char>(std::toupper(static_cast<unsigned char>(ch)));
        lower += static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
      }
      if (is_keyword(upper)) {
        out.push_back({TokenKind::Keyword, std::move(upper), start});
      } else {
        out.push_back({TokenKind::Identifier, std::move(lower), start});
      }
    } else if (is_digit(c)) {
      const std::size_t start = i;
      while (i < n && is_digit(in[i])) ++i;
      out.push_back({TokenKind::Integer, std::string(in.substr(start, i - start)), start});
    } else if (c == '\'') {
      const std::size_t start = i++;
      std::string text;
      bool closed = false;
      while (i < n) {
        if (in[i] == '\'') {
          if (i + 1 < n && in[i + 1] == '\'') {
            text += '\'';
            i += 2;
          } else {
            ++i;
            closed = true;
            break;
          }
        } else {
          text += in[i++];
        }
      }
      out.push_back({closed ? TokenKind::String : TokenKind::Invalid, std::move(text), start});
    } else if (c == ';') {
      out.push_back({TokenKind::Semicolon, ";", i++});
    } else {
      const std::size_t start = i;
      const char d = i + 1 < n ? in[i + 1] : '\0';
      if ((c == '<' && (d == '=' || d == '>')) || (c == '>' && d == '=') ||
          (c == '!' && d == '=') || (c == '=' && d == '=')) {
        out.push_back({TokenKind::Symbol, std::string(in.substr(i, 2)), start});
        i += 2;
      } else if (std::string_view("+-*/%=<>(),.").find(c) != std::string_view::npos) {
        out.push_back({TokenKind::Symbol, std::string(1, c), start});
        ++i;
      } else {
        out.push_back({TokenKind::Invalid, std::string(1, c), start});
        ++i;
      }
    }
  }
  return out;
}

std::vector<TokenRange> split_statements(const std::vector<Token>& tokens) {
  std::vector<TokenRange> ranges;
  std::size_t begin = 0;
  for (std::size_t i = 0; i <= tokens.size(); ++i) {
    if (i == tokens.size() || tokens[i].kind == TokenKind::Semicolon) {
      if (i > begin) ranges.emplace_back(begin, i);
      begin = i + 1;
    }
  }
  return ranges;
}

}  // namespace minisql
