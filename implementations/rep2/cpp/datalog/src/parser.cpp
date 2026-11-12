#include "datalog/parser.h"

#include <cstdlib>
#include <utility>
#include <vector>

namespace datalog {
namespace {

enum class Tok {
  Ident, Var, Anon, Int, Not,
  LParen, RParen, Comma, Dot, Implies, QueryMark,
  Lt, Le, Gt, Ge, Eq, Ne, End
};

struct Token {
  Tok kind;
  std::string text;
  int line;
};

bool is_lower(char c) { return c >= 'a' && c <= 'z'; }
bool is_upper(char c) { return c >= 'A' && c <= 'Z'; }
bool is_digit(char c) { return c >= '0' && c <= '9'; }
bool is_word(char c) {
  return is_lower(c) || is_upper(c) || is_digit(c) || c == '_';
}

std::vector<Token> tokenize(std::string_view s) {
  std::vector<Token> out;
  int line = 1;
  std::size_t i = 0, n = s.size();
  auto push = [&](Tok k, std::string t = {}) {
    out.push_back({k, std::move(t), line});
  };
  while (i < n) {
    char c = s[i];
    if (c == '\n') { ++line; ++i; continue; }
    if (c == ' ' || c == '\t' || c == '\r') { ++i; continue; }
    if (c == '%') {
      while (i < n && s[i] != '\n') ++i;
      continue;
    }
    if (is_lower(c)) {
      std::size_t j = i;
      while (j < n && is_word(s[j])) ++j;
      std::string word(s.substr(i, j - i));
      push(word == "not" ? Tok::Not : Tok::Ident, std::move(word));
      i = j;
    } else if (is_upper(c) || c == '_') {
      std::size_t j = i;
      while (j < n && is_word(s[j])) ++j;
      std::string word(s.substr(i, j - i));
      push(word == "_" ? Tok::Anon : Tok::Var, std::move(word));
      i = j;
    } else if (is_digit(c) || (c == '-' && i + 1 < n && is_digit(s[i + 1]))) {
      std::size_t j = i + 1;
      while (j < n && is_digit(s[j])) ++j;
      push(Tok::Int, std::string(s.substr(i, j - i)));
      i = j;
    } else {
      char d = i + 1 < n ? s[i + 1] : '\0';
      switch (c) {
        case '(': push(Tok::LParen); break;
        case ')': push(Tok::RParen); break;
        case ',': push(Tok::Comma); break;
        case '.': push(Tok::Dot); break;
        case '=': push(Tok::Eq); break;
        case ':':
          if (d != '-') throw ParseError("unexpected ':'", line);
          push(Tok::Implies); ++i; break;
        case '?':
          if (d != '-') throw ParseError("unexpected '?'", line);
          push(Tok::QueryMark); ++i; break;
        case '!':
          if (d != '=') throw ParseError("unexpected '!'", line);
          push(Tok::Ne); ++i; break;
        case '<':
          if (d == '=') { push(Tok::Le); ++i; } else push(Tok::Lt);
          break;
        case '>':
          if (d == '=') { push(Tok::Ge); ++i; } else push(Tok::Gt);
          break;
        default:
          throw ParseError(std::string("unexpected character '") + c + "'",
                           line);
      }
      ++i;
    }
  }
  out.push_back({Tok::End, {}, line});
  return out;
}

class Parser {
 public:
  explicit Parser(std::vector<Token> toks) : toks_(std::move(toks)) {}

  Program parse() {
    Program program;
    while (peek().kind != Tok::End) {
      if (peek().kind == Tok::QueryMark) {
        ++pos_;
        Query q;
        q.atom = atom();
        expect(Tok::Dot, "'.'");
        program.queries.push_back(std::move(q));
        continue;
      }
      Rule r;
      r.head = atom();
      if (accept(Tok::Implies)) {
        do {
          r.body.push_back(literal());
        } while (accept(Tok::Comma));
      }
      expect(Tok::Dot, "'.'");
      program.rules.push_back(std::move(r));
    }
    return program;
  }

 private:
  const Token& peek(std::size_t ahead = 0) const {
    std::size_t p = pos_ + ahead;
    return toks_[p < toks_.size() ? p : toks_.size() - 1];
  }
  bool accept(Tok k) {
    if (peek().kind != k) return false;
    ++pos_;
    return true;
  }
  void expect(Tok k, const char* what) {
    if (!accept(k))
      throw ParseError(std::string("expected ") + what, peek().line);
  }

  Atom atom() {
    if (peek().kind != Tok::Ident)
      throw ParseError("expected predicate name", peek().line);
    Atom a;
    a.predicate = toks_[pos_++].text;
    expect(Tok::LParen, "'('");
    do {
      a.args.push_back(term());
    } while (accept(Tok::Comma));
    expect(Tok::RParen, "')'");
    return a;
  }

  Term term() {
    const Token& t = peek();
    switch (t.kind) {
      case Tok::Ident:
        ++pos_;
        return Term::make_constant(Constant::symbol(t.text));
      case Tok::Int:
        ++pos_;
        return Term::make_constant(
            Constant::integer(std::strtoll(t.text.c_str(), nullptr, 10)));
      case Tok::Var:
        ++pos_;
        return Term::make_variable(t.text);
      case Tok::Anon:
        ++pos_;
        return Term::make_anonymous();
      default:
        throw ParseError("expected a term", t.line);
    }
  }

  Literal literal() {
    Literal lit;
    if (accept(Tok::Not)) {
      lit.kind = Literal::Kind::Negative;
      lit.atom = atom();
      return lit;
    }
    if (peek().kind == Tok::Ident && peek(1).kind == Tok::LParen) {
      lit.kind = Literal::Kind::Positive;
      lit.atom = atom();
      return lit;
    }
    lit.kind = Literal::Kind::Comparison;
    lit.lhs = term();
    switch (peek().kind) {
      case Tok::Lt: lit.op = CompareOp::Lt; break;
      case Tok::Le: lit.op = CompareOp::Le; break;
      case Tok::Gt: lit.op = CompareOp::Gt; break;
      case Tok::Ge: lit.op = CompareOp::Ge; break;
      case Tok::Eq: lit.op = CompareOp::Eq; break;
      case Tok::Ne: lit.op = CompareOp::Ne; break;
      default:
        throw ParseError("expected a comparison operator", peek().line);
    }
    ++pos_;
    lit.rhs = term();
    return lit;
  }

  std::vector<Token> toks_;
  std::size_t pos_ = 0;
};

}  // namespace

Program parse_program(std::string_view source) {
  return Parser(tokenize(source)).parse();
}

}  // namespace datalog
