#include "kiln/lexer.hpp"

#include "kiln/error.hpp"

namespace kiln {

std::size_t skipSingleQuoted(std::string_view s, std::size_t i) {
  while (i < s.size()) {
    if (s[i] == '\'') {
      if (i + 1 < s.size() && s[i + 1] == '\'') {
        i += 2;
        continue;
      }
      return i + 1;
    }
    ++i;
  }
  throw SyntaxError{};
}

std::size_t skipDoubleQuoted(std::string_view s, std::size_t i) {
  while (i < s.size()) {
    char c = s[i];
    if (c == '\\') {
      i += 2;
    } else if (c == '{') {
      if (i + 1 < s.size() && s[i + 1] == '{') i += 2;
      else i = skipInterpolation(s, i + 1);
    } else if (c == '}') {
      i += (i + 1 < s.size() && s[i + 1] == '}') ? 2 : 1;
    } else if (c == '"') {
      return i + 1;
    } else {
      ++i;
    }
  }
  throw SyntaxError{};
}

std::size_t skipInterpolation(std::string_view s, std::size_t i) {
  int depth = 1;
  while (i < s.size()) {
    char c = s[i];
    if (c == '"') {
      i = skipDoubleQuoted(s, i + 1);
    } else if (c == '\'') {
      i = skipSingleQuoted(s, i + 1);
    } else if (c == '{') {
      ++depth;
      ++i;
    } else if (c == '}') {
      ++i;
      if (--depth == 0) return i;
    } else {
      ++i;
    }
  }
  throw SyntaxError{};
}

namespace {

bool isIdentStart(char c) {
  return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
}
bool isDigit(char c) { return c >= '0' && c <= '9'; }

// Scans one physical line: returns the length of the part before any comment,
// updating the running bracket depth.
std::size_t scanPhysicalLine(std::string_view line, int& depth) {
  std::size_t i = 0;
  while (i < line.size()) {
    char c = line[i];
    if (c == '"') {
      i = skipDoubleQuoted(line, i + 1);
    } else if (c == '\'') {
      i = skipSingleQuoted(line, i + 1);
    } else if (c == '#') {
      return i;
    } else {
      if (c == '(' || c == '[') ++depth;
      else if (c == ')' || c == ']') {
        if (--depth < 0) throw SyntaxError{};
      }
      ++i;
    }
  }
  return line.size();
}

bool isBlank(std::string_view s) {
  for (char c : s)
    if (c != ' ' && c != '\t') return false;
  return true;
}

}  // namespace

std::vector<Token> tokenize(std::string_view text) {
  std::vector<Token> out;
  std::size_t i = 0;
  const std::size_t n = text.size();
  while (i < n) {
    char c = text[i];
    if (c == ' ' || c == '\t') {
      ++i;
      continue;
    }
    Token t;
    if (isIdentStart(c)) {
      std::size_t j = i + 1;
      while (j < n && (isIdentStart(text[j]) || isDigit(text[j]))) ++j;
      t.kind = Token::Ident;
      t.text = std::string(text.substr(i, j - i));
      i = j;
    } else if (isDigit(c)) {
      std::size_t j = i + 1;
      while (j < n && isDigit(text[j])) ++j;
      t.kind = Token::Int;
      t.text = std::string(text.substr(i, j - i));
      i = j;
    } else if (c == '"') {
      std::size_t j = skipDoubleQuoted(text, i + 1);
      t.kind = Token::Str;
      t.doubleQuoted = true;
      t.text = std::string(text.substr(i + 1, j - 1 - (i + 1)));
      i = j;
    } else if (c == '\'') {
      std::size_t j = skipSingleQuoted(text, i + 1);
      t.kind = Token::Str;
      t.doubleQuoted = false;
      t.text = std::string(text.substr(i + 1, j - 1 - (i + 1)));
      i = j;
    } else {
      t.kind = Token::Sym;
      static const char* two[] = {"|>", "||", "&&", "==", "!=", "<=", ">=", "++"};
      bool matched = false;
      if (i + 1 < n) {
        for (const char* op : two) {
          if (text[i] == op[0] && text[i + 1] == op[1]) {
            t.text = op;
            i += 2;
            matched = true;
            break;
          }
        }
      }
      if (!matched) {
        static const std::string_view single = "()[]{},=<>~+-*/%!";
        if (single.find(c) == std::string_view::npos) throw SyntaxError{};
        t.text = std::string(1, c);
        ++i;
      }
    }
    out.push_back(std::move(t));
  }
  return out;
}

std::vector<LogicalLine> lexBuildFile(std::string_view src, const std::string& file) {
  std::vector<LogicalLine> out;
  auto fail = [&](int line) {
    throw Error("E_PARSE", file + ":" + std::to_string(line));
  };
  std::size_t pos = 0;
  int lineNo = 0;
  bool inGroup = false;
  int groupLine = 0;
  int depth = 0;
  std::string group;
  while (pos < src.size()) {
    std::size_t nl = src.find('\n', pos);
    std::string_view line =
        src.substr(pos, nl == std::string_view::npos ? src.size() - pos : nl - pos);
    pos = nl == std::string_view::npos ? src.size() : nl + 1;
    ++lineNo;
    if (!inGroup) {
      inGroup = true;
      groupLine = lineNo;
      group.clear();
    } else {
      group += ' ';
    }
    std::size_t cut = 0;
    try {
      cut = scanPhysicalLine(line, depth);
    } catch (const SyntaxError&) {
      fail(groupLine);
    }
    std::string_view kept = line.substr(0, cut);
    while (!kept.empty() && (kept.back() == ' ' || kept.back() == '\t')) kept.remove_suffix(1);
    group.append(kept);
    if (depth == 0) {
      inGroup = false;
      if (!isBlank(group)) {
        LogicalLine ll;
        ll.line = groupLine;
        try {
          ll.tokens = tokenize(group);
        } catch (const SyntaxError&) {
          fail(groupLine);
        }
        out.push_back(std::move(ll));
      }
    }
  }
  if (inGroup) fail(groupLine);
  return out;
}

}  // namespace kiln
