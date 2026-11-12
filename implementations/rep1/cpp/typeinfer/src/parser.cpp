#include "typeinfer/parser.hpp"

#include <string>

#include "typeinfer/errors.hpp"

namespace typeinfer {

namespace {
bool starts_atom(TokenKind k) {
    switch (k) {
        case TokenKind::Int:
        case TokenKind::Ident:
        case TokenKind::KwTrue:
        case TokenKind::KwFalse:
        case TokenKind::LParen:
        case TokenKind::LBracket:
            return true;
        default:
            return false;
    }
}
}  // namespace

bool Parser::accept(TokenKind k) {
    if (peek().kind != k) return false;
    ++pos_;
    return true;
}

const Token& Parser::expect(TokenKind k, const char* what) {
    if (peek().kind != k)
        throw ParseError(std::string("expected ") + what, peek().offset);
    return advance();
}

Symbol Parser::expect_ident() {
    return symbols_.intern(expect(TokenKind::Ident, "identifier").text);
}

Expr* Parser::make(ExprKind k) {
    Expr* e = arena_.create<Expr>();
    e->kind = k;
    return e;
}

const Expr* Parser::binary(BinaryOp op, const Expr* l, const Expr* r) {
    Expr* e = make(ExprKind::Binary);
    e->op = op;
    e->first = l;
    e->second = r;
    return e;
}

std::span<const Symbol> Parser::parse_params() {
    std::vector<Symbol> ps;
    while (peek().kind == TokenKind::Ident) ps.push_back(expect_ident());
    return arena_.copy(ps);
}

std::optional<Decl> Parser::next_declaration() {
    if (peek().kind == TokenKind::End) return std::nullopt;
    Decl d{};
    if (peek().kind == TokenKind::KwLet) {
        parse_let(true, &d);
    } else {
        d.kind = DeclKind::Expr;
        d.body = parse_expr();
    }
    expect(TokenKind::SemiSemi, "';;'");
    return d;
}

// let [rec] name params = expr [in expr]. For a declaration there is no `in`.
const Expr* Parser::parse_let(bool is_decl, Decl* decl) {
    expect(TokenKind::KwLet, "'let'");
    bool rec = accept(TokenKind::KwRec);
    Symbol name = expect_ident();
    std::span<const Symbol> params = parse_params();
    expect(TokenKind::Eq, "'='");
    const Expr* rhs = parse_expr();
    if (is_decl) {
        decl->kind = rec ? DeclKind::LetRec : DeclKind::Let;
        decl->name = name;
        decl->params = params;
        decl->body = rhs;
        return nullptr;
    }
    expect(TokenKind::KwIn, "'in'");
    const Expr* body = parse_expr();
    Expr* e = make(rec ? ExprKind::LetRec : ExprKind::Let);
    e->name = name;
    e->params = params;
    e->first = rhs;
    e->second = body;
    return e;
}

const Expr* Parser::parse_expr() {
    switch (peek().kind) {
        case TokenKind::KwLet:
            return parse_let(false, nullptr);
        case TokenKind::KwFun: {
            advance();
            Expr* e = make(ExprKind::Lambda);
            e->params = parse_params();
            if (e->params.empty()) throw ParseError("expected parameter", peek().offset);
            expect(TokenKind::Arrow, "'->'");
            e->second = parse_expr();
            return e;
        }
        case TokenKind::KwIf: {
            advance();
            Expr* e = make(ExprKind::If);
            e->first = parse_expr();
            expect(TokenKind::KwThen, "'then'");
            e->second = parse_expr();
            expect(TokenKind::KwElse, "'else'");
            e->third = parse_expr();
            return e;
        }
        default:
            return parse_or();
    }
}

const Expr* Parser::parse_or() {
    const Expr* l = parse_and();
    while (accept(TokenKind::OrOr)) l = binary(BinaryOp::Or, l, parse_and());
    return l;
}

const Expr* Parser::parse_and() {
    const Expr* l = parse_cmp();
    while (accept(TokenKind::AndAnd)) l = binary(BinaryOp::And, l, parse_cmp());
    return l;
}

const Expr* Parser::parse_cmp() {
    const Expr* l = parse_cons();
    BinaryOp op;
    switch (peek().kind) {
        case TokenKind::Eq: op = BinaryOp::Eq; break;
        case TokenKind::Lt: op = BinaryOp::Lt; break;
        case TokenKind::Gt: op = BinaryOp::Gt; break;
        case TokenKind::Le: op = BinaryOp::Le; break;
        case TokenKind::Ge: op = BinaryOp::Ge; break;
        default: return l;
    }
    advance();
    return binary(op, l, parse_cons());
}

const Expr* Parser::parse_cons() {
    const Expr* l = parse_add();
    if (!accept(TokenKind::ColonColon)) return l;
    Expr* e = make(ExprKind::Cons);
    e->first = l;
    e->second = parse_cons();
    return e;
}

const Expr* Parser::parse_add() {
    const Expr* l = parse_mul();
    for (;;) {
        if (accept(TokenKind::Plus)) l = binary(BinaryOp::Add, l, parse_mul());
        else if (accept(TokenKind::Minus)) l = binary(BinaryOp::Sub, l, parse_mul());
        else return l;
    }
}

const Expr* Parser::parse_mul() {
    const Expr* l = parse_app();
    for (;;) {
        if (accept(TokenKind::Star)) l = binary(BinaryOp::Mul, l, parse_app());
        else if (accept(TokenKind::Slash)) l = binary(BinaryOp::Div, l, parse_app());
        else return l;
    }
}

const Expr* Parser::parse_app() {
    const Expr* f = parse_atom();
    if (!starts_atom(peek().kind)) return f;
    std::vector<const Expr*> args;
    while (starts_atom(peek().kind)) args.push_back(parse_atom());
    Expr* e = make(ExprKind::App);
    e->first = f;
    e->items = arena_.copy(args);
    return e;
}

const Expr* Parser::parse_atom() {
    const Token& t = peek();
    switch (t.kind) {
        case TokenKind::Int:
            advance();
            return make(ExprKind::Int);
        case TokenKind::KwTrue:
        case TokenKind::KwFalse:
            advance();
            return make(ExprKind::Bool);
        case TokenKind::Ident: {
            Expr* e = make(ExprKind::Var);
            e->name = symbols_.intern(advance().text);
            return e;
        }
        case TokenKind::LParen: {
            advance();
            if (accept(TokenKind::RParen)) return make(ExprKind::Unit);
            const Expr* first = parse_expr();
            if (accept(TokenKind::RParen)) return first;
            std::vector<const Expr*> items{first};
            while (accept(TokenKind::Comma)) items.push_back(parse_expr());
            if (items.size() < 2) throw ParseError("expected ')' or ','", peek().offset);
            expect(TokenKind::RParen, "')'");
            Expr* e = make(ExprKind::Tuple);
            e->items = arena_.copy(items);
            return e;
        }
        case TokenKind::LBracket: {
            advance();
            if (accept(TokenKind::RBracket)) return make(ExprKind::Nil);
            std::vector<const Expr*> items{parse_expr()};
            while (accept(TokenKind::Semi)) items.push_back(parse_expr());
            expect(TokenKind::RBracket, "']'");
            Expr* e = make(ExprKind::List);
            e->items = arena_.copy(items);
            return e;
        }
        default:
            throw ParseError("unexpected token", t.offset);
    }
}

}  // namespace typeinfer
