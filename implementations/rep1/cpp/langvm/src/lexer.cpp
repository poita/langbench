#include "lexer.h"

#include <cstdlib>
#include <limits>
#include <unordered_map>

#include "langvm/diagnostic.h"

namespace langvm {
namespace {

constexpr char32_t kEnd = 0xFFFFFFFFu;

bool isDigit(char32_t c) { return c >= '0' && c <= '9'; }
bool isHex(char32_t c) {
  return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}
int hexVal(char32_t c) {
  if (isDigit(c)) return static_cast<int>(c - '0');
  if (c >= 'a' && c <= 'f') return static_cast<int>(c - 'a') + 10;
  return static_cast<int>(c - 'A') + 10;
}
bool isIdentStart(char32_t c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
bool isIdentChar(char32_t c) { return isIdentStart(c) || isDigit(c); }

const std::unordered_map<std::string, Tok>& keywords() {
  static const std::unordered_map<std::string, Tok> kws = {
      {"as", Tok::KwAs},         {"break", Tok::KwBreak}, {"continue", Tok::KwContinue},
      {"else", Tok::KwElse},     {"enum", Tok::KwEnum},   {"false", Tok::KwFalse},
      {"fn", Tok::KwFn},         {"for", Tok::KwFor},     {"if", Tok::KwIf},
      {"impl", Tok::KwImpl},     {"in", Tok::KwIn},       {"let", Tok::KwLet},
      {"match", Tok::KwMatch},   {"pub", Tok::KwPub},     {"return", Tok::KwReturn},
      {"self", Tok::KwSelf},     {"struct", Tok::KwStruct}, {"trait", Tok::KwTrait},
      {"true", Tok::KwTrue},     {"use", Tok::KwUse},     {"var", Tok::KwVar},
      {"when", Tok::KwWhen},     {"while", Tok::KwWhile}};
  return kws;
}

class Lexer {
 public:
  explicit Lexer(const std::u32string& s) : s_(s) {}

  std::vector<Token> run() {
    std::vector<Token> out;
    for (;;) {
      skipTrivia();
      Token t;
      t.pos = {line_, col_};
      if (i_ >= s_.size()) {
        t.kind = Tok::Eof;
        out.push_back(std::move(t));
        return out;
      }
      lexToken(t);
      out.push_back(std::move(t));
    }
  }

 private:
  const std::u32string& s_;
  size_t i_ = 0;
  int line_ = 1, col_ = 1;

  char32_t peek(size_t k = 0) const { return i_ + k < s_.size() ? s_[i_ + k] : kEnd; }
  void adv() {
    if (s_[i_] == '\n') {
      ++line_;
      col_ = 1;
    } else {
      ++col_;
    }
    ++i_;
  }
  [[noreturn]] void fail(ErrorKind k, Pos p) const { throw CompileError(k, p.line, p.col); }

  void skipTrivia() {
    for (;;) {
      char32_t c = peek();
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        adv();
      } else if (c == '/' && peek(1) == '/') {
        while (peek() != kEnd && peek() != '\n') adv();
      } else if (c == '/' && peek(1) == '*') {
        Pos start{line_, col_};
        adv();
        adv();
        int depth = 1;
        while (depth > 0) {
          if (peek() == kEnd) fail(ErrorKind::Unterminated, start);
          if (peek() == '/' && peek(1) == '*') {
            adv(); adv(); ++depth;
          } else if (peek() == '*' && peek(1) == '/') {
            adv(); adv(); --depth;
          } else {
            adv();
          }
        }
      } else {
        return;
      }
    }
  }

  // Parses an escape; the backslash is the current character. Returns the value.
  char32_t escape() {
    Pos bs{line_, col_};
    adv();  // backslash
    char32_t c = peek();
    if (c == kEnd) fail(ErrorKind::BadEscape, bs);
    switch (c) {
      case 'n': adv(); return '\n';
      case 't': adv(); return '\t';
      case 'r': adv(); return '\r';
      case '0': adv(); return 0;
      case '\\': adv(); return '\\';
      case '\'': adv(); return '\'';
      case '"': adv(); return '"';
      case 'u': {
        adv();
        if (peek() != '{') fail(ErrorKind::BadEscape, bs);
        adv();
        uint32_t v = 0;
        int n = 0;
        while (isHex(peek())) {
          if (n < 7) v = v * 16 + static_cast<uint32_t>(hexVal(peek()));
          ++n;
          adv();
        }
        if (peek() != '}' || n < 1 || n > 6) fail(ErrorKind::BadEscape, bs);
        adv();
        if (v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF)) fail(ErrorKind::BadEscape, bs);
        return v;
      }
      default: fail(ErrorKind::BadEscape, bs);
    }
  }

  void lexToken(Token& t) {
    char32_t c = peek();
    if (isIdentStart(c)) return lexIdent(t);
    if (isDigit(c)) return lexNumber(t);
    if (c == '"') return lexString(t);
    if (c == '\'') return lexChar(t);
    lexPunct(t);
  }

  void lexIdent(Token& t) {
    size_t start = i_;
    while (isIdentChar(peek())) adv();
    std::string name;
    for (size_t k = start; k < i_; ++k) name.push_back(static_cast<char>(s_[k]));
    if (name.size() > 200) fail(ErrorKind::BadToken, t.pos);
    if (name == "_") {
      t.kind = Tok::Underscore;
      return;
    }
    auto it = keywords().find(name);
    if (it != keywords().end()) {
      t.kind = it->second;
      return;
    }
    t.kind = Tok::Ident;
    t.text = std::move(name);
  }

  // Reads digits (and '_' after the first digit) satisfying `ok`; appends digits to `out`.
  template <class Pred>
  void digitRun(Pred ok, std::string& out) {
    // precondition: peek() satisfies ok
    while (ok(peek()) || peek() == '_') {
      if (peek() != '_') out.push_back(static_cast<char>(peek()));
      adv();
    }
  }

  void lexNumber(Token& t) {
    char32_t c1 = peek(1);
    if (peek() == '0' && (c1 == 'x' || c1 == 'b')) {
      bool hex = c1 == 'x';
      auto ok = [hex](char32_t c) { return hex ? isHex(c) : (c == '0' || c == '1'); };
      if (!ok(peek(2))) fail(ErrorKind::BadToken, t.pos);
      adv();
      adv();
      unsigned __int128 v = 0;
      bool over = false;
      while (ok(peek()) || peek() == '_') {
        if (peek() != '_') {
          v = v * (hex ? 16 : 2) + static_cast<unsigned>(hexVal(peek()));
          if (v > static_cast<unsigned __int128>(std::numeric_limits<int64_t>::max())) {
            over = true;
            v = static_cast<unsigned __int128>(std::numeric_limits<int64_t>::max()) + 1;
          }
        }
        adv();
      }
      if (over) fail(ErrorKind::IntRange, t.pos);
      t.kind = Tok::Int;
      t.intVal = static_cast<int64_t>(v);
      return;
    }
    std::string text;
    digitRun(isDigit, text);
    bool isFloat = false;
    if (peek() == '.' && isDigit(peek(1))) {
      isFloat = true;
      text.push_back('.');
      adv();
      digitRun(isDigit, text);
    }
    if (peek() == 'e' || peek() == 'E') {
      size_t k = 1;
      if (peek(k) == '+' || peek(k) == '-') ++k;
      if (isDigit(peek(k))) {
        isFloat = true;
        text.push_back('e');
        adv();
        if (peek() == '+' || peek() == '-') {
          text.push_back(static_cast<char>(peek()));
          adv();
        }
        digitRun(isDigit, text);
      }
    }
    if (isFloat) {
      t.kind = Tok::Float;
      t.floatVal = std::strtod(text.c_str(), nullptr);
      return;
    }
    unsigned __int128 v = 0;
    for (char d : text) {
      v = v * 10 + static_cast<unsigned>(d - '0');
      if (v > static_cast<unsigned __int128>(std::numeric_limits<int64_t>::max()))
        fail(ErrorKind::IntRange, t.pos);
    }
    t.kind = Tok::Int;
    t.intVal = static_cast<int64_t>(v);
  }

  void lexString(Token& t) {
    adv();  // opening quote
    for (;;) {
      char32_t c = peek();
      if (c == kEnd || c == '\n' || c == '\r') fail(ErrorKind::Unterminated, t.pos);
      if (c == '"') {
        adv();
        break;
      }
      if (c == '\\') {
        t.strVal.push_back(escape());
      } else {
        t.strVal.push_back(c);
        adv();
      }
    }
    t.kind = Tok::Str;
  }

  void lexChar(Token& t) {
    adv();  // opening quote
    char32_t c = peek();
    if (c == kEnd || c == '\n' || c == '\r' || c == '\'') fail(ErrorKind::Unterminated, t.pos);
    char32_t v;
    if (c == '\\') {
      v = escape();
    } else {
      v = c;
      adv();
    }
    if (peek() != '\'') fail(ErrorKind::Unterminated, t.pos);
    adv();
    t.kind = Tok::Char;
    t.intVal = v;
  }

  void lexPunct(Token& t) {
    char32_t c = peek(), d = peek(1);
    auto two = [&](Tok k) {
      adv();
      adv();
      t.kind = k;
    };
    auto one = [&](Tok k) {
      adv();
      t.kind = k;
    };
    switch (c) {
      case '#':
        if (d == '[') return two(Tok::HashBracket);
        break;
      case ':': return d == ':' ? two(Tok::ColonColon) : one(Tok::Colon);
      case '.': return d == '.' ? two(Tok::DotDot) : one(Tok::Dot);
      case '-': return d == '>' ? two(Tok::Arrow) : one(Tok::Minus);
      case '=': return d == '=' ? two(Tok::EqEq) : one(Tok::Assign);
      case '!': return d == '=' ? two(Tok::NotEq) : one(Tok::Bang);
      case '<':
        if (d == '=') return two(Tok::LessEq);
        if (d == '<') return two(Tok::Shl);
        return one(Tok::Less);
      case '>':
        if (d == '=') return two(Tok::GreaterEq);
        if (d == '>') return two(Tok::Shr);
        return one(Tok::Greater);
      case '&': return d == '&' ? two(Tok::AndAnd) : one(Tok::Amp);
      case '|': return d == '|' ? two(Tok::OrOr) : one(Tok::Pipe);
      case '+': return d == '+' ? two(Tok::PlusPlus) : one(Tok::Plus);
      case '(': return one(Tok::LParen);
      case ')': return one(Tok::RParen);
      case '[': return one(Tok::LBracket);
      case ']': return one(Tok::RBracket);
      case '{': return one(Tok::LBrace);
      case '}': return one(Tok::RBrace);
      case ',': return one(Tok::Comma);
      case ';': return one(Tok::Semi);
      case '*': return one(Tok::Star);
      case '/': return one(Tok::Slash);
      case '%': return one(Tok::Percent);
      case '~': return one(Tok::Tilde);
      case '^': return one(Tok::Caret);
      default: break;
    }
    fail(ErrorKind::BadToken, t.pos);
  }
};

}  // namespace

std::vector<Token> lex(const std::u32string& text) { return Lexer(text).run(); }

}  // namespace langvm
