// Recursive-descent parser producing one declaration at a time.
#pragma once

#include <optional>
#include <vector>

#include "typeinfer/arena.hpp"
#include "typeinfer/ast.hpp"
#include "typeinfer/lexer.hpp"
#include "typeinfer/symbol.hpp"

namespace typeinfer {

/// Parses the token stream of one program, declaration by declaration.
///
/// The parser recurses on the nesting of the source, so very deeply nested
/// input needs a correspondingly deep call stack.
class Parser {
public:
    /// `tokens` must end with an End token (as `tokenize` guarantees). AST
    /// nodes are allocated in `arena`; identifiers are interned in `symbols`.
    Parser(const std::vector<Token>& tokens, SymbolTable& symbols, Arena& arena)
        : toks_(tokens), symbols_(symbols), arena_(arena) {}

    /// Parses the next declaration, or returns nullopt at end of input.
    /// Throws `ParseError` on malformed input.
    std::optional<Decl> next_declaration();

private:
    const Token& peek() const { return toks_[pos_]; }
    const Token& advance() { return toks_[pos_++]; }
    bool accept(TokenKind k);
    const Token& expect(TokenKind k, const char* what);
    Symbol expect_ident();

    const Expr* parse_expr();
    const Expr* parse_or();
    const Expr* parse_and();
    const Expr* parse_cmp();
    const Expr* parse_cons();
    const Expr* parse_add();
    const Expr* parse_mul();
    const Expr* parse_app();
    const Expr* parse_atom();
    const Expr* parse_let(bool is_decl, Decl* decl);

    Expr* make(ExprKind k);
    const Expr* binary(BinaryOp op, const Expr* l, const Expr* r);
    std::span<const Symbol> parse_params();

    const std::vector<Token>& toks_;
    SymbolTable& symbols_;
    Arena& arena_;
    std::size_t pos_ = 0;
};

}  // namespace typeinfer
