// Abstract syntax tree. Nodes are allocated in an `Arena` and refer to each
// other by raw pointer; they live until the arena is cleared.
#pragma once

#include <span>

#include "typeinfer/symbol.hpp"

namespace typeinfer {

enum class ExprKind {
    Int,     ///< integer literal (value irrelevant)
    Bool,    ///< `true` / `false`
    Unit,    ///< `()`
    Var,     ///< `name`
    Nil,     ///< `[]`
    Tuple,   ///< `(items...)`, at least 2 items
    List,    ///< `[items...]`, at least 1 item
    Cons,    ///< `first :: second`
    Binary,  ///< `first op second`
    App,     ///< `first items...` (n-ary application, left-associated)
    Lambda,  ///< `fun params -> second`
    If,      ///< `if first then second else third`
    Let,     ///< `let name params = first in second`
    LetRec,  ///< `let rec name params = first in second`
};

enum class BinaryOp { Add, Sub, Mul, Div, Eq, Lt, Gt, Le, Ge, And, Or };

struct Expr {
    ExprKind kind;
    BinaryOp op = BinaryOp::Add;  ///< Binary only
    Symbol name = 0;              ///< Var, Let, LetRec
    const Expr* first = nullptr;
    const Expr* second = nullptr;
    const Expr* third = nullptr;
    std::span<const Expr* const> items;  ///< Tuple elements, List elements, App arguments
    std::span<const Symbol> params;      ///< Lambda / Let / LetRec parameters
};

enum class DeclKind {
    Let,     ///< `let name params = body ;;`
    LetRec,  ///< `let rec name params = body ;;`
    Expr,    ///< `body ;;`
};

/// A top-level declaration. For Let/LetRec, `body` is the right-hand side
/// *without* the parameters (they are in `params`).
struct Decl {
    DeclKind kind;
    Symbol name = 0;
    std::span<const Symbol> params;
    const Expr* body = nullptr;
};

}  // namespace typeinfer
