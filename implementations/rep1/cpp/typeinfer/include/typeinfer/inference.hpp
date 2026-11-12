// Algorithm J: single-pass, left-to-right Hindley-Milner inference.
#pragma once

#include "typeinfer/ast.hpp"
#include "typeinfer/environment.hpp"
#include "typeinfer/types.hpp"

namespace typeinfer {

/// Infers types for expressions and declarations against an environment.
///
/// The inferencer recurses on the nesting of the expression, so very deeply
/// nested input needs a correspondingly deep call stack.
class Inferencer {
public:
    Inferencer(TypeStore& store, Environment& env) : store_(store), env_(env) {}

    /// Infers one top-level declaration. For `let` / `let rec` the generalised
    /// binding is added to the environment. Returns the (generalised) type.
    /// On failure throws `TypeError`, leaving the environment unchanged.
    Type* infer_declaration(const Decl& decl);

    /// Infers the type of an expression at the current level.
    Type* infer(const Expr& e);

private:
    Type* lookup(Symbol name);
    Type* infer_lambda(std::span<const Symbol> params, const Expr& body);
    Type* infer_application(const Expr& e);
    Binding infer_binding(bool rec, Symbol name, std::span<const Symbol> params, const Expr& rhs);

    TypeStore& store_;
    Environment& env_;
    int level_ = 0;
};

}  // namespace typeinfer
