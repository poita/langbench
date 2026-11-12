// Type graph, unification, generalisation and instantiation.
#pragma once

#include <climits>
#include <cstdint>
#include <span>

#include "typeinfer/arena.hpp"

namespace typeinfer {

enum class TypeKind : std::uint8_t { Var, Int, Bool, Unit, Fun, Tuple, List };

/// A node of the shared type graph.
///
/// Type variables are union-find nodes: an unbound variable has `link ==
/// nullptr`, a bound one points at its binding. Constructor nodes are also
/// forwarded (`link`) once they have been unified with a structurally equal
/// node, which keeps unification of shared (DAG) types linear in the number
/// of distinct nodes. Always look through links with `TypeStore::repr`.
struct Type {
    TypeKind kind;
    std::uint32_t nargs;      ///< number of children (Fun: 2, List: 1, Tuple: n)
    int level;                ///< Var only: binding level (`kGenericLevel` if quantified)
    std::uint32_t mark;       ///< epoch stamp of the last walk that visited this node
    Type* link;               ///< union-find forwarding pointer
    union {
        Type* copy;           ///< scratch result of the current walk (instantiation)
        std::uint32_t index;  ///< scratch variable number of the current walk (printing)
    } aux;
    Type** args;              ///< children
};

/// Owns all type nodes and implements the type-level operations of Algorithm J
/// with level-based (Rémy) generalisation.
///
/// Every walk (occurs check, generalisation, instantiation, printing) visits
/// each distinct node once, using per-node epoch stamps, and so is linear in
/// the size of the type as a DAG. Walks recurse on type depth; extremely deep
/// types need a correspondingly deep call stack.
class TypeStore {
public:
    /// Level value of quantified (generic) type variables.
    static constexpr int kGenericLevel = INT_MAX;

    TypeStore();

    // Constructors. Int/Bool/Unit are shared singletons.
    Type* int_type() const { return int_; }
    Type* bool_type() const { return bool_; }
    Type* unit_type() const { return unit_; }
    Type* fresh_var(int level);
    Type* generic_var() { return fresh_var(kGenericLevel); }
    Type* fun(Type* from, Type* to);
    Type* list(Type* elem);
    Type* tuple(std::span<Type* const> elems);

    /// Follows links (with path compression) to the representative node.
    static Type* repr(Type* t);

    /// Unifies two types, left to right, binding variables with an occurs
    /// check and lowering the levels of the variables it reaches.
    /// Throws `TypeError` (Unify or Occurs).
    void unify(Type* a, Type* b);

    /// Quantifies every unbound variable of `t` whose level exceeds `level`.
    /// Returns true if at least one variable was quantified.
    bool generalize(Type* t, int level);

    /// Copies `t`, replacing quantified variables by fresh variables at
    /// `level`. Sub-terms without quantified variables are shared.
    Type* instantiate(Type* t, int level);

    /// Starts a new walk: returns a fresh epoch for stamping `Type::mark`.
    std::uint32_t next_epoch() { return ++epoch_; }
    std::uint32_t epoch() const { return epoch_; }

private:
    Type* alloc(TypeKind kind, std::uint32_t nargs);
    void bind(Type* var, Type* target);
    void occurs_adjust(Type* t, Type* var);
    void generalize_walk(Type* t, int level, bool& any);
    Type* instantiate_walk(Type* t, int level);

    Arena arena_;
    Type* int_;
    Type* bool_;
    Type* unit_;
    std::uint32_t epoch_ = 0;
};

}  // namespace typeinfer
