#include "datalog/parser.h"

#include <utility>

#include "datalog/error.h"
#include "datalog/lexer.h"

namespace datalog {
namespace {

class Parser {
 public:
  explicit Parser(std::vector<Token> tokens) : toks_(std::move(tokens)) {}

  Program parse() {
    Program program;
    while (peek().kind != TokenKind::End) clause(program);
    return program;
  }

 private:
  const Token& peek(std::size_t ahead = 0) const {
    std::size_t i = pos_ + ahead;
    return i < toks_.size() ? toks_[i] : toks_.back();
  }

  Token take() {
    Token t = peek();
    if (pos_ + 1 < toks_.size()) ++pos_;
    return t;
  }

  [[noreturn]] void fail(const std::string& what) const {
    const Token& t = peek();
    throw ParseError("line " + std::to_string(t.line) + ", column " +
                     std::to_string(t.column) + ": expected " + what + ", found " +
                     describe(t));
  }

  void expect(TokenKind kind, const char* what) {
    if (peek().kind != kind) fail(what);
    take();
  }

  void clause(Program& program) {
    if (peek().kind == TokenKind::QueryMark) {
      take();
      program.queries.push_back(atom());
      expect(TokenKind::Dot, "'.'");
      return;
    }
    Rule rule;
    rule.head = atom();
    if (peek().kind == TokenKind::Implies) {
      take();
      rule.body.push_back(literal());
      while (peek().kind == TokenKind::Comma) {
        take();
        rule.body.push_back(literal());
      }
    }
    expect(TokenKind::Dot, "'.'");
    program.rules.push_back(std::move(rule));
  }

  Atom atom() {
    if (peek().kind != TokenKind::Identifier) fail("a predicate name");
    Atom a;
    a.predicate = take().text;
    expect(TokenKind::LParen, "'('");
    a.args.push_back(term());
    while (peek().kind == TokenKind::Comma) {
      take();
      a.args.push_back(term());
    }
    expect(TokenKind::RParen, "')'");
    return a;
  }

  Term term() {
    switch (peek().kind) {
      case TokenKind::Identifier: return Term::constant(Constant::symbol(take().text));
      case TokenKind::Integer: return Term::constant(Constant::integer(take().integer));
      case TokenKind::Variable: return Term::variable(take().text);
      case TokenKind::Anonymous: take(); return Term::anonymous();
      default: fail("a term");
    }
  }

  static bool is_compare(TokenKind k, CompareOp& op) {
    switch (k) {
      case TokenKind::Lt: op = CompareOp::Lt; return true;
      case TokenKind::Le: op = CompareOp::Le; return true;
      case TokenKind::Gt: op = CompareOp::Gt; return true;
      case TokenKind::Ge: op = CompareOp::Ge; return true;
      case TokenKind::Eq: op = CompareOp::Eq; return true;
      case TokenKind::Ne: op = CompareOp::Ne; return true;
      default: return false;
    }
  }

  Literal literal() {
    if (peek().kind == TokenKind::Not) {
      take();
      return Literal::negative(atom());
    }
    if (peek().kind == TokenKind::Identifier && peek(1).kind == TokenKind::LParen) {
      return Literal::positive(atom());
    }
    Term lhs = term();
    CompareOp op;
    if (!is_compare(peek().kind, op)) fail("a comparison operator");
    take();
    Term rhs = term();
    return Literal::comparison(std::move(lhs), op, std::move(rhs));
  }

  std::vector<Token> toks_;
  std::size_t pos_ = 0;
};

}  // namespace

Program parse_program(std::string_view source) {
  return Parser(tokenize(source)).parse();
}

}  // namespace datalog
