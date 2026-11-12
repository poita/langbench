#include "sqlitefile/query.hpp"

#include <charconv>
#include <cstdlib>

#include "sqlitefile/ddl.hpp"
#include "sqlitefile/error.hpp"

namespace sqlitefile {

namespace {

bool isWordChar(char c) {
  return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
         c == '_';
}
bool isDigit(char c) { return c >= '0' && c <= '9'; }

bool isIdentifier(std::string_view w) {
  if (w.empty() || isDigit(w[0])) return false;
  for (char c : w)
    if (!isWordChar(c)) return false;
  return true;
}

[[noreturn]] void fail(const char* msg) { throw QueryError(msg); }

/// A cursor over one query line.
class Parser {
 public:
  explicit Parser(std::string_view s) : s_(s) {}

  bool atEnd() const { return pos_ >= s_.size(); }
  char peek() const { return atEnd() ? '\0' : s_[pos_]; }

  void skipBlanks() {
    while (pos_ < s_.size() && (s_[pos_] == ' ' || s_[pos_] == '\t')) ++pos_;
  }

  /// A maximal run of word characters (possibly empty).
  std::string_view peekWord() const {
    std::size_t e = pos_;
    while (e < s_.size() && isWordChar(s_[e])) ++e;
    return s_.substr(pos_, e - pos_);
  }
  std::string_view readWord() {
    std::string_view w = peekWord();
    pos_ += w.size();
    return w;
  }

  void expectKeyword(std::string_view kw) {
    if (!equalsIgnoreCase(readWord(), kw)) fail("expected keyword");
  }

  std::string readIdentifier() {
    std::string_view w = readWord();
    if (!isIdentifier(w)) fail("expected identifier");
    return std::string(w);
  }

  bool consume(char c) {
    if (peek() == c && !atEnd()) {
      ++pos_;
      return true;
    }
    return false;
  }

  void expectEnd() {
    skipBlanks();
    if (!atEnd()) fail("trailing text");
  }

  Value readLiteral() {
    char c = peek();
    if (c == '\'') return readString();
    if ((c == 'x' || c == 'X') && pos_ + 1 < s_.size() && s_[pos_ + 1] == '\'') return readBlob();
    if (c == '+' || c == '-' || isDigit(c)) return readNumeral();
    std::string_view w = readWord();
    if (equalsIgnoreCase(w, "NULL")) return Value::null();
    fail("bad literal");
  }

  CompareOp readOperator() {
    char c = peek();
    if (c == '=') { ++pos_; return CompareOp::Eq; }
    if (c == '!') {
      ++pos_;
      if (!consume('=')) fail("bad operator");
      return CompareOp::Ne;
    }
    if (c == '<') { ++pos_; return consume('=') ? CompareOp::Le : CompareOp::Lt; }
    if (c == '>') { ++pos_; return consume('=') ? CompareOp::Ge : CompareOp::Gt; }
    std::string_view w = readWord();
    if (!equalsIgnoreCase(w, "IS")) fail("bad operator");
    skipBlanks();
    if (equalsIgnoreCase(peekWord(), "NOT")) {
      readWord();
      return CompareOp::IsNot;
    }
    return CompareOp::Is;
  }

  std::size_t pos() const { return pos_; }
  void seek(std::size_t p) { pos_ = p; }

 private:
  Value readString() {
    ++pos_;  // opening quote
    std::string out;
    while (true) {
      if (atEnd()) fail("unterminated string");
      char c = s_[pos_++];
      if (c == '\'') {
        if (peek() == '\'' && !atEnd()) {
          out.push_back('\'');
          ++pos_;
          continue;
        }
        return Value::text(std::move(out));
      }
      out.push_back(c);
    }
  }

  static int hexVal(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  }

  Value readBlob() {
    pos_ += 2;  // x'
    std::string out;
    while (true) {
      if (atEnd()) fail("unterminated blob");
      if (s_[pos_] == '\'') break;
      int hi = hexVal(s_[pos_]);
      if (hi < 0 || pos_ + 1 >= s_.size()) fail("bad blob");
      int lo = hexVal(s_[pos_ + 1]);
      if (lo < 0) fail("bad blob");
      out.push_back(static_cast<char>(hi * 16 + lo));
      pos_ += 2;
    }
    ++pos_;
    return Value::blob(std::move(out));
  }

  Value readNumeral() {
    std::size_t start = pos_;
    if (peek() == '+' || peek() == '-') ++pos_;
    std::size_t digits = pos_;
    while (isDigit(peek()) && !atEnd()) ++pos_;
    if (pos_ == digits) fail("bad numeral");
    bool real = false;
    if (peek() == '.' && !atEnd()) {
      real = true;
      ++pos_;
      while (isDigit(peek()) && !atEnd()) ++pos_;
    }
    if ((peek() == 'e' || peek() == 'E') && !atEnd()) {
      real = true;
      ++pos_;
      if (peek() == '+' || peek() == '-') ++pos_;
      std::size_t e = pos_;
      while (isDigit(peek()) && !atEnd()) ++pos_;
      if (pos_ == e) fail("bad exponent");
    }
    if (!atEnd() && isWordChar(s_[pos_])) fail("bad numeral");
    std::string_view text = s_.substr(start, pos_ - start);
    if (!real) {
      std::string_view t = text;
      if (t[0] == '+') t.remove_prefix(1);
      std::int64_t v = 0;
      auto r = std::from_chars(t.data(), t.data() + t.size(), v);
      if (r.ec != std::errc() || r.ptr != t.data() + t.size()) fail("integer out of range");
      return Value::integer(v);
    }
    std::string copy(text);
    return Value::real(std::strtod(copy.c_str(), nullptr));
  }

  std::string_view s_;
  std::size_t pos_ = 0;
};

Condition parseCondition(Parser& p) {
  Condition c;
  p.skipBlanks();
  c.column = p.readIdentifier();
  p.skipBlanks();
  c.op = p.readOperator();
  p.skipBlanks();
  c.literal = p.readLiteral();
  return c;
}

SelectQuery parseSelect(Parser& p) {
  SelectQuery q;
  p.skipBlanks();
  if (p.consume('*')) {
    q.all_columns = true;
  } else {
    q.columns.push_back(p.readIdentifier());
    p.skipBlanks();
    while (p.consume(',')) {
      p.skipBlanks();
      q.columns.push_back(p.readIdentifier());
      p.skipBlanks();
    }
  }
  p.skipBlanks();
  p.expectKeyword("FROM");
  p.skipBlanks();
  q.table = p.readIdentifier();

  int stage = 0;  // 1 = WHERE seen, 2 = ORDER BY seen, 3 = LIMIT seen
  while (true) {
    p.skipBlanks();
    if (p.atEnd()) break;
    std::string_view kw = p.readWord();
    if (equalsIgnoreCase(kw, "WHERE") && stage < 1) {
      stage = 1;
      q.where.push_back(parseCondition(p));
      while (true) {
        p.skipBlanks();
        std::size_t save = p.pos();
        if (equalsIgnoreCase(p.readWord(), "AND")) {
          q.where.push_back(parseCondition(p));
        } else {
          p.seek(save);
          break;
        }
      }
    } else if (equalsIgnoreCase(kw, "ORDER") && stage < 2) {
      stage = 2;
      p.skipBlanks();
      p.expectKeyword("BY");
      p.skipBlanks();
      OrderBy ob;
      ob.column = p.readIdentifier();
      p.skipBlanks();
      std::size_t save = p.pos();
      std::string_view w = p.readWord();
      if (equalsIgnoreCase(w, "ASC")) {
      } else if (equalsIgnoreCase(w, "DESC")) {
        ob.descending = true;
      } else {
        p.seek(save);
      }
      q.order_by = std::move(ob);
    } else if (equalsIgnoreCase(kw, "LIMIT") && stage < 3) {
      stage = 3;
      p.skipBlanks();
      std::string_view digits = p.readWord();
      if (digits.empty()) fail("bad LIMIT");
      for (char c : digits)
        if (!isDigit(c)) fail("bad LIMIT");
      std::int64_t n = 0;
      auto r = std::from_chars(digits.data(), digits.data() + digits.size(), n);
      if (r.ec != std::errc()) fail("bad LIMIT");
      q.limit = n;
    } else {
      fail("unexpected text");
    }
  }
  return q;
}

}  // namespace

Query parseQuery(std::string_view line) {
  if (!line.empty() && line[0] == '.') {
    if (line == ".tables") return TablesQuery{};
    if (line.substr(0, 8) == ".schema ") {
      std::string_view arg = line.substr(8);
      if (!isIdentifier(arg)) fail("bad .schema argument");
      return SchemaQuery{std::string(arg)};
    }
    fail("unknown dot command");
  }
  Parser p(line);
  std::string_view cmd = p.readWord();
  if (equalsIgnoreCase(cmd, "SELECT")) return parseSelect(p);
  if (equalsIgnoreCase(cmd, "COUNT")) {
    p.skipBlanks();
    CountQuery q{p.readIdentifier()};
    p.expectEnd();
    return q;
  }
  if (equalsIgnoreCase(cmd, "INDEX")) {
    p.skipBlanks();
    IndexQuery q;
    q.index = p.readIdentifier();
    p.skipBlanks();
    q.key = p.readLiteral();
    p.expectEnd();
    return q;
  }
  fail("unknown command");
}

}  // namespace sqlitefile
