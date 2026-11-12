#include "kiln/lexer.hpp"

#include <array>
#include <cctype>

#include "kiln/error.hpp"

namespace kiln {

namespace {
constexpr std::size_t npos = std::string_view::npos;

bool is_blank(char c) { return c == ' ' || c == '\t'; }
bool is_ident_start(char c) { return std::isalpha(static_cast<unsigned char>(c)) || c == '_'; }
bool is_ident_char(char c) { return is_ident_start(c) || std::isdigit(static_cast<unsigned char>(c)); }
bool is_digit(char c) { return c >= '0' && c <= '9'; }

[[noreturn]] void parse_error(std::string_view file, int line) {
  throw Error(ErrorKind::Parse, std::string(file) + ":" + std::to_string(line));
}
}  // namespace

std::size_t scan_interpolation(std::string_view s, std::size_t pos) {
  int depth = 1;
  std::size_t i = pos + 1;
  while (i < s.size()) {
    char c = s[i];
    if (c == '"' || c == '\'') {
      i = scan_literal(s, i);
      if (i == npos) return npos;
    } else if (c == '{') {
      ++depth;
      ++i;
    } else if (c == '}') {
      if (--depth == 0) return i;
      ++i;
    } else {
      ++i;
    }
  }
  return npos;
}

std::size_t scan_literal(std::string_view s, std::size_t pos) {
  char q = s[pos];
  std::size_t i = pos + 1;
  if (q == '\'') {
    while (i < s.size()) {
      if (s[i] == '\'') {
        if (i + 1 < s.size() && s[i + 1] == '\'') {
          i += 2;
        } else {
          return i + 1;
        }
      } else {
        ++i;
      }
    }
    return npos;
  }
  while (i < s.size()) {
    char c = s[i];
    if (c == '\\') {
      if (i + 1 >= s.size()) return npos;
      i += 2;
    } else if (c == '{') {
      if (i + 1 < s.size() && s[i + 1] == '{') {
        i += 2;
      } else {
        std::size_t end = scan_interpolation(s, i);
        if (end == npos) return npos;
        i = end + 1;
      }
    } else if (c == '}') {
      i += (i + 1 < s.size() && s[i + 1] == '}') ? 2 : 1;
    } else if (c == '"') {
      return i + 1;
    } else {
      ++i;
    }
  }
  return npos;
}

bool is_reserved_word(std::string_view s) {
  static constexpr std::array<std::string_view, 21> words = {
      "abort", "after", "cmd",  "cost", "default", "depfile", "each",
      "elsewhen", "false", "in", "include", "let",   "otherwise", "out",
      "phony", "rule",  "set",  "step", "true",    "use",     "when"};
  for (auto w : words) {
    if (w == s) return true;
  }
  return false;
}

std::vector<Token> tokenize(std::string_view text) {
  std::vector<Token> out;
  std::size_t i = 0;
  while (i < text.size()) {
    char c = text[i];
    if (is_blank(c)) {
      ++i;
      continue;
    }
    Token t;
    if (is_ident_start(c)) {
      std::size_t j = i;
      while (j < text.size() && is_ident_char(text[j])) ++j;
      t.kind = TokenKind::Ident;
      t.text = std::string(text.substr(i, j - i));
      i = j;
    } else if (is_digit(c)) {
      std::size_t j = i;
      std::uint64_t v = 0;
      while (j < text.size() && is_digit(text[j])) {
        v = v * 10 + static_cast<std::uint64_t>(text[j] - '0');
        ++j;
      }
      t.kind = TokenKind::Int;
      t.text = std::string(text.substr(i, j - i));
      t.int_value = static_cast<std::int64_t>(v);
      i = j;
    } else if (c == '"' || c == '\'') {
      std::size_t end = scan_literal(text, i);
      if (end == npos) throw SyntaxError{};
      t.kind = TokenKind::Str;
      t.text = std::string(text.substr(i, end - i));
      i = end;
    } else if (std::string_view("()[]{},=").find(c) != npos &&
               !(c == '=' && i + 1 < text.size() && text[i + 1] == '=')) {
      t.kind = TokenKind::Punct;
      t.text = std::string(1, c);
      ++i;
    } else {
      static constexpr std::array<std::string_view, 17> ops = {
          "|>", "||", "&&", "==", "!=", "<=", ">=", "++", "<", ">", "~", "+", "-", "*", "/", "%", "!"};
      bool found = false;
      for (auto op : ops) {
        if (text.substr(i, op.size()) == op) {
          t.kind = TokenKind::Op;
          t.text = std::string(op);
          i += op.size();
          found = true;
          break;
        }
      }
      if (!found) throw SyntaxError{};
    }
    out.push_back(std::move(t));
  }
  return out;
}

std::vector<LogicalLine> lex(std::string_view source, std::string_view file) {
  std::vector<LogicalLine> lines;
  std::string group;
  int group_line = 0;
  int depth = 0;
  bool in_group = false;

  auto finish_group = [&]() {
    bool blank = true;
    for (char c : group) {
      if (!is_blank(c)) {
        blank = false;
        break;
      }
    }
    if (!blank) {
      LogicalLine ll;
      ll.line = group_line;
      try {
        ll.tokens = tokenize(group);
      } catch (const SyntaxError&) {
        parse_error(file, group_line);
      }
      lines.push_back(std::move(ll));
    }
    group.clear();
    in_group = false;
  };

  std::size_t pos = 0;
  int line_no = 0;
  while (pos < source.size()) {
    std::size_t nl = source.find('\n', pos);
    std::string_view phys = source.substr(pos, nl == npos ? npos : nl - pos);
    pos = nl == npos ? source.size() : nl + 1;
    ++line_no;
    if (!in_group) {
      in_group = true;
      group_line = line_no;
      depth = 0;
    }
    // Stage 1 + 2: one pass finds the comment and updates the bracket depth.
    std::size_t keep = phys.size();
    for (std::size_t i = 0; i < phys.size();) {
      char c = phys[i];
      if (c == '"' || c == '\'') {
        i = scan_literal(phys, i);
        if (i == npos) parse_error(file, group_line);
      } else if (c == '#') {
        keep = i;
        break;
      } else {
        if (c == '(' || c == '[') ++depth;
        else if (c == ')' || c == ']') {
          if (--depth < 0) parse_error(file, group_line);
        }
        ++i;
      }
    }
    while (keep > 0 && is_blank(phys[keep - 1])) --keep;
    if (!group.empty() || group_line != line_no) group.push_back(' ');
    group.append(phys.substr(0, keep));
    if (depth == 0) finish_group();
  }
  if (in_group) {
    if (depth > 0) parse_error(file, group_line);
    finish_group();
  }
  return lines;
}

}  // namespace kiln
